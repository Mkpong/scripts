#!/bin/bash
###############################################################################
# KVM / libvirt 자동 설치 스크립트
# - qemu-kvm, libvirt, virt-manager, cloud-image-utils 설치
# - 현재 사용자를 libvirt / kvm 그룹에 추가 후 KVM 가속 가능 여부 확인
#
# 실행 방법: bash install_kvm.sh
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

step_header "KVM / libvirt 자동 설치 시작"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"

echo -n "sudo 비밀번호를 입력하세요: "
read -s sudo_pass
echo 

step_header "Step 1/3: 패키지 설치"
sudo apt-get update

sudo apt-get install qemu-kvm \
		libvirt-daemon-system \
		libvirt-clients \
		bridge-utils \
		virt-manager \
		cloud-image-utils
		
step_header "Step 2/3: 사용자 그룹 추가 (libvirt / libvirt-qemu / kvm)"
sudo adduser $USER libvirt
sudo adduser $USER libvirt-qemu
sudo adduser $USER kvm

step_header "Step 3/3: KVM 가속 가능 여부 확인"
cpu_support=$(egrep -c '(vmx|svm)' /proc/cpuinfo)
echo "$sudo_pass" | sudo -S lsmod | grep -q kvm
kvm_loaded=$?

if [[ "$cpu_support" -gt 0 && "$kvm_loaded" -eq 0 ]]; then
	log_success "KVM 가속을 사용할 수 있습니다."
else
	log_warn "KVM 가속을 사용할 수 없습니다."
	if [[ "$cpu_support" -eq 0 ]]; then
		log_error "- CPU 가 하드웨어 가상화를 지원하지 않습니다."
	fi
	if [[ "$kvm_loaded" -ne 0 ]]; then
		log_error "- KVM 모듈이 로드되어 있지 않습니다."
	fi
	log_info "VM 생성 시 --virt-type qemu 옵션을 사용하세요."
fi

step_header "모든 설치 및 설정이 완료되었습니다"
