#!/usr/bin/env bash
# build-noble-serial-mini.sh – Ubuntu 24.04 mini.iso → serial-friendly + expert-mode
set -euo pipefail

ISO_URL="http://cdimage.ubuntu.com/ubuntu-mini-iso/noble/daily-live/current/noble-mini-iso-amd64.iso"
BAUD="9600"
DI_EXPERT="priority=low"       # Debian-Installer “Expert install”
VOL="Noble-Serial"
WORKDIR="$(mktemp -d)"
OUT_ISO="${PWD}/noble-mini-serial.iso"

###############################################################################
# ensure_packages — resolve binaries → apt packages and install if missing
###############################################################################
ensure_packages() {
  declare -A MAP=([implantisomd5]=isomd5sum [isohybrid]=syslinux-utils [xorriso]=xorriso)
  local miss=() pkg
  for b in "$@"; do command -v "$b" >/dev/null || miss+=("$b"); done
  [[ ${#miss[@]} -eq 0 ]] && return
  echo "🔍  Installing: ${miss[*]}"
  apt-get -qq update
  for b in "${miss[@]}"; do
    pkg=${MAP[$b]:-}
    [[ -z $pkg ]] && pkg=$(apt-cache search --names-only "^${b}$" | awk '{print $1}' | head -n1)
    [[ -z $pkg ]] && pkg=$(apt-cache search "$b" | awk '{print $1}' | head -n1)
    [[ -n $pkg ]] || { echo "❌  No apt package provides $b"; exit 1; }
    DEBIAN_FRONTEND=noninteractive apt-get -y install "$pkg"
  done
}

ensure_packages wget rsync xorriso implantisomd5
[[ $EUID -eq 0 ]] || { echo "❌  Run as root (sudo)"; exit 1; }

echo "📥  Downloading mini.iso …"
wget -q --show-progress -O "$WORKDIR/orig.iso" "$ISO_URL"

###############################################################################
# 1. Mount ISO read-only under /tmp/<run>/mnt  (FHS-compliant)               #
###############################################################################
MNTDIR="${WORKDIR}/mnt"
mkdir "$MNTDIR"
mount -o loop,ro "$WORKDIR/orig.iso" "$MNTDIR"            # FHS 3.0 §3.12  :contentReference[oaicite:5]{index=5}
rsync -aHAX --quiet "${MNTDIR}/" "${WORKDIR}/extract/"
umount "$MNTDIR"

###############################################################################
# 2. Patch every grub.cfg (BIOS **and** UEFI all use GRUB since 22.04)       #
###############################################################################
echo "✏️   Updating GRUB menus …"
mapfile -t GRUB_CFGS < <(find "$WORKDIR/extract" -type f -name 'grub.cfg')
for cfg in "${GRUB_CFGS[@]}"; do
  grep -q '^serial --speed' "$cfg" || \
    sed -i "1iserial --speed=${BAUD} --unit=0 --word=8 --parity=no --stop=1\nterminal_input serial console\nterminal_output serial console\n" "$cfg"
  sed -Ei "s@(linux .*) ---@\1 console=ttyS0,${BAUD}n8 ${DI_EXPERT} ---@g" "$cfg"
done

###############################################################################
# 3. Optional ISOLINUX patch (only older ISOs still have it)                 #
###############################################################################
if [[ -f "$WORKDIR/extract/isolinux/txt.cfg" ]]; then
  echo "✏️   Patching legacy ISOLINUX …"
  sed -i "1iserial 0 $BAUD" "$WORKDIR/extract/isolinux/txt.cfg"
  sed -Ei "s@append (.*) ---@append console=ttyS0,${BAUD}n8 ${DI_EXPERT} \1 ---@g" \
      "$WORKDIR/extract/isolinux/txt.cfg"
fi

###############################################################################
# 4. Work out which EFI boot image actually exists                           #
###############################################################################
EFI_IMG=$(find "$WORKDIR/extract" -type f -iname 'efi*.img' | head -n1 || true)
BIOS_IMG=$(find "$WORKDIR/extract" -type f -path '*/i386-pc/eltorito.img' | head -n1 || true)

# Turn absolute paths into ISO-relative paths
rel() { echo "${1#${WORKDIR}/extract/}"; }

###############################################################################
# 5. Build the new hybrid ISO                                               #
###############################################################################
echo "📦  Building hybrid ISO …"
xorriso -as mkisofs -V "$VOL" -o "$OUT_ISO" -r -J -l -iso-level 3 \
${BIOS_IMG:+  -b "$(rel "$BIOS_IMG")" -no-emul-boot -boot-load-size 4 -boot-info-table} \
${EFI_IMG:+   -eltorito-alt-boot -e "$(rel "$EFI_IMG")" -no-emul-boot} \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
${EFI_IMG:+   -isohybrid-gpt-basdat -append_partition 2 0xef "$(rel "$EFI_IMG")"} \
  "$WORKDIR/extract"

###############################################################################
# 6. Embed Debian-Installer MD5 signature                                    #
###############################################################################
echo "🔑  Embedding MD5 …"
implantisomd5 --force "$OUT_ISO"

rm -rf "$WORKDIR"
echo "✅  Finished: $(basename "$OUT_ISO")"
