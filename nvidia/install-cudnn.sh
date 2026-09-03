#!/bin/bash
###############################################################################
# cuDNN 자동 설치 스크립트
# - NVIDIA local repository(deb) 등록 후 cuDNN 9 (CUDA 12) 설치
# - Ubuntu 환경 기준
#
# 실행 방법: bash install-cudnn.sh
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

step_header "cuDNN 자동 설치 시작"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"

step_header "Step 1/2: cuDNN local repository 등록"
wget https://developer.download.nvidia.com/compute/cudnn/9.18.1/local_installers/cudnn-local-repo-ubuntu2204-9.18.1_1.0-1_amd64.deb
sudo dpkg -i cudnn-local-repo-ubuntu2204-9.18.1_1.0-1_amd64.deb
sudo cp /var/cudnn-local-repo-ubuntu2204-9.18.1/cudnn-*-keyring.gpg /usr/share/keyrings/
sudo apt-get update

step_header "Step 2/2: cuDNN 설치"
sudo apt-get -y install cudnn9-cuda-12

step_header "모든 설치 및 설정이 완료되었습니다"
