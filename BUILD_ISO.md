# Build a bootable Linux ISO

This procedure builds the x86_64 kernel in the linux submodule, packages it with a small static BusyBox initramfs, and creates **linux-boot.iso** at the repository root. The ISO boots to a BusyBox shell and supports BIOS and UEFI boot. It is a kernel boot image, not a full Linux distribution.

## Requirements

Use Ubuntu under WSL2. Install the kernel and ISO build dependencies:

~~~bash
sudo apt update
sudo apt install -y build-essential bc flex bison libssl-dev libelf-dev cpio gzip busybox-static xorriso grub-pc-bin grub-efi-amd64-bin mtools
~~~

## Export the source from Windows

The Windows checkout may have CRLF line endings, which break the Linux kernel's Kconfig parser. From PowerShell, export the submodule's committed source with LF endings and save its tracked working-tree edits as a patch:

~~~powershell
git -C C:\Users\bahda\code\linux-boot\linux -c core.autocrlf=false archive --format=tar --output=C:\Users\bahda\code\linux-boot\linux-boot-source.tar HEAD
cmd.exe /c "git -C C:\Users\bahda\code\linux-boot\linux diff HEAD --binary > C:\Users\bahda\code\linux-boot\linux-boot-working.patch"
~~~

These paths match this workspace. Change the root path if the repository is elsewhere. The patch carries tracked edits from the submodule into the build.

## Build the kernel, initramfs, and ISO

Open Ubuntu with **wsl.exe -d Ubuntu**, then run this Bash block:

~~~bash
set -euo pipefail
cd /mnt/c/Users/bahda/code/linux-boot

BUILD="$HOME/linux-boot-build-$(date +%Y%m%d-%H%M%S)"
SRC="$BUILD/src"
OBJ="$BUILD/obj"
ROOTFS="$BUILD/rootfs"
ISO_DIR="$BUILD/iso"
mkdir -p "$SRC"

tar -xf linux-boot-source.tar -C "$SRC"
if [ -s linux-boot-working.patch ]; then
    git -C "$SRC" apply --check "$PWD/linux-boot-working.patch"
    git -C "$SRC" apply "$PWD/linux-boot-working.patch"
fi
rm -f linux-boot-source.tar linux-boot-working.patch

make -C "$SRC" O="$OBJ" ARCH=x86_64 x86_64_defconfig
make -C "$SRC" O="$OBJ" ARCH=x86_64 -j6 bzImage

mkdir -p "$ROOTFS"/{bin,dev,proc,sys,tmp,root}
chmod 1777 "$ROOTFS/tmp"
cp /usr/bin/busybox "$ROOTFS/bin/busybox"
cat > "$ROOTFS/init" <<'EOF'
#!/bin/sh
export PATH=/bin
export TERM=linux
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
echo
echo Linux kernel booted. BusyBox shell is ready.
echo Type poweroff to shut down.
exec /bin/sh
EOF
chmod 755 "$ROOTFS/init"

cat > "$BUILD/initramfs.list" <<EOF
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
nod /dev/tty 0666 0 0 c 5 0
dir /bin 0755 0 0
dir /proc 0755 0 0
dir /sys 0755 0 0
dir /tmp 1777 0 0
dir /root 0700 0 0
file /bin/busybox /usr/bin/busybox 0755 0 0
file /init $ROOTFS/init 0755 0 0
slink /bin/sh busybox 0777 0 0
slink /bin/ash busybox 0777 0 0
EOF
for applet in ls cat mount umount mkdir echo pwd uname dmesg ps top grep sed vi clear stty reboot poweroff sync sleep head tail cp mv rm ln touch chmod date id wc find; do
    printf 'slink /bin/%s busybox 0777 0 0\n' "$applet" >> "$BUILD/initramfs.list"
done

gcc -O2 -Wall -Wmissing-prototypes -o "$BUILD/gen_init_cpio" "$SRC/usr/gen_init_cpio.c"
"$BUILD/gen_init_cpio" -t 0 "$BUILD/initramfs.list" | gzip -9 > "$BUILD/initramfs.cpio.gz"

mkdir -p "$ISO_DIR/boot/grub"
cp "$OBJ/arch/x86/boot/bzImage" "$ISO_DIR/boot/vmlinuz"
cp "$BUILD/initramfs.cpio.gz" "$ISO_DIR/boot/initramfs.cpio.gz"
cat > "$ISO_DIR/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=5
set timeout_style=menu

menuentry Linux {
    linux /boot/vmlinuz console=tty0 rdinit=/init
    initrd /boot/initramfs.cpio.gz
}
EOF

grub-mkrescue -o /mnt/c/Users/bahda/code/linux-boot/linux-boot.iso "$ISO_DIR"
~~~

The build uses six parallel jobs to fit comfortably in this machine's WSL memory. Lower -j6 if WSL has less memory available.

## Verify the image

~~~bash
file /mnt/c/Users/bahda/code/linux-boot/linux-boot.iso
xorriso -indev /mnt/c/Users/bahda/code/linux-boot/linux-boot.iso -report_el_torito plain
~~~

The ISO should report BIOS and UEFI El Torito boot entries.
