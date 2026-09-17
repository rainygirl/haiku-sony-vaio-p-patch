# Sony VAIO P Haiku OS 패치 스크립트

English version: [`README.md`](README.md).

이 폴더는 Sony VAIO P (VGN-P70H_G)에서 ACPI를 켜고 Safe Mode 없이 정상 부팅/설치/동작하도록 만든 패치를, [Haiku](https://www.haiku-os.org/)에서 fork된 운영체제 [RenkuOS](https://github.com/RenkuOS/Source)에 적용해 **32비트** ISO로 빌드하는 스크립트를 담고 있습니다.

패치는 Haiku 자체 소스가 아니라 **RenkuOS 소스의 nightly build**에 적용됩니다: 빌드 스크립트가 현재 RenkuOS nightly가 빌드된 바로 그 커밋을 체크아웃하고, 그 위에 `vaio-p-patches.diff`를 적용해 빌드합니다.

RenkuOS nightly 자체는 x86_64로만 배포되는데, VAIO P의 Atom Z520은 long mode가 없어 실행할 수 없습니다. 그래서 그 nightly가 빌드된 커밋을 그대로 받아 `x86_gcc2h` 하이브리드로 빌드합니다. 자세한 내용은 [`AGENTS.ko.md`](AGENTS.ko.md)의 "패치 기준 시점"에 있습니다.

개발·기술 노트(각 패치가 무엇을 왜 고치는지, 무엇을 측정했는지)는 [`AGENTS.ko.md`](AGENTS.ko.md)에 있습니다.

## 전원을 켤 때 반복 재부팅은 정상입니다

VAIO P는 두 번째 CPU를 항상 띄울 수 있는 것이 아닙니다: 응답 여부는 전원을 켤 때마다 펌웨어가 정하고, 결과를 바꿀 수 있는 유일한 방법은 POST를 한 번 더 하는 것이었습니다. 그래서 응답이 없으면 부트로더가 **일부러 재부팅**해 다시 시도하며, 이때 아래 메시지가 나옵니다:

```
SMP: second CPU did not answer. Rebooting on purpose to re-roll the firmware state.
This is expected and may repeat several times before the machine finishes booting.
```

- **최대 8번**까지 재시도합니다. 한 번에 약 30초의 POST가 걸리므로, 문제라고 판단하기 전에 **4~5분**은 기다려 주세요.
- 결과는 둘 중 하나입니다: 두 번째 CPU가 응답해 **CPU 2개**로 부팅되거나, 8번을 모두 쓰고 **CPU 1개**로 부팅됩니다. 어느 쪽도 고장이 아닙니다.
- 비정상인 경우: 같은 메시지가 8번을 훨씬 넘어 계속 반복되거나, `Kernel Debugging Land` / `PANIC` 화면이 나올 때.

부팅이 끝난 뒤 아래 명령으로 그 부팅에서 무슨 일이 있었는지 확인할 수 있습니다:

```sh
grep -iE 'reroll|early wake' /var/log/syslog
```

`AP came up after N deliberate reboot(s)`면 CPU 2개로 성공한 것이고, `AP unresponsive after 8 reroll(s)`면 재시도를 다 쓰고 CPU 1개로 부팅한 것입니다. 자세한 내용은 [`AGENTS.ko.md`](AGENTS.ko.md)를 참고하세요.

## 이 기기에서는 `pkgman update`(또는 HaikuDepot 업데이트)를 실행하지 마세요

`pkgman update`나 HaikuDepot의 "Update"는 온라인 저장소에서 최신 `haiku` 패키지(커널, 모든 커널 add-on, kit 일체를 담고 있음)를 받아와 이 ISO가 빌드될 때 쓰인 것을 그대로 교체해버립니다 — 이 패치들이 적용한 하드웨어 전용 수정 전부가 조용히 무효화됩니다(특히 이 정확한 CPU에서 시스템을 완전히 멈추게 하는 `x86_acpi_cstates`가 다시 켜짐 — [`AGENTS.ko.md`](AGENTS.ko.md)의 "cpuidle" 참고). 실기로 확인됨: 정상 설치되어 잘 부팅되던 시스템이 `pkgman update`를 실행한 직후부터 부팅이 멈췄습니다(HAIKU 로고는 뜨지만 그 뒤로 아이콘이 하나도 안 켜지고 멈추며, DEBUG 옵션을 켜도 출력이 없음 — 이제 이 ISO의 수정이 빠진 시스템으로 재부팅되기 때문입니다). 이 시스템을 업데이트하는 지원되는 방법은 없습니다 — 더 최신 패치 기준으로 다시 빌드하고 재설치하는 것뿐입니다.

## 파일 구성

| 파일 | 설명 |
|---|---|
| `vaio-p-patches.diff` | 위에 설명한 VAIO P 패치를 모두 담은 unified diff입니다. `git diff`로 생성됩니다. |
| `build-vaio-p-iso.sh` | **Linux(amd64)**에서 실행합니다. RenkuOS/Source와 buildtools를 클론하고, 현재 RenkuOS nightly가 빌드된 커밋을 체크아웃해 패치를 적용한 뒤, 32비트 크로스툴체인 빌드와 `jam -q @nightly-anyboot`까지 자동화합니다. |
| `docker-build-vaio-p-iso.sh` | **macOS**에서 실행하는 래퍼입니다. amd64 Docker 컨테이너(`ubuntu:22.04`, Rosetta 가속, 이름 `vaio-p-builder`)를 준비하고 빌드 전체를 Docker named volume에 둔 채 `build-vaio-p-iso.sh`를 실행한 뒤 ISO를 꺼내옵니다. |
| `AGENTS.md` / `AGENTS.ko.md` | 개발·기술 노트. 각 패치가 무엇을 왜 고치는지, 실기에서 무엇을 측정했는지, 손대기 전에 알아둘 함정들. |
| `LICENSE` | 이 패치들이 추가한 신규 코드(특히 `sony_ec`, `intel_est` 드라이버)에 적용되는 MIT 라이선스입니다. |

레거시 `x86_gcc2` 크로스컴파일러는 `-m32` 호스트 지원이 필요한데, macOS와 arm64 Linux 모두 이를 제공하지 않아 macOS에서도, arm64 컨테이너에서도 직접 빌드할 수 없습니다. 그래서 macOS에서는 반드시 `docker-build-vaio-p-iso.sh`를 통해 amd64 Linux 컨테이너 안에서 빌드해야 하며, 래퍼는 다른 아키텍처의 컨테이너를 재사용하지 않도록 확인합니다.

## 사용법

### macOS

```sh
cd tools/vaio-p
./docker-build-vaio-p-iso.sh ~/renku-vaio-p.iso
```

Docker Desktop 설정에서 **Use Virtualization Framework**와 **Use Rosetta for x86/amd64 emulation**을 켜두어야 QEMU 완전 에뮬레이션이 아닌 Rosetta 가속으로 빌드되어 훨씬 빠릅니다 (몇 시간 -> 1~2시간 수준).

### Linux

```sh
cd tools/vaio-p
./build-vaio-p-iso.sh ~/vaio-p-work ~/renku-vaio-p.iso
```

### 환경 변수

- `SKIP_CROSS_TOOLS=1` : 크로스컴파일러가 이미 빌드되어 있으면 재빌드를 생략합니다 (패치만 수정하고 다시 빌드할 때 유용하며, 크로스툴 빌드에만 1~1.5시간이 소요됩니다).
- `RENKU_REF` : 빌드할 RenkuOS/Source의 브랜치/태그/커밋입니다. 기본값은 현재 nightly 릴리스가 빌드된 커밋으로, 릴리스 노트에서 읽어옵니다 — 절대 움직이지 않는 `nightly` 태그가 아닙니다([`AGENTS.ko.md`](AGENTS.ko.md)의 "패치 기준 시점" 참고). 릴리스를 읽지 못하면 검증된 커밋 `f04d7eb54a`를 씁니다.
- `DISTRO_COMPATIBILITY` : `configure --distro-compatibility` 값입니다. 기본값은 RenkuOS nightly와 같은 `default`입니다.
- `IMAGE_LABEL` : `HAIKU_IMAGE_LABEL` 값입니다. 기본값은 nightly와 같은 `RenkuOS`입니다.
- `CONTAINER_NAME` (macOS 래퍼 전용) : 빌드 컨테이너 이름입니다. 기본값은 `vaio-p-builder`입니다.
- `WORK_VOLUME_NAME` (macOS 래퍼 전용) : 소스·툴체인·오브젝트 등 빌드 전체를 담는 Docker named volume입니다. 기본값은 `haiku-vaio-p-work`입니다. macOS 바인드 마운트이면 안 됩니다: 빌드가 파일 타입을 확장 속성으로 읽고 쓰는데, 바인드 마운트(virtiofs)는 이를 지원하지 않습니다.
- `JOBS` : `configure`/`jam` 병렬 작업 수입니다. 기본값은 `nproc`입니다.

### `--distro-compatibility default`를 쓰는 이유

RenkuOS nightly가 이 설정으로 빌드하기 때문입니다. 상표가 있는 아트워크를 포함하지 않으므로 설치된 시스템의 바탕화면 로고가 비어 있는데, [`restore-haiku-logo.sh`](restore-haiku-logo.sh)로 되돌릴 수 있습니다. 부팅 스플래시는 어느 쪽이든 영향이 없습니다 — 패치셋이 더 이상 부팅 시 로고를 그리지 않기 때문입니다.

## 빌드 후 확인

빌드 자체는 소스 검증일 뿐이며, 실제 검증은 실기기에서만 가능합니다: USB로 ACPI를 켜고 Safe Mode 없이 부팅 -> 내장 디스크에 설치 (DriveSetup으로 Intel 파티션 맵 + BFS 파티션을 먼저 만든 뒤 설치) -> 재부팅까지 확인해야 합니다.

## AI 기여 고지

이 패치는 Claude와 함께 작업해 만들었습니다. 작업은 실제 기기에서 얻은 측정값 — syslog, KDL 세션, 디스어셈블한 DSDT, PCI 설정공간과 물리 메모리 직접 읽기, 제조사 정오표 문서 — 을 근거로 진행했고, 여기 적힌 모든 수정은 문서화 전에 실기에서 검증했습니다. 초안의 여러 결론은 틀렸고 측정 결과가 그것을 반박했기 때문에 바로잡혔습니다. 아직 규명하지 못한 것들은 덮지 않고 미해결로 표시해 두었습니다.

**Haiku 프로젝트는 AI가 개입한 기여를 받지 않으며, 이 내용은 업스트림에 제출된 적이 없고 제출해서도 안 됩니다.** 이것은 기기 한 대를 위한 개인 패치 묶음이고, 수정 대상 코드와 동일한 MIT 조건으로 그 취지에 맞게 공개합니다. 일부를 재사용하신다면 이 고지도 함께 옮겨주시기 바랍니다.
