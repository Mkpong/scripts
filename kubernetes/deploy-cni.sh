#!/bin/bash
###############################################################################
# Kubernetes CNI 배포 스크립트
# - flannel / calico / cilium 중 하나를 선택해 pod network 배포
# - kubectl 이 클러스터에 연결되어 있어야 함
#
# 실행 방법: CNI={flannel|calico|cilium} bash deploy-cni.sh
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
# set default
if [ "$CNI" == "" ]; then
    log_error "CNI 값이 지정되지 않았습니다."
    log_info  "사용법: CNI={flannel|calico|cilium} $0"
    exit
fi

# check supported CNI
if [ "$CNI" != "flannel" ] && [ "$CNI" != "calico" ] && [ "$CNI" != "cilium" ]; then
    log_error "지원하지 않는 CNI 입니다: $CNI"
    log_info  "사용법: CNI={flannel|calico|cilium} $0"
    exit
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
    log_info "calico 매니페스트 적용..."
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.0/manifests/calico.yaml
elif [ "$CNI" == "cilium" ]; then
    # install a pod network (cilium)
    log_info "cilium CLI 다운로드 및 설치..."
    curl -LO https://github.com/cilium/cilium-cli/releases/latest/download/cilium-linux-amd64.tar.gz
    sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
    rm cilium-linux-amd64.tar.gz
    log_info "cilium 설치..."
    /usr/local/bin/cilium install
fi

step_header "모든 설치 및 설정이 완료되었습니다"
