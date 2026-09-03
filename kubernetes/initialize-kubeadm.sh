#!/bin/bash
###############################################################################
# Kubernetes control-plane 초기화 스크립트
# - kubeadm init 수행 (swap 해제 / 커널·sysctl 설정은 install-kubeadm.sh 에서 수행)
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

# pod network CIDR — deploy-cni.sh 의 POD_CIDR 과 반드시 같아야 함
POD_CIDR="10.244.0.0/16"

# ----- 사전 점검 -----
MULTI="${MULTI:-false}"

if [ "$MULTI" != "true" ] && [ "$MULTI" != "false" ]; then
    log_error "MULTI 값은 'true' 또는 'false' 여야 합니다. (예: MULTI=true $0)"
    exit 1
fi

if [ -f ~/k8s_init.log ]; then
    log_warn "이미 kubeadm 초기화를 시도한 기록이 있습니다. (~/k8s_init.log)"
    log_info "다시 초기화하려면 'rm ~/k8s_init.log' 후 재실행하세요. (이미 초기화된 클러스터는 'sudo kubeadm reset' 먼저, ~/.kube/config 는 자동 백업됨)"
    exit 1
fi

step_header "Kubernetes control-plane 초기화 시작"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"
log_info "MULTI: ${MULTI}"

step_header "Step 1/3: kubeadm init (control-plane 초기화)"
# initialize the control plane
sudo kubeadm init --pod-network-cidr="${POD_CIDR}" | tee -a ~/k8s_init.log
if [ "${PIPESTATUS[0]}" != 0 ]; then
    log_error "kubeadm 초기화에 실패했습니다."
    log_info  "로그: ~/k8s_init.log — 원인 수정 후 'rm ~/k8s_init.log' 하고 재실행하세요."
    exit 1
fi

step_header "Step 2/3: kubectl 설정 (non-root 사용자)"
# make kubectl work for non-root user
# admin.conf 는 방금 init 한 클러스터의 유일한 올바른 인증 정보이므로,
# 이전 클러스터의 kubeconfig 가 남아 있으면 백업 후 덮어쓴다
mkdir -p "$HOME/.kube"
if [ -f "$HOME/.kube/config" ]; then
    KUBECONFIG_BACKUP="$HOME/.kube/config.bak.$(date '+%Y%m%d%H%M%S')"
    cp "$HOME/.kube/config" "${KUBECONFIG_BACKUP}"
    log_warn "기존 kubeconfig 백업: ${KUBECONFIG_BACKUP}"
fi
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$USER:$USER" "$HOME/.kube/config"
export KUBECONFIG="$HOME/.kube/config"
if ! grep -q 'export KUBECONFIG=' ~/.bashrc; then
    echo "export KUBECONFIG=$HOME/.kube/config" | tee -a ~/.bashrc
fi
log_success "kubeconfig 설정 완료: $HOME/.kube/config"

step_header "Step 3/3: control-plane taint 처리"
# remove the control-plane taint so pods can schedule on a single-node cluster
if [ "$MULTI" != "true" ]; then
    log_info "단일 노드 클러스터: control-plane taint 제거..."
    kubectl taint nodes --all node-role.kubernetes.io/control-plane-
else
    log_info "멀티 노드 클러스터: control-plane taint 유지"
fi

step_header "모든 설치 및 설정이 완료되었습니다"
log_info "다음 단계: CNI 배포는 'CNI={flannel|calico|cilium} ./deploy-cni.sh' 를 실행하세요."
if [ "$MULTI" = "true" ]; then
    log_info "워커 노드 join 명령 확인: 'kubeadm token create --print-join-command' (토큰은 24시간 유효)"
    log_info "워커 노드는 '../container/install-containerd.sh' → './install-kubeadm.sh' 실행 후, 위 명령을 sudo 로 실행하세요."
fi
