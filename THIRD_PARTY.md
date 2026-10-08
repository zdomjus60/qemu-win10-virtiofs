# Third-party components

This repository redistributes the following third-party software, each under
its original license:

| Component | Path | License | Upstream |
|---|---|---|---|
| OVMF UEFI firmware (4M build, incl. Secure Boot variants) | `OVMF/` | BSD-2-Clause (EDK2) and LGPL-2.1 portions; Debian packaging notice: `/usr/share/doc/ovmf/copyright` | <https://www.tianocore.org/>, Debian package `ovmf` |
| VirtIO-FS Windows drivers (`viofs`) and guest tools installer | `tools/viofs/`, `virtio-win-guest-tools.exe` | BSD-2-Clause | <https://github.com/virtio-win/virtio-win>, Fedora package `virtio-win` |
| WinFsp installer | `tools/winfsp-*.msi` | WinFsp License (permissive, BSD-style) | <https://winfsp.dev/> |
| swtpm sources | `swtpm/` | BSD-3-Clause (see `swtpm/LICENSE`) | <https://github.com/stefanberger/swtpm> |

**Not included** (obtain them yourself, see README):

- **Microsoft Windows installation ISO and product keys** — Microsoft license.
- **`virtio-win` ISO** — download link in README §1.5; the drivers needed by
  this setup are already in the repository under `tools/`.

Scripts and documentation of this project: [MIT](LICENSE).
