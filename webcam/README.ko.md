# VAIO P 웹캠 패치

English: [`README.md`](README.md) / Italiano: [`README.it.md`](README.it.md)

이 폴더는 `../vaio-p-patches.diff`에 들어 있는 USB 웹캠(UVC) 관련 변경을 따로 전달할 수 있게 분리해 둔 것입니다. hunk는 원본 그대로 복사했습니다. `vaio-p-patches.diff`에도 여전히 들어 있고, VAIO P ISO 빌드는 계속 그 파일을 사용합니다.

배경: 소니 VAIO P의 내장 카메라는 YUY2로 스트리밍하는 USB 2.0 UVC 장치입니다. Haiku의 `usb_webcam` 미디어 애드온은 UVC가 빠진 채로 빌드되어 배포됩니다. UVC를 넣어 빌드해도 애드온, USB Kit, `usb_raw`, EHCI 드라이버 여러 계층에서 캡처가 실패합니다. 이 패치들은 각 계층을 수정합니다.

## 파일

번호 순서대로 적용합니다. 각 diff는 소스 트리 루트 기준의 일반 `git diff`입니다.

| 파일 | 범위 | 내용 |
|---|---|---|
| `01-usb_webcam-uvc.diff` | `src/add-ons/media/media-add-ons/usb_webcam/` (파일 7개) | Jamfile에서 UVC를 켜고 UVC 경로를 수정합니다. 핵심 버그: `AcceptVideoFrame()`이 0부터 세는 목록 위치를 1부터 세는 UVC frame index로 보내, 카메라가 호스트가 해석하는 것과 다른 해상도로 스트리밍했습니다. 그 외 수정: bounds clamp를 넣은 YUY2 디코딩, high-bandwidth `wMaxPacketSize` 해석, 고정 stride 패킷 순회, 새 Queue/Wait API를 쓰는 이중 버퍼 캡처, FID 기준 deframing, 오래된 프레임 버리기, 프레임 손실 시 검은 화면 깜빡임 제거, `StopTransfer()` 해제 순서 수정("USB object did not become idle" 패닉), USB 스레드의 `fFrames.AddItem()`에 lock 추가. |
| `02-usbkit-queued-isochronous.diff` | `usb_raw.cpp`/`.h`, `USBEndpoint.cpp`, `USBKit.h` | 새 ioctl `B_USB_RAW_COMMAND_QUEUE_ISOCHRONOUS`/`WAIT_ISOCHRONOUS`와 `BUSBEndpoint::QueueIsochronous()`/`WaitIsochronous()`를 추가합니다. isochronous 전송 두 개를 동시에 걸어둘 수 있어, 캡처 루프에 장치가 데이터를 흘려보내는 빈틈이 생기지 않습니다. 기존 blocking ioctl은 그대로입니다. **`01`은 이것 없이는 컴파일되지 않습니다.** |
| `03-ehci-isochronous.diff` | `ehci.cpp`/`.h` | EHCI isochronous 경로의 일반 버그 4개: (1) TLENGTH가 status 비트로 넘침, (2) `fNextStartingFrame` off-by-one으로 생기는 1ms 빈틈, (3) 여러 iTD 중 마지막 것만 unlink하는 use-after-free 패닉, (4) 시작 프레임 선택 경쟁 조건. 빌드 의존성은 아니지만, 없으면 USB 2.0 캡처에서 패닉이 나거나 데이터가 손실됩니다. |
| `04-codycam.diff` | `src/apps/codycam/VideoConsumer.cpp`/`.h` | CodyCam 표시 수정: 늘리지 않고 letterbox로 표시, producer가 버퍼를 소유할 때 비트맵 3개를 돌려 써서 tearing 경쟁 조건 해결. 다른 diff와 독립입니다. |
| `05-media-event-looper.diff` | `src/kits/media/MediaEventLooper.cpp` | `ControlLoop()`가 `TimeSource()`를 검사 없이 역참조했습니다. 미디어 서버 종료 중에는 이 값이 NULL이라, 멈추는 웹캠 노드가 `media_addon_server`를 죽이고 오디오 믹서까지 같이 죽었습니다. 일반 버그이며 다른 diff와 독립입니다. |

