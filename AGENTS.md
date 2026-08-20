# VAIO P Haiku OS Patches -- Development Notes

한국어 버전은 [`AGENTS.ko.md`](AGENTS.ko.md) 참고 / For Korean, see [`AGENTS.ko.md`](AGENTS.ko.md).

Install and build instructions live in [`README.md`](README.md). This file is everything else: what each patch does and why, what was measured rather than assumed, and the traps that cost time the first time around.

## Patch baseline

These patches are derived against, and verified on, nightly commit **`8b91c532fa` (hrev99002+148, 2026-08-15)**. `build-vaio-p-iso.sh` pins that exact commit rather than following `master`: haiku.git moves several times a day, and an unpinned build silently mixes an untested upstream state into an ISO whose entire purpose is booting one specific fragile machine. `HAIKU_GIT_REF=master` overrides it. They were originally written against the 2026-07-21 source; the earlier `r1beta6`-based version of the diff is in this file's git history.

Some of the underlying bugs (e.g. the ACPICA Global Lock init race, ACPI IRQ trigger/polarity, PCI unaligned config access, the PS/2 multiplexer port-probing timeout, the USBKit `SetAlternate()` bug, the UHCI halt-recovery gap, all of the EHCI isochronous fixes, the UVC frame-index bug, and the SMP AP bring-up retry) are generic correctness issues, not VAIO-P-specific — they may already be fixed upstream by the time you apply this against a newer checkout. If a patch fails to apply, check whether it's already fixed before re-deriving it.

Three of them already were, and their hunks are consequently no longer in the diff:

| Was patched | Fixed upstream by | Notes |
| --- | --- | --- |
| `headers/private/kernel/kernel.h` (`SET_BIT`/`CLEAR_BIT` mask semantics) | `0dc37ccfb5` | The macros were deleted outright and their three h2-driver call sites written as plain bit operations. |
| `acpi_lid.cpp` (the `position > 0` early return that spun `power_daemon`) | `15c199f8fd` | Same removal, same reason. |
| `ehci.cpp` (12-bit `TLENGTH` overflowing into the status bits) | `051bb37f50` | The new `EHCI_ITD_TLENGTH(x)` macro masks to `0x0fff` itself. The other three EHCI isochronous fixes (frame chaining, unlinking every iTD, and the starting-frame race) are still needed and still in the diff. |

### Upstream commits this diff reverts

Going the other way, the diff also **reverts** four upstream commits that landed shortly before the pin, restoring the boot loader's previous timing implementation:

| Reverted | What it changed |
| --- | --- |
| `a89c12444a` | Boot loader takes `spin()` from BIOS `INT 15h/86h` and `system_time()` from `INT 1Ah`, instead of its own TSC-based implementation. |
| `30d3006ec7` | TSC calibration moved out of the boot loader into the kernel, always using PIT channel 2. |
| `11b378746a` | Added an overflow assert to `spin()`. |
| `774b6a58ae` | Falls back to `INT 1Ah` when `INT 15h/86h` doesn't work. |

The SMP AP bring-up retry patch (see "Boot speed/robustness" below) drives `spin()` hard on a path that has to work before anything else does -- `spin(10000)` between IPIs, `spin(200)` before the STARTUP IPI, and up to 500 x `spin(1000)` waiting for each AP -- and it was developed and verified against the TSC implementation. Routing all of that through this unit's BIOS instead is not a small change of footing: this is the same BIOS that never acknowledges the EHCI legacy handoff (see "Early EHCI BIOS handoff" above), and `774b6a58ae` -- an `INT 1Ah` fallback added days later for "a problem reported on the forums" -- suggests the new path already misbehaves on real machines. Upstream tested it in QEMU and VMware.

So the reverts are a deliberate hold, not a claim that upstream is wrong. Dropping them is worth trying on a spare boot -- if the machine still comes up, delete these four hunks and regenerate the diff.

Note that `abf211e2eb` (deterministic boot-device block checksums), which landed in the same window, is **not** reverted and does not need to be: the `disk_identifier` record stores `(offset, sum)` pairs and the kernel re-reads whichever offsets the boot loader wrote, so changing which blocks get checksummed keeps both sides in agreement by construction. It touches none of the files this patch does.

Since the target is a moving branch, `build-vaio-p-iso.sh` applies the diff with `git apply -3`, so hunks whose surrounding code merely shifted are merged automatically; it only stops if a hunk genuinely conflicts.

## What's patched

`vaio-p-patches.diff` is a single cumulative diff covering:

- **UHCI on Intel SCH (the headline fix)** — `uhci.cpp`: on the Poulsbo/SCH chipset (device IDs 0x8114-0x8116), the UHCI companion controllers **do not implement the standard USBLEGSUP config register at 0xC0**, and writing the usual legacy-support handoff value there (as this driver, like most UHCI drivers, always did) corrupts the controller's transfer engine in bizarre ways: the schedule appears to run (frame counter advancing, no error bits) but TDs execute wrongly or not at all — ActLen stuck at 0x7ff, transfers trampling memory past their buffers, "host controller process error" halts, and **no USB 1.1 device ever enumerating on any of the three companions**. The exact same failure was hit and root-caused by the coreboot/SeaBIOS port to this chipset (https://www.seabios.org/pipermail/seabios/2012-August/004327.html). The fix skips that one register write on these device IDs. With it, low/full-speed devices (USB 1.1 mice/keyboards on the external ports, and the internal Bluetooth module) enumerate and work for the first time. Additionally `Start()` now sets the Configure Flag and 64-byte reclamation bits alongside Run, matching Linux's uhci-hcd.
- **USB stability/boot speed** — `Hub.cpp`/`usb_private.h`/`BusManager.cpp`: bounded retry -> disable -> power-cycle backoff per port instead of retrying forever, an address-0 `GET_DESCRIPTOR` probe to skip pointless `SET_ADDRESS` retries, and an EHCI/UHCI BAR0 fixup for the Poulsbo chipset. A port that exhausts the full retry/power-cycle backoff is ignored until a fresh connection event after a 5-second cooldown (up to 3 re-arms, then for the rest of the boot) — this matters for internal devices whose EC-controlled power arrives only after the first enumeration attempts have already failed and been given up on. `uhci.cpp` similarly grants a controller that gave up on halt recovery another recovery attempt after a cooldown (up to 3), since early-boot halts can be caused by a device that simply wasn't powered yet.
- **Early EHCI BIOS handoff (Poulsbo)** — `pci_fixup.cpp`: this machine's BIOS never acknowledges the normal EHCI legacy-support handoff ("bios won't give up control" on every boot), and the EHCI driver's own force-takeover happens too late: the companion UHCI controllers (lower PCI function numbers) initialize and start enumerating devices first, while the BIOS still believes it owns USB and keeps intervening via SMM — observed as repeated UHCI "host process error" halts that previously spiraled until the halt-recovery gave up. The existing Poulsbo BAR0 fixup now also performs the full legacy handoff (polite request, then forced BIOS-semaphore clear and SMI disable) at PCI scan time, before any USB driver runs. With this, the UHCI halt spiral is gone — remaining halts recover cleanly on the first try.
- **UHCI controller halt recovery** — `uhci.cpp`/`.h`: on some hardware, this controller halts (`process error` -> `host controller halted`) when talking to a misbehaving device, and the driver previously just disabled interrupts and left the controller (and everything sharing it) permanently dead for the rest of the boot -- a literal `// ToDo: cancel all transfers and reset the host controller` in the source. Now it actually cancels in-flight transfers (properly unlinking them from the schedule, not just the software bookkeeping -- an earlier attempt at this that skipped that step caused an immediate re-halt loop that pegged the CPU), resets the controller, and restarts the schedule. If halts keep recurring in a tight loop anyway (observed on hardware where restarting the schedule alone re-triggers the fault, with no device activity involved), it gives up after a few tries within 2 seconds instead of looping forever.
- **PS/2 multiplexer** — `ps2_common.cpp`: only probes mux sub-ports 1-3 that actually have something respond, instead of running the full magic-knock sequence (and eating the timeout) on ports nothing is plugged into.
- **WiFi (Atheros AR928X)** — `if_ath.c`/`if_athvar.h`: escalates repeated beacon-miss/bb-hang recovery to a full PCI power-cycle (D3->D0) of the adapter. `ieee80211_scan_sta.c`: stops `net80211` from auto-joining any open AP before a real join was ever requested (the STA-mode default candidate scan used to grab the nearest open neighbor AP at boot). `AutoconfigLooper.cpp`/`.h`: retries auto-join on a grace period instead of only once, and doesn't treat an unsolicited open-network association as "done."
- **Sony EC driver (new) — including working Fn+F5/F6 brightness keys** — `drivers/power/sony_ec/`: a new MIT-licensed driver for the Sony `SNY5001` ACPI device (SNC), covering brightness get/set, hotkey arming, and the wireless kill-switch/Fn-key notify events. On every kill-switch toggle it requests both WLAN radio power (SNC `F124` sub-function 4) and Bluetooth module power (sub-function 6) — both derived from this model's disassembled DSDT, and neither is something the EC does on its own — so WiFi actually comes back after an off/on cycle instead of staying dead, and the Bluetooth module gets its logic power enabled (readback via sub-function 5 confirms `BTPW` sticks, and the module's USB presence visibly follows it). It also requests Bluetooth power once, unconditionally, ~10 seconds after boot (not just on kill-switch toggle), since some units never toggle the switch at all. (The indicator LED next to the switch is not EC/software-controllable on this unit: the `WLSL` bit writes and reads back fine but has no visible effect.) Written from scratch against the ACPI protocol (documented in the driver's own comments), not derived from Linux's `sony-laptop.c`.
  - **Fn+F5/F6 now actually dim/brighten the panel.** All twelve Fn+Fn-row keys funnel through the DSDT's `_Q0A`/`_Q0B` EC queries into one shared notify (handle `0x0100`); the driver reads the real per-key code back via `F100` sub-function 2 (`BUF0 = SNC.ECR`, itself populated from `H8EC.HKCD` right before the notify fires) and identified F5/F6 by testing on real hardware (Fn+F5 → code `0x05`/`0x85`, Fn+F6 → `0x06`/`0x86`; press vs. release wasn't distinguished, so the driver acts once on the non-`0x80` code). The harder part: this model's `SBRT` ACPI method only ever reaches the SNC's own scratch register and fires `ASLE`, a "backlight changed" notification meant for the Intel graphics driver to act on -- and Haiku has no such driver for this PowerVR SGX-based Poulsbo/GMA500 chip (see "graphics acceleration" below), so nothing was ever listening. A first attempt guessed the classic Intel mobile `BLC_PWM_CTL` MMIO register (period/duty in bits 31:16/15:0) — it visibly changed the backlight, proving *some* register at that offset affects it, but the level-to-brightness order came out scrambled (readback of the computed duty cycle was confirmed monotonic, so the bug wasn't in the math — it was the wrong register for this chip's actual layout). Intel's [SCH US15W datasheet](https://www.versalogic.com/wp-content/themes/vsl-new/assets/resources/support/ocelot/Intel_SCH_Specification_Mar_2009.pdf) (doc 319537, Graphics/Video/Display D2:F0 section) documents the real mechanism instead: the **LBB** (Legacy Backlight Brightness) register at **PCI config space offset 0xF4**, a plain linear 0 (dimmest) - 255 (brightest) byte -- no period/duty math needed at all, and confirmed correct (monotonic, evenly spaced) on real hardware once switched to it.
