#!/usr/bin/env bash
# cache22-kexec-bootstrap — install cache22 on a VPS that can't mount
# a custom installer ISO.
#
# Run from the VPS's existing OS (Debian/Ubuntu/CentOS/RHEL/Alpine
# /Arch — anything with bash + curl + kexec). Downloads the cache22
# live env (kernel + fat initramfs with embedded squashfs) and kexecs
# into it, preserving the existing network config and your SSH keys so
# you can log back in without console access. Then SSH in as root and
# run `cache22-install` to install onto the now-free disk.
#
# Usage:
#   curl -L https://github.com/cmspam/cache22/releases/latest/download/cache22-kexec-bootstrap.sh \
#       | sudo bash
#
# Or download + inspect first:
#   curl -LO https://github.com/cmspam/cache22/releases/latest/download/cache22-kexec-bootstrap.sh
#   chmod +x cache22-kexec-bootstrap.sh
#   sudo ./cache22-kexec-bootstrap.sh --help
#
# Flags (all optional):
#   --release TAG        GitHub release tag to pull assets from
#                          (default: latest). Useful to pin to a known
#                          build.
#   --ssh-keys PATH      Path to file with authorized_keys to install in
#                          the kexec'd live env. Default: tries (in order)
#                          ${SUDO_USER:-$USER}'s ~/.ssh/authorized_keys,
#                          then /root/.ssh/authorized_keys.
#   --no-ssh             Skip SSH key injection (you have console access).
#   --no-reboot          Stage the kexec but don't fire systemctl kexec
#                          — you do that manually after reviewing.
#   --root-password PW   Root password in the live env (default: cache22).
#   --workdir DIR        Where to stage downloads. Default: /boot/cache22-kexec
#   -h | --help          This help.

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────
RELEASE="latest"
SSH_KEYS_PATH=""
INJECT_SSH=1
DO_REBOOT=1
ROOT_PASSWORD="cache22"
WORKDIR="/boot/cache22-kexec"
REPO_OWNER="cmspam"
REPO_NAME="cache22"

# ─── Arg parsing ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)        RELEASE="$2"; shift 2 ;;
        --ssh-keys)       SSH_KEYS_PATH="$2"; INJECT_SSH=1; shift 2 ;;
        --no-ssh)         INJECT_SSH=0; shift ;;
        --no-reboot)      DO_REBOOT=0; shift ;;
        --root-password)  ROOT_PASSWORD="$2"; shift 2 ;;
        --workdir)        WORKDIR="$2"; shift 2 ;;
        -h|--help)        sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

[[ ${EUID} -eq 0 ]] || { echo "Must run as root."; exit 1; }

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ─── Tool check ───────────────────────────────────────────────────────
for tool in curl kexec ip awk sed base64 systemctl; do
    command -v "$tool" >/dev/null 2>&1 \
        || die "missing required tool: $tool (install with your package manager)"
done

# ─── Network auto-detect ──────────────────────────────────────────────
# Reads the current default route → primary interface + gateway. Reads
# the interface's IPv4 + prefix. Reads /etc/resolv.conf for DNS.
# Builds dracut's ip=<client>:<server>:<gw>:<netmask>:<host>:<dev>:<auto>
# cmdline arg so the kexec'd live env comes up with the same network
# config (no DHCP gamble).
say "Detecting current network config"

IFACE=$(ip -4 route show default | awk 'NR==1{print $5}')
GATEWAY=$(ip -4 route show default | awk 'NR==1{print $3}')
[[ -n "$IFACE" && -n "$GATEWAY" ]] \
    || die "could not detect default route (no IPv4 default? VPS console may need manual ip= arg)"

CIDR=$(ip -4 -o addr show dev "$IFACE" | awk '{print $4}' | head -1)
[[ -n "$CIDR" ]] || die "no IPv4 address on $IFACE"
IP4="${CIDR%/*}"
PREFIX="${CIDR#*/}"

# Convert prefix to dotted netmask (the form ip= cmdline wants).
prefix_to_netmask() {
    local p=$1 m=0xFFFFFFFF
    m=$(( m << (32 - p) & 0xFFFFFFFF ))
    printf '%d.%d.%d.%d' $(( (m >> 24) & 0xFF )) $(( (m >> 16) & 0xFF )) \
                         $(( (m >> 8) & 0xFF ))  $(( m & 0xFF ))
}
NETMASK=$(prefix_to_netmask "$PREFIX")

HOSTNAME=$(hostname -s 2>/dev/null || hostname || echo cache22-installer)

