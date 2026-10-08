# Windows 10/11 VM with QEMU/KVM — complete instructions

Guide to creating, installing, and using the Windows virtual machine in this
folder, starting from a freshly installed Debian (13 "trixie") system.

> [Italiano](README.it.md) · **English**

---

## 0. What's in this folder

| File / folder | What it's for |
|---|---|
| `launch.sh` | **The launcher**: starts the VM (network, UEFI, TPM, audio, ISO, share) |
| `qemu-up.sh` | Sets up the VM network (bridge `br0`, `tap0`, NAT, DHCP) |
| `qemu-down.sh` | Removes the network created by `qemu-up.sh` |
| `win10.qcow2` | The VM disk — **not in the repo** (23 GB): create it with `--create` (§2) |
| `en-us_windows_10_iot_enterprise_ltsc_2021_x64_dvd_257ad90f.iso` | Windows 10 ISO used by this guide — **not in the repo** (Microsoft license): download it, §1.5; for a different ISO `./launch.sh --iso-file FILE` (§4.2) |
| `virtio-win-0.1.262.iso` | Paravirtualized drivers (network, storage) — **not in the repo**: download it, §1.5 (optional, §4.3) |
| `virtio-win-guest-tools.exe` | Installer for the Windows guest tools: run it inside Windows for the network drivers (§4.1) |
| `OVMF/` | 4M UEFI firmware (CODE + VARS, Secure Boot variants `.ms` and `.snakeoil`) — in the repo (same files as the Debian `ovmf` package) |
| `ovmf/` | Old monolithic firmware + snakeoil keys (legacy, not needed; **not in the repo**) |
| `swtpm/` | swtpm sources, BSD-3 license (in the repo); `swtpm/state/` (TPM state) is generated at startup, **not in the repo** |
| `OVMF_VARS_win10.fd` | VM NVRAM: generated on first boot, **not in the repo**, **do not delete** |
| `OVMF_VARS_win10.secboot.fd` | NVRAM used with `--secureboot` (as above) |
| `condivisa/` | Folder shared with Windows via VirtIO-FS (see §6); the files inside are yours → **not in the repo** |
| `tools/` | Setup disk: `setup-virtiofs.bat` + `viofs/` drivers + WinFsp installer — **all in the repo** (`launch.sh` adds whatever is missing) |
| `tools.img` | FAT image with an MBR partition built by `launch.sh` from `tools/`: mounted in Windows as a setup drive (generated at startup, **not in the repo**) |
| `machine.sh`, `install.sh` | Legacy scripts (not used by this guide) |
| `LICENSE` | MIT license of the project |
| `THIRD_PARTY.md` | Licenses of the redistributed third-party components (firmware, drivers, swtpm) |

> **Note for those cloning the repository**: the repo has everything you need —
> scripts, `OVMF/` firmware, VirtIO-FS drivers and the WinFsp installer in `tools/`,
> `swtpm/` sources. Only these stay **outside**: the ISOs (downloadable, §1.5), the
> `win10.qcow2` disk (`./launch.sh --create`, §2), the serial key
> (`seriale.txt`), the contents of `condivisa/` (personal data), the legacy
> `ovmf/` (§9) and the files **generated at startup** (NVRAM `OVMF_VARS_win10*.fd`,
> `tools.img`, TPM state `swtpm/state/`): you don't need to create them, they appear on
> their own.

---

## 1. Installing the dependencies (from scratch)

### 1.1 Requirements

- CPU with **VT-x** (Intel) or AMD-V enabled in the physical machine's BIOS/UEFI.
  To check from a live Linux session: `grep -E 'vmx|svm' /proc/cpuinfo`
  (the `vmx`/`svm` flags must appear, along with `ept`), then
  `ls /dev/kvm` must exist. Many Celerons from 2011
  onwards have them too (e.g. Ivy Bridge): in the BIOS look for "Intel Virtualization
  Technology" and make sure it is enabled.
- ~40 GB free for the VM disk (100 GB recommended, the disk is dynamic).
- A desktop with audio (PipeWire) for window and sound.

### 1.2 User and KVM

```bash
ls -l /dev/kvm                     # must exist: crw-rw---- root kvm
groups | tr ' ' '\n' | grep kvm     # must show "kvm"
sudo usermod -aG kvm "$USER"       # if not there: add yourself to the group
# then LOG OUT of the session and back in (or reboot)
```

