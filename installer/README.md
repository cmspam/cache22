# cache22 installer

Live ISO + scripted installer that pulls the latest cache22 image from ghcr.io and lays it down with `bootc install to-filesystem`. The ISO is built by `.github/workflows/build-iso.yml` and published as a GitHub Release asset.

## Layout

```
installer/
├── fedora-live/                # Fedora-44 minimal live ISO build
│   └── build-iso.sh            # dnf --installroot + dracut + mksquashfs + xorrisofs
└── cache22-install             # interactive bash TUI; supports --no-prompt scripted mode
```

## Using it

1. Boot the ISO. tty1 auto-logins root; a motd explains how to proceed.
2. Run `cache22-install`. The interactive flow: image variant → disk → optional LUKS → partitioning → user account → hostname → locale → timezone → review.
3. On confirm, the installer:
   - Partitions: ESP (2 GB FAT32 at `/efi`) + root + scratch
   - Pulls the image (~8 GB compressed)
   - Runs `bootc install to-filesystem --bootloader=none` to lay down the deploy
   - Writes per-machine kargs to `/etc/cache22/extra-cmdline` (root UUID, LUKS UUIDs if encrypted, btrfs subvol if applicable)
   - Generates the per-machine SB + TPM keys via `sbctl create-keys`
   - Stages auto-enroll `.auth` files (`sbctl enroll-keys --microsoft --export auth`) so sd-boot enrolls cache22 + Microsoft DB keys on first boot when firmware is in setup mode
   - Installs sd-boot to the ESP via `bootctl install`
   - Builds the first signed UKI via `/usr/libexec/cache22/resign-uki`
   - Reclaims the scratch partition back into root (disk scratch mode) or skips (tmpfs scratch mode)
4. **Before first boot**: enter firmware setup, either disable Secure Boot or clear the Platform Key (puts firmware in setup mode). On the first boot of cache22, sd-boot auto-enrolls the staged keys, then SB enforcement engages.

## Why Fedora kernel/userland in the live ISO

The ISO needs to boot under Secure Boot on stock OEM hardware. That requires a shim-trusted kernel — Fedora's MS-signed shim + Fedora-signed grub2 + Fedora-signed kernel cover that. The installed system uses sd-boot + per-machine-signed UKIs instead; the live env's bootloader stack is throwaway.

## Scripted install

```
cache22-install --no-prompt --disk /dev/vda \
    --variant cachy-kde --user testuser --password testpass123 \
    --hostname testhost --locale en_US.UTF-8 --timezone Asia/Tokyo --reboot
```

`--variant cachy-kde|cachy-server|arch-kde|arch-server` is shorthand for `--image ghcr.io/cmspam/cache22-<id>:rolling`. `--image REF` overrides `--variant` if both are passed.

## Building locally

Requires Fedora 44 (or a Fedora 44 container), runs as root:

```bash
sudo dnf install -y dracut squashfs-tools xorriso mtools dosfstools python3
sudo ./fedora-live/build-iso.sh ./out
```

Output: `out/cache22-installer-YYYY.MM.DD.iso`.

## Switching an existing bootc system

From any bootc-based system:

```bash
sudo bootc switch ghcr.io/cmspam/cache22-cachy-kde:rolling
sudo systemctl reboot
```

This will work for `bootc switch` semantics, but the new image expects `cache22-resign-uki.service` to be present and a per-machine SB key + sd-boot on the ESP — not the case on a non-cache22 origin. For a clean cross-bootc rebase, use `cache22-repair` from the cache22 live ISO instead.
