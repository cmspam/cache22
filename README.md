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
- AMD, Intel (including Xe), and NVIDIA GPUs (single unified image)
- `sof-firmware`, `alsa-firmware` for broad audio device support
- `linux-cachyos` kernel with full sched-ext support
- ntfsplus kernel module for NTFS drives — faster and more reliable than ntfs-3g or ntfs3
- Xbox One/Series controller support via xone driver

### Gaming
- Steam (via `cachyos-gaming-applications`)
- Gamescope and gamescope-session
- MangoHud
- **Patched QEMU** — includes VAAPI hardware video transcoding, custom refresh rate support with SDL backend, and higher polling rate patches for improved desktop responsiveness
- **Patched Gamescope** — fixes for Steam Remote Play with NVIDIA cards
- Full Vulkan support for AMD, Intel, and NVIDIA including 32-bit layers

### Containers and Virtualization
- Flatpak with Flathub pre-configured
- Toolbox and Distrobox for mutable development containers
- Incus and Incus UI for full virtual machine management
- QEMU/KVM with virt-manager

### Software Installation
The immutable root means you install software differently from a traditional distro:

| Type | Tool |
|------|------|
| GUI apps | Flatpak (Flathub pre-configured) |
| CLI dev tools | Toolbox or Distrobox |
| Virtual machines | Incus or QEMU |
| System-level (Arch packages) | Not possible — request inclusion in the image |

You can also add [Homebrew](https://brew.sh) or [Nix](https://nixos.org) in your home directory for additional package management without touching the system root.

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
- x86-64-v3 capable CPU (Haswell/2013 or newer for Intel, Excavator/2015 or newer for AMD)
- 50GB minimum for root, plus space for `/var` (user data)
- Internet connection

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
- Disk selection and partitioning (automatic, free space, or manual)
- Optional LUKS encryption for `/var` (user data partition)
- Optional Btrfs for `/var` (XFS is default)
- Timezone, locale, hostname
- Root password and first user creation
- Image source (GHCR or local build)

### Secure Boot (optional, after install)

Cache22 includes `sbctl` for managing Secure Boot keys. With Secure Boot disabled in your UEFI firmware:
```bash
sudo sbctl create-keys
sudo sbctl enroll-keys --microsoft
sudo sbctl sign -s /boot/efi/EFI/BOOT/BOOTX64.EFI
sudo sbctl sign -s /boot/efi/EFI/grub/grubx64.efi 2>/dev/null || true
```

Then enable Secure Boot in your UEFI firmware and reboot. Keys persist across updates — `c22-update` re-signs automatically if sbctl is set up.

---

## Updating

Updates are built automatically every week and pushed to the GitHub Container Registry. To update:
```bash
sudo c22-update
sudo reboot
```

That's it. The new image is pulled, committed to OSTree, and staged for the next boot. Your previous deployment is kept as a rollback target.

### Rolling Back

If something goes wrong after an update:
```bash
# From the running system
sudo yorha deployment list
sudo ostree admin set-default 1
sudo reboot

# Or — select the previous deployment from the GRUB menu at boot
```

---

## Building Locally

If you want to build your own image:
```bash
git clone --recursive https://github.com/cmspam/cache22
cd cache22
sudo ./yorha compose container-base
sudo ./yorha compose container
```

Deploy a locally built image:
```bash
sudo yorha upgrade local
```

---

## Image Schedule

New images are built:
- **Weekly** — every Friday at 19:00 UTC, automatically via GitHub Actions
- **On every push** to the `main` branch

Images are published to `ghcr.io/cmspam/cache22/cachyos`.

---

## Credits

Cache22 is built on top of [YoRHa](https://github.com/lcook/yorha) by [lcook](https://github.com/lcook), which provides the OSTree image building and deployment toolkit. Special thanks to the [CachyOS](https://cachyos.org) team for their excellent kernel, repositories, and packages.

---

## License

[BSD 2-Clause](LICENSE)
