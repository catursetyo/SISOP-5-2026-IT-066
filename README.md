# Laporan Praktikum Modul 5 Sistem Operasi

**Nama:** Catur Setyo Ragil\
**NRP:** 5027251066\
**Kelas:** Sistem Operasi B\
**Kode Asisten:** SCRA

---

## Struktur Repository

```text
.
|-- AGENTS.md
|-- AGENTS2.md
|-- CONTEXT.md
|-- CONTEXT2.md
|-- README.md
|-- soal_1/
|   |-- .config
|   |-- backup.sh
|   |-- iso.sh
|   |-- kernel.sh
|   |-- multi.sh
|   |-- osboot/
|   |   |-- bzImage
|   |   |-- single.gz
|   |   |-- multi.gz
|   |   |-- farewell.iso
|   |   `-- farewell_backup_[DDMMYYYY-HHMMSS].zip
|   |-- qemu.sh
|   `-- single.sh
`-- soal_2/
    |-- Makefile
    |-- README.md
    |-- bochsrc.txt
    |-- bootloader.asm
    |-- build.sh
    |-- kernel.asm
    `-- kernel.c
```

---

## Pembahasan Soal

## Soal 1: FAREWELL PARTY

Pada soal nomor 1, diminta untuk membuat alur boot sistem operasi Linux kecil menggunakan kernel Linux `6.1.1`, BusyBox sebagai userspace, initramfs single-user dan multi-user, ISO bootable, helper QEMU, backup output, internet access, package manager bernama `party`, serta program FUSE sederhana.

Seluruh script utama Soal 1 berada di [soal_1](soal_1), dengan pembagian tugas:

- [kernel.sh](soal_1/kernel.sh): download dan build kernel Linux `6.1.1`.
- [single.sh](soal_1/single.sh): membuat initramfs single-user.
- [multi.sh](soal_1/multi.sh): membuat initramfs multi-user.
- [iso.sh](soal_1/iso.sh): membuat ISO bootable.
- [qemu.sh](soal_1/qemu.sh): menjalankan OS melalui QEMU.
- [backup.sh](soal_1/backup.sh): membuat arsip backup hasil akhir.

### Dependency Host

Project dikerjakan pada Fedora Linux. Dependency utama yang dibutuhkan dapat dipasang dengan:

```bash
sudo dnf install -y \
  gcc gcc-c++ make bc bison flex openssl-devel elfutils-libelf-devel \
  curl wget cpio gzip zip xorriso syslinux syslinux-extlinux \
  qemu-system-x86 qemu-img pkgconf-pkg-config file ncurses-devel \
  perl dwarves findutils tar xz
```

Untuk fitur FUSE, dependency tambahannya:

```bash
sudo dnf install -y fuse3 fuse3-devel meson ninja-build cmake musl-gcc
```

### Build Kernel

Script [kernel.sh](soal_1/kernel.sh) menggunakan Linux kernel versi `6.1.1`. Kernel source akan didownload jika belum tersedia, lalu hash tarball diverifikasi agar file yang dipakai sesuai.

```bash
KERNEL_VERSION="6.1.1"
KERNEL_SHA256="a3e61377cf4435a9e2966b409a37a1056f6aaa59e561add9125a88e3c0971dfb"
KERNEL_ARCHIVE="$BUILD_DIR/linux-$KERNEL_VERSION.tar.xz"
LINUX_DIR="$BUILD_DIR/linux-$KERNEL_VERSION"
```

File konfigurasi kernel yang dipakai adalah [soal_1/.config](soal_1/.config). Jika file tersebut ada, script langsung menyalinnya ke source kernel.

```bash
if [ -f "$ROOT/.config" ]; then
  echo "[INFO] Using tracked kernel config: $ROOT/.config"
  cp "$ROOT/.config" .config
else
  echo "[INFO] No tracked .config found; creating defconfig baseline..."
  make defconfig
fi
```

Kernel dikonfigurasi agar mendukung initramfs, filesystem dasar, serial console, networking QEMU, dan FUSE.

