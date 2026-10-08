# VM Windows 10/11 con QEMU/KVM — istruzioni complete

Guida per creare, installare e usare la macchina virtuale Windows in questa
cartella, partendo da un sistema Debian (13 "trixie") appena installato.

---

## 0. Cosa c'è in questa cartella

| File / cartella | A cosa serve |
|---|---|
| `launch.sh` | **Il launcher**: avvia la VM (rete, UEFI, TPM, audio, ISO, share) |
| `qemu-up.sh` | Configura la rete della VM (bridge `br0`, `tap0`, NAT, DHCP) |
| `qemu-down.sh` | Rimuove la rete creata da `qemu-up.sh` |
| `win10.qcow2` | Il disco della VM (creato con `--create`) |
| `Win10_22H2_Italian_x64v1.iso` | ISO di installazione Windows 10 |
| `Win11_25H2_Italian_x64.iso` | ISO di installazione Windows 11 |
| `virtio-win-0.1.262.iso` | Driver paravirtualizzati (rete, storage, ...) per Windows |
| `virtio-win-guest-tools.exe` | Installer dei guest tools (si esegue dentro Windows) |
| `OVMF/` | Firmware UEFI 4M (CODE + VARS, varianti Secure Boot `.ms` e `.snakeoil`) |
| `ovmf/` | Vecchio firmware unico + chiavi snakeoil (legacy, non serve) |
| `swtpm/` | Sorgenti swtpm + `swtpm/state/` (stato del TPM 2.0 della VM) |
| `OVMF_VARS_win10.fd` | NVRAM della VM (creato al primo avvio, **non cancellare**) |
| `OVMF_VARS_win10.secboot.fd` | NVRAM usato con `--secureboot` |
| `condivisa/` | Cartella condivisa con Windows via VirtIO-FS (vedi §6) |
| `tools/` | Sorgenti del disco di setup: `setup-virtiofs.bat` + driver `viofs/` + installer WinFsp (preparati da solo da `launch.sh`) |
| `tools.img` | Immagine FAT con partizione MBR costruita da `launch.sh` con `tools/`: montata in Windows come unità di setup |
| `machine.sh`, `install.sh` | Script legacy (non usati da questa guida) |

> **Nota per chi clona il repository**: i file binari/dati (ISO Windows,
> disco `win10.qcow2`, firmware `OVMF/` e `ovmf/`, NVRAM `OVMF_VARS_*.fd`,
> `seriale.txt`, stato TPM, contenuti di `condivisa/`) **non sono nel repo**
> (vedi `.gitignore`: contengono dati personali, licenze o seriali). In un
> clone pulito ti servono almeno: un'ISO Windows, la `virtio-win-*.iso`
> (link in §1.2), il firmware dal pacchetto Debian `ovmf` e
> `./launch.sh --create` per il disco virtuale.

---

## 1. Installazione delle dipendenze (da zero)

### 1.1 Requisiti

- CPU con **VT-x** (Intel) o AMD-V attivato nel BIOS/UEFI del fisico.
  Per verificare da un live Linux: `grep -E 'vmx|svm' /proc/cpuinfo`
  (devono comparire i flag `vmx`/`svm`, insieme a `ept`), poi
  `ls /dev/kvm` deve esistire. Ce l'hanno anche molti Celeron dal 2011
  in poi (es. Ivy Bridge): nel BIOS cerca "Intel Virtualization
  Technology" e assicurati che sia attivo.
- ~40 GB liberi per il disco della VM (100 GB consigliati, il disco è dinamico).
- Un desktop con audio (PipeWire) per finestra e suono.

### 1.2 Utente e KVM

```bash
ls -l /dev/kvm                     # deve esistere: crw-rw---- root kvm
groups | tr ' ' '\n' | grep kvm     # deve comparire "kvm"
sudo usermod -aG kvm "$USER"       # se non c'è: aggiungiti al gruppo
# poi ESCI dal sessione e rientra (o riavvia)
```

Se manca il modulo (raro):

```bash
sudo apt install --reinstall linux-image-$(uname -r)
```

### 1.3 Pacchetti necessari

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

`virtiofsd` è il demone che espone la cartella condivisa alla VM via
**VirtIO-FS** (sostituisce Samba: nessun servizio da avviare, nessuna porta di
rete, nessuna password).

