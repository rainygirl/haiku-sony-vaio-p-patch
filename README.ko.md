# Sony VAIO P Haiku OS 패치 스크립트

English version: [`README.md`](README.md).

이 폴더는 Sony VAIO P (VGN-P70H_G)에서 Haiku OS가 ACPI를 켜고 Safe Mode 없이 정상 부팅/설치/동작하도록 만든 패치를 새 Haiku OS 소스에 적용하고 ISO로 빌드하는 스크립트를 담고 있습니다.

개발·기술 노트(각 패치가 무엇을 왜 고치는지, 무엇을 측정했는지)는 [`AGENTS.ko.md`](AGENTS.ko.md)에 있습니다.

## 이 기기에서는 `pkgman update`(또는 HaikuDepot 업데이트)를 실행하지 마세요

`pkgman update`나 HaikuDepot의 "Update"는 온라인 저장소에서 최신 업스트림 `haiku` 패키지(커널, 모든 커널 add-on, kit 일체를 담고 있음)를 받아와 이 ISO가 빌드될 때 쓰인 것을 그대로 교체해버립니다 — 이 패치들이 적용한 하드웨어 전용 수정 전부가 조용히 무효화됩니다(특히 이 정확한 CPU에서 시스템을 완전히 멈추게 하는 `x86_acpi_cstates`가 다시 켜짐 — [`AGENTS.ko.md`](AGENTS.ko.md)의 "cpuidle" 참고). 실기로 확인됨: 정상 설치되어 잘 부팅되던 시스템이 `pkgman update`를 실행한 직후부터 부팅이 멈췄습니다(HAIKU 로고는 뜨지만 그 뒤로 아이콘이 하나도 안 켜지고 멈추며, DEBUG 옵션을 켜도 출력이 없음 — 이제 이 ISO의 수정이 빠진 시스템으로 재부팅되기 때문입니다). 이 시스템을 업데이트하는 지원되는 방법은 없습니다 — 더 최신 패치 기준으로 다시 빌드하고 재설치하는 것뿐입니다.

## 파일 구성

| 파일 | 설명 |
|---|---|
| `vaio-p-patches.diff` | 위에 설명한 VAIO P 패치를 모두 담은 unified diff입니다. `git diff`로 생성됩니다. |
| `build-vaio-p-iso.sh` | **Linux**에서 실행합니다. Haiku/buildtools 클론, 패치 적용, 크로스툴체인 빌드, `jam -q @nightly-anyboot` 실행까지 전 과정을 자동화합니다. |
| `docker-build-vaio-p-iso.sh` | **macOS**에서 실행하는 래퍼입니다. case-sensitive 디스크 이미지와 Docker 컨테이너(`ubuntu:22.04`, Rosetta 가속)를 준비한 뒤 그 안에서 `build-vaio-p-iso.sh`를 실행합니다. |
| `AGENTS.md` / `AGENTS.ko.md` | 개발·기술 노트. 각 패치가 무엇을 왜 고치는지, 실기에서 무엇을 측정했는지, 손대기 전에 알아둘 함정들. |
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
- `HAIKU_GIT_REF` : 체크아웃할 haiku.git의 브랜치/태그/커밋입니다. 기본값은 고정된 nightly 커밋 `8b91c532fa`입니다([`AGENTS.ko.md`](AGENTS.ko.md)의 "패치 기준 시점" 참고). `master`로 두면 최신 tip을 따라가지만, 패치가 그대로 적용될지는 보장되지 않습니다.
- `JOBS` : `configure`/`jam` 병렬 작업 수입니다. 기본값은 `nproc`입니다.

### `configure --distro-compatibility official`을 주는 이유

이 옵션이 없으면 `HAIKU_DISTRO_COMPATIBILITY`가 `default`가 되고, `headers/private/kernel/boot/images.h`가 상표 없는 스플래시 세트인 `images-sans-tm.h`를 포함합니다. 그런데 이 파일의 372x96 로고 이미지는 **빈 이미지**입니다. 부트 아이콘은 같은 헤더에서 오지만 실제 이미지라서, 증상은 "아이콘 줄만 나오고 그 위 Haiku 로고가 없는 부팅 화면"으로 나타납니다. `official`을 주면 업스트림 나이틀리가 쓰는 `images-tm-development.h`가 선택됩니다. 이 define을 참조하는 나머지 코드는 About, Deskbar 잎 메뉴, Installer, 첫 부팅 프롬프트뿐이며 전부 외형에만 영향을 줍니다.

## 빌드 후 확인

빌드 자체는 소스 검증일 뿐이며, 실제 검증은 실기기에서만 가능합니다: USB로 ACPI를 켜고 Safe Mode 없이 부팅 -> 내장 디스크에 설치 (DriveSetup으로 Intel 파티션 맵 + BFS 파티션을 먼저 만든 뒤 설치) -> 재부팅까지 확인해야 합니다.

## AI 기여 고지

이 패치는 Claude와 함께 작업해 만들었습니다. 작업은 실제 기기에서 얻은 측정값 — syslog, KDL 세션, 디스어셈블한 DSDT, PCI 설정공간과 물리 메모리 직접 읽기, 제조사 정오표 문서 — 을 근거로 진행했고, 여기 적힌 모든 수정은 문서화 전에 실기에서 검증했습니다. 초안의 여러 결론은 틀렸고 측정 결과가 그것을 반박했기 때문에 바로잡혔습니다. 아직 규명하지 못한 것들은 덮지 않고 미해결로 표시해 두었습니다.

**Haiku 프로젝트는 AI가 개입한 기여를 받지 않으며, 이 내용은 업스트림에 제출된 적이 없고 제출해서도 안 됩니다.** 이것은 기기 한 대를 위한 개인 패치 묶음이고, 수정 대상 코드와 동일한 MIT 조건으로 그 취지에 맞게 공개합니다. 일부를 재사용하신다면 이 고지도 함께 옮겨주시기 바랍니다.
