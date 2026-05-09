#!/usr/bin/env bash
# Build the cache22 installer ISO from scratch — no lorax, no Anaconda,
# no kickstart. Fedora 44 userland (because the kernel + bootloader
# need to be Fedora-signed for SB-with-MS-keys to work, and the
# kernel/initramfs/dracut hooks expect Fedora userland), but every
# user-visible string is rebranded to cache22.
#
# Pipeline:
#   1. dnf --installroot=/rootfs install <minimal Fedora 44 packages>
#   2. Copy cache22-install + variants.json into rootfs
#   3. Configure autologin tty1 → cache22-install
#   4. Aggressive Fedora→cache22 branding (os-release, issue, motd,
#      hostname, gettys, plymouth disabled, grub menu titles)
#   5. Strip caches, mksquashfs the rootfs → squashfs.img
#   6. dracut --add dmsquash-live in chroot → initramfs
#   7. Pull vmlinuz / shim / grub2 / mokmanager out of rootfs
#   8. Build EFI boot image (FAT) with shim + grub2
#   9. xorrisofs the whole thing into a hybrid ISO
#
# Must run as root. On Fedora 44 (host or container).
#
# Usage:  ./build-iso.sh [output_dir]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$HERE/out}"
WORK="${HERE}/work"
ROOTFS="$WORK/rootfs"
ISOROOT="$WORK/isoroot"
ISO_DATE="$(date -u --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
ISO_LABEL="CACHE22_INSTALLER"
ISO_NAME="cache22-installer-${ISO_DATE}"

[[ ${EUID} -eq 0 ]] || { echo "build-iso.sh must run as root."; exit 1; }
for tool in dnf dracut mksquashfs xorriso mkfs.fat mcopy mmd python3; do
    command -v "$tool" >/dev/null 2>&1 \
        || { echo "ERROR: missing $tool"; exit 1; }
done

# ─── 1. Bootstrap minimal Fedora 44 rootfs ────────────────────────
echo "==> Bootstrapping Fedora 44 rootfs at $ROOTFS"
rm -rf "$ROOTFS"; mkdir -p "$ROOTFS"

# Packages: only what the installer + boot chain actually need. No
# @core (drags in plymouth, fwupd, firewalld, sssd, audit, etc. that
# we don't use). Audio/print/scan stack stays out.
PKGS=(
    # Boot chain for the live ISO itself (Fedora's MS-signed shim +
    # signed grub2 so the live env boots under stock SB on factory
    # firmware). The installed system uses sd-boot + UKI instead;
    # cache22-install runs sbctl/bootctl/ukify inside a chroot of the
    # deployed cache22 rootfs, so the live env doesn't need them.
    kernel-core kernel-modules-core kernel-modules-extra
    shim-x64 grub2-efi-x64 grub2-tools-minimal
    efibootmgr
    # Initramfs + live-media support (dmsquash-live = mount squashfs from CD)
    dracut dracut-live dracut-network dracut-config-generic
    # Firmware: linux-firmware covers most modern wifi/wired; specific
    # wifi-firmware packages for the hardware not in linux-firmware.
    linux-firmware
    iwlwifi-mvm-firmware iwlwifi-dvm-firmware
    atheros-firmware brcmfmac-firmware realtek-firmware
    # Networking
    NetworkManager NetworkManager-wifi
    wpa_supplicant iwd
    iputils iproute
    # nftables for the firewall side (and iptables-nft as the compat
    # shim some tools/scripts still call); needed for cases where the
    # installer brings up isolated container networks (podman netavark
    # under specific configs) or the user wants a defensive posture
    # on the live env before running cache22-install over a hostile
    # network.
    nftables iptables-nft
    # WireGuard CLI tooling (NM ships WG natively; these are for
    # manual `wg`/`wg-quick` use and for setup scripts the user
    # may run from the live env before installing.
    wireguard-tools
    openssh-clients openssh-server
    curl ca-certificates
    # Core userspace
    bash bash-completion coreutils util-linux util-linux-core
    findutils grep sed gawk less vim-minimal nano which tmux
    # jq for the few sysadmin / setup scripts that need it. Other
    # "nice CLI" tools (yq, tree, ncdu, fzf, etc.) live in the
    # installed cache22 image, not here — the live ISO is one-shot
    # and kept lean.
    jq
    glibc-langpack-en sudo systemd systemd-resolved
    # Storage / partitioning (cache22-install uses these). gdisk is
    # Fedora's name for what Arch calls gptfdisk.
    parted gdisk e2fsprogs btrfs-progs xfsprogs dosfstools
    cryptsetup lvm2 mdadm
    # Container / installer tooling
    podman bootc skopeo
    # cache22-install needs python for variants.json parsing,
    # openssl for password hashing.
    python3 openssl
)