If the module is missing (rare):

```bash
sudo apt install --reinstall linux-image-$(uname -r)
```

### 1.3 Required packages

```bash
sudo apt update
sudo apt install -y \
    qemu-system-x86 qemu-utils \
    ovmf \
    swtpm swtpm-tools \
    dnsmasq \
    iptables \
    virtiofsd \
    dosfstools mtools
```

`virtiofsd` is the daemon that exposes the shared folder to the VM via
**VirtIO-FS** (replaces Samba: no service to start, no network
ports, no passwords).

`dosfstools` + `mtools` are needed by `launch.sh` to build `tools.img`
(the FAT image with the setup disk, see §6.1). Without them you fall back to QEMU's
`vvfat` module, which sometimes hits an assertion and kills the VM.

**Optional** but useful packages:

```bash
sudo apt install -y curl 7zip      # if tools/ is incomplete: extracts drivers from the ISO and downloads WinFsp
sudo apt install -y socat        # to talk to the QEMU monitor
sudo apt install -y cpu-checker  # provides kvm-ok, in /usr/sbin (see §1.4)
sudo apt install -y libguestfs-tools  # to inspect the disk without booting the VM
```

Audio uses PipeWire, present by default on Debian 13; if missing:

```bash
sudo apt install -y pipewire-audio pipewire-pulse wireplumber
```

### 1.4 Quick check

```bash
qemu-system-x86_64 --version      # e.g. 10.0.x
sudo /usr/sbin/kvm-ok            # optional: KVM self-test (from cpu-checker)
./launch.sh --dry-run             # prints the qemu command that would be run
```

> **Note about `kvm-ok`:** it is installed in `/usr/sbin`, a directory that is
> often **not in a normal user's `PATH`**: typing plain `kvm-ok` may answer
> *command not found* even though the package is installed. Use the full path
> as above (or `export PATH="$PATH:/usr/sbin"`). It is only a convenience:
> what really matters is `/dev/kvm` (§1.2), which `launch.sh` checks by itself
> at startup.

### 1.5 The ISOs (to download: not part of the repository)

