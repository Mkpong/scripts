#!/usr/bin/env bash
set -euo pipefail

echo "================ 패스스루 NVIDIA GPU 상태 ================"
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
        printf "   사용중  : %s  \033[1;31m[사용 불가]\033[0m\n" "$running_using"
    else
        printf "   사용중  : X  \033[1;32m[사용 가능]\033[0m\n"
    fi
    echo
done

echo "========================================================="
echo "미사용(사용 가능) GPU의 bus 값을 사용하세요. 예: bus=3b ./gpu-attach.sh <VM이름>"