# Bootstrap just the filesystem package first so the rootfs directory
# structure (/proc, /sys, /dev, /var, etc.) exists; then bind-mount
# /proc /sys /dev so post-install scriptlets (udev hwdb generation,
# grub2-editenv, systemd catalog) work cleanly.
dnf install \
    --installroot="$ROOTFS" \
    --use-host-config \
    --releasever=44 \
    --setopt=install_weak_deps=False \
    --setopt=keepcache=False \
    --setopt=tsflags=nodocs \
    --assumeyes \
    --nogpgcheck \
    filesystem

mkdir -p "$ROOTFS"/{proc,sys,dev,run}
mount --rbind /proc "$ROOTFS/proc"
mount --rbind /sys  "$ROOTFS/sys"
mount --rbind /dev  "$ROOTFS/dev"
trap 'for m in run dev sys proc; do umount -lR "$ROOTFS/$m" 2>/dev/null || true; done' EXIT

dnf install \
    --installroot="$ROOTFS" \
    --use-host-config \
    --releasever=44 \
    --setopt=install_weak_deps=False \
    --setopt=keepcache=False \
    --setopt=tsflags=nodocs \
    --assumeyes \
    --nogpgcheck \
    "${PKGS[@]}"

# ─── 2. Stage cache22-install + assets ────────────────────────────
echo "==> Staging cache22-install + cache22-repair + assets"
install -Dm0755 "$REPO/installer/cache22-install"  "$ROOTFS/usr/local/bin/cache22-install"
install -Dm0755 "$REPO/installer/cache22-repair"   "$ROOTFS/usr/local/bin/cache22-repair"
install -Dm0644 "$REPO/variants.json"              "$ROOTFS/etc/cache22/variants.json"

# ─── 3. Live env config (autologin root) ──────────────────────────
echo "==> Configuring live env (autologin, sshd, branding)"

# Root password (live env only — installed system has its own).
echo 'root:cache22' | chroot "$ROOTFS" chpasswd

# Auto-login root on tty1. Don't auto-launch the installer — the
# installer needs root, and exec'ing sudo from .bash_profile produces
# a black screen on tty1 in some configurations (similar issue we hit
# with the cachy live env). User runs `cache22-install` manually after
# seeing the motd.
mkdir -p "$ROOTFS/etc/systemd/system/getty@tty1.service.d"
cat > "$ROOTFS/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -o '-p -f -- \\u' --noclear --autologin root - $TERM
EOF

# Greeting on root login (motd tells the user how to start the installer).
cat > "$ROOTFS/root/.bash_profile" <<'EOF'
[[ -f /etc/motd ]] && cat /etc/motd
EOF

# Enable services we want at boot.
chroot "$ROOTFS" systemctl enable NetworkManager.service sshd.service \
    >/dev/null 2>&1 || true

# Allow root SSH on the live env (for emergency-recovery during
# installs). Installed system unaffected.
mkdir -p "$ROOTFS/etc/ssh/sshd_config.d"
cat > "$ROOTFS/etc/ssh/sshd_config.d/00-cache22-live.conf" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords no
EOF

# ─── 4. Aggressive Fedora→cache22 rebrand ─────────────────────────
echo "==> Rebranding Fedora → cache22"

# os-release: every Fedora-aware app reads this for "what distro am I".
# The filesystem package ships /etc/os-release as a symlink to
# ../usr/lib/os-release. `cat >` follows that symlink — so we'd write
# through to /usr/lib/os-release. Then if we `ln -sf ../etc/os-release`
# back at /usr/lib/os-release, both names point at each other and
# resolve to nothing. systemd-switch-root then refuses with "/sysroot
# does not seem to be an OS tree" and drops to emergency. Drop both
# names first, write the real file at /usr/lib/os-release (modern
# Fedora canonical location), and symlink /etc/os-release → there.
rm -f "$ROOTFS/etc/os-release" "$ROOTFS/usr/lib/os-release"
cat > "$ROOTFS/usr/lib/os-release" <<'EOF'
NAME="cache22 Live Installer"
PRETTY_NAME="cache22 Live Installer"
ID=cache22-installer
ID_LIKE=fedora
VERSION="44 (Live)"
VERSION_ID="44"
ANSI_COLOR="38;2;23;147;209"
HOME_URL="https://github.com/cmspam/cache22"
SUPPORT_URL="https://github.com/cmspam/cache22/issues"
BUG_REPORT_URL="https://github.com/cmspam/cache22/issues"
LOGO=cache22
EOF
ln -sf ../usr/lib/os-release "$ROOTFS/etc/os-release"

