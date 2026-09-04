#!/bin/bash
###############################################################################
# GPU 패스스루 관리 스크립트 (KVM)
# - 상태 보기: 호스트 NVIDIA GPU 별 function / 호스트 드라이버 / 연결된 VM / 사용 가능 여부
# - attach   : GPU 선택 → VM 선택 → (VM 종료) → 모든 function hostdev 추가 → (원래 켜져 있었으면 재시작)
# - detach   : VM 선택 → 그 VM 에 붙은 GPU 선택 → 대칭으로 제거
#
# 실행 방법: bash gpu-passthrough.sh   → 메뉴 (터미널 필요)
#
# 전제: BIOS 에서 VT-d/AMD-Vi 활성화 + 커널 파라미터 intel_iommu=on (또는 amd_iommu=on) iommu=pt
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

# ----- 화살표 선택 메뉴 -----
MENU_SELECTED=0
select_menu() {
	local items=("$@") n=$# idx=0 key seq i
	tput civis 2>/dev/null || true
	while true; do
		for ((i = 0; i < n; i++)); do
			if [ "$i" -eq "$idx" ]; then
				printf '  \033[7m ▶ %s \033[0m\n' "${items[i]}"
			else
				printf '     %s\n' "${items[i]}"
			fi
		done
		IFS= read -rsn1 key || true
		if [ "$key" = $'\x1b' ]; then
			seq=""; IFS= read -rsn2 -t 0.2 seq || true
			case "$seq" in
				'[A') idx=$(( (idx - 1 + n) % n )) ;;
				'[B') idx=$(( (idx + 1) % n )) ;;
			esac
		else
			case "$key" in
				k) idx=$(( (idx - 1 + n) % n )) ;;
				j) idx=$(( (idx + 1) % n )) ;;
				"") break ;;
				q|Q) tput cnorm 2>/dev/null || true; echo; log_warn "취소했습니다."; exit 1 ;;
			esac
		fi
		printf '\033[%dA' "$n"
	done
	tput cnorm 2>/dev/null || true
	MENU_SELECTED=$idx
}

# ----- 사전 점검 -----
if [ ! -t 0 ]; then
	log_error "이 스크립트는 터미널에서 실행해야 합니다."
	exit 1
fi
for cmd in lspci virsh python3; do
	command -v "$cmd" >/dev/null 2>&1 || { log_error "'$cmd' 명령을 찾을 수 없습니다."; exit 1; }
done

VIRSH="sudo virsh -c qemu:///system"
SYS_PCI="/sys/bus/pci/devices"
SYS_IOMMU="/sys/kernel/iommu_groups"

