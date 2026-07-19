# Sony VAIO P Haiku OS 패치 스크립트

English version: [`README.md`](README.md).

이 폴더는 Sony VAIO P (VGN-P70H)에서 Haiku OS가 ACPI를 켜고 Safe Mode 없이 정상 부팅/설치/동작하도록 만든 패치를 새 Haiku OS 소스에 적용하고 ISO로 빌드하는 스크립트를 담고 있습니다.

## 패치 기준 시점

이 패치들은 **2026년 7월 19일** 기준 Haiku OS 소스를 기준으로 작성되었습니다. 일부 버그(ACPICA Global Lock 초기화 순서 문제, ACPI IRQ 트리거/극성, PCI 미정렬 config 접근, PS/2 멀티플렉서 포트 프로브 타임아웃 등)는 VAIO P 전용이 아닌 범용 정합성 버그라서, 새 체크아웃을 받을 시점에는 이미 공식 소스에서 고쳐져 있을 수 있습니다.

## 무엇을 고치는가

`vaio-p-patches.diff`는 아래 내용을 모두 담은 하나의 누적 diff입니다:

- **USB 안정성/부팅 속도** — `Hub.cpp`/`usb_private.h`/`BusManager.cpp`: 포트마다 무한 재시도 대신 재시도 -> 비활성화 -> 파워사이클 순으로 단계적으로 포기하는 백오프, `SET_ADDRESS` 재시도를 낭비하지 않도록 주소 0에서 `GET_DESCRIPTOR`로 먼저 응답 여부를 확인하는 프로브, Poulsbo 칩셋의 EHCI/UHCI BAR0 픽스업.
- **PS/2 멀티플렉서** — `ps2_common.cpp`: 아무것도 연결되지 않은 멀티플렉스 서브포트(1~3)에 대해 매직시퀀스 전체를 시도하고 타임아웃까지 기다리는 대신, 실제로 응답이 있는 포트만 프로브합니다.
- **WiFi (Atheros AR928X)** — `if_ath.c`/`if_athvar.h`: beacon-miss/bb-hang 복구가 반복되면 어댑터를 PCI 파워사이클(D3->D0)까지 강제합니다. `ieee80211_scan_sta.c`: 실제 접속 요청이 있기 전까지 `net80211`이 열린 AP에 마음대로 자동 접속하지 못하게 막습니다(원래는 STA 모드의 기본 후보 스캔이 부팅 시 가장 가까운 열린 이웃 AP를 붙잡았습니다). `AutoconfigLooper.cpp`/`.h`: 자동 접속을 한 번만 시도하지 않고 유예 시간을 두고 재시도하며, 의도치 않은 오픈 네트워크 연결을 "완료"로 취급하지 않습니다.
- **Sony EC 드라이버 (신규)** — `drivers/power/sony_ec/`: Sony `SNY5001` ACPI 장치(SNC)용 신규 MIT 라이선스 드라이버로, 밝기 조회/설정, 핫키 arm, 무선 스위치/Fn키 notify 이벤트를 처리합니다. Linux `sony-laptop.c`를 그대로 가져온 게 아니라 ACPI 프로토콜을 참고해 처음부터 새로 작성했습니다(자세한 내용은 드라이버 코드 내 주석 참고).
- **웹캠 (UVC)** — `UVCCamDevice.cpp`/`.h`, `UVCDeframer.cpp`: YUY2 포맷 디코딩 추가(이 카메라는 기존 디코더가 가정한 Bayer 포맷이 아니라 YUY2를 보고함), 그리고 프레임마다 버퍼 위치가 초기화되지 않아 계속 이어붙여지면서 첫 프레임 이후로는 전부 조용히 버려지던 버그를 수정.
- **부팅 화면** — `video.cpp`: 이 하드웨어의 VESA BIOS는 DDC/EDID를 아예 지원하지 않아 네이티브 해상도(1600x768)를 자동 감지할 방법이 없습니다. VESA 모드 목록에 해당 해상도가 있으면 부트로더가 직접 골라 씁니다.
- **부팅 속도/견고성 (범용)** — `smp.cpp`: 응답 없는 코어를 무한 대기하지 않도록 AP 기동 과정에 타임아웃 추가. `evglock.c`: 핸들러 설치 도중 Global Lock SCI가 동기적으로 발생할 때 필요한 락이 아직 없어서 터지는 ACPICA 레이스를 수정. `pci.cpp`: 정렬 안 된 32비트 config 공간 접근을 그냥 거부하지 않고 16비트 접근 두 번으로 쪼갬. `acpi_irq_routing_table.cpp`: 잘못됐을 수 있는 ACPI 서술자를 그대로 믿는 대신 IRQ 극성/트리거 모드를 고정값으로 보정. `vfs_boot.cpp`: 열거가 느린 USB 부팅 매체에 대해 즉시 패닉하지 않고 부팅 파티션 탐색을 재시도.
- **설치기** — `WorkerThread.cpp`/`.h`: 설치 후 대상 파티션을 실제로 active로 표시하고 MBR 부트코드를 기록해서, 수동으로 `writembr`를 하지 않아도 설치 직후 바로 부팅 가능하게 함.
- **launch_daemon** — `Job.cpp`: `launch_daemon`이 아직 앱을 등록하지 못한 시점이면 즉시 실패하지 않고 한동안 재시도(느린 저장장치에서 중요).

