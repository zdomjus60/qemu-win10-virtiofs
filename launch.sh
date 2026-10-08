#!/usr/bin/env bash
#
# Launcher VM Windows 10/11 (QEMU/KVM + OVMF + swtpm + virtiofsd)
#
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

# --- configurazione predefinita ----------------------------------------
DISK="win10.qcow2"
MEM=""                 # RAM della VM in MB; vuoto = auto (rilevata all'avvio)
SMP=""                 # vCPU della VM;   vuoto = auto (rilevate all'avvio)
NET="tap"
ISO=0
DRIVERS=0
TPM=0
SECUREBOOT=0
SHARE=0
FS=1                 # 1 = condivisione VirtIO-FS via virtiofsd (default)
AUTO_NET=1           # 1 = se la rete tap non c'e', lancia da solo qemu-up.sh
CHECK=0
DRYRUN=0
CREATE_SIZE=""

# Condivisione host <-> guest (virtiofsd, sostituisce Samba)
SHARE_DIR="$PWD/condivisa"          # cartella dell'host da esporre
SHARE_TAG="condivisa"               # tag visto dentro Windows
VIRTIOFS_SOCK="$PWD/virtiofsd.sock" # socket vhost-user di virtiofsd
VIRTIOFS_LOG="$PWD/virtiofsd.log"    # log di virtiofsd (per debug)

# Disco di supporto: montato in Windows come unita' con setup-virtiofs.bat.
# Preferita l'immagine FAT reale SETUP_IMG (MBR + partizione FAT32, costruita
# con mkfs.fat + mtools): Windows NON monta un disco FAT senza partizione
# (superfloppy), quindi la partizione e' obbligatoria. vvfat (fat:rw:cartella)
# e' solo il fallback: in QEMU 10 va a volte in assertion "index < array->next"
# e fa morire la VM.
SETUP_DIR="$PWD/tools"
SETUP_IMG="$PWD/tools.img"
SETUP_MODE=""            # image | dir (deciso nei controlli preliminari)

WIN_ISO="en-us_windows_10_iot_enterprise_ltsc_2021_x64_dvd_257ad90f.iso"
VIRTIO_ISO="virtio-win-0.1.262.iso"
# accetta qualunque ISO virtio-win scaricata (virtio-win.iso, virtio-win-0.1.302.iso, ...)
if [ ! -f "$VIRTIO_ISO" ]; then
	for f in virtio-win*.iso; do
		[ -f "$f" ] && { VIRTIO_ISO="$f"; break; }
	done
fi

err()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }
info() { echo "  -> $*"; }

usage() {
	cat <<EOF
Usage: ./launch.sh [options]

Start the Windows VM with KVM, UEFI firmware (persistent pflash),
Hyper-V enlightenments, PipeWire audio and tap0/slirp networking.

Options:
  --create [SIZE]     create the qcow2 disk (default 100G) and exit
  --iso               attach the Windows+virtio ISOs and boot from CD (installation)
  --iso-file FILE     use another Windows ISO (same as --iso; e.g. Win11_25H2...iso)
  --drivers           attach the virtio-win ISO only (optional: the setup
                      prepares drivers and WinFsp in tools/ by itself, no ISO needed)
  --tpm               start swtpm (TPM 2.0, required for Windows 11)
  --secureboot        use OVMF with Secure Boot (Microsoft keys pre-enrolled)
  --net tap|user      network: tap0 with bridge/NAT (default) or rootless slirp
  --no-auto-net       if the tap network is missing, do not launch qemu-up.sh automatically
  --disk FILE         use a different qcow2 disk (default: $DISK)
  --smp N             VM vCPUs (default: auto — half the host threads, 1-8)
  --mem SIZE          VM RAM in MB or with G suffix, e.g. 4096 or 6G
                      (default: auto — about half the host RAM, 2G-16G)
  --share             info on the VirtIO-FS share (virtiofsd) and the Windows driver
  --share-dir DIR     host folder to share (default: ./condivisa)
  --no-share          start the VM without the VirtIO-FS share
  --check             only check KVM/display/disk/network and exit (no VM)
  --dry-run           print the qemu command without running it
  -h, --help          this help

Examples:
  ./launch.sh --create 120G
  ./qemu-up.sh && ./launch.sh --iso                     # Windows 10 installation
  ./qemu-up.sh && ./launch.sh --iso-file Win11_25H2_Italian_x64.iso --tpm --secureboot
                                                         # Windows 11 installation
  ./launch.sh                                           # normal start (network and share ready)
  ./qemu-up.sh && ./launch.sh --tpm                     # Windows 11 start (manual network)
  ./launch.sh --net user                                # network without bridge
  ./launch.sh --share                                   # VirtIO-FS share info
  ./launch.sh --share-dir "$HOME/Documenti"             # share another folder
EOF
}