이 패치들은 `BUSBInterface::SetAlternate()` 수정도 전제로 합니다. 이 수정이 없으면 `EndpointAt()`이 계속 alternate 0의 endpoint를 돌려줘 isochronous 데이터가 전혀 들어오지 않습니다. RenkuOS와 Haiku master에 이미 반영되어 있어 여기에는 넣지 않았습니다.

## 기준 커밋과 검증

- VAIO P 패치 묶음에서 잘라낸 것이며, 그 기준은 Haiku fork인 [RenkuOS](https://github.com/RenkuOS/Source) `f04d7eb54a`(`hrev60072+55`)입니다.
- 다음 세 트리에서 각 파일 단독으로 `git apply --check`가 통과하고, 다섯 개를 한꺼번에 `git apply`해도 성공합니다:
  - RenkuOS `f04d7eb54a`
  - RenkuOS `68a8443336` (2026-09-17 nightly)
  - Haiku master `d8655a1bdc` (2026-09-17)
- RenkuOS `68a8443336`에 다른 VAIO P 패치 없이 이 다섯 diff만 적용한 상태에서, 영향받는 대상이 모두 32비트 `x86_gcc2h`로 컴파일과 링크까지 됩니다: `usb_webcam.media_addon`, `CodyCam`, `libdevice.so`, `libmedia.so`, `usb_raw`, `ehci`.
- 전체 패치 묶음의 일부로 VAIO P에서 개발하고 실행했습니다. 다른 하드웨어에서는 테스트하지 않았습니다.

```sh
cd /path/to/haiku-or-renku-source
git apply /path/to/webcam/*.diff
```

## 테스트할 때 참고

- **재설치 없이 미디어 애드온 교체하기.** `non-packaged/add-ons/media`에 넣은 사본은 패키지 버전을 대체하지 않고 *추가로* 로드됩니다. 그러면 둘이 같은 카메라를 차지하려다 둘 다 동작하지 않습니다. 먼저 `/boot/system/settings/packages`로 패키지 파일을 숨기세요:

  ```
  Package haiku {
  	BlockedEntries {
  		add-ons/media/usb_webcam.media_addon
  	}
  }
  ```

  그다음 빌드한 애드온을 `/boot/system/non-packaged/add-ons/media/`에 넣고 재부팅합니다. 수정이 들어간 패키지를 설치한 뒤에는 이 blocklist를 지우세요. 그대로 두면 수정된 애드온까지 숨겨집니다.
- **커널/킷 짝 맞추기.** `02`는 `usb_raw`(커널)와 `libdevice.so`를 함께 바꾸며, 새 ioctl 번호가 서로 맞아야 합니다. 둘을 같이 배포하거나 둘 다 빼야 합니다.
- **카메라가 없는 것처럼 보여도 아닐 수 있음.** 기본 비디오 입력이 지정되지 않으면, 카메라가 인식되어 프레임을 내고 있어도 `BMediaRoster::GetVideoInput()`이 `B_NAME_NOT_FOUND`를 반환합니다. 먼저 syslog에서 `usb_webcam deframer` 줄을 확인하세요.
- **다른 UVC 애드온과 함께 올리지 마세요.** 예를 들어 [haiku-uvc-webcam](https://github.com/atomozero/haiku-uvc-webcam)과 이 `usb_webcam`은 같은 장치를 차지하려고 충돌합니다.

## 고지

이 패치는 Claude와 함께 작업해 만들었고, 실제 VAIO P에서 검증했습니다.

**Haiku 프로젝트는 AI가 개입한 기여를 받지 않으며, 이 내용은 업스트림에 제출된 적이 없고 제출해서도 안 됩니다.** 수정 대상 코드와 동일한 MIT 조건으로 공개합니다(`../LICENSE` 참고). 일부를 재사용하신다면 이 고지도 함께 옮겨주시기 바랍니다.
