#!/bin/bash
###############################################################################
# Docker 자동 설치 스크립트
# - Docker CE + containerd 설치 (CRI 활성화, systemd cgroup)
# - Ubuntu 환경 기준
#
# 실행 방법: bash install-docker.sh
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

step_header "Docker 자동 설치 시작"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"

step_header "Step 1/8: apt 업데이트"
sudo apt-get update

step_header "Step 2/8: 의존 패키지 설치"
sudo apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

step_header "Step 3/8: Docker GPG 키 등록"
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

step_header "Step 4/8: Docker APT repository 등록"
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $VERSION_CODENAME stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

step_header "Step 5/8: Docker 설치 (latest stable)"
sudo apt-get update
sudo apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

step_header "Step 6/8: Docker daemon 설정"
sudo mkdir -p /etc/docker
cat <<DAEMON | sudo tee /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
DAEMON

step_header "Step 7/8: containerd 설정 (CRI 활성화 + systemd cgroup)"
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

step_header "Step 8/8: Docker 시작"
sudo systemctl daemon-reexec
sudo systemctl restart docker
sudo systemctl enable docker

log_info "현재 사용자를 docker 그룹에 추가..."
sudo usermod -aG docker $USER

step_header "모든 설치 및 설정이 완료되었습니다"
log_info "docker 그룹 적용을 위해 로그아웃 후 다시 로그인하세요."
