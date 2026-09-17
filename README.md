# VAIO P Haiku OS Patch Scripts

한국어 버전은 [`README.ko.md`](README.ko.md) 참고 / For Korean, see [`README.ko.md`](README.ko.md).

This folder contains the scripts that apply the Sony VAIO P (VGN-P70H_G) boot/install/hardware patches to [RenkuOS](https://github.com/RenkuOS/Source), an operating system forked from [Haiku](https://www.haiku-os.org/), and build it into a **32-bit** ISO.

The patches are applied to the RenkuOS source at its **nightly build**, not to Haiku's own source: the build script checks out the exact commit the current RenkuOS nightly was built from, applies `vaio-p-patches.diff` on top of it, and builds that.

The RenkuOS nightly itself is published for x86_64 only, which the VAIO P cannot run: its Atom Z520 has no long mode. The build takes the exact commit that nightly was built from and produces the `x86_gcc2h` hybrid instead. Details are under "Patch baseline" in [`AGENTS.md`](AGENTS.md).

Development and technical notes -- what each patch does, why, and what was measured -- are in [`AGENTS.md`](AGENTS.md).

## Repeated reboots at power-on are expected

On the VAIO P the second CPU cannot always be started: whether it answers is decided by the firmware once per power-on, and the only thing found to change the outcome is another POST. So when it does not answer, the boot loader **reboots the machine on purpose** and tries again, showing:

```
SMP: second CPU did not answer. Rebooting on purpose to re-roll the firmware state.
This is expected and may repeat several times before the machine finishes booting.
```

- It retries **at most 8 times**. Each retry is one POST of about 30 seconds, so allow **4-5 minutes** before deciding anything is wrong.
- It ends one of two ways: the second CPU answers and the machine boots with **two CPUs**, or all 8 retries are used and it boots with **one CPU**. Neither is a failure.
- Not normal: the same message repeating well beyond 8 reboots, or a `Kernel Debugging Land` / `PANIC` screen.

After it is up, this shows what happened on that boot:

```sh
grep -iE 'reroll|early wake' /var/log/syslog
```

`AP came up after N deliberate reboot(s)` means it got both CPUs; `AP unresponsive after 8 reroll(s)` means the retries ran out and it continued with one. Details are in "Repeated reboots at power-on are the reroll working" in [`AGENTS.md`](AGENTS.md).

## Do not run `pkgman update` (or update through HaikuDepot) on this machine

`pkgman update`/HaikuDepot's "Update" pull the latest `haiku` package -- which contains the kernel, all kernel add-ons, and the kits -- from the online repository and replace the one this ISO was built with, silently undoing every hardware-specific fix these patches make (in particular, re-enabling `x86_acpi_cstates` on this exact CPU, which hard-hangs the machine -- see "cpuidle" in [`AGENTS.md`](AGENTS.md)). Confirmed on real hardware: a freshly installed, working system stopped booting (Haiku logo shows, then freezes, no boot icons, no debug output even with it enabled -- because the machine reboots into a system now missing this ISO's fixes) immediately after running `pkgman update`. There is no supported way to update this system other than rebuilding and reinstalling from a newer patch baseline.

## Files

| File | Description |
|---|---|
| `vaio-p-patches.diff` | Unified diff containing every VAIO P patch. What each one does is documented in [`AGENTS.md`](AGENTS.md). Generated via `git diff HEAD --binary`. |
| `build-vaio-p-iso.sh` | Runs on **Linux (amd64)**. Clones RenkuOS/Source and buildtools, checks out the commit the current RenkuOS nightly was built from, applies the patch, builds the 32-bit cross-toolchain, and runs `jam -q @nightly-anyboot`. |
| `docker-build-vaio-p-iso.sh` | **macOS**-side wrapper. Sets up an amd64 Docker container (`ubuntu:22.04`, Rosetta-accelerated, named `vaio-p-builder`) with the whole build on a Docker named volume, runs `build-vaio-p-iso.sh` inside it, and copies the ISO out. |
| `AGENTS.md` / `AGENTS.ko.md` | Development and technical notes: what each patch does and why, what was measured on hardware, and the traps worth knowing before touching any of it. |
| `LICENSE` | MIT license covering the new code added by these patches (the `sony_ec` and `intel_est` drivers in particular). |

The legacy `x86_gcc2` cross-compiler requires `-m32` host support, which neither macOS nor arm64 Linux provide -- so it cannot be built directly on macOS, nor in an arm64 container. On macOS, always build through `docker-build-vaio-p-iso.sh`, which runs everything inside an amd64 Linux container and refuses to reuse a container of another architecture.

## Usage

### macOS

```sh
cd tools/vaio-p
./docker-build-vaio-p-iso.sh ~/renku-vaio-p.iso
```

Make sure Docker Desktop has **Use Virtualization Framework** and **Use Rosetta for x86/amd64 emulation** enabled — otherwise the build runs under full QEMU emulation instead of Rosetta acceleration and takes many hours instead of ~1-2.

### Linux

```sh
cd tools/vaio-p
./build-vaio-p-iso.sh ~/vaio-p-work ~/renku-vaio-p.iso
```

### Environment variables

- `SKIP_CROSS_TOOLS=1` : Skip rebuilding the cross-compiler if it already exists (useful when only a patch changed — the cross-tools build alone takes ~1-1.5 hours).
- `RENKU_REF` : Branch/tag/commit of RenkuOS/Source to build. Defaults to the commit the current nightly release was built from, read from its release notes -- not the `nightly` tag, which never moves (see "Patch baseline" in [`AGENTS.md`](AGENTS.md)). Falls back to the verified commit `f04d7eb54a` if the release cannot be read.
- `DISTRO_COMPATIBILITY` : `configure --distro-compatibility`. Defaults to `default`, as the RenkuOS nightly uses.
- `IMAGE_LABEL` : `HAIKU_IMAGE_LABEL`. Defaults to `RenkuOS`, as the nightly uses.
- `CONTAINER_NAME` (macOS wrapper only) : Build container name. Defaults to `vaio-p-builder`.
- `WORK_VOLUME_NAME` (macOS wrapper only) : Docker named volume holding the whole build -- source, toolchain and objects. Defaults to `haiku-vaio-p-work`. It must not be a macOS bind mount: the build reads and writes file types as extended attributes, which bind mounts (virtiofs) do not support.
- `JOBS` : Parallelism for `configure`/`jam`. Defaults to `nproc`.

### Why `--distro-compatibility default`

That is what the RenkuOS nightly builds with. It ships no trademarked artwork, so an installed system comes up without the desktop logo; [`restore-haiku-logo.sh`](restore-haiku-logo.sh) puts it back. The boot splash is unaffected either way, since the patch set no longer draws the logo at boot.

## After building

A successful build only verifies the source compiles — real verification requires the actual hardware: boot from USB with ACPI on and no Safe Mode, install to the internal disk (create an Intel partition map + BFS partition in DriveSetup first, then install), then confirm it survives a reboot.

## AI disclaimer

These patches were produced by a human working with Claude. The work was driven by measurements taken on the actual machine -- syslogs, KDL sessions, disassembled DSDT, direct reads of PCI config space and physical memory, and vendor errata documents -- and every fix described here was verified on the real hardware before being written down. Several conclusions in earlier drafts were wrong and were corrected only because the measurements contradicted them; a few open questions are still marked as unresolved rather than papered over.

**The Haiku project does not accept AI-assisted contributions, and none of this has been or should be submitted upstream.** It is a personal patch set for one machine, published in that spirit under the same MIT terms as the code it modifies. If you reuse any of it, please carry this notice with it.
