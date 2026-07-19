# VAIO P Haiku OS Patch Scripts

한국어 버전은 [`README.ko.md`](README.ko.md) 참고 / For Korean, see [`README.ko.md`](README.ko.md).

This folder contains the scripts that apply the Sony VAIO P (VGN-P70H) boot/install/hardware patches to a fresh Haiku OS source checkout and build it into an ISO.

## Patch baseline

These patches were derived against the Haiku OS source as of **2026-07-19**. Some of the underlying bugs (e.g. the ACPICA Global Lock init race, ACPI IRQ trigger/polarity, PCI unaligned config access, the PS/2 multiplexer port-probing timeout) are generic correctness issues, not VAIO-P-specific — they may already be fixed upstream by the time you apply this against a newer checkout.

## What's patched

`vaio-p-patches.diff` is a single cumulative diff covering:

- **USB stability/boot speed** — `Hub.cpp`/`usb_private.h`/`BusManager.cpp`: bounded retry -> disable -> power-cycle backoff per port instead of retrying forever, an address-0 `GET_DESCRIPTOR` probe to skip pointless `SET_ADDRESS` retries, and an EHCI/UHCI BAR0 fixup for the Poulsbo chipset.
- **PS/2 multiplexer** — `ps2_common.cpp`: only probes mux sub-ports 1-3 that actually have something respond, instead of running the full magic-knock sequence (and eating the timeout) on ports nothing is plugged into.
- **WiFi (Atheros AR928X)** — `if_ath.c`/`if_athvar.h`: escalates repeated beacon-miss/bb-hang recovery to a full PCI power-cycle (D3->D0) of the adapter. `ieee80211_scan_sta.c`: stops `net80211` from auto-joining any open AP before a real join was ever requested (the STA-mode default candidate scan used to grab the nearest open neighbor AP at boot). `AutoconfigLooper.cpp`/`.h`: retries auto-join on a grace period instead of only once, and doesn't treat an unsolicited open-network association as "done."
- **Sony EC driver (new)** — `drivers/power/sony_ec/`: a new MIT-licensed driver for the Sony `SNY5001` ACPI device (SNC), covering brightness get/set, hotkey arming, and the wireless kill-switch/Fn-key notify events. Written from scratch against the ACPI protocol (documented in the driver's own comments), not derived from Linux's `sony-laptop.c`.
- **Webcam (UVC)** — `UVCCamDevice.cpp`/`.h`, `UVCDeframer.cpp`: adds YUY2 format decoding (this camera reports YUY2, not the Bayer format the existing decoder assumed) and fixes a buffer-position bug where frames kept concatenating instead of resetting, causing every frame after the first to be silently dropped.
- **Boot video** — `video.cpp`: this hardware's VESA BIOS doesn't support DDC/EDID at all, so the native 1600x768 panel resolution can never be auto-detected; the boot loader now picks it directly from the VESA mode list if present.
- **Boot speed/robustness (generic)** — `smp.cpp`: bounded timeouts around AP bring-up instead of spinning forever on a core that never responds. `evglock.c`: fixes an ACPICA race where the Global Lock SCI can fire synchronously during handler installation, before the lock it needs exists. `pci.cpp`: splits unaligned 32-bit config space accesses into two 16-bit ones instead of rejecting them outright. `acpi_irq_routing_table.cpp`: corrects IRQ polarity/trigger-mode to fixed values instead of trusting a possibly-wrong ACPI descriptor. `vfs_boot.cpp`: retries boot-partition discovery for slow-to-enumerate USB boot media instead of panicking immediately.
- **Installer** — `WorkerThread.cpp`/`.h`: actually marks the target partition active and writes MBR boot code after install, so a fresh install is bootable without a manual `writembr` step.
- **launch_daemon** — `Job.cpp`: retries launching a signature-based app for a while instead of failing immediately if `launch_daemon` hasn't seen it registered yet (matters on slow storage).

## Files

| File | Description |
|---|---|
| `vaio-p-patches.diff` | Unified diff containing all general-purpose VAIO P patches described above. Generated via `git diff`. |
| `build-vaio-p-iso.sh` | Runs on **Linux**. Automates cloning Haiku/buildtools, applying the patch(es), building the cross-toolchain, and running `jam -q @nightly-anyboot`. |
| `docker-build-vaio-p-iso.sh` | **macOS**-side wrapper. Sets up a case-sensitive disk image and a Docker container (`ubuntu:22.04`, Rosetta-accelerated), then runs `build-vaio-p-iso.sh` inside it. |
| `LICENSE` | MIT license covering the new code added by these patches (the `sony_ec` driver in particular). |

The legacy `x86_gcc2` cross-compiler requires `-m32` host support, and modern macOS SDKs have dropped i386 linking entirely — so it cannot be built directly on macOS. On macOS, always build through `docker-build-vaio-p-iso.sh`, which runs everything inside a Linux container.

## Usage

### macOS

```sh
cd tools/vaio-p
./docker-build-vaio-p-iso.sh ~/haiku.iso
```

Make sure Docker Desktop has **Use Virtualization Framework** and **Use Rosetta for x86/amd64 emulation** enabled — otherwise the build runs under full QEMU emulation instead of Rosetta acceleration and takes many hours instead of ~1-2.

### Linux

```sh
cd tools/vaio-p
./build-vaio-p-iso.sh ~/vaio-p-work ~/haiku.iso
```

### Environment variables

- `SKIP_CROSS_TOOLS=1` : Skip rebuilding the cross-compiler if it already exists (useful when only a patch changed — the cross-tools build alone takes ~1-1.5 hours).
- `HAIKU_GIT_REF` : Branch/tag/commit of haiku.git to check out. Defaults to whatever is currently checked out (or `master` on a fresh clone).
- `JOBS` : Parallelism for `configure`/`jam`. Defaults to `nproc`.

