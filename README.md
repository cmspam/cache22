<p align="center">
  <b>Cache22</b> — An immutable, atomic CachyOS-based desktop for people who just want it to work.
</p>

---

## What is Cache22?

The name is a joke — using a bleeding-edge, performance-optimized Linux distribution like CachyOS is great in theory, but in practice you often end up wrestling with broken packages, misconfigured gaming setups, driver workarounds, and opinionated helpers that get in your way. A catch-22.

Cache22 resolves this by building on top of CachyOS's excellent x86-64-v3 optimized packages and repositories, but delivering them as an **immutable, atomic OS image** powered by [OSTree](https://ostreedev.github.io/ostree). The system is read-only and reproducible. Updates are atomic and reversible. You never end up in a half-broken state. When something goes wrong, you roll back.

Built on the [YoRHa](https://github.com/lcook/yorha) toolkit, Cache22 gives you a clean, vanilla KDE Plasma desktop on Wayland with everything you need already baked in — gaming tools, virtualization, container support, input methods, broad hardware support — without any of the configuration burden.

---

## Design Philosophy

- **Immutable root** — `/usr` and `/` are read-only. The system is exactly what was built, on every machine, every time.
- **Atomic updates** — updates are pulled as a complete new image and staged for the next boot. If anything goes wrong, the previous deployment is one reboot away.
- **Vanilla KDE** — no opinionated theming, no custom greeter, no surprises. Just KDE Plasma on Wayland as it was meant to be.
- **Apps via Flatpak, Toolbox, Distrobox, or Incus** — the immutable root means you install applications in their own isolated environments, not into the system. This keeps the base clean and your apps portable.

---

## What's Included

### Desktop
- KDE Plasma 6 (Wayland, default)
- Plasma Login Manager with auto-login support
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

### Patches and Optimizations
Cache22 ships patched versions of two key gaming packages:

- **QEMU** — patched to add VAAPI hardware video transcoding support, custom refresh rate support with the SDL backend, and a higher polling rate for improved desktop responsiveness
- **Gamescope** — patched to fix Steam Remote Play with NVIDIA GPUs

These are provided via custom package repositories and updated independently of the base image.

### Containers and Virtualization
- Flatpak with Flathub pre-configured
- Toolbox and Distrobox for mutable development containers
- Incus and Incus UI for full virtual machine and container management
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

---

## Optional Services

Some included services are not enabled by default since they are not needed by all users. Enable only what you need.

### Incus (Virtual Machines and Containers)

Incus is included but not started by default:
```bash
sudo systemctl enable --now incus
```

After enabling, the Incus web UI is available at `https://localhost:8443`. You can manage VMs and containers either through the UI or via the `incus` command line tool.

### supergfxctl (Hybrid Graphics / Laptop GPU Switching)

If your laptop has hybrid graphics (e.g. an integrated Intel or AMD GPU alongside a discrete NVIDIA GPU), `supergfxctl` lets you switch between GPU modes:
```bash
sudo systemctl enable --now supergfxd
```

Once running, GPU mode can be switched from the system tray or via the command line:
```bash
supergfxctl --mode integrated   # battery saving, discrete GPU off
supergfxctl --mode hybrid       # NVIDIA available on demand
supergfxctl --mode dedicated    # always use NVIDIA
```

### Sunshine (Game Streaming)

Sunshine is included for streaming games to Moonlight clients. Launch it when needed:
```bash
sunshine
```

The Sunshine web interface for configuration is available at `https://localhost:47990`. Add it to KDE autostart in System Settings if you want it running at login.

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
- Filesystem choice for `/var` — XFS (default) or Btrfs with optional subvolumes
- Optional LUKS encryption for `/var` (user data — the root partition is public and immutable so encrypting it serves no purpose)
- Timezone, locale, and hostname
- Root password and first user account
- Image source — pull from GHCR or use a locally built image

### Secure Boot (optional, after first boot)

Cache22 includes `sbctl` for Secure Boot key management. With Secure Boot **disabled** in your UEFI firmware:
```bash
sudo sbctl create-keys
sudo sbctl enroll-keys --microsoft
sudo sbctl sign -s /boot/efi/EFI/BOOT/BOOTX64.EFI
sudo sbctl sign -s /boot/efi/EFI/grub/grubx64.efi 2>/dev/null || true
```

Then enable Secure Boot in your UEFI firmware and reboot. The `--microsoft` flag retains Microsoft's keys alongside yours for hardware compatibility. `c22-update` automatically re-signs EFI binaries after updates if sbctl is set up.

---

## Updating

New images are built automatically every week. To update your system:
```bash
sudo c22-update
sudo reboot
```

The new image is pulled from GHCR, committed to the local OSTree repository, and staged for the next boot. Your previous deployment is retained as a rollback target.

### Rolling Back

If something goes wrong after an update, you have two options:

**From the running system:**
```bash
sudo yorha deployment list
sudo ostree admin set-default 1
sudo reboot
```

**From the GRUB menu:**
Select the previous deployment entry at boot. No commands needed.

---

## Build Schedule

New images are published to `ghcr.io/cmspam/cache22/cachyos`:

- **Weekly** — every Friday at 19:00 UTC via GitHub Actions
- **On every push** to the `main` branch

---

## Building Locally

To build your own image:
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

---

## Credits

Cache22 is built on top of [YoRHa](https://github.com/lcook/yorha) by [lcook](https://github.com/lcook), which provides the OSTree image building and deployment toolkit. Special thanks to the [CachyOS](https://cachyos.org) team for their excellent kernel, repositories, and packages.

---

## License

[BSD 2-Clause](LICENSE)
