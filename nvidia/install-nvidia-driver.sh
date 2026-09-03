#!/bin/bash
###############################################################################
# NVIDIA Driver 자동 설치 스크립트
# - NVIDIA 공식 .run 파일을 내려받아 드라이버 설치 (kernel-open 모듈)
# - Ubuntu 환경 기준
#
# 실행 방법: bash install-nvidia-driver.sh [550|595]
#   550 - 550.120 (기본값)
#   595 - 595.58.03 (Blackwell)
###############################################################################

set -e

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

# ----- 사전 점검 -----
. /etc/os-release

if [ "$NAME" != "Ubuntu" ]; then
    log_error "이 스크립트는 Ubuntu 환경에서만 동작합니다."
    exit 1
fi

# Version mapping
declare -A DRIVER_VERSIONS
DRIVER_VERSIONS[550]="550.120"
DRIVER_VERSIONS[595]="595.58.03"

# Parse arguments
DRIVER_KEY="${1:-550}"

if [ -z "${DRIVER_VERSIONS[$DRIVER_KEY]}" ]; then
    log_error "지원하지 않는 버전입니다: $DRIVER_KEY"
    log_info  "사용법: $0 [550|595]"
    log_info  "  550 - ${DRIVER_VERSIONS[550]} (기본값)"
    log_info  "  595 - ${DRIVER_VERSIONS[595]} (Blackwell)"
    exit 1
fi

DRIVER_VERSION="${DRIVER_VERSIONS[$DRIVER_KEY]}"

step_header "NVIDIA Driver 자동 설치 시작"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"
log_info "설치 버전: ${DRIVER_VERSION}"

step_header "Step 1/4: NVIDIA Driver 다운로드 (${DRIVER_VERSION})"
BASE_URL="https://download.nvidia.com/XFree86/Linux-x86_64"
RUN_FILE="NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"
wget "${BASE_URL}/${DRIVER_VERSION}/${RUN_FILE}"
chmod +x "$RUN_FILE"

step_header "Step 2/4: 빌드 의존 패키지 설치"
sudo apt update
sudo apt install -y build-essential gcc make dkms

step_header "Step 3/4: NVIDIA Driver 설치"
sudo "./${RUN_FILE}" -m=kernel-open

step_header "Step 4/4: 드라이버 확인 및 설치 파일 정리"
nvidia-smi
rm "$RUN_FILE"

step_header "모든 설치 및 설정이 완료되었습니다"