```bash
./scripts/config --enable BLK_DEV_INITRD
./scripts/config --enable DEVTMPFS
./scripts/config --enable DEVTMPFS_MOUNT
./scripts/config --enable PROC_FS
./scripts/config --enable SYSFS
./scripts/config --enable TMPFS
./scripts/config --enable BINFMT_ELF
./scripts/config --enable SERIAL_8250
./scripts/config --enable SERIAL_8250_CONSOLE
./scripts/config --enable NET
./scripts/config --enable INET
./scripts/config --enable PACKET
./scripts/config --enable UNIX
./scripts/config --enable E1000
./scripts/config --enable FUSE_FS
```

Driver dibuat built-in, bukan modul, supaya initramfs tidak perlu membawa file module tambahan. Selain itu, beberapa konfigurasi certificate/keyring dinonaktifkan untuk menghindari error build OpenSSL pada Fedora modern.

Build kernel dilakukan dengan:

```bash
make CC="gcc -std=gnu11" HOSTCC="gcc -std=gnu11" -j"$(nproc)" bzImage
cp arch/x86/boot/bzImage "$OUT_DIR/bzImage"
```

Hasil akhirnya adalah:

```text
soal_1/osboot/bzImage
```

### Single-user Initramfs

Script [single.sh](soal_1/single.sh) membuat root filesystem single-user dengan BusyBox static. BusyBox versi yang digunakan adalah `1.36.1`.

```bash
BUSYBOX_VERSION="1.36.1"
BUSYBOX_ARCHIVE="$BUILD_DIR/busybox-$BUSYBOX_VERSION.tar.bz2"
BUSYBOX_DIR="$BUILD_DIR/busybox-$BUSYBOX_VERSION"
BUSYBOX_BIN="$BUSYBOX_DIR/busybox"
```

Root filesystem dibuat ulang setiap script dijalankan, sehingga script bersifat rerunnable.

```bash
rm -rf "$ROOTFS_DIR"
mkdir -p \
  "$ROOTFS_DIR/bin" \
  "$ROOTFS_DIR/dev" \
  "$ROOTFS_DIR/proc" \
  "$ROOTFS_DIR/sys" \
  "$ROOTFS_DIR/etc" \
  "$ROOTFS_DIR/tmp" \
  "$ROOTFS_DIR/root" \
  "$ROOTFS_DIR/var/lib/party/repo" \
  "$ROOTFS_DIR/var/lib/party/installed"
```

Permission penting pada single-user filesystem:

```bash
chmod 1777 "$ROOTFS_DIR/tmp"
chmod 0700 "$ROOTFS_DIR/root"
```

BusyBox disalin ke `/bin/busybox`, lalu seluruh applet BusyBox dibuat sebagai symlink.

```bash
cp "$BUSYBOX_BIN" "$ROOTFS_DIR/bin/busybox"
"$BUSYBOX_BIN" --list | while read -r applet; do
  [ "$applet" = "busybox" ] && continue
  ln -sf busybox "$ROOTFS_DIR/bin/$applet"
done
```

User yang tersedia pada single-user filesystem hanya `root`.

```text
root:x:0:0:root:/root:/bin/sh
```

File `/init` bertugas sebagai proses pertama. Di dalamnya dilakukan mount pseudo-filesystem, pembuatan device node, setup networking, tampilan banner, dan shell root.

```sh
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t tmpfs -o mode=1777 tmpfs /tmp 2>/dev/null || chmod 1777 /tmp

[ -c /dev/fuse ] || mknod -m 666 /dev/fuse c 10 229 2>/dev/null || true

ifconfig lo up 2>/dev/null || true
ifconfig eth0 up 2>/dev/null || true
udhcpc -i eth0 -q -n -s /etc/udhcpc.script >/dev/null 2>&1 || true
```

Setelah boot, OS menampilkan ASCII art Farewell Party dan pesan:

```text
Welcome, root.
```

Agar tidak kernel panic ketika user mengetik `exit`, shell tidak dijalankan dengan `exec` sebagai PID 1. Setelah shell keluar, script menjalankan `poweroff -f`.