# --- parsing argomenti ---------------------------------------------------
# --- risorse della VM: rilevamento automatico -----------------------------
# Senza --smp/--mem le risorse si adattano all'host:
#   vCPU: meta' dei thread logici, vincolata 1..8 e mai piu' del totale
#   RAM:  ~meta' della RAM dell'host, arrotondata al GB piu' vicino,
#         vincolata 2G..16G e comunque lasciando almeno 1G all'host
detect_resources() {
	HOST_THREADS=$(nproc 2>/dev/null || echo 1)
	HOST_MB=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
	[ "$HOST_MB" -ge 1024 ] || HOST_MB=8192   # /proc/meminfo illeggibile: prudente

	if [ -z "$SMP" ]; then
		SMP_SRC="auto"
		SMP=$(( HOST_THREADS / 2 ))
		[ "$SMP" -ge 2 ] || SMP=2
		[ "$SMP" -le 8 ] || SMP=8
		[ "$SMP" -le "$HOST_THREADS" ] || SMP=$HOST_THREADS
	else
		SMP_SRC="manual"
		[[ "$SMP" =~ ^[1-9][0-9]*$ ]] || err "--smp: a positive integer is required (e.g. 4)"
	fi

	if [ -z "$MEM" ]; then
		MEM_SRC="auto"
		MEM=$(( (HOST_MB / 2 + 512) / 1024 * 1024 ))   # ~meta', al GB piu' vicino
		[ "$MEM" -ge 2048 ] || MEM=2048
		[ "$MEM" -le 16384 ] || MEM=16384
		[ "$MEM" -le $((HOST_MB - 1024)) ] || MEM=$((HOST_MB - 1024))
		[ "$MEM" -ge 1024 ] || MEM=1024
	else
		MEM_SRC="manual"
		case "$MEM" in
			*[Gg]) MEM="${MEM%[Gg]}"; MEM=$(( MEM * 1024 )) ;;
		esac
		[[ "$MEM" =~ ^[0-9]+$ ]] && [ "$MEM" -ge 1024 ] ||
			err "--mem: a number >= 1024 MB is required, or with G suffix (e.g. 4096 or 6G)"
		[ "$MEM" -le "$HOST_MB" ] ||
			warn "--mem ${MEM}MB exceeds the host RAM (${HOST_MB}MB): starting anyway (overcommit), but the host may suffer"
	fi
}

while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help) usage; exit 0 ;;
		--create)
			if [ $# -gt 1 ] && [[ "$2" != -* ]]; then CREATE_SIZE="$2"; shift; fi
			CREATE_SIZE="${CREATE_SIZE:-100G}"
			shift ;;
		--iso)        ISO=1; shift ;;
		--iso-file)
			[ $# -ge 2 ] || err "--iso-file requires the path to an ISO"
			WIN_ISO="$2"; ISO=1; shift 2 ;;
		--drivers)    DRIVERS=1; shift ;;
		--tpm)        TPM=1; shift ;;
		--secureboot) SECUREBOOT=1; shift ;;
		--share)      SHARE=1; shift ;;
		--no-share)   FS=0; shift ;;
		--share-dir)
			[ $# -ge 2 ] || err "--share-dir requires the path to a folder"
			SHARE_DIR="$2"; shift 2 ;;
		--check)      CHECK=1; shift ;;
		--dry-run)    DRYRUN=1; shift ;;
		--net)
			[ $# -ge 2 ] || err "--net requires 'tap' or 'user'"
			NET="$2"; shift 2 ;;
		--no-auto-net) AUTO_NET=0; shift ;;
		--disk)
			[ $# -ge 2 ] || err "--disk requires a qcow2 file"
			DISK="$2"; shift 2 ;;
		--smp)
			[ $# -ge 2 ] || err "--smp requires a vCPU count (e.g. 4)"
			SMP="$2"; shift 2 ;;
		--mem)
			[ $# -ge 2 ] || err "--mem requires a size in MB or with G suffix (e.g. 4096 or 6G)"
			MEM="$2"; shift 2 ;;
		*) err "unknown option: $1  (use --help)" ;;
	esac
done

[ "$NET" = "tap" ] || [ "$NET" = "user" ] || err "--net accepts only 'tap' or 'user'"
[ "$ISO" -eq 0 ] || [ "$DRIVERS" -eq 0 ] || err "--iso and --drivers are incompatible"

detect_resources

