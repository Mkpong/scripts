#!/bin/bash
###############################################################################
# Ubuntu cloud image 다운로드 스크립트
# - KVM VM 생성에 사용할 Ubuntu cloud image 를 /var/lib/libvirt/images 에 저장
# - 이미 존재하는 이미지는 건너뜀
#
# 실행 방법: bash download-ubuntu-image.sh [VERSION ...]
#   ./download-ubuntu-image.sh                 # 20.04, 22.04, 24.04 전부 (기본값)
#   ./download-ubuntu-image.sh ubuntu24.04     # 24.04 만
#   ./download-ubuntu-image.sh 22.04 24.04     # 여러 버전
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
  -h, --help   도움말 출력

동작:
  - 이미 다운로드된 이미지는 건너뜁니다 (재다운로드 없음).
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

# Help option
for arg in "$@"; do
	case "$arg" in
		-h|--help)
			usage
			exit 0
			;;
	esac
done

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

	if [ -f "${IMG_PATH}" ]; then
		log_warn "${VERSION} 이미지가 이미 존재합니다 (건너뜀): ${IMG_PATH}"
		continue
	fi

	log_info "${VERSION} 다운로드: ${IMG_URL}"
	if sudo wget -q --show-progress -O "${IMG_PATH}" "${IMG_URL}"; then
		log_success "${VERSION} 다운로드 완료: ${IMG_PATH}"
	else
		log_error "${VERSION} 다운로드 실패"
		sudo rm -f "${IMG_PATH}"
		exit 1
	fi
done

step_header "모든 다운로드가 완료되었습니다"