Rootfs dikemas menjadi initramfs `newc` yang dikompresi gzip:

```bash
find . -print0 \
  | sort -z \
  | cpio --null --reproducible --renumber-inodes -ov --format=newc --owner=0:0 \
  | gzip -n -9
```

Output akhir:

```text
soal_1/osboot/single.gz
```

### Multi-user Initramfs

Script [multi.sh](soal_1/multi.sh) membuat root filesystem multi-user. Pengguna yang dibuat adalah:

```text
root / root123
henn / henn123
hann / hann123
viii / viii123
kids / kids123
```

Data user ditulis pada `/etc/passwd`:

```text
root:x:0:0:root:/root:/bin/sh
henn:x:1001:1001:henn:/home/henn:/bin/sh
hann:x:1002:1002:hann:/home/hann:/bin/sh
viii:x:1003:1003:viii:/home/viii:/bin/sh
kids:x:1004:1004:kids:/home/kids:/bin/sh
```

Permission antar user diatur melalui owner, group, dan mode directory. Karena GNU `cpio --owner=0:0` tidak cukup untuk banyak UID/GID, [multi.sh](soal_1/multi.sh) memakai helper `gen_init_cpio` dari source kernel.

```bash
echo "dir /root 0700 0 0"
echo "dir /home 0755 0 0"
echo "dir /home/henn 0700 1001 1001"
echo "dir /home/hann 0770 1002 2001"
echo "dir /home/viii 0770 1003 2002"
echo "dir /home/kids 0770 1004 2003"
echo "dir /tmp 1777 0 0"
```

Group tambahan dibuat untuk memenuhi rule akses bertingkat:

```text
g_hann:x:2001:henn,hann
g_viii:x:2002:henn,hann,viii
g_kids:x:2003:henn,hann,viii,kids
```

Dengan model tersebut:

- `henn` dapat mengakses semua `/home/*`, tetapi tidak dapat mengakses `/root`.
- `hann` dapat mengakses `/home/hann`, `/home/viii`, dan `/home/kids`.
- `viii` dapat mengakses `/home/viii` dan `/home/kids`.
- `kids` hanya dapat mengakses `/home/kids`.
- Semua user tetap dapat menggunakan `/tmp`.

Login multi-user menggunakan script `/bin/login_prompt` yang menampilkan prompt `User: `, lalu menjalankan BusyBox `login`.

```sh
while true; do
  printf "User: "
  IFS= read -r user || exit 0
  [ -n "$user" ] || continue
  export LOGIN_TIMEOUT=0
  exec login "$user"
done
```

Pada `/etc/profile`, banner Farewell Party ditampilkan setelah autentikasi berhasil dan pesan disesuaikan dengan user login.

```sh
USER="$(id -un 2>/dev/null || whoami 2>/dev/null || echo user)"
export USER
echo "Welcome, $USER."
```

Untuk ganti user, dibuat fungsi `logout` yang keluar dengan status `77`. Status tersebut ditangkap oleh `/init` agar kembali ke prompt `User: `.

```sh
logout() {
  exit 77
}
```

Output akhir:

```text
soal_1/osboot/multi.gz
```

### Package Manager `party`

Pada single-user dan multi-user filesystem terdapat package manager bernama `party`. Package manager ini berupa shell script POSIX yang berada di `/bin/party`.

Interface minimal yang tersedia:

```text
party list
party installed
party install <package>
party remove <package>
```

Repository default menggunakan path lokal:

```sh
DB_DIR=/var/lib/party
REPO="${PARTY_REPO:-file:///var/lib/party/repo}"
```

Jika repository berupa HTTP atau HTTPS, package diambil dengan `wget`. Untuk HTTPS, TLS verification dapat dibypass memakai `--no-check-certificate`.

```sh
case "$REPO" in
  http://*|https://*) wget --no-check-certificate -O "$out" "$src" ;;
  *) cp "$src" "$out" ;;
esac
```

Package bawaan yang disediakan:

- `hello`: memasang command `/bin/hello`.
- `fastfetch`: memasang script informasi sistem sederhana.
- `fuse`: memasang `/bin/fuse_hello` dan `/bin/fuse-test`.

Package `fuse` berisi program FUSE demo yang dapat membuat mount point dan menampilkan file `hello.txt`. Device `/dev/fuse` dibuat saat boot:

```sh
[ -c /dev/fuse ] || mknod -m 666 /dev/fuse c 10 229 2>/dev/null || true
```

### ISO Bootable

Script [iso.sh](soal_1/iso.sh) membuat ISO bernama [farewell.iso](soal_1/osboot/farewell.iso). ISO berisi kernel, single initramfs, multi initramfs, dan konfigurasi GRUB.

```bash
cp "$KERNEL" "$ISO_ROOT/boot/bzImage"
cp "$SINGLE_INITRAMFS" "$ISO_ROOT/boot/single.gz"
cp "$MULTI_INITRAMFS" "$ISO_ROOT/boot/multi.gz"
```

Menu GRUB menyediakan dua pilihan:

```text
Farewell Party - Single User Filesystem
Farewell Party - Multi User Filesystem
```

Kedua menu memakai kernel argument:

```text
console=ttyS0 rdinit=/init
```

ISO dibuat menggunakan `grub2-mkimage` atau `grub-mkimage`, lalu dipaketkan dengan `xorriso`.

```bash
xorriso -as mkisofs \
  -R \
  -J \
  -V ISOIMAGE \
  -b boot/grub/i386-pc/eltorito.img \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  -o "$ISO_OUT" \
  "$ISO_ROOT"
```

Output akhir:

```text
soal_1/osboot/farewell.iso
```

### QEMU Helper

Script [qemu.sh](soal_1/qemu.sh) menyediakan tiga mode boot:

```bash
./qemu.sh --single
./qemu.sh --multi
./qemu.sh --all
```

QEMU dijalankan dengan serial console dan user networking:

```bash
COMMON=(
  qemu-system-x86_64
  -m 512M
  -nographic
  -netdev user,id=net0
  -device e1000,netdev=net0
)
```

Mode `--single` dan `--multi` langsung memakai kernel serta initramfs:

```bash
-kernel "$OUT/bzImage"
-initrd "$OUT/single.gz"
-append "console=ttyS0 rdinit=/init"
```

Mode `--all` boot dari ISO:

```bash
-cdrom "$OUT/farewell.iso"
-boot d
```

### Backup

Script [backup.sh](soal_1/backup.sh) membuat file backup:

```text
soal_1/osboot/farewell_backup_[DDMMYYYY-HHMMSS].zip
```

Script mengecek semua file wajib sebelum membuat ZIP. Jika salah satu file tidak ada, script berhenti dengan pesan error.

```bash
require_file "$KERNEL"
require_file "$SINGLE_INITRAMFS"
require_file "$MULTI_INITRAMFS"
require_file "$ISO"
```

Arsip dibuat dengan `zip -X -j` agar metadata tambahan ZIP tidak ikut dan file di dalam arsip tidak membawa path directory host.

```bash
zip -X -j -q "$BACKUP_PATH" \
  "$KERNEL" \
  "$SINGLE_INITRAMFS" \
  "$MULTI_INITRAMFS" \
  "$ISO"
```

### Contoh Pengujian

Build semua output Soal 1:

```bash
cd soal_1
./kernel.sh
./single.sh
./multi.sh
./iso.sh
./backup.sh
```

Boot langsung ke single-user:

```bash
./qemu.sh --single
```

Test di dalam OS:

```sh
whoami
ls /bin /dev /proc /sys /etc /tmp /root
ping -c 3 8.8.8.8
wget -O- http://example.com
party list
party install fuse
fuse-test
```

Boot langsung ke multi-user:

```bash
./qemu.sh --multi
```

Test login:

```text
root / root123
henn / henn123
hann / hann123
viii / viii123
kids / kids123
```

Test permission:

