#!/bin/bash
###############################################################################
# KVM / libvirt 자동 설치 스크립트
# - qemu-kvm, libvirt, virt-manager, cloud-image-utils 설치
# - 현재 사용자를 libvirt / kvm 그룹에 추가 후 KVM 가속 가능 여부 확인
# - 네트워크(브리지)는 설정하지 않음 → setup-bridge-network.sh
#
# 실행 방법: bash install_kvm.sh   (sudo 로 실행하지 말 것 — 그룹 추가 대상이 root 가 됨)
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
OS_NAME=$(. /etc/os-release; echo "$NAME")
if [ "$OS_NAME" != "Ubuntu" ]; then
	log_error "이 스크립트는 Ubuntu 환경에서만 동작합니다."
	exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
	log_error "root 로 실행하지 마세요. 그룹 추가 대상이 root 가 됩니다. 일반 사용자로 실행하면 필요한 곳에서 sudo 를 요청합니다."
	exit 1
fi
TARGET_USER="$USER"

step_header "KVM / libvirt 자동 설치 시작"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"
log_info "대상 사용자: ${TARGET_USER}"

step_header "Step 1/3: 패키지 설치"
sudo apt-get update
sudo apt-get install -y \
		qemu-kvm \
		libvirt-daemon-system \
		libvirt-clients \
		bridge-utils \
		virt-manager \
		cloud-image-utils

step_header "Step 2/3: 사용자 그룹 추가 (libvirt / kvm)"
sudo adduser "${TARGET_USER}" libvirt
sudo adduser "${TARGET_USER}" kvm
log_info "그룹 변경은 로그아웃 후 다시 로그인해야 적용됩니다."

step_header "Step 3/3: KVM 가속 가능 여부 확인"
cpu_support=$(grep -Ec '(vmx|svm)' /proc/cpuinfo || true)
if lsmod | grep -q '^kvm'; then kvm_loaded=0; else kvm_loaded=1; fi

if [ "$cpu_support" -gt 0 ] && [ "$kvm_loaded" -eq 0 ] && [ -e /dev/kvm ]; then
	log_success "KVM 가속을 사용할 수 있습니다. (/dev/kvm)"
else
	log_warn "KVM 가속을 사용할 수 없습니다."
	if [ "$cpu_support" -eq 0 ]; then
		log_error "- CPU 가 하드웨어 가상화(VT-x/AMD-V)를 지원하지 않거나 BIOS 에서 꺼져 있습니다."
	fi
	if [ "$kvm_loaded" -ne 0 ]; then
		log_error "- kvm 커널 모듈이 로드되어 있지 않습니다. (sudo modprobe kvm_intel 또는 kvm_amd)"
	fi
	if [ ! -e /dev/kvm ]; then
		log_error "- /dev/kvm 이 없습니다."
	fi
	log_info "이 경우 create_ubuntu_vm.sh 에서 virt-type 을 qemu 로 선택하세요 (느림)."
fi

step_header "모든 설치 및 설정이 완료되었습니다"
log_info "다음 단계: VM 을 LAN 에 직접 연결하려면 './setup-bridge-network.sh' 로 브리지 네트워크를 만드세요."
log_info "          NAT 로 충분하면 create_ubuntu_vm.sh 에서 'default' 네트워크를 선택하면 됩니다."
