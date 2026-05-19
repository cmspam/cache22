---
title: Installation
parent: Getting Started
nav_order: 1
---

# Installation

## Prerequisites

- An x86_64 machine with UEFI firmware. cache22 does not support legacy BIOS boot.
- At least 8 GB of free disk space for the OS plus space for `/var` and user data. 60 GB or more is recommended.
- A reliable network connection during install. The image is pulled from `ghcr.io` (~8 GB compressed).
- A USB drive (4 GB or larger) to write the live ISO to.

## Step 1. Download the live ISO

Download the latest ISO from the [releases page](https://github.com/cmspam/cache22/releases/latest). The file is named `cache22-installer-YYYY.MM.DD.iso`.

The live ISO is Secure Boot bootable using Fedora's Microsoft-signed shim and Fedora-signed kernel. It runs on systems with Secure Boot enabled without any firmware changes.

## Step 2. Write the ISO to USB

On Linux:

```
sudo dd if=cache22-installer-YYYY.MM.DD.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

Replace `/dev/sdX` with the actual device node of your USB drive. Use `lsblk` to verify the correct device. Writing to the wrong device will erase its contents.

On Windows: use [Rufus](https://rufus.ie/) in DD-Image mode, or [Etcher](https://etcher.balena.io/).

On macOS: use `dd` with the same syntax as Linux, after `diskutil unmountDisk /dev/diskN` to release the drive.

## Step 3. Boot the live ISO

Insert the USB drive in the target machine and boot it. The live ISO auto-logins as root on tty1 and shows a message of the day with installation instructions.

If the machine boots into its existing OS instead of the USB, enter the firmware boot menu (commonly F12, F11, F10, ESC, or F8 at power-on depending on vendor) and select the USB drive.

### Alternative: Install on a VPS via kexec (no ISO mount needed)

For VPS providers that don't let you mount a custom ISO (most cheap-tier cloud VPSes), use the kexec bootstrap. From the VPS's existing OS (Debian / Ubuntu / CentOS / Alpine / Arch — anything with `bash`, `curl`, and `kexec-tools`):

```
sudo apt-get install -y kexec-tools   # or your distro's equivalent
curl -L https://github.com/cmspam/cache22/releases/latest/download/cache22-kexec-bootstrap.sh \
    | sudo bash
```

The script:

1. Detects your current network config (interface, IP, gateway, DNS).
2. Reads your `~/.ssh/authorized_keys` (or `/root/.ssh/authorized_keys` if running as root).
3. Downloads the cache22 live env (kernel ~12 MB + initramfs-with-embedded-squashfs ~1.3 GB).
4. Builds a kexec target with the network config baked in and your SSH keys injected via kernel cmdline.
5. Fires `systemctl kexec`. Your SSH session drops; the VPS reboots in place into the cache22 live env, picks up the same IP, and starts sshd with your authorized_keys.

Wait 30-60 seconds, then SSH back in as `root` and run `cache22-install` as you would from the ISO. The host's disks are now free (the live env runs entirely from RAM), so the installer can wipe and install onto `/dev/sda` (or whatever your VPS disk is called).

Useful flags (run `cache22-kexec-bootstrap.sh --help` for the full list):

```
--release TAG      Pin to a specific release tag (default: latest)
--ssh-keys PATH    Use a specific authorized_keys file
--no-reboot        Stage kexec but don't fire systemctl kexec
                   (review what's loaded, then fire it yourself)
--no-ssh           Skip SSH key injection (you have console access)
```

If the kexec'd boot fails to come back up, your VPS provider's web console may show the failure on the serial port (the bootstrap configures `console=ttyS0`).

## Step 4. Run the installer

At the live shell, run:

```
cache22-install
```

The installer walks through the following prompts:

1. **Variant.** Choose between `cachy-server`, `cachy-kde`, `cachy-gnome`, `arch-server`, `arch-kde`, or `arch-gnome`. The picker fetches the live variant catalog from this repository so the choices stay current. See [Variants](../variants/) for details on each.
2. **Target disk.** Lists candidate disks. Selecting a disk in whole-disk mode erases it.
3. **LUKS encryption.** When enabled, the root partition is encrypted with LUKS2. A passphrase is required at install time. TPM2 auto-unlock can be enabled later with [`cache22-encryption`](../../boot-and-security/tpm-luks/).
4. **User account.** Username, password, and groups (`wheel` for sudo by default).
5. **Hostname, locale, timezone.** Standard system identification.

After confirming the choices, the installer:

1. Partitions the disk (ESP at `/efi`, root, and a temporary scratch partition or RAM-backed scratch).
2. Pulls the OCI image from `ghcr.io` (~8 GB compressed, depending on variant).
3. Lays down the deployment with `bootc install to-filesystem --bootloader=none`.
4. Generates the per-machine Secure Boot key with `sbctl create-keys`.
5. Stages auto-enroll files for sd-boot.
6. Installs sd-boot to the ESP.
7. Builds and signs the first per-deploy UKI.

The full install takes 10-30 minutes depending on disk speed and network bandwidth.

## Step 5. Reboot

When the installer reports completion, run:

```
reboot
```

Remove the USB drive when prompted by the firmware.

**Important:** before the installed system boots, complete [First-Boot Secure Boot Setup](../secure-boot-first-boot/). This is a one-time step that lets cache22 enroll its keys into firmware on the first boot.

## Scratch modes

The installer needs a scratch area (~6 GB for server variants, ~12 GB for KDE) to stage the OCI image before laying it down on the target disk. Two strategies are available:

### Tmpfs scratch (default when RAM permits)

A RAM-backed scratch directory. Faster install (no SSD writes for scratch), zero wear on the target disk for the install itself, and the target's root partition is created at full size with no reclaim step.

Selected automatically when MemAvailable is at least 14 GB for server variants or 20 GB for KDE variants.

### Disk partition scratch

A temporary 30 GB partition on the target disk. Formatted, used, then merged back into root at the end of install. Adds a few minutes of install time and ~10 GB of write traffic to the target.

Selected automatically when there is not enough RAM for tmpfs.

### Manual override

```
cache22-install --scratch tmpfs       # Force RAM scratch even on lower-RAM systems.
cache22-install --scratch /dev/sda5   # Use a specific existing partition for scratch.
                                       # Flips the installer into custom-partition mode.
```

The `--scratch tmpfs` override risks OOM on machines below the auto-detection threshold.

## Custom partition layout

The installer's whole-disk mode erases the target. To install alongside an existing OS or with custom partitioning, pre-create the partitions and pass them to `cache22-install`:

```
cache22-install --root /dev/sda5 --esp /dev/sda1
```

The ESP must be FAT32 with at least 1 GB of free space (2 GB recommended). The root partition must be unformatted or empty; the installer formats it with btrfs.

`--scratch /dev/sda6` selects a separate scratch partition (recommended on machines with less than 14 GB RAM).

## Pinning to a specific image at install time

To install a specific build instead of `:rolling`:

```
cache22-install --image ghcr.io/cmspam/cache22-cachy-server:2026-05-09
cache22-install --image ghcr.io/cmspam/cache22-cachy-kde:sha-9065ce1
```

Available tags per variant are listed at `https://github.com/cmspam/cache22/pkgs/container/cache22-<variant>`.

## Installing a fork

To install your own fork (see [Forking](../../building-and-forking/forking/) for setup):

```
cache22-install --image ghcr.io/<your-username>/cache22-<variant>:rolling
```

The installer accepts any OCI image reference. The fork must follow cache22's variant naming so the installer can pull the variant catalog.

## What to do next

Continue to [First-Boot Secure Boot Setup](../secure-boot-first-boot/) before the first boot of the installed system.