`dosfstools` + `mtools` servono a `launch.sh` per costruire `tools.img`
(l'immagine FAT col disco di setup, vedi §6.1). Senza, si ricade sul modulo
`vvfat` di QEMU, che va a volte in assertion e uccide la VM.

Pacchetti **opzionali** ma utili:

```bash
sudo apt install -y curl 7zip      # preparano da soli driver e WinFsp in tools/
sudo apt install -y socat        # per parlare con il monitor di QEMU
sudo apt install -y cpu-checker  # fornisce il comando "kvm-ok"
sudo apt install -y libguestfs-tools  # per ispezionare il disco senza avviare la VM
```

L'audio usa PipeWire, presente di default su Debian 13; se manca:

```bash
sudo apt install -y pipewire-audio pipewire-pulse wireplumber
```

### 1.4 Verifica rapida

```bash
qemu-system-x86_64 --version      # es. 10.0.x
kvm-ok                            # se hai installato cpu-checker
./launch.sh --dry-run             # stampa il comando qemu che verrebbe eseguito
```

Le ISO Windows e `virtio-win-0.1.262.iso` sono già nella cartella (ma non
fanno parte del repository: vedi §0). Se vuoi
scaricare l'ultima versione dei driver VirtIO:

```text
https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
```

---

## 2. Creazione della macchina virtuale

```bash
./launch.sh --create          # crea win10.qcow2 da 100 GB (spazio usato reale: ~0)
./launch.sh --create 150G     # oppure una dimensione diversa
```

- Il disco è **qcow2 dinamico**: dichiara 100 GB ma occupa lo spazio realmente
  usato (ora ~35 GB per la tua installazione esistente).
- Per un secondo disco/macchina: `./launch.sh --create --disk win11.qcow2`.
- Per ingrandire un disco esistente: `qemu-img resize win10.qcow2 150G`
  (dentro Windows poi va esteso lo spazio non allocato).

Non serve altro: la VM usa q35 + UEFI, mentre **RAM e vCPU vengono rilevate
automaticamente** all'avvio in base all'host (metà dei thread e circa metà
della RAM, con vincoli 1-8 vCPU e 2G-16G): con `--smp`/`--mem` le puoi
forzare (vedi §5, "Tutte le opzioni").

---

## 3. Rete della VM (bridge + NAT + DHCP)

**In pratica non devi pensarci**: se la rete manca, `./launch.sh` lancia da
solo `./qemu-up.sh` (ti chiede solo la password sudo al terminale) e prosegue
con l'avvio. Per disabilitare questo comportamento: `./launch.sh --no-auto-net`.

La rete resta comunque configurata **una volta dopo ogni riavvio** del fisico:

```bash
./qemu-up.sh
```

Lo script fa, chiedendo la password sudo:

1. rileva da solo l'interfaccia di uplink dalla route default
   (es. `wlp3s0` su Wi-Fi, `enp0…` su cavo) — basta che tu abbia internet;
2. abilita `net.ipv4.ip_forward=1`;
3. crea il bridge `br0` con indirizzo `192.168.100.1/24` e l'interfaccia
   `tap0` (proprietaria: il tuo utente, così QEMU parte **senza sudo**);
4. aggiunge le regole iptables di NAT verso l'esterno;
5. avvia un `dnsmasq` dedicato che fa **solo DHCP** per la VM
   (range `192.168.100.10–200`, gateway `192.168.100.1`, DNS `8.8.8.8`).

Per rimuovere tutto:

```bash
./qemu-down.sh
```

**Alternativa senza root/bridge** (utile in viaggio o se non vuoi toccare la
rete dell'host):

```bash
./launch.sh --net user
```

Rete "slirp": la VM ha internet, l'host è raggiungibile all'indirizzo
`10.0.2.2`. La VM **non** è raggiungibile dall'esterno.

---

## 4. Installazione di Windows 10 o 11

### 4.1 Windows 10

```bash
./qemu-up.sh
./launch.sh --iso
```

Si avvia dal CD di installazione. Durante l'installazione:

1. seleziona la partizione e lascia che Windows crei GPT/UEFI (se trovi una
   vecchia partizione, `Cancella` + `Avanti`);
2. l'installazione va avanti da sola (il disco è su AHCI, driver già inclusi
   in Windows).

Dopo il primo avvio:

1. dentro Windows apri il drive del CD **virtio-win** ed esegui
   `virtio-win-guest-tools.exe` (installa driver di rete, ballooning,
   memoria, ecc.);
2. disattiva il **Fast Startup**:
   *Pannello di controllo → Opzioni risparmio energetico → Scelta azione
   alimentazione → Modifica impostazioni attuali → Seleziona quello che deve
   eseguire l'interruttore di spegnimento* → rimuovi la spunta su
   "Attiva avvio rapido";
3. installa le aggiornamenti di Windows.

> Dopo l'installazione si riprende normalmente con `./launch.sh` (senza
> `--iso`, che serve solo per l'installazione). Se ti servono comunque i
> driver come unità: `./launch.sh --drivers` aggancia **solo** la ISO virtio-win
> facendo boot dal disco (per la condivisione VirtIO-FS non serve: i driver
> vengono estratti automaticamente in `tools/`).

### 4.2 Windows 11

Windows 11 richiede **TPM 2.0** (e firmware UEFI con Secure Boot
"capacitativo"): per quello esistono i flag `--tpm` e `--secureboot`.

```bash
./qemu-up.sh
./launch.sh --iso-file Win11_25H2_Italian_x64.iso --tpm --secureboot
```

- `--tpm` avvia **swtpm** (TPM 2.0 virtuale) con stato persistente in
  `swtpm/state/`: dopo la prima configurazione Windows lo vede sempre presente.
  **È necessario per l'installazione**: senza TPM il setup si ferma su
  "Questo PC non supporta Windows 11".
- `--secureboot` usa `OVMF/OVMF_CODE_4M.secboot.fd` con il template
  `OVMF_VARS_4M.ms.fd` che contiene già le chiavi Microsoft
  (`Microsoft Windows Production PCA 2011`, `Microsoft Corporation UEFI CA 2011`)
  → Windows parte con Secure Boot **attivo**.
  *Nota:* esiste anche un template `.snakeoil` (chiavi di prova): **non
  usarlo**, blocherebbe Windows Boot Manager.
- In seguito avvii con `./launch.sh --tpm` (senza `--iso-file`).
- Se per qualche motivo Windows non parte con `--secureboot`, toglilo:
  Win11 si installa comunque con UEFI "capacitativo" + TPM.

L'avvio del TPM e la pulizia avvengono in automatico: quando chiudi la VM,
`launch.sh` termina anche swtpm.

### 4.3 Driver virtio durante l'installazione (facoltativo)

Di default il disco è su controller AHCI e la rete usa `virtio-net`:

- il disco funziona subito (Windows ha il driver `storahci`);
- la **rete** funziona solo dopo aver installato i driver (passaggio
  `virtio-win-guest-tools.exe` del §4.1), oppure caricandoli a mano durante
  l'installazione con *"Carica driver → sfoglia → DVD virtio-win → vioscsi/netkvm"*.

---

## 5. Il launcher: `launch.sh`

Uso quotidiano:

```bash
./qemu-up.sh     # una volta dopo il riavvio del fisico (rete)
./launch.sh      # avvia la VM
```

**Fermare la VM:** chiudi la finestra della VM, oppure:

```bash
socat - UNIX-CONNECT:"$PWD/win10-monitor.sock"     # poi scrivi "quit"
```

Non usare `sudo ./launch.sh`: il launcher parte e gira come utente normale
(ed è **obbligatorio** per l'audio, vedi FAQ). L'utente deve solo far parte
del gruppo `kvm` (§1.2): l'interfaccia `tap0` viene creata da `qemu-up.sh`
proprietaria del tuo utente, quindi non serve sudo per avviare la VM.

### Tutte le opzioni

| Opzione | Effetto |
|---|---|
| `--create [DIM]` | crea il disco qcow2 (default 100G) ed esce |
| `--iso` | aggancia ISO Windows + virtio-win e avvia dal CD (installazione) |
| `--iso-file FILE` | come `--iso` ma con un'altra ISO Windows (Win11) |
| `--drivers` | aggancia solo la ISO virtio-win, boot dal disco (opzionale: il setup della condivisione non ne ha bisogno) |
| `--tpm` | avvia swtpm (TPM 2.0) — serve per Windows 11 |
| `--secureboot` | firmware OVMF con Secure Boot e chiavi Microsoft |
| `--net tap\|user` | rete bridge/NAT (default) oppure slirp senza root |
| `--no-auto-net` | non lancia automaticamente `qemu-up.sh` se la rete tap manca |
| `--disk FILE` | usa un altro disco qcow2 |
| `--smp N` | vCPU della VM (default: auto — metà dei thread dell'host, 1-8) |
| `--mem SIZE` | RAM della VM in MB o con suffisso G, es. `4096` oppure `6G` (default: auto — circa metà della RAM dell'host, 2G-16G) |
| `--share` | info sulla condivisione VirtIO-FS e sul driver Windows |
| `--share-dir DIR` | cartella host da condividere (default `./condivisa`) |
| `--no-share` | avvia la VM senza la condivisione VirtIO-FS |
| `--check` | controlla solo KVM/display/disco/rete e termina (niente VM) |
| `--dry-run` | stampa il comando qemu senza eseguirlo (utile per debug) |
| `-h`, `--help` | aiuto |

### Cosa fa al posto tuo

- **KVM**: `accel=kvm` + `-cpu host` e gli enlightenments Hyper-V
  (`hv_relaxed`, `hv_vapic`, `hv_spinlocks`, `hv_time`, ...) → Windows è
  fluido invece di arenarsi; senza questi flag la VM va 3-5× più lento.
- **UEFI**: pflash con `OVMF_CODE_4M.fd` + `OVMF_VARS_win10.fd` → le voci di
  boot e il TPM restano salvati tra un riavvio e l'altro.
- **Rete**: controlla che `br0`/`tap0`/DHCP siano pronti e ti dice esattamente
  cosa lanciare se non lo sono; con `--net user` non serve nulla.
- **Audio**: `-audiodev pipewire` collegato alla sessione utente.
- **Disco**: `format=qcow2` esplicito e `discard=unmap` (TRIM di Windows).
- **Protezioni**: se la VM è già in giro, ti avvisa invece di morire con
  *"Failed to get write lock"*; se manca `/dev/kvm` o il display, errore chiaro.
- **USB**: un solo controller `qemu-xhci` con tastiera/mouse/tablet.

---

## 6. Cartella condivisa host ↔ VM (VirtIO-FS)

La condivisione avviene via **VirtIO-FS** (`virtiofsd`), non più con Samba:
il demone parte e si spegne insieme alla VM, senza rete, porta 445, utenti né
password. Il launcher la abilita **di default**.

- cartella host: `./condivisa` (si crea da sola se manca)
- tag guest: `condivisa`
- socket: `./virtiofsd.sock` (vhost-user, creato e rimosso ad ogni avvio)

Cambiarla:

```bash
./launch.sh --share-dir "$HOME/Documenti"
./launch.sh --no-share                    # VM senza condivisione
./launch.sh --share                       # verifica + istruzioni
```

### 6.1 Installazione dentro Windows (una tantum, automatizzata)

All'avvio il launcher prepara dentro `tools/` tutto ciò che serve (una tantum)
e ne fa l'immagine FAT `tools.img`, montata in Windows come unità (di solito
`E:`):

- `viofs/w10` e `viofs/w11`: i driver VirtIO FS estratti dalla ISO virtio-win
  (servono `7z` e la ISO `virtio-win-*.iso` nella cartella della VM);
- `winfsp-*.msi` (o `.setup.exe`): l'installer di WinFsp scaricato da GitHub
  (serve `curl`); se il download non riesce, dentro Windows si può comunque
  installarlo a mano passando per la rete.

> L'immagine è un disco FAT vero e proprio (`mkfs.fat` + `mtools`, da cui
> dipendono `dosfstools`/`mtools`): niente `vvfat` di QEMU, che in versioni
> recenti va a volte in assertion `index < array->next` e fa morire la VM.
> Contiene un **MBR con una partizione FAT32** (tipo `0x0C`, da 1 MiB a fine
> disco): Windows non monta un disco FAT senza tabella partizioni («super-
> floppy»), quindi la partizione è obbligatoria — un'immagine vecchia senza
> partizione viene rilevata e rigenerata da sola.
> `tools.img` viene rigenerata quando manca la partizione attesa o quando
> qualcosa in `tools/` cambia.

Dentro Windows quindi **non servono né ISO montate né connessione**.

1. **Dentro Windows**: apri l'unità che contiene `setup-virtiofs.bat` (un disco
   virtuale, es. `E:` — è quello col file `.bat`) ed eseguilo con
   *destro → Esegui come amministratore*. Fa da solo:
   - installa **WinFsp** dall'installer presente nell'unità (in fallback:
     lo scarica da GitHub se la VM ha rete);
   - installa il driver VirtIO FS da `viofs\w10\amd64` (o `w11`) sempre
     sull'unità, con `pnputil /install` — in fallback cerca la ISO virtio-win
     montata come unità, quindi `./launch.sh --drivers` resta valido);
   - copia il client `virtiofs.exe` in `C:\Windows\VirtioFS`;
   - crea/aggiorna e avvia il servizio **VirtioFsSvc**.

