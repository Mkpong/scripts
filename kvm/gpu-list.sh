#!/usr/bin/env bash
###############################################################################
# GPU 패스스루 상태 확인 스크립트
# - 호스트의 NVIDIA GPU 를 bus 단위로 나열
# - 각 GPU 가 어느 VM 에 연결되어 있고, 현재 사용 중인지 표시
#
# 실행 방법: bash gpu-list.sh
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

step_header "패스스루 NVIDIA GPU 상태"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"
echo

# 현재 running 중인 VM 목록
running_vms="$(virsh list --state-running --name | grep -v '^$' || true)"

is_running() {
    echo "$running_vms" | grep -qx "$1"
}

# 모든 VM의 hostdev bus.func → VM 매핑 수집
attached_map=""
for vm in $(virsh list --all --name | grep -v '^$'); do
    while read -r b f; do
        [ -z "$b" ] && continue
        attached_map+="${b}.${f} ${vm}"$'\n'
    done < <(
        virsh dumpxml "$vm" 2>/dev/null \
        | grep -A4 "<hostdev" \
        | grep "<address domain" \
        | sed -nE "s/.*bus='0x([0-9a-fA-F]+)'.*function='0x([0-9a-fA-F]+)'.*/\1 \2/p"
    )
done

# NVIDIA 장치를 bus 단위로 묶기
# 각 bus 별로: 대표 설명(.0), 그리고 연결된 VM 모음
mapfile -t buses < <(lspci -Dnn -d 10de: | awk '{print $1}' | cut -d: -f2 | sort -u)

for bus in "${buses[@]}"; do
    # 이 bus 의 .0 장치 설명 (대표 이름)
    gpu_line="$(lspci -Dnn -d 10de: | grep -E ":${bus}:00\.0" | head -n1)"
    gpu_desc="$(echo "$gpu_line" | cut -d']' -f2- | sed 's/^: //' | sed 's/ \[10de:[0-9a-f]*\].*//')"
    [ -z "$gpu_desc" ] && gpu_desc="(이름 확인 불가)"

    # 이 bus 에 연결된 모든 VM (function 0,1 통합)
    mapfile -t vms < <(echo "$attached_map" | awk -v b="$bus" '$1 ~ "^"b"\\." {print $2}' | sort -u)

    linked=""
    running_using=""
    for vm in "${vms[@]}"; do
        [ -z "$vm" ] && continue
        linked+="${vm},"
        if is_running "$vm"; then
            running_using+="${vm},"
        fi
    done
    linked="${linked%,}"
    running_using="${running_using%,}"

    echo "── bus=${bus}   ${gpu_desc}"

    if [ -n "$linked" ]; then
        printf "   연결됨  : %s\n" "$linked"
    else
        printf "   연결됨  : (없음)\n"
    fi

    if [ -n "$running_using" ]; then
        printf "   사용중  : %s  ${RED}[사용 불가]${NC}\n" "$running_using"
    else
        printf "   사용중  : X  ${GREEN}[사용 가능]${NC}\n"
    fi
    echo
done

step_header "확인이 완료되었습니다"
log_info "미사용(사용 가능) GPU 의 bus 값을 사용하세요. 예: bus=3b ./attach-gpu.sh <VM이름>"
