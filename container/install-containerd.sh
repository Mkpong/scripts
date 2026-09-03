#!/bin/bash
###############################################################################
# containerd 자동 설치 스크립트
# - Docker 없이 containerd 만 설치 (Kubernetes 노드용 컨테이너 런타임)
# - CRI 활성화 + systemd cgroup 설정까지 완료 (install-docker.sh 와 동일한 설정)
# - Ubuntu 환경 기준
#
# 실행 방법: bash install-containerd.sh
###############################################################################

set -euo pipefail

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
# os-release 를 서브셸에서 읽어 NAME/VERSION 등이 현재 셸을 덮지 않게 함
OS_NAME=$(. /etc/os-release; echo "$NAME")
OS_CODENAME=$(. /etc/os-release; echo "$VERSION_CODENAME")

if [ "$OS_NAME" != "Ubuntu" ]; then
    log_error "이 스크립트는 Ubuntu 환경에서만 동작합니다."
    exit 1
fi

if command -v docker &>/dev/null; then
    log_warn "Docker 가 이미 설치되어 있습니다. containerd 설정(/etc/containerd/config.toml)을 다시 생성합니다."
fi

step_header "containerd 자동 설치 시작"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"

step_header "Step 1/7: apt 업데이트"
sudo apt-get update

step_header "Step 2/7: 의존 패키지 설치"
sudo apt-get install -y \
    ca-certificates \
    curl \
    gnupg

step_header "Step 3/7: Docker GPG 키 등록 (containerd.io 패키지 제공 저장소)"
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

step_header "Step 4/7: Docker APT repository 등록"
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  ${OS_CODENAME} stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

step_header "Step 5/7: containerd 설치"
sudo apt-get update
sudo apt-get install -y containerd.io

step_header "Step 6/7: containerd 설정 (CRI 활성화 + systemd cgroup)"
# 커널 모듈 (containerd/kubernetes 공식 사전 요구사항)
log_info "커널 모듈 로드 (overlay, br_netfilter)..."
cat <<MODULES | sudo tee /etc/modules-load.d/containerd.conf > /dev/null
overlay
br_netfilter
MODULES
sudo modprobe overlay
sudo modprobe br_netfilter

# 기존 설정 백업 후 기본 설정 재생성
sudo mkdir -p /etc/containerd
if [ -f /etc/containerd/config.toml ]; then
    BACKUP="/etc/containerd/config.toml.bak.$(date '+%Y%m%d%H%M%S')"
    sudo cp /etc/containerd/config.toml "${BACKUP}"
    log_warn "기존 설정 백업: ${BACKUP}"
fi
log_info "기본 설정 생성 (containerd config default)..."
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

log_info "SystemdCgroup = true 설정..."
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
if ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
    log_error "SystemdCgroup 설정을 적용하지 못했습니다. /etc/containerd/config.toml 을 확인하세요."
    exit 1
fi

sudo systemctl restart containerd
sudo systemctl enable containerd

step_header "Step 7/7: 설치 확인"
containerd --version
if [ ! -S /var/run/containerd/containerd.sock ]; then
    log_error "containerd 소켓(/var/run/containerd/containerd.sock)이 없습니다. 'systemctl status containerd' 를 확인하세요."
    exit 1
fi
log_success "containerd 소켓 확인 완료"

step_header "모든 설치 및 설정이 완료되었습니다"
log_info "다음 단계: Kubernetes 설치는 '../kubernetes/install-kubeadm.sh' 를 실행하세요."