# ===================== GPU / VM 상태 수집 =====================
# GPU_BUSES[i]   : "0000:3b"           (domain:bus)
# GPU_NAMES[i]   : 대표 이름 (function 0)
# GPU_FUNCS[i]   : "0000:3b:00.0 0000:3b:00.1"   (그 bus 의 모든 NVIDIA function 주소)
# GPU_DRIVERS[i] : function 0 의 호스트 드라이버 (vfio-pci / nvidia / nouveau / -)
# GPU_GROUP[i]   : IOMMU 그룹 번호 (-: 없음)
# GPU_OTHERS[i]  : 같은 IOMMU 그룹의 다른 bus 장치 수
# ATTACH_MAP     : "0000:3b:00.0 vmname state" 줄들
collect_gpus() {
	GPU_BUSES=(); GPU_NAMES=(); GPU_FUNCS=(); GPU_DRIVERS=(); GPU_GROUP=(); GPU_OTHERS=()
	local line addr bus name i
	SMI_NAMES=$(nvidia-smi --query-gpu=pci.bus_id,name --format=csv,noheader 2>/dev/null | sed 's/^0000//' || true)
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		addr="${line%% *}"                       # 0000:3b:00.0
		bus="${addr%:*}"                         # 0000:3b   (마지막 :slot.func 제거)
		name=$(echo "$line" | sed -E 's/^[^ ]+ [^:]+: //; s/ \[10de:[0-9a-f]+\].*//; s/NVIDIA Corporation //')
		if [ -z "$name" ] || [ "$name" = "Device" ]; then
			# pci.ids 가 오래되면 lspci 는 모델명을 모름 → nvidia-smi(호스트 드라이버 GPU 만) → PCI ID
			name=$(echo "${SMI_NAMES}" | awk -F', ' -v a="$(echo "${addr#0000:}" | tr 'a-f' 'A-F')" 'toupper($1) ~ a"$" {print $2}' | head -n1)
			[ -z "$name" ] && name="Device $(echo "$line" | grep -oE '\[10de:[0-9a-f]+\]' | head -n1 | tr -d '[]')"
		fi
		for i in "${!GPU_BUSES[@]}"; do
			if [ "${GPU_BUSES[i]}" = "$bus" ]; then
				GPU_FUNCS[i]="${GPU_FUNCS[i]} ${addr}"
				continue 2
			fi
		done
		GPU_BUSES+=("$bus"); GPU_NAMES+=("$name"); GPU_FUNCS+=("$addr")
		GPU_DRIVERS+=("$(lspci -k -s "$addr" 2>/dev/null | sed -n 's/.*Kernel driver in use: //p' | head -n1)")
		local grp="-" others=0
		if [ -L "${SYS_PCI}/${addr}/iommu_group" ]; then
			grp=$(basename "$(readlink "${SYS_PCI}/${addr}/iommu_group")")
			others=$(ls "${SYS_IOMMU}/${grp}/devices" 2>/dev/null | grep -vc "^${bus}:" || true)
		fi
		GPU_GROUP+=("$grp"); GPU_OTHERS+=("$others")
	done < <(lspci -Dnn -d 10de: 2>/dev/null | sort)
	for i in "${!GPU_DRIVERS[@]}"; do
		if [ -z "${GPU_DRIVERS[i]}" ]; then GPU_DRIVERS[i]="-"; fi
	done
}

# VM 의 hostdev PCI 주소 목록 (python3 XML 파싱, 출력 순서에 의존하지 않음)
vm_hostdevs() {
	${VIRSH} dumpxml "$1" 2>/dev/null | python3 -c '
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.stdin.read())
for hd in root.iter("hostdev"):
    if hd.get("type") != "pci": continue
    a = hd.find("source/address")
    if a is None: continue
    d, b, s, f = (int(a.get(k, "0"), 16) for k in ("domain", "bus", "slot", "function"))
    print(f"{d:04x}:{b:02x}:{s:02x}.{f:x}")
' 2>/dev/null || true
}

collect_attach_map() {
	ATTACH_MAP=""
	local vm state addr
	while IFS= read -r vm; do
		[ -z "$vm" ] && continue
		state=$(${VIRSH} domstate "$vm" 2>/dev/null || echo unknown)
		while IFS= read -r addr; do
			[ -z "$addr" ] && continue
			ATTACH_MAP+="${addr} ${vm} ${state}"$'\n'
		done < <(vm_hostdevs "$vm")
	done < <(${VIRSH} list --all --name 2>/dev/null | grep -v '^$' || true)
}

# bus 에 연결된 VM 들 → BUS_VMS="vm(state) vm(state)"  /  running 인 VM 이 있으면 GPU_BUSY=1
# (서브셸에서 호출하면 전역이 안 남으므로 $(...) 로 감싸지 말 것)
BUS_VMS=""; GPU_BUSY=0
bus_vms() {
	local bus="$1" out
	out=$(echo "${ATTACH_MAP}" | awk -v b="${bus}:" 'index($1,b)==1 {print $2"("$3")"; if($3=="running") r=1} END{print (r ? "BUSY" : "FREE")}')
	if [ "$(echo "$out" | tail -n1)" = "BUSY" ]; then GPU_BUSY=1; else GPU_BUSY=0; fi
	BUS_VMS=$(echo "$out" | sed '$d' | sort -u | tr '\n' ' ' | sed 's/ $//')
}

# GPU 메뉴 라벨 + 선택 가능 여부 (GPU_SELECTABLE[i], GPU_NOTE[i])
build_gpu_labels() {
	GPU_LABELS=(); GPU_SELECTABLE=(); GPU_NOTE=()
	local i fns vms status note sel
	for i in "${!GPU_BUSES[@]}"; do
		fns=$(echo "${GPU_FUNCS[i]}" | tr ' ' '\n' | sed 's/.*\.//' | tr '\n' ',' | sed 's/,$//')
		bus_vms "${GPU_BUSES[i]}"; vms="${BUS_VMS}"
		sel=1; note=""
		if [ "${GPU_BUSY}" -eq 1 ]; then
			status="${RED}[사용 불가]${NC} ${vms}"; sel=0
		elif [ -n "${vms}" ]; then
			status="${YELLOW}[연결됨]${NC} ${vms}"; note="다른 VM 에 연결되어 있음 (꺼진 상태) — 동시에 켤 수 없음"
		elif [ "${GPU_DRIVERS[i]}" = "nvidia" ] || [ "${GPU_DRIVERS[i]}" = "nouveau" ]; then
			status="${YELLOW}[호스트 사용]${NC}"; note="호스트 ${GPU_DRIVERS[i]} 드라이버가 잡고 있음 — 사용 중인 프로세스가 있으면 VM 시작 실패"
		else
			status="${GREEN}[사용 가능]${NC}"
		fi
		if [ "${GPU_OTHERS[i]}" != "0" ]; then note="${note:+${note} / }IOMMU 그룹 ${GPU_GROUP[i]} 에 다른 장치 ${GPU_OTHERS[i]}개 (함께 넘어감)"; fi
		GPU_LABELS+=("$(printf '%-5s %-26s fn %-6s drv %-9s grp %-3s %b' "${GPU_BUSES[i]#0000:}" "${GPU_NAMES[i]:0:26}" "${fns}" "${GPU_DRIVERS[i]}" "${GPU_GROUP[i]}" "${status}")")
		GPU_SELECTABLE+=("$sel"); GPU_NOTE+=("$note")
	done
}

print_gpu_table() {
	local i
	if [ "${#GPU_BUSES[@]}" -eq 0 ]; then
		log_warn "NVIDIA PCI 장치가 없습니다. (lspci -d 10de:)"
		return
	fi
	printf '  %-5s %-26s %-9s %-13s %-7s %s\n' "bus" "GPU" "function" "host driver" "iommu" "상태"
	for i in "${!GPU_BUSES[@]}"; do
		printf '  %s\n' "${GPU_LABELS[i]}"
		if [ -n "${GPU_NOTE[i]}" ]; then printf '        %b\n' "${YELLOW}↳${NC} ${GPU_NOTE[i]}"; fi
	done
}

# ===================== VM 종료 / 시작 헬퍼 =====================
WAS_RUNNING=0
ensure_shut_off() {
	local vm="$1" state i
	state=$(${VIRSH} domstate "$vm")
	WAS_RUNNING=0
	if [ "$state" = "shut off" ]; then
		log_info "${vm} 은(는) 이미 꺼져 있습니다."
		return 0
	fi
	WAS_RUNNING=1
	log_info "${vm} 종료 요청 (${state})..."
	${VIRSH} shutdown "$vm" >/dev/null
	for i in $(seq 1 60); do
		[ "$(${VIRSH} domstate "$vm")" = "shut off" ] && { log_success "종료 확인 (${i}초)"; return 0; }
		sleep 1
	done
	log_warn "60초 내에 종료되지 않았습니다."
	read -rp "$(echo -e "${YELLOW}[WARN]${NC} 강제 종료(destroy)할까요? 게스트 입장에서는 전원 차단입니다 [y/N] ")" ans
	case "$ans" in
		[Yy]*) ${VIRSH} destroy "$vm"; sleep 2; log_success "강제 종료" ;;
		*) log_warn "취소했습니다. VM 을 직접 종료한 뒤 재실행하세요."; exit 1 ;;
	esac
}

restart_if_needed() {
	if [ "${WAS_RUNNING}" -eq 1 ]; then
		log_info "$1 시작..."
		${VIRSH} start "$1"
	else
		log_info "$1 은(는) 원래 꺼져 있었으므로 시작하지 않습니다.  (시작: sudo virsh start $1)"
	fi
}

hostdev_xml() {
	local addr="$1" d b s f
	d="${addr%%:*}"; b=$(echo "$addr" | cut -d: -f2); s="${addr##*:}"; s="${s%.*}"; f="${addr##*.}"
	cat <<XML
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x${d}' bus='0x${b}' slot='0x${s}' function='0x${f}'/>
  </source>
</hostdev>
XML
}

# ===================== 모드 선택 =====================
step_header "GPU 패스스루 관리"
log_info "GPU / VM 상태 수집 중..."
collect_gpus
collect_attach_map
build_gpu_labels
echo
print_gpu_table
echo

log_info "작업을 선택하세요  (↑/↓ 이동 · Enter 선택 · q 취소)"
select_menu "GPU 연결 (attach)   GPU 선택 → VM 선택" \
            "GPU 해제 (detach)   VM 선택 → GPU 선택" \
            "상태만 보기 (종료)"
MODE=$MENU_SELECTED
[ "$MODE" -eq 2 ] && exit 0

# ===================== attach =====================
if [ "$MODE" -eq 0 ]; then
	# IOMMU
	if [ ! -d "${SYS_IOMMU}" ] || [ -z "$(ls -A "${SYS_IOMMU}" 2>/dev/null)" ]; then
		log_error "IOMMU 가 활성화되어 있지 않습니다. (${SYS_IOMMU} 비어 있음)"
		log_info  "BIOS 에서 VT-d/AMD-Vi 를 켜고, /etc/default/grub 의 GRUB_CMDLINE_LINUX 에 'intel_iommu=on iommu=pt' (AMD: 'amd_iommu=on iommu=pt') 추가 후 update-grub, 재부팅"
		exit 1
	fi
	if [ "${#GPU_BUSES[@]}" -eq 0 ]; then log_error "연결할 NVIDIA GPU 가 없습니다."; exit 1; fi

	# 1. GPU — 선택 가능한 것이 하나도 없으면 메뉴로 들어가지 않음
	SELECTABLE=0
	for i in "${!GPU_SELECTABLE[@]}"; do [ "${GPU_SELECTABLE[i]}" -eq 1 ] && SELECTABLE=$((SELECTABLE + 1)); done
	if [ "${SELECTABLE}" -eq 0 ]; then
		echo
		log_error "연결 가능한 GPU 가 없습니다. 모든 GPU 를 실행 중인 VM 이 사용하고 있습니다."
		log_info  "해당 VM 을 종료하거나, 'GPU 해제 (detach)' 로 먼저 해제하세요."
		exit 1
	fi
	echo
	log_info "연결할 GPU 를 선택하세요  (선택 가능: ${SELECTABLE}개)"
	while true; do
		select_menu "${GPU_LABELS[@]}"
		G=$MENU_SELECTED
		if [ "${GPU_SELECTABLE[G]}" -eq 0 ]; then
			log_warn "실행 중인 VM 이 사용하고 있어 선택할 수 없습니다."
			continue
		fi
		if [ -n "${GPU_NOTE[G]}" ]; then log_warn "${GPU_NOTE[G]}"; fi
		break
	done
	BUS="${GPU_BUSES[G]}"; FUNCS="${GPU_FUNCS[G]}"

	# 호스트 nvidia 드라이버가 잡고 있으면 사용 프로세스 검사
	if [ "${GPU_DRIVERS[G]}" = "nvidia" ] && command -v nvidia-smi >/dev/null 2>&1; then
		PROCS=$(nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader -i "${BUS#0000:}:00.0" 2>/dev/null || true)
		if [ -n "${PROCS}" ]; then
			log_error "이 GPU 를 호스트 프로세스가 사용 중입니다:"; echo "${PROCS}" | sed 's/^/       /'
			exit 1
		fi
	fi

	# 2. VM
	mapfile -t VM_LIST < <(${VIRSH} list --all --name 2>/dev/null | grep -v '^$' || true)
	[ "${#VM_LIST[@]}" -eq 0 ] && { log_error "정의된 VM 이 없습니다."; exit 1; }
	VM_LABELS=()
	for vm in "${VM_LIST[@]}"; do
		st=$(${VIRSH} domstate "$vm" 2>/dev/null || echo unknown)
		gpus=$(echo "${ATTACH_MAP}" | awk -v v="$vm" '$2==v {split($1,a,":"); print a[2]}' | sort -u | tr '\n' ',' | sed 's/,$//')
		VM_LABELS+=("$(printf '%-24s %-12s GPU: %s' "$vm" "($st)" "${gpus:-없음}")")
	done
	echo
	log_info "GPU 를 연결할 VM 을 선택하세요"
	select_menu "${VM_LABELS[@]}"
	VM="${VM_LIST[$MENU_SELECTED]}"

	if vm_hostdevs "$VM" | grep -q "^${BUS}:"; then
		log_success "${BUS#0000:} 은(는) 이미 ${VM} 에 연결되어 있습니다. 할 일이 없습니다."
		exit 0
	fi

	# 3. 요약 / 확인
	echo
	log_info "작업 요약"
	log_info "  GPU      : ${BUS#0000:}  ${GPU_NAMES[G]}"
	log_info "  function : ${FUNCS}"
	log_info "  VM       : ${VM} ($(${VIRSH} domstate "$VM"))"
	if [ "$(${VIRSH} domstate "$VM")" != "shut off" ]; then log_warn "  VM 을 종료한 뒤 연결하고 다시 시작합니다."; fi
	read -rp "$(echo -e "${BLUE}[INFO]${NC} 계속할까요? [Y/n] ")" CONFIRM
	case "${CONFIRM}" in ""|[Yy]*) ;; *) log_warn "취소했습니다."; exit 1 ;; esac

	step_header "GPU attach 시작 (${BUS#0000:} → ${VM})"
	step_header "Step 1/3: VM 종료"
	ensure_shut_off "$VM"

	step_header "Step 2/3: hostdev attach (${FUNCS})"
	for addr in ${FUNCS}; do
		log_info "attach ${addr}"
		hostdev_xml "$addr" | ${VIRSH} attach-device "$VM" /dev/stdin --config
	done

	step_header "Step 3/3: VM 시작 및 검증"
	restart_if_needed "$VM"
	MISSING=""
	for addr in ${FUNCS}; do vm_hostdevs "$VM" | grep -qx "$addr" || MISSING="${MISSING} ${addr}"; done
	if [ -z "${MISSING}" ]; then
		log_success "VM 정의에 반영 확인: ${FUNCS}"
	else
		log_error "VM 정의에 없는 function:${MISSING}"; exit 1
	fi
	step_header "GPU attach 가 완료되었습니다"
	exit 0
