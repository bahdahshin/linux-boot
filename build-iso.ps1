[CmdletBinding()]
param(
    [string]$Distro = "Ubuntu",
    [ValidateRange(1, 64)]
    [int]$Jobs = 6
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$linuxPath = Join-Path $repoRoot "linux"
$isoPath = Join-Path $repoRoot "linux-boot.iso"

if (-not (Test-Path -LiteralPath $linuxPath)) {
    throw "Linux submodule not found at $linuxPath"
}
if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
    throw "Git for Windows is required and must be on PATH."
}
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "WSL is required. Install WSL2 with an Ubuntu distribution first."
}

$stamp = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $PID
$archivePath = Join-Path $repoRoot ".linux-boot-source-$stamp.tar"
$patchName = ".linux-boot-working-$stamp.patch"
$patchPath = Join-Path $repoRoot $patchName
$tempDirectory = Join-Path $env:TEMP "linux-boot-build-$stamp"
$bashPath = Join-Path $tempDirectory "build-linux-iso.sh"
$null = New-Item -ItemType Directory -Path $tempDirectory

function ConvertTo-WslPath {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath -notmatch '^([A-Za-z]):\\(.*)$') {
        throw "Expected a drive-letter path that WSL can mount: $fullPath"
    }

    $driveLetter = $Matches[1].ToLowerInvariant()
    $relativePath = $Matches[2].Replace('\', '/')
    return "/mnt/$driveLetter/$relativePath"
}

try {
    Write-Host "Exporting the Linux source and tracked working-tree edits..."
    & git.exe -C $linuxPath -c core.autocrlf=false archive --format=tar "--output=$archivePath" HEAD
    if ($LASTEXITCODE -ne 0) {
        throw "git archive failed with exit code $LASTEXITCODE"
    }

    Push-Location $repoRoot
    try {
        & $env:ComSpec /d /c "git -C linux diff HEAD --binary > $patchName"
        if ($LASTEXITCODE -ne 0) {
            throw "Creating the working-tree patch failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }

    $bashSource = @'
set -euo pipefail

REPO="$1"
ARCHIVE="$2"
PATCH="$3"
ISO="$4"
JOBS="$5"

missing=""
for tool in make gcc bc flex bison openssl perl python3 cpio gzip busybox xorriso grub-mkrescue grub-script-check mformat readelf; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        missing="$missing $tool"
    fi
done
if [ ! -f /usr/include/openssl/opensslv.h ]; then
    missing="$missing libssl-dev"
fi
if [ ! -f /usr/include/libelf.h ]; then
    missing="$missing libelf-dev"
fi
if [ -n "$missing" ]; then
    printf 'Missing WSL build dependencies:%s\n' "$missing" >&2
    printf '%s\n' 'Install them in Ubuntu with:' >&2
    printf '%s\n' 'sudo apt update && sudo apt install -y build-essential bc flex bison libssl-dev libelf-dev cpio gzip busybox-static xorriso grub-pc-bin grub-efi-amd64-bin mtools' >&2
    exit 2
fi
if readelf -l /usr/bin/busybox | grep -q INTERP; then
    echo "BusyBox is dynamically linked. Install the busybox-static package." >&2
    exit 2
fi

BUILD="$HOME/linux-boot-build-$(date +%Y%m%d-%H%M%S)-$$"
SRC="$BUILD/src"
OBJ="$BUILD/obj"
ROOTFS="$BUILD/rootfs"
ISO_DIR="$BUILD/iso"
mkdir -p "$SRC"

echo "Staging Linux source..."
tar -xf "$ARCHIVE" -C "$SRC"
if [ -s "$PATCH" ]; then
    git -C "$SRC" apply --check "$PATCH"
    git -C "$SRC" apply "$PATCH"
fi

echo "Configuring and compiling the x86_64 kernel..."
make -C "$SRC" O="$OBJ" ARCH=x86_64 x86_64_defconfig
make -C "$SRC" O="$OBJ" ARCH=x86_64 -j"$JOBS" bzImage

echo "Creating the BusyBox initramfs..."
mkdir -p "$ROOTFS/bin" "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/tmp" "$ROOTFS/root"
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

echo "Creating the BIOS and UEFI GRUB ISO..."
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
grub-script-check "$ISO_DIR/boot/grub/grub.cfg"
grub-mkrescue -o "$ISO" "$ISO_DIR"

bootReport="$(xorriso -indev "$ISO" -report_el_torito plain 2>&1)"
printf '%s\n' "$bootReport"
if ! printf '%s\n' "$bootReport" | grep -q BIOS; then
    echo "ISO is missing its BIOS boot entry." >&2
    exit 1
fi
if ! printf '%s\n' "$bootReport" | grep -q UEFI; then
    echo "ISO is missing its UEFI boot entry." >&2
    exit 1
fi
ls -lh "$ISO"
'@

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $unixNewlines = $bashSource.Replace(([string][char]13 + [string][char]10), [string][char]10)
    [System.IO.File]::WriteAllText($bashPath, $unixNewlines, $utf8NoBom)

    Write-Host "Checking WSL distribution '$Distro'..."
    & wsl.exe -d $Distro -- true
    if ($LASTEXITCODE -ne 0) {
        throw "Could not run the WSL distribution '$Distro'."
    }

    $wslBashPath = ConvertTo-WslPath $bashPath
    $wslRepoPath = ConvertTo-WslPath $repoRoot
    $wslArchivePath = ConvertTo-WslPath $archivePath
    $wslPatchPath = ConvertTo-WslPath $patchPath
    $wslIsoPath = ConvertTo-WslPath $isoPath

    Write-Host "Building the ISO in WSL Ubuntu..."
    & wsl.exe -d $Distro -- bash $wslBashPath $wslRepoPath $wslArchivePath $wslPatchPath $wslIsoPath $Jobs
    if ($LASTEXITCODE -ne 0) {
        throw "The WSL build failed with exit code $LASTEXITCODE"
    }

    Write-Host "Created $isoPath"
}
finally {
    Remove-Item -LiteralPath $archivePath, $patchPath -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
