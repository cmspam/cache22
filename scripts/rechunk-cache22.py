#!/usr/bin/env python3
"""
rechunk-cache22 — split a built cache22 OCI image into per-package layers
                  so OCI layer dedup gives sub-layer delta updates.

Background: bootc downloads images at LAYER granularity. A single 8 GB
install layer means every change forces a full redownload. By creating
one layer per pacman package (ordered alphabetically for stability), an
update that touches N packages only needs to redownload those N small
layers — typically 50-200 MB of actual delta instead of multiple GB.

Inputs:
  --src   source image (e.g. localhost/cache22-kde:raw)
  --dst   destination ref to write to (skopeo dir transport)

The output directory can be uploaded with:
  skopeo copy dir:<dst> docker://ghcr.io/<owner>/<repo>:<tag>

Strategy:
  1. Mount the source image via buildah mount.
  2. Read /usr/lib/sysimage/pacman/local/*/files for per-package file lists.
  3. For each package (alphabetical), build a tar layer of just its files.
  4. Build a "leftover" layer containing files not owned by any package
     (initramfs, depmod outputs, /etc edits from alpm hooks, etc.).
  5. Build a "pacman-db" layer containing the pacman DB and other metadata.
  6. Construct OCI image directory (manifest + config + layer blobs).
  7. Caller pushes via skopeo copy.

Layer sizes are stable across builds when the package's content hasn't
changed; the desc/install timestamps in the pacman DB go into the
leftover layer, which keeps per-package layers truly content-stable.
"""


import argparse
import fnmatch
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import time
from pathlib import Path

# ─── Helpers ──────────────────────────────────────────────────────────────

# Set in main() from --source-date-epoch. All tar entries (files, dirs,
# symlinks) get this mtime so identical-content layers produce identical
# blob hashes across builds — without it, fresh pacstrap mtimes invalidate
# every bucket layer that contains any file from a freshly-installed pkg.
SDE: int = 0

# Static package groupings. Each tuple is (group_name, glob_patterns).
# Matched packages all land in one layer per group instead of being
# scattered across hash-buckets — so when an upstream rebuild churns a
# correlated set (cmspam/* daily rebuilds, all qt6, all kf6), exactly
# one layer flips instead of N.
#
# Patterns are fnmatch-style, applied to the bare pkgname (no version).
# Order matters: first match wins. Anything not matched falls through
# to the existing solo/bucket logic. Groups named here are stable across
# builds — adding/removing patterns reshuffles only this group's
# membership, not the unmatched packages' bucket assignment.
GROUPS: list[tuple[str, list[str]]] = [
    # cmspam/* repos (bootc-v3, gamescope-patched, qemu-patched,
    # virglrenderer-patched, xe-virt-host-v3) force-rebuild at 14:00 UTC
    # daily — image build at 18:00 always pulls fresh bytes for these.
    ("cmspam-daily", [
        "bootc",
        "gamescope", "gamescope-*",
        "qemu", "qemu-*",
        "virglrenderer", "virglrenderer-*",
        "xe-virt-host-v3",
    ]),
    # Kernel + pre-built per-kernel modules (cachy ships nvidia-open/zfs/
    # r8125 prebuilt; arch uses dkms which lands its .ko output in the
    # leftover layer regardless, so dkms source pkgs aren't grouped here).
    ("kernel", [
        "linux", "linux-headers",
        "linux-cachyos-bore-lto", "linux-cachyos-bore-lto-*",
    ]),
    # Qt6 framework — entire suite churns together on Qt point releases.
    ("qt6", ["qt6-*"]),
    # KDE Frameworks 6 + Plasma 6 desktop shell.
    ("kf6", ["kf6-*", "plasma-*", "kde-*"]),
    # Mesa graphics stack + Vulkan + VAAPI.
    ("mesa", [
        "mesa", "mesa-*",
        "vulkan-*",
        "libva", "libva-*",
        "intel-compute-runtime", "intel-media-driver",
    ]),
    # Firmware blobs + ucode (rarely change but always together when they do).
    ("firmware", [
        "linux-firmware", "linux-firmware-*",
        "sof-firmware", "alsa-firmware",
        "amd-ucode", "intel-ucode",
        "wireless-regdb",
    ]),
]

# AUR packages built fresh in this image build. The list is written by
# build-aur-packages.sh and persisted to /usr/share/cache22/aur-pkgs.txt
# in the final image. Read at rechunk time and treated as one group.
AUR_SIDECAR_REL = "usr/share/cache22/aur-pkgs.txt"
AUR_GROUP_NAME = "cache22-aur"

