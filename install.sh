#!/usr/bin/env bash
# Cache22 Installer
# Run from an Arch or CachyOS live environment as root

set -e

# ─────────────────────────────────────────────
# Colours and helpers
# ─────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${BLUE}==>${RESET} ${BOLD}$*${RESET}"; }
success() { echo -e "${GREEN}==>${RESET} ${BOLD}$*${RESET}"; }
warn()    { echo -e "${YELLOW}==>${RESET} $*"; }
error()   { echo -e "${RED}==>${RESET} ${BOLD}$*${RESET}" >&2; exit 1; }
confirm() {
    whiptail --yesno "$1" 10 60 --defaultno 2>/dev/null || return 1
    return 0
}

# ─────────────────────────────────────────────
# Global state
# ─────────────────────────────────────────────
DISK_BY_ID=""
PART_BOOT=""
PART_ROOT=""
PART_VAR=""
VAR_FS="xfs"
ENCRYPT_VAR=false
LUKS_PASS=""
HOSTNAME=""
TIMEZONE="Asia/Tokyo"
LOCALE="en_US"
ROOT_PASS=""
USERNAME=""
USER_PASS=""
IMAGE="ghcr.io/cmspam/cache22/cachyos:latest"
DISK_MODE=""   # wipe | freespace | manual
BTRFS_SUBVOLS=false

# ─────────────────────────────────────────────
# 1. PREFLIGHT
# ─────────────────────────────────────────────
preflight() {
    info "Running preflight checks..."

    [[ $EUID -ne 0 ]] && error "Must be run as root"

    [[ ! -d /sys/firmware/efi ]] && error "UEFI boot required. Not running in UEFI mode."

    if ! ping -c1 -W3 archlinux.org &>/dev/null; then
        error "No internet connection detected. Please connect and retry."
    fi

    info "Installing required tools..."
    pacman -Sy --noconfirm --needed \
        ostree podman git libnewt \
        dosfstools xfsprogs btrfs-progs \
        cryptsetup parted util-linux \
        whiptail 2>/dev/null || true

    success "Preflight complete"
}

# ─────────────────────────────────────────────
# 2. DISK SELECTION
# ─────────────────────────────────────────────
select_disk() {
    info "Scanning disks..."

    # Build list of disks using by-id paths
    local disk_list=()
    while IFS= read -r byid_path; do
        local dev
        dev=$(readlink -f "$byid_path")
        # Skip partitions
        [[ "$dev" =~ [0-9]p[0-9]+$ ]] && continue
        [[ "$dev" =~ [0-9]+$ && ! "$dev" =~ nvme ]] && continue
        local size
        size=$(lsblk -dno SIZE "$dev" 2>/dev/null || echo "?")
        local model
        model=$(lsblk -dno MODEL "$dev" 2>/dev/null | xargs || echo "")
        disk_list+=("$byid_path" "$model $size")
    done < <(ls /dev/disk/by-id/ | grep -v -- '-part' | sed 's|^|/dev/disk/by-id/|')

    [[ ${#disk_list[@]} -eq 0 ]] && error "No disks found in /dev/disk/by-id/"

    DISK_BY_ID=$(whiptail --title "Cache22 Installer" \
        --menu "Select target disk:" 20 78 10 \
        "${disk_list[@]}" 3>&1 1>&2 2>&3) || error "Disk selection cancelled"

    local dev
    dev=$(readlink -f "$DISK_BY_ID")
    info "Selected: $DISK_BY_ID → $dev"

    # Show current partition layout
    whiptail --title "Current layout of $dev" \
        --msgbox "$(lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$dev" 2>/dev/null)" \
        20 78 || true
}

# ─────────────────────────────────────────────
# 3. DISK MODE
# ─────────────────────────────────────────────
select_disk_mode() {
    DISK_MODE=$(whiptail --title "Disk Setup" \
        --menu "How would you like to set up the disk?" 15 70 3 \
        "wipe"      "Wipe entire disk and start fresh" \
        "freespace" "Use free space (existing partitions untouched)" \
        "manual"    "Manual — I will create partitions myself" \
        3>&1 1>&2 2>&3) || error "Cancelled"

    case "$DISK_MODE" in
        wipe)      disk_mode_wipe ;;
        freespace) disk_mode_freespace ;;
        manual)    disk_mode_manual ;;
    esac
}

