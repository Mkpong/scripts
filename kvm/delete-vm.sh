#!/bin/bash
###############################################################################
# VM 삭제 스크립트 (KVM)
# - 목록에서 VM 을 선택하고 삭제 범위를 고름
# - 스토리지 풀은 이름을 가정하지 않고 디스크 경로에서 역조회 (virsh vol-pool)
#   → virt-install 이 자동 생성한 풀 이름이 VM 이름과 달라도(test-1 등) 정확히 삭제
#
# 실행 방법: bash delete-vm.sh   → 메뉴에서 VM / 삭제 범위 선택 (터미널 필요)
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

# ----- 종료 시 커서 복원 -----
trap 'tput cnorm 2>/dev/null || true' EXIT

# ----- 화살표 선택 메뉴 -----
# 사용: select_menu "항목1" "항목2" ...  → 선택한 인덱스(0부터)가 MENU_SELECTED 에 저장. q 면 종료
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
			seq=""
			IFS= read -rsn2 -t 0.2 seq || true
			case "$seq" in
				'[A') idx=$(( (idx - 1 + n) % n )) ;;
				'[B') idx=$(( (idx + 1) % n )) ;;
			esac
		else
			case "$key" in
				k) idx=$(( (idx - 1 + n) % n )) ;;
				j) idx=$(( (idx + 1) % n )) ;;
				"") break ;;                       # Enter
				q|Q) tput cnorm 2>/dev/null || true; echo; log_warn "취소했습니다."; exit 1 ;;
			esac
		fi
		printf '\033[%dA' "$n"                     # 메뉴 줄 수만큼 커서 위로 → 다시 그림
	done

	tput cnorm 2>/dev/null || true
	MENU_SELECTED=$idx
}

# ----- 사전 점검 -----
if [ ! -t 0 ]; then
	log_error "이 스크립트는 터미널에서 실행해야 합니다. (VM 을 메뉴에서 선택)"
	exit 1
fi

VIRSH="sudo virsh -c qemu:///system"

# 디렉터리 삭제를 허용하는 풀 루트 (이 루트 자체나 루트 밖 경로는 절대 삭제하지 않음)
POOL_ROOTS=("/var/lib/libvirt/images" "/mnt/data/images")

step_header "VM 삭제"

# ----- 1. VM 선택 -----
mapfile -t VM_LIST < <(${VIRSH} list --all --name 2>/dev/null | grep -v '^$' || true)
if [ "${#VM_LIST[@]}" -eq 0 ]; then
	log_error "정의된 VM 이 없습니다."
	exit 1
fi
VM_LABELS=()
for vm in "${VM_LIST[@]}"; do
	VM_LABELS+=("$(printf '%-24s %s' "${vm}" "($(${VIRSH} domstate "${vm}" 2>/dev/null || echo '상태 불명'))")")
done
log_info "삭제할 VM 을 선택하세요  (↑/↓ 이동 · Enter 선택 · q 취소)"
select_menu "${VM_LABELS[@]}"
VM="${VM_LIST[$MENU_SELECTED]}"
VM_STATE=$(${VIRSH} domstate "${VM}" 2>/dev/null || echo "unknown")

# ----- 2. 디스크 / 풀 / 디렉터리 수집 -----
# domblklist: Type Device Target Source — 로컬 파일(file)만 대상
mapfile -t DISK_PATHS < <(${VIRSH} domblklist "${VM}" --details 2>/dev/null | awk 'NR>2 && $1=="file" && $4!="-" {print $4}' || true)