# /etc/issue: shown above the login prompt on TTYs
cat > "$ROOTFS/etc/issue" <<'EOF'

  cache22 Live Installer

  Login: cache22  (autologin on tty1)
  Run:   cache22-install   (new install)
         cache22-repair    (fix bootloader / redeploy, keep /home)

EOF
echo "cache22 Live Installer" > "$ROOTFS/etc/issue.net"

# /etc/motd: shown after login (SSH and interactive shells)
cat > "$ROOTFS/etc/motd" <<'EOF'

  ┌──────────────────────────────────────────────────────────┐
  │                  cache22 Live Installer                  │
  │                                                          │
  │   New install:        cache22-install                    │
  │   Reinstall + keep    cache22-repair                     │
  │     /home, /etc, …    (--help on either for details)     │
  │                                                          │
  │   `cache22-repair` reinstalls just the OS image bits     │
  │   (ostree repo, kernels, bootloader). Everything you've  │
  │   touched — /var, /home, /etc, user accounts, NM         │
  │   connections, SSH host keys — stays. Use it after an    │
  │   ESP wipe, format change, or whenever `bootc upgrade`   │
  │   can't move you to the new layout.                      │
  │                                                          │
  │   Image is pulled from ghcr.io at install/repair time,   │
  │   so this ISO doesn't need rebuilding for image updates. │
  │                                                          │
  │   GitHub: https://github.com/cmspam/cache22              │
  └──────────────────────────────────────────────────────────┘

EOF

# Hostname
echo "cache22-live" > "$ROOTFS/etc/hostname"

# SELinux off in /etc/selinux/config (kernel cmdline has selinux=0
# already; this is belt-and-braces for any userspace tools that
# would otherwise try to apply contexts).
[[ -f "$ROOTFS/etc/selinux/config" ]] && \
    sed -i 's/^SELINUX=.*/SELINUX=disabled/' "$ROOTFS/etc/selinux/config"

# Disable plymouth boot-splash (cosmetic, but it shows the Fedora
# logo). Kernel cmdline has rd.plymouth=0 plymouth.enable=0 too.
chroot "$ROOTFS" systemctl mask plymouth-start.service \
    plymouth-quit.service plymouth-quit-wait.service \
    plymouth-read-write.service >/dev/null 2>&1 || true

# Stub-resolv.conf is set up by systemd-resolved; remove the static
# /etc/resolv.conf we copied for chroot dnf so resolved manages it
# at runtime.
rm -f "$ROOTFS/etc/resolv.conf"

# ─── 5. Build initramfs with dmsquash-live in chroot ──────────────
echo "==> Building initramfs via dracut --add dmsquash-live"
KVER=$(basename "$(ls -d "$ROOTFS"/usr/lib/modules/*/ | head -1)")
[[ -n "$KVER" ]] || { echo "ERROR: no kernel found in $ROOTFS/usr/lib/modules/"; exit 1; }
echo "    kernel version: $KVER"

# /proc /sys /dev are already bind-mounted from the dnf install step.

# dracut produces /boot/initramfs-<kver>.img inside the chroot.
chroot "$ROOTFS" dracut \
    --no-hostonly \
    --add 'dmsquash-live' \
    --add-drivers 'squashfs overlay loop dm_mod sr_mod sd_mod ahci nvme xhci_hcd xhci_pci uhci_hcd ehci_hcd ehci_pci usb_storage virtio_blk virtio_net virtio_pci virtio_scsi vmw_pvscsi vmxnet3 e1000 e1000e r8169 igb iwlwifi rtw88_8822be ath10k_pci' \
    --reproducible \
    --kver "$KVER" \
    --force \
    "/boot/initramfs-${KVER}.img"

# ─── 6. mksquashfs the rootfs ─────────────────────────────────────
echo "==> Cleaning rootfs caches before squashfs"
# Trim what we don't need at runtime.
rm -rf "$ROOTFS/var/cache/dnf"/* \
       "$ROOTFS/var/log"/* \
       "$ROOTFS/var/tmp"/* \
       "$ROOTFS/tmp"/*

# Pull boot artifacts OUT of rootfs first (so the squashfs doesn't
# carry duplicates of vmlinuz / shim / grub).
mkdir -p "$WORK/boot"
cp "$ROOTFS/usr/lib/modules/${KVER}/vmlinuz"             "$WORK/boot/vmlinuz"
cp "$ROOTFS/boot/initramfs-${KVER}.img"                  "$WORK/boot/initramfs.img"
cp "$ROOTFS/boot/efi/EFI/fedora/shimx64.efi"             "$WORK/boot/shimx64.efi" 2>/dev/null \
    || cp "$ROOTFS"/usr/lib/efi/shim/*/EFI/fedora/shimx64.efi "$WORK/boot/shimx64.efi"