```sh
ls -ld /root /home/henn /home/hann /home/viii /home/kids /tmp
touch /home/henn/a
touch /home/hann/a
touch /home/viii/a
touch /home/kids/a
```

Boot lewat ISO:

```bash
./qemu.sh --all
```

Pada mode ISO, GRUB menampilkan menu untuk memilih single-user atau multi-user filesystem.

### Kendala dan Solusi Soal 1

Beberapa kendala yang muncul selama pengerjaan:

- Kernel Linux lama dapat gagal dibuild dengan compiler Fedora baru karena warning dianggap error. Solusinya `CONFIG_WERROR` dinonaktifkan.
- Build kernel dapat terganggu konfigurasi certificate/keyring. Solusinya konfigurasi module signature, trusted key, revocation key, dan beberapa parser certificate dinonaktifkan.
- BusyBox applet `tc` gagal build dengan header kernel host baru. Solusinya `CONFIG_TC` dan fitur terkait dinonaktifkan.
- Single-user sempat kernel panic saat `exit` karena shell dijalankan sebagai PID 1 dengan `exec`. Solusinya shell dijalankan sebagai child process, lalu `/init` melakukan `poweroff -f`.
- Multi-user membutuhkan UID/GID berbeda pada initramfs. Solusinya memakai `gen_init_cpio` dari source kernel, bukan GNU `cpio --owner=0:0`.
- ISO dibuat deterministik dengan `grub2-mkimage` dan `xorriso`, bukan `grub2-mkrescue` penuh, karena metadata waktu dari rescue ISO dapat berubah antar build.

---

## Soal 2: SEASON

Pada soal nomor 2, diminta untuk melengkapi sistem operasi 16-bit sederhana yang boot melalui floppy image dan berjalan di Bochs. File yang menjadi fokus utama adalah [kernel.asm](soal_2/kernel.asm) dan [kernel.c](soal_2/kernel.c).

Command shell yang harus tersedia:

```text
check
add <a> <b>
sub <a> <b>
fac <n>
season <winter|spring|summer|fall|radiant>
triangle <n>
clear
help
about
```

### Build dan Run

Build dilakukan melalui [Makefile](soal_2/Makefile):

```make
prepare:
	dd if=/dev/zero of=floppy.img bs=512 count=2880

bootloader:
	nasm -f bin bootloader.asm -o bootloader.bin
	dd if=bootloader.bin of=floppy.img bs=512 count=1 conv=notrunc

kernel:
	nasm -f as86 kernel.asm -o kernel-asm.o
	bcc -ansi -c kernel.c -o kernel.o
	ld86 -o kernel.bin -d kernel-asm.o kernel.o
	dd if=kernel.bin of=floppy.img bs=512 seek=1 conv=notrunc
```

Command untuk build dan run:

```bash
cd soal_2
make build
make run
```

Pada Fedora, path BIOS Bochs disesuaikan di [bochsrc.txt](soal_2/bochsrc.txt):

```text
romimage: file=/usr/share/bochs/BIOS-bochs-latest
vgaromimage: file=/usr/share/bochs/VGABIOS-lgpl-latest.bin
```

### Input Keyboard di `kernel.asm`

Fungsi `_getChar` pada [kernel.asm](soal_2/kernel.asm) diimplementasikan menggunakan BIOS interrupt `int 0x16`.

```asm
_getChar:
    push ds
    push es

    mov ah, 0x00
    int 0x16

    pop es
    pop ds
    xor ah, ah
    ret
```

`AH=0x00` membuat BIOS menunggu keypress, lalu ASCII character dikembalikan melalui register `AL`. Register `DS` dan `ES` disimpan lebih dulu karena BIOS interrupt dapat mengubah segment register, sedangkan kode C masih bergantung pada segment yang benar.

Fungsi `_putInMemory` dipakai oleh C untuk menulis langsung ke video memory text mode `0xB800`.

```asm
_putInMemory:
    push bp
    mov bp, sp

    push ds
    push si

    mov ax, [bp+4]
    mov si, [bp+6]
    mov cl, [bp+8]

    mov ds, ax
    mov [si], cl

    pop si
    pop ds

    pop bp
    ret
```