# Leftover-promotion: specific file globs that get pulled OUT of the
# default leftover layer and into a named layer. Same principle as
# GROUPS but for unowned files (initramfs, DKMS-compiled modules) which
# pacman doesn't track. Without this, every-build-changes-anyway content
# (initramfs, dkms .kos) sits in the same layer as stable-when-no-source-
# change content (alpm hook caches, /etc edits, factory-var) — forcing
# users to re-download the stable bytes whenever the volatile bits flip.
LEFTOVER_PROMOTIONS: list[tuple[str, list[str]]] = [
    # initramfs.img is rebuilt by dracut every image build (non-deterministic
    # cpio + kernel-module ordering). Isolating it costs nothing for itself
    # but prevents it from dragging the rest of leftover.
    ("initramfs", [
        "usr/lib/modules/*/initramfs*.img",
        "usr/lib/modules/*/initrd*",
    ]),
    # DKMS-built .kos under .../extra/ and .../updates/. arch family rebuilds
    # these every image build via the dkms alpm hook (cachy uses pre-built
    # per-kernel module packages instead, so this group is empty there).
    # depmod outputs (modules.dep, modules.alias, modules.symbols, etc.)
    # are coupled — they regenerate when the dkms hook adds/removes modules.
    ("dkms-modules", [
        "usr/lib/modules/*/extra/*",
        "usr/lib/modules/*/extra/**",
        "usr/lib/modules/*/updates/*",
        "usr/lib/modules/*/updates/**",
        "usr/lib/modules/*/modules.*",
    ]),
]


def assign_leftover_group(rel_path: str) -> str | None:
    """Pick a promotion group for a leftover file, or None to keep in leftover."""
    for group_name, patterns in LEFTOVER_PROMOTIONS:
        for pat in patterns:
            if fnmatch.fnmatchcase(rel_path, pat):
                return group_name
    return None


# File-path groups: specific files get pulled into a dedicated layer
# regardless of which package owns them. Used for files modified by
# finalize-image.sh (or similar post-pacman steps) that change per-build
# for reasons unrelated to the owning package — without this, those files
# pollute their package's bucket every build, dragging unrelated bystanders
# along.
FILE_PATH_GROUPS: list[tuple[str, list[str]]] = [
    # finalize-image.sh stamps a build timestamp into these.
    # Owners: filesystem (os-release), lsb-release (lsb-release).
    ("release-stamp", [
        "usr/etc/os-release",
        "usr/lib/os-release",
        "usr/etc/lsb-release",
    ]),
]


def assign_file_path_group(rel_path: str) -> str | None:
    """Pick a path-based group for a file, or None for normal handling."""
    for group_name, patterns in FILE_PATH_GROUPS:
        for pat in patterns:
            if fnmatch.fnmatchcase(rel_path, pat):
                return group_name
    return None

# pacman directory naming: "<pkgname>-<pkgver>-<pkgrel>" where pkgver
# starts with a digit (per Arch packaging guidelines). pkgname can
# contain hyphens; split from the right.
_PKG_NAME_RE = re.compile(r"^(.+)-([^-]+)-(\d+)$")


def pkgname_of(dir_name: str) -> str:
    """Strip -<ver>-<rel> suffix from a pacman local-db dir name."""
    m = _PKG_NAME_RE.match(dir_name)
    return m.group(1) if m else dir_name


def assign_group(pkg_dir_name: str, aur_pkgnames: set[str]) -> str | None:
    """Pick a static group for this package, or None to fall through."""
    name = pkgname_of(pkg_dir_name)
    if name in aur_pkgnames:
        return AUR_GROUP_NAME
    for group_name, patterns in GROUPS:
        for pat in patterns:
            if fnmatch.fnmatchcase(name, pat):
                return group_name
    return None


def run(cmd: list[str], **kw) -> str:
    """Run a command, return stdout, raise on failure."""
    r = subprocess.run(cmd, check=True, capture_output=True, text=True, **kw)
    return r.stdout.strip()


def sha256_file(path: Path) -> str:
    """Stream-hash a file."""
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_pacman_files(files_path: Path) -> list[str]:
    """Parse a pacman 'files' database file and return the file list.

    Returns only files + symlinks (excludes directories — entries with a
    trailing slash). Directories are shared between packages in pacman's
    model and including them in per-package layers would cause "duplicate
    path" errors when stacked.

    Format:
        %FILES%
        usr/bin/         (← directory, skipped)
        usr/bin/foo      (← file, kept)
        usr/share/foo/...
    """
    out: list[str] = []
    in_files = False
    for line in files_path.read_text(errors="replace").splitlines():
        if line == "%FILES%":
            in_files = True
            continue
        if line.startswith("%") and line.endswith("%"):
            in_files = False
            continue
        if in_files and line and not line.endswith("/"):
            out.append(line.lstrip("/"))
    return out


def parse_pacman_desc(desc_path: Path) -> dict[str, str]:
    """Parse a pacman 'desc' file into a dict of single-value fields."""
    out: dict[str, str] = {}
    cur: str | None = None
    for line in desc_path.read_text(errors="replace").splitlines():
        if line.startswith("%") and line.endswith("%"):
            cur = line.strip("%")
            continue
        if cur and line:
            out.setdefault(cur, line)
    return out


# ─── OCI image construction ──────────────────────────────────────────────


