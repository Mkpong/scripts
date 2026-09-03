#!/bin/bash
###############################################################################
# VM 삭제 스크립트 (KVM)
# - 스냅샷이 있으면 삭제 여부 확인 후 제거
# - VM 정의 / 디스크 / 관련 파일 삭제 범위를 선택
#
# 실행 방법: VM=<VM이름> bash delete_vm.sh
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
if [ -z "$VM" ]; then
	log_error "VM 이름이 지정되지 않았습니다."
	log_info  "사용법: VM=<VM이름> $0"
	exit 1
fi

echo -n "Please enter your sudo password:"

step_header "VM 삭제 시작 (${VM})"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"

step_header "Step 1/2: 스냅샷 확인"
# 스냅샷 존재하는지 확인 후 삭제 or 실행 취소
snapshot_count=$(virsh snapshot-list "$VM" --name | wc -l)

if [[ "$snapshot_count" -gt 1 ]]; then
	log_warn "스냅샷이 존재합니다."
	while true; do
		read -p "스냅샷을 모두 삭제하고 VM 삭제를 계속할까요? (Y/N): " choice
	
		case "$choice" in
			[Yy]* )
				log_info "모든 스냅샷 삭제..."
				virsh snapshot-list "$VM" --name | xargs -I {} virsh snapshot-delete "$VM" --snapshotname {}
				break
				;;
			[Nn]* )
				log_error "VM 을 삭제하려면 먼저 스냅샷을 삭제해야 합니다."
				exit 1
				;;
			* )
				log_warn "잘못된 입력입니다. Y 또는 N 을 입력하세요."
				;;
		esac
	done
else
	log_success "스냅샷 없음"
fi

step_header "Step 2/2: 삭제 범위 선택"
# 삭제 옵션 선택
log_info "VM 삭제 방식을 선택하세요:"
log_info "  1) VM 과 관련 파일 전부 삭제"
log_info "  2) 디스크 이미지 파일만 삭제"
log_info "  3) VM 정의만 삭제"
while true; do
	read -p "선택 (1/2/3): " choice
	case "$choice" in
		1)
			log_info "VM 과 관련 파일 전부 삭제..."
			virsh destroy "$VM"
			virsh undefine "$VM" --remove-all-storage
			virsh pool-destroy "$VM"
			virsh pool-undefine "$VM"
			sudo rm -rf "/var/lib/libvirt/images/${VM}"
			break
			;;
		2)
			log_info "VM 과 디스크 이미지 파일 삭제..."
			virsh destroy "$VM"
			virsh undefine "$VM" --remove-all-storage
			break
			;;
		3)
			log_info "VM 정의만 삭제..."
			virsh destroy "$VM"
			virsh undefine "$VM"
			break
			;;
		*)
			log_warn "잘못된 입력입니다. 1, 2, 3 중 하나를 입력하세요."
			;;
	esac
done

step_header "VM 삭제가 완료되었습니다 (${VM})"
