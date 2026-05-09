# cache22 UKI migration — implementation tracker

**Status:** in progress · **Started:** 2026-05-09 · **Branch baseline:** `legacy-grub` (push-time `86f9fed`).

This document tracks the migration from `shim → grub → BLS → sb-signed vmlinuz` to `sd-boot → per-machine-signed UKI` with local key generation, modeled on NixOS lanzaboote. It exists to prevent silent omissions during a 30+ file refactor.

---

## Architecture summary

**Out:** central GH-secret SB key, shim, grub, bootupd, MOK enrollment, BLS Type-1 entries, build-time vmlinuz signing, `--bootloader=grub`, the entire Fedora-bootloader Containerfile stage (no more `FROM registry.fedoraproject.org/fedora:latest`, no `dnf install shim-x64 grub2-efi-x64`, no `/usr/lib/efi/` tree in the runtime image), **the separate /boot partition entirely** (UKIs live on ESP; kernel/initramfs live inside the deploy under `/usr/lib/modules/<kver>/`; /boot becomes either a regular directory on the rootfs that ostree can use for vestigial BLS entries we ignore, or simply absent).

**In:** per-machine sbctl-generated SB+TPM key, sd-boot signed by the same local key, signed UKI (kernel + initramfs + cmdline + signed PCR-11 policy) generated and placed on ESP by a post-bootc-upgrade hook, direct firmware DB enrollment via sd-boot's `secure-boot-enroll=force` (Microsoft DB keys also enrolled via `sbctl enroll-keys --microsoft` so Windows dual-boot keeps working). LUKS+TPM bound to PCR 11 via signed policy (`--tpm2-public-key=`), so TPM unseal survives every kernel update without re-enrollment.

**Invariants the implementation must uphold:**

- The signing key always exists. If `/var/lib/cache22/sbkey/` is missing on hook entry, regenerate before signing. Never error out for a missing key.
- UKIs are always signed, regardless of whether SB is enforcing in firmware. Flipping SB on later "just works" with no rebuild.
- SB enrollment is a separate user-toggled concern, owned by the `cache22-secureboot` helper, not implicit in install.
- LUKS and TPM are independently optional. Each combination must boot:
  - no SB, no LUKS, no TPM (dev/VM)
  - SB, no LUKS, no TPM (signed boot, no encryption)
  - SB + LUKS, no TPM (signed boot, passphrase every boot)
  - SB + LUKS + TPM (signed boot, TPM auto-unlock against signed PCR 11 policy)