# ─────────────────────────────────────────────
# Wipe mode
# ─────────────────────────────────────────────
disk_mode_wipe() {
    local dev
    dev=$(readlink -f "$DISK_BY_ID")

    confirm "WARNING: ALL data on $dev will be permanently erased. Continue?" \
        || error "Aborted by user"

    # Partition sizes
    local boot_size root_size
    boot_size=$(whiptail --inputbox "EFI partition size (e.g. 500MiB):" 8 50 "500MiB" \
        3>&1 1>&2 2>&3) || error "Cancelled"
    root_size=$(whiptail --inputbox "Root partition size (e.g. 50GiB):" 8 50 "50GiB" \
        3>&1 1>&2 2>&3) || error "Cancelled"

    info "Partitioning $dev..."
    parted -a optimal -s "$dev" -- \
        mklabel gpt \
        mkpart SYS_BOOT fat32 0% "$boot_size" \
        set 1 esp on \
        mkpart SYS_ROOT xfs "$boot_size" "$root_size" \
        mkpart SYS_VAR xfs "$root_size" 100%

    sleep 1
    partprobe "$dev"
    sleep 1

    _derive_part_paths "$dev"
    _format_partitions
}

# ─────────────────────────────────────────────
# Free space mode
# ─────────────────────────────────────────────
disk_mode_freespace() {
    local dev
    dev=$(readlink -f "$DISK_BY_ID")

    # Show free space info
    local free_info
    free_info=$(parted "$dev" unit MiB print free 2>/dev/null | grep "Free Space" || echo "Could not determine free space")

    whiptail --title "Free Space on $dev" \
        --msgbox "Free space available:\n\n$free_info\n\nThe installer will create three new partitions in the free space.\nExisting partitions will NOT be touched." \
        18 70 || true

    local boot_size root_size
    boot_size=$(whiptail --inputbox "EFI partition size (e.g. 500MiB):" 8 50 "500MiB" \
        3>&1 1>&2 2>&3) || error "Cancelled"
    root_size=$(whiptail --inputbox "Root partition size (e.g. 50GiB):" 8 50 "50GiB" \
        3>&1 1>&2 2>&3) || error "Cancelled"

    # Find the start of largest free space block
    local free_start
    free_start=$(parted "$dev" unit MiB print free 2>/dev/null \
        | awk '/Free Space/ {print $1}' \
        | sed 's/MiB//' \
        | sort -n \
        | tail -1)

    [[ -z "$free_start" ]] && error "Could not find free space on $dev"

    local boot_end root_end
    boot_end="${free_start}MiB + $boot_size"
    # Let parted calculate end points relative to start
    local p1_start="${free_start}MiB"
    local p1_end="$((free_start + ${boot_size%MiB}))MiB"
    local p2_end="$((free_start + ${boot_size%MiB} + ${root_size%GiB} * 1024))MiB"

    info "Creating partitions in free space starting at ${free_start}MiB..."
    parted -a optimal -s "$dev" -- \
        mkpart SYS_BOOT fat32 "${p1_start}" "${p1_end}" \
        set "$(parted "$dev" print | grep SYS_BOOT | awk '{print $1}')" esp on \
        mkpart SYS_ROOT xfs "${p1_end}" "${p2_end}" \
        mkpart SYS_VAR xfs "${p2_end}" 100%

    sleep 1
    partprobe "$dev"
    sleep 1

    _derive_part_paths "$dev"
    _format_partitions
}

