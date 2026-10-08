#!/bin/bash
if [ "$#" -ne 2 ]; then
	echo "inserire create <nome> install <nome> o start <nome>"
	exit 1
elif [ "$1" == 'create' ] ; then
	qemu-img create -f qcow2 $2.qcow2 100G
elif [ "$1" == 'install' ] ; then
	echo "inserisci il nome della iso completo di path" 
	read path
	echo $path
	qemu-system-x86_64 -cpu host \
	-accel kvm -cdrom $path -hda $2.qcow2 -m 16384
elif [ "$1" == 'start' ]; then
	qemu-system-x86_64 -cpu host \
	-accel kvm -smp cpus=4 \
	-vga std -hda $2.qcow2 -soundhw ac97 -m 16384
else
 	echo "inserire comando e nome della macchina"
fi
