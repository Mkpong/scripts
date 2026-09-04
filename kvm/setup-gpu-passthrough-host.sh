#!/bin/bash
###############################################################################
# GPU 패스스루 호스트 사전 설정 스크립트 (VFIO)
# - IOMMU 커널 파라미터(intel_iommu / amd_iommu + iommu=pt) → GRUB
# - vfio 모듈 부팅 로드, 선택한 GPU 의 PCI ID 를 vfio-pci 에 바인딩(softdep 포함)
# - (선택) 호스트 nouveau / nvidia 드라이버 블랙리스트
# - update-initramfs / update-grub 후 재부팅 안내. 재부팅 후 다시 실행하면 검증
#
# 실행 방법: bash setup-gpu-passthrough-host.sh   (터미널 필요)
#
# 전제: BIOS 에서 VT-d(Intel) / AMD-Vi(AMD), VT-x/SVM, Above 4G Decoding 활성화
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

trap 'tput cnorm 2>/dev/null || true' EXIT

# ----- 화살표 단일 선택 -----
MENU_SELECTED=0
select_menu() {
	local items=("$@") n=$# idx=0 key seq i
	tput civis 2>/dev/null || true
	while true; do
		for ((i = 0; i < n; i++)); do
			if [ "$i" -eq "$idx" ]; then printf '  \033[7m ▶ %s \033[0m\n' "${items[i]}"; else printf '     %s\n' "${items[i]}"; fi
		done
		IFS= read -rsn1 key || true
		if [ "$key" = $'\x1b' ]; then
			seq=""; IFS= read -rsn2 -t 0.2 seq || true
			case "$seq" in '[A') idx=$(( (idx - 1 + n) % n )) ;; '[B') idx=$(( (idx + 1) % n )) ;; esac
		else
			case "$key" in
				k) idx=$(( (idx - 1 + n) % n )) ;; j) idx=$(( (idx + 1) % n )) ;;
				"") break ;;
				q|Q) tput cnorm 2>/dev/null || true; echo; log_warn "취소했습니다."; exit 1 ;;
			esac
		fi
		printf '\033[%dA' "$n"
	done
	tput cnorm 2>/dev/null || true
	MENU_SELECTED=$idx
}

# ----- 화살표 다중 선택 (Space 토글, Enter 확정) → MULTI_SELECTED[i]=1/0 -----
MULTI_SELECTED=()
select_multi() {
	local items=("$@") n=$# idx=0 key seq i mark
	MULTI_SELECTED=(); for ((i = 0; i < n; i++)); do MULTI_SELECTED+=(1); done   # 기본 전부 선택
	tput civis 2>/dev/null || true
	while true; do
		for ((i = 0; i < n; i++)); do
			if [ "${MULTI_SELECTED[i]}" -eq 1 ]; then mark="[x]"; else mark="[ ]"; fi
			if [ "$i" -eq "$idx" ]; then printf '  \033[7m ▶ %s %s \033[0m\n' "$mark" "${items[i]}"; else printf '     %s %s\n' "$mark" "${items[i]}"; fi
		done
		IFS= read -rsn1 key || true
		if [ "$key" = $'\x1b' ]; then
			seq=""; IFS= read -rsn2 -t 0.2 seq || true
			case "$seq" in '[A') idx=$(( (idx - 1 + n) % n )) ;; '[B') idx=$(( (idx + 1) % n )) ;; esac
		else
			case "$key" in
				k) idx=$(( (idx - 1 + n) % n )) ;; j) idx=$(( (idx + 1) % n )) ;;
				" ") if [ "${MULTI_SELECTED[idx]}" -eq 1 ]; then MULTI_SELECTED[idx]=0; else MULTI_SELECTED[idx]=1; fi ;;
				"") break ;;
				q|Q) tput cnorm 2>/dev/null || true; echo; log_warn "취소했습니다."; exit 1 ;;
			esac
		fi
		printf '\033[%dA' "$n"
	done
	tput cnorm 2>/dev/null || true
}

# ----- 사전 점검 -----
if [ ! -t 0 ]; then log_error "이 스크립트는 터미널에서 실행해야 합니다."; exit 1; fi
OS_NAME=$(. /etc/os-release; echo "$NAME")
if [ "$OS_NAME" != "Ubuntu" ]; then log_error "이 스크립트는 Ubuntu 환경에서만 동작합니다."; exit 1; fi
for cmd in lspci python3 update-grub update-initramfs; do
	command -v "$cmd" >/dev/null 2>&1 || { log_error "'$cmd' 명령을 찾을 수 없습니다."; exit 1; }