# ─────────────────────────────────────────────
# Manual mode
# ─────────────────────────────────────────────
disk_mode_manual() {
    whiptail --title "Manual Partitioning" \
        --msgbox "Please create the following labeled partitions manually:\n
  SYS_BOOT  FAT32   EFI partition     (min 500MB, set esp flag)
  SYS_ROOT  XFS     Root partition    (min 20GB, recommended 50GB)
  SYS_VAR   XFS     User data         (rest of disk)

If you want encryption on /var, create a LUKS container
and format the inside as XFS or Btrfs. Label the LUKS
container itself SYS_VAR_CRYPT instead of SYS_VAR.

Open another terminal and partition the disk, then
press OK to continue." \
        22 70 || true

    # Wait for user to partition
    whiptail --title "Ready?" \
        --msgbox "Press OK when partitioning is complete." \
        8 50 || true

    # Verify labels
    info "Verifying partition labels..."
    local missing=()
    for label in SYS_BOOT SYS_ROOT; do
        [[ ! -e "/dev/disk/by-label/$label" ]] && missing+=("$label")
    done

    # Either SYS_VAR or SYS_VAR_CRYPT must exist
    if [[ ! -e /dev/disk/by-label/SYS_VAR ]] && \
       [[ ! -e /dev/disk/by-label/SYS_VAR_CRYPT ]]; then
        missing+=("SYS_VAR or SYS_VAR_CRYPT")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required partition labels: ${missing[*]}"
    fi

    # Set partition paths from labels
    PART_BOOT=$(readlink -f /dev/disk/by-label/SYS_BOOT)
    PART_ROOT=$(readlink -f /dev/disk/by-label/SYS_ROOT)

    if [[ -e /dev/disk/by-label/SYS_VAR_CRYPT ]]; then
        PART_VAR=$(readlink -f /dev/disk/by-label/SYS_VAR_CRYPT)
        ENCRYPT_VAR=true
        _ask_luks_pass_existing
    else
        PART_VAR=$(readlink -f /dev/disk/by-label/SYS_VAR)
        # Ask if they encrypted it themselves
        if confirm "Did you encrypt the /var partition with LUKS?"; then
            ENCRYPT_VAR=true
            _ask_luks_pass_existing
        fi
    fi

    # Get var filesystem type
    if [[ "$ENCRYPT_VAR" == true ]]; then
        local inner_dev="/dev/mapper/sys_var_check"
        cryptsetup open "$PART_VAR" sys_var_check --key-file <(echo "$LUKS_PASS") 2>/dev/null || true
        VAR_FS=$(blkid -o value -s TYPE /dev/mapper/sys_var_check 2>/dev/null || echo "xfs")
        cryptsetup close sys_var_check 2>/dev/null || true
    else
        VAR_FS=$(blkid -o value -s TYPE "$PART_VAR" 2>/dev/null || echo "xfs")
    fi

    success "Manual partition verification complete"
}

# ─────────────────────────────────────────────
# Helpers for partition paths and formatting
# ─────────────────────────────────────────────
_derive_part_paths() {
    local dev="$1"
    # Handle nvme (nvme0n1p1) vs sda (sda1) naming
    if echo "$dev" | grep -q "nvme\|mmcblk"; then
        PART_BOOT="${DISK_BY_ID}-part1"
        PART_ROOT="${DISK_BY_ID}-part2"
        PART_VAR="${DISK_BY_ID}-part3"
    else
        PART_BOOT="${DISK_BY_ID}-part1"
        PART_ROOT="${DISK_BY_ID}-part2"
        PART_VAR="${DISK_BY_ID}-part3"
    fi
}

_format_partitions() {
    info "Formatting EFI partition..."
    mkfs.vfat -n SYS_BOOT -F 32 "$(readlink -f "$PART_BOOT")"

    info "Formatting root partition (XFS)..."
    mkfs.xfs -L SYS_ROOT -f "$(readlink -f "$PART_ROOT")" -n ftype=1

    _ask_var_options
}

# ─────────────────────────────────────────────
# 4. /var OPTIONS (filesystem + encryption)
# ─────────────────────────────────────────────
_ask_var_options() {
    # Filesystem
    VAR_FS=$(whiptail --title "/var Filesystem" \
        --menu "Choose filesystem for /var (user data):" 12 60 2 \
        "xfs"   "XFS — simple, reliable (recommended)" \
        "btrfs" "Btrfs — copy-on-write, subvolumes" \
        3>&1 1>&2 2>&3) || error "Cancelled"

    if [[ "$VAR_FS" == "btrfs" ]]; then
        confirm "Create Btrfs subvolumes (@home, @log) for /var?" \
            && BTRFS_SUBVOLS=true || BTRFS_SUBVOLS=false
    fi

    # Encryption
    if confirm "Encrypt /var with LUKS? (recommended for user data)"; then
        ENCRYPT_VAR=true
        _ask_luks_pass_new
    fi

    _format_var
}

