# cache22 image build. See docs/IMAGE_BUILD.md.
#
# Build args: VARIANT_FAMILY (cachy|arch), VARIANT_TYPE (kde|server),
# VARIANT (e.g. arch-kde). CI passes all three.

ARG BASE_IMAGE=docker.io/cachyos/cachyos-v3
ARG BASE_TAG=latest

# ─── Reproducibility env (applied to BOTH stages) ────────────────
# SOURCE_DATE_EPOCH = git commit timestamp passed by the CI workflow.
# - dracut --reproducible uses this for cpio mtimes (initramfs becomes
#   content-stable for same input modules)
# - kbuild uses it as __DATE__/__TIME__ replacement in DKMS module compiles
# - many other tools (gzip, ar, etc.) honor it for archive entry mtimes
# - KBUILD_BUILD_USER/HOST are baked into Linux module utsname strings
#   if not set explicitly; pinning eliminates that source of variance
ARG SOURCE_DATE_EPOCH=0

# ─── Stage: libfaketime (tiny, just installs libfaketime so other ─
# stages can COPY /usr/bin/faketime + /usr/lib/faketime out). Used
# downstream to wrap dkms (alpm-hook-triggered module compiles) and
# makepkg (aur-builder package builds) in faketime, pinning the
# wall-clock the actual compiler/linker sees so build outputs are
# byte-stable across fresh builds. Other operations (pacman, mirror
# TLS, GPG keyring) keep using real time so cert/key rotations don't
# break us.
#
# Pinned to archlinux:latest (NOT ${BASE_IMAGE}) because cachyos-v3
# ships an alpm hook chain that hangs indefinitely on `pacman -S
# libfaketime` in buildah's hook context (the 35-systemd-update.hook
# trying to talk to a non-running systemd, most likely). archlinux's
# hook set doesn't hit this. The output binary is identical either
# way — we only COPY files out.
FROM docker.io/archlinux:latest AS libfaketime
RUN pacman -Sy --noconfirm libfaketime

# ─── Stage 1: aur-builder ─────────────────────────────────────────
# Auto-detect packages cache22 lists that no configured repo provides,
# build them (plus transitive AUR deps) via paru into /aur-out. Stage
# is discarded after the main stage COPYs /aur-out, so base-devel /
# paru / cloned PKGBUILDs / etc. never reach the final image.
FROM ${BASE_IMAGE}:${BASE_TAG} AS aur-builder
ARG VARIANT_FAMILY
ARG VARIANT
ARG SOURCE_DATE_EPOCH=0
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} \
    KBUILD_BUILD_TIMESTAMP="@${SOURCE_DATE_EPOCH}" \
    KBUILD_BUILD_USER=cache22 \
    KBUILD_BUILD_HOST=cache22 \
    NV_BUILD_USER=cache22 \
    NV_BUILD_HOST=cache22-build

# Surgical faketime for AUR builds: shim /usr/local/bin/makepkg so the
# actual package-build invocation (the part that runs the compiler and
# may otherwise leak wall-clock into output binaries) sees a fixed
# clock. paru's pacman calls and git clones for PKGBUILDs continue to
# use real time, keeping mirror TLS + GPG verification working.
COPY --from=libfaketime /usr/bin/faketime /usr/bin/faketime
COPY --from=libfaketime /usr/lib/faketime /usr/lib/faketime
RUN install -d /usr/local/bin \
 && printf '#!/bin/sh\nexec /usr/bin/faketime "2026-05-06 00:00:00" /usr/bin/makepkg "$@"\n' \
        > /usr/local/bin/makepkg \
 && chmod +x /usr/local/bin/makepkg