- bootc rollback / status / upgrade / switch / edit semantics unchanged from the user's perspective.
- Hook never deletes an old UKI before all desired UKIs are confirmed present (lanzaboote's safety pattern).

---

## File-level inventory

### DELETE

- [x] `scripts/sign-secureboot.sh` — central-key kernel signing. Replaced by per-machine UKI signing in the runtime hook.
- [x] `scripts/build-sb-enrollment.sh` — DER conversion of the central cert. No central cert in the new model.
- [x] `scripts/generate-bootupd-metadata.sh` — bootupd payload generator. No bootupd in the new model.
- [x] `secureboot.cer` (repo root) — DER of central cert.
- [x] `secureboot.crt` (repo root) — PEM of central cert.
- [x] `system_files/common/usr/share/cache22/secureboot.crt` — runtime copy of central cert.

### REWRITE

- [x] `Containerfile` — drop Stage 0 `fedora-bootloader` **entirely** (lines 19–34) — no more `FROM registry.fedoraproject.org/fedora:latest`, no `dnf install shim-x64 grub2-efi-x64`, no rename to `EFI/cache22`. Drop `--mount=type=secret,id=sbkey` blocks (lines 172–222). Drop `generate-bootupd-metadata.sh`/`build-sb-enrollment.sh`/`sign-secureboot.sh` invocations. Drop `COPY --from=fedora-bootloader /usr/lib/efi/`. Drop the `/usr/lib/efi/` tree entirely from the image (no Fedora binaries needed anywhere — sd-boot ships in the Arch `systemd` package). Add: build-time UKI-tooling validation only (the actual UKI build happens at runtime). Keep mkinitcpio/dracut initramfs generation as-is (UKI consumes the per-deploy initramfs).
- [x] `installer/cache22-install` — full SB section rewrite. Remove `queue_mok_enrollment()`, MOK password constant, `mokutil` calls, `--bootloader=grub`, MokManager copy logic, `sbcert.der` ESP placement. **Drop the separate /boot partition entirely** (no more `[boot_part]`/`[boot_size]` in CFG, no `mkfs.ext4 boot`, no `mount $boot_part /target/boot`, no `BOOT_UUID` in fstab). Bigger ESP instead (default 2 G FAT32, holds sd-boot binaries + UKIs). Add: SB+LUKS+TPM choice flow; first-boot key generation via `sbctl create-keys`; `sbctl enroll-keys --microsoft`; sd-boot install via `bootctl install`; first-time `cache22-resign-uki` invocation before reboot. Use `--bootloader=none` and own the bootloader install ourselves.
- [x] `installer/cache22-repair` — replace grub repair paths with sd-boot equivalents; `bootctl is-installed`, `bootctl install` re-run, ESP key re-stage, UKI rebuild via `cache22-resign-uki`.
- [x] `installer/fedora-live/build-iso.sh` — *keep* Fedora live base (we still want the live ISO itself to boot under stock Secure Boot via Fedora's MS-signed shim — this is the install media, separate from the installed system). Drop any post-install grub/bootupd setup it currently scripts. Add sbctl, systemd-boot, ukify to the live env so the installer can run them.
- [x] Installer end-of-flow prompt: after a successful install, display a clear screen explaining the user must reboot into firmware setup, *either* disable Secure Boot, *or* clear the Platform Key to enter setup mode (so cache22 can auto-enroll its own keys via `sbctl enroll-keys --microsoft` on first boot). Include guidance for common firmware vendors (where the SB controls typically live). This replaces today's "MokManager screen on first boot" expectation.
- [x] `installer/README.md` — high-level UX rewrite (firmware setup mode prompt instead of MokManager dance).
- [x] `system_files/common/usr/bin/cache22-secureboot` — full rewrite. Subcommands become: `status` (SB state, sbctl enrollment state, key fingerprint, UKI signature), `enable` (generate key if missing, walk user through firmware setup mode, `sbctl enroll-keys --microsoft`, switch sd-boot to `secure-boot-enroll=force`), `disable` (remove our key from firmware DB, leave Microsoft, leave the local key file alone), `rotate-keys` (regenerate key, re-sign all UKIs, re-enroll, re-seal LUKS).
- [x] `system_files/common/usr/bin/cache22-encryption` — switch enrollment to `--tpm2-public-key=/var/lib/cache22/sbkey/tpm-pcr11.pub --tpm2-public-key-pcrs=11` (signed PCR 11 policy). Remove `--tpm2-pcrs=0+7` direct binding. Add `--with-pin` opt-in. Update help text and docs/SECUREBOOT.md correspondingly.
- [x] `system_files/common/usr/bin/cache22-karg` — write `/etc/cache22/extra-cmdline` (newline-separated kargs, our format) instead of `/etc/bootc/kargs.d/50-cache22-user.toml`. After write, trigger `systemctl start cache22-resign-uki.service` synchronously. Update help text (no more "hit `e` in grub menu" advice).
- [x] `system_files/common/usr/bin/cache22-update` — remove `--apply` (which races our hook); explicit reboot prompt. Add explicit `systemctl start cache22-resign-uki.service` after `bootc upgrade` so the hook runs before any reboot the user might invoke.
- [x] `system_files/common/usr/bin/cache22-changelog` — already fixed for parser bug; spot-check the BLS-entry-reading paths still apply or need replacement.
- [x] `system_files/common/usr/bin/cache22-rebase` — same finalize chain change as `cache22-update`; trigger UKI rebuild after `bootc switch`.
- [x] `system_files/common/etc/dkms/framework.conf` — points at central SB key today; either remove signing or repoint at `/var/lib/cache22/sbkey/db.{key,pem}`. Decision: repoint (DKMS modules continue to be signed locally for consistency with the per-machine model).
- [x] `system_files/common/usr/lib/bootc/kargs.d/00-cache22.toml` — kargs become the *image-default* portion that gets baked into every UKI. Probably keep contents (`rw`, `console=tty0`); helper hook reads this + extra-cmdline to assemble `.cmdline`.
- [x] `system_files/common/usr/lib/systemd/system-preset/50-cache22.preset` — drop `bootloader-update.service` (bootupd unit); add `cache22-resign-uki.path` enable, drop `systemd-boot-update.service` (we manage sd-boot ourselves to avoid clobbering local signature).
- [x] `system_files/common/etc/dracut.conf.d/10-cache22.conf` — verify `add_dracutmodules+=" crypt dm "` still right (yes — for LUKS); verify nothing references grub/shim. Likely no changes.
- [x] `packages/arch-common.txt` — drop `grub`, `bootupd`, `mokutil`, `efitools`-if-only-for-shim-stuff, `sbsigntools` (sbctl shells out but ukify uses python-cryptography). Keep `sbctl`, `systemd-ukify`, `efibootmgr`, `cryptsetup`, `tpm2-tools`, `tpm2-tss`, `dracut`, `swtpm`. Add `systemd` is already implicit (sd-boot ships in `systemd` package on Arch).
- [x] `packages/cachy-common.txt` — same diff as arch-common.
- [x] `.github/workflows/build-image.yml` — drop the SB key secret reference (`secrets.SB_KEY` or similar; verify the actual var name) and the `--mount=type=secret,id=sbkey,src=/tmp/sbkey.pem` build-arg path. Drop the cert artifact upload if any. The package-diff and rechunker progress changes from earlier today stay.
- [x] `.github/workflows/build-iso.yml` — drop SB key references; ISO ships unsigned (the user signs at install time anyway).
- [x] `ARCHITECTURE.md` — full rewrite of "Bootloader" + "Secure Boot" sections.
- [x] `README.md` — update SB/install description.
- [x] `docs/SECUREBOOT.md` — full rewrite. New chain: `firmware (PK=ours, KEK=ours, db=ours+MS) → sd-boot (signed by us) → UKI (signed by us, includes PCR 11 signed policy)`. Document install-time setup-mode flow, not MokManager dance.
- [x] `docs/INSTALLER.md` — rewrite the SB+TPM choice flow to match new installer; document firmware setup-mode prompt; remove all MOK references.
- [x] `docs/UPDATES.md` — describe `cache22-resign-uki` hook firing on every `bootc upgrade`; sd-boot picks UKI by `.osrel` `VERSION_ID`; no more BLS entries.
- [x] `docs/IMAGE_BUILD.md` — drop SB-signing build step; describe that the image ships unsigned and signing happens at user install.

### ADD

- [x] `system_files/common/usr/lib/systemd/system/cache22-resign-uki.service` — oneshot, `WantedBy=bootc-status-updated.target`, also `Before=systemd-reboot.service` to maximize chance of completing before user-issued reboot. Body shells out to `/usr/libexec/cache22/resign-uki`.
- [x] `system_files/common/usr/lib/systemd/system/cache22-resign-uki.path` — fallback path watcher on `/etc/cache22/extra-cmdline` so karg edits trigger a rebuild even if the karg tool wasn't used.
- [x] `system_files/common/usr/libexec/cache22/resign-uki` — the actual hook. ~150 lines bash. Walks `bootc status --json` deploys, checks `/var/lib/cache22/sbkey/` (regenerates via sbctl if missing), assembles cmdline (image kargs + `/etc/cache22/extra-cmdline` + `ostree=<deploy-path>`), invokes `ukify build` per deploy with `--secureboot-private-key`, `--secureboot-certificate`, `--pcr-private-key`, `--pcr-public-key`. Atomic write to ESP. GC stale UKIs only after all writes succeed.
- [x] `system_files/common/usr/libexec/cache22/sb-key-init` — idempotent helper called by both installer and hook to ensure `/var/lib/cache22/sbkey/` is populated. Wraps `sbctl create-keys` (PK/KEK/db) and generates a TPM PCR-policy keypair.
- [x] `system_files/common/etc/cache22/extra-cmdline` — empty file shipped in the image; users append to it via `cache22-karg`. Newline-separated entries, blank lines and `#` comments allowed.
- [x] `system_files/common/usr/lib/tmpfiles.d/cache22-uki.conf` — ensure `/var/lib/cache22/sbkey/` (mode 0700, root) and `/etc/cache22/` exist.
- [ ] `docs/UKI.md` — new doc explaining the UKI architecture, hook lifecycle, key management, recovery procedures. (Or fold into rewritten SECUREBOOT.md — decide during write.)

### NO CHANGE EXPECTED (verify only)

- [x] `scripts/finalize-image.sh` — should already be SB-agnostic; verify no shim/grub/bootupd touches.
- [x] `scripts/rechunk-cache22.py` — bootloader-agnostic.
- [x] `scripts/build-aur-packages.sh` — unrelated.
- [x] All `system_files/<variant>/...` — desktop/server-specific files; SB-agnostic.

---

## Memory updates

After implementation, update these files in `/home/charlesmiller/.claude/projects/-home-charlesmiller-Development-Claude/memory/`:

- [x] `project_cache22_v0x_architecture.md` — update architecture summary; "v0.x" should probably bump to "v0.y" or be retitled. New chain, no shim, no grub, no bootupd.
- [x] `project_cache22_sb_chain.md` — major rewrite. Old shim+MOK chain notes are obsolete. New title: "cache22 SB chain (UKI, validated YYYY-MM-DD)". Document: sbctl direct DB enrollment + Microsoft keys, ukify per-deploy at hook time, signed PCR 11 LUKS policy.
- [x] `project_cache22_packages.md` — update package list deltas (grub, bootupd, mokutil out; see file-level inventory above).
- [ ] `project_cache22_research.md` — add findings from today's research (lanzaboote model, signed PCR policy, bootc-status-updated hook).
- [ ] `project_cache22_v01_state.md` — retire (or update to reflect post-migration state).
- [ ] `project_cache22_bootc_quirks.md` — verify still relevant; may need addition about `bootc upgrade --apply` racing post-stage hooks.

---

## Implementation phases

### Phase 0 — preflight (this doc + branch)
- [x] Push `legacy-grub` branch from `86f9fed`.
- [x] Survey codebase, inventory changes.
- [x] Write this tracking doc.
- [x] User reviews and green-lights.

### Phase 1 — image-build pipeline
- [x] Drop SB-signing stage from Containerfile.
- [x] Delete `sign-secureboot.sh`, `build-sb-enrollment.sh`, `generate-bootupd-metadata.sh`, `secureboot.{cer,crt}`, `system_files/.../secureboot.crt`.
- [x] Update `packages/*-common.txt`.
- [x] Update `.github/workflows/build-image.yml` to drop SB secret usage.
- [ ] Verify build still completes (no SB key needed in CI now).

### Phase 2 — runtime hook
- [x] Write `/usr/libexec/cache22/sb-key-init`.
- [x] Write `/usr/libexec/cache22/resign-uki`.
- [x] Write systemd units (`cache22-resign-uki.service` + `.path`).
- [x] Write `/etc/cache22/extra-cmdline` ship-an-empty-file + tmpfiles.d.
- [x] Update preset.

### Phase 3 — helper bins
- [x] Rewrite `cache22-secureboot` (status/enable/disable/rotate-keys subcommands).
- [x] Rewrite `cache22-encryption` (signed PCR-11 enrollment).
- [x] Rewrite `cache22-karg` (writes extra-cmdline, triggers hook).
- [x] Update `cache22-update` (drop `--apply`, explicit hook + reboot).
- [x] Update `cache22-rebase` (same).
- [x] Spot-check `cache22-changelog`.
- [x] Update `dkms/framework.conf` to point at per-machine key.

### Phase 4 — installer
- [x] Rewrite SB/TPM/LUKS choice flow in `installer/cache22-install`.
- [x] Remove all MOK code paths.
- [x] Switch to `bootc install --bootloader=none` + manual `bootctl install` + key gen + first UKI build.
- [x] Update `installer/cache22-repair`.
- [x] Update `installer/fedora-live/build-iso.sh` if present-grub stuff remains.
- [x] Update `installer/README.md`.

### Phase 5 — documentation
- [x] Rewrite `docs/SECUREBOOT.md`.
- [x] Rewrite `docs/INSTALLER.md`.
- [x] Rewrite `docs/UPDATES.md`.
- [x] Update `docs/IMAGE_BUILD.md`.
- [x] Update `ARCHITECTURE.md`.
- [x] Update `README.md`.
- [ ] Add `docs/UKI.md` if standalone (or fold into SECUREBOOT.md — decide during write).

### Phase 6 — memory + finalize
- [x] Update memory files per inventory above.
- [ ] **Logical-chunk commits** per phase (Containerfile/scripts, hook, helpers, installer, docs, memory). Held local until everything is in place.
- [ ] **Single push** so CI sees the complete change set at once (avoids broken-mid-migration builds).
- [ ] Verify GH Actions build succeeds without SB secret.
- [ ] Hand off to user for QEMU + real-hardware testing.

---

## Open questions / parking lot

- bootc may grow native `bootc install --bootloader=systemd` support (issue #806). Until then we use `--bootloader=none` and own the install. When upstream ships, switch over and delete our install code.
- `systemd-pcrlock` is still experimental in v260 (March 2026). Skip it for v1; revisit when upstream removes the experimental warning, then layer it on for PCR 7 binding.
- DPS-based partitioning (Discoverable Partitions Spec) is *nice-to-have* — with local UKI signing we know all UUIDs at sign time and can put them in cmdline directly, so DPS isn't load-bearing. Keep current installer's UUID-based approach for v1 to minimize churn; consider DPS as a follow-up cleanup.
- Out-of-repo concern: cache22-shell installer hooks live partly in a private repo (per `feedback_keep_personal_out_of_public.md`). Anything in this migration that requires changes there gets noted as a hand-off list at the end.
- Test-script edits sitting in working tree (`scripts/test-buildah-determinism.sh` modified, `scripts/test-dkms-determinism.sh` untracked) are unrelated to this migration; left alone.

---

## Out-of-repo follow-ups

(Filled in as encountered during implementation.)

---

## Validation checklist (post-implementation, by user on real hardware)

- [ ] QEMU: image boots without SB.
- [ ] QEMU: image boots with SB after `cache22-secureboot enable` + firmware setup mode + reboot.
- [ ] QEMU: `bootc upgrade` produces new UKI on ESP.
- [ ] QEMU: `bootc rollback` flips boot ordering correctly.
- [ ] QEMU: `cache22-karg add foo=bar` produces new UKI with the karg in `.cmdline`.
- [ ] Real hardware: TPM2 LUKS enrollment via `cache22-encryption enroll`.
- [ ] Real hardware: TPM2 unseal works after `bootc upgrade` (signed PCR 11 policy holds).
- [ ] Real hardware: dual-boot Windows still boots.