def add_layer_from_files(
    out_blobs: Path,
    layer_name: str,
    file_list: list[Path],
    arcname_for: dict[Path, str],
    src_root: Path,
    extra_dirs: list[tuple[str, int]] | None = None,
) -> dict | None:
    """
    Build a zstd-compressed tar layer containing exactly file_list.
    Returns the OCI layer descriptor dict (digest, size, mediaType, diff_id),
    or None if file_list is empty after filtering.

    extra_dirs is an optional list of (arcname, mode) tuples for empty
    directories to add to the layer (e.g. /tmp at 1777). These are
    necessary because pacman files DBs omit directories entirely and our
    file walk only collects files, so empty mount-point dirs would
    otherwise vanish from the rechunked image.
    """
    if not file_list and not extra_dirs:
        return None

    tmp_tar = out_blobs / f"{layer_name}.tar"

    # Pre-compute every dir to emit (parents of files, parents of
    # extra_dirs, and the extra_dirs themselves), with the right mode:
    # prefer the explicit mode from extra_dirs, then stat-derived, then
    # fallback (0o755, root:root). Default applies when the source
    # rootfs doesn't have the dir — var-to-tmpfiles.sh strips /var/lib,
    # /var/cache, etc., but extra_dirs still references paths like
    # var/lib/flatpak/repo/objects.
    #
    # Dirs are deduped here to keep the layer free of duplicate paths
    # (composefs/bootc reject those when unpacking — extra_dirs entries
    # like var/lib/flatpak/repo/refs collide with their own role as
    # parent of var/lib/flatpak/repo/refs/heads).
    import stat as _stat

    explicit_modes: dict[str, int] = {}
    for arcname, mode in extra_dirs or []:
        explicit_modes[arcname.strip("/")] = mode

    dirs_to_emit: set[str] = set()
    for src_path in file_list:
        arcname = arcname_for.get(src_path, "")
        parts = arcname.strip("/").split("/")
        for i in range(1, len(parts)):
            dirs_to_emit.add("/".join(parts[:i]))
    for arcname in explicit_modes.keys():
        parts = arcname.split("/")
        for i in range(1, len(parts)):
            dirs_to_emit.add("/".join(parts[:i]))
        dirs_to_emit.add(arcname)

    def dir_metadata(arcname: str) -> tuple[int, int, int]:
        """Pick (mode, uid, gid) for a directory entry."""
        if arcname in explicit_modes:
            return (explicit_modes[arcname], 0, 0)
        src = src_root / arcname
        try:
            st = os.stat(str(src), follow_symlinks=False)
            if _stat.S_ISDIR(st.st_mode):
                return (_stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid)
        except OSError:
            pass
        return (0o755, 0, 0)

    def emit_dir(tar: "tarfile.TarFile", arcname: str) -> bool:
        mode, uid, gid = dir_metadata(arcname)
        ti = tarfile.TarInfo(name=arcname)
        ti.type = tarfile.DIRTYPE
        ti.mode = mode
        ti.uid = uid
        ti.gid = gid
        ti.mtime = SDE
        tar.addfile(ti)
        return True

    actually_added = 0
    with tarfile.open(tmp_tar, "w", format=tarfile.PAX_FORMAT) as tar:
        # Emit parent dirs first (sorted so / before /usr before /usr/lib...)
        for d in sorted(dirs_to_emit, key=lambda p: (p.count("/"), p)):
            if emit_dir(tar, d):
                actually_added += 1

        for src_path in file_list:
            arcname = arcname_for[src_path]
            try:
                ti = tar.gettarinfo(name=str(src_path), arcname=arcname)
                if ti is None:
                    continue
                ti.mtime = SDE
                # Read xattrs (skip if path is a broken symlink/gone)
                try:
                    xattrs = os.listxattr(str(src_path), follow_symlinks=False)
                except OSError:
                    xattrs = []
                for x in xattrs:
                    try:
                        v = os.getxattr(str(src_path), x, follow_symlinks=False)
                    except OSError:
                        continue
                    # Use surrogateescape so non-ASCII bytes round-trip
                    # cleanly through tarfile's pax-header encoding.
                    # latin-1 looked right but encoded via UTF-8 expanded
                    # bytes 0x80-0xFF to 2-byte sequences, corrupting
                    # binary xattrs (security.capability) and breaking
                    # the install with `lsetxattr ...: invalid argument`.
                    # surrogateescape triggers tarfile's `binary=True`
                    # branch which preserves the original bytes verbatim.
                    ti.pax_headers[f"SCHILY.xattr.{x}"] = \
                        v.decode("ascii", errors="surrogateescape")
                # Add the file content (or just the metadata for non-files)
                if ti.isfile():
                    with open(src_path, "rb") as f:
                        tar.addfile(ti, f)
                else:
                    tar.addfile(ti)
                actually_added += 1
            except (FileNotFoundError, OSError):
                continue

    if actually_added == 0:
        tmp_tar.unlink(missing_ok=True)
        return None

    t0 = time.monotonic()
    diff_id = "sha256:" + sha256_file(tmp_tar)
    raw_size = tmp_tar.stat().st_size

    # zstd compression. The zstd CLI is deterministic regardless of
    # thread count (a design goal — Arch's pacman relies on it), so
    # -T0 (use all cores) is safe. The zstd frame has no embedded
    # mtime; output bytes depend only on input bytes and level.
    zst_tmp = out_blobs / f"{layer_name}.tar.zst"
    with tmp_tar.open("rb") as src, zst_tmp.open("wb") as dst:
        subprocess.run(
            ["zstd", "-T0", "-19", "--quiet", "--stdout"],
            stdin=src, stdout=dst, check=True,
        )
    tmp_tar.unlink()

    digest = "sha256:" + sha256_file(zst_tmp)
    size = zst_tmp.stat().st_size

    # Move to content-addressed name
    final = out_blobs / digest.removeprefix("sha256:")
    dedup = ""
    if not final.exists():
        zst_tmp.rename(final)
    else:
        zst_tmp.unlink()  # already there from a prior package with same content
        dedup = "  [dedup]"

    elapsed = time.monotonic() - t0
    raw_mib = raw_size / 1024 / 1024
    zst_mib = size / 1024 / 1024
    ratio = (size / raw_size * 100) if raw_size else 0.0
    # One line per layer so the GH Actions log shows live progress
    # through what is otherwise a multi-minute silent block. flush=True
    # because GH's log streaming buffers per chunk; without flush the
    # output appears all at once at the end of the step.
    print(
        f"    [{layer_name:32s}] {actually_added:5d} entries  "
        f"raw={raw_mib:7.2f} MiB  zst={zst_mib:7.2f} MiB ({ratio:4.1f}%)  "
        f"compress={elapsed:5.1f}s{dedup}",
        flush=True,
    )

    return {
        "mediaType": "application/vnd.oci.image.layer.v1.tar+zstd",
        "digest": digest,
        "size": size,
        "_diff_id": diff_id,  # internal; stripped before writing manifest
    }