Register `SI` juga disimpan agar tidak merusak hasil kompilasi `bcc`.

### Output ke Video Memory

Pada [kernel.c](soal_2/kernel.c), cursor disimpan sebagai indeks karakter layar. Setiap karakter di text mode memakai 2 byte: byte karakter dan byte warna.

```c
int cursor = 0;
char color = 0x07;

void putInMemory(int segment, int address, char character);
int getChar();
```

Fungsi `printChar` menulis karakter ke segment `0xB800`, menangani newline, backspace, dan clear screen jika cursor melewati batas layar.

```c
void printChar(char c) {
    int pos;

    if (c == '\n') {
        newline();
        return;
    }

    if (c == 8) {
        if (cursor > 0) {
            cursor--;
            pos = cursor * 2;
            putInMemory(0xB800, pos, ' ');
            putInMemory(0xB800, pos + 1, color);
        }
        return;
    }

    pos = cursor * 2;
    putInMemory(0xB800, pos, c);
    putInMemory(0xB800, pos + 1, color);
    cursor++;
}
```

Fungsi `readString` membaca input dari keyboard melalui `getChar`, menampilkan echo ke layar, mendukung Backspace, dan berhenti saat Enter.

```c
void readString(char *buf) {
    int i;
    char c;

    i = 0;
    while (1) {
        c = getChar();

        if (c == 13) {
            buf[i] = 0;
            return;
        }

        if (c == 8) {
            if (i > 0) {
                i--;
                printChar(8);
            }
        } else {
            if (c >= 32 && c <= 126 && i < 63) {
                buf[i] = c;
                i++;
                printChar(c);
            }
        }
    }
}
```

### Parser dan Konversi Angka

Karena project ini adalah OS 16-bit real mode, `kernel.c` tidak menggunakan `stdio.h`, `stdlib.h`, `string.h`, `printf`, `scanf`, atau `malloc`. Fungsi string dan parsing dibuat manual.

Fungsi `strcmp` dibuat dengan return `1` jika string sama dan `0` jika berbeda.

```c
int strcmp(char *a, char *b) {
    int i;

    i = 0;
    while (a[i] != 0 && b[i] != 0) {
        if (a[i] != b[i]) {
            return 0;
        }
        i++;
    }

    if (a[i] == 0 && b[i] == 0) {
        return 1;
    }

    return 0;
}
```

Parsing angka dilakukan dengan `parseNumberAt` dan hasilnya disimpan pada global `parsedNumber`. Cara ini dipakai karena toolchain `bcc` 16-bit kurang stabil saat helper parsing memakai pointer ke variabel lokal.

```c
int parseNumberAt(char *s, int idx) {
    int sign;
    int value;
    int found;
    int digit;

    sign = 1;
    value = 0;
    found = 0;

    idx = skipSpacesAt(s, idx);

    if (s[idx] == '-') {
        sign = -1;
        idx++;
    } else if (s[idx] == '+') {
        idx++;
    }

    while (s[idx] >= '0' && s[idx] <= '9') {
        digit = s[idx] - '0';
        value = value * 10;
        value = value + digit;
        found = 1;
        idx++;
    }

    if (!found) {
        return -1;
    }

    parsedNumber = value * sign;
    return idx;
}
```

Konversi integer ke string dilakukan tanpa operator pembagian `/` dan modulo `%`. Implementasinya memakai pengurangan berulang terhadap `10000`, `1000`, `100`, `10`, dan `1`.

```c
digit = 0;
while (n >= 1000) {
    n = n - 1000;
    digit++;
}
if (digit > 0 || started) {
    j = appendDigit(out, j, digit);
    started = 1;
}
```

### Implementasi Command

Saat boot, shell menampilkan:

```text
Welcome to Assistant's Last Gift
type 'help'

>
```

Loop utama berada di fungsi `main`.

