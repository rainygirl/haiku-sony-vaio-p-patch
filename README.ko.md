# Sony VAIO P Haiku OS 패치 스크립트

English version: [`README.md`](README.md).

이 폴더는 Sony VAIO P (VGN-P70H)에서 Haiku OS가 ACPI를 켜고 Safe Mode 없이 정상 부팅/설치/동작하도록 만든 패치를 새 Haiku OS 소스에 적용하고 ISO로 빌드하는 스크립트를 담고 있습니다.

## 패치 기준 시점

이 패치들은 **2026년 7월 21일** 기준 Haiku OS 소스를 기준으로 작성되었습니다. 일부 버그(ACPICA Global Lock 초기화 순서 문제, ACPI IRQ 트리거/극성, PCI 미정렬 config 접근, PS/2 멀티플렉서 포트 프로브 타임아웃, USBKit `SetAlternate()` 버그, UHCI halt 복구 미구현, EHCI isochronous 버그 일체, UVC frame index 버그, SMP AP 기동 재시도 등)는 VAIO P 전용이 아닌 범용 정합성 버그라서, 새 체크아웃을 받을 시점에는 이미 공식 소스에서 고쳐져 있을 수 있습니다. 패치가 적용되지 않으면 먼저 이미 수정됐는지 확인한 뒤 다시 작성해 주세요.

## 무엇을 고치는가

`vaio-p-patches.diff`는 아래 내용을 모두 담은 하나의 누적 diff입니다:

