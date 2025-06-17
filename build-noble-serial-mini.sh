#!/usr/bin/env bash
# Build a BIOS+UEFI hybrid ISO that boots Debian-Installer (expert, serial)
# and installs Ubuntu 24.04 LTS (Noble Numbat).

set -euo pipefail

#########################  CONFIG  ############################################
UBU_MINI_URL="https://cdimage.ubuntu.com/ubuntu-mini-iso/noble/daily-live/current/noble-mini-iso-amd64.iso"
DEB_NETBOOT_URL="https://deb.debian.org/debian/dists/bookworm/main/installer-amd64/current/images/netboot/netboot.tar.gz"
BAUD=9600
VOL="NOBLE_SERIAL_DI"
OUT_ISO="$PWD/noble-serial-di.iso"
###############################################################################

WORKDIR=$(mktemp -d)
trap 'sudo umount "$WORKDIR/mnt" 2>/dev/null || true; rm -rf "$WORKDIR"' EXIT

#########################  DEPENDENCIES  ######################################
ensure() { command -v "$1" >/dev/null || sudo apt-get -y install "$1"; }
for pkg in wget rsync xorriso grub-mkstandalone mtools mkfs.vfat cpio gzip \
           isomd5sum ubuntu-archive-keyring; do ensure "$pkg"; done
###############################################################################

echo "📥 Downloading files ..."
wget -q --show-progress -O "$WORKDIR/mini.iso"   "$UBU_MINI_URL"
wget -q --show-progress -O "$WORKDIR/netboot.tgz" "$DEB_NETBOOT_URL"

echo "📦  Extracting Ubuntu mini.iso ..."
mkdir "$WORKDIR/mnt"
sudo mount -o loop,ro "$WORKDIR/mini.iso" "$WORKDIR/mnt"
rsync -aHAX --quiet "$WORKDIR/mnt/" "$WORKDIR/extract/"


sudo umount "$WORKDIR/mnt"

echo "🔧  Unpacking Debian netboot ..."
tar -xf "$WORKDIR/netboot.tgz" -C "$WORKDIR"

DI_DIR="$WORKDIR/extract/install/netboot/ubuntu-installer/amd64"
mkdir -p "$DI_DIR"
cp "$WORKDIR/debian-installer/amd64/linux"      "$DI_DIR/linux"
cp "$WORKDIR/debian-installer/amd64/initrd.gz"  "$WORKDIR/di-initrd.gz"

echo "🔑  Patching initrd with Ubuntu key + preseed ..."
mkdir "$WORKDIR/initrd.work"
pushd "$WORKDIR/initrd.work" >/dev/null
gzip -dc ../di-initrd.gz | cpio -idmu --quiet
# add Ubuntu archive key
mkdir -p usr/share/keyrings
cp /usr/share/keyrings/ubuntu-archive-keyring.gpg usr/share/keyrings/

echo "🔧  Patching Ubuntu mini.iso for serial console ..."
cat > "ubuntu-post.sh" <<'EOSCRIPT'
#!/bin/sh
set -e

# --- remove Debian shim to avoid file-overlap with Ubuntu shim ---
apt-get -y --allow-remove-essential purge shim-unsigned shim-signed grub-efi-amd64-signed || true
apt-get -y autoremove

# --- add Ubuntu mirror ---
echo "deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] \
http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse" > /etc/apt/sources.list
apt-get update

# pull minimal Ubuntu GRUB + shim stack + kernmel
apt-get -y install grub-common grub-efi-amd64-signed shim-signed linux-image-oem-24.04

# upgrade everything else
apt-get -y dist-upgrade

# --- classic interface names + serial console ---
sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="net.ifnames=0 biosdevname=0 console=ttyS0,9600n8"/' /etc/default/grub
update-grub
ln -s /dev/null /etc/udev/rules.d/80-net-setup-link.rules

# enable login on ttyS0 9600n8
systemctl enable serial-getty@ttyS0.service
mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d
cat > /etc/systemd/system/serial-getty@ttyS0.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --keep-baud 9600 --noclear %I \$TERM
EOF
systemctl daemon-reload
EOSCRIPT

chmod +x "ubuntu-post.sh"

# minimal preseed: Ubuntu mirror + full expert mode
cat > preseed.cfg <<'ENDPRESEED'
### --- localisation ---
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i console-setup/ask_detect boolean false

### --- Debian mirror for installer components ---
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/suite string bookworm
d-i mirror/codename string bookworm
d-i mirror/http/proxy string

### Clock & time ###
d-i clock-setup/utc boolean true
d-i time/zone string UTC
d-i clock-setup/hardware_clock boolean UTC

### --- load SSH network-console inside the installer ---
d-i anna/choose_modules string network-console

### --- force UEFI GRUB even on CSM boards ---
grub-installer/force-efi-install boolean true
grub-installer/update_nvram boolean true
grub-installer/force-efi-extra-removable boolean true
partman-efi/non_efi_system boolean false

