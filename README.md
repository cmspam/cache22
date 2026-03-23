<p align="center">
  <b>Cache22</b> — An immutable, atomic CachyOS-based desktop for people who just want it to work.
</p>

---

## What is Cache22?

The name is a joke — using a bleeding-edge, performance-optimized Linux distribution like CachyOS is great in theory, but in practice you often end up wrestling with broken packages, misconfigured gaming setups, driver workarounds, and opinionated helpers that get in your way. A catch-22.

Cache22 resolves this by building on top of CachyOS's excellent x86-64-v3 optimized packages and repositories, but delivering them as an **immutable, atomic OS image** powered by [OSTree](https://ostreedev.github.io/ostree). The system is read-only and reproducible. Updates are atomic and reversible. You never end up in a half-broken state. When something goes wrong, you roll back.

Built on the [YoRHa](https://github.com/lcook/yorha) toolkit, Cache22 gives you a clean, vanilla KDE Plasma desktop on Wayland with everything you need already baked in — gaming tools, virtualization, container support, input methods, and broad hardware support — without any of the configuration burden.

---

## Design Philosophy

- **Immutable root** — `/usr` and `/` are read-only. The system is exactly what was built, on every machine, every time.
- **Atomic updates** — updates are pulled as a complete new image and staged for the next boot. If anything goes wrong, the previous deployment is one reboot away.
- **Vanilla KDE** — no opinionated theming, no custom greeter, no surprises. Just KDE Plasma 6 on Wayland as it was meant to be.
- **Apps via Flatpak, Toolbox, Distrobox, or Incus** — install applications in isolated environments rather than into the system root. The base stays clean, your apps stay portable.

---

## What's Included

### Desktop
- KDE Plasma 6 (Wayland, default)
- Plasma Login Manager
- Full font support including CJK (Japanese, Chinese, Korean)
- Fcitx5 with Mozc for Japanese input
- Bluetooth, printing, and network shares out of the box

### Hardware Support
- AMD, Intel (including Xe), and NVIDIA GPUs — single unified image, all supported
- `sof-firmware` and `alsa-firmware` for broad audio device support
- `linux-cachyos` kernel with full sched-ext support
- ntfsplus kernel module for NTFS drives — faster and more reliable than ntfs-3g or the in-kernel ntfs3 driver. Mount your Windows Steam library safely.
- Xbox One and Xbox Series controller support via the xone driver

### Gaming
- Steam (via `cachyos-gaming-applications`)
- Gamescope and gamescope-session
- MangoHud
- Full Vulkan support for AMD, Intel, and NVIDIA including 32-bit layers

### Virtualization and Containers
- Flatpak with Flathub pre-configured
- Toolbox and Distrobox for mutable development containers
- Incus and Incus UI for virtual machine and container management
- QEMU/KVM with virt-manager

### Software Installation

The immutable root means you install software differently from a traditional distribution:

| Type | Tool |
|------|------|
| GUI apps | Flatpak (Flathub pre-configured) |
| CLI dev tools | Toolbox or Distrobox |
| Virtual machines | Incus or QEMU |
| System-level packages | Not possible — request inclusion in the image |

You can also add [Homebrew](https://brew.sh) or [Nix](https://nixos.org) in your home directory for additional package management without touching the system root.

### Patches and Optimizations

Cache22 ships patched versions of two packages via custom repositories:

- **QEMU** — patched to add VAAPI hardware video transcoding support, custom refresh rate support with the SDL backend, and higher polling rate for improved desktop responsiveness
- **Gamescope** — patched to fix Steam Remote Play with NVIDIA GPUs

---

## Installation

### Requirements

- UEFI firmware (BIOS not supported)
- x86-64-v3 capable CPU (Intel Haswell 2013 or newer, AMD Excavator 2015 or newer)
- 50GB minimum for the root partition, plus space for `/var` (user data)
- Internet connection during install

### From an Arch or CachyOS Live USB

1. Boot the live environment
2. Connect to the internet
3. Download and run the installer:
```bash
curl -O https://raw.githubusercontent.com/cmspam/cache22/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

The installer will guide you through:

- Disk selection — wipe entire disk, use free space alongside existing partitions, or partition manually
- Filesystem choice for `/var` — XFS (default) or Btrfs with optional subvolumes (`@`, `@home`, `@log`)
- Optional LUKS encryption for `/var` (the root partition is public and immutable so encrypting it serves no purpose)
- Timezone, locale, and hostname
- Root password and first user account
- Image source — pull latest from GHCR or use a locally built image

---

## Updating

New images are built automatically twice every day. To update:
```bash
sudo c22-update
sudo reboot
```

The new image is pulled from GHCR, committed to the local OSTree repository, and staged for the next boot. Your previous deployment is retained as a rollback target.

### Rolling Back

If something goes wrong after an update:

**From the running system:**
```bash
sudo yorha deployment list
sudo ostree admin set-default 1
sudo reboot
```

**From the GRUB menu:**
Select the previous deployment entry at boot. No commands needed.

---

## Deck Mode

Cache22 includes a built-in gaming mode that boots directly into a Steam/Gamescope session, similar to SteamOS on the Steam Deck.

**Enable deck mode:**
```bash
sudo c22-deck-enable
sudo reboot
```

**Disable deck mode (return to KDE desktop):**
```bash
sudo c22-deck-disable
sudo reboot
```

The script automatically detects your user and the correct Gamescope session. No configuration required.

---

## Secure Boot

Cache22 supports Secure Boot using your own keys via `sbctl`. A guided setup script is included.

### Setup

First, enter Setup Mode in your UEFI firmware — this clears existing Secure Boot keys and allows enrolling new ones. The option is usually called "Clear Secure Boot Keys" or "Reset to Setup Mode". Secure Boot should be **disabled** at this point.

Boot into Cache22 and run:
```bash
sudo c22-setup-secureboot
```

The script will:
1. Verify you are in Setup Mode
2. Generate your personal Secure Boot keys
3. Enroll them alongside Microsoft's certificates (required for hardware compatibility on most systems)
4. Sign the GRUB EFI binaries
5. Sign all kernels in the OSTree boot directory
6. Verify everything is correctly signed

Then reboot into your UEFI firmware, enable Secure Boot, save and reboot. Verify it worked:
```bash
sbctl status
```

### Staying signed after updates

`c22-update` automatically re-signs all registered EFI binaries and kernels after each update if sbctl is configured. No manual action required.

---

## Optional Services

Some included services are not enabled by default. Enable only what you need.

### Incus (Virtual Machines and Containers)
```bash
sudo systemctl enable --now incus
```

The Incus web UI is then available at `https://localhost:8443`.

### supergfxctl (Hybrid Graphics / Laptop GPU Switching)

For laptops with hybrid graphics (integrated + discrete NVIDIA GPU):
```bash
sudo systemctl enable --now supergfxd
```

Switch GPU modes via the system tray or command line:
```bash
supergfxctl --mode integrated   # battery saving, discrete GPU off
supergfxctl --mode hybrid       # NVIDIA available on demand
supergfxctl --mode dedicated    # always use NVIDIA
```

### Sunshine (Game Streaming)

Sunshine is included for streaming to [Moonlight](https://moonlight-stream.org) clients. Enable it as a user service:
```bash
systemctl --user enable --now sunshine
```

The Sunshine configuration interface is available at `https://localhost:47990`.

---

## Building Locally
```bash
git clone --recursive https://github.com/cmspam/cache22
cd cache22
sudo ./yorha compose container-base
sudo ./yorha compose container
```

Deploy a locally built image from within a running Cache22 system:
```bash
sudo yorha upgrade local
```

New images are published to `ghcr.io/cmspam/cache22/cachyos` every twice a day and on every push to `main`.

---

## Credits

Cache22 is built on top of [YoRHa](https://github.com/lcook/yorha) by [lcook](https://github.com/lcook), which provides the OSTree image building and deployment toolkit. Special thanks to the [CachyOS](https://cachyos.org) team for their excellent kernel, repositories, and packages.

---

## License

[BSD 2-Clause](LICENSE)
