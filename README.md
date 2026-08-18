# VAIO P Haiku OS Patch Scripts

한국어 버전은 [`README.ko.md`](README.ko.md) 참고 / For Korean, see [`README.ko.md`](README.ko.md).

This folder contains the scripts that apply the Sony VAIO P (VGN-P70H_G) boot/install/hardware patches to a fresh Haiku OS source checkout and build it into an ISO.

Development and technical notes -- what each patch does, why, and what was measured -- are in [`AGENTS.md`](AGENTS.md).

## Do not run `pkgman update` (or update through HaikuDepot) on this machine

`pkgman update`/HaikuDepot's "Update" pull the latest upstream `haiku` package -- which contains the kernel, all kernel add-ons, and the kits -- from the online repository and replace the one this ISO was built with, silently undoing every hardware-specific fix these patches make (in particular, re-enabling `x86_acpi_cstates` on this exact CPU, which hard-hangs the machine -- see "cpuidle" in [`AGENTS.md`](AGENTS.md)). Confirmed on real hardware: a freshly installed, working system stopped booting (Haiku logo shows, then freezes, no boot icons, no debug output even with it enabled -- because the machine reboots into a system now missing this ISO's fixes) immediately after running `pkgman update`. There is no supported way to update this system other than rebuilding and reinstalling from a newer patch baseline.

## Files

| File | Description |
|---|---|
| `vaio-p-patches.diff` | Unified diff containing every VAIO P patch. What each one does is documented in [`AGENTS.md`](AGENTS.md). Generated via `git diff HEAD --binary`. |
| `build-vaio-p-iso.sh` | Runs on **Linux**. Automates cloning Haiku/buildtools, applying the patch, building the cross-toolchain, and running `jam -q @nightly-anyboot`. |
| `docker-build-vaio-p-iso.sh` | **macOS**-side wrapper. Sets up a case-sensitive disk image and a Docker container (`ubuntu:22.04`, Rosetta-accelerated), then runs `build-vaio-p-iso.sh` inside it. |
| `AGENTS.md` / `AGENTS.ko.md` | Development and technical notes: what each patch does and why, what was measured on hardware, and the traps worth knowing before touching any of it. |
| `LICENSE` | MIT license covering the new code added by these patches (the `sony_ec` and `intel_est` drivers in particular). |

The legacy `x86_gcc2` cross-compiler requires `-m32` host support, and modern macOS SDKs have dropped i386 linking entirely — so it cannot be built directly on macOS. On macOS, always build through `docker-build-vaio-p-iso.sh`, which runs everything inside a Linux container.

## Usage

### macOS

```sh
cd tools/vaio-p
./docker-build-vaio-p-iso.sh ~/haiku-vaio-p.iso
```

Make sure Docker Desktop has **Use Virtualization Framework** and **Use Rosetta for x86/amd64 emulation** enabled — otherwise the build runs under full QEMU emulation instead of Rosetta acceleration and takes many hours instead of ~1-2.

### Linux

```sh
cd tools/vaio-p
./build-vaio-p-iso.sh ~/vaio-p-work ~/haiku-vaio-p.iso
```

### Environment variables

- `SKIP_CROSS_TOOLS=1` : Skip rebuilding the cross-compiler if it already exists (useful when only a patch changed — the cross-tools build alone takes ~1-1.5 hours).
- `HAIKU_GIT_REF` : Branch/tag/commit of haiku.git to check out. Defaults to the pinned nightly commit `8b91c532fa` (see "Patch baseline" in [`AGENTS.md`](AGENTS.md)). Set it to `master` to track the tip instead; the patch may or may not still apply there.
- `JOBS` : Parallelism for `configure`/`jam`. Defaults to `nproc`.

### Why `configure --distro-compatibility official`

Without it, `HAIKU_DISTRO_COMPATIBILITY` defaults to `default`, which makes `headers/private/kernel/boot/images.h` pull in `images-sans-tm.h` — the trademark-free splash set, whose 372x96 logo image is *blank*. The boot icons come from the same header and are real, so the symptom is a boot screen with the row of icons and no Haiku logo above it. `official` selects `images-tm-development.h` (what upstream's own nightlies use) instead. The define is otherwise only read by About, Deskbar's leaf menu, Installer, and the first-boot prompt, all cosmetic.

## After building

A successful build only verifies the source compiles — real verification requires the actual hardware: boot from USB with ACPI on and no Safe Mode, install to the internal disk (create an Intel partition map + BFS partition in DriveSetup first, then install), then confirm it survives a reboot.

## AI disclaimer

These patches were produced by a human working with Claude. The work was driven by measurements taken on the actual machine -- syslogs, KDL sessions, disassembled DSDT, direct reads of PCI config space and physical memory, and vendor errata documents -- and every fix described here was verified on the real hardware before being written down. Several conclusions in earlier drafts were wrong and were corrected only because the measurements contradicted them; a few open questions are still marked as unresolved rather than papered over.

**The Haiku project does not accept AI-assisted contributions, and none of this has been or should be submitted upstream.** It is a personal patch set for one machine, published in that spirit under the same MIT terms as the code it modifies. If you reuse any of it, please carry this notice with it.
