#!/bin/bash
###############################################################################
# Kubernetes control-plane 초기화 스크립트
# - swap 해제, br_netfilter 설정 후 kubeadm init 수행
# - 단일 노드(MULTI=false)일 경우 control-plane taint 제거
#
# 실행 방법: bash initialize-kubeadm.sh
#   MULTI=true  ./initialize-kubeadm.sh   (멀티 노드 클러스터)
#   MULTI=false ./initialize-kubeadm.sh   (단일 노드, 기본값)
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
MULTI="false"

if [ "$MULTI" != "true" ] && [ "$MULTI" != "false" ]; then
    log_error "MULTI 값은 'true' 또는 'false' 여야 합니다. (예: MULTI=true $0)"
    exit
fi

if [ -f ~/k8s_init.log ]; then
    log_warn "이미 kubeadm 초기화를 시도한 기록이 있습니다. (~/k8s_init.log)"
    exit
fi

step_header "Kubernetes control-plane 초기화 시작"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"
log_info "MULTI: ${MULTI}"

step_header "Step 1/4: swap 해제 및 br_netfilter 설정"
# turn off swap
log_info "swap 해제..."
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# enable br_netfilter
log_info "br_netfilter 활성화..."
sudo modprobe br_netfilter
if [ $(cat /proc/sys/net/bridge/bridge-nf-call-iptables) == 0 ]; then
    sudo bash -c "echo '1' > /proc/sys/net/bridge/bridge-nf-call-iptables"
    sudo bash -c "echo 'net.bridge.bridge-nf-call-iptables=1' >> /etc/sysctl.conf"
fi

step_header "Step 2/4: kubeadm init (control-plane 초기화)"
# initialize the control plane
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 | tee -a ~/k8s_init.log
if [ $? != 0 ]; then
    log_error "kubeadm 초기화에 실패했습니다."
    exit
fi

step_header "Step 3/4: kubectl 설정 (non-root 사용자)"
# make kubectl work for non-root user
if [ ! -f $HOME/.kube/config ]; then
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $USER:$USER $HOME/.kube/config
    export KUBECONFIG=$HOME/.kube/config
    echo "export KUBECONFIG=$HOME/.kube/config" | tee -a ~/.bashrc
fi

step_header "Step 4/4: control-plane taint 처리"
# remove the control-plane taint so pods can schedule on a single-node cluster
if [ "$MULTI" != "true" ]; then
    log_info "단일 노드 클러스터: control-plane taint 제거..."
    kubectl taint nodes --all node-role.kubernetes.io/control-plane-
else
    log_info "멀티 노드 클러스터: control-plane taint 유지"
fi

step_header "모든 설치 및 설정이 완료되었습니다"
log_info "다음 단계: CNI 배포는 'CNI={flannel|calico|cilium} ./deploy-cni.sh' 를 실행하세요."
log_info "워커 노드에서 'kubeadm join' 이 'bridge-nf-call-iptables does not exist' 로 실패하면,"
log_info "해당 노드에서 './enable-bridge-nf-call-iptables.sh' 를 먼저 실행하세요."