- **Bluetooth (fully working: local device, remote scanning, kill-switch recovery, boot auto-start)** — this unit's Bluetooth module was long presumed dead hardware, based on what looked like a complete elimination chain: EC power request demonstrably working (`BTPW` readback, USB presence-detect following power), healthy-looking controller, yet never an answer to a single `GET_DESCRIPTOR`. That chain had one unverifiable hidden assumption — that the UHCI controller could successfully perform a transfer at all — and it was false: the SCH USBLEGSUP corruption (see the headline fix above) meant no device on any UHCI companion could ever enumerate, indistinguishable from software from a dead module. With the UHCI fix the module enumerates and Haiku's `h2generic` driver binds it, but three further bugs in the userland Bluetooth stack still stood between that and an actually usable system:
  - **`headers/private/kernel/kernel.h`** — `SET_BIT`/`CLEAR_BIT` shifted their second argument (`1 << b`) while `GET_BIT` masked it directly (`a & b`); the h2 driver's `bt_transport_status_t` flags (`RUNNING = 1<<1`, etc.) are already final bitmasks, so `SET_BIT(state, RUNNING)` actually set bit 0x4 while `GET_BIT(state, RUNNING)` checked bit 0x2 — the transport logged "Device online" and then refused every single HCI command forever with `B_DEV_NOT_READY`, since the RUNNING flag it had supposedly just set could never be observed as set. Fixed to match `GET_BIT`'s mask semantics (its only callers are the three h2 driver files; nothing else in the tree uses these macros).
  - **`servers/bluetooth/BluetoothServer.cpp`** — `HandleSimpleRequest()` permanently unregistered (and deleted) a local device the instant a *single* HCI command failed to submit. `LocalDevice`'s constructor fires six of these back-to-back right after acquisition, so one transient USB hiccup during that burst was enough to silently wipe the device from `fLocalDevicesList` for the rest of the session — every later "Local devices found on system:" lookup came back empty with nothing in the log to explain why. Now a single failed request just fails; the device stays registered.
  - **`servers/bluetooth/HCITransportAccessor.cpp`/`.h`** — the VAIO P's EC-driven wireless kill switch disables the USB port the Bluetooth module hangs off (see `sony_ec` below), so toggling it off and back on physically replugs the module; the file descriptor `bluetooth_server` opened at boot dies (`EBADF`) and nothing ever reopened it, permanently breaking Bluetooth until reboot. `IssueCommand()` now detects `EBADF`, reopens the same devfs path, and re-issues `BT_UP` before retrying the command.
  - **`preferences/bluetooth/BluetoothMain.cpp`/`.h`** — opening the Preferences window the instant `be_roster->IsRunning()` flips true raced the server's own async device discovery (a race the original author's own TODO comment already flagged); now it retries for a bounded number of tries until `LocalDevice::GetLocalDeviceCount()` actually returns a device, not just until the server's team exists.
  - **`data/launch/user`** — `bluetooth_server` now auto-starts as a `launch_daemon` service (`requires x-vnd.Be-TSKB`, i.e. after Deskbar) instead of needing a manual "Launch now" from Preferences; it was deliberately *not* added to the earlier, pre-Deskbar `data/launch/system` stage, since `BluetoothServer::ReadyToRun()`'s `_InstallDeskbarIcon()` silently no-ops if Deskbar's team doesn't exist yet.

  (The `sony_ec` power plumbing below — kill-switch handler plus a one-shot request ~10 seconds after boot — remains required for the module to have power at all.)
- **EHCI isochronous fixes (kernel, generic)** — `ehci.cpp`/`.h`: four real bugs in the isochronous path, dormant only because almost nothing exercises it: (1) a per-transaction length that exceeds the iTD's 12-bit TLENGTH field bled into the adjacent status bits, corrupting the descriptor at submission time (any high-bandwidth endpoint's `wMaxPacketSize` decodes to >4095 bytes, so USB2 cameras hit this immediately); (2) an off-by-one in `fNextStartingFrame` chaining left a guaranteed 1-frame (1ms) scheduling gap between consecutive submissions, silently losing whatever an isochronous IN device transmitted in it; (3) completing a multi-iTD transfer freed all its iTDs but only ever unlinked the last one from its frame chain, leaving the other frame slots pointing at freed memory (real use-after-free kernel panic); (4) the starting-frame decision and its reservation weren't atomic, racing two concurrent submissions into overlapping frame slots.
- **usb_raw + USBKit: overlapped isochronous transfers** — `usb_raw.cpp`/`.h`, `USBEndpoint.cpp`, `USBKit.h`: new `B_USB_RAW_COMMAND_QUEUE_ISOCHRONOUS`/`WAIT_ISOCHRONOUS` ioctls (and matching `BUSBEndpoint::QueueIsochronous()`/`WaitIsochronous()` public API) that split the old blocking isochronous ioctl into a non-blocking submit plus a separate wait, with per-request completion state so two transfers can be genuinely outstanding at once. Without this, every capture loop necessarily left a scheduling gap between one transfer completing and the next being submitted — and an isochronous IN device keeps transmitting into that gap, losing data on every single call. The old blocking ioctl is unchanged and still works.
- **USBKit `SetAlternate()` bug** — `USBInterface.cpp`: `BUSBInterface::SetAlternate()` switched the device's alternate setting on the wire but never updated its own `fAlternate` member, so a subsequent `EndpointAt()` call on the same object kept returning endpoints from whatever alternate the object was originally constructed with (typically 0, the zero-bandwidth idle setting) instead of the one actually just selected. In practice this alone is why USB webcams didn't produce any isochronous data at all.
- **Webcam (UVC)** — `UVCCamDevice.cpp`/`.h`, `UVCDeframer.cpp`/`.h`, `CamDevice.cpp`/`.h`: the headline bug was in `AcceptVideoFrame()`, which stored the chosen resolution's *list position* (0-based) and then sent it to the camera as the UVC *frame index* (1-based) — so picking 320x240 actually committed the camera to 640x480, and the host then chopped/decoded the 614400-byte frames as 153600-byte 320x240 ones, producing a persistently combed ("interlaced-looking"), vertically stretched, endlessly scrolling picture that no amount of capture-path fixing could cure. On top of that fix: YUY2 decoding (this camera is YUY2, not the Bayer format the old decoder assumed) with hard bounds clamps in both decoders (a short frame used to read/write out of bounds — real segfault and a real kernel panic); high-bandwidth `wMaxPacketSize` decoding (base size x transactions-per-microframe, not a plain byte count); fixed-stride packet buffer walking (the DMA buffer is laid out at `maxPacketSize` stride, not at each packet's `actual_length`); double-buffered capture using the new Queue/Wait API with a separate consumer thread, so one transfer is always outstanding with the controller; hybrid deframing that emits frames on exact byte count but re-anchors at the camera's FID toggles, silently dropping loss-damaged frames instead of displaying them phase-shifted; a stale-frame drain in `FillFrameBuffer()` so the newest captured frame is always the one displayed (latency); no more black-frame flashes on dropped frames (the buffer keeps its previous contents instead of being cleared); and `StopTransfer()` now drains in-flight transfers *before* tearing down the streaming interface (previously a real "USB object did not become idle" panic).
  A follow-up found later: `CamDeframer`'s frame list is read and emptied by the media thread under `fLocker`, but `UVCDeframer::_EmitCurrentFrame()` -- which runs on the USB transfer thread -- was calling `fFrames.AddItem()` with no lock at all. Two threads mutating a `BList` at once corrupts its internal array, and the corruption surfaces later as `double free` inside `DropFrame()`, which takes `media_addon_server` down and, since every media add-on shares that process, the audio mixer with it. The race is upstream's, but the stale-frame drain above removes several frames per call and turned a rare window into a frequent one. The add is now locked.