def write_blob(out_blobs: Path, content: bytes, media_type: str) -> dict:
    """Write a JSON/text blob and return its descriptor."""
    digest = "sha256:" + hashlib.sha256(content).hexdigest()
    path = out_blobs / digest.removeprefix("sha256:")
    path.write_bytes(content)
    return {"mediaType": media_type, "digest": digest, "size": len(content)}


# ─── Main ────────────────────────────────────────────────────────────────


def main():
    # GH Actions buffers a step's stdout in chunks; line-buffering makes
    # every print() flush on newline so the build log shows progress
    # live during the multi-minute layer-build phase instead of dumping
    # everything when the script exits.
    sys.stdout.reconfigure(line_buffering=True)
    sys.stderr.reconfigure(line_buffering=True)
    t_start = time.monotonic()
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="source image ref (e.g. localhost/foo:raw)")
    ap.add_argument("--dst", required=True, help="output skopeo dir path")
    ap.add_argument(
        "--source-date-epoch",
        type=int,
        default=0,
        help=(
            "Stable epoch for tar-entry mtimes. Identical across builds "
            "so unchanged content produces identical layer digests."
        ),
    )
    ap.add_argument(
        "--image-created-epoch",
        type=int,
        default=None,
        help=(
            "Epoch for the OCI image config 'created' annotation. "
            "Lives only in the config blob, not in any layer, so it can "
            "vary per build without affecting layer dedup. Defaults to "
            "--source-date-epoch."
        ),
    )
    args = ap.parse_args()

    global SDE
    SDE = args.source_date_epoch
    if args.image_created_epoch is None:
        args.image_created_epoch = args.source_date_epoch

    out_root = Path(args.dst).absolute()
    out_blobs = out_root / "blobs" / "sha256"
    out_blobs.mkdir(parents=True, exist_ok=True)

    print(f"==> Creating buildah container from {args.src}")
    ctr = run(["sudo", "buildah", "from", args.src])
    print(f"==> Mounting container {ctr}")
    mnt = run(["sudo", "buildah", "mount", ctr])
    src_mnt = Path(mnt)

    try:
        # Read pacman DB
        db_root = src_mnt / "usr" / "lib" / "sysimage" / "pacman" / "local"
        if not db_root.is_dir():
            print(f"FATAL: pacman DB not found at {db_root}", file=sys.stderr)
            sys.exit(1)

        print(f"==> Reading pacman DB at {db_root}")
        pkg_files: dict[str, list[str]] = {}
        for pkg_dir in sorted(db_root.iterdir()):
            if not pkg_dir.is_dir():
                continue
            files_db = pkg_dir / "files"
            if files_db.exists():
                pkg_files[pkg_dir.name] = parse_pacman_files(files_db)
        print(f"    found {len(pkg_files)} packages")

        # Pull file-path-grouped files OUT of their owning packages.
        # Their absence from the package layer is why this works: the
        # next time the file changes (e.g. finalize-image.sh re-stamps
        # os-release), only the dedicated file-group layer flips, not
        # the owning package's bucket.
        file_group_paths: dict[str, list[str]] = {}
        moved_count = 0
        for pkg, files in pkg_files.items():
            kept: list[str] = []
            for f in files:
                g = assign_file_path_group(f)
                if g:
                    file_group_paths.setdefault(g, []).append(f)
                    moved_count += 1
                else:
                    kept.append(f)
            pkg_files[pkg] = kept
        if moved_count:
            print(f"    moved {moved_count} files into file-path groups: "
                  f"{', '.join(sorted(file_group_paths.keys()))}")

        # Compute approximate package sizes for solo/bucket decisions
        print("==> Sizing packages (for solo-layer selection)")
        pkg_sizes: dict[str, int] = {}
        for pkg, files in pkg_files.items():
            total = 0
            for f in files:
                try:
                    total += (src_mnt / f).lstat().st_size
                except OSError:
                    pass
            pkg_sizes[pkg] = total

        # Layer plan, in priority order:
        #   1. Group layers (one per matched static group + AUR group)
        #      — packages whose churn is correlated land together so a
        #        single upstream rebuild flips one layer instead of N
        #        scattered bucket layers
        #   2. Solo layers (top N_SOLO unmatched packages by size)
        #      — big standalone packages get isolated
        #   3. Bucket layers (remaining unmatched packages by sha256)
        #      — small bystanders share, hash-bucketed deterministically
        #   4. pacman-db layer
        #   5. Leftover-promotion layers (initramfs, dkms-modules)
        #   6. Leftover layer (everything else unowned)
        #
        # OverlayFS max stacked layers = 128. Reserve headroom for groups
        # and promotions: 8 groups + 2 promotions + N_SOLO + N_BUCKETS +
        # pacman-db + leftover ≤ 128 → keep N_SOLO + N_BUCKETS ≤ 116.
        N_SOLO = 40
        N_BUCKETS = 60

        # Load AUR sidecar (list of pkgnames built fresh in this build).
        aur_sidecar = src_mnt / AUR_SIDECAR_REL
        aur_pkgnames: set[str] = set()
        if aur_sidecar.is_file():
            aur_pkgnames = {
                line.strip() for line in aur_sidecar.read_text().splitlines()
                if line.strip()
            }
            print(f"==> AUR sidecar: {len(aur_pkgnames)} pkgs → {AUR_GROUP_NAME} layer")
        else:
            print(f"==> No AUR sidecar at {aur_sidecar} — {AUR_GROUP_NAME} group will be empty")

        # Categorize each package: static group, AUR group, or unmatched.
        group_assignment: dict[str, list[str]] = {}
        ungrouped: list[str] = []
        for pkg in pkg_files.keys():
            g = assign_group(pkg, aur_pkgnames)
            if g:
                group_assignment.setdefault(g, []).append(pkg)
            else:
                ungrouped.append(pkg)

        # Solo + bucket packing applies to UNGROUPED packages only.
        ungrouped_by_size = sorted(ungrouped, key=lambda p: -pkg_sizes[p])
        solo_pkgs = set(ungrouped_by_size[:N_SOLO])
        bucket_assignment: dict[int, list[str]] = {i: [] for i in range(N_BUCKETS)}
        for pkg in ungrouped:
            if pkg in solo_pkgs:
                continue
            bidx = (
                int(hashlib.sha256(pkg.encode()).hexdigest(), 16) % N_BUCKETS
            )
            bucket_assignment[bidx].append(pkg)

        print(f"==> Layer plan ({len(pkg_files)} packages total):")
        for gname in sorted(group_assignment.keys()):
            pkgs = group_assignment[gname]
            mib = sum(pkg_sizes[p] for p in pkgs) / 1024 / 1024
            print(f"    group {gname:16s}: {len(pkgs):3d} pkgs, {mib:6.1f} MiB")
        if ungrouped:
            largest = ungrouped_by_size[0]
            print(
                f"    {len(solo_pkgs)} solo layers "
                f"(largest: {largest} @ {pkg_sizes[largest] / 1024 / 1024:.0f} MiB)"
            )
            print(
                f"    {N_BUCKETS} bucket layers "
                f"({len(ungrouped) - len(solo_pkgs)} packages)"
            )

        # Build the set of all files owned by a package
        owned: set[str] = set()
        for files in pkg_files.values():
            owned.update(files)

        # Walk the rootfs to find leftover (unowned) files.
        # We'll exclude the pacman DB itself — that goes in its own layer
        # so per-package layers stay content-stable across builds.
        print("==> Walking rootfs to identify leftover files")
        excluded_prefixes = (
            "usr/lib/sysimage/pacman/",  # DB → its own layer
            "proc/",
            "sys/",
            "dev/",
            "run/",
            "tmp/",
            "var/tmp/",
        )
        # Walk and capture files + symlinks (no real directories — see
        # comment in parse_pacman_files about why directory entries cause
        # "duplicate path" errors when stacked across layers).
        #
        # Subtle: os.walk(followlinks=False) classifies a *valid* symlink-
        # to-dir into `dirs` (not `files`), even though the symlink itself
        # is a file. If we only iterate `files` we silently drop those
        # symlinks from the rechunked image — exactly what happened to
        # /home, /srv, /root once /var/home etc. existed as targets.
        # Inspect both lists and pick out the symlinks from `dirs` too.
        all_files: list[str] = []
        for root, dirs, files in os.walk(src_mnt, followlinks=False):
            rel_root = os.path.relpath(root, src_mnt)
            if rel_root == ".":
                rel_root = ""
            for name in files:
                p = os.path.join(rel_root, name) if rel_root else name
                if any(p.startswith(pre) for pre in excluded_prefixes):
                    continue
                all_files.append(p)
            # Promote symlinks misclassified as `dirs` into `all_files`,
            # and prevent os.walk from descending into them (they're not
            # real subtrees of THIS filesystem).
            real_dirs = []
            for name in dirs:
                full = os.path.join(root, name)
                p = os.path.join(rel_root, name) if rel_root else name
                if os.path.islink(full):
                    if any(p.startswith(pre) for pre in excluded_prefixes):
                        continue
                    all_files.append(p)
                else:
                    real_dirs.append(name)
            dirs[:] = real_dirs

        all_files_set = set(all_files)
        # Files moved into file-path groups must be excluded from the
        # leftover walk too — otherwise they'd appear in BOTH the
        # file-group layer (because we put them there) AND the leftover
        # layer (because they're not in `owned` after the move),
        # producing a duplicate-path error at unpack time.
        file_group_set: set[str] = set()
        for paths in file_group_paths.values():
            file_group_set.update(paths)
        unowned = all_files_set - owned - file_group_set

        # Sort unowned files into leftover-promotion groups vs default leftover.
        promoted_files: dict[str, list[str]] = {}
        leftover_files: list[str] = []
        for f in sorted(unowned):
            g = assign_leftover_group(f)
            if g:
                promoted_files.setdefault(g, []).append(f)
            else:
                leftover_files.append(f)
        print(f"    leftover (unowned) files: {len(leftover_files)}")
        for gname, files in sorted(promoted_files.items()):
            mib = sum(
                (src_mnt / f).lstat().st_size for f in files
                if (src_mnt / f).exists()
            ) / 1024 / 1024
            print(f"    promoted to {gname}: {len(files)} files, {mib:.1f} MiB")

        # Build layers in deterministic order: file-path groups (alphabetical),
        # package groups (alphabetical), solo (alphabetical), buckets (by index),
        # pacman-db, leftover-promoted groups (alphabetical), leftover.
        layers_desc: list[dict] = []

        phase_t = time.monotonic()
        print(f"==> Building file-path-group layers ({len(file_group_paths)} groups)")
        for gname in sorted(file_group_paths.keys()):
            files = sorted(set(file_group_paths[gname]))
            file_paths = [src_mnt / f for f in files]
            arcname = {src_mnt / f: f for f in files}
            desc = add_layer_from_files(
                out_blobs, f"file-{gname}", file_paths, arcname, src_mnt
            )
            if desc:
                layers_desc.append(desc)
        print(f"    {len(layers_desc)} file-path-group layers built in {time.monotonic()-phase_t:.1f}s")

        before_groups = len(layers_desc)
        phase_t = time.monotonic()
        print(f"==> Building package-group layers ({len(group_assignment)} groups)")
        for gname in sorted(group_assignment.keys()):
            pkgs_in = sorted(group_assignment[gname])
            file_paths: list[Path] = []
            arcname: dict[Path, str] = {}
            for pkg in pkgs_in:
                for f in pkg_files[pkg]:
                    p = src_mnt / f
                    file_paths.append(p)
                    arcname[p] = f
            desc = add_layer_from_files(
                out_blobs, f"group-{gname}", file_paths, arcname, src_mnt
            )
            if desc:
                layers_desc.append(desc)
        print(f"    {len(layers_desc) - before_groups} package-group layers built in {time.monotonic()-phase_t:.1f}s")

        phase_t = time.monotonic()
        print(f"==> Building solo layers ({len(solo_pkgs)} packages)")
        before_solo = len(layers_desc)
        for i, pkg in enumerate(sorted(solo_pkgs), 1):
            files = pkg_files[pkg]
            file_paths = [src_mnt / f for f in files]
            arcname = {src_mnt / f: f for f in files}
            desc = add_layer_from_files(
                out_blobs, f"solo-{pkg}", file_paths, arcname, src_mnt
            )
            if desc:
                layers_desc.append(desc)
        print(f"    {len(layers_desc) - before_solo} solo layers built in {time.monotonic()-phase_t:.1f}s")

        phase_t = time.monotonic()
        nonempty_buckets = sum(1 for b in range(N_BUCKETS) if bucket_assignment[b])
        print(f"==> Building bucket layers ({nonempty_buckets} non-empty of {N_BUCKETS})")
        before_buckets = len(layers_desc)
        for bidx in range(N_BUCKETS):
            pkgs_in = sorted(bucket_assignment[bidx])
            if not pkgs_in:
                continue
            file_paths: list[Path] = []
            arcname: dict[Path, str] = {}
            for pkg in pkgs_in:
                for f in pkg_files[pkg]:
                    p = src_mnt / f
                    file_paths.append(p)
                    arcname[p] = f
            desc = add_layer_from_files(
                out_blobs, f"bucket-{bidx:03d}", file_paths, arcname, src_mnt
            )
            if desc:
                layers_desc.append(desc)
        print(f"    {len(layers_desc) - before_buckets} bucket layers built in {time.monotonic()-phase_t:.1f}s")

        phase_t = time.monotonic()
        print("==> Building pacman-db layer")
        # Normalize wall-clock timestamps in pacman's local DB to SDE.
        #   desc:  %INSTALLDATE% (set by pacman at install) +
        #          %BUILDDATE%   (set by makepkg at AUR-package build)
        #   mtree: time=<epoch>.<frac> on every entry (also set by makepkg)
        # All three drift every build for AUR packages we rebuild fresh
        # (r8125-dkms, xone-dkms-git, etc.); INSTALLDATE drifts for every
        # package since pacman runs at image-build time. Without this
        # rewrite the pacman-db layer hash drifts even when content is
        # byte-identical.
        db_root_path = src_mnt / "usr/lib/sysimage/pacman/local"
        EPOCH_FIELDS = {"%INSTALLDATE%", "%BUILDDATE%"}
        desc_normalized = 0
        for desc_file in db_root_path.glob("*/desc"):
            try:
                lines = desc_file.read_text().splitlines()
            except OSError:
                continue
            changed = False
            for i, line in enumerate(lines):
                if line in EPOCH_FIELDS and i + 1 < len(lines):
                    if lines[i + 1] != str(SDE):
                        lines[i + 1] = str(SDE)
                        changed = True
            if changed:
                try:
                    desc_file.write_text("\n".join(lines) + "\n")
                    desc_normalized += 1
                except OSError:
                    pass
        print(f"    normalized INSTALL/BUILDDATE in {desc_normalized} desc files")

        # mtree files are gzip-compressed and contain "time=<epoch>.<frac>"
        # on every entry. Rewrite each entry's time= to SDE. Also
        # normalize the sha256digest of the package-archive metadata
        # files (.BUILDINFO, .PKGINFO) — those are inside the original
        # .tar.zst archive and embed makepkg's wall-clock builddate,
        # packager string, and the full "installed = pkg-ver" list of
        # build-deps, all of which drift between builds even when the
        # final installed file set is identical. The mtree's
        # sha256digest field is informational on an immutable image
        # (pacman -Qkk isn't expected to be run); pinning these to a
        # fixed sentinel makes the mtree byte-stable.
        import gzip as _gzip, re as _re
        time_re = _re.compile(rb"time=\d+(?:\.\d+)?")
        repl = f"time={SDE}.0".encode()
        # Match a sha256digest=<64hex> on lines starting with .BUILDINFO or .PKGINFO
        meta_sha_re = _re.compile(
            rb"^(\./\.(?:BUILDINFO|PKGINFO)\s.*?sha256digest=)[0-9a-f]{64}",
            _re.MULTILINE,
        )
        meta_sha_repl = rb"\g<1>" + b"0" * 64
        mtree_normalized = 0
        for mtree_file in db_root_path.glob("*/mtree"):
            try:
                with _gzip.open(mtree_file, "rb") as f:
                    data = f.read()
            except OSError:
                continue
            new_data = time_re.sub(repl, data)
            new_data = meta_sha_re.sub(meta_sha_repl, new_data)
            if new_data != data:
                try:
                    # gzip.open() doesn't take mtime; use GzipFile via
                    # fileobj. filename="" suppresses the gzip header's
                    # FNAME field (else it would record this build's
                    # overlay mount path, defeating determinism). mtime=0
                    # keeps the header's mtime field stable.
                    with mtree_file.open("wb") as raw:
                        with _gzip.GzipFile(filename="", fileobj=raw,
                                            mode="wb", compresslevel=9,
                                            mtime=0) as gz:
                            gz.write(new_data)
                    mtree_normalized += 1
                except OSError:
                    pass
        print(f"    normalized time= in {mtree_normalized} mtree files")

        db_files: list[Path] = []
        db_arcname: dict[Path, str] = {}
        for root, _, files in os.walk(src_mnt / "usr/lib/sysimage/pacman"):
            for name in files:
                fp = Path(root) / name
                rel = str(fp.relative_to(src_mnt))
                db_files.append(fp)
                db_arcname[fp] = rel
        # os.walk returns files in readdir() order, which is filesystem-
        # dependent and not stable across runs. Sort before tar-write so
        # the layer's bytes are deterministic.
        db_files.sort()
        desc = add_layer_from_files(
            out_blobs, "pacman-db", db_files, db_arcname, src_mnt
        )
        if desc:
            layers_desc.append(desc)

        print(f"    pacman-db phase done in {time.monotonic()-phase_t:.1f}s")

        phase_t = time.monotonic()
        print(f"==> Building leftover-promotion layers ({len(promoted_files)} groups)")
        before_promo = len(layers_desc)
        for gname in sorted(promoted_files.keys()):
            files = promoted_files[gname]
            file_paths = [src_mnt / f for f in files]
            arcname = {src_mnt / f: f for f in files}
            desc = add_layer_from_files(
                out_blobs, f"leftover-{gname}", file_paths, arcname, src_mnt
            )
            if desc:
                layers_desc.append(desc)
        print(f"    {len(layers_desc) - before_promo} leftover-promotion layers built in {time.monotonic()-phase_t:.1f}s")

        phase_t = time.monotonic()
        print(f"==> Building leftover layer ({len(leftover_files)} files)")
        leftover_paths = [src_mnt / f for f in leftover_files]
        leftover_arcname = {src_mnt / f: f for f in leftover_files}
        # Empty mount-point dirs that must exist at runtime. The file walk
        # only collects files, and pacman 'files' DBs skip directory
        # entries, so without explicitly adding these the rechunked image
        # ships without them. bootc's tempfile::tempfile() needs /tmp
        # ENOENTs otherwise — and the misleading error is "Inspecting
        # filesystem /target: No such file or directory". /sysroot is
        # needed by ostree-prepare-root: without it, switch_root fails
        # in dracut and the system drops to emergency mode.
        extra_dirs = [
            ("tmp", 0o1777),
            ("var/tmp", 0o1777),
            ("proc", 0o555),
            ("sys", 0o555),
            ("dev", 0o755),
            ("run", 0o755),
            ("sysroot", 0o755),
            # sshd's privilege-separation chroot. Empty dir, eaten by the
            # files-only walk; sshd refuses to start without it
            # ("Missing privilege separation directory").
            ("usr/share/empty.sshd", 0o711),
            # avahi-daemon logs an error if /etc/avahi/services is missing.
            ("etc/avahi/services", 0o755),
            # flatpak's ostree-format repo is initialized by `flatpak
            # remote-add` in finalize-image.sh. Its subdirs start empty
            # (no flatpaks installed yet) and get dropped by our
            # files-only walk; flatpak then errors with "opendir(objects):
            # No such file or directory" on every command.
            ("var/lib/flatpak/repo/objects", 0o755),
            ("var/lib/flatpak/repo/refs", 0o755),
            ("var/lib/flatpak/repo/refs/heads", 0o755),
            ("var/lib/flatpak/repo/refs/mirrors", 0o755),
            ("var/lib/flatpak/repo/refs/remotes", 0o755),
            ("var/lib/flatpak/repo/state", 0o755),
            ("var/lib/flatpak/repo/tmp", 0o755),
            ("var/lib/flatpak/repo/tmp/cache", 0o755),
            ("var/lib/flatpak/repo/extensions", 0o755),
        ]
        desc = add_layer_from_files(
            out_blobs, "leftover", leftover_paths, leftover_arcname, src_mnt,
            extra_dirs=extra_dirs,
        )
        if desc:
            layers_desc.append(desc)
        print(f"    leftover phase done in {time.monotonic()-phase_t:.1f}s")

        print(f"==> {len(layers_desc)} layers built")

        # ─── Construct OCI config ──────────────────────────────────────
        # Pull the source image config so we preserve labels, env, etc.
        print("==> Reading source image config")
        src_inspect = json.loads(
            run(["sudo", "podman", "image", "inspect", args.src])
        )[0]
        src_config = src_inspect.get("Config", {})

        created_iso = time.strftime(
            "%Y-%m-%dT%H:%M:%SZ", time.gmtime(args.image_created_epoch)
        )
        config = {
            "created": created_iso,
            "architecture": "amd64",
            "os": "linux",
            "config": {
                "Env": src_config.get("Env", []),
                "Labels": src_config.get("Labels", {}),
                "Cmd": src_config.get("Cmd"),
                "Entrypoint": src_config.get("Entrypoint"),
                "WorkingDir": src_config.get("WorkingDir", ""),
            },
            "rootfs": {
                "type": "layers",
                "diff_ids": [d["_diff_id"] for d in layers_desc],
            },
            "history": [
                {
                    "created": created_iso,
                    "created_by": f"cache22 rechunk: layer {i}",
                    "empty_layer": False,
                }
                for i in range(len(layers_desc))
            ],
        }

        # Strip None values from config dict to avoid serializing nulls oddly
        for k in list(config["config"].keys()):
            if config["config"][k] is None:
                del config["config"][k]

        config_bytes = json.dumps(config, separators=(",", ":")).encode()
        config_desc = write_blob(
            out_blobs, config_bytes, "application/vnd.oci.image.config.v1+json"
        )

        # ─── Construct manifest ───────────────────────────────────────
        manifest = {
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.manifest.v1+json",
            "config": config_desc,
            "layers": [
                {k: v for k, v in d.items() if not k.startswith("_")}
                for d in layers_desc
            ],
            "annotations": {
                "containers.bootc": "1",
                "org.opencontainers.image.title": "cache22",
            },
        }
        manifest_bytes = json.dumps(manifest, separators=(",", ":")).encode()
        manifest_desc = write_blob(
            out_blobs, manifest_bytes, "application/vnd.oci.image.manifest.v1+json"
        )

        # ─── Write OCI image layout (skopeo `oci:` transport) ─────────
        # Standard OCI image layout v1.0:
        #   oci-layout — version marker
        #   index.json — references the manifest(s) by digest
        #   blobs/sha256/<digest> — all blobs (manifest, config, layers)
        (out_root / "oci-layout").write_text(
            json.dumps({"imageLayoutVersion": "1.0.0"})
        )
        index = {
            "schemaVersion": 2,
            "mediaType": "application/vnd.oci.image.index.v1+json",
            "manifests": [
                {
                    **manifest_desc,
                    "annotations": {
                        "org.opencontainers.image.ref.name": "rechunked",
                    },
                }
            ],
        }
        (out_root / "index.json").write_bytes(
            json.dumps(index, separators=(",", ":")).encode()
        )

        # Print summary
        total = sum(d["size"] for d in layers_desc)
        elapsed_total = time.monotonic() - t_start
        print()
        print(f"=== Rechunked image written to {out_root} ===")
        print(f"    layers: {len(layers_desc)}")
        print(f"    total compressed size: {total / 1024**3:.2f} GiB")
        print(f"    median layer size: ", end="")
        sizes = sorted(d["size"] for d in layers_desc)
        if sizes:
            print(f"{sizes[len(sizes) // 2]:,} bytes")
        print(f"    largest layer: {max(d['size'] for d in layers_desc):,} bytes")
        print(f"    smallest layer: {min(d['size'] for d in layers_desc):,} bytes")
        print(f"    total wall time: {elapsed_total:.1f}s ({elapsed_total/60:.1f} min)")
        print()
        print("Push with:")
        print(f"  sudo skopeo copy oci:{out_root}:rechunked docker://ghcr.io/<owner>/<repo>:<tag>")

    finally:
        print(f"==> Unmounting and removing container {ctr}")
        try:
            run(["sudo", "buildah", "umount", ctr])
        except subprocess.CalledProcessError:
            pass
        try:
            run(["sudo", "buildah", "rm", ctr])
        except subprocess.CalledProcessError:
            pass


if __name__ == "__main__":
    main()
