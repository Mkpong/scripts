#!/usr/bin/env bash
###############################################################################
# GPU 패스스루 detach 스크립트
# - VM 을 종료한 뒤 지정한 bus 의 PCI 장치(function 0, 1)를 hostdev 에서 제거
# - 반영 후 VM 재시작
#
# 실행 방법: bus=<bus> bash detach-gpu.sh <VM이름>
#   예: bus=17 ./detach-gpu.sh myvm   (bus 값은 gpu-list.sh 로 확인)
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
VM="${1:?사용법: bus=17 $0 <VM이름>}"
: "${bus:?bus 값을 지정하세요. 예: bus=17 $0 <VM이름>}"

bus="${bus#0x}"

step_header "GPU detach 시작 (${VM} → bus=${bus})"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"

step_header "Step 1/3: VM 종료"
# 1) VM 종료
state=$(virsh domstate "$VM")
if [ "$state" = "running" ]; then
    log_info "${VM} 종료 요청..."
    virsh shutdown "$VM"
else
    log_info "${VM} 이미 종료 상태(${state})."
fi

# 2) 종료 확인 (최대 60초 대기, 안 꺼지면 강제 종료)
log_info "종료 대기 중..."
for i in $(seq 1 60); do
    if [ "$(virsh domstate "$VM")" = "shut off" ]; then
        break
    fi
    sleep 1
done

if [ "$(virsh domstate "$VM")" != "shut off" ]; then
    log_warn "60초 내 종료 안 됨 → 강제 종료(destroy)."
    virsh destroy "$VM"
    sleep 2
fi
log_success "종료 확인 완료."

step_header "Step 2/3: hostdev detach (function 0, 1)"
# 3) hostdev detach (function 0, 1)
for func in 0 1; do
    log_info "detach ${bus}:00.${func} ..."
    virsh detach-device "$VM" /dev/stdin --config <<HOSTDEV
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0x${bus}' slot='0x00' function='0x${func}'/>
  </source>
</hostdev>
HOSTDEV
done

step_header "Step 3/3: VM 시작"
# 4) VM 시작
log_info "${VM} 시작..."
virsh start "$VM"

step_header "GPU detach 가 완료되었습니다"
log_success "${bus}:00.0, ${bus}:00.1 제거 후 ${VM} 재시작했습니다."