## 파일 구성

| 파일 | 설명 |
|---|---|
| `vaio-p-patches.diff` | 위에 설명한 범용 VAIO P 패치를 모두 담은 unified diff입니다. `git diff`로 생성됩니다. |
| `build-vaio-p-iso.sh` | **Linux**에서 실행합니다. Haiku/buildtools 클론, 패치 적용, 크로스툴체인 빌드, `jam -q @nightly-anyboot` 실행까지 전 과정을 자동화합니다. |
| `docker-build-vaio-p-iso.sh` | **macOS**에서 실행하는 래퍼입니다. case-sensitive 디스크 이미지와 Docker 컨테이너(`ubuntu:22.04`, Rosetta 가속)를 준비한 뒤 그 안에서 `build-vaio-p-iso.sh`를 실행합니다. |
| `LICENSE` | 이 패치들이 추가한 신규 코드(특히 `sony_ec` 드라이버)에 적용되는 MIT 라이선스입니다. |

레거시 `x86_gcc2` 크로스컴파일러는 `-m32` 호스트 지원이 필요한데, 최신 macOS SDK는 i386 링크를 완전히 제거했기 때문에 macOS에서는 직접 빌드할 수 없습니다. 그래서 macOS에서는 반드시 `docker-build-vaio-p-iso.sh`를 통해 Linux 컨테이너 안에서 빌드해야 합니다.

## 사용법

### macOS

```sh
cd tools/vaio-p
./docker-build-vaio-p-iso.sh ~/haiku.iso
```

Docker Desktop 설정에서 **Use Virtualization Framework**와 **Use Rosetta for x86/amd64 emulation**을 켜두어야 QEMU 완전 에뮬레이션이 아닌 Rosetta 가속으로 빌드되어 훨씬 빠릅니다 (몇 시간 -> 1~2시간 수준).

### Linux

```sh
cd tools/vaio-p
./build-vaio-p-iso.sh ~/vaio-p-work ~/haiku.iso
```

### 환경 변수

- `SKIP_CROSS_TOOLS=1` : 크로스컴파일러가 이미 빌드되어 있으면 재빌드를 생략합니다 (패치만 수정하고 다시 빌드할 때 유용하며, 크로스툴 빌드에만 1~1.5시간이 소요됩니다).
- `HAIKU_GIT_REF` : 체크아웃할 haiku.git의 브랜치/태그/커밋입니다. 기본값은 현재 체크아웃 상태를 유지합니다 (새로 클론 시 `master`).
- `JOBS` : `configure`/`jam` 병렬 작업 수입니다. 기본값은 `nproc`입니다.