```c
while (1) {
    printString("> ");
    readString(cmd);
    newline();

    if (strcmp(cmd, "check")) {
        printString("ok");
    } else if (isCommand(cmd, "add")) {
        ...
    } else if (isCommand(cmd, "sub")) {
        ...
    } else if (isCommand(cmd, "fac")) {
        ...
    } else if (isCommand(cmd, "season")) {
        ...
    } else if (isCommand(cmd, "triangle")) {
        ...
    } else if (strcmp(cmd, "clear")) {
        clearScreen();
    } else if (strcmp(cmd, "help")) {
        printString("check add sub fac season triangle clear about");
    } else if (strcmp(cmd, "about")) {
        printString("Assistant's Last Gift");
    } else {
        printString("unknown command");
    }

    newline();
}
```

Command `check` digunakan sebagai sanity test:

```text
check -> ok
```

Command `add` dan `sub` memakai `parseTwoArgs`.

```c
if (parseTwoArgs(cmd, 3)) {
    a = parsedA;
    b = parsedB;
    result = a + b;
    intToString(result, number);
    printString(number);
} else {
    printString("usage: add <a> <b>");
}
```

Command `fac` dibatasi sampai `7` agar aman pada signed integer 16-bit.

```c
if (cmd[idx] == 0 && a >= 0 && a <= 7) {
    result = factorial(a);
    intToString(result, number);
    printString(number);
} else {
    printString("know your limit little bro.");
}
```

Command `season` mengganti warna global `color`.

```c
if (matchWordAt(cmd, 6, "winter")) {
    color = 0x0B;
    printString("winter mode");
    return 1;
}
```

Mode warna yang tersedia:

- `winter`: cyan/biru muda.
- `spring`: hijau muda.
- `summer`: kuning.
- `fall`: coklat/kuning gelap.
- `radiant`: magenta terang.

Command `triangle` mencetak pola segitiga memakai karakter `x` dan warna aktif saat itu.

```c
void printTriangle(int n) {
    int row;
    int col;

    row = 1;
    while (row <= n) {
        col = 0;
        while (col < row) {
            printChar('x');
            col++;
        }

        if (row < n) {
            newline();
        }

        row++;
    }
}
```

### Contoh Pengujian

Command pengujian di Bochs:

```text
check
add 5 3
sub 10 2
fac 6
fac 120
season winter
season spring
season summer
season fall
season radiant
triangle 5
help
clear
about
```

Expected output minimal:

```text
check       -> ok
add 5 3    -> 8
sub 10 2   -> 8
fac 6      -> 720
fac 120    -> know your limit little bro.
help       -> check add sub fac season triangle clear about
about      -> Assistant's Last Gift
```

Output `triangle 5`:

```text
x
xx
xxx
xxxx
xxxxx
```

### Kendala dan Solusi Soal 2

Beberapa kendala yang muncul selama pengerjaan:

- Layar blank setelah build karena urutan link `kernel.bin` salah. Bootloader melompat ke awal kernel, sehingga `_start` dari `kernel.asm` harus berada di awal binary. Solusinya link order dibuat `kernel-asm.o kernel.o`.
- Input keyboard awal belum berjalan karena `_getChar` belum diimplementasikan. Solusinya memakai BIOS interrupt `int 0x16`.
- Tampilan dapat menjadi aneh jika BIOS interrupt mengubah segment register. Solusinya `_getChar` menyimpan dan mengembalikan `DS` serta `ES`.
- Command `add`, `sub`, dan `fac` sempat selalu menampilkan usage karena parser memakai pointer ke variabel lokal. Solusinya hasil parsing disimpan di global `parsedNumber`, `parsedA`, dan `parsedB`.
- Sistem sempat freeze saat konversi angka. Solusinya `intToString` ditulis ulang tanpa array lokal dan tanpa pembagian/modulo.
- Path BIOS Bochs di Fedora berbeda, sehingga [bochsrc.txt](soal_2/bochsrc.txt) disesuaikan ke `/usr/share/bochs/BIOS-bochs-latest` dan `/usr/share/bochs/VGABIOS-lgpl-latest.bin`.