2. **Risultato**: in *Esplora file* la condivisione `condivisa` appare come
   unità (di default `Z:`). Lettera diversa, senza editare il registro a mano:

   ```bat
   setup-virtiofs.bat X:
   ```

   (scrive `HKLM\SOFTWARE\VirtIO-FS\MountPoint` e riavvia il servizio).

Se anche l'installer di WinFsp fosse mancante (host senza rete al primo
avvio) e la VM è senza rete, lo script ti chiede di installarlo a mano:
<https://github.com/winfsp/winfsp/releases>.

Tutto in un colpo: `./launch.sh --share` stampa questi stessi passaggi.

### 6.2 Note

- Se la cartella host esiste già con file "vecchi", nessun problema: virtiofsd
  la espone così com'è (solo serve leggibile/scrivibile dall'utente che lancia
  la VM).
- Le ACL/Linux non sono meaningful per Windows: i permessi dentro la VM sono
  quelli dell'utente host che lancia `launch.sh`.
- Le modifiche sono **immediatamente visibili** in entrambe le parti (stessa
  cartella sul disco), senza refresh della rete.
- Per condividere più cartelle: aggiungi un secondo `-chardev`/`-device` con
  tag diverso (serve un `virtiofsd` per cartella), oppure esponi un'unica
  cartella padre.

