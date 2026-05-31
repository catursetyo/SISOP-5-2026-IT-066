#!/bin/bash
set -e

WORKDIR=$(pwd)

dd if=/dev/zero of=floppy.img bs=512 count=2880
echo "created floppy.img"

echo ""
nasm -f bin simple-bootloader.asm -o simple-bootloader.bin
echo "simple-bootloader.bin OK"

echo ""
nasm -f bin bootloader.asm -o bootloader.bin
echo "bootloader.bin OK"

echo ""
docker run --rm \
  -v "$WORKDIR":/build \
  -w /build \
  ubuntu:22.04 \
  bash -c "
    set -e

    apt-get update -qq
    apt-get install -y -qq nasm bcc bin86 binutils 2>/dev/null

    echo '[Docker] tools installed'

    nasm -f as86 kernel.asm -o kernel-asm.o

    bcc -ansi -c kernel.c -o kernel.o

    ld86 -0 -d \
    -o kernel.bin \
    kernel-asm.o \
    kernel.o

    echo '[Docker] kernel.bin OK'
  "

echo ""
ls -lh bootloader.bin kernel.bin floppy.img

echo ""
dd if=bootloader.bin of=floppy.img bs=512 count=1 conv=notrunc
dd if=kernel.bin of=floppy.img bs=512 seek=1 count=15 conv=notrunc
echo "floppy.img ready"

echo ""
echo "done"