cp "$ROOTFS/boot/efi/EFI/fedora/mmx64.efi"               "$WORK/boot/mmx64.efi" 2>/dev/null \
    || cp "$ROOTFS"/usr/lib/efi/shim/*/EFI/fedora/mmx64.efi "$WORK/boot/mmx64.efi"
cp "$ROOTFS/boot/efi/EFI/fedora/grubx64.efi"             "$WORK/boot/grubx64.efi" 2>/dev/null \
    || cp "$ROOTFS"/usr/lib/efi/grub2/*/EFI/fedora/grubx64.efi "$WORK/boot/grubx64.efi"

for f in vmlinuz initramfs.img shimx64.efi mmx64.efi grubx64.efi; do
    [[ -f "$WORK/boot/$f" ]] || { echo "ERROR: missing $WORK/boot/$f"; exit 1; }
done

# unmount before squashfs so /proc /sys /dev contents aren't in the squashfs
for m in run dev sys proc; do umount -lR "$ROOTFS/$m" 2>/dev/null || true; done
trap - EXIT

echo "==> Building two-layer live image (squashfs containing LiveOS/rootfs.img)"
# dracut's dmsquash-live module specifically looks for
#   /run/initramfs/squashfs/LiveOS/rootfs.img
# inside the squashfs. A single-layer squashfs (rootfs directly) hits
# the "Failed to find a root filesystem in $SQUASHED" branch. Wrap the
# rootfs in an ext4 image, place it at LiveOS/rootfs.img, mksquashfs.
SQUASH_WORK=$(mktemp -d)
mkdir -p "$SQUASH_WORK/LiveOS"
ROOTFS_KB=$(du -sk "$ROOTFS" | awk '{print $1}')
ROOTFS_MB=$(( (ROOTFS_KB / 1024) + 256 ))
echo "    rootfs.img size: ${ROOTFS_MB}M"
truncate -s "${ROOTFS_MB}M" "$SQUASH_WORK/LiveOS/rootfs.img"
mkfs.ext4 -L Anaconda -F "$SQUASH_WORK/LiveOS/rootfs.img" >/dev/null
ROOTFS_MNT=$(mktemp -d)
mount -o loop "$SQUASH_WORK/LiveOS/rootfs.img" "$ROOTFS_MNT"
cp -a "$ROOTFS"/. "$ROOTFS_MNT/"
umount "$ROOTFS_MNT"
rmdir "$ROOTFS_MNT"

echo "==> mksquashfs (zstd, level 19) — this can take several minutes"
mkdir -p "$ISOROOT/LiveOS"
mksquashfs "$SQUASH_WORK" "$ISOROOT/LiveOS/squashfs.img" \
    -comp zstd -Xcompression-level 19 \
    -b 1M -no-xattrs -noappend
rm -rf "$SQUASH_WORK"
ls -lh "$ISOROOT/LiveOS/squashfs.img"

# ─── 7. Assemble ISO directory ────────────────────────────────────
echo "==> Assembling ISO directory tree"
mkdir -p "$ISOROOT/images" "$ISOROOT/EFI/BOOT" "$ISOROOT/EFI/fedora" "$ISOROOT/grub"

cp "$WORK/boot/vmlinuz"        "$ISOROOT/images/vmlinuz"
cp "$WORK/boot/initramfs.img"  "$ISOROOT/images/initramfs.img"

cp "$WORK/boot/shimx64.efi"    "$ISOROOT/EFI/BOOT/BOOTX64.EFI"
cp "$WORK/boot/grubx64.efi"    "$ISOROOT/EFI/BOOT/grubx64.efi"
cp "$WORK/boot/mmx64.efi"      "$ISOROOT/EFI/BOOT/mmx64.efi"