done

GRUB_FILE="/etc/default/grub"
MODLOAD_FILE="/etc/modules-load.d/vfio.conf"
MODPROBE_FILE="/etc/modprobe.d/vfio.conf"
BLACKLIST_FILE="/etc/modprobe.d/blacklist-nvidia.conf"
INITRAMFS_MODULES="/etc/initramfs-tools/modules"
SYS_IOMMU="/sys/kernel/iommu_groups"
SYS_PCI="/sys/bus/pci/devices"
ACPI_TABLES="/sys/firmware/acpi/tables"

step_header "GPU 패스스루 호스트 설정"

# ----- 현재 상태 -----
CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
case "${CPU_VENDOR}" in
	GenuineIntel) IOMMU_PARAM="intel_iommu=on"; ACPI_TABLE="DMAR"; BIOS_NAME="VT-d" ;;
	AuthenticAMD) IOMMU_PARAM="amd_iommu=on";   ACPI_TABLE="IVRS"; BIOS_NAME="AMD-Vi" ;;
	*) log_error "알 수 없는 CPU 벤더: ${CPU_VENDOR}"; exit 1 ;;
esac
log_info "CPU            : ${CPU_VENDOR} → ${IOMMU_PARAM} iommu=pt"

if [ -e "${ACPI_TABLES}/${ACPI_TABLE}" ]; then
	log_success "BIOS IOMMU     : ${BIOS_NAME} 활성 (ACPI ${ACPI_TABLE} 테이블 있음)"
else
	log_warn "BIOS IOMMU     : ACPI ${ACPI_TABLE} 테이블 없음 → BIOS 에서 ${BIOS_NAME} 를 켜야 합니다. 설정은 계속 진행할 수 있으나 재부팅 후 IOMMU 가 안 잡힙니다."
fi

IOMMU_GROUPS=$(ls "${SYS_IOMMU}" 2>/dev/null | wc -l || echo 0)
CUR_CMDLINE=$(cat /proc/cmdline)
if [ "${IOMMU_GROUPS}" -gt 0 ]; then
	log_success "커널 IOMMU     : 활성 (그룹 ${IOMMU_GROUPS}개)"
else
	log_warn "커널 IOMMU     : 비활성 (재부팅 전이거나 파라미터 없음)"
fi
echo "${CUR_CMDLINE}" | grep -q 'iommu=pt' && PT_NOTE="iommu=pt 있음" || PT_NOTE="iommu=pt 없음"
log_info "현재 cmdline   : $(echo "${CUR_CMDLINE}" | grep -oE '(intel|amd)_iommu=[^ ]+' | head -n1 || echo '(iommu 파라미터 없음)') / ${PT_NOTE}"

VFIO_LOADED=0; lsmod | grep -q '^vfio_pci' && VFIO_LOADED=1
[ "${VFIO_LOADED}" -eq 1 ] && log_success "vfio_pci 모듈  : 로드됨" || log_info "vfio_pci 모듈  : 미로드"
NVIDIA_LOADED=0; lsmod | grep -qE '^(nvidia|nouveau) ' && NVIDIA_LOADED=1