POOLS=()          # 볼륨이 속한 풀 (중복 제거)
POOL_DIRS=()      # 삭제 대상 디렉터리 (풀 target path)
SKIPPED_POOLS=()  # 공용 풀이라 건드리지 않는 것
for path in "${DISK_PATHS[@]}"; do
	pool=$(${VIRSH} vol-pool "${path}" 2>/dev/null || true)
	[ -z "${pool}" ] && continue
	# 중복 제거
	dup=0; for p in "${POOLS[@]}" "${SKIPPED_POOLS[@]}"; do [ "$p" = "$pool" ] && dup=1; done
	[ "$dup" -eq 1 ] && continue

	pool_dir=$(${VIRSH} pool-dumpxml "${pool}" 2>/dev/null | sed -nE 's|.*<path>(.*)</path>.*|\1|p' | head -n1 || true)
	# 안전 검사: 루트 풀(default 등) 이거나 허용 루트 밖이면 풀/디렉터리를 건드리지 않음
	safe=0
	for root in "${POOL_ROOTS[@]}"; do
		case "${pool_dir}" in
			"${root}"/*) safe=1 ;;
		esac
	done
	if [ "${pool}" = "default" ] || [ "${safe}" -eq 0 ]; then
		SKIPPED_POOLS+=("${pool}")
		continue
	fi
	POOLS+=("${pool}")
	POOL_DIRS+=("${pool_dir}")
done

# 스냅샷
mapfile -t SNAPSHOTS < <(${VIRSH} snapshot-list "${VM}" --name 2>/dev/null | grep -v '^$' || true)

# ----- 3. 현황 표시 -----
echo
log_info "VM 정보"
log_info "  이름     : ${VM}"
log_info "  상태     : ${VM_STATE}"
if [ "${#DISK_PATHS[@]}" -gt 0 ]; then
	for path in "${DISK_PATHS[@]}"; do log_info "  디스크   : ${path}"; done
else
	log_info "  디스크   : (없음)"
fi
if [ "${#POOLS[@]}" -gt 0 ]; then
	for i in "${!POOLS[@]}"; do log_info "  풀       : ${POOLS[i]}  →  ${POOL_DIRS[i]}"; done
fi
for p in "${SKIPPED_POOLS[@]}"; do log_warn "  풀       : ${p}  (공용 풀 — 풀/디렉터리는 삭제하지 않음)"; done
log_info "  스냅샷   : ${#SNAPSHOTS[@]}개"

# ----- 4. 삭제 범위 선택 -----
echo
log_info "삭제 범위를 선택하세요"
select_menu \
	"전부 삭제        VM 정의 + 디스크 + 스토리지 풀 + 디렉터리(cloud-init 파일 포함)" \
	"디스크까지 삭제  VM 정의 + 디스크  (풀·디렉터리는 유지)" \
	"정의만 삭제      VM 정의만  (디스크 파일은 그대로 남김)"
SCOPE=$MENU_SELECTED

# ----- 5. 확인 -----
echo
log_warn "다음 작업을 수행합니다:"
[ "${VM_STATE}" = "running" ] && log_warn "  - 실행 중인 VM 강제 종료 (destroy)"
[ "${#SNAPSHOTS[@]}" -gt 0 ] && log_warn "  - 스냅샷 ${#SNAPSHOTS[@]}개 삭제"
log_warn "  - VM 정의 삭제 (undefine)"
[ "${SCOPE}" -le 1 ] && log_warn "  - 디스크 볼륨 삭제: ${#DISK_PATHS[@]}개"
if [ "${SCOPE}" -eq 0 ]; then
	for i in "${!POOLS[@]}"; do log_warn "  - 풀 ${POOLS[i]} 삭제 + rm -rf ${POOL_DIRS[i]}"; done
fi
read -rp "$(echo -e "${RED}[FAIL]${NC} 되돌릴 수 없습니다. VM 이름을 다시 입력하면 진행합니다 [${VM}]: ")" CONFIRM
if [ "${CONFIRM}" != "${VM}" ]; then
	log_warn "이름이 일치하지 않아 취소했습니다."
	exit 1
fi

step_header "VM 삭제 시작 (${VM})"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"

# ----- Step 1: 종료 -----
step_header "Step 1/4: VM 종료"
if [ "${VM_STATE}" = "running" ] || [ "${VM_STATE}" = "paused" ]; then
	${VIRSH} destroy "${VM}"
else
	log_info "이미 종료 상태 (${VM_STATE})"
fi

# ----- Step 2: 스냅샷 -----
step_header "Step 2/4: 스냅샷 삭제"
if [ "${#SNAPSHOTS[@]}" -gt 0 ]; then
	for snap in "${SNAPSHOTS[@]}"; do
		log_info "스냅샷 삭제: ${snap}"
		if ! ${VIRSH} snapshot-delete "${VM}" --snapshotname "${snap}"; then
			log_error "스냅샷을 삭제하지 못했습니다: ${snap} (external 스냅샷은 virsh 로 삭제 불가 — 수동 정리 필요)"
			exit 1
		fi
	done
else
	log_info "스냅샷 없음"
fi

# ----- Step 3: 정의 / 디스크 -----
step_header "Step 3/4: VM 정의 삭제"
if [ "${SCOPE}" -le 1 ]; then
	${VIRSH} undefine "${VM}" --remove-all-storage --nvram
else
	${VIRSH} undefine "${VM}" --nvram
	for path in "${DISK_PATHS[@]}"; do log_info "디스크 파일 유지: ${path}"; done
fi

# ----- Step 4: 풀 / 디렉터리 -----
step_header "Step 4/4: 스토리지 풀 및 디렉터리 정리"
if [ "${SCOPE}" -eq 0 ]; then
	if [ "${#POOLS[@]}" -eq 0 ]; then
		log_info "삭제할 전용 풀 없음"
	fi
	for i in "${!POOLS[@]}"; do
		pool="${POOLS[i]}"; dir="${POOL_DIRS[i]}"
		${VIRSH} pool-destroy "${pool}" 2>/dev/null || true     # 이미 비활성이면 무시
		${VIRSH} pool-undefine "${pool}"
		log_success "풀 삭제: ${pool}"
		if [ -d "${dir}" ]; then
			sudo rm -rf "${dir}"
			log_success "디렉터리 삭제: ${dir}"
		fi
	done
else
	log_info "풀·디렉터리 유지 (선택한 범위)"
fi

step_header "VM 삭제가 완료되었습니다 (${VM})"