- **USB 안정성/부팅 속도** — `Hub.cpp`/`usb_private.h`/`BusManager.cpp`: 포트마다 무한 재시도 대신 재시도 -> 비활성화 -> 파워사이클 순으로 단계적으로 포기하는 백오프, `SET_ADDRESS` 재시도를 낭비하지 않도록 주소 0에서 `GET_DESCRIPTOR`로 먼저 응답 여부를 확인하는 프로브, Poulsbo 칩셋의 EHCI/UHCI BAR0 픽스업. 재시도/파워사이클 백오프를 모두 소진한 포트는 그 부팅 동안 영구히 건드리지 않습니다(매 물리적 재연결마다 다시 살리지 않음) — 원래는 이 개체의 죽은 내장 Bluetooth 모듈용으로 작성됐지만(아래 "Bluetooth" 참고), 범용으로도 유효했습니다: 이 칩셋의 UHCI 컴패니언 컨트롤러가 아무것도 연결되지 않은 내부 포트에서 매 부팅마다 가짜 "new device connected"를 보고하는데, 이제 그때마다 halt/복구 사이클을 반복하지 않습니다.
- **조기 EHCI BIOS 핸드오프 (Poulsbo)** — `pci_fixup.cpp`: 이 기기의 BIOS는 표준 EHCI 레거시 핸드오프에 끝내 응하지 않고("bios won't give up control"이 매 부팅 기록됨), EHCI 드라이버 자체의 강제 탈취는 너무 늦게 실행됩니다: PCI 펑션 번호가 낮은 컴패니언 UHCI 컨트롤러들이 먼저 초기화되어 장치 열거를 시작하는 동안 BIOS는 여전히 자기가 USB를 소유한다고 믿고 SMM으로 개입합니다 — UHCI "host process error" halt가 복구 포기까지 반복되던 원인이 이것이었습니다. 기존 Poulsbo BAR0 픽스업이 이제 PCI 스캔 시점(모든 USB 드라이버 실행 전)에 레거시 핸드오프 전체(정중한 요청 → BIOS 세마포어 강제 클리어 + SMI 차단)를 함께 수행합니다. 이 수정으로 UHCI halt 소용돌이가 사라지고, 남은 halt도 첫 시도에 깨끗하게 복구됩니다.
- **UHCI 컨트롤러 halt 복구** — `uhci.cpp`/`.h`: 일부 하드웨어에서는 오작동하는 장치와 통신하다 컨트롤러 자체가 halt(`process error` → `host controller halted`)되는데, 기존 드라이버는 이때 인터럽트만 끄고 그 컨트롤러(와 거기 물린 모든 장치)를 부팅 내내 영구히 죽은 상태로 방치했습니다 — 소스에 `// ToDo: cancel all transfers and reset the host controller`라고 그대로 적혀 있었습니다. 이제는 진행 중이던 전송을 실제로 취소(소프트웨어 기록뿐 아니라 스케줄에서도 unlink — 이 unlink를 빠뜨린 첫 시도는 즉시 재halt가 반복되며 CPU를 잡아먹는 버그를 냈습니다)하고, 컨트롤러를 리셋한 뒤 스케줄을 재시작합니다. 그래도 halt가 계속 반복되면(스케줄 재시작 자체가 다시 halt를 유발하는, 장치 활동과 무관한 하드웨어 결함으로 보이는 경우) 2초 내 몇 차례 시도 후 포기하도록 상한을 뒀습니다(무한 루프 방지).
- **PS/2 멀티플렉서** — `ps2_common.cpp`: 아무것도 연결되지 않은 멀티플렉스 서브포트(1~3)에 대해 매직시퀀스 전체를 시도하고 타임아웃까지 기다리는 대신, 실제로 응답이 있는 포트만 프로브합니다.
- **WiFi (Atheros AR928X)** — `if_ath.c`/`if_athvar.h`: beacon-miss/bb-hang 복구가 반복되면 어댑터를 PCI 파워사이클(D3->D0)까지 강제합니다. `ieee80211_scan_sta.c`: 실제 접속 요청이 있기 전까지 `net80211`이 열린 AP에 마음대로 자동 접속하지 못하게 막습니다(원래는 STA 모드의 기본 후보 스캔이 부팅 시 가장 가까운 열린 이웃 AP를 붙잡았습니다). `AutoconfigLooper.cpp`/`.h`: 자동 접속을 한 번만 시도하지 않고 유예 시간을 두고 재시도하며, 의도치 않은 오픈 네트워크 연결을 "완료"로 취급하지 않습니다.
- **Sony EC 드라이버 (신규)** — `drivers/power/sony_ec/`: Sony `SNY5001` ACPI 장치(SNC)용 신규 MIT 라이선스 드라이버로, 밝기 조회/설정, 핫키 arm, 무선 스위치/Fn키 notify 이벤트를 처리합니다. 무선 킬스위치를 토글할 때마다 WLAN 라디오 전원(SNC `F124` sub-function 4)과 Bluetooth 모듈 전원(sub-function 6)을 함께 요청합니다 — 둘 다 이 모델의 DSDT를 직접 디스어셈블해 알아낸 프로토콜이며, EC가 알아서 해주지 않는 일입니다. 덕분에 스위치를 껐다 켜도 WiFi가 죽지 않고 살아나며, Bluetooth 모듈의 로직 전원도 켜집니다(sub-function 5 readback으로 `BTPW` 반영을 확인했고, 모듈의 USB 존재 신호가 전원을 정확히 따라 움직이는 것도 실측 확인). 킬스위치 토글과 별개로, 부팅 후 ~10초 뒤 한 번 무조건 Bluetooth 전원을 요청합니다(스위치를 아예 안 건드리는 개체도 있으므로). (스위치 옆 표시 LED는 이 개체에서는 소프트웨어로 제어되지 않습니다: `WLSL` 비트 쓰기/재독은 정상 동작하지만 실제 LED에는 반영되지 않음.) Linux `sony-laptop.c`를 그대로 가져온 게 아니라 처음부터 새로 작성했습니다(자세한 내용은 드라이버 코드 내 주석 참고).
- **Bluetooth (하드웨어 판정)** — 이 개체는 Bluetooth가 하드웨어 자체 결함이며, 증상만이 아니라 완전한 소거 사슬로 확인했습니다: 조기 EHCI BIOS 핸드오프 수정(아래)으로 BIOS-SMM 간섭과 UHCI halt 소용돌이를 제거했고(컨트롤러가 건강함을 입증), `sony_ec` 드라이버의 Bluetooth 전원 요청도 실제로 동작하며(EC의 `BTPW` 비트가 readback으로 확인되고, 모듈의 USB 존재 신호가 전원 on/off를 그대로 따라감), 로직 전원이 켜진 것이 확인된 상태에서도 모듈은 주소 0의 `GET_DESCRIPTOR`에 단 한 번도 응답하지 않았습니다. 소프트웨어로 제어 가능한 모든 계층이 정상으로 검증됐으므로 — 모듈 자체가 응답하지 않는 것입니다. 모듈이 정상인 VAIO P라면 이 패치들만으로 Bluetooth가 열거될 것으로 기대됩니다(부팅 후 무선 스위치를 한 번 껐다 켜거나, ~10초 기다려서 모듈 전원을 올려 주세요).
- **EHCI isochronous 수정 (커널, 범용)** — `ehci.cpp`/`.h`: 사실상 아무도 쓰지 않아 잠자고 있던 isochronous 경로의 실제 버그 4개: (1) iTD의 12비트 TLENGTH 필드를 넘는 패킷 길이가 인접 상태 비트를 침범해 제출 시점부터 디스크립터를 손상시킴(하이밴드위드 엔드포인트의 `wMaxPacketSize`는 4095바이트를 쉽게 넘으므로 USB2 카메라가 바로 걸림); (2) `fNextStartingFrame` 체이닝의 off-by-one으로 제출 사이마다 1프레임(1ms)의 스케줄 공백이 보장되어 isochronous IN 장치가 그 사이에 보낸 데이터가 조용히 유실됨; (3) 멀티 iTD 전송 완료 시 모든 iTD를 해제하면서 마지막 것만 프레임 체인에서 unlink해서, 나머지 프레임 슬롯이 해제된 메모리를 가리키게 됨(실제 use-after-free 커널 패닉 발생); (4) 시작 프레임 결정과 예약이 원자적이지 않아 동시 제출 두 건이 같은 프레임 슬롯에 겹칠 수 있는 레이스.
- **usb_raw + USBKit: 중첩 isochronous 전송** — `usb_raw.cpp`/`.h`, `USBEndpoint.cpp`, `USBKit.h`: 기존의 블로킹 isochronous ioctl을 논블로킹 제출 + 별도 대기로 분리한 신규 `B_USB_RAW_COMMAND_QUEUE_ISOCHRONOUS`/`WAIT_ISOCHRONOUS` ioctl(그리고 대응하는 `BUSBEndpoint::QueueIsochronous()`/`WaitIsochronous()` 공개 API)을 추가했습니다. 요청별 완료 상태를 분리해 전송 2개를 동시에 진행할 수 있습니다. 이게 없으면 모든 캡처 루프가 전송 완료와 다음 제출 사이에 스케줄 공백을 필연적으로 만들고, isochronous IN 장치는 그 공백에도 계속 전송하므로 매 호출마다 데이터가 유실됩니다. 기존 블로킹 ioctl은 그대로 유지됩니다.
- **USBKit `SetAlternate()` 버그** — `USBInterface.cpp`: `BUSBInterface::SetAlternate()`가 실제 장치의 alternate setting은 정상적으로 전환시키면서도 자기 자신의 `fAlternate` 멤버는 갱신하지 않아서, 그 직후 같은 객체에서 `EndpointAt()`을 호출하면 방금 선택한 alternate가 아니라 객체 생성 당시의 alternate(보통 대역폭 0인 유휴 상태)의 엔드포인트를 계속 돌려줬습니다. 실질적으로 USB 웹캠이 isochronous 데이터를 전혀 받지 못했던 첫 번째 원인입니다.
- **웹캠 (UVC)** — `UVCCamDevice.cpp`/`.h`, `UVCDeframer.cpp`/`.h`, `CamDevice.cpp`/`.h`: 최대 원인은 `AcceptVideoFrame()`이 선택한 해상도의 *목록 위치*(0부터)를 저장해놓고 그걸 카메라에 UVC *frame index*(1부터)로 보낸 버그였습니다 — 320x240을 골랐는데 실제로는 카메라에 640x480이 커밋되어, 호스트가 614400바이트 프레임을 153600바이트 320x240으로 잘라 디코드하면서 빗살무늬("인터레이스처럼 보임"), 세로 늘어남, 끝없는 세로 스크롤이 생겼고, 캡처 경로를 아무리 고쳐도 사라지지 않았습니다. 그 위에 얹힌 수정들: YUY2 디코딩(이 카메라는 Bayer가 아니라 YUY2) + 디코더 양쪽에 하드 바운드 클램프(짧은 프레임이 버퍼 밖을 읽고 써서 실제 세그폴트/커널 패닉 발생했음); 하이밴드위드 `wMaxPacketSize` 디코딩(단순 바이트 수가 아니라 기본크기 x microframe당 전송수); 고정 stride 패킷 버퍼 워킹(DMA 버퍼는 `actual_length`가 아니라 `maxPacketSize` 간격으로 배치됨); 신규 Queue/Wait API + 별도 소비 스레드를 쓰는 더블 버퍼 캡처(항상 전송 1개가 컨트롤러에 걸려 있도록); 정확한 바이트 카운트로 프레임을 내보내되 카메라 FID 토글에서 위상을 재고정하고 손실 프레임은 밀린 채 표시하는 대신 조용히 버리는 하이브리드 디프레이밍; 최신 프레임만 표시하는 큐 드레인(지연 감소); 드롭된 프레임에서 검은 화면 대신 직전 프레임 유지; `StopTransfer()`가 스트리밍 인터페이스를 내리기 *전에* 진행 중 전송을 먼저 비우도록 순서 수정(기존엔 실제 "USB object did not become idle" 패닉 발생).
- **CodyCam** — `VideoConsumer.cpp`/`.h`: 표시 쪽 수정 2건: 비트맵을 뷰 모양에 강제로 늘리는 대신 화면비를 유지하며 레터박스/필러박스로 그리고, 프로듀서 소유 버퍼일 때 슬롯 0 하나만 쓰지 않고 비트맵 3개를 순환합니다 — 기존 코드는 뷰가 아직 그리는 중인 비트맵 하나를 매 프레임 덮어써서 실제 티어링 레이스가 있었습니다.
- **부팅 화면** — `video.cpp`: 이 하드웨어의 VESA BIOS는 DDC/EDID를 아예 지원하지 않아 네이티브 해상도(1600x768)를 자동 감지할 방법이 없습니다. VESA 모드 목록에 해당 해상도가 있으면 부트로더가 직접 골라 씁니다.
- **부팅 속도/견고성 (범용)** — `smp.cpp`: 이 개체의 두 번째 논리 CPU(HT 형제 스레드)가 느린 게 아니라 아예 기동에 실패하는 경우가 있었습니다 — `smp_boot_other_cpus()`가 이제 AP마다 INIT/SIPI/SIPI 전체 시퀀스(트램폴린 스택 재설정 포함)를 최대 3회까지 재시도한 뒤에야 포기합니다(기존엔 한 번 시도하고 넘어갔음). `evglock.c`: 핸들러 설치 도중 Global Lock SCI가 동기적으로 발생할 때 필요한 락이 아직 없어서 터지는 ACPICA 레이스를 수정. `pci.cpp`: 정렬 안 된 32비트 config 공간 접근을 그냥 거부하지 않고 16비트 접근 두 번으로 쪼갬. `acpi_irq_routing_table.cpp`: 잘못됐을 수 있는 ACPI 서술자를 그대로 믿는 대신 IRQ 극성/트리거 모드를 고정값으로 보정. `vfs_boot.cpp`: 열거가 느린 USB 부팅 매체에 대해 즉시 패닉하지 않고 부팅 파티션 탐색을 재시도.
- **마이크로코드** — `data/system/data/firmware/intel-ucode/06-1c-02`(신규, Intel 공식 마이크로코드 저장소에서 받음) + `build/jam/images/definitions/regular`의 이미지 규칙: 이 Atom Z520(family 06, model 1c, stepping 02)은 마이크로코드 업데이트가 전혀 배포되지 않아 BIOS가 남긴 리비전 그대로 돌고 있었습니다. 이제 이미지에 해당 파일을 포함하고 `ucode_load`가 부팅 시 이를 적용합니다.
- **harfbuzz 패키징** — `build/jam/DefaultBuildProfiles`: nightly 빌드 프로필에 `harfbuzz`가 아예 빠져 있어서, harfbuzz에 링크된 gcc2용 `libfreetype`이 매 부팅마다 `Cannot open file libharfbuzz.so.0`를 기록했습니다. 이 빌드가 실제로 쓰는 non-gcc2 primary 아키텍처에 대해서는 수정했지만, 저장소에 gcc2 primary 아키텍처용 `harfbuzz` 패키지 자체가 없어서(secondary_x86용만 존재) gcc2 하이브리드 빌드에서는 이 경고를 완전히 없앨 수 없습니다 — 기능에는 영향 없는 경고입니다(harfbuzz 기반 셰이핑은 FreeType의 선택 기능일 뿐).
- **cpuidle (x86_acpi_cstates)** — `acpi_cpuidle.cpp`: 논리 CPU 2개짜리 기기에서 이 드라이버를 실제로 동작시키며 발견한 진짜 범용 버그 2건 — (1) ACPI processor 객체와 `cpu_ent`를 DSDT `Processor()` 객체의 ProcessorId만으로 매칭했고, MADT LAPIC ProcessorId와 값이 다를 때(이 개체의 HT 형제 스레드에서 실제로 발생하는 펌웨어 불일치) 대응할 폴백이 없었습니다 — 이제 매칭되지 않고 남은 것들은 발견 순서로 폴백 매칭합니다. (2) `acpi_cstate_idle()`의 인터럽트 수신 경로가, C-state를 아직 고르기 전에 인터럽트가 들어온 경우 할당되지 않은 `acpi_cstate_info*`를 그대로 역참조하는 실제 NULL 포인터 커널 패닉이 있었습니다 — 지금까지는 CPU1이 동작하는 ACPI cstate 장치를 가진 적이 없어서 이 경로를 탈 일이 없었을 뿐입니다. **하지만 두 논리 CPU가 실제로 이 드라이버의 idle 경로를 함께 쓰게 되자, 이 특정 CPU(Atom Bonnell, model 0x1c)에서 실기 기준 완전한 하드행이 재현됐습니다** — 패닉도, 디버거 진입도, 키보드 입력도 없고 멈추는 지점이 매 부팅 달라지는, 이 드라이버 아래쪽(ACPICA 또는 칩셋 자체)의 진짜 SMP 데드락으로 보이는 증상이었고, 해당 기기에서 작동하는 커널 디버거 진입 경로가 없어 더 이상 안전하게 원인을 추적할 수 없었습니다. `acpi_cstate_quirks()`가 이제 이 정확한 CPU 모델을 아예 거부합니다; 위 두 버그 수정 자체는 이 드라이버가 도는 다른 모든 CPU에 그대로 유효합니다.
- **cpufreq (intel_est, 신규)** — `power/cpufreq/intel_est/`: 신규 MIT 라이선스 EST(Enhanced SpeedStep) 드라이버입니다. 기존 `intel_pstates`는 HWP(Skylake 이후)만 지원해서, 이 1세대 Atom(Bonnell)은 CPUID에 `IA32_FEATURE_EST`를 광고하고도 거부당해 항상 단일 주파수에 고정되어 있었습니다. `intel_est`는 대신 ACPI `_PSS`/`_PCT`에서 P-state 테이블을 읽습니다. 이 기기에서 실제로 동작하게 만든 핵심 2가지: (1) `_PSS`/`_PCT`가 정적 DSDT에 아예 없습니다 — 위의 `_CST`처럼, BIOS가 `_OSC` 평가의 부수효과로만 트리거되는 AML `Load()`로 OEM SSDT를 주입하므로, `intel_est`도 `_PSS`/`_PCT`를 확인하기 전에 ACPI processor 노드에서 `_OSC`(실패 시 폐기된 `_PDC`로 폴백)를 먼저 평가합니다. (2) `_PCT`의 control register 주소 공간이 이 기기에서는 **부팅마다 달라집니다** — 어떤 때는 `FixedHW`(MSR인 `IA32_PERF_CTL`, 0x199에 직접 씀), 어떤 때는 `SystemMemory`(MSR이 아니라 칩셋 MMIO 레지스터)입니다. 드라이버가 이제 둘 다 지원하며, 후자인 경우 `map_physical_memory()`로 물리 레지스터를 매핑합니다. P-state를 쓰기 전에 `IA32_MISC_ENABLE`의 bit 16(EST 활성화 게이트)도 무조건 확인/설정합니다 — 펌웨어가 모든 부팅 경로에서 이걸 항상 켜두는 건 아니기 때문입니다.
- **설치기** — `WorkerThread.cpp`/`.h`: 설치 후 대상 파티션을 실제로 active로 표시하고 MBR 부트코드를 기록해서, 수동으로 `writembr`를 하지 않아도 설치 직후 바로 부팅 가능하게 함. 디스크 디바이스 매니저는 마운트된 상태의 파티션에는 파티션 테이블 변경(active 플래그 포함)을 커밋해주지 않으므로, 이 시점부터는 더 이상 마운트가 필요 없다는 걸 확인하고 대상을 먼저 마운트 해제합니다. active 표시가 실제로 성공했을 때만 MBR을 덮어씁니다 — active 파티션이 하나도 없는 상태에서 범용 MBR 코드만 새로 쓰면 디스크가 완전히 부팅 불가능해지므로(부트로더가 전혀 실행되지 않아 부팅 옵션 메뉴조차 뜨지 않음), 실패 시에는 디스크에 원래 있던 부팅 설정을 그대로 두고 건드리지 않습니다.
- **launch_daemon** — `Job.cpp`: `launch_daemon`이 아직 앱을 등록하지 못한 시점이면 즉시 실패하지 않고 한동안 재시도(느린 저장장치에서 중요).

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

## 패치가 적용되지 않을 때

`git apply --check tools/vaio-p/vaio-p-patches.diff`로 정확히 어느 hunk가 실패했는지 확인한 뒤 해당 위치의 코드를 살펴보세요. "패치 기준 시점"에 나열한 범용 정합성 버그처럼 이미 공식 소스에 같은 수정이 들어가 있다면 그 hunk는 건너뛰면 되고, 주변 코드만 약간 밀린 경우라면 패치 전체를 다시 생성하지 말고 해당 파일 하나만 수동으로 다시 반영한 뒤 `git diff`로 그 hunk만 재생성하세요.

## 빌드 후 확인

빌드 자체는 소스 검증일 뿐이며, 실제 검증은 실기기에서만 가능합니다: USB로 ACPI를 켜고 Safe Mode 없이 부팅 -> 내장 디스크에 설치 (DriveSetup으로 Intel 파티션 맵 + BFS 파티션을 먼저 만든 뒤 설치) -> 재부팅까지 확인해야 합니다.
