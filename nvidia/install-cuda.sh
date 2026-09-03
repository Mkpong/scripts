#!/bin/bash
###############################################################################
# CUDA 자동 설치 스크립트
# - NVIDIA APT repository 등록 후 CUDA 12.1 설치
# - Ubuntu 환경 기준
#
# 실행 방법: bash install-cuda.sh
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

step_header "CUDA 자동 설치 시작"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"

step_header "Step 1/4: CUDA APT repository 등록"
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-ubuntu2204.pin
sudo mv cuda-ubuntu2204.pin /etc/apt/preferences.d/cuda-repository-pin-600

sudo apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/3bf863cc.pub

sudo add-apt-repository \
"deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/ /"


step_header "Step 2/4: CUDA 설치"
sudo apt update
sudo apt install -y cuda-12-1


step_header "Step 3/4: 환경 변수 설정"
echo 'export PATH=/usr/local/cuda-12.1/bin:$PATH' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH=/usr/local/cuda-12.1/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
source ~/.bashrc

step_header "Step 4/4: CUDA 설치 확인"
nvcc --version

step_header "모든 설치 및 설정이 완료되었습니다"