# --- info cartella condivisa (VirtIO-FS) ----------------------------------
VIRTIOFSD_BIN=""
for c in virtiofsd /usr/libexec/virtiofsd /usr/lib/qemu/virtiofsd; do
	if command -v "$c" >/dev/null 2>&1; then VIRTIOFSD_BIN="$(command -v "$c")"; break; fi
	if [ -x "$c" ]; then VIRTIOFSD_BIN="$c"; break; fi
done

if [ "$SHARE" -eq 1 ]; then
	echo "Shared folder host <-> VM (VirtIO-FS, replacing Samba):"
	if [ -n "$VIRTIOFSD_BIN" ]; then
		echo "   - virtiofsd     : $VIRTIOFSD_BIN ($(virtiofsd --version 2>/dev/null || "$VIRTIOFSD_BIN" --version 2>/dev/null || echo '?'))"
	else
		echo "   - virtiofsd     : NOT INSTALLED -> sudo apt install virtiofsd"
	fi
	echo "   - host folder   : $SHARE_DIR"
	echo "   - tag in guest  : $SHARE_TAG"
	echo "   - socket        : $VIRTIOFS_SOCK"
	if [ "$FS" -eq 0 ]; then
		echo "   - status        : DISABLED (--no-share)"
	elif [ -S "$VIRTIOFS_SOCK" ]; then
		echo "   - status        : active (virtiofsd running)"
	else
		echo "   - status        : starts with the VM (automatic, no service to start)"
	fi
	echo
	echo "Inside Windows (fully automatic):"
	echo "   1. start the VM:  ./launch.sh"
	echo "      (in tools/ it prepares the VirtIO FS drivers extracted from the ISO"
	echo "       and the WinFsp installer: inside Windows no ISO or network needed)"
	echo "   2. inside Windows open the drive containing  setup-virtiofs.bat"
	echo "      (a small virtual disk, e.g. E: — it's the one with the .bat file)"
	echo "   3. run  setup-virtiofs.bat  right-click -> Run as administrator"
	echo "      it does it all: WinFsp, VirtIO FS driver, VirtioFsSvc service"
	echo "   4. File Explorer: the '$SHARE_TAG' share appears as a drive (default Z:)"
	echo "      different letter:  setup-virtiofs.bat X:"
	echo "   (optional: --drivers also attaches the virtio-win ISO as a drive)"
	exit 0
fi

# --- creazione disco -----------------------------------------------------
if [ -n "$CREATE_SIZE" ]; then
	if [ -e "$DISK" ]; then err "$DISK already exists: use --disk <otherfile> or rename it"; fi
	qemu-img create -f qcow2 "$DISK" "$CREATE_SIZE"
	info "disk created: $DISK ($CREATE_SIZE)"
	exit 0
fi

# --- firmware UEFI -------------------------------------------------------
if [ "$SECUREBOOT" -eq 1 ]; then
	# .ms = template con chiavi Microsoft gia' incluse (Windows Boot Manager parte
	# con Secure Boot attivo). Il template .snakeoil NON serve: bloccherebbe Windows.
	OVMF_CODE="OVMF/OVMF_CODE_4M.secboot.fd"
	OVMF_VARS_SRC="OVMF/OVMF_VARS_4M.ms.fd"
	OVMF_VARS="OVMF_VARS_win10.secboot.fd"
else
	OVMF_CODE="OVMF/OVMF_CODE_4M.fd"
	OVMF_VARS_SRC="OVMF/OVMF_VARS_4M.fd"
	OVMF_VARS="OVMF_VARS_win10.fd"
fi
[ -e "$OVMF_CODE" ] || err "missing firmware $OVMF_CODE"
[ -e "$OVMF_VARS_SRC" ] || err "missing $OVMF_VARS_SRC"

