# cache22 installer — internals

The bootc/ostree/dracut ecosystem is built around Fedora's assumptions; several things need explicit handling on Arch/CachyOS. Read this before changing the installer or the image.

## Architecture

- Image builds run in GitHub Actions: matrix of 4 variants (cachy-kde, cachy-server, arch-kde, arch-server). cachy variants build on `cachyos/cachyos-v3`; arch variants on `archlinux:latest`. The Containerfile installs packages, generates initramfs, runs `bootc container lint`. **No SB signing or bootloader binaries ship in the image** — sd-boot comes from the Arch `systemd` package, UKIs are built and signed at install / `bootc upgrade` time on the user's machine.
- Each variant is rechunked into ~120 per-package layers via `scripts/rechunk-cache22.py`.
- Images published to `ghcr.io/cmspam/cache22-{cachy,arch}-{kde,server}:rolling`.
- Live ISO is a Fedora-44 live environment that pulls the variant image from ghcr at install time. The ISO uses a Fedora kernel (SB-bootable with default Microsoft keys); the installed system is Arch/CachyOS booted via per-machine-signed UKIs.
- Disk layout: ESP (2 GB FAT32, mounted at `/efi`, holds sd-boot + per-deploy UKIs) + root (rest minus 30 GB, btrfs/xfs/ext4) + scratch (30 GB ext4, freed back into root after install). With `--luks`, only root is encrypted; ESP stays unencrypted (UEFI requirement). No separate `/boot` partition.

## Boot chain

```
firmware (cache22 PK/KEK/db + Microsoft DB, enrolled via sd-boot auto-enroll on first boot)
  └─ /efi/EFI/systemd/systemd-bootx64.efi    (signed by cache22 SB key)
      └─ /efi/EFI/Linux/cache22-<csum>.efi   (UKI: kernel + initramfs + cmdline + .pcrsig)
          └─ ostree-prepare-root binds the deploy at /sysroot
              └─ switch_root → systemd
```

The UKI is loaded directly by sd-boot — there is no menu editor, no shim, no MOK. Cmdline comes from the UKI's signed `.cmdline` PE section (sd-stub ignores external overrides under SB). See [`SECUREBOOT.md`](SECUREBOOT.md).

## Install flow (high-level)

1. Boot live ISO. Connect WiFi if needed (`nmcli`).
2. Run `cache22-install`. Picks variant, partitions, formats, mounts ESP at `/efi` + root, pulls the image (~8 GB compressed), runs `bootc install to-filesystem --bootloader=none`, writes user/hostname/locale/timezone + per-machine kargs into `<deploy>/etc/`, generates per-machine SB + TPM keys (`sbctl create-keys`), stages auto-enroll `.auth` files (`sbctl enroll-keys --microsoft --export auth`), installs sd-boot via `bootctl install`, builds the first signed UKI via `cache22-resign-uki`, reclaims scratch into root.
3. **Before reboot:** user enters firmware setup, either disables Secure Boot or clears the Platform Key (puts firmware in setup mode).
4. First boot: sd-boot auto-enrolls cache22's keys (PK + KEK + db) plus Microsoft DB keys. Then loads the signed UKI; sd-stub validates `.cmdline` and `.pcrsig`; ostree-prepare-root binds the deploy; main systemd boots.

## Required image-side fixes

Without each of these, install or boot fails.

### 1. Empty mount-point dirs in the image

Pacman 'files' DBs do not include directory entries, and the rechunker walks files only. Empty dirs (`/tmp`, `/var/tmp`, `/sysroot`, `/proc`, `/sys`, `/dev`, `/run`) vanish from the rechunked image entirely.

- `/tmp` missing → bootc's `findmnt` wrapper hits `ENOENT`, surfaces as `Inspecting filesystem /target: No such file or directory`.
- `/sysroot` missing → `ostree-prepare-root` cannot bind-mount the deployment; switch_root drops to dracut emergency.

**Fix:** `scripts/rechunk-cache22.py` injects these as explicit directory entries (`extra_dirs` in the leftover layer) with correct modes (`/tmp` = 1777, `/sysroot` = 0755).

### 2. ostree dracut module wants-symlink path

Upstream `50ostree` does:

    ln_r ".../ostree-prepare-root.service" \
         "${systemdsystemconfdir}/initrd-root-fs.target.wants/..."