# ----- NVIDIA 장치 수집 (bus 단위) -----
GPU_BUSES=(); GPU_LABELS=(); GPU_IDS=(); GPU_ADDRS=(); GPU_BOOTVGA=(); GPU_GROUP=(); GPU_OTHERS=()
while IFS= read -r line; do
	[ -z "$line" ] && continue
	addr="${line%% *}"; bus="${addr%:*}"
	id=$(echo "$line" | grep -oE '\[10de:[0-9a-f]+\]' | head -n1 | tr -d '[]')
	name=$(echo "$line" | sed -E 's/^[^ ]+ [^:]+: //; s/ \[10de:[0-9a-f]+\].*//; s/NVIDIA Corporation //')
	[ "$name" = "Device" ] && name="Device ${id}"
	drv=$(lspci -k -s "$addr" 2>/dev/null | sed -n 's/.*Kernel driver in use: //p' | head -n1); drv="${drv:--}"
	found=0
	for i in "${!GPU_BUSES[@]}"; do
		if [ "${GPU_BUSES[i]}" = "$bus" ]; then
			GPU_IDS[i]="${GPU_IDS[i]},${id}"; GPU_ADDRS[i]="${GPU_ADDRS[i]} ${addr}"; found=1
			GPU_LABELS[i]="${GPU_LABELS[i]} +fn${addr##*.}(${drv})"
		fi
	done
	[ "$found" -eq 1 ] && continue
	# 부팅 VGA (호스트 콘솔 출력 중인 GPU) / IOMMU 그룹 / 같은 그룹의 다른 bus 장치 수
	bootvga=0; [ "$(cat "${SYS_PCI}/${addr}/boot_vga" 2>/dev/null)" = "1" ] && bootvga=1
	grp="-"; others=0
	if [ -L "${SYS_PCI}/${addr}/iommu_group" ]; then
		grp=$(basename "$(readlink "${SYS_PCI}/${addr}/iommu_group")")
		others=$(ls "${SYS_IOMMU}/${grp}/devices" 2>/dev/null | grep -vc "^${bus}:" || true)
	fi
	GPU_BUSES+=("$bus"); GPU_IDS+=("$id"); GPU_ADDRS+=("$addr"); GPU_BOOTVGA+=("$bootvga"); GPU_GROUP+=("$grp"); GPU_OTHERS+=("$others")
	GPU_LABELS+=("$(printf '%-5s %-28s %s%s' "${bus#0000:}" "${name:0:28}" "fn0(${drv})" "$([ "$bootvga" -eq 1 ] && echo ' [부팅 VGA]')")")
done < <(lspci -Dnn -d 10de: 2>/dev/null | sort)

echo
if [ "${#GPU_BUSES[@]}" -eq 0 ]; then
	log_error "NVIDIA PCI 장치가 없습니다. (lspci -d 10de:)"
	exit 1
fi
log_info "NVIDIA 장치 ${#GPU_BUSES[@]}개 (bus 단위, 괄호는 현재 호스트 드라이버)"

# ----- 모드 -----
echo
log_info "작업을 선택하세요  (↑/↓ 이동 · Enter 선택 · q 취소)"
select_menu "설정 적용   GRUB / vfio 모듈 / vfio-pci 바인딩 / (선택) 블랙리스트 → 재부팅 필요" \
            "검증만      현재 상태 표시 후 종료"
if [ "${MENU_SELECTED}" -eq 1 ]; then
	echo
	printf '  %-5s %-28s %-8s %-12s %s\n' "bus" "장치" "iommu" "동거 장치" "function(드라이버)"
	ISOLATION_OK=1
	for i in "${!GPU_BUSES[@]}"; do
		fn="${GPU_LABELS[i]#* }"; fn="${fn#* }"; fn="$(echo "${GPU_LABELS[i]}" | sed -E 's/^[^ ]+ +//; s/^.{28} *//')"
		if [ "${GPU_OTHERS[i]}" != "0" ]; then others_txt="${GPU_OTHERS[i]}개 ✗"; ISOLATION_OK=0; else others_txt="없음"; fi
		printf '  %-5s %-28s grp %-4s %-12s %s\n' "${GPU_BUSES[i]#0000:}" "$(echo "${GPU_LABELS[i]}" | sed -E 's/^[^ ]+ +//' | cut -c1-28)" "${GPU_GROUP[i]}" "${others_txt}" "${fn}"
	done
	echo
	if [ "${IOMMU_GROUPS}" -eq 0 ]; then
		log_warn "커널 IOMMU 가 비활성입니다. '설정 적용' 후 재부팅하세요. (BIOS ${BIOS_NAME} 확인)"
	elif [ "${VFIO_LOADED}" -eq 0 ]; then
		log_warn "vfio_pci 가 로드되지 않았습니다. '설정 적용' 후 재부팅하세요."
	elif [ "${ISOLATION_OK}" -eq 0 ]; then
		log_warn "IOMMU 그룹에 GPU 외 장치가 섞인 GPU 가 있습니다. 그 그룹은 통째로 넘겨야 하므로 패스스루가 실패할 수 있습니다. (다른 PCIe 슬롯 사용 권장, ACS override 는 비권장)"
	else
		log_success "IOMMU 활성 + vfio_pci 로드 + 그룹 격리 OK. 위 표에서 대상 GPU 의 드라이버가 vfio-pci 면 준비 완료입니다."
	fi
	exit 0
fi

# ----- 1. 패스스루할 GPU 선택 (다중) -----
echo
log_info "vfio-pci 에 바인딩할 GPU 를 선택하세요  (Space 토글 · Enter 확정 · 기본: 전부)"
select_multi "${GPU_LABELS[@]}"
SEL_BUSES=(); SEL_IDS=""
for i in "${!GPU_BUSES[@]}"; do
	if [ "${MULTI_SELECTED[i]}" -eq 1 ]; then
		SEL_BUSES+=("${GPU_BUSES[i]}")
		SEL_IDS="${SEL_IDS},${GPU_IDS[i]}"
	fi
done
if [ "${#SEL_BUSES[@]}" -eq 0 ]; then log_error "선택된 GPU 가 없습니다."; exit 1; fi
for i in "${!GPU_BUSES[@]}"; do
	if [ "${MULTI_SELECTED[i]}" -eq 1 ] && [ "${GPU_BOOTVGA[i]}" -eq 1 ]; then
		log_warn "${GPU_BUSES[i]#0000:} 은(는) 호스트 콘솔 출력에 쓰이는 부팅 VGA 입니다. vfio-pci 로 넘기면 재부팅 후 모니터 화면이 나오지 않습니다 (SSH/BMC 는 가능)."
		read -rp "$(echo -e "${YELLOW}[WARN]${NC} 그래도 진행할까요? [y/N] ")" ans
		case "$ans" in [Yy]*) ;; *) log_warn "취소했습니다."; exit 1 ;; esac
	fi