### Kernel & initrd ###
d-i base-installer/kernel/override-image string linux-generic
d-i initramfs-tools/driver-policy select most

### --- minimal base + SSH only ---
d-i debconf/priority string low
d-i debian-installer/console string ttyS0,9600n8
tasksel tasksel/first multiselect standard
d-i pkgsel/include string openssh-server
d-i pkgsel/install-language-support boolean false
d-i pkgsel/upgrade select none
popularity-contest popularity-contest/participate boolean false

### --- run our post-script inside target system ---
d-i preseed/late_command string mount --make-private --rbind /dev /target/dev && mount --make-private --rbind /proc /target/proc && mount --make-private --rbind /sys /target/sys &&cp /usr/share/keyrings/* /target/usr/share/keyrings/ && cp /ubuntu-post.sh /target/tmp && in-target /bin/bash /tmp/ubuntu-post.sh
ENDPRESEED


find . | cpio -o -H newc | gzip -9 > ../initrd-ubuntu.gz
popd >/dev/null
cp "$WORKDIR/initrd-ubuntu.gz" "$DI_DIR/initrd.gz"

DI_KERNEL="/install/netboot/ubuntu-installer/amd64/linux"
DI_INITRD="/install/netboot/ubuntu-installer/amd64/initrd.gz"

echo "✏️  Patching GRUB menus for serial + d-i ..."
find "$WORKDIR/extract" -type f -name grub.cfg | while read -r cfg; do
  grep -q '^serial --speed' "$cfg" || sed -i \
    "1iserial --speed=${BAUD} --unit=0 --word=8 --parity=no --stop=1\nterminal_input serial console\nterminal_output serial console\n" "$cfg"
  sed -Ei "s|^[[:space:]]*linux .*|  linux ${DI_KERNEL} console=ttyS0,${BAUD}n8 priority=low net.ifnames=0 biosdevname=0 ---|" "$cfg"
  sed -Ei "s|^[[:space:]]*initrd .*|  initrd ${DI_INITRD}|" "$cfg"
  sed -Ei 's/(boot=casper|maybe-live|iso-scan[^ ]*)//g' "$cfg"
done

echo "✏️  Updating ISOLINUX (legacy BIOS) if present ..."
if [[ -f "$WORKDIR/extract/isolinux/txt.cfg" ]]; then
  sed -i "1iserial 0 ${BAUD}" "$WORKDIR/extract/isolinux/txt.cfg"
  sed -Ei "s|append .*|append linux ${DI_KERNEL} initrd=${DI_INITRD} console=ttyS0,${BAUD}n8 priority=low net.ifnames=0 biosdevname=0 ---|" \
        "$WORKDIR/extract/isolinux/txt.cfg"
fi

echo "🔨  Building ESP with standalone GRUB EFI …"
ESP="$WORKDIR/esp"
mkdir -p "$ESP/EFI/BOOT"
cat > "$ESP/min.cfg" <<'EOF'
search --file --set=root /.disk/info
set prefix=($root)/boot/grub
configfile $prefix/grub.cfg
EOF
grub-mkstandalone -O x86_64-efi -o "$ESP/EFI/BOOT/BOOTX64.EFI" \
  "boot/grub/grub.cfg=$ESP/min.cfg" --compress=xz
dd if=/dev/zero of="$WORKDIR/efi.img" bs=1M count=8 status=none
mkfs.vfat "$WORKDIR/efi.img" >/dev/null
mcopy -s -i "$WORKDIR/efi.img" "$ESP"/* ::

BIOS_IMG=$(find "$WORKDIR/extract" -name eltorito.img | head -n1)
rel() { echo "${1#${WORKDIR}/extract/}"; }

echo "📀  Creating hybrid ISO …"
xorriso -as mkisofs -V "$VOL" -o "$OUT_ISO" -r -J -l -iso-level 3 \
  -b "$(rel "$BIOS_IMG")" -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot -e EFI.img -no-emul-boot \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin -isohybrid-gpt-basdat \
  -append_partition 2 0xef "$WORKDIR/efi.img" \
  -graft-points \
     "$(rel "$BIOS_IMG")"="$BIOS_IMG" \
     "EFI.img"="$WORKDIR/efi.img" \
     /="$WORKDIR/extract"

implantisomd5 --force "$OUT_ISO" >/dev/null
echo "✅  Done → $(basename "$OUT_ISO")"
echo "💾  To write to USB stick, use:"
echo "    sudo dd if=\"$OUT_ISO\" of=/dev/sdX bs=4M status=progress && sync"
echo "    (replace /dev/sdX with your USB device, e.g. /dev/sdb)"
echo "    (make sure to unmount the USB device first!)"
echo "    (this will erase all data on the USB stick!)"
echo "    (use 'lsblk' to find your USB device)"