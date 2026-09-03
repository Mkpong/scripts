#!/bin/bash
###############################################################################
# NVIDIA 권장 드라이버 버전 확인 스크립트
# - ubuntu-drivers 로 현재 GPU에 권장되는 드라이버 버전 조회
# - Ubuntu 환경 기준
#
# 실행 방법: bash check-nvidia-driver-version.sh
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

step_header "NVIDIA 권장 드라이버 버전 확인 시작"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"

step_header "Step 1/3: apt 업데이트"
sudo apt-get update

step_header "Step 2/3: ubuntu-drivers-common 설치"
sudo apt-get install -y ubuntu-drivers-common

step_header "Step 3/3: 권장 드라이버 버전 확인"
ubuntu-drivers devices

step_header "확인이 완료되었습니다"
log_info "드라이버 설치는 install-nvidia-driver.sh 를 실행하세요."