# Live boot menu — referenced by Fedora grub2 via $prefix=/EFI/fedora.
# Critical: $root starts as the ESP (where shim/grub live). The kernel
# and initramfs live on the iso9660 fs, NOT the ESP. The
# `search --label` line switches $root to the iso9660 volume before
# linuxefi/initrdefi resolve their paths.
#
# Kernel cmdline:
#   selinux=0 enforcing=0  — we built the rootfs without SELinux labels
#   audit=0                 — silences IMA-tagged audit messages on tty
#   rd.plymouth=0 plymouth.enable=0 — skip Fedora's boot splash entirely
#   quiet                   — keep tty clean; troubleshoot entry has the
#                             noise plus serial console for debugging
cat > "$ISOROOT/EFI/fedora/grub.cfg" <<EOF
function load_video { insmod all_video; }
function gfxmode { true; }
set timeout=3
set default=0

# Switch \$root from ESP → iso9660 fs (where /images/* lives).
search --no-floppy --set=root --label ${ISO_LABEL}

menuentry 'cache22 Installer (live)' {
    linuxefi /images/vmlinuz root=live:CDLABEL=${ISO_LABEL} rd.live.image selinux=0 enforcing=0 audit=0 quiet rd.plymouth=0 plymouth.enable=0
    initrdefi /images/initramfs.img
}

menuentry 'cache22 Installer (live, troubleshoot - rd.shell)' {
    linuxefi /images/vmlinuz root=live:CDLABEL=${ISO_LABEL} rd.live.image selinux=0 enforcing=0 audit=0 console=tty0 rd.shell rd.debug plymouth.enable=0
    initrdefi /images/initramfs.img
}
EOF
# Keep a copy at the conventional ISO9660 location too.
cp "$ISOROOT/EFI/fedora/grub.cfg" "$ISOROOT/grub/grub.cfg"

# ─── 8. Build EFI boot image (FAT) ─────────────────────────────────
# archiso rule: round used KiB up to the next full MiB, add 8 MiB
# buffer. mkfs.fat picks FAT32 only at ≥36 MiB; below that we get
# FAT16, which is what OVMF's FAT driver actually wants for a small
# ESP. Forcing FAT32 on a tiny volume produces an out-of-spec image
# (FAT32 needs ≥65525 clusters) that some firmwares refuse to mount.
echo "==> Building EFI boot image"
EFIIMG="$WORK/efiboot.img"
EFI_SIZE_KB=$(du -bcs "$ISOROOT/EFI" | tail -1 | awk \
    'function ceil(x){return int(x)+(x>int(x))}
     { kib=$1/1024; print int( ((ceil(kib/1024)*1024) + 8192) ) }')
MKFS_OPTS=(-C -n CACHE22EFI)
if (( EFI_SIZE_KB >= 36864 )); then
    MKFS_OPTS+=(-F 32)
fi
rm -f "$EFIIMG"
mkfs.fat "${MKFS_OPTS[@]}" "$EFIIMG" "$EFI_SIZE_KB" >/dev/null
mmd -i "$EFIIMG" ::/EFI ::/EFI/BOOT ::/EFI/fedora
mcopy -i "$EFIIMG" -s "$ISOROOT/EFI"/* ::/EFI/

# ─── 9. xorrisofs hybrid ISO (UEFI-only; SB-bootable on stock OEM) ──
# Critical: `-eltorito-alt-boot` BEFORE the `-e` line. Without it,
# xorriso mutates a placeholder/discarded El-Torito section instead
# of registering a real UEFI alt-entry; OVMF then sees no bootable
# option even though the ESP is present. lorax, mkarchiso, and
# titanoboa all use this flag in this exact position.
#
# `-iso_mbr_part_type` and `-append_partition` GUIDs match
# lorax/titanoboa exactly. Rock Ridge + Joliet so iso9660 paths
# round-trip correctly (Fedora's grub2 hardcodes `/EFI/fedora/grub.cfg`
# with that exact case).
echo "==> xorrisofs"
mkdir -p "$OUT"
FINAL_ISO="$OUT/${ISO_NAME}.iso"
xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -joliet -joliet-long \
    -rational-rock \
    -volid "$ISO_LABEL" \
    -appid 'cache22-installer' \
    -publisher 'cache22 <https://github.com/cmspam/cache22>' \
    -preparer 'cache22 build pipeline' \
    -partition_offset 16 \
    -appended_part_as_gpt \
    -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B "$EFIIMG" \
    -iso_mbr_part_type EBD0A0A2-B9E5-4433-87C0-68B6B72699C7 \
    -eltorito-alt-boot \
    -e --interval:appended_partition_2:all:: \
    -no-emul-boot \
    -eltorito-catalog 'EFI/boot.cat' \
    -o "$FINAL_ISO" \
    "$ISOROOT"

ls -lh "$FINAL_ISO"
sha256sum "$FINAL_ISO"
echo
echo "==> Done. ISO at $FINAL_ISO"