- **Windows ISO** (only needed for installation): download the official ISO
  image from Microsoft —
  [Windows 10](https://www.microsoft.com/software-download/windows10) or
  [Windows 11](https://www.microsoft.com/software-download/windows11).
  Put it in this folder and run `./launch.sh --iso-file NAME.iso`
  (the `--iso` option with no arguments uses the name of the ISO present in
  the original folder of this guide:
  `en-us_windows_10_iot_enterprise_ltsc_2021_x64_dvd_257ad90f.iso`).
- **virtio-win driver ISO** (optional): only needed to attach it with
  `./launch.sh --drivers` and install the network drivers from the CD (§4.1, §4.3).
  For VirtIO-FS and WinFsp it is **not needed**: the drivers and installer are
  already in the repository under `tools/`. Latest version (official static
  link): [virtio-win.iso](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso).

  In the browser an anti-bot verification page appears (JavaScript required)
  and the download sometimes refuses to start: it is much easier to download
  from the terminal, it works right away (~840 MB):

  ```bash
  curl -L -o virtio-win.iso "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso"
  ```

  `launch.sh` automatically recognizes any `virtio-win*.iso` file
  (both `virtio-win.iso` and `virtio-win-0.1.302.iso`).

---

## 2. Creating the virtual machine

```bash
./launch.sh --create          # create a 100 GB win10.qcow2 (actual space used: ~0)
./launch.sh --create 150G     # or a different size
```

- The disk is a **dynamic qcow2**: it declares 100 GB but only occupies the space
  actually used (now ~35 GB for your existing installation).
- For a second disk/machine: `./launch.sh --create --disk win11.qcow2`.
- To grow an existing disk: `qemu-img resize win10.qcow2 150G`
  (inside Windows you then have to extend the unallocated space).

Nothing else is needed: the VM uses q35 + UEFI, while **RAM and vCPUs are detected
automatically** at startup based on the host (half the threads and about half
the RAM, limited to 1-8 vCPUs and 2G-16G): with `--smp`/`--mem` you can
force them (see §5, "All the options").

---

## 3. VM network (bridge + NAT + DHCP)

**In practice you don't need to think about it**: if the network is missing, `./launch.sh` runs
`./qemu-up.sh` by itself (it only asks for your sudo password in the terminal) and continues
booting. To disable this behavior: `./launch.sh --no-auto-net`.

The network still has to be configured **once after each reboot** of the physical machine:

```bash
./qemu-up.sh
```

The script does the following, asking for the sudo password:

1. it detects the uplink interface from the default route
   (e.g. `wlp3s0` on Wi-Fi, `enp0…` on cable) — you just need internet;
2. enables `net.ipv4.ip_forward=1`;
3. creates the `br0` bridge with address `192.168.100.1/24` and the `tap0`
   interface (owned by your user, so QEMU starts **without sudo**);
4. adds the iptables NAT rules for outbound traffic;
5. starts a dedicated `dnsmasq` that does **DHCP only** for the VM
   (range `192.168.100.10–200`, gateway `192.168.100.1`, DNS `8.8.8.8`).

To remove everything:

```bash
./qemu-down.sh
```

**Alternative without root/bridge** (useful when traveling or if you don't want to touch the
host network):

```bash
./launch.sh --net user
```

"slirp" network: the VM has internet, the host is reachable at address
`10.0.2.2`. The VM is **not** reachable from outside.

---

## 4. Installing Windows 10 or 11

### 4.1 Windows 10

```bash
./qemu-up.sh
./launch.sh --iso
```

It boots from the installation CD. During installation:

1. select the partition and let Windows create GPT/UEFI (if you find an
   old partition, `Delete` + `Next`);
2. the installation proceeds by itself (the disk is on AHCI, drivers already included
   in Windows);
3. if Windows asks for the product key: choose *"I don't have a product
   key"* (it activates later) or enter yours, writing it down in
   `seriale.txt` (a file excluded from the repository, see §0).

After the first boot:

1. inside Windows open the **virtio-win** CD drive and run
   `virtio-win-guest-tools.exe` (installs network drivers, ballooning,
   memory, etc.). *Alternative without downloading the ISO: copy
   `virtio-win-guest-tools.exe` (it's in the repository) into the
   `condivisa/` folder on the host and, after running `setup-virtiofs.bat`
   (§6.1), launch it inside Windows from the shared drive (Z:);*
2. disable **Fast Startup**:
   *Control Panel → Power Options → Choose what the power buttons
   do → Change settings that are currently available → Define what the
   power buttons do* → uncheck "Turn on fast startup";
3. install Windows updates.

> After installation you simply continue with `./launch.sh` (without
> `--iso`, which is only needed for installation). If you still need the
> drivers as a drive: `./launch.sh --drivers` attaches **only** the virtio-win
> ISO, booting from disk (for the VirtIO-FS share it's not needed: the drivers
> are already in `tools/`, inside the repository).

### 4.2 Windows 11

Windows 11 requires **TPM 2.0** (and UEFI firmware with "capable"
Secure Boot): that's what the `--tpm` and `--secureboot` flags are for.

```bash
./qemu-up.sh
./launch.sh --iso-file Win11_25H2_Italian_x64.iso --tpm --secureboot
```

- `--tpm` starts **swtpm** (virtual TPM 2.0) with persistent state in
  `swtpm/state/`: after the first setup Windows always sees it present.
  **It is required for installation**: without TPM setup stops at
  "This PC doesn't support Windows 11".
- `--secureboot` uses `OVMF/OVMF_CODE_4M.secboot.fd` with the template
  `OVMF_VARS_4M.ms.fd` which already contains the Microsoft keys
  (`Microsoft Windows Production PCA 2011`, `Microsoft Corporation UEFI CA 2011`)
  → Windows boots with Secure Boot **enabled**.
  *Note:* there is also a `.snakeoil` template (test keys): **do not
  use it**, it would block Windows Boot Manager.
- Afterwards, boot with `./launch.sh --tpm` (without `--iso-file`).
- If for some reason Windows doesn't boot with `--secureboot`, drop it:
  Win11 installs anyway with "capable" UEFI + TPM.

TPM startup and cleanup are automatic: when you close the VM,
`launch.sh` also terminates swtpm.

### 4.3 Virtio drivers during installation (optional)

By default the disk is on an AHCI controller and the network uses `virtio-net`:

- the disk works right away (Windows has the `storahci` driver);
- the **network** works only after installing the drivers (the
  `virtio-win-guest-tools.exe` step of §4.1), or by loading them manually during
  installation with *"Load driver → browse → virtio-win DVD → vioscsi/netkvm"*.

---

## 5. The launcher: `launch.sh`

Daily use:

```bash
./qemu-up.sh     # once after rebooting the physical machine (network)
./launch.sh      # start the VM
```

**Stopping the VM:** close the VM window, or:

```bash
socat - UNIX-CONNECT:"$PWD/win10-monitor.sock"     # then type "quit"
```

Don't run `sudo ./launch.sh`: the launcher starts and runs as a normal user
(and this is **mandatory** for audio, see the FAQ). The user only needs to be a
member of the `kvm` group (§1.2): the `tap0` interface is created by `qemu-up.sh`
owned by your user, so no sudo is needed to start the VM.

### All the options

| Option | Effect |
|---|---|
| `--create [SIZE]` | creates the qcow2 disk (default 100G) and exits |
| `--iso` | attaches the Windows + virtio-win ISOs and boots from CD (installation) |
| `--iso-file FILE` | like `--iso` but with a different Windows ISO (Win11) |
| `--drivers` | attaches only the virtio-win ISO, boots from disk (optional: the share setup doesn't need it) |
| `--tpm` | starts swtpm (TPM 2.0) — needed for Windows 11 |
| `--secureboot` | OVMF firmware with Secure Boot and Microsoft keys |
| `--net tap\|user` | bridge/NAT network (default) or rootless slirp |
| `--no-auto-net` | doesn't automatically run `qemu-up.sh` if the tap network is missing |
| `--disk FILE` | uses a different qcow2 disk |
| `--smp N` | VM vCPUs (default: auto — half the host's threads, 1-8) |
| `--mem SIZE` | VM RAM in MB or with a G suffix, e.g. `4096` or `6G` (default: auto — about half the host's RAM, 2G-16G) |
| `--share` | info on the VirtIO-FS share and the Windows driver |
| `--share-dir DIR` | host folder to share (default `./condivisa`) |
| `--no-share` | starts the VM without the VirtIO-FS share |
| `--check` | only checks KVM/display/disk/network and exits (no VM) |
| `--dry-run` | prints the qemu command without running it (useful for debugging) |
| `-h`, `--help` | help |

### What it does for you

- **KVM**: `accel=kvm` + `-cpu host` and the Hyper-V enlightenments
  (`hv_relaxed`, `hv_vapic`, `hv_spinlocks`, `hv_time`, ...) → Windows is
  smooth instead of stalling; without these flags the VM runs 3-5× slower.
- **UEFI**: pflash with `OVMF_CODE_4M.fd` + `OVMF_VARS_win10.fd` → boot entries
  and the TPM stay saved across reboots.
- **Network**: checks that `br0`/`tap0`/DHCP are ready and tells you exactly
  what to run if they aren't; with `--net user` nothing is needed.
- **Audio**: `-audiodev pipewire` connected to the user session.
- **Disk**: explicit `format=qcow2` and `discard=unmap` (Windows TRIM).
- **Protections**: if the VM is already running, it warns you instead of dying with
  *"Failed to get write lock"*; if `/dev/kvm` or the display is missing, a clear error.
- **USB**: a single `qemu-xhci` controller with keyboard/mouse/tablet.

---

## 6. Shared folder host ↔ VM (VirtIO-FS)

Sharing happens via **VirtIO-FS** (`virtiofsd`), no longer with Samba:
the daemon starts and stops together with the VM, with no network, port 445, users, or
passwords. The launcher enables it **by default**.

- host folder: `./condivisa` (created automatically if missing)
- guest tag: `condivisa`
- socket: `./virtiofsd.sock` (vhost-user, created and removed at every start)

To change it:

```bash
./launch.sh --share-dir "$HOME/Documenti"
./launch.sh --no-share                    # VM without sharing
./launch.sh --share                       # checks + instructions
```

### 6.1 Installation inside Windows (one-time, automated)

At startup the launcher prepares everything needed inside `tools/` (one time)
and builds the FAT image `tools.img` from it, mounted in Windows as a drive (usually
`E:`):

- `viofs/w10` and `viofs/w11`: the VirtIO FS drivers extracted from the virtio-win
  ISO (requires `7z` and the `virtio-win-*.iso` ISO in the VM folder);
- `winfsp-*.msi` (or `.setup.exe`): the WinFsp installer downloaded from GitHub
  (requires `curl`); if the download fails, you can still
  install it manually inside Windows over the network.

> The image is a real FAT disk (`mkfs.fat` + `mtools`, which
> `dosfstools`/`mtools` depend on): no QEMU `vvfat`, which in recent
> versions sometimes asserts `index < array->next` and kills the VM.
> It contains an **MBR with a FAT32 partition** (type `0x0C`, from 1 MiB to the end
> of the disk): Windows doesn't mount a FAT disk without a partition table ("super-
> floppy"), so the partition is mandatory — an old partitionless image is detected
> and regenerated automatically.
> `tools.img` is regenerated when the expected partition is missing or when
> something in `tools/` changes.

So inside Windows **you need neither mounted ISOs nor a network connection**.

1. **Inside Windows**: open the drive containing `setup-virtiofs.bat` (a virtual
   disk, e.g. `E:` — it's the one with the `.bat` file) and run it via
   *right-click → Run as administrator*. It does everything itself:
   - installs **WinFsp** from the installer on the drive (fallback:
     downloads it from GitHub if the VM has network);
   - installs the VirtIO FS driver from `viofs\w10\amd64` (or `w11`), also
     on the drive, with `pnputil /install` — as a fallback it looks for the virtio-win
     ISO mounted as a drive, so `./launch.sh --drivers` remains valid);
   - copies the `virtiofs.exe` client to `C:\Windows\VirtioFS`;
   - creates/updates and starts the **VirtioFsSvc** service.

2. **Result**: in *File Explorer* the `condivisa` share appears as a
   drive (by default `Z:`). Different letter, without editing the registry by hand:

   ```bat
   setup-virtiofs.bat X:
   ```

   (writes `HKLM\SOFTWARE\VirtIO-FS\MountPoint` and restarts the service).

If even the WinFsp installer is missing (host without network on first
boot) and the VM has no network, the script asks you to install it manually:
<https://github.com/winfsp/winfsp/releases>.

All in one go: `./launch.sh --share` prints these same steps.

### 6.2 Notes

- If the host folder already exists with "old" files, no problem: virtiofsd
  exposes it as it is (it just needs to be readable/writable by the user who runs
  the VM).
- Linux ACLs are not meaningful to Windows: the permissions inside the VM are
  those of the host user who runs `launch.sh`.
- Changes are **immediately visible** on both sides (same
  folder on disk), with no network refresh.
- To share multiple folders: add a second `-chardev`/`-device` with
  a different tag (one `virtiofsd` per folder), or expose a single
  parent folder.

---

## 7. Performance and tips

- **Already optimized in the launcher**: Hyper-V enlightenments, absence of
  `intel-iommu`/`kernel-irqchip=split` (which slowed down every interrupt),
  a single USB controller, `discard=unmap`.
- **Disk on an NVMe SSD**: `win10.qcow2` lives on an external USB disk
  (`r_await ~250 ms`): it's the biggest bottleneck. Copy the image to the
  internal NVMe and launch from there:

  ```bash
  cp --reflink=auto win10.qcow2 /mnt/storage/win10.qcow2
  ./launch.sh --disk /mnt/storage/win10.qcow2
  ```

  (or move the whole folder; always use `--disk` with the correct path).
- **RAM/CPU**: they are **auto** (half the threads and about half the host's
  RAM, limited to 1-8 vCPUs and 2G-16G): on a host with 8 threads/16 GB
  it starts with 4 vCPUs and 8 GB, on a dual-core with 8 GB it starts with 2 vCPUs and
  4 GB. To force them: `./launch.sh --smp 4 --mem 6G`.
- **Display**: `virtio-vga-gl` with `sdl,gl=on` uses the host GPU's real
  OpenGL; if 3D is slow in SDL, try replacing `-display sdl,gl=on` with
  `-display gtk,gl=on`.
- **Audio**: keep an active sink on the host session (otherwise PipeWire
  has nowhere to send the sound).

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ERROR: /dev/kvm not accessible` | user not in the group | `sudo usermod -aG kvm $USER` + re-login |
| `kvm-ok: command not found` | `kvm-ok` lives in `/usr/sbin`, which is not in `PATH` | run `sudo /usr/sbin/kvm-ok` (or `export PATH="$PATH:/usr/sbin"`) |
| `kvm-ok` says *CPU does not support KVM extensions* or */dev/kvm does not exist* | VT-x disabled in the BIOS, or module not loaded | enable **Intel Virtualization Technology** in the BIOS + **power off and on**, then `sudo modprobe kvm_intel` |
| `ERROR: the network is still not ready` | network not configured | `./qemu-up.sh` (or `--net user`) |
| VM has no internet | wrong NAT/interface | re-run `./qemu-up.sh` (the uplink is detected automatically), then `ip route` to check |
| `ERROR: ... is already in use by another QEMU instance` | VM still open | close the VM window; if none: `pgrep -a qemu-system-x86_64` |
| **No audio** | QEMU run with `sudo` (root can't see PipeWire) | start `./launch.sh` **without sudo**; check `pactl list short sinks` |
| `ERROR: no display available` | no graphical session | launch from a terminal in the desktop, or export `DISPLAY=:0` |
| Windows spinner spinning for a long time | slow disk / slow boot | wait the first time (disable Fast Startup), consider moving the qcow2 to NVMe (§7) |
| Win11: "this PC doesn't support Windows 11" | TPM missing | use `--tpm` |
| Win11 boots but complains about Secure Boot | firmware without MS keys | use `--secureboot` (`.ms` template) |
| VM doesn't see the share | WinFsp missing or service won't start | §6.1, then `sc.exe start VirtioFsSvc` |
| `ERROR: virtiofsd did not start` | package missing or folder not accessible | `sudo apt install virtiofsd`; check `ls -ld condivisa` |
| `VirtIO FS Device` device without driver | setup never run | inside Windows run `setup-virtiofs.bat` (§6.1) — the drivers are already on the `tools/` disk |
| WinFsp missing / service won't start | setup never run or installer missing | re-run `setup-virtiofs.bat` (uses `tools\winfsp*.msi`), otherwise install manually (§6.1) |
| VM dies with `block/vvfat.c ... Assertion` | `tools.img` not built: the `vvfat` fallback is used | `sudo apt install dosfstools mtools`, then `rm -f tools.img` and retry (§6.1) |
| Windows only sees `C:` (the setup disk doesn't appear) | old `tools.img` without a partition ("superfloppy", Windows won't mount it) | close the VM and re-run `./launch.sh`: the image is regenerated with an MBR partition (§6.1); if still nothing, check in *Disk Management* whether the disk shows as not initialized/RAW |
| Share visible but slow | slow host disk | same problem as the qcow2: move the folder to NVMe (§7) |
| `ERROR: swtpm did not start` | package missing or corrupted state | `sudo apt install swtpm swtpm-tools`; if it persists: `rm -rf swtpm/state && mkdir -p swtpm/state` |
| Boot starts from the CD instead of the disk | left `--iso` on | launch without `--iso`, or press ESC at the OVMF logo to choose the device |

**Debugging the qemu command:**

```bash
./launch.sh --dry-run          # see the full command line
./launch.sh --dry-run --tpm --secureboot --net user
```

**QEMU monitor (without opening other windows):**

```bash
socat - UNIX-CONNECT:"$PWD/win10-monitor.sock"
(QEMU) info status
(QEMU) screendump /tmp/schermo.ppm
(QEMU) quit
```

---

## 9. Notes on the other files

- `machine.sh` and `install.sh` are old scripts: `machine.sh` uses
  `-soundhw ac97`, removed in QEMU 9+, so it no longer works. Use
  `launch.sh` (§2, §4, §5).
- `install.sh` refers to a Fedora ISO that isn't in the folder.
- `ovmf/` contains the old monolithic `OVMF.fd` firmware (4 MB) and the
  snakeoil test keys: no longer needed (the launcher uses `OVMF/` in
  pflash mode), so it is **not in the repository**.
- `swtpm/` contains the sources of the swtpm that is already installed on the system
  (`/usr/bin/swtpm`): you can use them to recompile it, not required.
- `swtpm/state/` and `OVMF_VARS_win10*.fd` contain the VM state
  (TPM and NVRAM): they are not in the repository (they are recreated on first boot)
  and must **not be deleted** during use, otherwise Windows might not
  boot anymore (the boot manager would have to be redone).

---

## 10. License

Code and documentation are released under the [MIT](LICENSE) license:
you may use, modify, and redistribute them, even commercially,
provided that the copyright is retained. The redistributed third-party
components in the repository (UEFI firmware, VirtIO drivers, WinFsp
installer, swtpm sources) remain subject to their respective licenses:
see [THIRD_PARTY.md](THIRD_PARTY.md) for provenance and licenses.
The Windows ISOs and serial keys are **not part of the repository**
(Microsoft license): the links to download them are in §1.5.