_ask_luks_pass_new() {
    while true; do
        LUKS_PASS=$(whiptail --passwordbox "Enter LUKS passphrase for /var:" 8 50 \
            3>&1 1>&2 2>&3) || error "Cancelled"
        local confirm_pass
        confirm_pass=$(whiptail --passwordbox "Confirm LUKS passphrase:" 8 50 \
            3>&1 1>&2 2>&3) || error "Cancelled"
        [[ "$LUKS_PASS" == "$confirm_pass" ]] && break
        whiptail --msgbox "Passphrases do not match. Try again." 8 50 || true
    done
}

_ask_luks_pass_existing() {
    LUKS_PASS=$(whiptail --passwordbox "Enter LUKS passphrase for /var:" 8 50 \
        3>&1 1>&2 2>&3) || error "Cancelled"
}

_format_var() {
    local var_dev
    var_dev=$(readlink -f "$PART_VAR")

    if [[ "$ENCRYPT_VAR" == true ]]; then
        info "Setting up LUKS encryption on /var..."
        echo -n "$LUKS_PASS" | cryptsetup luksFormat \
            --label SYS_VAR_CRYPT \
            --type luks2 \
            "$var_dev" -
        echo -n "$LUKS_PASS" | cryptsetup open "$var_dev" sys_var -
        local format_target="/dev/mapper/sys_var"
    else
        local format_target="$var_dev"
    fi

    if [[ "$VAR_FS" == "btrfs" ]]; then
        info "Formatting /var as Btrfs..."
        mkfs.btrfs -L SYS_VAR -f "$format_target"
        if [[ "$BTRFS_SUBVOLS" == true ]]; then
            info "Creating Btrfs subvolumes..."
            mount "$format_target" /mnt/btrfs_tmp
            btrfs subvolume create /mnt/btrfs_tmp/@home
            btrfs subvolume create /mnt/btrfs_tmp/@log
            umount /mnt/btrfs_tmp
            rmdir /mnt/btrfs_tmp 2>/dev/null || true
        fi
    else
        info "Formatting /var as XFS..."
        mkfs.xfs -L SYS_VAR -f "$format_target" -n ftype=1
    fi

    success "Partitions formatted"
}

# ─────────────────────────────────────────────
# 5. SYSTEM CONFIGURATION
# ─────────────────────────────────────────────
system_config() {
    # Hostname
    HOSTNAME=$(whiptail --inputbox "Enter hostname:" 8 50 "cache22" \
        3>&1 1>&2 2>&3) || error "Cancelled"

    # Timezone
    local tz_list=()
    while IFS= read -r tz; do
        tz_list+=("$tz" "")
    done < <(timedatectl list-timezones 2>/dev/null || \
        find /usr/share/zoneinfo -type f | sed 's|/usr/share/zoneinfo/||' | sort)

    TIMEZONE=$(whiptail --title "Timezone" \
        --menu "Select timezone:" 20 60 12 \
        "${tz_list[@]}" 3>&1 1>&2 2>&3) || error "Cancelled"

    # Locale
    LOCALE=$(whiptail --title "Locale" \
        --menu "Select locale:" 15 60 4 \
        "en_US" "English (US)" \
        "en_GB" "English (UK)" \
        "ja_JP" "Japanese" \
        "de_DE" "German" \
        3>&1 1>&2 2>&3) || error "Cancelled"

    # Root password
    while true; do
        ROOT_PASS=$(whiptail --passwordbox "Enter root password:" 8 50 \
            3>&1 1>&2 2>&3) || error "Cancelled"
        local confirm_pass
        confirm_pass=$(whiptail --passwordbox "Confirm root password:" 8 50 \
            3>&1 1>&2 2>&3) || error "Cancelled"
        [[ "$ROOT_PASS" == "$confirm_pass" ]] && break
        whiptail --msgbox "Passwords do not match. Try again." 8 50 || true
    done

    # First user
    USERNAME=$(whiptail --inputbox "Enter username for first user:" 8 50 \
        3>&1 1>&2 2>&3) || error "Cancelled"

    while true; do
        USER_PASS=$(whiptail --passwordbox "Enter password for $USERNAME:" 8 50 \
            3>&1 1>&2 2>&3) || error "Cancelled"
        local confirm_pass
        confirm_pass=$(whiptail --passwordbox "Confirm password for $USERNAME:" 8 50 \
            3>&1 1>&2 2>&3) || error "Cancelled"
        [[ "$USER_PASS" == "$confirm_pass" ]] && break
        whiptail --msgbox "Passwords do not match. Try again." 8 50 || true
    done
}