# --- asset per il setup Windows (driver + WinFsp in tools/) ---------------
# Prepara quello che a setup-virtiofs.bat servira' dentro Windows: tutto
# finisce in tools/ (montato in VM come unita' FAT), cosi' dentro Windows non
# servono ne' la ISO virtio-win montata ne' la rete. Una tantum: si esegue
# solo se qualcuno manca, prima dell'avvio della VM.
prepare_setup_assets() {
	[ "$FS" -eq 1 ] || return 0
	[ -d "$SETUP_DIR" ] || return 0
	local c z7="" url nome

	# 1) driver VirtIO-FS estratti dalla ISO virtio-win (niente --drivers)
	if [ ! -f "$SETUP_DIR/viofs/w10/amd64/viofs.inf" ]; then
		for c in 7z 7zz 7zr; do
			if command -v "$c" >/dev/null 2>&1; then z7="$c"; break; fi
		done
		if [ -e "$VIRTIO_ISO" ] && [ -n "$z7" ]; then
			info "extracting VirtIO-FS drivers from $VIRTIO_ISO -> tools/viofs/ (one-time)"
			"$z7" x -y "-o$SETUP_DIR" "$VIRTIO_ISO" "viofs/w10/amd64/*" "viofs/w11/amd64/*" >/dev/null 2>&1 || true
			rm -f "$SETUP_DIR"/viofs/*/amd64/*.pdb 2>/dev/null || true
		fi
		if [ ! -f "$SETUP_DIR/viofs/w10/amd64/viofs.inf" ]; then
			warn "VirtIO-FS drivers not extracted ($VIRTIO_ISO + 7z needed): inside Windows the mounted ISO will be needed (use --drivers)"
		fi
	fi

	# 2) installer di WinFsp (cosi' dentro Windows non serve la rete).
	#    Le release recenti da GitHub forniscono un .msi, quelle vecchie un
	#    .setup.exe: accetto entrambi. (ls su piu' pattern fallisce se ne
	#    manca anche solo uno: i due controlli vanno fatti separati.)
	if ! ls "$SETUP_DIR"/winfsp*.msi >/dev/null 2>&1 &&
		! ls "$SETUP_DIR"/winfsp*.exe >/dev/null 2>&1; then
		if command -v curl >/dev/null 2>&1; then
			url=$(curl -fsSL --max-time 20 "https://api.github.com/repos/winfsp/winfsp/releases/latest" 2>/dev/null |
				grep -o '"browser_download_url": *"[^"]*"' |
				sed 's|^"browser_download_url": *"||; s|"$||' |
				grep -Ei '\.(msi|exe)$' | grep -vi test | head -1 || true)
			if [ -n "$url" ]; then
				nome="$SETUP_DIR/$(basename "$url")"
				info "downloading WinFsp -> tools/$(basename "$url") (one-time)"
				if ! curl -fsSL --max-time 180 -o "$nome" "$url"; then
					rm -f "$nome"
					warn "WinFsp download failed: inside Windows you will be asked to install it manually"
				fi
			else
				warn "WinFsp installer not found on GitHub: inside Windows you will be asked to install it manually"
			fi
		else
			warn "curl not installed: inside Windows you will be asked to install WinFsp manually"
		fi
	fi
	return 0
}

# --- disco di supporto: immagine FAT reale (tools.img) ---------------------
# Costruisce/aggiorna tools.img con dentro tools/ e la monta come unita'
# ordinaria: niente vvfat (modulo con assertion nota in QEMU 10, vedi
# GitLab qemu#2958, che uccide la VM in modo intermittente).
# Funziona solo se ci sono dosfstools (mkfs.fat) + mtools (mcopy), altrimenti
# si avvisa e si ricade su vvfat.
find_mkfs() {
	local c
	for c in mkfs.vfat mkfs.fat /sbin/mkfs.vfat /sbin/mkfs.fat \
		/usr/sbin/mkfs.vfat /usr/sbin/mkfs.fat; do
		if command -v "$c" >/dev/null 2>&1; then
			printf '%s\n' "$c"
			return 0
		fi
	done
	return 1
}

fat_image_possible() {
	find_mkfs >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1
}

# true se tools.img contiene gia' la partizione MBR attesa (entry 1 valida:
# CHS fe:ff:ff, tipo 0x0C FAT32-LBA, start settore 2048, 129024 settori =
# 63M esatti fino alla fine del disco). Le immagini "vecchie" senza partizione
# — superfloppy, non montato da Windows — o con geometria errata vanno
# rigenerate.
img_has_mbr() {
	[ -f "$SETUP_IMG" ] || return 1
	[ "$(od -An -tx1 -j 447 -N 15 "$SETUP_IMG" 2>/dev/null | tr -d ' \n')" = "feffff0cfeffff0008000000f80100" ]
}

build_setup_image() {
	SETUP_MODE="dir"
	[ -d "$SETUP_DIR" ] || return 0

	if ! fat_image_possible; then
		warn "dosfstools/mtools missing: setup drive via vvfat (may hit a QEMU assertion) — sudo apt install dosfstools mtools"
		return 0
	fi
	local mkfs entry fs_tmp="$PWD/.tools-fs.tmp"
	mkfs="$(find_mkfs || true)"

	# rigenera se manca, se e' la vecchia variante senza partizione, o se
	# qualcosa in tools/ e' piu' recente dell'immagine
	if img_has_mbr &&
		! find "$SETUP_DIR" -newer "$SETUP_IMG" -print -quit 2>/dev/null | grep -q .; then
		SETUP_MODE="image"
		return 0
	fi

	info "creating/updating tools.img (MBR + FAT32 partition with tools/) -> setup drive"
	rm -f "$SETUP_IMG" "$fs_tmp"

	# 1) filesystem FAT32 su file temporaneo, grande quanto la partizione (63M)
	if ! truncate -s 63M "$fs_tmp" ||
		! "$mkfs" -F 32 -n SETUP "$fs_tmp" >/dev/null 2>&1; then
		warn "FAT filesystem creation failed: setup drive via vvfat"
		rm -f "$fs_tmp"
		return 0
	fi
	for entry in "$SETUP_DIR"/*; do
		if ! mcopy -i "$fs_tmp" -s -o "$entry" ::/ >/dev/null 2>&1; then
			warn "copying '$entry' into the filesystem failed: setup drive via vvfat"
			rm -f "$fs_tmp"
			return 0
		fi
	done

	# 2) immagine finale: MBR con partizione 1 (tipo 0x0C = FAT32 LBA,
	#    start settore 2048 = 1MiB, 129024 settori = 63M; CHS fe:ff:ff =
	#    marcatore "usa LBA") e il filesystem incollato a 1MiB.
	if ! truncate -s 64M "$SETUP_IMG"; then
		warn "tools.img creation failed: setup drive via vvfat"
		rm -f "$fs_tmp"
		return 0
	fi
	if printf '\x00\xfe\xff\xff\x0c\xfe\xff\xff\x00\x08\x00\x00\x00\xf8\x01\x00' |
		dd of="$SETUP_IMG" bs=1 seek=446 conv=notrunc status=none &&
		printf '\x55\xaa' | dd of="$SETUP_IMG" bs=1 seek=510 conv=notrunc status=none &&
		dd if="$fs_tmp" of="$SETUP_IMG" bs=1048576 seek=1 conv=notrunc status=none; then
		:
	else
		warn "tools.img write failed: setup drive via vvfat"
		rm -f "$SETUP_IMG" "$fs_tmp"
		return 0
	fi
	rm -f "$fs_tmp"
	SETUP_MODE="image"
	return 0
}

# --- controlli preliminari ------------------------------------------------
if [ "$DRYRUN" -eq 0 ]; then
	[ -e "$DISK" ] || err "missing $DISK — create the VM with: ./launch.sh --create 100G"
	if [ ! -e /dev/kvm ]; then
		err "/dev/kvm missing: the CPU has no VT-x/AMD-V, or it is disabled in the BIOS (Intel Virtualization Technology / AMD-V / SVM), or the module is not loaded (sudo modprobe kvm_intel or kvm_amd). Check from a live session: grep -E 'vmx|svm' /proc/cpuinfo"
	elif [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
		err "/dev/kvm not accessible. Add yourself to the group: sudo usermod -aG kvm \$USER  (then log out and back in)"
	fi
	if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
		err "no display available (DISPLAY/WAYLAND_DISPLAY not set)"
	fi
	if [ "$(id -u)" -eq 0 ]; then
		warn "you are running as root: audio and display may not work. Run ./launch.sh as a normal user."
	fi
	if [ "$ISO" -eq 1 ]; then
		[ -e "$WIN_ISO" ] || err "missing $WIN_ISO (needed for --iso): download a Windows ISO and pass it with --iso-file FILE (README §1.5)"
		[ -e "$VIRTIO_ISO" ] || warn "virtio-win ISO not found: only the Windows ISO will be attached (download it for the CD driver flow, README §1.5)"
	fi
	if [ "$DRIVERS" -eq 1 ]; then
		[ -e "$VIRTIO_ISO" ] || err "missing virtio-win ISO (needed for --drivers): download it, see README §1.5"
	fi
	if [ "$FS" -eq 1 ]; then
		[ -n "$VIRTIOFSD_BIN" ] || err "virtiofsd not installed (sudo apt install virtiofsd) — or start with --no-share"
		[ -d "$SHARE_DIR" ] || { mkdir -p "$SHARE_DIR"; info "shared folder created: $SHARE_DIR"; }
		[ -w "$SHARE_DIR" ] || err "shared folder not writable: $SHARE_DIR"
	fi
	if [ ! -e "$OVMF_VARS" ]; then
		cp "$OVMF_VARS_SRC" "$OVMF_VARS"
		info "NVRAM created: $OVMF_VARS (persistent boot entries)"
	fi

	# asset per il setup dentro Windows: tutto in tools/ (una tantum)
	prepare_setup_assets

	# immagine FAT del disco di setup (aggiornata se tools/ cambia)
	build_setup_image
fi

# --- rete ----------------------------------------------------------------
check_tap() {
	local problems=()
	ip link show dev br0 >/dev/null 2>&1 || problems+=("br0 does not exist")
	ip link show dev tap0 >/dev/null 2>&1 || problems+=("tap0 does not exist")
	if ip link show dev tap0 >/dev/null 2>&1; then
		ip link show dev tap0 | grep -q "master br0" || problems+=("tap0 is not attached to br0")
		ip -br link show dev tap0 | grep -oE '<[^>]*>' | grep -qw UP || problems+=("tap0 is down")
	fi
	if ip link show dev br0 >/dev/null 2>&1; then
		ip -br link show dev br0 | grep -oE '<[^>]*>' | grep -qw UP || problems+=("br0 is down")
		ip -4 addr show dev br0 2>/dev/null | grep -q "192.168.100.1/24" ||
			problems+=("br0 does not have address 192.168.100.1")
		local dnspid
		dnspid=$(cat /run/qemu-dnsmasq.pid 2>/dev/null || true)
		# /proc/<pid>/comm e' leggibile da tutti: kill -0 darebbe EPERM
		# perche' dnsmasq gira come root/nobody
		if [ -n "$dnspid" ] && [ -r "/proc/$dnspid/comm" ] &&
			grep -q dnsmasq "/proc/$dnspid/comm" 2>/dev/null; then
			:
		else
			problems+=("DHCP (VM dnsmasq) not running")
		fi
	fi
	if [ ${#problems[@]} -gt 0 ]; then
		echo "Network not ready:" >&2
		local p
		for p in "${problems[@]}"; do echo "   - $p" >&2; done
		echo "Run: ./qemu-up.sh   (or start with --net user)" >&2
		return 1
	fi
	return 0
}

if [ "$NET" = "tap" ] && [ "$DRYRUN" -eq 0 ]; then
	if ! check_tap; then
		if [ "$AUTO_NET" -eq 1 ]; then
			echo
			info "I'll prepare it: launching ./qemu-up.sh (if needed, the sudo password goes to the terminal)"
			if ./qemu-up.sh; then
				echo
				check_tap || err "the network is still not ready after qemu-up.sh (check the output above)"
				info "network ready"
			else
				err "qemu-up.sh failed — fix the network manually, or start with: ./launch.sh --net user"
			fi
		else
			err "run ./qemu-up.sh  or start with: ./launch.sh --net user   (--no-auto-net active)"
		fi
	fi
fi

# --- lock immagine -------------------------------------------------------
check_lock() {
	command -v python3 >/dev/null 2>&1 || return 0
	python3 - "$DISK" <<'PY' || err "$DISK is already in use by another QEMU instance: close the old one"
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_WRONLY)
try:
    fcntl.lockf(fd, fcntl.LOCK_EX | fcntl.LOCK_NB, 1, 0)
except OSError:
    sys.exit(1)
finally:
    os.close(fd)
PY
}
if [ "$DRYRUN" -eq 0 ]; then check_lock; fi

# --- solo controllo (nessuna VM) -----------------------------------------
if [ "$CHECK" -eq 1 ]; then
	echo "Checks passed:"
	echo "   - disk $DISK present"
	echo "   - /dev/kvm accessible and display available"
	if [ "$NET" = "tap" ]; then
		echo "   - tap0/br0 network ready (bridge 192.168.100.1 + DHCP active)"
		[ "$AUTO_NET" -eq 1 ] && echo "     (if it was missing, it was just prepared by qemu-up.sh)"
	else
		echo "   - network: slirp (no configuration needed)"
	fi
	if [ "$FS" -eq 1 ]; then
		echo "   - VirtIO-FS share: $SHARE_DIR  (virtiofsd: ${VIRTIOFSD_BIN:-MISSING})"
	else
		echo "   - VirtIO-FS share: disabled (--no-share)"
	fi
	echo "   - image $DISK not locked"
	echo
	echo "Everything ready: start with  ./launch.sh"
	exit 0
fi

# --- TPM (swtpm) ---------------------------------------------------------
TPM_PID=""
VIRTIOFS_PID=""
VIRTIOFS_SOCK_INO=""
cleanup() {
	if [ -n "$TPM_PID" ] && kill -0 "$TPM_PID" 2>/dev/null; then
		kill "$TPM_PID" 2>/dev/null || true
		wait "$TPM_PID" 2>/dev/null || true
	fi
	if [ -n "$VIRTIOFS_PID" ] && kill -0 "$VIRTIOFS_PID" 2>/dev/null; then
		kill "$VIRTIOFS_PID" 2>/dev/null || true
		wait "$VIRTIOFS_PID" 2>/dev/null || true
	fi
	# rimuovi il socket SOLO se e' ancora quello creato da noi: se un altro
	# launch.sh ha gia' riavviato virtiofsd, non glielo cancelliamo
	if [ -n "$VIRTIOFS_SOCK_INO" ]; then
		local ino
		ino="$(stat -c %i "$VIRTIOFS_SOCK" 2>/dev/null || true)"
		if [ -n "$ino" ] && [ "$ino" = "$VIRTIOFS_SOCK_INO" ]; then
			rm -f "$VIRTIOFS_SOCK"
		fi
	fi
	return 0
}
trap cleanup EXIT

TPM_ARGS=()
TPM_SOCK="$(pwd)/swtpm/sock"
if [ "$TPM" -eq 1 ]; then
	if [ "$DRYRUN" -eq 0 ]; then
		command -v swtpm >/dev/null 2>&1 || err "swtpm not installed (sudo apt install swtpm swtpm-tools)"
		mkdir -p swtpm/state
		rm -f "$TPM_SOCK"
		swtpm socket --tpmstate dir=swtpm/state \
			--ctrl "type=unixio,path=$TPM_SOCK" \
			--tpm2 --flags not-need-init,startup-clear \
			>/dev/null 2>&1 &
		TPM_PID=$!
		sleep 0.5
		kill -0 "$TPM_PID" 2>/dev/null || err "swtpm did not start (check the swtpm/ folder)"
		info "TPM 2.0 started (persistent state in swtpm/state)"
	fi
	TPM_ARGS=(
		-chardev "socket,id=chrtpm,path=$TPM_SOCK"
		-tpmdev emulator,id=tpm0,chardev=chrtpm
		-device tpm-tis,tpmdev=tpm0
	)
fi

# --- condivisione VirtIO-FS (virtiofsd) -----------------------------------
# Sostituisce Samba: virtiofsd espone SHARE_DIR su un socket vhost-user e
# QEMU lo presenta alla VM come dispositivo PCI "VirtIO FS".
VIRTIOFS_ARGS=()
if [ "$FS" -eq 1 ]; then
	if [ "$DRYRUN" -eq 0 ]; then
		# residuo di un avvio precedente sullo stesso socket: chiudilo prima
		if [ -S "$VIRTIOFS_SOCK" ]; then
			for p in $(pgrep -x virtiofsd 2>/dev/null || true); do
				if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qF -- "$VIRTIOFS_SOCK"; then
					info "closing leftover virtiofsd (pid $p)"
					kill "$p" 2>/dev/null || true
				fi
			done
			sleep 0.5
		fi
		rm -f "$VIRTIOFS_SOCK"
		# --xattr: preserva gli xattr dell'host. --posix-acl omesso: il client
		# Windows non lo supporta (genererebbe solo "client does not support")
		"$VIRTIOFSD_BIN" \
			--shared-dir "$SHARE_DIR" \
			--socket-path "$VIRTIOFS_SOCK" \
			--cache auto --xattr \
			>"$VIRTIOFS_LOG" 2>&1 &
		VIRTIOFS_PID=$!
		# attendi la creazione del socket (max ~5 s)
		for _ in $(seq 1 50); do
			[ -S "$VIRTIOFS_SOCK" ] && break
			kill -0 "$VIRTIOFS_PID" 2>/dev/null || break
			sleep 0.1
		done
		[ -S "$VIRTIOFS_SOCK" ] ||
			err "virtiofsd did not start: see $VIRTIOFS_LOG"
		VIRTIOFS_SOCK_INO="$(stat -c %i "$VIRTIOFS_SOCK" 2>/dev/null || true)"
		info "VirtIO-FS share ready: $SHARE_DIR  (tag '$SHARE_TAG')"
	fi
	VIRTIOFS_ARGS=(
		-chardev "socket,id=vfs0,path=$VIRTIOFS_SOCK"
		-device "vhost-user-fs-pci,chardev=vfs0,tag=$SHARE_TAG"
	)
fi

# --- disco di supporto (setup-virtiofs.bat dentro Windows) -----------------
# Usata tools.img se esiste/è stata costruita; altrimenti (fallback vvfat o
# dry-run) la cartella tools/ montata direttamente da QEMU.
SETUP_ARGS=()
if [ -d "$SETUP_DIR" ]; then
	if [ -z "$SETUP_MODE" ]; then	# dry-run: solo ipotetico, nessuna costruzione
		if fat_image_possible; then SETUP_MODE="image"; else SETUP_MODE="dir"; fi
	fi
	if [ "$SETUP_MODE" = "image" ]; then
		SETUP_ARGS=(-drive "file=$SETUP_IMG,format=raw,if=ide,id=setup0")
	else
		SETUP_ARGS=(-drive "file=fat:rw:$SETUP_DIR,format=raw,if=ide,id=setup0")
	fi
fi

# --- composito comando qemu ---------------------------------------------
CDROM_ARGS=()
BOOT_ARGS=(-boot c)
if [ "$ISO" -eq 1 ]; then
	CDROM_ARGS=(-drive "file=$WIN_ISO,media=cdrom,readonly=on")
	[ -e "$VIRTIO_ISO" ] && CDROM_ARGS+=(-drive "file=$VIRTIO_ISO,media=cdrom,readonly=on")
	BOOT_ARGS=(-boot d)
elif [ "$DRIVERS" -eq 1 ]; then
	CDROM_ARGS=(-drive "file=$VIRTIO_ISO,media=cdrom,readonly=on")
fi

if [ "$NET" = "tap" ]; then
	NETDEV_ARGS=(-netdev tap,id=network0,ifname=tap0,script=no,downscript=no)
else
	NETDEV_ARGS=(-netdev user,id=network0)
fi

MON_SOCK="$(pwd)/win10-monitor.sock"

QEMU_ARGS=(
	-name "win10"
	-M "q35,accel=kvm,memory-backend=mem0"
	-cpu "host,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff,hv_vpindex,hv_runtime,hv_time,hv_synic,hv_stimer,hv_frequencies,hv_tlbflush,hv_ipi"
	-smp "$SMP"
	-m "$MEM"
	# RAM condivisa con virtiofsd: senza share=on la negoziazione vhost-user
	# fallisce (HandleRequest(InvalidParam)) e virtiofsd esce subito
	-object "memory-backend-memfd,id=mem0,size=${MEM}M,share=on"
	-drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE"
	-drive "if=pflash,format=raw,unit=1,file=$OVMF_VARS"
	-device virtio-vga-gl
	-display sdl,gl=on
	-nodefaults
	-drive "file=$DISK,format=qcow2,media=disk,discard=unmap"
	"${CDROM_ARGS[@]}"
	"${BOOT_ARGS[@]}"
	"${NETDEV_ARGS[@]}"
	-device virtio-net-pci,netdev=network0
	-device qemu-xhci
	-device usb-kbd
	-device usb-mouse
	-device usb-tablet
	-audiodev pipewire,id=snd0
	-device ich9-intel-hda
	-device hda-output,audiodev=snd0
	"${TPM_ARGS[@]}"
	"${VIRTIOFS_ARGS[@]}"
	"${SETUP_ARGS[@]}"
	-monitor "unix:$MON_SOCK,server=on,wait=off"
)

# --- dry run -------------------------------------------------------------
if [ "$DRYRUN" -eq 1 ]; then
	printf 'qemu-system-x86_64'
	printf ' %q' "${QEMU_ARGS[@]}"
	printf '\n'
	exit 0
fi

rm -f "$MON_SOCK"

# --- avvio ---------------------------------------------------------------
NET_DESC="slirp (10.0.2.2 to the host)"
[ "$NET" = "tap" ] && NET_DESC="tap0 + bridge (192.168.100.x, DHCP from dnsmasq)"
SB_DESC="$OVMF_CODE"
[ "$SECUREBOOT" -eq 1 ] && SB_DESC="$OVMF_CODE + Secure Boot"
TPM_DESC="none"
[ "$TPM" -eq 1 ] && TPM_DESC="swtpm 2.0"
ISO_DESC="none (boot from disk)"
[ "$ISO" -eq 1 ] && ISO_DESC="Windows+virtio (boot from CD)"
[ "$DRIVERS" -eq 1 ] && ISO_DESC="virtio-win (boot from disk)"
FS_DESC="disabled (--no-share)"
[ "$FS" -eq 1 ] && FS_DESC="$SHARE_DIR (tag '$SHARE_TAG')"
SETUP_DESC="missing (tools/ folder missing)"
if [ -d "$SETUP_DIR" ]; then
	if [ "$SETUP_MODE" = "image" ]; then
		SETUP_DESC="$SETUP_IMG (MBR + FAT32 partition with tools/: setup-virtiofs.bat, drivers, WinFsp)"
	else
		SETUP_DESC="$SETUP_DIR (drive via vvfat: setup-virtiofs.bat)"
	fi
fi

echo "Starting VM:"
info "cpu/ram : $SMP vCPU [$SMP_SRC], $MEM MB RAM [$MEM_SRC] (host: $HOST_THREADS threads, $HOST_MB MB)"
info "disk    : $DISK"
info "network : $NET_DESC"
info "firmware: $SB_DESC"
info "tpm     : $TPM_DESC"
info "iso     : $ISO_DESC"
info "share   : $FS_DESC"
info "setup   : $SETUP_DESC"
echo "To stop: close the VM window, or run:"
echo "         socat - UNIX-CONNECT:$MON_SOCK"

qemu-system-x86_64 "${QEMU_ARGS[@]}"