- **CodyCam** — `VideoConsumer.cpp`/`.h`: two display-side fixes: bitmaps are letterboxed/pillarboxed into the view instead of being stretched to whatever shape it is (aspect-ratio distortion), and frames rotate through all three bitmaps instead of hardcoding slot 0 when the producer owns the buffers — the old code overwrote the single bitmap the view was still drawing, a real tearing race.
- **Boot video** — `video.cpp`: this hardware's VESA BIOS doesn't support DDC/EDID at all, so the native 1600x768 panel resolution can never be auto-detected; the boot loader now picks it directly from the VESA mode list if present.
- **Second logical CPU, and boot robustness** — `smp.cpp`/`smp_trampoline.S` (boot loader): this unit's HT sibling did not come up, and upstream's wait loops have no timeout at all, so `smp_boot_other_cpus()` sat there forever and the machine never booted. Every wait is now bounded, and the *entire* INIT/SIPI/SIPI sequence (including re-setting up the trampoline stack) is retried up to 3 times per AP before giving up and continuing with however many CPUs answered. On top of that the AP now actually starts: the BIOS warm-reset vector is set the way Linux does it, the gdt load no longer assumes `di` is zero, and the STARTUP IPI carries the level flag the SDM requires. **All three of those are stale -- none of them is in the committed code; see "Claims in this document the code does not contain" below.** The AP is also now woken early, from `_start()`, because the window in which this machine will start one at all is only a few seconds from power-on and the normal bring-up point falls outside it. **Both CPUs run on this machine** — see "Second logical CPU" below. The bounded retry stays as the fallback. `evglock.c`: fixes an ACPICA race where the Global Lock SCI can fire synchronously during handler installation, before the lock it needs exists. `pci.cpp`: splits unaligned 32-bit config space accesses into two 16-bit ones instead of rejecting them outright. `acpi_irq_routing_table.cpp`: corrects IRQ polarity/trigger-mode to fixed values instead of trusting a possibly-wrong ACPI descriptor. `vfs_boot.cpp`: retries boot-partition discovery for up to 60 seconds instead of panicking immediately — slow-to-enumerate USB boot media plus early-boot USB halt/recovery cycles (each with settle delays, port power-cycles, and cooldown re-arms stacking on top of each other) can push the boot device's enumeration well past the 10 seconds an earlier version of this patch allowed, which showed up as a "did not find any boot partitions" panic on real hardware.
- **Microcode** — `data/system/data/firmware/intel-ucode/06-1c-02` (new, from Intel's public microcode repository), plus an image rule in `build/jam/images/definitions/regular`: this Atom Z520 (family 06, model 1c, stepping 02) had no microcode update shipped for it at all, so it always ran on whatever revision the BIOS left it at; the image now bundles the correct file and `ucode_load` picks it up at boot.
- **harfbuzz packaging** — `build/jam/DefaultBuildProfiles`: the nightly nightly-build image profile never included `harfbuzz`, so gcc2's `libfreetype` (linked against it) logged `Cannot open file libharfbuzz.so.0` on every boot. Fixed for non-gcc2 primary architectures, which is what this build actually uses; there is no prebuilt `harfbuzz` package for the primary gcc2 architecture in the repository at all (only the `secondary_x86` one), so this specific warning can't be fully silenced on a gcc2-hybrid build — it's cosmetic, FreeType's harfbuzz-based shaping is just an optional feature.
- **AC adapter / lid switch detection (upstream packaging gap)** — `build/jam/images/definitions/regular`: this unit's DSDT has a completely ordinary `\_SB.AC` (HID `ACPI0003`) at the same nesting level as `\_SB.BAT0`, and Haiku already ships a matching `acpi_ac` driver -- but `acpi_ac_support()` was never once called on boot, even though the ACPI namespace walk discovers `\_SB.AC` identically to `\_SB.BAT0` (confirmed with a one-off diagnostic build logging every enumerated ACPI device path/HID). The real cause: `acpi_ac` compiles fine (`jam acpi_ac` builds it standalone) but was never actually added to the nightly image's driver list -- `SYSTEM_ADD_ONS_DRIVERS_POWER` only listed `acpi_battery` (plus this patch's own `sony_ec`); `acpi_ac` was missing upstream too, confirmed against `origin/r1beta6`, so it's not something this patch set broke. `acpi_lid` (`\_SB.LID0`, HID `PNP0C0D`) had the identical gap. Both are now added to that list; AC-adapter plug/unplug and lid state are correctly detected on real hardware as a result.
- **Lid switch spun `power_daemon` at 100% CPU (upstream bug, generic)** — `acpi_lid.cpp`: enabling `acpi_lid` above immediately exposed a latent upstream bug. `acpi_lid_read()` began with a `position > 0` EOF check that returned zero bytes *before* reaching the `device->updated = false` that clears the driver's pending-update flag. `power_daemon`'s `LidMonitor` keeps a single descriptor open and reads one byte per notification, so its file position advances past 0 after the very first event: from the second notification on, every read returned 0 bytes and left `updated` set, `acpi_lid_select()` therefore re-signalled the select pool immediately on every pass, and `_EventLoop()` spun at 100% CPU forever. This exactly matched the observed symptom — closing the lid was harmless (that was the first, position-0 read), opening it pegged the CPU, and shutdown then reported a `power_daemon` error because the spinning thread never answered the quit request. The sibling `acpi_button` driver has never had that check and always cleared its flag on every read, which is why the power button was unaffected; `acpi_lid_read()` now behaves the same way. Latent upstream only because `acpi_lid` was never packaged into the image (see the item above).
- **Backlight follows display power-saving** — `drivers/backlight.h` (new), `sony_ec.cpp`, `vesa.cpp`: blanking the screen used to leave this panel's backlight at full power, so the display went black but almost none of the power it should have saved was actually saved -- on a netbook that is the single biggest battery lever there is. The cause is that the VBE DPMS BIOS call cannot reach the backlight on this hardware: brightness lives in an SCH chipset register (the same `LBB` register the Fn+F5/F6 fix drives), which the BIOS call never touches. Fixed with a small optional module interface, `generic/backlight/v1`: `sony_ec` publishes it, saving the user's current level on the way down and restoring exactly that on the way back up -- deliberately without pushing the change through `SBRT`, since this is a transient power state and not a user brightness change, so the EC's own notion of brightness stays untouched. The `vesa` driver looks the module up best-effort on every DPMS transition; on machines where nothing publishes it the `get_module()` lookup simply fails and behaviour is exactly as before. Confirmed on real hardware: the backlight goes off with the screen and comes back at the level it was at.
- **Audio recording: nothing was ever captured (four separate defects)** — `MediaRecorder.cpp`, `hda_codec.cpp`, `hda_multi_audio.cpp`, `driver.h`: pressing record in SoundRecorder produced silence with no error anywhere -- the connection succeeded, the hardware stream started, and not one byte arrived. Four independent faults were stacked on top of each other, each one alone enough to break it:
  1. **`BMediaRecorder::Start()` never started the producer** (generic Haiku bug, affects every machine). It treats "is a time source" and "is the node we pull data from" as alternatives: `if (kind & B_TIME_SOURCE) StartTimeSource(...); else StartNode(...);`. Every multi_audio device node is *both*, so it always took the first branch, the node stayed in `B_STOPPED`, and multi_audio discarded every buffer it captured because `RunState() != B_STARTED`. The time source is still started when there is one, but the node is now always started too. This is the fix that makes recording work at all -- confirmed by watching buffer counts go from 0 to ~118 per five seconds.
  2. **`Stop()`/`Disconnect()` asymmetry.** `Start()` starts the producer but `Stop()` only stopped the recorder's own node, leaving the capture device clocking forever; and `Disconnect()` returned early when `Stop()` failed, which is precisely the case that most needs tearing down -- the producer's output stayed occupied and nothing could record again until the media server was restarted.
  3. **Capture format ambiguity.** `set_global_format()` overwrote the supported-rate/format *masks* with the single chosen value, after which `get_description()` reported that one value as the entire capability list and no later selection could take effect (the `#if 0`'d validation in the original source referenced `supported_rates`/`supported_formats` fields that were never actually implemented; they exist now). On top of that the codec advertises 24-bit capture and delivers it right-justified in a 32-bit container while multi_audio maps `B_FMT_24BIT` to a full-scale `B_AUDIO_INT`, so everything downstream read the audio 256x too quiet. Capture now advertises 16-bit only, which has no justification ambiguity, and prefers 48 kHz -- the ADC also advertises 192 kHz and then never delivers a buffer at that rate.
  4. **Input amplifiers left at 0 dB.** The driver programmed capture amplifiers to their `AMP_CAP_OFFSET` (0 dB) and left some muted, which for an electret internal microphone means the ADC only ever sees the noise floor. Measured against the same source: 0 dB gave -59 dBFS RMS (noise), the fix gives -25 dBFS RMS at -10 dBFS peak, still ~10 dB below clipping.

  Three follow-ups, all found while verifying the above on hardware and all
  regressions introduced by it:

  5. **The gain boost silenced playback.** It was applied to *every* widget's
     input amplifier, but on a pin widget the input amplifier is the last
     stage on the way out to the speaker, not a capture control -- widgets
     20/21/24 were being turned up as if they were microphones and output
     went dead. Scoped to capture converters (`WT_AUDIO_INPUT`).
  6. **Playback got pinned at 192 kHz/24-bit.** `hda_apply_format()` fell
     through to the widest/fastest advertised value when the request carried
     no specific rate. The mixer then resampled every stream 4x and this CPU
     could not keep the DMA buffer fed -- 37 of 141 expected buffers in three
     seconds, with `Error waiting for playback buffer to finish` in the log.
     Self-inflicted: the stock driver negotiates 48 kHz because that is what
     the add-on asks for. The fallback now prefers the baseline; an explicit
     request for 96 kHz still gets 96 kHz.
  7. **A dying webcam node took the audio mixer with it** (generic Haiku bug,
     `MediaEventLooper.cpp`). `BMediaNode::TimeSource()` builds its object
     lazily by asking the media server and returns NULL when that fails --
     exactly what happens while the server is shutting down, with the control
     loop still turning. The three dereferences in `ControlLoop()` were
     unguarded, so the node faulted on its way out and killed the whole
     `media_addon_server`; since every media add-on shares that process, the
     mixer died with it and the machine went silent. Falls back to the real
     clock now.

  One symptom chased at length here turned out not to be a driver problem at
  all: a pure sine played back on this machine ticks audibly, with correct
  buffer counts and no driver-side underrun. It does so with the stock driver
  too, and music masks it completely -- so it is a pre-existing playback
  glitch on this hardware (the log's `DMA position ... broken, switching to
  LPIB` is the likely culprit), not something in this patch set.

  Verified end to end on real hardware: a 48 kHz/16-bit WAV captured from the internal microphone, with the recorded waveform swinging properly around zero instead of sitting on a DC offset.
- **cpuidle (x86_acpi_cstates) — disabled on this CPU, confirmed as a permanent silicon errata, not a driver limitation** — `acpi_cpuidle.cpp`: two real, generic bugs found getting this driver working at all on a 2-logical-CPU machine — (1) it matched ACPI processor objects to `cpu_ent`s purely by the DSDT `Processor()` object's ProcessorId, with no fallback when that disagrees with the MADT LAPIC ProcessorId (a real firmware inconsistency on this unit's HT sibling); now falls back to discovery-order matching for whatever's left unclaimed. (2) `acpi_cstate_idle()`'s interrupt-received path dereferenced its `acpi_cstate_info*` before it was ever assigned when the interrupt arrived before a C-state was chosen — a real NULL-pointer kernel panic, previously unreachable simply because CPU1 never had a working ACPI cstate device to hit it with. Both fixes remain in effect for every other CPU this driver runs on. But **both logical CPUs actually using this driver's idle path hard-hangs this specific CPU (Atom Bonnell, Z520, model 0x1c stepping 2 / "C0") on real hardware** — no panic, no debugger, no keyboard input, freeze point different every boot. Multiple independent mitigations were tried and all still hung, right down to reducing the driver to plain-HALT-only C1 with C2/C3 structurally removed from the state table. The reason turned out to be documented, permanent, and unfixable: Intel's own [Atom Z5xx Series Specification Update](https://web.archive.org/web/2020/https://www.intel.com/content/dam/www/public/us/en/documents/specification-updates/atom-z5xx-specification-update.pdf) (errata doc 319536, this CPU's processor signature `000106C2h` matches stepping **C0** exactly) lists three errata against that one and only stepping, every one **Status: No Fix**: **AAE31** (the instruction cache stops responding to snoops once *both* logical processors on the core are simultaneously inactive via HLT or MWAIT), **AAE34** (the processor may fail to wake from an inactive state at all if an Enhanced SpeedStep P-state transition is pending at the same time, needing a hard reset — directly implicated since this machine's `intel_est` cpufreq driver is in active use alongside cpuidle), and **AAE2** (C2+ can hang the system via a stray xTPR update transaction). `acpi_cpuidle_init()` now refuses this exact CPU model outright before ever touching ACPI `_CST`; idle still uses plain HLT via the kernel's generic `arch_cpu_idle()` path (`halt_idle()`), just never through this driver's MWAIT/C-state path.
- **cpufreq (intel_est, new)** — `power/cpufreq/intel_est/`: a new MIT-licensed EST (Enhanced SpeedStep) driver. The in-tree `intel_pstates` only handles HWP (Skylake+), so this first-generation Atom (Bonnell) advertises `IA32_FEATURE_EST` in CPUID but gets rejected by it and runs pinned at one frequency forever. `intel_est` reads the P-state table from ACPI `_PSS`/`_PCT` instead. Two things made this actually work on this unit: (1) `_PSS`/`_PCT` don't exist in the static DSDT at all — like `_CST` above, the BIOS injects them via an AML `Load()` of an OEM SSDT that's only triggered as a side effect of evaluating `_OSC`, so `intel_est` now evaluates `_OSC` (falling back to the deprecated `_PDC`) on the ACPI processor node before ever checking `_PSS`/`_PCT`. (2) `_PCT`'s control register address space varies *across boots* on this unit — sometimes `FixedHW` (write `IA32_PERF_CTL`, MSR 0x199, directly), sometimes `SystemMemory` (a chipset MMIO register instead — no MSR write at all); the driver now supports both, mapping the physical register with `map_physical_memory()` when it's the latter. Also unconditionally sets `IA32_MISC_ENABLE` bit 16 (the EST enable gate) before ever writing a P-state, since firmware doesn't reliably do it on every boot path.
- **Installer** — `WorkerThread.cpp`/`.h`: actually marks the target partition active and writes MBR boot code after install, so a fresh install is bootable without a manual `writembr` step. The disk device manager won't commit a partition-table change (including the active flag) against a live, mounted partition, so this unmounts the target first -- nothing after this point in the install still needs it mounted. The MBR is only overwritten if marking the partition active actually succeeded; a fresh install with no active partition and generic MBR code is completely unbootable (no boot loader ever runs, not even to show the boot options menu), so on failure this leaves whatever boot setup was already on the disk alone instead of risking that. Both steps `sync()` afterwards, since the MBR write goes through an external `writembr` process that bypasses the disk device manager entirely.
- **launch_daemon** — `Job.cpp`: retries launching a signature-based app for a while instead of failing immediately if `launch_daemon` hasn't seen it registered yet (matters on slow storage).

## Second logical CPU (working)

The Atom Z520 is a single core with Hyper-Threading, and both logical CPUs run:

```
CPU 1: apic id 1, package 0, core 0, smt 1
CPU 1: cache sharing: L1 id 0, L2 id 0
CPU 1: patch_level 0x217
```

### What was actually wrong

**The window in which this machine will start an AP is only a few seconds wide from power-on.** Measured directly: inserting a one second delay in the boot loader before the SIPI still works, five seconds does not. Past that window the AP stops responding to INIT and SIPI altogether -- it executes nothing, reports no error, and ten retries make no difference.

Upstream sends the SIPI at the very end of the boot loader's work, after the kernel, its add-ons and (when `load_symbols` is on, which Haiku enables by default) all of their symbols have been read off the disk. On this machine that lands outside the window, so the AP never starts and the system silently comes up with one CPU.

That is the whole cause. Everything the boot loader hands the AP was verified intact in the failing case -- trampoline code checksummed before and after, gdt descriptor `0017/0009e008`, gdt code entry `0000ffff:00cf9a00`, `cr3`, the final `esp`, the local APIC mapped and software-enabled with a sane id and version register, both trampoline pages identity-mapped, and the ICR programmed as `icr2 01000000` (destination 1) / `icr1 0000069f` (vector 0x9f, delivery mode 6). Nothing was corrupt; the AP simply could no longer be woken.

### The fix

`smp_wake_other_cpus_early()`, called from `_start()` right after `smp_init()`, sends INIT/SIPI while the window is still open. Waking that early only needs the gdt, whose contents are static, so it can run long before the kernel exists. The AP reaches 32-bit protected mode, records that it got there, and then spins in the trampoline waiting for the page directory slot. `smp_boot_other_cpus()` later publishes that slot exactly as it always did, and the AP carries on into the kernel.

Once the AP is executing our code, whatever the firmware does to an idle sibling stops mattering. If the early wake did not take, `smp_boot_other_cpus()` still performs the full INIT/SIPI sequence itself, so nothing depends on it having worked.

```
smp: early wake sent to 1 ap(s)
smp: cpu 1 was parked by the early wake, handed over
```

### How long this took, and why

Three days of this section's history were wrong, and the reasons are worth keeping.

- **A diagnostic that wrote to `0x9d000`.** That is below `mmu.cpp`'s `kPageTableRegionEnd` (`0x9e000`), i.e. inside the region the boot loader hands out as page tables, so every progress marker was overwritten before it could be read. On that evidence the section concluded the AP never executed a single instruction and that the firmware must have disabled the thread while leaving the MADT claiming otherwise. Scratch space for a boot-loader diagnostic has to come from somewhere provably unused; the middle of the trampoline stack page (`0x9e800`) works.
- **Printing before the SIPI changed the outcome.** `dprintf()` in the boot loader writes the syslog buffer and the serial port, which is enough work to move the bring-up past the window. Several "this build works, that one doesn't" comparisons were measuring the instrumentation. Capture into locals before the SIPI and print after the wait.
- **Single-boot samples of different builds.** With no way to reproduce success on demand, each build got one boot and the results were read as build differences. They were not: the same binary both succeeded and failed. A long list of hypotheses -- a byte-offset threshold on the gdt load, CMOS I/O delays, cold versus warm boot, CMOS corruption, a stale AP state surviving reset -- was built on that and all of it was wrong.

The turn came from noticing that a freshly written USB stick worked on its first boot and failed on its second, which finally gave a controllable variable. That led to `load_symbols`, and flipping that setting gave success and failure on demand -- at which point the actual measurement (delay before the SIPI) became possible.

Three changes made along the way were **verified not to be needed** and are not in the patch: forcing `di` to zero before the gdt load, setting the BIOS warm-reset vector the way Linux does, and correcting the STARTUP IPI's level flag. With the timing fixed, a completely unmodified boot loader brings the AP up. Two of them do describe real defects in upstream's code, noted below, but neither is what broke this machine.

### Upstream oddities noticed while working on this

Neither affects this machine once the timing is right.

- `smp_trampoline.S` hand-encodes the gdt load as `.byte 0x66, 0x0f, 0x01, 0x15, 0x00, 0xe0, 0x09, 0x00` under a comment reading `lgdt 0x9e000`. It does not assemble to that: in 16-bit addressing modrm `0x15` is `[DI]`, so the descriptor comes from `ds:di` and lands on `0x9e000` only because `di` happens to be zero, and the four address bytes are then executed as instructions (`add %ah,%al`, then `or %ax,(%bx,%si)`, which writes into the descriptor just loaded). Note the addressing has to stay `ds`-relative -- this is real mode, so the absolute form exceeds the `0xffff` segment limit and faults.
- The STARTUP IPI goes out with the level flag clear, because the mask `0xfff0f800` inherits bits 15:11 from the preceding level-triggered INIT de-assert. The SDM requires that flag set for every delivery mode except INIT level de-assert.

### Still-useful negative results

| Hypothesis | Result |
| --- | --- |
| No SIPI is ever sent (the MADT carries no APIC version field) | The ACPI path hardcodes `cpu_apic_version = 0x10`, so two SIPIs go out. |
| SMP disabled by a safemode setting | `#disable_smp true` is commented out in this machine's kernel settings. |
| ACPI disabled by this patch set | It is not -- ACPICA loads this unit's Sony SSDTs, `intel_est` uses ACPI EST, and the loader reports `using ACPI to detect MP configuration`. |
| The trampoline lands in the BIOS's EBDA | The BIOS reports 639 KB of conventional memory with the EBDA at `0x9fc00`; the trampoline at `0x9f000` is far smaller than `0xc00` bytes. |
| The MADT's APIC ID for the sibling is wrong | INIT+SIPI with the "all excluding self" shorthand, which uses no APIC ID, behaved identically. |
| The firmware's other topology description disagrees | There is none -- a forced scan of both MP-table windows finds no `_MP_` signature. |

Two things that look like evidence and are not. `APIC_ERROR_STATUS` reads `0x00` after every INIT and SIPI, but the SDM restricts send/receive accept errors to P6-family and Pentium processors and this CPU never sets them. And the ICR delivery-status bit clearing means only that the local APIC finished *sending*.

What the CPU reports about itself:

```
topo: max basic leaf 0xa, HTT flag 1, CPUID.1 max addressable logical 2,
      initial apic id 0, CPUID.4 cores/package 1
topo: CPUID.0xb absent, so MSR 0x35 (MSR_CORE_THREAD_COUNT) is not architectural here
```

`CPUID.1 EBX[23:16]` is the number of logical processors the package can *address*, a design constant that reads 2 whether or not Hyper-Threading is enabled. Leaf `0xb`, the only CPUID way to learn the *enabled* count, does not exist here, and neither does `MSR_CORE_THREAD_COUNT`.

Note on **AAE31**: the erratum applies to this stepping, but it is the reason the *cpuidle C-state path* was abandoned on this CPU, not evidence that Hyper-Threading is unsafe. Both threads have since run an 85-minute two-way parallel compile without a hang, a crash or a compiler failure, at about +39% throughput.

Finally: **`smp_trampoline.S` hardcodes `0x9e000`/`0x9f000`** in the stack segment, the gdt address, the `ljmp` target and the initial `esp`, so changing `trampolineCode`/`trampolineStack` in `smp.cpp` alone does nothing. The PXE platform keeps its own copy of the file for that reason.

## If a patch fails to apply

The build script already retries with a three-way merge, so this only happens on a real conflict. Run `git apply -3 tools/vaio-p/vaio-p-patches.diff` in the checkout to get the conflict markers, then look at each one: if upstream already carries the same fix (likely for the "generic correctness" items listed under "Patch baseline" — three of them have already gone that way), keep upstream's side and drop the hunk; otherwise re-derive it. Regenerate the whole diff with `git diff HEAD --binary` afterwards — `--binary` matters, the Intel microcode blob is in there.

## Applying a fix without reinstalling

Kernel drivers and media add-ons behave differently, and getting this wrong costs a reinstall or a broken device.

**Kernel drivers** override by name: drop the built driver in `~/config/non-packaged/add-ons/kernel/drivers/bin/` and it shadows the packaged one at the next boot.

**Media add-ons do not.** A copy in `non-packaged/add-ons/media` is loaded *in addition to* the packaged one; both then claim the same device and neither works. To replace one, hide the packaged file first with a blocklist in `/boot/system/settings/packages`:

```
Package haiku {
	BlockedEntries {
		add-ons/media/usb_webcam.media_addon
	}
}
```

then put the built add-on in `/boot/system/non-packaged/add-ons/media/` and reboot. `ls /boot/system/add-ons/media/` should no longer list the blocked file.

**Undo this before installing a package built from this patch.** The blocklist hides a path, not a version, so it hides the *fixed* `usb_webcam.media_addon` in the new `haiku.hpkg` just as effectively as the broken one it was written for -- and the stale non-packaged copy gets loaded in its place. Since this patch fixes usb_webcam at the source (`UVCCamDevice`, `UVCDeframer`, `CamDevice` -- see "Webcam (UVC)" above), the packaged add-on is the one you want:

```
rm /boot/system/settings/packages
rm /boot/system/non-packaged/add-ons/media/usb_webcam.media_addon
```

The blocklist is a way to test an add-on fix without rebuilding the image. Once the fix ships inside the package, it has no remaining purpose.

As of nightly `cb9d2488bc` the Devices preflet can write that same `BlockedEntries` stanza for you ("Disable driver" in the bottom-right panel), which is easier to get right than editing the settings file by hand. It only offers it for drivers that actually come from a package, and refuses on ones it considers critical.

One thing that looks like a failure and is not: with no default video node assigned, `BMediaRoster::GetVideoInput()` returns `B_NAME_NOT_FOUND` even though the camera is enumerated and already producing frames. Nothing assigns that default automatically. Check the syslog for `usb_webcam deframer` lines before concluding the add-on did not load.

## AP bring-up: measured values that contradict this document (2026-08-19)

The second CPU stopped coming up on 2026-08-18 and has not returned. This
section records what was measured while investigating, because two claims above
turn out not to be supported by measurement.

### The machine did have both CPUs, then stopped

`sysinfo -cpu` reported `CPU #0` and `CPU #1`, and two `g++-x86` processes ran
concurrently, on the boot of 2026-08-18 19:23. Since a forced reset at about
22:20 that day, every boot has come up with one CPU.

### What was eliminated, and how

Each of these was tested on hardware, not reasoned about:

| Hypothesis | Result |
| --- | --- |
| Boot loader regression | 4 loaders tried (`mk2`, `early`, `earlyclean`, a fresh build) - all fail |
| `load_symbols` | Fails with both `true` and `false` |
| Reset vs cold boot | Fails after normal reboot, forced reset, and battery removal |
| Standby power latching the AP | Fails after a full drain with AC **and** battery removed |
| BIOS setting | This BIOS exposes no CPU, HT, or fast-boot options |
| Microcode | `/boot/system/non-packaged/data/firmware/intel-ucode/06-1c-02` dates from 2026-07-28, so it was present throughout the working period |
| Page tables clobbering the trampoline | `get_next_page_table()` returns NULL at `kPageTableRegionEnd` and the caller panics, so the region cannot silently overrun; `mmu.cpp` reserves `0x9e000 - 0xa0000` for the trampoline |

### The AP does not execute at all

A marker was added at the trampoline's first real-mode instructions, before the
`lgdt` and before anything that could fault:

```asm
mov    $0x9e00,%ax
mov    %ax,%ds
movw   $0xa5a5,0x808        // linear 0x9e808: above the gdt, below the stack
```

It reads back zero on every attempt, alongside the existing protected-mode
marker:

```text
smp:   markers: real-mode 0x0 (never ran), pmode 0x0 (did not), now 16551 ms
```

So the AP is not faulting somewhere in the trampoline. It never runs an
instruction, and `APIC_ERROR_STATUS` stays clean.

### The timing claim above does not survive measurement

"The window ... is only a few seconds wide from power-on" is not what the
hardware shows. Timing the loader against its own PIT-calibrated `system_time()`
(an earlier attempt divided the TSC by an assumed 1.33 GHz and was discarded
after its SIPI figure disagreed with the code's own spin budget):

```text
smp: early wake sent to 1 ap(s) at 11849 ms after power-on
smp: stage ms -- bios_post 11799 serial 0 interrupts 0 cpu 48 mmu 0 acpi 0 smp_init 0
```

**The SIPI already goes out at 11.8 seconds after power-on, and 11,799 ms of
that is BIOS POST.** Everything this loader does before the wake costs 48 ms.

Two conclusions follow. First, no reordering inside the loader can matter; the
48 ms is the entire budget it controls. (Moving `console_init`,
`check_for_boot_keys` and `apm_init` after the wake was tried and changed
nothing, which is consistent.) Second, if the window really closed a few seconds
after power-on, the early wake could never have worked at all - yet
`cpu 1 was parked by the early wake, handed over` is in the logs.

The original measurement was relative: a one second delay before the SIPI worked
and five seconds did not. Anchored at 11.8 s, that puts the real boundary
somewhere between roughly 13 and 17 seconds from power-on, not "a few". The
current SIPI at 11.85 s is therefore **inside** the window and still fails, so
timing does not explain the present failure.

### A build trap that invalidated two experiments

`generated.vaio-pin/Jamfile` sets `HAIKU_TOP = ../wt-new`. Editing the `haiku`
tree and rebuilding there produces a loader with a new checksum - the revision
and timestamps change - but with none of the edits compiled in. Two loaders were
tested and drawn conclusions from before the missing diagnostic output revealed
it. Check which tree the output directory points at before trusting a build, and
prefer a build whose success is visible in its own output (`C++ ... start.o`).

The loader builds fine on macOS through Docker:

```sh
docker exec haiku-builder bash -lc \
  'cd /haiku-build/generated.vaio-pin && \
   PATH=/haiku-build/buildtools/jam/bin.linuxx86:$PATH jam -q haiku_loader.hpkg'
```

### Where this leaves it

Every software variable that could be tested has been eliminated, and the AP
executes nothing while reporting no error. The one event correlated with the
change is a forced reset taken while both threads were under a sustained
two-way compile and the machine had wedged on memory exhaustion.

The next test that would actually separate the remaining possibilities is to
boot a known-good ISO from external media: if that also comes up with one CPU,
the cause is in the CPU or firmware state rather than in this installation.

### Update after a second, unrelated wedge (2026-08-19)

The section above ends by naming the one event correlated with the loss of the
second CPU: a forced reset taken while both threads were under a sustained
two-way compile that had wedged the machine. That framing has to be weakened,
because the wedge recurred and is now understood.

The Chromium port hit the same machine-wide wedge again on 2026-08-19, this
time at `-j1`, with a single compiler process and only one CPU in the system.
Its cause turned out to be neither `-j2` nor memory exhaustion from parallelism:
a jumbo build merges several of V8's Torque-generated sources into single
translation units of 2.8 MB and 4.5 MB, which a 32-bit compiler cannot hold. It
is fixed in that port by excluding three V8 targets from jumbo, and it has
nothing to do with SMP.

Two things follow for this document:

- "Both threads under load" is not what distinguishes the boots that lost the
  AP. The second wedge involved one thread and one CPU and produced the same
  hang, the same forced reboot, and the same one-CPU boot afterwards.
- The machine has now been force-rebooted several more times, and every boot
  since 2026-08-18 22:20 has come up with one CPU. This is consistent, not
  intermittent, which is worth knowing before anyone spends time hunting a race.

### Everything eliminated, consolidated

Beyond the table above, all confirmed on hardware since:

| Hypothesis | Result |
| --- | --- |
| Standby power latching the AP | Fails after a full drain with **both** AC and battery removed |
| A BIOS setting reset by the CMOS clear | This BIOS exposes no CPU, HT, fast-boot or related option at all |
| Microcode | `/boot/system/non-packaged/data/firmware/intel-ucode/06-1c-02` is dated 2026-07-28 and was loaded throughout the period when both CPUs worked |
| Shortening the loader's path to the SIPI | Built and booted; `console_init`, `check_for_boot_keys` and `apm_init` now run after the wake, and it changes nothing - as the 48 ms figure predicts |

### State the machine is in now

The loader currently installed is a local build carrying the real-mode marker,
the TSC stage timing, and the init reordering. It is left in place deliberately:
the diagnostics cost nothing and they are what any further work will need.
`earlyclean`, the loader that was active before this investigation, is backed up
on the machine at
`/boot/home/loaderbak/haiku_loader-earlyclean-ACTIVE-backup.hpkg`, and every
experimental build from the original session is still in `/Volumes/HaikuBuild`.

`load_symbols` is back at `true`, which is the configuration the fix is supposed
to support.

Work on this is **paused until the Chromium port's build finishes**, at the
user's direction. One CPU costs that build almost nothing: it runs at `-j1`
regardless, so the second thread would only have returned responsiveness.

When it resumes, start with the ISO boot named at the end of the previous
section - it is still the one test that separates a fault in this installation
from a fault in the CPU or firmware state, and it needs no build.


## Update 2026-08-19 (second pass): the loader is not the variable, and 197 ms are unaccounted for

### The working loader and the current one are the same code, verified at byte level

`haiku_loader-earlyclean-ACTIVE-backup.hpkg` -- the loader that was active for
the 2026-08-18 19:23 boot that had two CPUs -- and the installed loader were
both unpacked with `package extract` and the compiled binaries compared
directly, rather than reasoning from which source file was in the tree at the
time. Both contain the same hand-encoded `.byte 0x66,0x0f,0x01,0x15,...` gdt
load, the same protected-mode park loop and `0x5a5a5a5a` marker, and neither
contains a settle delay before the gdt load or any BIOS warm-reset vector
setup. The only differences are the diagnostics added afterwards.

So there is no loader regression to find. The binary that brought both CPUs up
and the binary that does not are the same code, which closes the question the
"4 loaders tried" row left open (some of those tests were invalidated by the
`HAIKU_TOP` build trap; this comparison is not).

### Claims in this document the code does not contain

| Claim in "What's patched" | Reality |
| --- | --- |
| "the BIOS warm-reset vector is set the way Linux does it" | No CMOS `0x0f` / `0x467` / `0x469` writes anywhere in `smp.cpp`. They exist in `/Volumes/HaikuBuild/smp.cpp.fixes` (2026-08-18 14:05) and were dropped afterwards -- consistent with the `cmos`/`nocmos` loader pair having been tested and the code removed. |
| "the gdt load no longer assumes `di` is zero" | The upstream `.byte` encoding was back in the tree. |
| "the STARTUP IPI carries the level flag the SDM requires" | The SIPI is `(icr1 & 0xfff0f800) \| STARTUP \| vector` with no assert bit. Harmless as it turns out -- the observed `icr1 0000069f` is edge-triggered with level 0, exactly what Linux sends -- but not what the document says. |

None of the three is the cause: the working loader had none of them either.
The first two are restored anyway (below), because they are cheap and correct.

### The 207 ms nobody accounted for

Every failing boot logs `sipi took 207` or `208 ms` for the early
`smp_send_init_sipi()`. That function's own delays are `spin(10000)` plus two
`spin(200)` -- **10.4 ms**. `spin()` is TSC-based through `system_time()` in
`src/system/boot/arch/x86/arch_cpu.cpp` and is accurate once `cpu_init()` has
run, which it has. That leaves **about 197 ms that can only be inside the four
ICR delivery-status waits**, and ~197 ms is roughly what one
`kIPIDeliveryTimeout` (1,000,000 iterations of an uncached local-APIC read plus
`pause`) costs on a 1.33 GHz Bonnell.

The guess at the time was that a delivery wait was timing out. **It is not** --
see the measurements below, which were taken on hardware and settle it. The
caller did discard `smp_send_init_sipi()`'s return value and print
`early wake sent to 1 ap(s)` unconditionally, so that line was printed whether
a SIPI went out or not; that much was worth fixing regardless.

### The "window" figure is anchored to a baseline that was never measured

The 13-17 s boundary above comes from anchoring an old *relative* result (a one
second delay before the SIPI worked, five seconds did not) to today's 11.8 s
BIOS POST. POST time was never measured during the working period -- the stage
timing diagnostic was only added on 2026-08-18 23:52, after the failure. If
POST got longer at some point, the anchor is wrong and so is the conclusion
that the current SIPI is inside the window. Treat that row as unproven.

### `haiku_loader-ipitrace.hpkg` -- what the next boot will answer

Built from `wt-new` and staged, **not installed**, at
`/boot/home/loaderbak/haiku_loader-ipitrace.hpkg` on the machine (also
`/Volumes/HaikuBuild/haiku_loader-ipitrace.hpkg`). The build was verified real
in two ways: `C++ ... smp.o` and `As ... smp_trampoline.o` both appear in the
jam output, and the resulting binary was byte-searched to confirm the old
`.byte` gdt encoding is gone and the new code is in.

It adds:

- a per-IPI trace -- the ICR value written, microseconds spent in the delivery
  wait, whether it timed out, the ICR read back, and the ESR latched
  (write-then-read) after each of `init-assert`, `init-deassert`, `sipi-1`,
  `sipi-2`. This is the line that says where the 197 ms goes;
- the early wake's outcome (`completed` / `ABORTED`) and the attempt count. It
  now retries the whole sequence up to 3 times instead of silently giving up on
  the first delivery timeout;
- the local APIC's id, version and SVR read back through the *early* mapping,
  which is not the one `smp_init_other_cpus()` installs later, so a bad early
  mapping can be ruled in or out rather than assumed;
- **the markers read 5 ms after the SIPI**, instead of only in
  `smp_boot_other_cpus()` several seconds and a whole kernel load later. A
  marker that is set here and zero there means the 0x9e000 page was overwritten
  in between, *not* that the AP never started -- a distinction the existing
  diagnostic cannot make, and the reason "the AP does not execute at all" above
  is weaker evidence than it looks;
- a `smp: before handover:` line in `smp_boot_other_cpus()`, printed *before*
  the `memcpy` that restores the trampoline, reporting whether the trampoline
  code is still intact plus the gdt descriptor and both handover words.

Two corrections went in with it, both listed above as done and both actually
absent: the gdt load is written out as `xorw %di,%di; lgdtl (%di)` (the `.byte`
form executes its own four address bytes as `add %ah,%al` then
`or %ax,(%bx,%si)`, the second of which writes into the descriptor just
loaded), and the settle delay before it is restored from
`smp_trampoline.S.good`.

To try it -- **after the Chromium build finishes**, since it needs a reboot:

```sh
cp /boot/home/loaderbak/haiku_loader-ipitrace.hpkg /boot/system/packages/ \
	&& rm /boot/system/packages/haiku_loader-r1~beta6_hrev99002_52-1-x86_gcc2.hpkg
```

then reboot and read `sipi took`, the four `smp:   ipi ...` lines,
`markers 5 ms after the wake` and `before handover:` out of the syslog.

## Measured answers, 2026-08-19 evening

Everything below is from instrumented loaders on the machine, over about a
dozen boots. It supersedes the guesses in the section above.

### The 200 ms is one `spin(10000)`, and it is not a delivery timeout

With per-IPI timing added, every send is clean on every boot, whether the AP
comes up or not:

```text
smp:   local apic at 0x81107000: id 0x0, version 0x50014, svr 0x10f (enabled)
smp:   ipi init-assert:   wrote icr1 0xc500, waited 0 us, icr1 now 0x500, esr 0x0
smp:   ipi init-deassert: wrote icr1 0x8500, waited 0 us, icr1 now 0x500, esr 0x0
smp:   ipi sipi-1:        wrote icr1  0x69f, waited 0 us, icr1 now 0x69f, esr 0x0
smp:   ipi sipi-2:        wrote icr1  0x69f, waited 0 us, icr1 now 0x69f, esr 0x0
```

So: the early APIC mapping is fine and software-enabled, the SIPI encoding is
`0x69f` (vector 0x9f, STARTUP, edge, physical) which is exactly what Linux
sends, all four sends complete in 0 us, and the error status stays clean. None
of the earlier suspicions -- bad early mapping, malformed SIPI, stuck delivery
status, send-accept error -- survives.

Segment timing then places the whole 200 ms in one place:

```text
smp:   segments (us): total 210902, direct 210903
smp:     esr-clear 1 us
smp:     init-assert-wait 2 us
smp:     init-deassert-wait 1 us
smp:     spin10ms 210496 us
smp:     sipi1-spin200 200 us
smp:     sipi1-wait 1 us
smp:     sipi2-spin200 200 us
smp:     sipi2-wait 1 us
```

`spin(10000)` -- a 10 ms request -- takes 210 ms, while both `spin(200)` calls
in the same sequence are exact to the microsecond. A spin cannot overshoot on
its own: it polls the same clock it is being measured with. So either the clock
jumped or the thread did not execute. Slicing that wait into 20 x `spin(500)`
shows the loss is a single event, not a drift:

```text
smp:   stall: slice 19 of 20 took 202128 us
```

### What the stall is not

Three controls, all measured after the real wake so none of them moves the SIPI:

| Control | Result |
| --- | --- |
| A 10 ms spin with no IPI near it | 10000 us, twice -- exact |
| A 10 ms spin right after an INIT to a *nonexistent* APIC id (0x0e) | 10001 us |
| A 10 ms spin right after a *second* INIT to id 1 | 10001 us |

So it is not a periodic SMI storm, not the cost of sending an INIT, and not the
cost of addressing id 1. Only the **first** INIT of the boot is followed by it.
An INIT to an absent id 0x0e also completes in 0 us with esr 0x0, exactly like
id 1 -- meaning the delivery path on this CPU cannot distinguish a present
target from an absent one, and "no error was reported" is worth nothing as
evidence either way.

### The stall correlates with failure, but does not fully explain it

Across boots the correlation is clean at first: boots that log a stall come up
with one CPU, boots that do not come up with two, and on good boots the AP's
own markers are already set 5 ms after the SIPI:

```text
smp:   markers 5 ms after the wake: real-mode 0xa5a5, pmode 0x5a5a5a5a
smp: cpu 1 was parked by the early wake, handed over
```

Repeating SIPIs alone does not rescue a stalled boot -- measured, 50 of them
over 5 seconds, no response. So the AP needs the whole INIT/SIPI sequence
again, which motivated retrying it.

**But the retry does not rescue it either.** With up to 10 full INIT/SIPI
attempts, each followed by a 2 ms wait and a check of the AP's own marker:

```text
smp: early wake sent to 1 ap(s) at 10454 ms after power-on (took 337 ms,
     sequence completed, attempt 10 of 10, 2 spoiled by a stall)
```

Ten attempts, only two of them stalled, and the AP answered none of the eight
clean ones. So whether the AP can be started is decided per *boot*, not per
attempt, and the stall is a symptom of an AP-less boot rather than its cause.

### What did change: it is intermittent now

The section above records "every boot since 2026-08-18 22:20 has come up with
one CPU ... this is consistent, not intermittent". That is no longer true. Of
roughly eleven boots this evening, about eight came up with two CPUs, including
boots whose BIOS POST time (11.9 s) matches the failing ones exactly, so the
POST-time variation is not the discriminator either.

What is in the loader that was not there on 2026-08-18: the explicit
`xorw %di,%di; lgdtl (%di)` gdt load, the settle delay before it, and the 10 ms
INIT-to-SIPI wait sliced into 20. The first three failing boots of the evening
had the first two of those and still failed every time; success starts with the
sliced wait. Three failures then eight successes in ten is suggestive but not
proof -- at a ~70% success rate three consecutive failures still has about a
3% chance -- so treat "the sliced wait fixed it" as unconfirmed.

### Where it stands

`haiku_loader-stallretry.hpkg` is installed. It carries all of the above
diagnostics plus the 10-attempt retry. The retry costs about 340 ms on a boot
that never brings the AP up and nothing at all on a boot that does, and it is
harmless, but it is not the fix -- nothing here is yet. Every experimental
build is in `/boot/home/loaderbak/` on the machine and in
`/Volumes/HaikuBuild/`.

The next thing worth doing is the one this document has been pointing at all
along and that no amount of loader instrumentation can substitute for: boot a
known-good ISO from external media and see whether it also comes up with one
CPU on the boots where this installation does. Everything measurable from
inside the loader now says the INIT and the SIPI are perfectly formed, are
accepted by the local APIC without error, and are simply not acted on -- which
is what an AP that is not there looks like.

### Reading the AP diagnostics without a desktop

Booting the diagnostic ISO on this machine reached a blue desktop with no
Installer and no Deskbar, so there was no Terminal to read a syslog from. That
does not block the measurement: every `smp:` line the investigation needs is
printed by the **boot loader**, before the kernel starts, so it can be read off
the screen directly.

Hold Shift (or tap Space) as the loader starts, then
`Select debug options` -> mark `Enable on screen debug output`
(`debug_screen`, `src/system/boot/loader/menu.cpp:1484`). Leave
`Disable on screen paging` unmarked so the output stops a screenful at a time
and can be read or photographed. `Continue booting`.

The lines that decide a boot:

```text
smp: early wake sent to 1 ap(s) at NNNNN ms after power-on
     (took NN ms, sequence completed, attempt X of 10, Y spoiled by a stall)
smp:   stall: slice N of 20 took NNNNNN us          # bad boots only
smp:   markers 5 ms after the wake: real-mode 0x..., pmode 0x...
smp: cpu 1 was parked by the early wake, handed over
scheduler_init: found N logical cpu
```

`markers` of `0xa5a5`/`0x5a5a5a5a` means the AP ran; `0x0`/`0x0` means it did
not. That one line settles a boot without needing userland at all.

### The diagnostic ISO

`/Volumes/HaikuBuild/generated.vaio-pin/haiku-nightly-anyboot.iso`, built
2026-08-19 16:16 with `jam -q -j2 @nightly-anyboot` in `generated.vaio-pin`
(whose `HAIKU_TOP` is `../wt-new`), so it carries the same loader as the
installed system including every diagnostic above. 1202 targets updated, no
failures; verified by byte-searching the image for `spoiled by a stall` and
`markers 5 ms after the wake`.

Do not use `docker-build-vaio-p-iso.sh` for this: it clones a fresh tree and
applies `vaio-p-patches.diff`, which does not contain the diagnostics, and it
rebuilds from scratch.

Two things checked while chasing the missing Installer, both negative:

- `AddHaikuImagePackages: package icu not available!` is a **pre-existing**
  warning -- it appears in more than ten older `jam_*.log` files on the build
  volume, and the icu packages are in fact present in the image.
- `Installer` is registered normally in `build/jam/images/definitions/minimum`
  (in both `SYSTEM_APPS` at line 139 and `DESKBAR_APPLICATIONS` at line 157)
  and its binary is built. Searching the ISO for the string finds nothing only
  because it lives inside the compressed `haiku.hpkg`; that search proves
  nothing either way.

The cause of the missing Installer is still unknown. Note this machine needs up
to 60 seconds of boot-partition retries off USB (`vfs_boot.cpp:489`), so "still
loading" has not been excluded.

## The causal fix candidate: pre-wake EHCI handoff (2026-08-19 evening)

### The chain of evidence

Assembled from this evening's measurements, each piece already recorded above:

1. Boots where a ~200 ms stall lands in the INIT-to-SIPI window lose the AP;
   boots without the stall keep it. The stall is this thread ceasing to
   execute -- an SMI, by elimination (not periodic, not the INIT's cost, not
   the target's cost; only the *first* INIT of the boot is followed by it).
2. An SMI takes **both** logical processors into SMM. An INIT/SIPI aimed at
   the sibling while firmware is holding it is firmware's to lose, and this
   firmware demonstrably loses it: eight clean INIT/SIPI sequences in one
   boot, zero responses.
3. This BIOS never acknowledges the EHCI legacy handoff, so its USB legacy
   emulation -- SMI-driven -- stays armed. The existing fix for that
   (`intel_fixup_ehci_bar()` in `pci_fixup.cpp`) runs at *kernel* PCI scan
   time. The early wake runs in the *loader*, minutes of machine-time
   earlier. During every early wake so far, the BIOS's USB SMIs were live.

### The change

`smp_early_usb_handoff()` in the loader's `smp.cpp`, called at the top of
`smp_wake_other_cpus_early()`, before the first INIT. It replicates the
kernel fixup with raw config-mechanism-1 accesses (the loader has no PCI
module; it needs twenty lines): find 8086:8117 on bus 0, read EECP from MMIO
HCCPARAMS (fallback 0x68 per the SCH datasheet), verify capability ID 0x01,
briefly request ownership politely (50 ms -- this BIOS has never acknowledged,
the wait is a formality), then force the BIOS semaphore off and zero
USBLEGCTLSTS, killing every BIOS SMI source on the controller. The SCH UHCI
companions (0x8114-0x8116) are left strictly alone -- they do not implement
USBLEGSUP and writing it corrupts them (the headline fix).

Gated on the exact device ID, so it is a no-op on any other machine.

### The stated risk

Booting the *ISO from USB*, the loader still reads the kernel off the stick
via BIOS INT 13h after this handoff. If this BIOS implements USB INT 13h via
the same SMI machinery, that read could fail and the boot hang right there.
Typical BIOS mass-storage INT 13h is synchronous driver code, not SMI-driven
(the SMIs gate the 60h/64h keyboard trap and ownership events), and the
loader itself was already read successfully before the handoff runs -- but
this BIOS has earned skepticism. **If the handoff ISO hangs early in boot on
USB, that is why**, and the handoff needs gating to non-USB boots. On the
installed system (internal disk) this risk does not exist.

### Boot-loader-menu verdict (third attempt at making the result readable)

The `debug_screen` hold never ran: safemode settings are created by the boot
menu (`main()`, start.cpp:260) and the early wake runs before it
(start.cpp:219), so the setting always read false. Attempt three puts the
verdict where reading it needs no timing at all: `smp_add_safemode_menus()`
now prepends a non-selectable `AP: STARTED -- 2 CPUs this boot` /
`AP: NOT STARTED -- 1 CPU this boot` line (details in its help text) to the
safe-mode menu, which is built after the wake and waits for the user by
construction. Shift at boot -> Select safe mode options -> read the first
line.

### The live-session application failure, planned

On the live ISO the workspace paints and Ctrl+Alt+Del's Team Monitor works
(so app_server and input are fine), but no application launches -- not
Tracker, not Deskbar, not Terminal from the Team Monitor itself. That rules
out the launch_daemon *conditions* this document previously blamed (two ISO
respins proved that theory wrong) and points below BRoster/registrar or at
image content.

The loader patch already defaults `keep_debug_output_buffer` to true
(`loader/main.cpp:45`), so the wedged session's syslog survives a forced
reboot. The read path that needs no working userland: wedge, force reboot,
Shift into the loader menu, **Display syslog from previous session**. The
keyboard works in the menu (it navigates it), paging there is by keypress.
The registrar/Tracker/runtime_loader errors will name the actual cause;
everything tried before that read is guessing, and both guesses so far were
wrong.

### The handoff ISO crashed the loader on USB boot -- risk confirmed, gate added

The stated risk was real, and it manifested on the very first USB boot of the
handoff build: `Boot Loader Death Land`, a Divide Error at eip 0x3eb5b.
Symbolized against `boot_loader_bios_ia32` (text base 0x10000), that is
`__divmoddi4`, and the frames walk up through `BIOSDrive::ReadAt` (0x1124f),
`Descriptor::ReadAt`, `read_pos`, `boot::Partition::ReadAt`,
`EFI::Header::_Read`, `efi_gpt_identify_partition` -- the GPT scan of the
boot USB stick, reading through BIOS INT 13h, dividing by a
`bytes_per_sector` of 0. After `smp_early_usb_handoff()` cleared the BIOS's
EHCI claim and SMI enables, the BIOS's USB mass-storage service was broken.

Two consequences:

- **This is direct evidence for the SMI hypothesis.** The BIOS's USB legacy
  machinery is demonstrably alive and load-bearing during the loader phase --
  the same machinery that generates SMIs through the early wake window on
  every boot.
- **The handoff is now gated on the boot medium**:
  `platform_boot_drive_is_ata()` (devices.cpp) asks EDD (INT 13h AH=48h,
  usable this early -- it needs only `gBootDriveID`, set by shell.S from DL)
  for the boot drive's interface type. Only an explicit EDD 3.0 "ATA" answer
  lets the handoff run; USB, no EDD 3.0, or no answer skips it with a syslog
  line. On this machine the internal 1.8" drive is ATA, so the installed
  system gets the handoff; the ISO on a USB stick does not.

Which splits the validation cleanly: the USB/ISO boots measure the baseline
AP success rate (no handoff, expect ~70%) plus the live-session application
failure; the handoff's effect on the AP rate is measured on the installed
system, where reboots can be driven over ssh.

Loader packages: `haiku_loader-usbhandoff.hpkg` (ungated -- crashes USB
boots, do not use), `haiku_loader-usbhandoff-gated.hpkg` (the one to use).

### USB baseline: 5 of 5 boots came up with both CPUs (2026-08-19 evening)

Five consecutive USB boots of the gated ISO (handoff *skipped* -- the gate
correctly refuses non-ATA boot media), each photographed with on-screen debug
output enabled, all five showing `CPU 1: apic id 1 ... smt 1` and
`scheduler_init: found 2 logical cpus`. So the AP came up every time on USB,
against an installed-system baseline of roughly 7 in 10.

Caveats before reading too much into that: 5/5 at a true 70% rate has ~17%
probability, so this alone does not prove USB boots are different; and these
boots ran with on-screen debug output active, which slows the whole loader
down (VGA text output for every dprintf) and therefore moves the wake later
by seconds -- not a controlled comparison against the installed numbers.
What it does establish: the gated ISO boots reliably (the divide-error crash
is gone), and the AP question on this machine remains per-boot, not
per-medium.

### Why "Display syslog from previous session" was missing, and the way in

The menu item is conditional (loader menu.cpp): it appears only when the
loader finds the previous session's syslog ring buffer still readable in RAM
(`gKernelArgs.debug_output`). Cutting power destroys RAM, so the power-off
between test boots is exactly what removed the item. The tree already
defaults `keep_debug_output_buffer` to true (loader main.cpp:45), so the
buffer exists -- it just has to survive, which needs a *warm* reboot.

The wedged live desktop provides one: the Team Monitor (Ctrl+Alt+Del) has a
**Force reboot** button wired straight to `_kern_shutdown(true)`
(TeamMonitorWindow.cpp:286) -- a kernel syscall from input_server, no
application launch involved, so it works precisely in the state where nothing
else does. The procedure for reading why applications fail on the live ISO:

1. Boot the ISO, let it reach the wedged blue desktop.
2. Ctrl+Alt+Del -> Force reboot (NOT the power button).
3. Shift into the loader menu -> Debug options ->
   "Display syslog from previous session" (it will exist this time).
4. The registrar/Tracker/runtime_loader errors from the wedged session are in
   there; page through with the keyboard, which works in the menu.

No rebuild is needed for this; the burned gated ISO already does everything
required.

### The pre-wake EHCI handoff does not fix the AP (2026-08-19, ~19:00)

First boots with the handoff active on the internal disk, all warm reboots:

| wake at | handoff | stalled attempts | result |
| --- | --- | --- | --- |
| 10326 ms | ran, BIOS released | 2 of 10 | 1 CPU |
| 10424 ms | ran, BIOS released | 2 of 10 | 1 CPU |
| 10450 ms | ran, BIOS released | 2 of 10 | 1 CPU |
| 10518 ms | ran, BIOS released | 2 of 10 | 1 CPU |

Two facts, both decisive. The stalls **persist with every EHCI SMI source
cleared before the first INIT**, so the EHCI legacy capability is not where
the stall comes from (note the BIOS even released ownership politely at
loader time, something it never once did at kernel time). And the AP still
never starts. The handoff stays in the loader (gated, harmless, possibly
useful to the kernel-side USB story) but it is not the CPU fix.

Same-session boots without the handoff: successes at 14452 ms and 10287 ms
(attempt 1, zero stalls), failures at 10162/10345/10454 ms (2-3 stalls).
10287 succeeded and 10326 failed 39 ms apart, so the wake-time-threshold
reading of the morning's data is also dead. What survives, now across ~15
instrumented boots without a single exception: **stalls during the wake
attempts == the AP will not start this boot; no stalls == it will.** The
fate is fixed before the loader runs, and re-rolls per POST.

### The reroll loader (haiku_loader-reroll.hpkg): stop fighting, re-toss

If the state is a per-boot coin toss that the loader can read within 600 ms,
the robust move is to detect the losing toss and reboot on purpose. After
the 10 wake attempts, if the AP's own real-mode marker is still zero, the
loader increments a counter and pulses the keyboard controller (out8(0xfe,
0x64) -- the ACPI reset register on this machine times out, measured;
the KBC pulse demonstrably works). Counter lives in the RTC alarm-seconds
CMOS byte (0x01): survives warm reset, not in the checksummed setup area
(this BIOS has no setup UI to fix a checksum error with, so that area must
never be touched), never otherwise used here, magic high nibble 0xa0
against stale bytes. Cap: 3 rerolls, then boot on with one CPU and clear
the counter; also cleared on success. A reroll costs one POST (~11 s).

The syslog of the boot that finally succeeds carries
`AP came up after N deliberate reboot(s)`, so the mechanism is visible
after the fact even though the rerolled boots' own loader logs are lost.

Honest caveat: in this evening's warm-reboot streaks the bad state repeated
7 boots out of 8, so consecutive rerolls may be correlated rather than
independent tosses -- 10287's success right after a failure shows the state
*can* flip on a warm reset, but if the measured convergence turns out poor,
the next variant should try a harder reset for the reroll (port 0xcf9 full
reset, if this SCH implements RST_CNT) before giving up on the approach.

### Reroll results, first round: works until the dice are loaded

With the reroll loader installed, the first five internal-disk boots all came
up with both CPUs on the first toss (wakes at 10477-10510 ms, attempt 1, zero
stalls, no rerolls fired). Then, straight after the TCP panic below and its
KDL `reboot`, one boot ran the whole gauntlet and lost:

```text
smp: early wake: AP unresponsive after 3 reroll(s), continuing with one CPU
```

Four bad tosses in a row, consistent with the evening's earlier 7-of-8
warm-reboot failure streak: **the bad state tends to survive a KBC-pulse warm
reset**, so consecutive rerolls are correlated, not independent. The loader
now escalates: RST_CNT full reset first (`out8(0x02, 0xcf9)`, pause,
`out8(0x0e, 0xcf9)` -- FULL_RST is as close to a power cycle as software gets
here), KBC pulse only as the fallback if the chipset ignores 0xcf9
(`haiku_loader-reroll-cf9.hpkg`). Whether CF9 rolls better dice than the KBC
is exactly what the next measurement round is for.

### The second CPU's first casualty: an SMP race in the TCP stack, found and fixed

Minutes into the first session with both CPUs doing real work, the kernel
panicked -- `PANIC: bound endpoint 0xe0bf0e00 not in hash!`, thread "sshd"
**running on CPU 1**, tearing down a TCPEndpoint while the measurement loop's
rapid ssh connects hammered the stack. The bug is a textbook TOCTOU in
`EndpointManager::Unbind()` (tcp/EndpointManager.cpp): the `IsBound()` check
ran *before* taking the write lock, while both the hash removal and the
`sa_len = 0` that makes `IsBound()` false happen *under* it. Two concurrent
Unbind() calls both pass the check, serialize on the lock, and the loser
panics on the failed hash removal. Strictly unreachable with one CPU --
which is why a machine that spent weeks at 1 CPU never saw it, and hit it
within minutes of having two.

Fix: move the bound check under the WriteLocker (double-unbind now returns
`B_BAD_VALUE` benignly; a genuinely bound-but-not-hashed endpoint still
panics, as it should). The Bind-side paths were audited and already hold the
write lock correctly. Upstream-worthy.

Deployed without a kernel rebuild: `jam -q tcp` builds the protocol add-on
standalone, and a copy at
`/boot/system/non-packaged/add-ons/kernel/network/protocols/tcp` shadows the
packaged one from the next boot (same mechanism as the kernel-driver
override; unlike media add-ons, kernel modules shadow cleanly by path).

Measurement-loop hygiene, learned the hard way: rapid-fire ssh probes are a
TCP torture test for the machine being probed. The probe loops now hold each
session open a second (`ssh ... 'sleep 1; ...'`) instead of opening dozens of
back-to-back connections.

## The live-medium "no Installer" bug: root-caused and fixed (2026-08-20)

Reproduced in QEMU, which turns this from a photograph-and-guess problem into
an ordinary debugging loop:

```sh
qemu-system-x86_64 -m 1024 -smp 2 -cdrom haiku-nightly-anyboot.iso \
	-usb -device usb-tablet \
	-serial file:serial.log -display none \
	-monitor unix:/tmp/hq/mon.sock,server,nowait -daemonize -pidfile q.pid
```

`-serial file:` captures kernel *and* userland syslog (userland syslog is
forwarded there too, which is how `package_daemon:` and
`Launching ... failed:` lines become visible). The monitor socket gives
`screendump` for the framebuffer and `sendkey` for input; `-device usb-tablet`
makes `mouse_move` absolute, without which the PS/2 relative mouse clamps at
~±128 per packet and clicks land nowhere. Alt+SysReq+D
(`sendkey alt-sysrq-d`, ps2_keyboard.cpp:196) drops into KDL, whose prompt is
readable on serial and typeable via sendkey, so `threads`, `sem <id>` and
`bt <thread>` all work headless.

smp=1 and smp=2 guests stalled identically, so SMP was eliminated early.

### Two independent bugs, both upstream

**1. `BRoster` cannot resolve any signature on a live ISO9660 session.**

The MIME database's app hints are written when the image is built and name
paths on the *build* machine:

```
$ catattr META:PPATH /boot/system/data/mime_db/application/x-vnd.haiku-firstbootprompt
/haiku-build/generated.x86_gcc2h-linux/objects/.../firstbootprompt/FirstBootPrompt
```

(`mimeset -f --apps` via `CreateAppMimeDBEntries`, BeOSRules:211, records
whatever path it was handed.) `BRoster::_FindApp` therefore finds the hint
invalid, drops it, and falls back to `query_for_app()` -- which searches only
volumes that both `KnowsQuery()` and carry a `BEOS:APP_SIG` index, skipping
all others *deliberately*. A live ISO9660 volume has no such index, so the
query searches nothing and returns `B_LAUNCH_FAILED_APP_NOT_FOUND`.

Every observed failure was a signature launch, and every success was a path
launch -- the symptom was never "the desktop is broken":

| what | how it launches | live ISO |
| --- | --- | --- |
| FirstBootPrompt (the "Try Haiku" window) | signature (`job x-vnd.Haiku-FirstBootPrompt`) | failed |
| Installer | signature | failed |
| Team Monitor's "Open Terminal" | signature (`be_roster->Launch`, TeamMonitorWindow.cpp:281) | failed |
| app_server | path (`launch /system/servers/app_server`) | worked |

It also explains why the installed BFS system was fine (queries work there),
and why the pre-existing `Job.cpp` retry patch never helped: it retries
`B_LAUNCH_FAILED_APP_NOT_FOUND` for 180 s, but the condition is permanent.

Fix (`src/kits/app/Roster.cpp`): when the query comes up empty, search the
standard application directories for a file whose `BEOS:APP_SIG` matches,
before giving up. The stale hint's *file name* is kept and tried directly in
each directory first, so the common case is a handful of `stat()` calls rather
than a scan. This fixes the whole class, including the signature launches that
FirstBootPrompt itself performs when its buttons are pressed.

**2. A `run` block that names targets directly is silently ignored.**

`LaunchDaemon::_AddRunTargets(message, NULL)` built an empty local `targets`
message and iterated *that*, so with

```
run {
	desktop
}
```

the parser stored `target = "desktop"` in the block's own message
(`RunConverter`, SettingsParser.cpp:121) and the daemon read none of it. Only
the `then`/`else` sub-message forms ever worked. Confirmed in KDL: the user
session's launch_daemon worker sat on `sem 357 'have runnable job'` with
`count -1` -- no jobs had ever been queued -- while app_server, which is a
top-level entry rather than a target member, was running fine.

This is why the `run { desktop }` workaround tried on 2026-08-19 changed
nothing. Fixed to iterate the message itself when no sub-message is named.

### Verified

`data/launch/user` is back to upstream (the workaround is gone; `first_boot`
is selected on live media as designed). In QEMU the ISO now boots to
**"Welcome to Haiku!" with Install Haiku / Try Haiku**, no
`Launching ... failed` anywhere in the log, and "Try Haiku" brings up the full
desktop -- Tracker, Deskbar, and an Installer icon on the Desktop.

### On the Deskbar's "Applications" being empty

Worth separating from the launch bug above, because it has a different cause
and is *not* fixed by the Roster change.

The Deskbar menu is not built by querying or by launching anything. On open,
`TBarWindow::MenusBeginning()` (BarWindow.cpp:114) reads a `menu_entries`
file and navigates the directories it lists:

```text
directory /boot/home/config/settings/deskbar/menu
directory /boot/home/config/non-packaged/data/deskbar/menu
directory /boot/home/config/data/deskbar/menu
directory /boot/system/non-packaged/data/deskbar/menu
directory /boot/system/data/deskbar/menu
```

Those entries are plain symlinks shipped in `haiku.hpkg`
(`build/jam/packages/Haiku:480-496`, from `DESKBAR_APPLICATIONS` in the image
definitions). Verified present in the current image: `data/deskbar/menu_entries`
plus 24 links under `data/deskbar/menu/Applications/` -- Terminal, Installer,
HaikuDepot, DriveSetup and the rest -- each pointing at `../../../../apps/<name>`.
`TDeskbarMenu::DoneBuildingItemList()` is what prints
`<Deskbar folder is empty>` when that navigation yields nothing.

So if the menu still comes up empty on the VAIO, the question is whether those
directories resolve *at that moment* on that machine -- a packagefs/mount
timing question -- not a signature-resolution one. The check is one line in a
Terminal on the live session:

```sh
ls /boot/system/data/deskbar/menu/Applications | wc -l    # expect 24
```

The installed system answers 32 (it has extra links in
`~/config/settings/deskbar/menu`), so the mechanism demonstrably works there.

Not yet confirmed on the live medium: driving the Deskbar menu open under
QEMU was not possible. `-device usb-tablet` is enumerated by the guest
(`usb_hid` loads) but `mouse_move` never moves the guest cursor, and the PS/2
mouse only accepts small relative deltas, so clicks could be delivered
(a Tracker context menu did open) but not aimed. Everything above was
established from the image contents and the source instead.

### Resolved: the AP is slow to start, not unwakeable (2026-08-20)

The USB boot test settled it, and it overturns the model this document has been
built on. **There is no few-second window.** The AP does start; it just takes far
longer to execute the trampoline than any of the waits allowed for.

The live-USB boot logged both halves of the story in one run:

```text
smp: early wake sent to 1 ap(s) at 12983 ms after power-on (took 846 ms,
     sequence completed, attempt 10 of 10, 3 spoiled by a stall)
smp: early wake: AP unresponsive after 3 reroll(s), continuing with one CPU
smp:   markers 5 ms after the wake: real-mode 0x0, pmode 0x0
...
smp: before handover: trampoline code intact, gdt limit 0x17 base 0x9e008,
     markers real-mode 0xa5a5 pmode 0x5a5a5a5a, handover 0x0/0x0
smp: cpu 1 was parked by the early wake, handed over
```

Five milliseconds after the SIPI both markers read zero and the code declared
the AP unresponsive. By handover time both were set and CPU 1 was taken over.
Nothing was wrong with the wake - the check was simply too early.

That explains every failure recorded above. `earlyclean` and the loaders built
during this investigation give the AP 500 ms per attempt, three attempts, and
then **disable the CPU permanently**. The newer code retries up to ten times,
detects when its own timing loop stalls and rerolls the attempt, and - the part
that actually matters - **re-reads the markers at handover instead of trusting
its own earlier verdict**.

The machine's internal disk already runs that loader (`9af78137`), and it comes
up with both CPUs:

```text
smp: early wake sent to 1 ap(s) at 11058 ms after power-on (took 13 ms,
     sequence completed, attempt 1 of 10, 0 spoiled by a stall)
smp: cpu 1 was parked by the early wake, handed over
```

### Why USB booting is the harder case

The live boot needed all ten attempts and lost three to stalls; the ATA boot
succeeded on the first, in 13 ms. The loader says why:

```text
smp: early usb handoff skipped: boot drive is not ATA,
     the BIOS's USB machinery may be load-bearing for INT 13h
```

Booting from USB, the loader cannot take USB away from the BIOS, so BIOS activity
keeps perturbing its timing. Booting from the internal disk it can, and the
sequence runs clean. Worth knowing when reading a log: an `attempt 10 of 10` on a
live USB boot is expected, not a warning sign.

### Corrections this supersedes

- "The window in which this machine will start an AP is only a few seconds wide
  from power-on" - not supported. The SIPI goes out at 11-13 s on every boot,
  including the ones that succeed.
- The measured "one second delay works, five does not" result was real but was
  reading a different effect; with an insufficient wait, whether a boot succeeds
  is close to chance, which is exactly the "same binary both succeeded and
  failed" behaviour recorded earlier.
- Standby power, CMOS state, cold versus warm boot, microcode and BIOS settings
  are all irrelevant, as the eliminations above found. The variable was always
  the wait.

### Still open

Booting the live image, the Deskbar leaf menu shows only `<empty>`. Terminal via
Ctrl+Alt+Del works, so the system itself is fine. To be reproduced in QEMU and
fixed there - unrelated to SMP.
