# VAIO P webcam patches

한국어: [`README.ko.md`](README.ko.md) / Italiano: [`README.it.md`](README.it.md)

This folder holds the USB webcam (UVC) changes from `../vaio-p-patches.diff`, split out so they can be handed on separately. The hunks are copied unchanged: `vaio-p-patches.diff` still contains them, and the VAIO P ISO build still uses that file.

Background: the Sony VAIO P's built-in camera is a USB 2.0 UVC device that streams YUY2. Haiku's `usb_webcam` media add-on ships with UVC compiled out. Even with it compiled in, capture fails at several layers: the add-on, the USB Kit, `usb_raw`, and the EHCI driver. These patches fix each layer.

## Files

Apply in numeric order. Each diff is a plain `git diff` against the source tree root.

| File | Scope | What it does |
|---|---|---|
| `01-usb_webcam-uvc.diff` | `src/add-ons/media/media-add-ons/usb_webcam/` (7 files) | Enables UVC in the Jamfile and fixes the UVC path. The main fix: `AcceptVideoFrame()` sent the 0-based list position as the 1-based UVC frame index, so the camera streamed a different resolution than the host decoded. Also: YUY2 decoding with bounds clamps; high-bandwidth `wMaxPacketSize` decoding; fixed-stride packet walking; double-buffered capture on the new Queue/Wait API; FID-anchored deframing; a stale-frame drain; no black flashes on dropped frames; a `StopTransfer()` teardown order fix (it caused a "USB object did not become idle" panic); and a lock around `fFrames.AddItem()` on the USB thread. |
| `02-usbkit-queued-isochronous.diff` | `usb_raw.cpp`/`.h`, `USBEndpoint.cpp`, `USBKit.h` | New `B_USB_RAW_COMMAND_QUEUE_ISOCHRONOUS`/`WAIT_ISOCHRONOUS` ioctls and `BUSBEndpoint::QueueIsochronous()`/`WaitIsochronous()`. They let two isochronous transfers be outstanding at once, so a capture loop leaves no gap for the device to transmit into. The old blocking ioctl is unchanged. **`01` does not compile without this.** |
| `03-ehci-isochronous.diff` | `ehci.cpp`/`.h` | Four generic EHCI isochronous bugs: (1) TLENGTH overflowing into the status bits; (2) a 1 ms gap from an off-by-one in `fNextStartingFrame`; (3) only the last iTD of a multi-iTD transfer was unlinked, a use-after-free panic; (4) a race in starting-frame selection. Not a build dependency, but USB 2.0 capture panics or loses data without it. |
| `04-codycam.diff` | `src/apps/codycam/VideoConsumer.cpp`/`.h` | CodyCam display: letterboxing instead of stretching, and rotating through all three bitmaps when the producer owns the buffers (fixes a tearing race). Independent of the others. |
| `05-media-event-looper.diff` | `src/kits/media/MediaEventLooper.cpp` | `ControlLoop()` dereferenced `TimeSource()` unguarded. That call returns NULL while the media server shuts down, so a stopping webcam node crashed `media_addon_server`, taking the audio mixer with it. Generic and independent of the others. |

These patches also rely on a `BUSBInterface::SetAlternate()` fix: without it, `EndpointAt()` keeps returning alternate 0's endpoints and no isochronous data ever arrives. That fix is not included here because RenkuOS and Haiku master already carry it.

## Base and verification

- The diffs were cut from the VAIO P patch set, whose baseline is [RenkuOS](https://github.com/RenkuOS/Source) `f04d7eb54a` (`hrev60072+55`). RenkuOS is a fork of Haiku.
- `git apply --check` passes for each file on its own, and `git apply` succeeds for all five together, on:
  - RenkuOS `f04d7eb54a`;
  - RenkuOS `68a8443336` (the nightly of 2026-09-17);
  - Haiku master `d8655a1bdc` (2026-09-17).
- With only these five diffs applied to RenkuOS `68a8443336` (none of the other VAIO P patches), everything they touch compiles and links for 32-bit `x86_gcc2h`: `usb_webcam.media_addon`, `CodyCam`, `libdevice.so`, `libmedia.so`, `usb_raw` and `ehci`.
- They were developed and run on the VAIO P as part of the full patch set. They were not tested on other hardware.

```sh
cd /path/to/haiku-or-renku-source
git apply /path/to/webcam/*.diff
```

## Testing notes

- **Replacing a media add-on without reinstalling.** A copy in `non-packaged/add-ons/media` loads *in addition to* the packaged one. Both then claim the camera and neither works. Hide the packaged file first with `/boot/system/settings/packages`:

  ```
  Package haiku {
  	BlockedEntries {
  		add-ons/media/usb_webcam.media_addon
  	}
  }
  ```

  Then put the built add-on in `/boot/system/non-packaged/add-ons/media/` and reboot. Remove the blocklist once a package with the fix is installed, or it hides the fixed add-on too.
- **Kernel/kit side.** `02` changes `usb_raw` (kernel) and `libdevice.so` together, and the new ioctl numbers must match. Ship both, or neither.
- **A "no camera" result that is not one.** With no default video input assigned, `BMediaRoster::GetVideoInput()` returns `B_NAME_NOT_FOUND` even though the camera is enumerated and producing frames. Check the syslog for `usb_webcam deframer` lines first.
- **Do not load another UVC add-on beside it.** For example, [haiku-uvc-webcam](https://github.com/atomozero/haiku-uvc-webcam) and this `usb_webcam` both claim the same device.

## Notice

These patches were produced by a human working with Claude, and were verified on the actual VAIO P hardware.

**The Haiku project does not accept AI-assisted contributions, and none of this has been or should be submitted upstream.** It is published under the same MIT terms as the code it modifies (see `../LICENSE`). If you reuse any of it, please carry this notice with it.
