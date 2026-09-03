#!/bin/bash
###############################################################################
# Kubernetes(kubeadm) 자동 설치 스크립트
# - kubeadm / kubelet / kubectl 설치 및 커널·네트워크 설정
# - Ubuntu 환경 기준, containerd 가 먼저 설치되어 있어야 함
#
# 실행 방법: bash install-kubeadm.sh
#   VERSION=1.33        ./install-kubeadm.sh   (1.33 최신 patch)
#   VERSION=1.33.0      ./install-kubeadm.sh   (특정 patch)
#   VERSION=1.33.2-1.1  ./install-kubeadm.sh   (특정 deb revision)
#   (VERSION 미지정)     ./install-kubeadm.sh   (latest stable)
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

# ----- 사전 점검 -----
# read os-release in a subshell so it does not clobber $VERSION (the
# user-supplied Kubernetes version), which /etc/os-release also defines
OS_NAME=$(. /etc/os-release; echo "$NAME")

if [ "$OS_NAME" != "Ubuntu" ]; then
    log_error "이 스크립트는 Ubuntu 환경에서만 동작합니다."
    exit
fi

# check container runtime
if [ ! -S /var/run/containerd/containerd.sock ]; then
    log_error "containerd 가 감지되지 않았습니다."
    log_info  "containerd 설치: '../containers/install-containerd.sh' 를 실행하세요."
    exit 1
fi

step_header "Kubernetes(kubeadm) 자동 설치 시작"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"

step_header "Step 1/5: apt 업데이트 및 필수 패키지 설치"
# update repo
sudo apt-get update

# install prerequisites
sudo apt-get install -y curl ca-certificates apt-transport-https gpg

step_header "Step 2/5: 설치 버전 결정"
# resolve version
# usage: VERSION=1.33        ./install-kubeadm.sh   (latest patch on 1.33)
#        VERSION=1.33.0      ./install-kubeadm.sh   (specific patch)
#        VERSION=1.33.2-1.1  ./install-kubeadm.sh   (specific deb revision)
#        (no VERSION)        ./install-kubeadm.sh   (latest stable)
if [ -z "$VERSION" ]; then
    LATEST=$(curl -L -s https://dl.k8s.io/release/stable.txt | sed 's/^v//')
    if [ -z "$LATEST" ]; then
        log_error "최신 Kubernetes 버전 정보를 가져오지 못했습니다."
        exit 1
    fi
    MINOR=$(echo "$LATEST" | cut -d. -f1,2)
    PKG_SPEC=""
    log_info "최신 Kubernetes (v$LATEST) 를 설치합니다."
else
    CLEAN=$(echo "$VERSION" | sed 's/^v//')
    MINOR=$(echo "$CLEAN" | cut -d. -f1,2)
    # if user only gave minor (e.g. 1.33), let apt pick the latest patch
    if [ "$CLEAN" = "$MINOR" ]; then
        PKG_SPEC=""
        log_info "Kubernetes v$MINOR 의 최신 patch 를 설치합니다."
    else
        # append default deb revision if missing
        if echo "$CLEAN" | grep -q -- '-'; then
            DEB_VERSION="$CLEAN"
        else
            DEB_VERSION="${CLEAN}-1.1"
        fi
        PKG_SPEC="=$DEB_VERSION"
        log_info "Kubernetes v$CLEAN 을 설치합니다."
    fi
fi

step_header "Step 3/5: Kubernetes APT repository 등록"
# add the key for the kubernetes repo
log_info "GPG 키 등록..."
sudo mkdir -p /etc/apt/keyrings
sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${MINOR}/deb/Release.key" \
    | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# add sources.list.d
log_info "APT repository 등록..."
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${MINOR}/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list

# update repo
sudo apt-get update

step_header "Step 4/5: kubeadm / kubelet / kubectl 설치"
# install kubernetes
sudo apt-get install -y "kubeadm${PKG_SPEC}" "kubelet${PKG_SPEC}" "kubectl${PKG_SPEC}"

# exclude kubernetes packages from updates
log_info "Kubernetes 패키지 자동 업데이트 제외(hold)..."
sudo apt-mark hold kubeadm kubelet kubectl

step_header "Step 5/5: 커널 / 네트워크 설정"
# mount bpffs (for cilium)
log_info "bpffs 마운트 설정 (cilium)..."
if ! grep -q "^bpffs" /etc/fstab; then
    echo "bpffs                                     /sys/fs/bpf     bpf     defaults          0       0" | sudo tee -a /etc/fstab
fi

# enable ip forwarding
log_info "ip_forward 활성화..."
if [ $(cat /proc/sys/net/ipv4/ip_forward) == 0 ]; then
    sudo bash -c "echo '1' > /proc/sys/net/ipv4/ip_forward"
    sudo bash -c "echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf"
fi

# enable br_netfilter
log_info "br_netfilter 활성화..."
sudo modprobe br_netfilter
if [ $(cat /proc/sys/net/bridge/bridge-nf-call-iptables) == 0 ]; then
    sudo bash -c "echo '1' > /proc/sys/net/bridge/bridge-nf-call-iptables"
    sudo bash -c "echo 'net.bridge.bridge-nf-call-iptables=1' >> /etc/sysctl.conf"
fi

# disable rp_filter
log_info "rp_filter 비활성화 (cilium)..."
if [ ! -f /etc/sysctl.d/99-override_cilium_rp_filter.conf ]; then
    sudo bash -c "echo 'net.ipv4.conf.all.rp_filter = 0' > /etc/sysctl.d/99-override_cilium_rp_filter.conf"
    sudo systemctl restart systemd-sysctl
fi

step_header "모든 설치 및 설정이 완료되었습니다"
log_info "다음 단계: Kubernetes 초기화는 '(MULTI=true) ./initialize-kubeadm.sh' 를 실행하세요."