done
VFIO_IDS=$(echo "${SEL_IDS#,}" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')

# 같은 ID 인데 선택 안 된 장치가 있으면 경고 (ID 바인딩은 같은 모델을 전부 잡음)
for i in "${!GPU_BUSES[@]}"; do
	[ "${MULTI_SELECTED[i]}" -eq 1 ] && continue
	for id in $(echo "${GPU_IDS[i]}" | tr ',' ' '); do
		if echo ",${VFIO_IDS}," | grep -q ",${id},"; then
			log_warn "${GPU_BUSES[i]#0000:} 은(는) 선택하지 않았지만 같은 PCI ID(${id})라 vfio-pci 에 함께 바인딩됩니다. 호스트에서 쓰려면 주소별 driver_override 가 필요합니다."
			break
		fi
	done
done

# ----- 2. 블랙리스트 여부 -----
echo
if [ "${NVIDIA_LOADED}" -eq 1 ]; then
	log_warn "호스트에 nvidia/nouveau 드라이버가 로드되어 있습니다."
fi
log_info "호스트 NVIDIA 드라이버 처리를 선택하세요"
select_menu "블랙리스트    호스트에서는 NVIDIA GPU 를 쓰지 않음 (nouveau/nvidia 모듈 차단 — 패스스루 전용 호스트 권장)" \
            "유지          호스트 드라이버는 그대로 두고 vfio-pci softdep 만으로 우선순위 처리"
BLACKLIST=$([ "${MENU_SELECTED}" -eq 0 ] && echo 1 || echo 0)

# ----- 3. 요약 / 확인 -----
GRUB_ADD=""
for tok in "${IOMMU_PARAM}" "iommu=pt"; do
	sudo grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "${GRUB_FILE}" | grep -q -- "${tok}" || GRUB_ADD="${GRUB_ADD} ${tok}"
done
GRUB_ADD="${GRUB_ADD# }"
echo
log_info "설정 요약"
if [ -n "${GRUB_ADD}" ]; then
	log_info "  GRUB              : ${GRUB_FILE}  추가 → \"${GRUB_ADD}\""
else
	log_info "  GRUB              : ${GRUB_FILE}  (이미 설정됨, 변경 없음)"
fi
log_info "  vfio 모듈         : ${MODLOAD_FILE}  (vfio vfio_iommu_type1 vfio_pci)"
log_info "  vfio-pci ids      : ${MODPROBE_FILE}  ids=${VFIO_IDS}"
log_info "  initramfs 모듈    : ${INITRAMFS_MODULES}  (vfio_pci 를 initramfs 단계에서 먼저 로드)"
log_info "  대상 GPU          : $(printf '%s ' "${SEL_BUSES[@]#0000:}")"
[ "${BLACKLIST}" -eq 1 ] && log_info "  블랙리스트        : ${BLACKLIST_FILE}  (nouveau nvidia nvidia_drm nvidia_modeset nvidia_uvm)" || log_info "  블랙리스트        : 안 함"
log_info "  이후              : update-initramfs -u -k all → update-grub → 재부팅 필요"
read -rp "$(echo -e "${YELLOW}[WARN]${NC} 부팅 설정을 변경합니다. 계속하려면 'yes' 입력: ")" CONFIRM
[ "${CONFIRM}" = "yes" ] || { log_warn "취소했습니다."; exit 1; }

step_header "GPU 패스스루 호스트 설정 시작"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"
TS=$(date '+%Y%m%d%H%M%S')

# ----- Step 1: GRUB -----
step_header "Step 1/5: GRUB 커널 파라미터"
if [ -n "${GRUB_ADD}" ]; then
	sudo cp "${GRUB_FILE}" "${GRUB_FILE}.bak.${TS}"
	log_info "백업: ${GRUB_FILE}.bak.${TS}"
	sudo python3 - "${GRUB_FILE}" ${GRUB_ADD} <<'PYGRUB'
import sys, re
path, tokens = sys.argv[1], sys.argv[2:]
lines = open(path).read().splitlines()
done = False
for i, l in enumerate(lines):
    m = re.match(r'^GRUB_CMDLINE_LINUX_DEFAULT=(["\']?)(.*)\1\s*$', l)
    if m:
        q, val = m.group(1) or '"', m.group(2)
        cur = val.split()
        for t in tokens:
            if t not in cur: cur.append(t)
        lines[i] = f'GRUB_CMDLINE_LINUX_DEFAULT={q}{" ".join(cur)}{q}'
        done = True
        break
if not done:
    lines.append(f'GRUB_CMDLINE_LINUX_DEFAULT="{" ".join(tokens)}"')
open(path, "w").write("\n".join(lines) + "\n")
print("       " + [l for l in lines if l.startswith("GRUB_CMDLINE_LINUX_DEFAULT=")][0])
PYGRUB
	log_success "GRUB 파라미터 추가: ${GRUB_ADD}"
else
	log_info "이미 설정되어 있음 → 변경 없음"
fi

# ----- Step 2: vfio 모듈 -----
step_header "Step 2/5: vfio 모듈 부팅 로드"
printf 'vfio\nvfio_iommu_type1\nvfio_pci\n' | sudo tee "${MODLOAD_FILE}" > /dev/null
log_success "작성: ${MODLOAD_FILE}"

# ----- Step 3: vfio-pci 바인딩 -----
step_header "Step 3/5: vfio-pci 바인딩 (${VFIO_IDS})"
[ -f "${MODPROBE_FILE}" ] && { sudo cp "${MODPROBE_FILE}" "${MODPROBE_FILE}.bak.${TS}"; log_info "백업: ${MODPROBE_FILE}.bak.${TS}"; }
{
	echo "# generated by setup-gpu-passthrough-host.sh — GPU: $(printf '%s ' "${SEL_BUSES[@]#0000:}")"
	echo "options vfio-pci ids=${VFIO_IDS}"
	echo "softdep nvidia pre: vfio-pci"
	echo "softdep nouveau pre: vfio-pci"
	echo "softdep snd_hda_intel pre: vfio-pci"
} | sudo tee "${MODPROBE_FILE}" > /dev/null
log_success "작성: ${MODPROBE_FILE}"

# initramfs 단계에서 vfio_pci 가 먼저 장치를 잡도록 (호스트 드라이버가 initramfs 안에서 먼저 로드되는 경우 대비)
[ -f "${INITRAMFS_MODULES}" ] && sudo cp "${INITRAMFS_MODULES}" "${INITRAMFS_MODULES}.bak.${TS}"
sudo sed -i '/^vfio/d' "${INITRAMFS_MODULES}" 2>/dev/null || true
printf 'vfio\nvfio_iommu_type1\nvfio_pci ids=%s\n' "${VFIO_IDS}" | sudo tee -a "${INITRAMFS_MODULES}" > /dev/null
log_success "작성: ${INITRAMFS_MODULES}"

# ----- Step 4: 블랙리스트 -----
step_header "Step 4/5: 호스트 NVIDIA 드라이버 블랙리스트"
if [ "${BLACKLIST}" -eq 1 ]; then
	printf 'blacklist nouveau\noptions nouveau modeset=0\nblacklist nvidia\nblacklist nvidia_drm\nblacklist nvidia_modeset\nblacklist nvidia_uvm\n' | sudo tee "${BLACKLIST_FILE}" > /dev/null
	log_success "작성: ${BLACKLIST_FILE}"
	if systemctl is-enabled nvidia-persistenced >/dev/null 2>&1; then
		sudo systemctl disable nvidia-persistenced >/dev/null 2>&1 || true
		log_info "nvidia-persistenced 비활성화"
	fi
else
	log_info "건너뜀"
fi

# ----- Step 5: 반영 -----
step_header "Step 5/5: initramfs / GRUB 갱신"
sudo update-initramfs -u -k all
sudo update-grub

step_header "설정이 완료되었습니다 — 재부팅이 필요합니다"
log_warn "sudo reboot 후 이 스크립트를 다시 실행해 '검증만' 으로 확인하세요."
log_info "확인 항목: 커널 IOMMU 활성(그룹 > 0), 대상 GPU 의 드라이버가 vfio-pci"
