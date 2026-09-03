#!/bin/bash
###############################################################################
# Kubernetes CNI 배포 스크립트
# - flannel / calico / cilium 중 하나를 선택해 pod network 배포
# - kubectl 이 클러스터에 연결되어 있어야 함
#
# 실행 방법: CNI={flannel|calico|cilium} bash deploy-cni.sh
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

# pod network CIDR — initialize-kubeadm.sh 의 POD_CIDR 과 반드시 같아야 함
# (flannel 매니페스트는 10.244.0.0/16 고정이므로 flannel 사용 시 이 값을 바꾸면 안 됨)
POD_CIDR="10.244.0.0/16"

# ----- 사전 점검 -----
# set default
if [ "$CNI" == "" ]; then
    log_error "CNI 값이 지정되지 않았습니다."
    log_info  "사용법: CNI={flannel|calico|cilium} $0"
    exit 1
fi

# check supported CNI
if [ "$CNI" != "flannel" ] && [ "$CNI" != "calico" ] && [ "$CNI" != "cilium" ]; then
    log_error "지원하지 않는 CNI 입니다: $CNI"
    log_info  "사용법: CNI={flannel|calico|cilium} $0"
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    log_error "kubectl 을 찾을 수 없습니다."
    exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
    log_error "Kubernetes 클러스터에 연결할 수 없습니다. kubeconfig 를 확인하세요. (initialize-kubeadm.sh 를 먼저 실행)"
    exit 1
fi
log_success "클러스터 연결 확인 완료"

# 다른 CNI 가 이미 배포되어 있으면 중단 (겹치면 pod 네트워크가 깨짐). 같은 CNI 재적용은 허용
case "$CNI" in
    flannel) MY_CNI_MARK="kube-flannel" ;;
    calico)  MY_CNI_MARK="calico-node" ;;
    cilium)  MY_CNI_MARK="cilium" ;;
esac
EXISTING_CNI=$(kubectl get pods -A --no-headers 2>/dev/null \
    | grep -Eo 'kube-flannel|calico-node|cilium' | sort -u | grep -v "^${MY_CNI_MARK}$" | tr '\n' ' ' || true)
if [ -n "${EXISTING_CNI}" ]; then
    log_error "이미 다른 CNI 가 배포되어 있습니다: ${EXISTING_CNI}"
    log_info  "기존 CNI 를 제거한 뒤 재실행하세요."
    exit 1
fi

step_header "Kubernetes CNI 배포 시작 (${CNI})"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"

step_header "Step 1/1: ${CNI} 배포"
if [ "$CNI" == "flannel" ]; then
    # install a pod network (flannel)
    log_info "flannel 매니페스트 적용..."
    kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
elif [ "$CNI" == "calico" ]; then
    # install a pod network (calico)
    # 매니페스트의 CALICO_IPV4POOL_CIDR (주석 처리, 기본 192.168.0.0/16) 을 kubeadm 의 pod CIDR 로 맞춤
    log_info "calico 매니페스트 적용 (CALICO_IPV4POOL_CIDR=${POD_CIDR})..."
    curl -fsSL https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/calico.yaml \
        | sed -E -e 's|^(\s*)# - name: CALICO_IPV4POOL_CIDR|\1- name: CALICO_IPV4POOL_CIDR|' \
                 -e "s|^(\s*)#   value: \"192.168.0.0/16\"|\1  value: \"${POD_CIDR}\"|" \
        | kubectl apply -f -
elif [ "$CNI" == "cilium" ]; then
    # install a pod network (cilium)
    # cilium 전용 호스트 설정. 이 스크립트는 control-plane 에서 실행되므로 이 노드에만 적용된다.
    # 워커 노드는 cilium 에이전트가 기동하면서 rp_filter / bpffs 를 스스로 처리한다.
    log_info "bpffs 마운트 설정..."
    if ! grep -q "^bpffs" /etc/fstab; then
        echo "bpffs                                     /sys/fs/bpf     bpf     defaults          0       0" | sudo tee -a /etc/fstab
    fi
    sudo mount -a

    log_info "rp_filter 비활성화..."
    if [ ! -f /etc/sysctl.d/99-override_cilium_rp_filter.conf ]; then
        sudo bash -c "echo 'net.ipv4.conf.all.rp_filter = 0' > /etc/sysctl.d/99-override_cilium_rp_filter.conf"
        sudo systemctl restart systemd-sysctl
    fi

    log_info "cilium CLI 다운로드 및 체크섬 검증..."
    CILIUM_CLI_URL="https://github.com/cilium/cilium-cli/releases/latest/download"
    curl -fLO "${CILIUM_CLI_URL}/cilium-linux-amd64.tar.gz"
    curl -fLO "${CILIUM_CLI_URL}/cilium-linux-amd64.tar.gz.sha256sum"
    sha256sum --check cilium-linux-amd64.tar.gz.sha256sum
    log_info "cilium CLI 설치..."
    sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
    rm cilium-linux-amd64.tar.gz cilium-linux-amd64.tar.gz.sha256sum
    log_info "cilium 설치..."
    /usr/local/bin/cilium install
fi

step_header "모든 설치 및 설정이 완료되었습니다"