---

## 7. Prestazioni e consigli

- **Già ottimizzato nel launcher**: enlightenments Hyper-V, assenza di
  `intel-iommu`/`kernel-irqchip=split` (che appesantivano ogni interrupt),
  un solo controller USB, `discard=unmap`.
- **Disco su SSD NVMe**: `win10.qcow2` vive su un disco USB esterno
  (`r_await ~250 ms`): è il collo di bottiglia più grosso. Copia l'immagine
  sull'NVMe interno e lancia da lì:

  ```bash
  cp --reflink=auto win10.qcow2 /mnt/storage/win10.qcow2
  ./launch.sh --disk /mnt/storage/win10.qcow2
  ```

  (oppure sposta l'intera cartella; usa sempre `--disk` percorso-giusto).
- **RAM/CPU**: sono **auto** (metà dei thread e circa metà della RAM
  dell'host, vincolate 1-8 vCPU e 2G-16G): su un host con 8 thread/16 GB
  parte con 4 vCPU e 8 GB, su un dual-core con 8 GB parte con 2 vCPU e
  4 GB. Per forzarle: `./launch.sh --smp 4 --mem 6G`.
- **Schermo**: `virtio-vga-gl` con `sdl,gl=on` usa l'OpenGL reale della GPU
  host; se il 3D è lento in SDL, prova a sostituire `-display sdl,gl=on` con
  `-display gtk,gl=on`.
- **Audio**: tieni un sink attivo sulla sessione host (altrimenti PipeWire
  non ha dove mandare il suono).

---

## 8. Risoluzione problemi

| Sintomo | Causa | Rimedio |
|---|---|---|
| `ERRORE: /dev/kvm non accessibile` | utente fuori dal gruppo | `sudo usermod -aG kvm $USER` + re-login |
| `Rete non pronta: ...` | rete non configurata | `./qemu-up.sh` (oppure `--net user`) |
| VM senza internet | NAT/interfaccia sbagliata | ri-esegui `./qemu-up.sh` (l'uplink viene rilevato automaticamente), poi `ip route` per verificare |
| `ERRORE: ... e' gia' in uso da un'altra istanza QEMU` | VM ancora aperta | chiudi la finestra VM; se non c'è: `pgrep -a qemu-system-x86_64` |
| **Nessun audio** | QEMU girato con `sudo` (root non vede PipeWire) | avvia `./launch.sh` **senza sudo**; controlla `pactl list short sinks` |
| `ERRORE: nessun display` | sessione grafica assente | lancia da un terminale nel desktop, o esporta `DISPLAY=:0` |
| Rotella di Windows che gira a lungo | disco lento / boot lento | aspetta la prima volta (disattiva Fast Startup), valuta di spostare il qcow2 su NVMe (§7) |
| Win11: "questo PC non supporta Windows 11" | manca TPM | usa `--tpm` |
| Win11 parte ma si lamenta di Secure Boot | firmware senza chiavi MS | usa `--secureboot` (template `.ms`) |
| La VM non vede la condivisione | manca WinFsp o il servizio non parte | §6.1, poi `sc.exe start VirtioFsSvc` |
| `virtiofsd non e' partito` | pacchetto assente o cartella non accessibile | `sudo apt install virtiofsd`; verifica `ls -ld condivisa` |
| Dispositivo `VirtIO FS Device` senza driver | setup mai eseguito | dentro Windows esegui `setup-virtiofs.bat` (§6.1) — i driver sono già nel disco `tools/` |
| WinFsp mancante / servizio non parte | setup mai eseguito o installer mancante | rilancia `setup-virtiofs.bat` (usa `tools\winfsp*.msi`), altrimenti installa a mano (§6.1) |
| VM muore con `block/vvfat.c ... Assertion` | `tools.img` non costruita: si usa il fallback `vvfat` | `sudo apt install dosfstools mtools`, poi `rm -f tools.img` e riprova (§6.1) |
| Windows vede solo `C:` (il disco di setup non compare) | `tools.img` vecchia senza partizione («superfloppy», Windows non la monta) | chiudi la VM e rilancia `./launch.sh`: l'immagine viene rigenerata con partizione MBR (§6.1); se ancora niente, guarda in *Gestione disco* se il disco risulta non inizializzato/RAW |
| Condivisione visibile ma lenta | disco host lento | stesso problema del qcow2: sposta la cartella su NVMe (§7) |
| `swtpm non e' partito` | pacchetto mancante o stato corrotto | `sudo apt install swtpm swtpm-tools`; se persiste: `rm -rf swtpm/state && mkdir -p swtpm/state` |
| Boot che parte dal CD invece che dal disco | lasciato `--iso` | lancia senza `--iso`, o premi ESC al logo OVMF per scegliere il dispositivo |

**Debug del comando qemu:**

```bash
./launch.sh --dry-run          # vedi la riga di comando completa
./launch.sh --dry-run --tpm --secureboot --net user
```

**Monitor QEMU (senza aprire altre finestre):**

```bash
socat - UNIX-CONNECT:"$PWD/win10-monitor.sock"
(QEMU) info status
(QEMU) screendump /tmp/schermo.ppm
(QEMU) quit
```

---

## 9. Note sugli altri file

- `machine.sh` e `install.sh` sono script vecchi: `machine.sh` usa
  `-soundhw ac97`, rimosso da QEMU 9+, quindi non funziona più. Usa
  `launch.sh` (§2, §4, §5).
- `install.sh` si riferisce a un'ISO Fedora che non c'è nella cartella.
- `ovmf/` contiene il vecchio firmware monoblocco `OVMF.fd` (4 MB): non serve
  più, il launcher usa `OVMF/` in modalità pflash.
- `swtpm/` contiene i sorgenti dello swtpm che è già installato nel sistema
  (`/usr/bin/swtpm`): puoi usarli per ricompilarlo, non è necessario.
- `swtpm/state/` e `OVMF_VARS_win10*.fd` contengono lo stato della VM
  (TPM e NVRAM): **non cancellarli**, altrimenti Windows potrebbe non
  avviarsi più (va poi rifatta la registrazione dell'arrancatore di boot).