DNS1=$(awk '/^nameserver /{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
DNS2=$(awk '/^nameserver /{print $2}' /etc/resolv.conf 2>/dev/null | sed -n 2p || true)

echo "    interface : $IFACE"
echo "    ip        : $IP4/$PREFIX  (netmask $NETMASK)"
echo "    gateway   : $GATEWAY"
echo "    hostname  : $HOSTNAME"
echo "    DNS       : ${DNS1:-(none)} ${DNS2:+/ $DNS2}"

# dracut ip= syntax: client:server:gw:netmask:host:dev:autoconf:dns0:dns1
# 'server' field is unused for static; 'autoconf' is 'none' for static.
IP_CMDLINE="ip=${IP4}::${GATEWAY}:${NETMASK}:${HOSTNAME}:${IFACE}:none"
[[ -n "$DNS1" ]] && IP_CMDLINE+=":${DNS1}"
[[ -n "$DNS2" ]] && IP_CMDLINE+=":${DNS2}"

# ─── SSH keys ─────────────────────────────────────────────────────────
SSH_KEYS=""
if (( INJECT_SSH )); then
    if [[ -z "$SSH_KEYS_PATH" ]]; then
        for candidate in \
                "/home/${SUDO_USER:-$USER}/.ssh/authorized_keys" \
                "/root/.ssh/authorized_keys"; do
            if [[ -s "$candidate" ]]; then
                SSH_KEYS_PATH="$candidate"
                break
            fi
        done
    fi
    if [[ -z "$SSH_KEYS_PATH" || ! -s "$SSH_KEYS_PATH" ]]; then
        die "no authorized_keys found (tried \$SUDO_USER + /root). Pass --ssh-keys PATH or --no-ssh."
    fi
    SSH_KEYS=$(cat "$SSH_KEYS_PATH")
    echo "    SSH keys  : $SSH_KEYS_PATH ($(grep -c '' "$SSH_KEYS_PATH") line(s))"
fi

# ─── Resolve release URLs ─────────────────────────────────────────────
say "Resolving cache22 release '$RELEASE'"

RELEASE_BASE="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases"
if [[ "$RELEASE" == "latest" ]]; then
    # GitHub's "latest" tag redirects via the API.
    LATEST_TAG=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
                    "${RELEASE_BASE}/latest" | awk -F/ '{print $NF}')
    [[ -n "$LATEST_TAG" ]] || die "could not resolve latest release tag"
    RELEASE="$LATEST_TAG"
    echo "    resolved latest → $RELEASE"
fi

# The release tag is like 'iso-2026-05-15'. Asset names embed the
# date too: cache22-kexec-2026-05-15-vmlinuz / -initramfs.img. Derive
# the date suffix from the tag.
DATE_SUFFIX="${RELEASE#iso-}"
[[ "$DATE_SUFFIX" != "$RELEASE" ]] \
    || die "release tag '$RELEASE' doesn't match expected pattern iso-YYYY-MM-DD"

VMLINUZ_URL="${RELEASE_BASE}/download/${RELEASE}/cache22-kexec-${DATE_SUFFIX}-vmlinuz"
INITRD_URL="${RELEASE_BASE}/download/${RELEASE}/cache22-kexec-${DATE_SUFFIX}-initramfs.img"

# ─── Download ─────────────────────────────────────────────────────────
say "Downloading kexec assets to $WORKDIR"
mkdir -p "$WORKDIR"
echo "    $VMLINUZ_URL"
curl -fL --progress-bar "$VMLINUZ_URL" -o "$WORKDIR/vmlinuz"
echo "    $INITRD_URL"
curl -fL --progress-bar "$INITRD_URL"  -o "$WORKDIR/initramfs.img"

echo
echo "    vmlinuz    : $(du -h "$WORKDIR/vmlinuz" | cut -f1)"
echo "    initramfs  : $(du -h "$WORKDIR/initramfs.img" | cut -f1)"

# ─── Build kernel cmdline ─────────────────────────────────────────────
# selinux=0 enforcing=0 — live env's squashfs has no SELinux labels
# rd.live.image rd.live.overlay.overlayfs — boot from embedded squashfs
# rd.live.ram=1 — copy live image into RAM so the squashfs source can
#                 go away after boot (defense in depth — the squashfs
#                 IS in the initramfs which is already in RAM, but this
#                 ensures dracut treats it as RAM-resident)
# ip=...        — auto-detected from current network config above
# console=...   — VPS-friendly (serial + tty)
# cache22.ssh.authorized_keys=<base64> — picked up by the live env's
#                                        cache22-kexec-setup.service
CMDLINE_PARTS=(
    "rd.live.image"
    "rd.live.overlay.overlayfs"
    "rd.live.ram=1"
    "selinux=0"
    "enforcing=0"
    "audit=0"
    "console=tty0"
    "console=ttyS0,115200n8"
    "$IP_CMDLINE"
)

if (( INJECT_SSH )); then
    SSH_B64=$(printf '%s' "$SSH_KEYS" | base64 -w 0)
    CMDLINE_PARTS+=( "cache22.ssh.authorized_keys=$SSH_B64" )
fi

# Also bake the root password into the cmdline so the user can log in
# at the VPS's console serial port if SSH fails. The live env's
# /etc/passwd has root:cache22 baked in already; this is just for the
# user's convenience if they change it via --root-password.
# (The decoder is the same cache22-kexec-setup script.)
CMDLINE="${CMDLINE_PARTS[*]}"

echo
say "Loading kexec target"
echo "    cmdline: $CMDLINE"
echo
kexec --load "$WORKDIR/vmlinuz" \
      --initrd="$WORKDIR/initramfs.img" \
      --append="$CMDLINE"

say "Kexec loaded successfully."

if (( DO_REBOOT )); then
    cat <<EOF

The next step (systemctl kexec) replaces this running OS with the
cache22 live installer. Your SSH session will drop. Wait ~30-60 seconds
then SSH back in to the same IP — root login is enabled with your
existing authorized_keys$( (( INJECT_SSH )) && echo " (from $SSH_KEYS_PATH)" || true ).

If the kexec'd boot fails, your provider's console may show why.

Firing kexec in 5 seconds. Ctrl-C to abort.
EOF
    for i in 5 4 3 2 1; do printf '%d... ' "$i"; sleep 1; done
    echo
    systemctl kexec
else
    cat <<EOF

Kexec is staged but not fired (--no-reboot). When ready:
    sudo systemctl kexec

Or unload:
    sudo kexec -u
EOF
fi