# ─────────────────────────────────────────────
# 6. IMAGE SELECTION
# ─────────────────────────────────────────────
image_select() {
    local choice
    choice=$(whiptail --title "Image Source" \
        --menu "Which image to install?" 12 70 2 \
        "remote" "Pull latest from GHCR (ghcr.io/cmspam/cache22/cachyos)" \
        "local"  "Use locally built image (localhost/cache22/cachyos)" \
        3>&1 1>&2 2>&3) || error "Cancelled"

    if [[ "$choice" == "local" ]]; then
        IMAGE="localhost/cache22/cachyos:latest"
    else
        IMAGE="ghcr.io/cmspam/cache22/cachyos:latest"
    fi

    info "Using image: $IMAGE"
}

# ─────────────────────────────────────────────
# 7. CONFIRMATION SUMMARY
# ─────────────────────────────────────────────
confirm_install() {
    local dev
    dev=$(readlink -f "$DISK_BY_ID")

    local summary="Installation Summary
─────────────────────────────
Disk:       $DISK_BY_ID
Mode:       $DISK_MODE
EFI:        $PART_BOOT
Root:       $PART_ROOT (XFS)
/var:       $PART_VAR ($VAR_FS)"

    [[ "$ENCRYPT_VAR" == true ]] && summary+="\nEncrypt /var: YES (LUKS2)"
    [[ "$BTRFS_SUBVOLS" == true ]] && summary+="\nBtrfs subvols: @home, @log"

    summary+="
─────────────────────────────
Hostname:   $HOSTNAME
Timezone:   $TIMEZONE
Locale:     $LOCALE
User:       $USERNAME (wheel)
Image:      $IMAGE
─────────────────────────────

Proceed with installation?"

    whiptail --title "Confirm Installation" \
        --yesno "$summary" 28 60 || error "Installation cancelled by user"
}

