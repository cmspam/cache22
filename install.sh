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
DISK_MODE=""
BTRFS_SUBVOLS=false
VAR_DEVICE=""  # final block device for /var (mapper or raw partition)

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
        cryptsetup parted util-linux 2>/dev/null || true

    success "Preflight complete"
}

# ─────────────────────────────────────────────
# 2. DISK SELECTION
# ─────────────────────────────────────────────
select_disk() {
    info "Scanning disks..."

    local disk_list=()
    while IFS= read -r byid_path; do
        local dev
        dev=$(readlink -f "$byid_path")
        # Skip partition entries
        [[ "$dev" =~ p[0-9]+$ ]] && continue
        [[ "$dev" =~ [^0-9][0-9]+$ && ! "$dev" =~ nvme ]] && continue
        local size model
        size=$(lsblk -dno SIZE "$dev" 2>/dev/null || echo "?")
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

disk_mode_wipe() {
    local dev
    dev=$(readlink -f "$DISK_BY_ID")

    confirm "WARNING: ALL data on $dev will be permanently erased. Continue?" \
        || error "Aborted by user"

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

    sleep 2
    partprobe "$dev"
    sleep 2

    _derive_part_paths "$dev"
    _format_efi_and_root
    _ask_var_options
}

disk_mode_freespace() {
    local dev
    dev=$(readlink -f "$DISK_BY_ID")

    local free_info
    free_info=$(parted "$dev" unit MiB print free 2>/dev/null \
        | grep "Free Space" || echo "Could not determine free space")

    whiptail --title "Free Space on $dev" \
        --msgbox "Free space available:\n\n$free_info\n\nThree new partitions will be created in the free space.\nExisting partitions will NOT be touched." \
        18 70 || true

    local boot_size root_size
    boot_size=$(whiptail --inputbox "EFI partition size (e.g. 500MiB):" 8 50 "500MiB" \
        3>&1 1>&2 2>&3) || error "Cancelled"
    root_size=$(whiptail --inputbox "Root partition size (e.g. 50GiB):" 8 50 "50GiB" \
        3>&1 1>&2 2>&3) || error "Cancelled"

    local free_start
    free_start=$(parted "$dev" unit MiB print free 2>/dev/null \
        | awk '/Free Space/ {gsub(/MiB/,"",$1); print $1}' \
        | sort -n | tail -1)
    [[ -z "$free_start" ]] && error "Could not find free space on $dev"

    local boot_mb root_mb
    boot_mb=${boot_size%MiB}
    root_mb=$(( ${root_size%GiB} * 1024 ))

    local p1_start p1_end p2_end
    p1_start="${free_start}MiB"
    p1_end="$(( free_start + boot_mb ))MiB"
    p2_end="$(( free_start + boot_mb + root_mb ))MiB"

    info "Creating partitions in free space starting at ${free_start}MiB..."
    parted -a optimal -s "$dev" -- \
        mkpart SYS_BOOT fat32 "$p1_start" "$p1_end" \
        mkpart SYS_ROOT xfs   "$p1_end"   "$p2_end" \
        mkpart SYS_VAR  xfs   "$p2_end"   100%

    local boot_partnum
    boot_partnum=$(parted "$dev" print 2>/dev/null | awk '/SYS_BOOT/ {print $1}')
    [[ -n "$boot_partnum" ]] && parted "$dev" set "$boot_partnum" esp on || true

    sleep 2
    partprobe "$dev"
    sleep 2

    _derive_part_paths "$dev"
    _format_efi_and_root
    _ask_var_options
}

disk_mode_manual() {
    whiptail --title "Manual Partitioning" \
        --msgbox "Please create the following labeled partitions manually:\n
  SYS_BOOT  FAT32   EFI partition     (min 500MB, set esp flag)
  SYS_ROOT  XFS     Root partition    (min 20GB, recommended 50GB)
  SYS_VAR   any     User data         (rest of disk)

If you want LUKS encryption on /var, create the LUKS
container and label it SYS_VAR_CRYPT. Format the inside
as XFS or Btrfs — do NOT label the inner filesystem,
the installer will handle that.

If no encryption, label the partition SYS_VAR and
format it as XFS or Btrfs.

Open another terminal, partition the disk, then
press OK to continue." \
        24 70 || true

    whiptail --title "Ready?" \
        --msgbox "Press OK when partitioning is complete." \
        8 50 || true

    info "Verifying partition labels..."
    local missing=()
    for label in SYS_BOOT SYS_ROOT; do
        [[ ! -e "/dev/disk/by-label/$label" ]] && missing+=("$label")
    done
    if [[ ! -e /dev/disk/by-label/SYS_VAR ]] && \
       [[ ! -e /dev/disk/by-label/SYS_VAR_CRYPT ]]; then
        missing+=("SYS_VAR or SYS_VAR_CRYPT")
    fi
    [[ ${#missing[@]} -gt 0 ]] && error "Missing required partition labels: ${missing[*]}"

    PART_BOOT=$(readlink -f /dev/disk/by-label/SYS_BOOT)
    PART_ROOT=$(readlink -f /dev/disk/by-label/SYS_ROOT)

    if [[ -e /dev/disk/by-label/SYS_VAR_CRYPT ]]; then
        PART_VAR=$(readlink -f /dev/disk/by-label/SYS_VAR_CRYPT)
        ENCRYPT_VAR=true
        _ask_luks_pass_existing
        info "Opening LUKS device..."
        echo -n "$LUKS_PASS" | cryptsetup open "$PART_VAR" sys_var -
        VAR_DEVICE="/dev/mapper/sys_var"
    else
        PART_VAR=$(readlink -f /dev/disk/by-label/SYS_VAR)
        VAR_DEVICE="$PART_VAR"
        if confirm "Did you encrypt the /var partition with LUKS?"; then
            ENCRYPT_VAR=true
            _ask_luks_pass_existing
            echo -n "$LUKS_PASS" | cryptsetup open "$PART_VAR" sys_var -
            VAR_DEVICE="/dev/mapper/sys_var"
        fi
    fi

    # Detect filesystem on the (possibly unlocked) device
    VAR_FS=$(blkid -o value -s TYPE "$VAR_DEVICE" 2>/dev/null || echo "xfs")
    info "Detected /var filesystem: $VAR_FS"

    # If Btrfs, ask about subvolumes
    if [[ "$VAR_FS" == "btrfs" ]]; then
        confirm "Use Btrfs subvolumes (@, @home, @log) for /var?" \
            && BTRFS_SUBVOLS=true || BTRFS_SUBVOLS=false
        if [[ "$BTRFS_SUBVOLS" == true ]]; then
            _create_btrfs_subvolumes
        fi
    fi

    success "Manual partition verification complete"
}

# ─────────────────────────────────────────────
# Derive partition paths from disk by-id
# ─────────────────────────────────────────────
_derive_part_paths() {
    local dev="$1"
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

# ─────────────────────────────────────────────
# Format EFI and root (always XFS)
# ─────────────────────────────────────────────
_format_efi_and_root() {
    info "Formatting EFI partition..."
    mkfs.vfat -n SYS_BOOT -F 32 "$(readlink -f "$PART_BOOT")"

    info "Formatting root partition (XFS)..."
    mkfs.xfs -L SYS_ROOT -f "$(readlink -f "$PART_ROOT")" -n ftype=1
}

# ─────────────────────────────────────────────
# /var options — filesystem, subvolumes, encryption
# ─────────────────────────────────────────────
_ask_var_options() {
    VAR_FS=$(whiptail --title "/var Filesystem" \
        --menu "Choose filesystem for /var (user data):" 12 60 2 \
        "xfs"   "XFS — simple, reliable (recommended)" \
        "btrfs" "Btrfs — copy-on-write, compression" \
        3>&1 1>&2 2>&3) || error "Cancelled"

    if [[ "$VAR_FS" == "btrfs" ]]; then
        confirm "Create Btrfs subvolumes (@, @home, @log) for /var?" \
            && BTRFS_SUBVOLS=true || BTRFS_SUBVOLS=false
    fi

    if confirm "Encrypt /var with LUKS? (recommended — protects your personal data)"; then
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
        info "Setting up LUKS2 encryption on /var..."
        echo -n "$LUKS_PASS" | cryptsetup luksFormat \
            --label SYS_VAR_CRYPT \
            --type luks2 \
            "$var_dev" -
        info "Opening LUKS device..."
        echo -n "$LUKS_PASS" | cryptsetup open "$var_dev" sys_var -
        VAR_DEVICE="/dev/mapper/sys_var"
    else
        VAR_DEVICE="$var_dev"
    fi

    if [[ "$VAR_FS" == "btrfs" ]]; then
        info "Formatting /var as Btrfs..."
        # Label goes on the Btrfs filesystem (inside LUKS if encrypted)
        mkfs.btrfs -L SYS_VAR -f "$VAR_DEVICE"
        if [[ "$BTRFS_SUBVOLS" == true ]]; then
            _create_btrfs_subvolumes
        fi
    else
        info "Formatting /var as XFS..."
        mkfs.xfs -L SYS_VAR -f "$VAR_DEVICE" -n ftype=1
    fi

    success "/var partition ready"
}

_create_btrfs_subvolumes() {
    info "Creating Btrfs subvolumes (@, @home, @log)..."
    local tmp="/mnt/btrfs_setup"
    mkdir -p "$tmp"

    # Mount top-level Btrfs to create subvolumes
    mount -o defaults,noatime "$VAR_DEVICE" "$tmp"

    # Create subvolumes
    btrfs subvolume create "$tmp/@"
    btrfs subvolume create "$tmp/@home"
    btrfs subvolume create "$tmp/@log"

    # Disable copy-on-write for @log (good for log files and databases)
    # We do this after creating the subvolume by setting the nodatacow flag
    # on a placeholder directory inside it
    mount -o defaults,noatime,subvol=/@log "$VAR_DEVICE" "$tmp/log_tmp" 2>/dev/null || {
        mkdir -p "$tmp/log_tmp"
        mount -o defaults,noatime,subvol=/@log "$VAR_DEVICE" "$tmp/log_tmp"
    }
    chattr +C "$tmp/log_tmp" 2>/dev/null || true
    umount "$tmp/log_tmp" 2>/dev/null || true
    rmdir "$tmp/log_tmp" 2>/dev/null || true

    umount "$tmp"
    rmdir "$tmp"

    info "Btrfs subvolumes created: @, @home, @log"
}

# ─────────────────────────────────────────────
# 4. SYSTEM CONFIGURATION
# ─────────────────────────────────────────────
system_config() {
    HOSTNAME=$(whiptail --inputbox "Enter hostname:" 8 50 "cache22" \
        3>&1 1>&2 2>&3) || error "Cancelled"

    local tz_list=()
    while IFS= read -r tz; do
        tz_list+=("$tz" "")
    done < <(timedatectl list-timezones 2>/dev/null || \
        find /usr/share/zoneinfo -type f \
            ! -name "*.list" \
            ! -name "*.tab" \
            ! -name "posixrules" \
            ! -name "localtime" \
        | sed 's|/usr/share/zoneinfo/||' | sort)

    TIMEZONE=$(whiptail --title "Timezone" \
        --menu "Select timezone:" 20 60 12 \
        "${tz_list[@]}" 3>&1 1>&2 2>&3) || error "Cancelled"

    LOCALE=$(whiptail --title "Locale" \
        --menu "Select locale:" 15 60 4 \
        "en_US" "English (US)" \
        "en_GB" "English (UK)" \
        "ja_JP" "Japanese" \
        "de_DE" "German" \
        3>&1 1>&2 2>&3) || error "Cancelled"

    while true; do
        ROOT_PASS=$(whiptail --passwordbox "Enter root password:" 8 50 \
            3>&1 1>&2 2>&3) || error "Cancelled"
        local confirm_pass
        confirm_pass=$(whiptail --passwordbox "Confirm root password:" 8 50 \
            3>&1 1>&2 2>&3) || error "Cancelled"
        [[ "$ROOT_PASS" == "$confirm_pass" ]] && break
        whiptail --msgbox "Passwords do not match. Try again." 8 50 || true
    done

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
# 5. IMAGE SELECTION
# ─────────────────────────────────────────────
image_select() {
    local choice
    choice=$(whiptail --title "Image Source" \
        --menu "Which image to install?" 12 70 2 \
        "remote" "Pull latest from GHCR (ghcr.io/cmspam/cache22/cachyos)" \
        "local"  "Use locally built image (localhost/cache22/cachyos)" \
        3>&1 1>&2 2>&3) || error "Cancelled"

    [[ "$choice" == "local" ]] \
        && IMAGE="localhost/cache22/cachyos:latest" \
        || IMAGE="ghcr.io/cmspam/cache22/cachyos:latest"

    info "Using image: $IMAGE"
}

# ─────────────────────────────────────────────
# 6. CONFIRMATION
# ─────────────────────────────────────────────
confirm_install() {
    local var_desc="$PART_VAR ($VAR_FS"
    [[ "$ENCRYPT_VAR" == true ]]   && var_desc+=", LUKS2 encrypted"
    [[ "$BTRFS_SUBVOLS" == true ]] && var_desc+=", subvolumes: @, @home, @log"
    var_desc+=")"

    local summary="Installation Summary
─────────────────────────────
Disk:       $DISK_BY_ID
Mode:       $DISK_MODE
Root:       $PART_ROOT (XFS)
/var:       $var_desc
─────────────────────────────
Hostname:   $HOSTNAME
Timezone:   $TIMEZONE
Locale:     $LOCALE
User:       $USERNAME (wheel)
Image:      $IMAGE
─────────────────────────────

Proceed with installation?"

    whiptail --title "Confirm Installation" \
        --yesno "$summary" 30 65 || error "Installation cancelled by user"
}

# ─────────────────────────────────────────────
# 7. INSTALLATION
# ─────────────────────────────────────────────
do_install() {
    local dev part_boot part_root part_var
    dev=$(readlink -f "$DISK_BY_ID")
    part_boot=$(readlink -f "$PART_BOOT")
    part_root=$(readlink -f "$PART_ROOT")
    part_var=$(readlink -f "$PART_VAR")

    # Mount root and EFI
    info "Mounting root and EFI partitions..."
    mkdir -p /mnt
    mount "$part_root" /mnt
    mkdir -p /mnt/boot/efi
    mount "$part_boot" /mnt/boot/efi

    # Open LUKS if encrypted and not already open
    if [[ "$ENCRYPT_VAR" == true ]]; then
        if ! cryptsetup status sys_var &>/dev/null; then
            info "Opening LUKS /var device..."
            echo -n "$LUKS_PASS" | cryptsetup open "$part_var" sys_var -
        else
            info "LUKS /var device already open"
        fi
        VAR_DEVICE="/dev/mapper/sys_var"
    else
        VAR_DEVICE="$part_var"
    fi

    # Fix container storage for live environment
    info "Configuring container storage..."
    mkdir -p /etc/containers
    [[ ! -f /etc/containers/storage.conf ]] && \
        cp /usr/share/containers/storage.conf \
           /etc/containers/storage.conf 2>/dev/null || true
    sed -i \
        -e "s|^\(graphroot\s*=\s*\).*|\1\"/mnt/setup/container-storage\"|g" \
        /etc/containers/storage.conf 2>/dev/null || true
    mkdir -p /mnt/setup/container-tmp

    # Initialize OSTree
    info "Initializing OSTree repository..."
    ostree admin init-fs --sysroot=/mnt --modern /mnt
    ostree admin stateroot-init --sysroot=/mnt cache22
    ostree init --repo=/mnt/ostree/repo --mode=bare
    ostree config --repo=/mnt/ostree/repo set sysroot.bootprefix true

    # Pull image if remote
    if [[ "$IMAGE" == ghcr* ]]; then
        info "Pulling image from GHCR (this will take a while)..."
        podman pull "$IMAGE"
    fi

    # Export container to rootfs
    info "Exporting container image to rootfs..."
    mkdir -p /mnt/setup/rootfs
    podman export "$(podman create "$IMAGE" sh)" \
        | tar -xC /mnt/setup/rootfs

    info "Creating OSTree filesystem layout..."
    _create_ostree_layout

    # Write machine-specific /etc files before commit
    _write_etc_files

    # Commit to OSTree
    info "Committing rootfs to OSTree..."
    ostree commit \
        --repo=/mnt/ostree/repo \
        --branch=cache22/x86_64/standard \
        --tree=dir=/mnt/setup/rootfs

    # Build kernel arguments
    local kargs="root=LABEL=SYS_ROOT rw"
    if [[ -f /mnt/setup/rootfs/usr/share/cache22/.karg ]]; then
        while IFS= read -r karg; do
            [[ -n "$karg" ]] && kargs="$kargs $karg"
        done < /mnt/setup/rootfs/usr/share/cache22/.karg
    fi

    # Add LUKS unlock arg if encrypted
    if [[ "$ENCRYPT_VAR" == true ]]; then
        local luks_uuid
        luks_uuid=$(cryptsetup luksUUID "$part_var")
        kargs="$kargs rd.luks.name=${luks_uuid}=sys_var"
    fi

    # Deploy OSTree
    info "Deploying OSTree..."
    ostree admin deploy \
        --sysroot=/mnt \
        --karg-none \
        --karg="$kargs" \
        --os=cache22 \
        --retain \
        cache22/x86_64/standard \
        2>&1 | grep -v "grub2-mkconfig\|Bootloader write" || true

    # Install GRUB and generate config
    _install_grub "$dev" "$part_root"

    # Create first user
    _create_user

    success "Installation complete!"
}

# ─────────────────────────────────────────────
# Create OSTree filesystem layout from rootfs
# ─────────────────────────────────────────────
_create_ostree_layout() {
    local rootfs="/mnt/setup/rootfs"

    touch "$rootfs/etc/machine-id"
    mv "$rootfs/etc" "$rootfs/usr/"

    # Replace mutable top-level dirs with symlinks into /var
    rm -rf "$rootfs/home"
    ln -s /var/home "$rootfs/home"

    rm -rf "$rootfs/mnt"
    ln -s /var/mnt "$rootfs/mnt"

    rm -rf "$rootfs/root"
    ln -s /var/roothome "$rootfs/root"

    rm -rf "$rootfs/srv"
    ln -s /var/srv "$rootfs/srv"

    ln -s /var/scratch "$rootfs/scratch"

    mkdir -p "$rootfs/sysroot"
    ln -s /sysroot/ostree "$rootfs/ostree"

    rm -rf "$rootfs/usr/local"
    ln -s /var/usrlocal "$rootfs/usr/local"

    # tmpfiles.d — creates /var structure on first boot
    # Note: for Btrfs with subvolumes, /var/home and /var/log are
    # actual subvolumes, so we use 'D' (create if not dir) rather
    # than 'd' to avoid conflicts
    local tfile="$rootfs/usr/lib/tmpfiles.d/ostree-0-integration.conf"
    cat >> "$tfile" << TMPFILES
d /var/home 0755 root root -
d /var/scratch 0755 root root -
d /var/scratch/users 0755 root root -
d /var/lib 0755 root root -
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

    # For Btrfs with subvolumes, /var/log is a subvolume — don't
    # let tmpfiles try to create it as a plain directory
    if [[ "$VAR_FS" != "btrfs" ]] || [[ "$BTRFS_SUBVOLS" != "true" ]]; then
        echo "d /var/log 0755 root root -" >> "$tfile"
        echo "d /var/log/journal 0755 root root -" >> "$tfile"
    fi

    # Move pacman DB into /usr so it survives immutable updates
    mv "$rootfs/var/lib/pacman" "$rootfs/usr/lib/"
    sed -i \
        -e "s|^#\(DBPath\s*=\s*\).*|\1/usr/lib/pacman|g" \
        -e "s|^#\(IgnoreGroup\s*=\s*\).*|\1modified|g" \
        "$rootfs/usr/etc/pacman.conf"

    # Wipe /var — it will be the separate SYS_VAR partition at runtime
    rm -rf "$rootfs/var/"*

    # Fix newuidmap/newgidmap capabilities for rootless containers
    chmod u-s "$rootfs/usr/bin/newgidmap" \
               "$rootfs/usr/bin/newuidmap"
    setcap cap_setuid+eip "$rootfs/usr/bin/newuidmap"
    setcap cap_setgid+eip "$rootfs/usr/bin/newgidmap"
}

# ─────────────────────────────────────────────
# Write machine-specific /etc into rootfs
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

    # fstab
    {
        echo "# Cache22 fstab — generated by installer"
        echo "LABEL=SYS_ROOT  /         auto   rw,relatime                                                                                                   0 1"
        echo "LABEL=SYS_BOOT  /boot/efi vfat   rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro         0 2"
        echo ""

        local var_dev
        if [[ "$ENCRYPT_VAR" == true ]]; then
            var_dev="/dev/mapper/sys_var"
        else
            var_dev="LABEL=SYS_VAR"
        fi

        if [[ "$VAR_FS" == "btrfs" && "$BTRFS_SUBVOLS" == true ]]; then
            # Root subvolume @ mounted at /var
            echo "${var_dev}  /var       btrfs  rw,noatime,compress=zstd,subvol=/@       0 2"
            # @home subvolume
            echo "${var_dev}  /var/home  btrfs  rw,noatime,compress=zstd,subvol=/@home   0 2"
            # @log subvolume — nodatacow for log files
            echo "${var_dev}  /var/log   btrfs  rw,noatime,nodatacow,subvol=/@log        0 2"
        elif [[ "$VAR_FS" == "btrfs" ]]; then
            echo "${var_dev}  /var       btrfs  rw,noatime,compress=zstd                 0 2"
        else
            echo "${var_dev}  /var       auto   rw,relatime                              0 2"
        fi
    } > "$etc/fstab"

    # crypttab — only needed if LUKS encrypted
    if [[ "$ENCRYPT_VAR" == true ]]; then
        echo "sys_var  LABEL=SYS_VAR_CRYPT  none  luks,timeout=90" > "$etc/crypttab"
    fi
}

# ─────────────────────────────────────────────
# Install GRUB and generate grub.cfg
# ─────────────────────────────────────────────
_install_grub() {
    local dev="$1" part_root="$2"

    info "Installing GRUB..."
    local deploy
    deploy=$(ls -d /mnt/ostree/deploy/cache22/deploy/*.0 2>/dev/null \
        | grep -v origin | head -1)
    [[ -z "$deploy" ]] && error "Could not find OSTree deployment directory"

    # Set up chroot environment
    mkdir -p "$deploy/sysroot/ostree"
    mkdir -p "$deploy/boot/efi/EFI/grub"
    mount --bind /dev  "$deploy/dev"
    mount --bind /proc "$deploy/proc"
    mount --bind /sys  "$deploy/sys"
    mount --rbind /mnt/boot   "$deploy/boot"
    mount --rbind /mnt/ostree "$deploy/sysroot/ostree"

    export GRUB_DEVICE=LABEL=SYS_ROOT
    export GRUB_DEVICE_BOOT=LABEL=SYS_BOOT
    export GRUB_DEVICE_UUID
    GRUB_DEVICE_UUID=$(blkid -s UUID -o value "$part_root")

    chroot "$deploy" grub-install \
        --target=x86_64-efi \
        --efi-directory=/boot/efi \
        --removable \
        --boot-directory=/boot/efi/EFI \
        --bootloader-id=cache22 \
        --modules="tpm" \
        --disable-shim-lock \
        "$dev" || warn "grub-install completed with warnings (usually ok)"

    chroot "$deploy" grub-mkconfig -o /boot/efi/EFI/grub/grub.cfg

    local count
    count=$(grep -c "ostree" /mnt/boot/efi/EFI/grub/grub.cfg 2>/dev/null || echo 0)
    [[ "$count" -gt 0 ]] \
        && success "GRUB configured with $count OSTree boot entries" \
        || error "GRUB config has no OSTree entries — something went wrong"
}

# ─────────────────────────────────────────────
# Create first user in deployed system
# ─────────────────────────────────────────────
_create_user() {
    info "Creating user $USERNAME..."
    local deploy
    deploy=$(ls -d /mnt/ostree/deploy/cache22/deploy/*.0 2>/dev/null \
        | grep -v origin | head -1)

    # Mount /var into the deployment chroot so useradd can create home dir
    mkdir -p "$deploy/var"

    if [[ "$VAR_FS" == "btrfs" && "$BTRFS_SUBVOLS" == true ]]; then
        # Mount @ subvolume at /var
        mount -o defaults,noatime,compress=zstd,subvol=/ \
            "$VAR_DEVICE" "$deploy/var"
        # Mount @home subvolume at /var/home
        mkdir -p "$deploy/var/home"
        mount -o defaults,noatime,compress=zstd,subvol=/@home \
            "$VAR_DEVICE" "$deploy/var/home"
        # Mount @log subvolume at /var/log
        mkdir -p "$deploy/var/log"
        mount -o defaults,noatime,nodatacow,subvol=/@log \
            "$VAR_DEVICE" "$deploy/var/log"
    else
        mount --bind "$VAR_DEVICE" "$deploy/var"
        mkdir -p "$deploy/var/home"
    fi

    # Set root password
    echo "root:${ROOT_PASS}" | chroot "$deploy" chpasswd

    # Create user with home directory in /var/home
    chroot "$deploy" useradd \
        -m \
        -G wheel \
        -s /bin/bash \
        -d "/home/$USERNAME" \
        "$USERNAME"
    echo "${USERNAME}:${USER_PASS}" | chroot "$deploy" chpasswd

    # Unmount /var subvolumes or bind mount
    if [[ "$VAR_FS" == "btrfs" && "$BTRFS_SUBVOLS" == true ]]; then
        umount "$deploy/var/log"  2>/dev/null || true
        umount "$deploy/var/home" 2>/dev/null || true
        umount "$deploy/var"      2>/dev/null || true
    else
        umount "$deploy/var" 2>/dev/null || true
    fi

    success "User $USERNAME created successfully"
}

# ─────────────────────────────────────────────
# 8. CLEANUP AND REBOOT
# ─────────────────────────────────────────────
cleanup() {
    info "Unmounting all partitions..."
    umount -R -l /mnt 2>/dev/null || true

    # Note: leave LUKS open — the OS will manage it from here

    whiptail --title "Installation Complete" \
        --msgbox "Cache22 has been installed successfully!\n
Hostname:   $HOSTNAME
User:       $USERNAME
Timezone:   $TIMEZONE
/var:       $VAR_FS$([ "$ENCRYPT_VAR" == true ] && echo " (encrypted)")$([ "$BTRFS_SUBVOLS" == true ] && echo " with subvolumes")

Remove the installation media and reboot.
Select Cache22 from your UEFI boot menu." \
        20 60 || true

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