On Fedora's dracut, `${systemdsystemconfdir}` is `/etc/systemd/system`. On Arch's dracut 110, it is unset. The wants symlink lands at `/initrd-root-fs.target.wants/...` — a path systemd does not scan. `ostree-prepare-root.service` never runs; switch_root fails.

**Fix:** `scripts/patch-ostree-dracut.sh` hard-codes `/etc/systemd/system/initrd-root-fs.target.wants/` before initramfs generation.

### 3. ostree dracut module is required

Without `add_dracutmodules+=" ostree "` in `/etc/dracut.conf.d/10-cache22.conf`, the initramfs lacks `ostree-prepare-root.service` entirely.

### 4. system_files overlay must be re-applied AFTER pacman

Some packages (notably `ostree`) overwrite directories where the overlay lives. The Containerfile applies the overlay both before and after `pacman -S`.

### 5. bootc must be built for x86-64-v3 baseline

`cmspam/bootc-v3` builds bootc inside a `cachyos/cachyos-v3` container on GHA (AMD EPYC runners) with `RUSTFLAGS="-C target-cpu=x86-64-v3"` and `CFLAGS="-march=x86-64-v3 -mtune=generic"`. Required so the binary runs on any x86-64-v3 CPU (Intel Haswell / AMD Excavator+), not just AMD.

## Required installer-side recipe

### A. Mount propagation

- `mount --make-rshared /` on the live ISO before mounting the target.
- Per-target rshared on `$TARGET` and `$TARGET/efi` so bootc's `findmnt --mountpoint /target` sees the submounts.

### B. Partition typecodes

- p1 ESP — `ef00` (FAT32, 2 GB, label `EFI-SYSTEM`)
- p2 root — `8304` (Linux x86-64 root)
- p3 scratch — `8300` (generic Linux), ext4

No separate `/boot` partition. /boot exists as a regular directory inside the deploy; ostree may write vestigial BLS entries there but cache22 ignores them — sd-boot reads UKIs from the ESP only.

### C. bootc invocation

    bootc install to-filesystem \
        --source-imgref containers-storage:$IMAGE \
        --target-no-signature-verification \
        --generic-image \
        --stateroot default \
        --bootloader=none \
        --root-mount-spec=UUID=$ROOT_UUID \
        --skip-finalize \
        /target

Critical flags:

- `--bootloader=none` — bootc does not install a bootloader. cache22 owns the bootloader install via `bootctl install` + `cache22-resign-uki`.
- `--source-imgref containers-storage:$IMAGE` — install from local podman storage, not by re-pulling inside the container.
- `--root-mount-spec` by UUID — bootc's auto-detection via findmnt is brittle; explicit spec is stable.
- `--generic-image` — skip firmware-specific bootloader configuration.
- `--skip-finalize` — defer the final boot-entry write until after sd-boot install + UKI build.

We do NOT use `--composefs-backend`. The composefs strict-verity path broke on linux 7.x at "Initializing /etc and /var" with EIO. The legacy ostree backend works: composefs is still used at runtime to mount `/usr` read-only via `[composefs] enabled = true` in `prepare-root.conf`, but without verity enforcement.

### D. podman run wrapper for bootc

    podman run --rm --privileged --pid=host \
        --mount type=bind,src=$TARGET,dst=/target,bind-propagation=rshared \
        -v /dev:/dev \
        -v /var/lib/containers:/var/lib/containers \
        -v /var/tmp:/var/tmp \
        --entrypoint /usr/bin/bootc \
        $IMAGE \
        install to-filesystem ...

- `--privileged` and `--pid=host` are required for bootc to setns into PID 1's mount namespace.
- `-v /var/lib/containers` — the container needs to see the host's containers-storage at the same path.
- `-v /var/tmp` — skopeo stages large blobs in `/var/tmp`; without this the container's tmpfs fills up.

### E. Bootloader install (`install_sb_and_uki()`)

After `bootc install`, the installer sets up the SB chain inside the deployed rootfs via chroot:

1. Bind /sys/firmware/efi/efivars + /dev + /proc + /sys + the ESP into the deploy.
2. `chroot $DEPLOY /usr/libexec/cache22/sb-key-init` — generates `/var/lib/cache22/sbkey/` (sbctl PK/KEK/db + TPM PCR-policy keypair).
3. `chroot $DEPLOY sbctl enroll-keys --microsoft --export auth` — stages `.auth` files at `/efi/loader/keys/auto/` so sd-boot's `secure-boot-enroll = force` enrolls cache22 + Microsoft DB keys on first boot.
4. `chroot $DEPLOY bootctl install --esp-path=/efi` — copies sd-boot to `/efi/EFI/systemd/systemd-bootx64.efi` + `/efi/EFI/BOOT/BOOTX64.EFI` and writes the NVRAM Boot#### entry via efibootmgr.
5. Write `/efi/loader/loader.conf` with `default cache22-*.efi`, `editor no`, `secure-boot-enroll force`.
6. `chroot $DEPLOY /usr/libexec/cache22/resign-uki` — assembles + signs the first UKI from the deploy's vmlinuz + initramfs + cmdline (image kargs from `/usr/lib/bootc/kargs.d/*.toml` + per-machine kargs from `/etc/cache22/extra-cmdline` + the `ostree=...` deploy path), atomically writes to `/efi/EFI/Linux/cache22-<csum>.efi`. Also re-signs sd-boot if the in-image binary is newer than what bootctl just installed.

### F. Per-machine kargs (`configure_deploy()`)

Per-machine values that must be in the kernel cmdline are written to `<deploy>/etc/cache22/extra-cmdline`:

```
root=UUID=<root-fs-uuid>
rd.luks.uuid=<luks-part-uuid>           # only if --luks
rd.luks.name=<luks-part-uuid>=cache22-root
rd.luks.options=<luks-part-uuid>=discard,tpm2-device=auto
rootflags=subvol=root,<btrfs opts>      # only if btrfs
```

`resign-uki` reads this file and concatenates its lines into the UKI's `.cmdline`. Users can append their own kargs via `cache22-karg add KEY=VAL`, which writes to the same file and triggers `cache22-resign-uki.path`.

### G. Writing user/hostname/locale/timezone into the deployed /etc

**THIS IS A FOOTGUN.** A find with `head -1` can pick `<deploy>/usr/etc` (the immutable image default) instead of `<deploy>/etc` (the writable per-deployment copy). Writing to `/usr/etc/hostname` does nothing useful; ostree's etc-merge treats `hostname`, `machine-id`, etc. as machine-specific and does NOT propagate them from `/usr/etc` into `/etc`.

The installer uses `deploy_etc()` which searches `$TARGET/ostree/deploy` and `$TARGET/state/deploy`, filtering for paths ending in `*.0/etc` that don't go through `/usr`.

Files written:

- `$DEPLOY_ETC/hostname`
- `$DEPLOY_ETC/locale.conf` — `LANG=$LOCALE`
- `$DEPLOY_ETC/localtime` — symlink to `/usr/share/zoneinfo/$TIMEZONE`
- `$DEPLOY_ETC/passwd`, `shadow`, `group`
- `$DEPLOY_ETC/sudoers.d/10-wheel` — `%wheel ALL=(ALL:ALL) ALL`
- `$DEPLOY_ETC/fstab` — only the ESP mount (`UUID=$ESP_UUID /efi vfat umask=0077 0 2`) plus optional `/var/home` btrfs subvol
- `$DEPLOY_ETC/cache22/extra-cmdline` — per-machine kargs
- User home: `$DEPLOY_VAR/home/$USERNAME` chowned to 1000:1000
- `$DEPLOY_ETC/subuid` + `subgid` — pre-seeded for rootless podman/distrobox/incus

### H. Scratch reclaim

In disk-scratch auto mode (when `CFG[scratch_part]` is not `tmpfs`):

    sync
    umount -R $TARGET
    parted -s $DISK rm 3
    parted -s $DISK resizepart 2 100%
    partprobe; udevadm settle; sleep 2
    [re-open LUKS if applicable]
    mount $ROOT_DEV $TARGET
    btrfs filesystem resize max $TARGET   # or xfs_growfs / resize2fs
    umount $TARGET

In tmpfs-scratch mode, root already spans the full disk; no reclaim step.

## x86-64-v3 preflight

The installer checks for `avx avx2 bmi1 bmi2 fma` in `/proc/cpuinfo` flags before proceeding. `lzcnt` and `movbe` are omitted because Linux doesn't always report them under those names even on real v3 CPUs. The five checked flags identify the v3 baseline (Intel Haswell / AMD Excavator or newer).

## Verifying it actually boots

A successful boot shows:

    Starting OSTree Prepare OS/...
    [  OK  ] Finished OSTree Prepare OS/.
    Welcome to cache22!
    [...services...]
    cache22 login:

The `Starting OSTree Prepare OS/` line is the smoke test for the dracut wants-symlink fix: if absent, the symlink is in the wrong place.
