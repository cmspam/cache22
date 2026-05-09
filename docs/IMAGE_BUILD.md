# Image build pipeline

`Containerfile` orchestrates the build; the per-step scripts under
`scripts/` carry the logic. A single Containerfile dispatches on three
build args (`VARIANT_FAMILY`, `VARIANT_TYPE`, `VARIANT`) so all four
shipped variants share one definition.

## Step order (top to bottom of Containerfile)

| Stage | Script / op | What it does |
| --- | --- | --- |
| pacman db relocation | `rewrite-pacman-paths.sh` | Move pacman state from `/var/lib/pacman` into `/usr/lib/sysimage/pacman` so the package DB ships inside the immutable image. Without this, fresh installs would have an empty DB (since `/var` is per-machine, not part of the OCI image). |
| repo bootstrap | `inject-custom-repos-${family}.sh` | cachy: layer cmspam/* on top of cachyos-v3 base + enable `[multilib]`. arch: bootstrap chaotic-aur (for `alhp-keyring`), then layer cmspam/* + ALHP rebuilds at the top of `pacman.conf` above stock core/extra/multilib. The two scripts share zero state. |
| system_files overlay (1) | `cp -av system_files/common/. /` | Apply the cache22 overlay (helpers, units, configs) before pacman so packages can't clobber, e.g., our `prepare-root.conf`. |
| package install | `pacman -S` | Combined family-common + variant-specific package list. Retries 5× with 60s backoff because cachy/ALHP CDNs occasionally serve a stale 404 while a new package propagates. |
| system_files overlay (2) | `cp -av system_files/common/. /` | Re-apply overlay because some packages overwrite our files at install (notably ostree's `prepare-root.conf`). |
| dracut module patch | `patch-ostree-dracut.sh` | Two patches against upstream `50ostree` + `51bootc`: (1) `${systemdsystemconfdir}` is empty on Arch's dracut, so target.wants symlinks land at the wrong path → switch_root drops to emergency. Hard-code `/etc/systemd/system`. (2) `51bootc` `check()` returns 255, so dracut skips it even with force-add. Rewrite to return 0. |
| initramfs | `generate-initramfs.sh` | dracut once per kernel under `/usr/lib/modules/<kver>/`. dracut (not mkinitcpio) because bootc/composefs/ostree's hooks are dracut-shaped. |
| Bootloader | none in-image | The Containerfile ships no bootloader binaries. sd-boot comes from Arch's `systemd` package and is staged on the ESP at install time by `bootctl install`. UKIs are assembled and signed at install / `bootc upgrade` time on the user's machine — see [`SECUREBOOT.md`](SECUREBOOT.md). |
| finalize | `finalize-image.sh` | os-release rewrite, `/home`/`/srv`/`/root` → `var/*` symlinks, `/ostree` → `sysroot/ostree` symlink, kernel-from-`/boot` cleanup, `/var` → `factory + tmpfiles.d` (via `var-to-tmpfiles.sh`), SUID adjustments, machine-id wipe, pacman cache drop, `/tmp` `/run` cleanup. |
| lint | `bootc container lint` | Hard fail. Surfaces nonempty-`/boot`, baseimage-root, var-tmpfiles, etc. |

## /var lifecycle (`var-to-tmpfiles.sh`)

bootc treats `/var` as per-stateroot persistent storage: anything the
image ships under `/var` MUST be reproducible on first boot via
`tmpfiles.d`. The script:

1. Strip regenerable junk (caches, logs, `/var/lib/pacman` already
   relocated by `rewrite-pacman-paths.sh`).
2. For everything left under `/var`, emit a `tmpfiles.d` entry that
   recreates it on boot — dirs as `d`, symlinks as `L+`, files as `C+`
   (which copies from `/usr/share/factory/var/...`).
3. Move regular files into `/usr/share/factory/var/`.
4. Remove the original `/var` content, preserving the
   `KEEP_TOPLEVEL` mountpoint dirs (`home`, `srv`, `roothome`,
   `tmp`) that ostree's stateroot init expects.

If you don't do this, `bootc container lint var-tmpfiles` fails AND
fresh installs silently lose anything the image carried under `/var`.

## SUID-not-caps quirk

Arch's shadow / iputils packages set file capabilities via an alpm hook
that needs `CAP_SETFCAP`. Build containers drop that cap, so file caps
never get set. Even if we apply them explicitly, composefs's
strict-verity overlay strips `security.capability` xattrs at unpack
time on the target system. SUID (a stat mode bit) is what survives
composefs deploy. Less precise than file caps but functional.
`finalize-image.sh` applies SUID to `newuidmap` / `newgidmap` /
`ping` / `arping` / `clockdiff` / `tracepath`.

## Packages

`packages/{cachy,arch}-{common,kde,server}.txt` — one package per line,
inline `# comments` allowed. The Containerfile's pacman invocation
strips them with `sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d'`
(otherwise comment text gets passed as bogus package names).

Each family is independent — to add `gnome` family, create
`packages/gnome-*.txt` + `scripts/inject-custom-repos-gnome.sh` + a
matrix row in `.github/workflows/build-image.yml`. To remove a family,
delete its files and matrix rows; the rest of the build is unaffected.