fi

# ===================== detach =====================
# 1. GPU 가 붙은 VM 만
mapfile -t VM_LIST < <(echo "${ATTACH_MAP}" | awk 'NF {print $2}' | sort -u)
if [ "${#VM_LIST[@]}" -eq 0 ]; then
	log_warn "GPU 가 연결된 VM 이 없습니다."
	exit 0
fi
VM_LABELS=()
for vm in "${VM_LIST[@]}"; do
	st=$(${VIRSH} domstate "$vm" 2>/dev/null || echo unknown)
	gpus=$(echo "${ATTACH_MAP}" | awk -v v="$vm" '$2==v {split($1,a,":"); print a[2]}' | sort -u | tr '\n' ',' | sed 's/,$//')
	VM_LABELS+=("$(printf '%-24s %-12s GPU: %s' "$vm" "($st)" "$gpus")")
done
echo
log_info "GPU 를 해제할 VM 을 선택하세요"
select_menu "${VM_LABELS[@]}"
VM="${VM_LIST[$MENU_SELECTED]}"

# 2. 그 VM 의 GPU (bus 단위)
mapfile -t VM_BUSES < <(vm_hostdevs "$VM" | awk -F: '{print $1":"$2}' | sort -u)
BUS_LABELS=()
for b in "${VM_BUSES[@]}"; do
	name="(lspci 에 없음)"
	for i in "${!GPU_BUSES[@]}"; do [ "${GPU_BUSES[i]}" = "$b" ] && name="${GPU_NAMES[i]}"; done
	fns=$(vm_hostdevs "$VM" | grep "^${b}:" | sed 's/.*\.//' | tr '\n' ',' | sed 's/,$//')
	BUS_LABELS+=("$(printf '%-5s %-26s fn %s' "${b#0000:}" "${name:0:26}" "$fns")")
done
echo
log_info "해제할 GPU 를 선택하세요"
select_menu "${BUS_LABELS[@]}"
BUS="${VM_BUSES[$MENU_SELECTED]}"
FUNCS=$(vm_hostdevs "$VM" | grep "^${BUS}:" | tr '\n' ' ' | sed 's/ $//')

echo
log_info "작업 요약"
log_info "  VM       : ${VM} ($(${VIRSH} domstate "$VM"))"
log_info "  GPU      : ${BUS#0000:}"
log_info "  function : ${FUNCS}"
if [ "$(${VIRSH} domstate "$VM")" != "shut off" ]; then log_warn "  VM 을 종료한 뒤 해제하고 다시 시작합니다."; fi
read -rp "$(echo -e "${BLUE}[INFO]${NC} 계속할까요? [Y/n] ")" CONFIRM
case "${CONFIRM}" in ""|[Yy]*) ;; *) log_warn "취소했습니다."; exit 1 ;; esac

step_header "GPU detach 시작 (${BUS#0000:} ← ${VM})"
step_header "Step 1/3: VM 종료"
ensure_shut_off "$VM"

step_header "Step 2/3: hostdev detach (${FUNCS})"
for addr in ${FUNCS}; do
	log_info "detach ${addr}"
	hostdev_xml "$addr" | ${VIRSH} detach-device "$VM" /dev/stdin --config
done

step_header "Step 3/3: VM 시작 및 검증"
restart_if_needed "$VM"
if vm_hostdevs "$VM" | grep -q "^${BUS}:"; then
	log_error "VM 정의에 아직 ${BUS#0000:} 이 남아 있습니다."; exit 1
fi
log_success "VM 정의에서 제거 확인"
step_header "GPU detach 가 완료되었습니다"
