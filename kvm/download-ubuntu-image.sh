#!/bin/bash
###############################################################################
# Ubuntu cloud image 다운로드 스크립트
# - KVM VM 생성에 사용할 Ubuntu cloud image 를 /var/lib/libvirt/images 에 저장
# - 이미 존재하는 이미지는 건너뜀
#
# 실행 방법: bash download-ubuntu-image.sh [--verify] [VERSION ...]
#   ./download-ubuntu-image.sh                 # 20.04, 22.04, 24.04 전부 (기본값)
#   ./download-ubuntu-image.sh ubuntu24.04     # 24.04 만
#   ./download-ubuntu-image.sh 22.04 24.04     # 여러 버전
#   ./download-ubuntu-image.sh --verify 24.04  # 이미 있는 이미지도 SHA256 재검증
#
# - .part 임시 파일로 받고 SHA256SUMS 대조에 통과해야 최종 경로로 이동 (중단/손상 파일이 남지 않음)
###############################################################################

# ----- 색상 출력 -----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[ OK ]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $1"; }

step_header() {
	echo ""
	echo "================================================================"
	echo " $1"
	echo "================================================================"
}

IMAGE_DIR="/var/lib/libvirt/images"
BASE_URL="https://cloud-images.ubuntu.com"

usage() {
	cat <<USAGE
사용법: ./download-ubuntu-image.sh [VERSION ...]

인자:
  VERSION    다운로드할 Ubuntu 버전. 허용 값: ubuntu24.04 | 24.04 | noble
                                            ubuntu22.04 | 22.04 | jammy
                                            ubuntu20.04 | 20.04 | focal
             생략하면 지원하는 모든 버전을 다운로드합니다.

옵션:
  --verify     이미 있는 이미지도 SHA256SUMS 로 재검증 (불일치면 삭제 후 재다운로드)
  -h, --help   도움말 출력

동작:
  - 이미 다운로드된 이미지는 건너뜁니다 (재다운로드 없음). --verify 시 재검증.
  - 임시 파일(.part)로 받아 SHA256 검증 후 최종 경로로 이동합니다.
  - 저장 위치: ${IMAGE_DIR}

예시:
  ./download-ubuntu-image.sh                  # 20.04, 22.04, 24.04 전부
  ./download-ubuntu-image.sh ubuntu24.04      # 24.04 만
  ./download-ubuntu-image.sh 22.04 24.04      # 여러 버전
USAGE
}

# Map os-variant -> "codename:image-filename"
get_image_info() {
	case "$1" in
		ubuntu24.04|24.04|noble)
			echo "noble:noble-server-cloudimg-amd64.img"
			;;
		ubuntu22.04|22.04|jammy)
			echo "jammy:jammy-server-cloudimg-amd64.img"
			;;
		ubuntu20.04|20.04|focal)
			echo "focal:focal-server-cloudimg-amd64.img"
			;;
		*)
			echo ""
			;;
	esac
}

# 옵션 파싱 (--verify / -h), 나머지는 버전 인자
VERIFY=0
ARGS=()
for arg in "$@"; do
	case "$arg" in
		-h|--help) usage; exit 0 ;;
		--verify)  VERIFY=1 ;;
		*)         ARGS+=("$arg") ;;
	esac
done
set -- "${ARGS[@]}"

# 중단(Ctrl-C 등) 시 받다 만 .part 파일 제거
PART_FILE=""
trap '[ -n "${PART_FILE}" ] && sudo rm -f "${PART_FILE}"' EXIT

# SHA256SUMS 에서 해당 파일의 해시를 받아 대조. 사용: verify_image <파일경로> <URL 디렉터리> <파일명>
verify_image() {
	local file="$1" base="$2" name="$3" expected actual
	expected=$(curl -fsSL --max-time 30 "${base}/SHA256SUMS" 2>/dev/null | awk -v n="*${name}" '$2==n {print $1}' | head -n1)
	if [ -z "${expected}" ]; then
		log_warn "SHA256SUMS 에서 ${name} 항목을 가져오지 못했습니다 (네트워크?). 검증을 건너뜁니다."
		VERIFY_SKIPPED=1
		return 0
	fi
	actual=$(sudo sha256sum "${file}" | awk '{print $1}')
	if [ "${actual}" = "${expected}" ]; then
		return 0
	fi
	log_error "SHA256 불일치: ${name}"
	log_info  "  기대: ${expected}"
	log_info  "  실제: ${actual}"
	return 1
}

# Default: all supported versions
if [ "$#" -eq 0 ]; then
	set -- ubuntu20.04 ubuntu22.04 ubuntu24.04
fi

step_header "Ubuntu cloud image 다운로드 시작"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"
log_info "저장 위치: ${IMAGE_DIR}"
log_info "대상 버전: $*"

sudo mkdir -p "${IMAGE_DIR}"

for VERSION in "$@"; do
	INFO=$(get_image_info "${VERSION}")

	if [ -z "${INFO}" ]; then
		log_error "지원하지 않는 버전입니다: ${VERSION}"
		log_info  "지원 버전: ubuntu20.04, ubuntu22.04, ubuntu24.04"
		exit 1
	fi

	CODENAME="${INFO%%:*}"
	IMG_NAME="${INFO##*:}"
	IMG_PATH="${IMAGE_DIR}/${IMG_NAME}"
	IMG_URL="${BASE_URL}/${CODENAME}/current/${IMG_NAME}"

	IMG_BASE_URL="${BASE_URL}/${CODENAME}/current"

	if [ -f "${IMG_PATH}" ]; then
		if [ "${VERIFY}" -eq 1 ]; then
			log_info "${VERSION} 기존 이미지 검증 중: ${IMG_PATH}"
			if verify_image "${IMG_PATH}" "${IMG_BASE_URL}" "${IMG_NAME}"; then
				log_success "${VERSION} 검증 통과 (건너뜀)"
				continue
			fi
			log_warn "${VERSION} 손상된 이미지를 삭제하고 다시 받습니다. (이 이미지를 backing file 로 쓰는 VM 이 있으면 영향 있음)"
			sudo rm -f "${IMG_PATH}"
		else
			log_warn "${VERSION} 이미지가 이미 존재합니다 (건너뜀): ${IMG_PATH}   재검증: --verify"
			continue
		fi
	fi

	PART_FILE="${IMG_PATH}.part"
	sudo rm -f "${PART_FILE}"
	log_info "${VERSION} 다운로드: ${IMG_URL}"
	if ! sudo wget -q --show-progress -O "${PART_FILE}" "${IMG_URL}"; then
		log_error "${VERSION} 다운로드 실패"
		exit 1                                   # trap 이 .part 삭제
	fi

	log_info "${VERSION} SHA256 검증 중..."
	VERIFY_SKIPPED=0
	if ! verify_image "${PART_FILE}" "${IMG_BASE_URL}" "${IMG_NAME}"; then
		log_error "${VERSION} 검증 실패 — 받은 파일을 삭제합니다."
		exit 1                                   # trap 이 .part 삭제
	fi
	sudo mv "${PART_FILE}" "${IMG_PATH}"
	PART_FILE=""
	if [ "${VERIFY_SKIPPED}" -eq 1 ]; then
		log_success "${VERSION} 다운로드 완료 (SHA256 검증 생략): ${IMG_PATH}"
	else
		log_success "${VERSION} 다운로드·검증 완료: ${IMG_PATH}"
	fi
done

step_header "모든 다운로드가 완료되었습니다"
