qemu-system-x86_64 \
-m 8192 \
-M q35 -enable-kvm \
-cpu host \
-smp 2 \
-cdrom Fedora-Workstation-Live-42-1.1.x86_64.iso \
-boot d \
-hda fedora.qcow2 \
#-bios ./ovmf/OVMF.fd \

