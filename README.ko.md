# Sony VAIO P Haiku OS 패치 스크립트

English version: [`README.md`](README.md).

이 폴더는 Sony VAIO P (VGN-P70H_G)에서 Haiku OS가 ACPI를 켜고 Safe Mode 없이 정상 부팅/설치/동작하도록 만든 패치를 새 Haiku OS 소스에 적용하고 ISO로 빌드하는 스크립트를 담고 있습니다.

## 이 기기에서는 `pkgman update`(또는 HaikuDepot 업데이트)를 실행하지 마세요

`pkgman update`나 HaikuDepot의 "Update"는 온라인 저장소에서 최신 업스트림 `haiku` 패키지(커널, 모든 커널 add-on, kit 일체를 담고 있음)를 받아와 이 ISO가 빌드될 때 쓰인 것을 그대로 교체해버립니다 — 이 문서에 나열된 하드웨어 전용 수정 전부가 조용히 무효화됩니다(특히 이 정확한 CPU에서 시스템을 완전히 멈추게 하는 `x86_acpi_cstates`가 다시 켜짐 — 아래 "cpuidle" 참고). 실기로 확인됨: 정상 설치되어 잘 부팅되던 시스템이 `pkgman update`를 실행한 직후부터 부팅이 멈췄습니다(HAIKU 로고는 뜨지만 그 뒤로 아이콘이 하나도 안 켜지고 멈추며, DEBUG 옵션을 켜도 출력이 없음 — 이제 이 ISO의 수정이 빠진 시스템으로 재부팅되기 때문입니다). 이 시스템을 업데이트하는 지원되는 방법은 없습니다 — 더 최신 패치 기준으로 다시 빌드하고 재설치하는 것뿐입니다.

## 패치 기준 시점

이 패치들은 **`master` 기준이며 `056fed280f`(hrev99002+115, 2026년 8월 8일)에서 검증**했습니다 — `build-vaio-p-iso.sh`가 새 클론에서 체크아웃하는 바로 그 브랜치입니다. 최초 작성은 2026년 7월 21일 소스 기준이었고, `r1beta6` 기준의 이전 diff는 이 파일의 git 히스토리에 남아 있습니다.

일부 버그(ACPICA Global Lock 초기화 순서 문제, ACPI IRQ 트리거/극성, PCI 미정렬 config 접근, PS/2 멀티플렉서 포트 프로브 타임아웃, USBKit `SetAlternate()` 버그, UHCI halt 복구 미구현, EHCI isochronous 버그 일체, UVC frame index 버그, SMP AP 기동 재시도 등)는 VAIO P 전용이 아닌 범용 정합성 버그라서, 새 체크아웃을 받을 시점에는 이미 공식 소스에서 고쳐져 있을 수 있습니다. 패치가 적용되지 않으면 먼저 이미 수정됐는지 확인한 뒤 다시 작성해 주세요.

실제로 세 건이 그렇게 되어 이제 diff에서 빠졌습니다:

| 패치했던 곳 | 업스트림 수정 커밋 | 비고 |
| --- | --- | --- |
| `headers/private/kernel/kernel.h` (`SET_BIT`/`CLEAR_BIT`의 마스크 해석) | `0dc37ccfb5` | 매크로 자체가 삭제되고 h2 드라이버 세 곳의 호출부가 평범한 비트 연산으로 바뀌었습니다. |
| `acpi_lid.cpp` (`power_daemon`을 100% CPU로 돌게 만든 `position > 0` 조기 반환) | `15c199f8fd` | 같은 제거, 같은 이유입니다. |
| `ehci.cpp` (12비트 `TLENGTH`가 status 비트를 침범하던 문제) | `051bb37f50` | 새 `EHCI_ITD_TLENGTH(x)` 매크로가 `0x0fff`로 직접 마스킹합니다. 나머지 EHCI isochronous 수정 세 건(프레임 체이닝, 모든 iTD 언링크, 시작 프레임 경쟁)은 여전히 필요하며 diff에 남아 있습니다. |

대상이 계속 움직이는 브랜치이므로 `build-vaio-p-iso.sh`는 `git apply -3`로 적용합니다. 주변 코드만 밀린 hunk는 자동으로 병합되고, 진짜 충돌이 날 때만 중단됩니다.

## 무엇을 고치는가

`vaio-p-patches.diff`는 아래 내용을 모두 담은 하나의 누적 diff입니다:

- **Intel SCH의 UHCI (핵심 수정)** — `uhci.cpp`: Poulsbo/SCH 칩셋(디바이스 ID 0x8114~0x8116)의 UHCI 컴패니언 컨트롤러에는 **표준 USBLEGSUP config 레지스터(0xC0)가 아예 구현되어 있지 않으며**, 거기에 통상적인 레거시 핸드오프 값을 쓰면(이 드라이버를 포함해 대부분의 UHCI 드라이버가 늘 하던 일) 컨트롤러의 전송 엔진이 괴상하게 손상됩니다: 스케줄이 도는 것처럼 보이지만(프레임 카운터 진행, 에러 비트 없음) TD가 잘못 실행되거나 아예 실행되지 않고 — ActLen이 0x7ff에 고정, 버퍼 밖 메모리 침범, "host controller process error" halt 연쇄 — **세 컴패니언 어디에서도 USB 1.1 장치가 단 하나도 열거되지 않습니다.** 같은 칩셋의 coreboot/SeaBIOS 포팅에서도 정확히 같은 실패를 겪고 같은 원인을 찾아냈습니다(https://www.seabios.org/pipermail/seabios/2012-August/004327.html). 수정은 해당 디바이스 ID에서 그 레지스터 쓰기 하나를 건너뛰는 것입니다. 이 수정으로 저속/풀스피드 장치(외부 포트의 USB 1.1 마우스/키보드, 그리고 내장 Bluetooth 모듈)가 처음으로 열거되고 동작합니다. 추가로 `Start()`가 Linux uhci-hcd와 동일하게 Run과 함께 Configure Flag/64바이트 reclamation 비트도 설정합니다.
- **USB 안정성/부팅 속도** — `Hub.cpp`/`usb_private.h`/`BusManager.cpp`: 포트마다 무한 재시도 대신 재시도 -> 비활성화 -> 파워사이클 순으로 단계적으로 포기하는 백오프, `SET_ADDRESS` 재시도를 낭비하지 않도록 주소 0에서 `GET_DESCRIPTOR`로 먼저 응답 여부를 확인하는 프로브, Poulsbo 칩셋의 EHCI/UHCI BAR0 픽스업. 재시도/파워사이클 백오프를 모두 소진한 포트는 5초 쿨다운 후 새로운 연결 이벤트가 있을 때만 다시 기회를 얻습니다(최대 3회 재무장, 그 후에는 그 부팅 동안 무시) — EC가 제어하는 내장 장치처럼 첫 열거 시도가 다 실패한 뒤에야 전원이 들어오는 경우에 중요합니다. `uhci.cpp`도 마찬가지로 halt 복구를 포기했던 컨트롤러에 쿨다운 후 재복구 기회를 최대 3회 부여합니다(부팅 초기 halt는 아직 전원이 안 들어온 장치와의 상호작용 때문일 수 있으므로).
- **조기 EHCI BIOS 핸드오프 (Poulsbo)** — `pci_fixup.cpp`: 이 기기의 BIOS는 표준 EHCI 레거시 핸드오프에 끝내 응하지 않고("bios won't give up control"이 매 부팅 기록됨), EHCI 드라이버 자체의 강제 탈취는 너무 늦게 실행됩니다: PCI 펑션 번호가 낮은 컴패니언 UHCI 컨트롤러들이 먼저 초기화되어 장치 열거를 시작하는 동안 BIOS는 여전히 자기가 USB를 소유한다고 믿고 SMM으로 개입합니다 — UHCI "host process error" halt가 복구 포기까지 반복되던 원인이 이것이었습니다. 기존 Poulsbo BAR0 픽스업이 이제 PCI 스캔 시점(모든 USB 드라이버 실행 전)에 레거시 핸드오프 전체(정중한 요청 → BIOS 세마포어 강제 클리어 + SMI 차단)를 함께 수행합니다. 이 수정으로 UHCI halt 소용돌이가 사라지고, 남은 halt도 첫 시도에 깨끗하게 복구됩니다.
- **UHCI 컨트롤러 halt 복구** — `uhci.cpp`/`.h`: 일부 하드웨어에서는 오작동하는 장치와 통신하다 컨트롤러 자체가 halt(`process error` → `host controller halted`)되는데, 기존 드라이버는 이때 인터럽트만 끄고 그 컨트롤러(와 거기 물린 모든 장치)를 부팅 내내 영구히 죽은 상태로 방치했습니다 — 소스에 `// ToDo: cancel all transfers and reset the host controller`라고 그대로 적혀 있었습니다. 이제는 진행 중이던 전송을 실제로 취소(소프트웨어 기록뿐 아니라 스케줄에서도 unlink — 이 unlink를 빠뜨린 첫 시도는 즉시 재halt가 반복되며 CPU를 잡아먹는 버그를 냈습니다)하고, 컨트롤러를 리셋한 뒤 스케줄을 재시작합니다. 그래도 halt가 계속 반복되면(스케줄 재시작 자체가 다시 halt를 유발하는, 장치 활동과 무관한 하드웨어 결함으로 보이는 경우) 2초 내 몇 차례 시도 후 포기하도록 상한을 뒀습니다(무한 루프 방지).
- **PS/2 멀티플렉서** — `ps2_common.cpp`: 아무것도 연결되지 않은 멀티플렉스 서브포트(1~3)에 대해 매직시퀀스 전체를 시도하고 타임아웃까지 기다리는 대신, 실제로 응답이 있는 포트만 프로브합니다.
- **WiFi (Atheros AR928X)** — `if_ath.c`/`if_athvar.h`: beacon-miss/bb-hang 복구가 반복되면 어댑터를 PCI 파워사이클(D3->D0)까지 강제합니다. `ieee80211_scan_sta.c`: 실제 접속 요청이 있기 전까지 `net80211`이 열린 AP에 마음대로 자동 접속하지 못하게 막습니다(원래는 STA 모드의 기본 후보 스캔이 부팅 시 가장 가까운 열린 이웃 AP를 붙잡았습니다). `AutoconfigLooper.cpp`/`.h`: 자동 접속을 한 번만 시도하지 않고 유예 시간을 두고 재시도하며, 의도치 않은 오픈 네트워크 연결을 "완료"로 취급하지 않습니다.
- **Sony EC 드라이버 (신규) — Fn+F5/F6 밝기 단축키 실동작 포함** — `drivers/power/sony_ec/`: Sony `SNY5001` ACPI 장치(SNC)용 신규 MIT 라이선스 드라이버로, 밝기 조회/설정, 핫키 arm, 무선 스위치/Fn키 notify 이벤트를 처리합니다. 무선 킬스위치를 토글할 때마다 WLAN 라디오 전원(SNC `F124` sub-function 4)과 Bluetooth 모듈 전원(sub-function 6)을 함께 요청합니다 — 둘 다 이 모델의 DSDT를 직접 디스어셈블해 알아낸 프로토콜이며, EC가 알아서 해주지 않는 일입니다. 덕분에 스위치를 껐다 켜도 WiFi가 죽지 않고 살아나며, Bluetooth 모듈의 로직 전원도 켜집니다(sub-function 5 readback으로 `BTPW` 반영을 확인했고, 모듈의 USB 존재 신호가 전원을 정확히 따라 움직이는 것도 실측 확인). 킬스위치 토글과 별개로, 부팅 후 ~10초 뒤 한 번 무조건 Bluetooth 전원을 요청합니다(스위치를 아예 안 건드리는 개체도 있으므로). (스위치 옆 표시 LED는 이 개체에서는 소프트웨어로 제어되지 않습니다: `WLSL` 비트 쓰기/재독은 정상 동작하지만 실제 LED에는 반영되지 않음.) Linux `sony-laptop.c`를 그대로 가져온 게 아니라 처음부터 새로 작성했습니다(자세한 내용은 드라이버 코드 내 주석 참고).
  - **이제 Fn+F5/F6이 실제로 화면 밝기를 조절합니다.** Fn-로우 12개 키 전부가 DSDT의 `_Q0A`/`_Q0B` EC 쿼리를 거쳐 같은 notify(handle `0x0100`) 하나로 들어오는데, 실제 어떤 키인지는 `F100`의 sub-function 2(`BUF0 = SNC.ECR`, notify 직전에 `H8EC.HKCD`로 채워짐)로 읽어와 실기에서 직접 눌러 확인했습니다(Fn+F5 → 코드 `0x05`/`0x85`, Fn+F6 → `0x06`/`0x86`; press/release 구분은 안 했고 0x80 비트 없는 쪽 코드에서만 동작). 더 어려웠던 부분: 이 모델의 `SBRT` ACPI 메서드는 SNC 자체 스크래치 레지스터를 갱신하고 `ASLE`("백라이트 변경됨" 신호, 인텔 그래픽 드라이버가 받아서 처리하는 용도)를 세팅하는 것까지만 하는데, Haiku엔 이 PowerVR SGX 기반 Poulsbo/GMA500 칩용 그래픽 드라이버가 없어서(아래 "그래픽 가속" 참고) 아무도 이 신호를 안 받습니다. 처음엔 전통적인 인텔 모바일 `BLC_PWM_CTL` MMIO 레지스터(상위16비트 period/하위16비트 duty)를 추측해서 시도했는데 — 실제로 화면 밝기가 바뀌긴 했지만(이 오프셋의 어떤 레지스터가 밝기에 영향을 준다는 증거) 레벨별 밝기 순서가 뒤죽박죽이었습니다(계산한 duty cycle 값 자체는 readback으로 단조 증가가 확인됐으니 수학 문제가 아니라 이 칩의 실제 레지스터 배치와 다른 엉뚱한 레지스터를 건드린 것). Intel의 [SCH US15W 데이터시트](https://www.versalogic.com/wp-content/themes/vsl-new/assets/resources/support/ocelot/Intel_SCH_Specification_Mar_2009.pdf)(문서번호 319537, Graphics/Video/Display D2:F0 섹션)에 진짜 방식이 나와있었습니다: **PCI Config Space 오프셋 0xF4의 LBB(Legacy Backlight Brightness) 레지스터** — period/duty 계산이 아예 필요 없는 단순 선형 0(가장 어두움)~255(가장 밝음) 값이고, 이걸로 바꾸니 실기에서 단조롭고 고른 밝기 조절이 확인됐습니다.
- **Bluetooth (완전히 동작: 로컬 디바이스, 원격 스캔, 킬스위치 복구, 부팅 자동시작)** — 이 개체의 Bluetooth 모듈은 오랫동안 하드웨어 결함으로 판정되어 있었습니다. 완전해 보이는 소거 사슬(EC 전원 요청 정상 동작 확인 — `BTPW` readback, USB 존재 신호가 전원을 따라 움직임 — 건강해 보이는 컨트롤러, 그런데도 `GET_DESCRIPTOR` 무응답)에 근거했지만, 그 사슬에는 검증 불가능한 숨은 전제가 하나 있었습니다 — "UHCI 컨트롤러가 전송 자체는 수행할 수 있다"는 것 — 그리고 그 전제가 거짓이었습니다. SCH USBLEGSUP 손상(위의 핵심 수정 참고) 때문에 UHCI 컴패니언의 어떤 장치도 열거될 수 없었고, 이는 소프트웨어에서 보면 죽은 장치와 구별이 불가능합니다. UHCI 수정 후 모듈은 열거되고 Haiku의 `h2generic` 드라이버가 바인딩되지만, 유저랜드 Bluetooth 스택에 남아있던 버그 3개를 더 고쳐야 실제로 쓸 수 있는 상태가 됐습니다:
  - **`headers/private/kernel/kernel.h`** — `SET_BIT`/`CLEAR_BIT`는 두번째 인자를 `1 << b`로 다시 시프트하는데 `GET_BIT`은 `a & b`로 직접 마스크 비교를 합니다. h2 드라이버의 `bt_transport_status_t` 플래그(`RUNNING = 1<<1` 등)는 이미 최종 비트마스크값이라서, `SET_BIT(state, RUNNING)`은 실제로 0x4를 세팅하는데 `GET_BIT(state, RUNNING)`은 0x2를 확인 — 트랜스포트가 "Device online"이라고 로그를 찍고도 방금 세팅했다는 RUNNING 플래그를 영원히 확인할 수 없어서 모든 HCI 명령을 `B_DEV_NOT_READY`로 거부했습니다. `GET_BIT`과 동일한 마스크 방식으로 수정(이 매크로를 쓰는 곳은 h2 드라이버 파일 3개뿐이라 안전하게 확인됨).
  - **`servers/bluetooth/BluetoothServer.cpp`** — `HandleSimpleRequest()`가 HCI 명령 단 하나만 전송 실패해도 로컬 디바이스를 영구 등록 해제(및 삭제)했습니다. `LocalDevice` 생성자는 등록 직후 이런 요청 6개를 연달아 쏘기 때문에, 그중 하나의 일시적 USB hiccup만으로도 디바이스가 세션 내내 `fLocalDevicesList`에서 조용히 사라져서 이후 "시스템에서 발견한 주변 장치" 조회가 계속 비어있었습니다. 이제 요청 하나만 실패시키고 디바이스는 등록된 채로 남겨둡니다.
  - **`servers/bluetooth/HCITransportAccessor.cpp`/`.h`** — VAIO P의 EC 무선 킬스위치는 Bluetooth 모듈이 물린 USB 포트 자체를 비활성화합니다(아래 `sony_ec` 참고). 그래서 스위치를 껐다 켜면 모듈이 물리적으로 재연결되는데, `bluetooth_server`가 부팅 시 열어둔 파일 디스크립터가 죽어버리고(`EBADF`) 아무도 재오픈하지 않아 재부팅 전까지 Bluetooth가 영구히 고장났습니다. 이제 `IssueCommand()`가 `EBADF`를 감지하면 같은 devfs 경로로 재오픈하고 `BT_UP`을 재전송한 뒤 명령을 재시도합니다.
  - **`preferences/bluetooth/BluetoothMain.cpp`/`.h`** — `be_roster->IsRunning()`이 true가 되는 즉시 Preferences 창을 여는 것은 서버의 비동기 디바이스 탐색과 경쟁 상태였습니다(원저자의 TODO 주석이 이미 지적했던 문제). 이제 서버 팀이 존재하는지만이 아니라 `LocalDevice::GetLocalDeviceCount()`가 실제로 디바이스를 반환할 때까지 제한된 횟수만큼 재시도합니다.
  - **`data/launch/user`** — `bluetooth_server`가 이제 `launch_daemon` 서비스로 자동 시작됩니다(`requires x-vnd.Be-TSKB`, 즉 Deskbar 이후). Preferences에서 수동으로 "지금 실행"을 누를 필요가 없습니다. Deskbar보다 먼저 실행되는 이른 부팅 단계인 `data/launch/system`에는 일부러 넣지 않았는데, `BluetoothServer::ReadyToRun()`의 `_InstallDeskbarIcon()`이 Deskbar 팀이 아직 없으면 조용히 아무 일도 안 하기 때문입니다.

  (아래 `sony_ec`의 전원 처리 — 킬스위치 핸들러 + 부팅 ~10초 후 1회 요청 — 는 모듈에 전원이 들어가기 위해 여전히 필수입니다.)
- **EHCI isochronous 수정 (커널, 범용)** — `ehci.cpp`/`.h`: 사실상 아무도 쓰지 않아 잠자고 있던 isochronous 경로의 실제 버그 4개: (1) iTD의 12비트 TLENGTH 필드를 넘는 패킷 길이가 인접 상태 비트를 침범해 제출 시점부터 디스크립터를 손상시킴(하이밴드위드 엔드포인트의 `wMaxPacketSize`는 4095바이트를 쉽게 넘으므로 USB2 카메라가 바로 걸림); (2) `fNextStartingFrame` 체이닝의 off-by-one으로 제출 사이마다 1프레임(1ms)의 스케줄 공백이 보장되어 isochronous IN 장치가 그 사이에 보낸 데이터가 조용히 유실됨; (3) 멀티 iTD 전송 완료 시 모든 iTD를 해제하면서 마지막 것만 프레임 체인에서 unlink해서, 나머지 프레임 슬롯이 해제된 메모리를 가리키게 됨(실제 use-after-free 커널 패닉 발생); (4) 시작 프레임 결정과 예약이 원자적이지 않아 동시 제출 두 건이 같은 프레임 슬롯에 겹칠 수 있는 레이스.
- **usb_raw + USBKit: 중첩 isochronous 전송** — `usb_raw.cpp`/`.h`, `USBEndpoint.cpp`, `USBKit.h`: 기존의 블로킹 isochronous ioctl을 논블로킹 제출 + 별도 대기로 분리한 신규 `B_USB_RAW_COMMAND_QUEUE_ISOCHRONOUS`/`WAIT_ISOCHRONOUS` ioctl(그리고 대응하는 `BUSBEndpoint::QueueIsochronous()`/`WaitIsochronous()` 공개 API)을 추가했습니다. 요청별 완료 상태를 분리해 전송 2개를 동시에 진행할 수 있습니다. 이게 없으면 모든 캡처 루프가 전송 완료와 다음 제출 사이에 스케줄 공백을 필연적으로 만들고, isochronous IN 장치는 그 공백에도 계속 전송하므로 매 호출마다 데이터가 유실됩니다. 기존 블로킹 ioctl은 그대로 유지됩니다.
- **USBKit `SetAlternate()` 버그** — `USBInterface.cpp`: `BUSBInterface::SetAlternate()`가 실제 장치의 alternate setting은 정상적으로 전환시키면서도 자기 자신의 `fAlternate` 멤버는 갱신하지 않아서, 그 직후 같은 객체에서 `EndpointAt()`을 호출하면 방금 선택한 alternate가 아니라 객체 생성 당시의 alternate(보통 대역폭 0인 유휴 상태)의 엔드포인트를 계속 돌려줬습니다. 실질적으로 USB 웹캠이 isochronous 데이터를 전혀 받지 못했던 첫 번째 원인입니다.
- **웹캠 (UVC)** — `UVCCamDevice.cpp`/`.h`, `UVCDeframer.cpp`/`.h`, `CamDevice.cpp`/`.h`: 최대 원인은 `AcceptVideoFrame()`이 선택한 해상도의 *목록 위치*(0부터)를 저장해놓고 그걸 카메라에 UVC *frame index*(1부터)로 보낸 버그였습니다 — 320x240을 골랐는데 실제로는 카메라에 640x480이 커밋되어, 호스트가 614400바이트 프레임을 153600바이트 320x240으로 잘라 디코드하면서 빗살무늬("인터레이스처럼 보임"), 세로 늘어남, 끝없는 세로 스크롤이 생겼고, 캡처 경로를 아무리 고쳐도 사라지지 않았습니다. 그 위에 얹힌 수정들: YUY2 디코딩(이 카메라는 Bayer가 아니라 YUY2) + 디코더 양쪽에 하드 바운드 클램프(짧은 프레임이 버퍼 밖을 읽고 써서 실제 세그폴트/커널 패닉 발생했음); 하이밴드위드 `wMaxPacketSize` 디코딩(단순 바이트 수가 아니라 기본크기 x microframe당 전송수); 고정 stride 패킷 버퍼 워킹(DMA 버퍼는 `actual_length`가 아니라 `maxPacketSize` 간격으로 배치됨); 신규 Queue/Wait API + 별도 소비 스레드를 쓰는 더블 버퍼 캡처(항상 전송 1개가 컨트롤러에 걸려 있도록); 정확한 바이트 카운트로 프레임을 내보내되 카메라 FID 토글에서 위상을 재고정하고 손실 프레임은 밀린 채 표시하는 대신 조용히 버리는 하이브리드 디프레이밍; 최신 프레임만 표시하는 큐 드레인(지연 감소); 드롭된 프레임에서 검은 화면 대신 직전 프레임 유지; `StopTransfer()`가 스트리밍 인터페이스를 내리기 *전에* 진행 중 전송을 먼저 비우도록 순서 수정(기존엔 실제 "USB object did not become idle" 패닉 발생).
  뒤늦게 발견한 후속 수정: `CamDeframer`의 프레임 목록은 미디어 스레드가 `fLocker` 잠금 아래에서 읽고 비우는데, USB 전송 스레드에서 도는 `UVCDeframer::_EmitCurrentFrame()`은 **잠금 없이** `fFrames.AddItem()`을 호출하고 있었습니다. 두 스레드가 `BList`를 동시에 건드리면 내부 배열이 깨지고, 그 결과가 나중에 `DropFrame()` 안에서 `double free`로 터집니다. 그러면 `media_addon_server`가 죽고, 모든 미디어 애드온이 이 프로세스를 공유하므로 오디오 믹서까지 함께 사라집니다. 경합 자체는 업스트림 것이지만, 위의 오래된 프레임 비우기가 호출마다 여러 프레임을 제거하면서 드물던 창을 잦은 것으로 만들었습니다. 이제 추가 쪽에도 잠금을 겁니다.

- **CodyCam** — `VideoConsumer.cpp`/`.h`: 표시 쪽 수정 2건: 비트맵을 뷰 모양에 강제로 늘리는 대신 화면비를 유지하며 레터박스/필러박스로 그리고, 프로듀서 소유 버퍼일 때 슬롯 0 하나만 쓰지 않고 비트맵 3개를 순환합니다 — 기존 코드는 뷰가 아직 그리는 중인 비트맵 하나를 매 프레임 덮어써서 실제 티어링 레이스가 있었습니다.
- **부팅 화면** — `video.cpp`: 이 하드웨어의 VESA BIOS는 DDC/EDID를 아예 지원하지 않아 네이티브 해상도(1600x768)를 자동 감지할 방법이 없습니다. VESA 모드 목록에 해당 해상도가 있으면 부트로더가 직접 골라 씁니다.
- **부팅 속도/견고성 (범용)** — `smp.cpp`(부트로더): 이 개체의 두 번째 논리 CPU는 기동하지 않는데, 업스트림의 대기 루프에는 타임아웃이 아예 없어서 `smp_boot_other_cpus()`가 그 자리에서 영원히 멈췄고 결국 부팅 자체가 되지 않았습니다. 이제 모든 대기에 상한을 두고, AP마다 INIT/SIPI/SIPI 전체 시퀀스(트램폴린 스택 재설정 포함)를 최대 3회까지 재시도한 뒤 포기하고 실제로 응답한 CPU 수만으로 부팅을 계속합니다. **이는 수정이 아니라 회피이며 CPU는 단일 스레드로 남습니다 — 이 기기에서는 그게 올바른 결과입니다. 아래 "두 번째 논리 CPU" 항목을 보세요.** `evglock.c`: 핸들러 설치 도중 Global Lock SCI가 동기적으로 발생할 때 필요한 락이 아직 없어서 터지는 ACPICA 레이스를 수정. `pci.cpp`: 정렬 안 된 32비트 config 공간 접근을 그냥 거부하지 않고 16비트 접근 두 번으로 쪼갬. `acpi_irq_routing_table.cpp`: 잘못됐을 수 있는 ACPI 서술자를 그대로 믿는 대신 IRQ 극성/트리거 모드를 고정값으로 보정. `vfs_boot.cpp`: 부팅 파티션 탐색을 즉시 패닉하지 않고 최대 60초까지 재시도 — 열거가 느린 USB 부팅 매체에 더해, 부팅 초기 USB halt/복구 사이클(각각의 안정화 지연, 포트 파워사이클, 쿨다운 재무장이 겹겹이 쌓임)이 부팅 장치의 열거를 이전 버전의 10초 한도 너머로 밀어내면서 실기에서 "did not find any boot partitions" 패닉으로 나타났습니다.
- **마이크로코드** — `data/system/data/firmware/intel-ucode/06-1c-02`(신규, Intel 공식 마이크로코드 저장소에서 받음) + `build/jam/images/definitions/regular`의 이미지 규칙: 이 Atom Z520(family 06, model 1c, stepping 02)은 마이크로코드 업데이트가 전혀 배포되지 않아 BIOS가 남긴 리비전 그대로 돌고 있었습니다. 이제 이미지에 해당 파일을 포함하고 `ucode_load`가 부팅 시 이를 적용합니다.
- **harfbuzz 패키징** — `build/jam/DefaultBuildProfiles`: nightly 빌드 프로필에 `harfbuzz`가 아예 빠져 있어서, harfbuzz에 링크된 gcc2용 `libfreetype`이 매 부팅마다 `Cannot open file libharfbuzz.so.0`를 기록했습니다. 이 빌드가 실제로 쓰는 non-gcc2 primary 아키텍처에 대해서는 수정했지만, 저장소에 gcc2 primary 아키텍처용 `harfbuzz` 패키지 자체가 없어서(secondary_x86용만 존재) gcc2 하이브리드 빌드에서는 이 경고를 완전히 없앨 수 없습니다 — 기능에는 영향 없는 경고입니다(harfbuzz 기반 셰이핑은 FreeType의 선택 기능일 뿐).
- **AC 어댑터/뚜껑 스위치 감지 (업스트림 패키징 누락)** — `build/jam/images/definitions/regular`: 이 기기의 DSDT엔 배터리(`\_SB.BAT0`)와 같은 레벨에 지극히 평범한 `\_SB.AC`(HID `ACPI0003`)가 있고 Haiku엔 이에 맞는 `acpi_ac` 드라이버도 이미 있는데, 부팅 시 `acpi_ac_support()`가 단 한 번도 호출되지 않았습니다 — ACPI 네임스페이스 순회 자체는 `\_SB.AC`를 `\_SB.BAT0`와 똑같이 정상 발견합니다(순회되는 모든 ACPI 디바이스 경로/HID를 로그로 남기는 1회성 진단 빌드로 확인). 진짜 원인: `acpi_ac`는 컴파일은 정상적으로 되는데(`jam acpi_ac`로 단독 빌드하면 성공) nightly 이미지의 드라이버 목록에 애초에 추가된 적이 없었습니다 — `SYSTEM_ADD_ONS_DRIVERS_POWER`엔 `acpi_battery`(그리고 이 패치셋이 추가한 `sony_ec`)만 있었고, `acpi_ac`는 업스트림에도 원래 없었음을 `origin/r1beta6`과 비교해서 확인했습니다(이 패치셋이 실수로 뺀 게 아님). `acpi_lid`(`\_SB.LID0`, HID `PNP0C0D`)도 똑같은 누락이었습니다. 둘 다 이제 그 목록에 추가했고, 실기에서 AC 어댑터 연결/해제와 뚜껑 상태가 정상적으로 감지됩니다.
- **뚜껑 스위치가 `power_daemon`을 CPU 100%로 회전시키던 문제 (업스트림 버그, 범용)** — `acpi_lid.cpp`: 위에서 `acpi_lid`를 이미지에 넣자마자 잠복해 있던 업스트림 버그가 드러났습니다. `acpi_lid_read()`는 함수 첫머리의 `position > 0` EOF 검사에서 0바이트를 반환하며 조기 복귀했는데, 그 지점은 드라이버의 대기 플래그를 지우는 `device->updated = false`보다 **앞**입니다. `power_daemon`의 `LidMonitor`는 디스크립터 하나를 계속 열어둔 채 알림마다 1바이트씩 읽으므로 첫 이벤트 이후 파일 위치가 0을 넘어갑니다. 그래서 두 번째 알림부터는 매번 0바이트가 반환되고 `updated`가 참인 채로 남아, `acpi_lid_select()`가 호출될 때마다 select pool을 즉시 다시 signal 상태로 만들었고 `_EventLoop()`는 영원히 100%로 회전했습니다. 실제 증상과 정확히 일치합니다 — 뚜껑을 닫을 때는 멀쩡하고(그게 위치 0에서의 첫 읽기), 열 때 CPU가 치솟으며, 그 상태에서 종료하면 회전 중인 스레드가 종료 요청에 응답하지 못해 `power_daemon` 오류 대화상자가 떴습니다. 형제 드라이버인 `acpi_button`에는 이 검사가 처음부터 없고 매 읽기마다 플래그를 지우기 때문에 전원 버튼은 멀쩡했던 것이며, `acpi_lid_read()`도 이제 동일하게 동작합니다. `acpi_lid`가 애초에 이미지에 포함된 적이 없어서(바로 위 항목) 업스트림에서 잠복해 있던 버그입니다.
- **화면 절전에 백라이트가 따라가도록** — `drivers/backlight.h`(신규), `sony_ec.cpp`, `vesa.cpp`: 지금까지는 화면이 꺼져도 이 패널의 백라이트가 최대 밝기 그대로 켜져 있어서, 화면만 검게 되고 정작 아껴야 할 전력은 거의 그대로 소모됐습니다. 넷북에서는 이게 배터리에 가장 크게 작용하는 요소입니다. 원인은 이 하드웨어에서 VBE DPMS BIOS 호출이 백라이트에 닿지 못한다는 점입니다 — 밝기는 SCH 칩셋 레지스터(Fn+F5/F6 수정이 다루는 그 `LBB` 레지스터)에 있고 BIOS 호출은 거기를 건드리지 않습니다. 작은 선택적 모듈 인터페이스 `generic/backlight/v1`로 해결했습니다: `sony_ec`가 이 모듈을 발행해 꺼질 때 사용자의 현재 밝기를 저장하고 켜질 때 정확히 그 값으로 복원합니다. 이때 일부러 `SBRT`로는 내보내지 않습니다 — 일시적인 전원 상태이지 사용자의 밝기 변경이 아니므로 EC가 아는 밝기 값은 그대로 둡니다. `vesa` 드라이버는 DPMS 전환마다 이 모듈을 best-effort로 조회하며, 아무도 발행하지 않는 기계에서는 `get_module()`이 실패할 뿐 동작이 기존과 완전히 같습니다. 실기 확인: 화면과 함께 백라이트가 꺼지고, 복귀 시 원래 밝기로 돌아옵니다.
- **오디오 녹음: 아무것도 캡처되지 않던 문제 (네 겹의 독립적 결함)** — `MediaRecorder.cpp`, `hda_codec.cpp`, `hda_multi_audio.cpp`, `driver.h`: SoundRecorder에서 녹음을 눌러도 아무 오류 없이 무음만 나왔습니다. 연결도 성공하고 하드웨어 스트림도 시작되는데 단 한 바이트도 도착하지 않았습니다. 서로 무관한 결함 네 개가 겹쳐 있었고, 각각만으로도 녹음을 망가뜨리기 충분했습니다:
  1. **`BMediaRecorder::Start()`가 프로듀서를 시작하지 않음** (Haiku 범용 버그, 모든 기기 해당). "타임소스인가"와 "데이터를 가져올 노드인가"를 배타적으로 취급합니다: `if (kind & B_TIME_SOURCE) StartTimeSource(...); else StartNode(...);`. 모든 multi_audio 장치 노드는 **둘 다**이므로 항상 첫 가지로 빠졌고, 노드가 `B_STOPPED`에 머물러 multi_audio가 캡처한 버퍼를 `RunState() != B_STARTED`라는 이유로 전부 폐기했습니다. 이제 타임소스도 시작하되 노드는 **항상** 시작합니다. 녹음이 되게 만든 핵심 수정이며, 5초당 버퍼 수가 0에서 약 118로 바뀌는 것으로 확인했습니다.
  2. **`Stop()`/`Disconnect()` 비대칭.** `Start()`는 프로듀서를 시작하는데 `Stop()`은 레코더 자신의 노드만 정지시켜 캡처 장치가 계속 돌았고, `Disconnect()`는 `Stop()` 실패 시 조기 반환했습니다 — 정리가 가장 필요한 경우에 정반대로 동작한 것입니다. 그 결과 프로듀서 출력이 점유된 채 남아, 미디어 서버를 재시작하기 전까지 어떤 앱도 녹음할 수 없었습니다.
  3. **캡처 포맷 모호성.** `set_global_format()`이 지원 레이트/포맷 **마스크**를 선택된 단일값으로 덮어써서, 이후 `get_description()`이 그 값 하나만 지원 목록으로 보고했고 어떤 선택도 무효가 됐습니다 (원본에 `#if 0`으로 죽어 있던 검증 코드가 참조하던 `supported_rates`/`supported_formats` 필드는 구현된 적이 없었고, 이번에 실제로 만들었습니다). 여기에 더해 코덱은 24비트 캡처를 광고하면서 32비트 컨테이너에 **우측정렬**로 담아 보내는데 multi_audio는 `B_FMT_24BIT`를 풀스케일 `B_AUDIO_INT`로 매핑하므로, 하위 전체가 오디오를 256배 작게 읽었습니다. 이제 캡처는 정렬 모호성이 없는 16비트만 광고하고 48kHz를 선호합니다 — ADC는 192kHz도 광고하지만 그 레이트에서는 버퍼를 하나도 보내지 않습니다.
  4. **입력 앰프가 0dB로 방치됨.** 드라이버가 캡처 앰프를 `AMP_CAP_OFFSET`(0dB)으로만 설정하고 일부는 뮤트 상태로 두었습니다. 내장 일렉트릿 마이크에서는 ADC가 노이즈 플로어만 보게 됩니다. 같은 음원 기준 실측: 0dB에서 -59 dBFS RMS(잡음), 수정 후 -25 dBFS RMS / -10 dBFS 피크로 클리핑까지 약 10dB 여유가 남습니다.

  아래 세 가지는 위 작업을 실기에서 검증하다 발견한 후속 수정이며, 모두 위
  작업이 만든 회귀입니다.

  5. **게인 부스트가 재생을 죽였습니다.** *모든* 위젯의 input amplifier에
     적용했는데, 핀 위젯의 input amplifier는 캡처 제어가 아니라 스피커로
     나가는 마지막 단입니다. 위젯 20/21/24가 마이크인 양 올라가면서 출력이
     완전히 끊겼습니다. 캡처 컨버터(`WT_AUDIO_INPUT`)로 한정했습니다.
  6. **재생이 192 kHz/24비트에 고정됐습니다.** 요청에 특정 레이트가 없을 때
     `hda_apply_format()`이 광고된 값 중 최댓값으로 떨어졌습니다. 믹서가 모든
     스트림을 4배 리샘플링하게 되고 이 CPU는 DMA 버퍼를 채우지 못했습니다 --
     3초에 141개여야 할 버퍼가 37개, 로그에는
     `Error waiting for playback buffer to finish`. 자초한 문제입니다. 순정
     드라이버는 애드온이 48 kHz를 요청하므로 그대로 48 kHz로 협상합니다.
     이제 폴백에서 베이스라인을 우선하되, 96 kHz를 명시적으로 요청하면
     96 kHz가 그대로 선택됩니다.
  7. **웹캠 노드가 죽으면서 오디오 믹서까지 끌고 갔습니다** (Haiku 공통 버그,
     `MediaEventLooper.cpp`). `BMediaNode::TimeSource()`는 미디어 서버에
     요청해 객체를 지연 생성하고, 실패하면 NULL을 반환합니다 -- 서버가
     내려가는 중이면서 컨트롤 루프는 아직 도는 상황이 정확히 그렇습니다.
     `ControlLoop()`의 역참조 세 곳에 가드가 없어 노드가 종료 중에 폴트를
     내고 `media_addon_server` 전체를 죽였습니다. 미디어 애드온은 모두 이
     프로세스를 공유하므로 믹서도 함께 죽어 소리가 사라졌습니다. 이제 실제
     클럭으로 폴백합니다.

  여기서 오래 쫓았던 증상 하나는 드라이버 문제가 아니었습니다. 이 머신은
  순수 사인파를 재생하면 버퍼 수가 정확하고 드라이버 측 언더런도 없는데
  틱틱거리는 소리가 납니다. 순정 드라이버에서도 동일하고 음악에서는 완전히
  마스킹됩니다 -- 즉 이 패치와 무관하게 원래 있던 재생 글리치이며, 로그의
  `DMA position ... broken, switching to LPIB`가 유력한 원인입니다.

  실기에서 처음부터 끝까지 검증했습니다: 내장 마이크로 48kHz/16비트 WAV를 캡처했고, 파형이 DC 오프셋 위에 얹혀 있지 않고 0을 중심으로 정상적으로 진동합니다.
- **cpuidle (x86_acpi_cstates) — 이 CPU에서는 비활성화, 드라이버 한계가 아니라 영구 실리콘 결함으로 확정** — `acpi_cpuidle.cpp`: 논리 CPU 2개짜리 기기에서 이 드라이버를 실제로 동작시키며 발견한 진짜 범용 버그 2건 — (1) ACPI processor 객체와 `cpu_ent`를 DSDT `Processor()` 객체의 ProcessorId만으로 매칭했고, MADT LAPIC ProcessorId와 값이 다를 때(이 개체의 HT 형제 스레드에서 실제로 발생하는 펌웨어 불일치) 대응할 폴백이 없었습니다 — 이제 매칭되지 않고 남은 것들은 발견 순서로 폴백 매칭합니다. (2) `acpi_cstate_idle()`의 인터럽트 수신 경로가, C-state를 아직 고르기 전에 인터럽트가 들어온 경우 할당되지 않은 `acpi_cstate_info*`를 그대로 역참조하는 실제 NULL 포인터 커널 패닉이 있었습니다 — 지금까지는 CPU1이 동작하는 ACPI cstate 장치를 가진 적이 없어서 이 경로를 탈 일이 없었을 뿐입니다. 이 두 수정 자체는 이 드라이버가 도는 다른 모든 CPU에 그대로 유효합니다. 하지만 **두 논리 CPU가 실제로 이 드라이버의 idle 경로를 함께 쓰게 되자, 이 특정 CPU(Atom Bonnell, Z520, model 0x1c stepping 2 / "C0")에서 실기 기준 완전한 하드행이 재현됐습니다** — 패닉도, 디버거 진입도, 키보드 입력도 없고 멈추는 지점이 매 부팅 달라지는 증상이었습니다. 여러 독립적인 완화책을 시도했지만(C2/C3를 state 테이블에서 아예 제거해서 순수 HALT뿐인 C1만 남기는 것까지) 전부 하드행이 재현됐습니다. 원인은 문서화된, 영구적인, 고칠 수 없는 문제였습니다: Intel의 [Atom Z5xx Series Specification Update](https://web.archive.org/web/2020/https://www.intel.com/content/dam/www/public/us/en/documents/specification-updates/atom-z5xx-specification-update.pdf)(errata 문서 319536, 이 CPU의 processor signature `000106C2h`가 정확히 스테핑 **C0**과 일치)에 이 유일한 스테핑에 대해 **Status: No Fix**인 errata가 3개 등재돼있습니다: **AAE31**(코어의 두 논리 프로세서가 HLT 또는 MWAIT로 동시에 비활성 상태가 되면 명령어 캐시가 스누프에 응답을 멈춤), **AAE34**(Enhanced SpeedStep P-state 전환이 대기 중일 때 비활성 상태에서 못 깨어날 수 있고 하드 리셋이 필요함 — 이 기기의 `intel_est` cpufreq 드라이버가 cpuidle과 동시에 활성 상태라서 직접 해당), **AAE2**(C2 이상에서 xTPR 업데이트 트랜잭션으로 인한 시스템 행업). `acpi_cpuidle_init()`이 이제 ACPI `_CST`를 건드리기도 전에 이 정확한 CPU 모델을 아예 거부합니다; idle은 여전히 커널의 범용 `arch_cpu_idle()` 경로(`halt_idle()`)로 순수 HALT를 쓰고 있고, 다만 이 드라이버의 MWAIT/C-state 경로를 거치지 않을 뿐입니다.
- **cpufreq (intel_est, 신규)** — `power/cpufreq/intel_est/`: 신규 MIT 라이선스 EST(Enhanced SpeedStep) 드라이버입니다. 기존 `intel_pstates`는 HWP(Skylake 이후)만 지원해서, 이 1세대 Atom(Bonnell)은 CPUID에 `IA32_FEATURE_EST`를 광고하고도 거부당해 항상 단일 주파수에 고정되어 있었습니다. `intel_est`는 대신 ACPI `_PSS`/`_PCT`에서 P-state 테이블을 읽습니다. 이 기기에서 실제로 동작하게 만든 핵심 2가지: (1) `_PSS`/`_PCT`가 정적 DSDT에 아예 없습니다 — 위의 `_CST`처럼, BIOS가 `_OSC` 평가의 부수효과로만 트리거되는 AML `Load()`로 OEM SSDT를 주입하므로, `intel_est`도 `_PSS`/`_PCT`를 확인하기 전에 ACPI processor 노드에서 `_OSC`(실패 시 폐기된 `_PDC`로 폴백)를 먼저 평가합니다. (2) `_PCT`의 control register 주소 공간이 이 기기에서는 **부팅마다 달라집니다** — 어떤 때는 `FixedHW`(MSR인 `IA32_PERF_CTL`, 0x199에 직접 씀), 어떤 때는 `SystemMemory`(MSR이 아니라 칩셋 MMIO 레지스터)입니다. 드라이버가 이제 둘 다 지원하며, 후자인 경우 `map_physical_memory()`로 물리 레지스터를 매핑합니다. P-state를 쓰기 전에 `IA32_MISC_ENABLE`의 bit 16(EST 활성화 게이트)도 무조건 확인/설정합니다 — 펌웨어가 모든 부팅 경로에서 이걸 항상 켜두는 건 아니기 때문입니다.
- **설치기** — `WorkerThread.cpp`/`.h`: 설치 후 대상 파티션을 실제로 active로 표시하고 MBR 부트코드를 기록해서, 수동으로 `writembr`를 하지 않아도 설치 직후 바로 부팅 가능하게 함. 디스크 디바이스 매니저는 마운트된 상태의 파티션에는 파티션 테이블 변경(active 플래그 포함)을 커밋해주지 않으므로, 이 시점부터는 더 이상 마운트가 필요 없다는 걸 확인하고 대상을 먼저 마운트 해제합니다. active 표시가 실제로 성공했을 때만 MBR을 덮어씁니다 — active 파티션이 하나도 없는 상태에서 범용 MBR 코드만 새로 쓰면 디스크가 완전히 부팅 불가능해지므로(부트로더가 전혀 실행되지 않아 부팅 옵션 메뉴조차 뜨지 않음), 실패 시에는 디스크에 원래 있던 부팅 설정을 그대로 두고 건드리지 않습니다. 두 단계 모두 이후 `sync()`를 호출합니다(MBR 쓰기는 디스크 디바이스 매니저를 완전히 우회하는 외부 `writembr` 프로세스로 이루어지기 때문).
- **launch_daemon** — `Job.cpp`: `launch_daemon`이 아직 앱을 등록하지 못한 시점이면 즉시 실패하지 않고 한동안 재시도(느린 저장장치에서 중요).

## 두 번째 논리 CPU (미해결이며, 고칠 필요도 없음)

Atom Z520은 HT를 지원하는 단일 코어라 두 번째 논리 CPU가 존재해야 하고, 펌웨어와 실리콘 모두 존재한다고 답합니다: ACPI MADT에 Local APIC 항목이 두 개 있고 둘 다 `ENABLED` 플래그가 서 있으며, 실기에서 읽은 `CPUID.1`은 `EBX[23:16] = 2`(논리 프로세서 2개), `CPUID.4`는 코어 1개를 보고합니다. 그런데도 AP는 기동하지 않습니다. 이건 추론이 아니라 측정한 결과입니다:

- 부트로더의 IPI 전송은 전부 성공합니다 — APIC delivery-status 폴링이 한 번도 타임아웃하지 않아 `timeout sending INIT IPI` / `STARTUP IPI` 메시지가 아예 출력되지 않습니다.
- 트램폴린 코드는 정상 배치돼 있습니다: 동작 중인 기기에서 `/dev/misc/mem`으로 물리주소 `0x9F000`을 되읽으면 예상대로 `cli; mov $0x9e00,%ax; mov %ax,%ds; lgdt 0x9e000; ...`가 나오고 `ljmp` 타깃도 올바릅니다.
- 트램폴린이 자기 스크래치 페이지에 진행 마커(리얼 모드 / 보호 모드 / `CR3` 적재 후 / 페이징 직전)를 기록하고 커널이 그 값을 출력하도록 만든 진단 빌드에서는 **마커 4개가 모두 0**으로 나왔습니다 — AP가 트램폴린의 첫 명령어조차 실행하지 않습니다.

즉 AP는 올바르게 지정되고, 유효한 코드를 받고, IPI도 전달되는데, 받는 쪽에서 아무것도 실행되지 않습니다. 원인은 OS가 닿을 수 있는 층위 아래(펌웨어 또는 실리콘)에 있으며 끝내 규명하지 못했습니다. 다른 개체에서 같은 현상이 나타난다는 독립적인 확인도 찾지 못했으므로, 위 내용은 이 기종 전반의 특성이 아니라 이 개체 한 대에서의 측정 결과로 받아들여야 합니다.

**AAE31**은 과대 해석하기 쉬우니 주의가 필요합니다. 이 정오표는 실재하며 이 스테핑에 해당하는 것도 맞지만, 그렇다고 2스레드 구성 자체가 못 쓸 물건이 되는 건 아닙니다 — 이 기기는 원래 Windows에서 두 스레드를 모두 쓰며 출하됐고 Linux에서도 두 스레드로 동작합니다. Intel 문서 자체도 BIOS 레벨 워크어라운드가 가능하다고 적고 있습니다. AAE31은 이 CPU에서 **cpuidle의 C-state 경로**를 포기한 근거(거기서는 재현 가능하게 치명적이었음)로만 취급해야지, HT 자체가 위험하다는 증거로 읽으면 안 됩니다.

## 파일 구성

| 파일 | 설명 |
|---|---|
| `vaio-p-patches.diff` | 위에 설명한 VAIO P 패치를 모두 담은 unified diff입니다. `git diff`로 생성됩니다. |
| `build-vaio-p-iso.sh` | **Linux**에서 실행합니다. Haiku/buildtools 클론, 패치 적용, 크로스툴체인 빌드, `jam -q @nightly-anyboot` 실행까지 전 과정을 자동화합니다. |
| `docker-build-vaio-p-iso.sh` | **macOS**에서 실행하는 래퍼입니다. case-sensitive 디스크 이미지와 Docker 컨테이너(`ubuntu:22.04`, Rosetta 가속)를 준비한 뒤 그 안에서 `build-vaio-p-iso.sh`를 실행합니다. |
| `LICENSE` | 이 패치들이 추가한 신규 코드(특히 `sony_ec`, `intel_est` 드라이버)에 적용되는 MIT 라이선스입니다. |

레거시 `x86_gcc2` 크로스컴파일러는 `-m32` 호스트 지원이 필요한데, 최신 macOS SDK는 i386 링크를 완전히 제거했기 때문에 macOS에서는 직접 빌드할 수 없습니다. 그래서 macOS에서는 반드시 `docker-build-vaio-p-iso.sh`를 통해 Linux 컨테이너 안에서 빌드해야 합니다.

## 사용법

### macOS

```sh
cd tools/vaio-p
./docker-build-vaio-p-iso.sh ~/haiku-vaio-p.iso
```

Docker Desktop 설정에서 **Use Virtualization Framework**와 **Use Rosetta for x86/amd64 emulation**을 켜두어야 QEMU 완전 에뮬레이션이 아닌 Rosetta 가속으로 빌드되어 훨씬 빠릅니다 (몇 시간 -> 1~2시간 수준).

### Linux

```sh
cd tools/vaio-p
./build-vaio-p-iso.sh ~/vaio-p-work ~/haiku-vaio-p.iso
```

### 환경 변수

- `SKIP_CROSS_TOOLS=1` : 크로스컴파일러가 이미 빌드되어 있으면 재빌드를 생략합니다 (패치만 수정하고 다시 빌드할 때 유용하며, 크로스툴 빌드에만 1~1.5시간이 소요됩니다).
- `HAIKU_GIT_REF` : 체크아웃할 haiku.git의 브랜치/태그/커밋입니다. 기본값은 현재 체크아웃 상태를 유지합니다 (새로 클론 시 `master`).
- `JOBS` : `configure`/`jam` 병렬 작업 수입니다. 기본값은 `nproc`입니다.

### `configure --distro-compatibility official`을 주는 이유

이 옵션이 없으면 `HAIKU_DISTRO_COMPATIBILITY`가 `default`가 되고, `headers/private/kernel/boot/images.h`가 상표 없는 스플래시 세트인 `images-sans-tm.h`를 포함합니다. 그런데 이 파일의 372x96 로고 이미지는 **빈 이미지**입니다. 부트 아이콘은 같은 헤더에서 오지만 실제 이미지라서, 증상은 "아이콘 줄만 나오고 그 위 Haiku 로고가 없는 부팅 화면"으로 나타납니다. `official`을 주면 업스트림 나이틀리가 쓰는 `images-tm-development.h`가 선택됩니다. 이 define을 참조하는 나머지 코드는 About, Deskbar 잎 메뉴, Installer, 첫 부팅 프롬프트뿐이며 전부 외형에만 영향을 줍니다.

## 패치가 적용되지 않을 때

빌드 스크립트가 이미 3-way 병합으로 재시도하므로, 여기까지 오는 건 진짜 충돌일 때뿐입니다. 체크아웃에서 `git apply -3 tools/vaio-p/vaio-p-patches.diff`를 실행해 충돌 표시를 확인한 뒤 각각을 살펴보세요. "패치 기준 시점"에 나열한 범용 정합성 버그처럼 이미 공식 소스에 같은 수정이 들어가 있다면(이미 세 건이 그렇게 됐습니다) 업스트림 쪽을 남기고 해당 hunk를 버리면 되고, 아니면 다시 작성하세요. 이후 `git diff HEAD --binary`로 diff 전체를 재생성합니다 — Intel 마이크로코드 바이너리가 들어 있으므로 `--binary`가 필요합니다.

## 재설치 없이 수정 적용하기

커널 드라이버와 미디어 애드온은 동작 방식이 다릅니다. 여기서 틀리면 장치가 죽거나 재설치를 하게 됩니다.

**커널 드라이버**는 이름으로 대체됩니다. 빌드한 드라이버를 `~/config/non-packaged/add-ons/kernel/drivers/bin/`에 넣으면 다음 부팅부터 패키지 사본을 가립니다.

**미디어 애드온은 그렇지 않습니다.** `non-packaged/add-ons/media`에 넣으면 패키지 사본과 **둘 다** 로드되고, 같은 장치를 두고 경쟁해 결국 어느 쪽도 동작하지 않습니다. 교체하려면 `/boot/system/settings/packages`에 차단 목록을 만들어 패키지 파일을 먼저 가려야 합니다.

```
Package haiku {
	BlockedEntries {
		add-ons/media/usb_webcam.media_addon
	}
}
```

그 다음 빌드한 애드온을 `/boot/system/non-packaged/add-ons/media/`에 넣고 재부팅합니다. `ls /boot/system/add-ons/media/`에서 해당 파일이 사라졌으면 적용된 것입니다.

실패처럼 보이지만 아닌 경우가 하나 있습니다. 기본 비디오 노드가 지정되지 않으면 카메라가 이미 열거되어 프레임을 내보내고 있어도 `BMediaRoster::GetVideoInput()`은 `B_NAME_NOT_FOUND`를 반환합니다. 이 기본값을 자동으로 지정해 주는 것은 없습니다. 애드온이 로드되지 않았다고 단정하기 전에 syslog에서 `usb_webcam deframer` 줄을 확인하세요.

## 빌드 후 확인

빌드 자체는 소스 검증일 뿐이며, 실제 검증은 실기기에서만 가능합니다: USB로 ACPI를 켜고 Safe Mode 없이 부팅 -> 내장 디스크에 설치 (DriveSetup으로 Intel 파티션 맵 + BFS 파티션을 먼저 만든 뒤 설치) -> 재부팅까지 확인해야 합니다.

## AI 기여 고지

이 패치는 Claude와 함께 작업해 만들었습니다. 작업은 실제 기기에서 얻은 측정값 — syslog, KDL 세션, 디스어셈블한 DSDT, PCI 설정공간과 물리 메모리 직접 읽기, 제조사 정오표 문서 — 을 근거로 진행했고, 여기 적힌 모든 수정은 문서화 전에 실기에서 검증했습니다. 초안의 여러 결론은 틀렸고 측정 결과가 그것을 반박했기 때문에 바로잡혔습니다. 아직 규명하지 못한 것들은 덮지 않고 미해결로 표시해 두었습니다.

**Haiku 프로젝트는 AI가 개입한 기여를 받지 않으며, 이 내용은 업스트림에 제출된 적이 없고 제출해서도 안 됩니다.** 이것은 기기 한 대를 위한 개인 패치 묶음이고, 수정 대상 코드와 동일한 MIT 조건으로 그 취지에 맞게 공개합니다. 일부를 재사용하신다면 이 고지도 함께 옮겨주시기 바랍니다.