COPY scripts/  /tmp/cache22-build/scripts/
COPY packages/ /tmp/cache22-build/packages/
RUN chmod +x /tmp/cache22-build/scripts/*.sh

RUN /tmp/cache22-build/scripts/inject-custom-repos-${VARIANT_FAMILY}.sh
RUN /tmp/cache22-build/scripts/build-aur-packages.sh \
        "/tmp/cache22-build/packages/${VARIANT_FAMILY}-common.txt" \
        "/tmp/cache22-build/packages/${VARIANT}.txt"

# ─── Stage 2: main image ──────────────────────────────────────────
FROM ${BASE_IMAGE}:${BASE_TAG}

ARG VARIANT_FAMILY=cachy
ARG VARIANT_TYPE=kde
ARG VARIANT=cachy-kde
ARG SOURCE_DATE_EPOCH=0
ENV SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} \
    KBUILD_BUILD_TIMESTAMP="@${SOURCE_DATE_EPOCH}" \
    KBUILD_BUILD_USER=cache22 \
    KBUILD_BUILD_HOST=cache22 \
    NV_BUILD_USER=cache22 \
    NV_BUILD_HOST=cache22-build

LABEL containers.bootc=1
LABEL org.opencontainers.image.source=https://github.com/cmspam/cache22
LABEL org.opencontainers.image.description="cache22 — immutable bootc image (${VARIANT})"
LABEL org.opencontainers.image.licenses=Apache-2.0

COPY scripts/      /tmp/cache22-build/scripts/
COPY packages/     /tmp/cache22-build/packages/
COPY system_files/ /tmp/cache22-build/system_files/
RUN chmod +x /tmp/cache22-build/scripts/*.sh

# Move the pacman DB into /usr/lib/sysimage so the immutable image
# carries it. Must run before any pacman op.
RUN /tmp/cache22-build/scripts/rewrite-pacman-paths.sh

RUN /tmp/cache22-build/scripts/inject-custom-repos-${VARIANT_FAMILY}.sh

# Pull in AUR builds from stage 1; inject [cache22-aur] in pacman.conf
# (no-op if stage 1 had nothing to build).
COPY --from=aur-builder /aur-out /var/cache/pacman/cache22-aur
RUN if [ -f /var/cache/pacman/cache22-aur/.has-packages ]; then \
        /tmp/cache22-build/scripts/inject-cache22-aur-repo.sh; \
    else \
        echo "==> aur-builder produced no packages; skipping [cache22-aur] inject."; \
    fi \
 && mkdir -p /usr/share/cache22 \
 && if [ -f /var/cache/pacman/cache22-aur/cache22-aur-pkgs.txt ]; then \
        cp /var/cache/pacman/cache22-aur/cache22-aur-pkgs.txt /usr/share/cache22/aur-pkgs.txt; \
        echo "==> Persisted AUR sidecar: $(wc -l < /usr/share/cache22/aur-pkgs.txt) packages"; \
    fi

RUN cp -av --remove-destination /tmp/cache22-build/system_files/common/. / \
 && if [ -d "/tmp/cache22-build/system_files/${VARIANT}" ]; then \
        cp -av --remove-destination "/tmp/cache22-build/system_files/${VARIANT}/." /; \
    fi

RUN pacman -Syy --noconfirm \
 && pacman-key --populate

# Pin the hostname returned by `hostname` (the shell command) so build-
# time tools that shell out to it see a stable value. nvidia-open-dkms
# bakes "Release Build (root@<HOSTNAME>)" into nvidia.ko's .modinfo,
# which then drives a different .note.gnu.build-id and module signature
# every build. /usr/local/bin precedes /usr/bin in PATH so this shim
# overrides the real binary; finalize-image.sh removes it before
# bootc-lint runs.
RUN install -d /usr/local/bin \
 && printf '#!/bin/sh\nexec echo cache22-build\n' > /usr/local/bin/hostname \
 && chmod +x /usr/local/bin/hostname

# Shim /usr/local/bin/dkms so the alpm hooks (which call `dkms` via
# PATH, and /usr/local/bin precedes /usr/bin) wrap the real binary
# with faketime. The shim runs from a PostTransaction hook after the
# bulk pacman -S finishes — by which point libfaketime (in
# {arch,cachy}-common.txt) has been installed, so /usr/bin/faketime
# is available. We don't COPY libfaketime from the libfaketime stage
# here because it'd file-conflict with the package install.
# finalize-image.sh removes the shim before bootc-lint so the runtime
# image has plain /usr/bin/dkms behavior.
RUN install -d /usr/local/bin \
 && printf '#!/bin/sh\nexec /usr/bin/faketime "2026-05-06 00:00:00" /usr/bin/dkms "$@"\n' \
        > /usr/local/bin/dkms \
 && chmod +x /usr/local/bin/dkms

# Strip comments + blanks; retry up to 5x for transient mirror 404s.
RUN pkglist=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' \
        "/tmp/cache22-build/packages/${VARIANT_FAMILY}-common.txt" \
        "/tmp/cache22-build/packages/${VARIANT}.txt") \
 && for attempt in 1 2 3 4 5; do \
        echo "==> pacman -S attempt $attempt"; \
        pacman -Syy --noconfirm; \
        if pacman -S --noconfirm --needed --disable-download-timeout $pkglist; then \
            echo "==> pacman -S succeeded on attempt $attempt"; \
            break; \
        fi; \
        if [ "$attempt" = "5" ]; then \
            echo "==> pacman -S failed after 5 attempts"; \
            exit 1; \
        fi; \
        echo "==> retrying in 60s"; \
        sleep 60; \
    done

# Re-apply overlay so post-install package files (e.g. ostree's
# prepare-root.conf) don't clobber our config.
RUN cp -av --remove-destination /tmp/cache22-build/system_files/common/. / \
 && if [ -d "/tmp/cache22-build/system_files/${VARIANT}" ]; then \
        cp -av --remove-destination "/tmp/cache22-build/system_files/${VARIANT}/." /; \
    fi

RUN /tmp/cache22-build/scripts/patch-ostree-dracut.sh
RUN /tmp/cache22-build/scripts/generate-initramfs.sh

# No SB signing or bootloader binaries shipped — sd-boot + UKI are
# assembled and signed at install / bootc-upgrade time by
# /usr/libexec/cache22/resign-uki against the per-machine sbctl key.
# See docs/SECUREBOOT.md.

RUN VARIANT=${VARIANT} /tmp/cache22-build/scripts/finalize-image.sh

RUN bootc container lint

# Strip [cache22-aur] from pacman.conf since the file:// repo it
# points at is about to be removed. The block (header + 2 lines)
# ends at the next blank line. Sed is a no-op when absent (cachy
# variants and arch-server skip the inject entirely).
RUN sed -i '/^\[cache22-aur\]/,/^$/d' /etc/pacman.conf \
 && rm -rf /tmp/cache22-build /var/cache/pacman/cache22-aur