# ─────────────────────────────────────────────
# 8. INSTALLATION
# ─────────────────────────────────────────────
do_install() {
    local dev
    dev=$(readlink -f "$DISK_BY_ID")
    local part_boot part_root part_var
    part_boot=$(readlink -f "$PART_BOOT")
    part_root=$(readlink -f "$PART_ROOT")
    part_var=$(readlink -f "$PART_VAR")

    # Mount root and boot
    info "Mounting partitions..."
    mkdir -p /mnt
    mount "$part_root" /mnt
    mkdir -p /mnt/boot/efi
    mount "$part_boot" /mnt/boot/efi

    # Open LUKS if needed
    if [[ "$ENCRYPT_VAR" == true ]]; then
        if ! cryptsetup status sys_var &>/dev/null; then
            echo -n "$LUKS_PASS" | cryptsetup open "$part_var" sys_var -
        fi
    fi

    # Fix container storage for live environment
    info "Configuring container storage..."
    mkdir -p /etc/containers
    [[ ! -f /etc/containers/storage.conf ]] && \
        cp /usr/share/containers/storage.conf /etc/containers/storage.conf 2>/dev/null || true
    sed -i -e "s|^\(graphroot\s*=\s*\).*|\1\"/mnt/setup/container-storage\"|g" \
        /etc/containers/storage.conf 2>/dev/null || true
    mkdir -p /mnt/setup/container-tmp

    # Initialize OSTree
    info "Initializing OSTree repository..."
    ostree admin init-fs --sysroot=/mnt --modern /mnt
    ostree admin stateroot-init --sysroot=/mnt cache22
    ostree init --repo=/mnt/ostree/repo --mode=bare
    ostree config --repo=/mnt/ostree/repo set sysroot.bootprefix true

    # Pull image
    if [[ "$IMAGE" == ghcr* ]]; then
        info "Pulling image from GHCR (this will take a while)..."
        podman pull "$IMAGE"
    fi

    # Export and commit
    info "Exporting container image to rootfs..."
    mkdir -p /mnt/setup/rootfs
    podman export $(podman create "$IMAGE" sh) | tar -xC /mnt/setup/rootfs

    info "Creating OSTree filesystem layout..."
    touch /mnt/setup/rootfs/etc/machine-id
    mv /mnt/setup/rootfs/etc /mnt/setup/rootfs/usr/
    rm -rf /mnt/setup/rootfs/home
    ln -s /var/home /mnt/setup/rootfs/home
    ln -s /var/scratch /mnt/setup/rootfs/scratch
    rm -rf /mnt/setup/rootfs/mnt
    ln -s /var/mnt /mnt/setup/rootfs/mnt
    rm -rf /mnt/setup/rootfs/root
    ln -s /var/roothome /mnt/setup/rootfs/root
    rm -rf /mnt/setup/rootfs/srv
    ln -s /var/srv /mnt/setup/rootfs/srv
    mkdir -p /mnt/setup/rootfs/sysroot
    ln -s /sysroot/ostree /mnt/setup/rootfs/ostree
    rm -rf /mnt/setup/rootfs/usr/local
    ln -s /var/usrlocal /mnt/setup/rootfs/usr/local

    # tmpfiles
    cat >> /mnt/setup/rootfs/usr/lib/tmpfiles.d/ostree-0-integration.conf << 'TMPFILES'
d /var/home 0755 root root -
d /var/scratch/users 0755 root root -
d /var/lib 0755 root root -
d /var/log/journal 0755 root root -
d /var/mnt 0755 root root -
d /var/opt 0755 root root -
d /var/roothome 0700 root root -
d /var/srv 0755 root root -
d /var/usrlocal 0755 root root -
d /var/usrlocal/bin 0755 root root -
d /var/usrlocal/etc 0755 root root -
d /var/usrlocal/games 0755 root root -
d /var/usrlocal/include 0755 root root -
d /var/usrlocal/lib 0755 root root -
d /var/usrlocal/man 0755 root root -
d /var/usrlocal/sbin 0755 root root -
d /var/usrlocal/share 0755 root root -
d /var/usrlocal/src 0755 root root -
d /run/media 0755 root root -
TMPFILES

    mv /mnt/setup/rootfs/var/lib/pacman /mnt/setup/rootfs/usr/lib/
    sed -i \
        -e "s|^#\(DBPath\s*=\s*\).*|\1/usr/lib/pacman|g" \
        -e "s|^#\(IgnoreGroup\s*=\s*\).*|\1modified|g" \
        /mnt/setup/rootfs/usr/etc/pacman.conf

    rm -rf /mnt/setup/rootfs/var/*

    chmod u-s /mnt/setup/rootfs/usr/bin/newgidmap \
              /mnt/setup/rootfs/usr/bin/newuidmap
    setcap cap_setuid+eip /mnt/setup/rootfs/usr/bin/newuidmap
    setcap cap_setgid+eip /mnt/setup/rootfs/usr/bin/newgidmap

    # Write machine-specific /etc files into the rootfs before commit
    _write_etc_files

    # Commit to OSTree
    info "Committing to OSTree..."
    ostree commit \
        --repo=/mnt/ostree/repo \
        --branch=cache22/x86_64/standard \
        --tree=dir=/mnt/setup/rootfs

    # Build kargs
    local kargs="root=LABEL=SYS_ROOT rw"
    if [[ -f /mnt/setup/rootfs/usr/share/cache22/.karg ]]; then
        while IFS= read -r karg; do
            kargs="$kargs $karg"
        done < /mnt/setup/rootfs/usr/share/cache22/.karg
    fi

    # Add LUKS karg if encrypted
    if [[ "$ENCRYPT_VAR" == true ]]; then
        local luks_uuid
        luks_uuid=$(cryptsetup luksUUID "$part_var")
        kargs="$kargs rd.luks.name=${luks_uuid}=sys_var"
    fi

    # Deploy
    info "Deploying OSTree..."
    ostree admin deploy \
        --sysroot=/mnt \
        --karg-none \
        --karg="$kargs" \
        --os=cache22 \
        --retain \
        cache22/x86_64/standard 2>&1 | grep -v "grub2-mkconfig\|Bootloader write" || true

    # Install GRUB and generate config
    _install_grub "$dev" "$part_root"

    # Create user in deployed system
    _create_user

    success "Installation complete!"
}

# ─────────────────────────────────────────────
# Write machine-specific /etc files
# ─────────────────────────────────────────────
_write_etc_files() {
    local etc="/mnt/setup/rootfs/usr/etc"

    # Hostname
    echo "$HOSTNAME" > "$etc/hostname"

    # Timezone
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$etc/localtime"

    # Locale
    echo "LANG=${LOCALE}.UTF-8" > "$etc/locale.conf"
    echo "${LOCALE}.UTF-8 UTF-8" > "$etc/locale.gen"

    # fstab — write appropriate version
    {
        echo "LABEL=SYS_ROOT /         auto  rw,relatime 0 1"
        echo "LABEL=SYS_BOOT /boot/efi vfat  rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro 0 2"
        if [[ "$ENCRYPT_VAR" == true ]]; then
            echo "/dev/mapper/sys_var /var auto rw,relatime 0 2"
        else
            echo "LABEL=SYS_VAR  /var  auto  rw,relatime 0 2"
        fi
        if [[ "$VAR_FS" == "btrfs" && "$BTRFS_SUBVOLS" == true ]]; then
            echo "# Btrfs subvolumes managed automatically"
        fi
    } > "$etc/fstab"

    # crypttab if encrypted
    if [[ "$ENCRYPT_VAR" == true ]]; then
        echo "sys_var  LABEL=SYS_VAR_CRYPT  none  luks,timeout=90" > "$etc/crypttab"
    fi
}

# ─────────────────────────────────────────────
# Install GRUB
# ─────────────────────────────────────────────
_install_grub() {
    local dev="$1" part_root="$2"

    info "Installing GRUB..."
    local deploy
    deploy=$(ls -d /mnt/ostree/deploy/cache22/deploy/*.0 | grep -v origin | head -1)

    mkdir -p "$deploy/sysroot/ostree"
    mkdir -p "$deploy/boot/efi/EFI/grub"
    mount --bind /dev "$deploy/dev"
    mount --bind /proc "$deploy/proc"
    mount --bind /sys "$deploy/sys"
    mount --rbind /mnt/boot "$deploy/boot"
    mount --rbind /mnt/ostree "$deploy/sysroot/ostree"

    export GRUB_DEVICE=LABEL=SYS_ROOT
    export GRUB_DEVICE_BOOT=LABEL=SYS_BOOT
    export GRUB_DEVICE_UUID=$(blkid -s UUID -o value "$part_root")

    chroot "$deploy" grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --removable \
        --boot-directory=/boot/efi/EFI \
        --bootloader-id=cache22 \
        "$dev" || warn "grub-install had warnings (may be ok)"

    chroot "$deploy" grub-mkconfig -o /boot/efi/EFI/grub/grub.cfg

    local count
    count=$(grep -c "ostree" /mnt/boot/efi/EFI/grub/grub.cfg 2>/dev/null || echo 0)
    [[ "$count" -gt 0 ]] && success "GRUB configured with $count OSTree references" \
        || error "GRUB config has no OSTree entries — something went wrong"
}

# ─────────────────────────────────────────────
# Create user in deployed system
# ─────────────────────────────────────────────
_create_user() {
    info "Creating user $USERNAME..."
    local deploy
    deploy=$(ls -d /mnt/ostree/deploy/cache22/deploy/*.0 | grep -v origin | head -1)

    # Set root password
    echo "root:${ROOT_PASS}" | chroot "$deploy" chpasswd

    # Create user
    chroot "$deploy" useradd -m -G wheel -s /bin/bash "$USERNAME"
    echo "${USERNAME}:${USER_PASS}" | chroot "$deploy" chpasswd

    success "User $USERNAME created"
}

# ─────────────────────────────────────────────
# 9. CLEANUP AND REBOOT
# ─────────────────────────────────────────────
cleanup() {
    info "Cleaning up..."
    umount -R -l /mnt 2>/dev/null || true
    [[ "$ENCRYPT_VAR" == true ]] && \
        cryptsetup close sys_var 2>/dev/null || true

    whiptail --title "Installation Complete" \
        --msgbox "Cache22 has been installed successfully!\n\nHostname:  $HOSTNAME\nUser:      $USERNAME\nTimezone:  $TIMEZONE\n\nRemove installation media and reboot.\nSelect Cache22 from your UEFI boot menu." \
        18 60 || true

    confirm "Reboot now?" && systemctl reboot || true
}

# ─────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────
main() {
    clear
    whiptail --title "Cache22 Installer" \
        --msgbox "Welcome to the Cache22 installer.\n\nThis will guide you through installing Cache22,\nan immutable Arch/CachyOS-based desktop system.\n\nPress OK to begin." \
        14 60 || exit 0

    preflight
    select_disk
    select_disk_mode
    system_config
    image_select
    confirm_install
    do_install
    cleanup
}

main "$@"
