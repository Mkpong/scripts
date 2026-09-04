#!/bin/bash
###############################################################################
# Ubuntu VM 생성 스크립트 (KVM / cloud-init)
# - Ubuntu cloud image 를 backing file 로 qcow2 디스크 생성
# - cloud-init seed 이미지 생성 후 virt-install 로 VM 정의 및 기동
#
# 실행 방법: bash create_ubuntu_vm.sh   → 항목을 차례로 입력/선택 (터미널 필요)
#   VM 이름 / OS 버전 / vCPU / RAM / 디스크 크기 / 디스크 타입 / cloud-init 폴더 / 네트워크 / virt-type
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

# ----- 텍스트 입력 -----
# 사용: ask_text "질문" "기본값"  → ASK_RESULT 에 저장 (빈 입력이면 기본값)
ASK_RESULT=""
ask_text() {
	local prompt="$1" default="$2" input
	if [ -n "${default}" ]; then
		read -rp "$(echo -e "${BLUE}[INFO]${NC} ${prompt} [${default}]: ")" input
	else
		read -rp "$(echo -e "${BLUE}[INFO]${NC} ${prompt}: ")" input
	fi
	ASK_RESULT="${input:-$default}"
}

# 사용: ask_number "질문" "기본값"  → 양의 정수만 허용
ask_number() {
	while true; do
		ask_text "$1" "$2"
		if [[ "${ASK_RESULT}" =~ ^[1-9][0-9]*$ ]]; then
			return 0
		fi
		log_warn "양의 정수를 입력하세요."
	done
}

# ----- 사전 점검 -----
if [ ! -t 0 ]; then
	log_error "이 스크립트는 터미널에서 실행해야 합니다. (항목을 메뉴에서 선택)"
	exit 1
fi

# Storage path per disk type
SSD_POOL_PATH="/var/lib/libvirt/images"
HDD_POOL_PATH="/mnt/data/images"
DEFAULT_CLOUD_INIT_FOLDER_PATH="/home/boan/kvm/data/ubuntu"   # Needs meta-data, user-data, network-config file

step_header "Ubuntu VM 생성"

# ----- 1. VM 이름 -----
while true; do
	ask_text "VM 이름" ""
	if [ -n "${ASK_RESULT}" ]; then
		break
	fi
	log_warn "VM 이름은 필수입니다."
done
VM_NAME="${ASK_RESULT}"

# ----- 2. OS 버전 (이미지 다운로드 여부 표시) -----
OS_VARIANTS=(ubuntu24.04 ubuntu22.04 ubuntu20.04)
OS_IMAGES=(
	"/var/lib/libvirt/images/noble-server-cloudimg-amd64.img"
	"/var/lib/libvirt/images/jammy-server-cloudimg-amd64.img"
	"/var/lib/libvirt/images/focal-server-cloudimg-amd64.img"
)
OS_LABELS=()
for i in "${!OS_VARIANTS[@]}"; do
	if [ -f "${OS_IMAGES[i]}" ]; then
		OS_LABELS+=("$(printf '%-14s %s' "${OS_VARIANTS[i]}" "이미지 있음")")
	else
		OS_LABELS+=("$(printf '%-14s %s' "${OS_VARIANTS[i]}" "이미지 없음 → ./download-ubuntu-image.sh ${OS_VARIANTS[i]}")")
	fi
done
echo
log_info "OS 버전을 선택하세요  (↑/↓ 이동 · Enter 선택 · q 취소)"
select_menu "${OS_LABELS[@]}"
OS_VARIANT="${OS_VARIANTS[$MENU_SELECTED]}"
OS_IMG_PATH="${OS_IMAGES[$MENU_SELECTED]}"

# OS image existence check
if [ ! -f "${OS_IMG_PATH}" ]; then
	log_error "OS 이미지를 찾을 수 없습니다: ${OS_IMG_PATH}"
	log_info  "먼저 다운로드하세요: ./download-ubuntu-image.sh ${OS_VARIANT}"
	exit 1
fi
log_success "OS 이미지 확인: ${OS_IMG_PATH}"

# ----- 3~5. vCPU / RAM / 디스크 크기 -----
echo
ask_number "vCPU 수" "2";           VCPUS="${ASK_RESULT}"
ask_number "메모리 (MB)" "2048";    RAM_SIZE="${ASK_RESULT}"
ask_number "디스크 크기 (GB)" "128"; DISK_SIZE="${ASK_RESULT}"

# ----- 6. 디스크 타입 → 스토리지 풀 경로 -----
echo
log_info "디스크 타입을 선택하세요"
select_menu "$(printf '%-6s %s' "ssd" "${SSD_POOL_PATH}")" \
            "$(printf '%-6s %s' "hdd" "${HDD_POOL_PATH}")"
if [ "${MENU_SELECTED}" -eq 0 ]; then
	DISK_TYPE="ssd"; STORAGE_POOL_PATH="${SSD_POOL_PATH}"
else
	DISK_TYPE="hdd"; STORAGE_POOL_PATH="${HDD_POOL_PATH}"
fi
log_success "디스크 타입: ${DISK_TYPE} → ${STORAGE_POOL_PATH}"

# ----- 7. cloud-init 폴더 -----
echo
ask_text "cloud-init 폴더 (meta-data / user-data / network-config)" "${DEFAULT_CLOUD_INIT_FOLDER_PATH}"
CLOUD_INIT_FOLDER_PATH="${ASK_RESULT}"

# ----- 8. 네트워크 (libvirt 네트워크 목록에서 선택) -----
echo
mapfile -t NET_LIST < <(sudo virsh -c qemu:///system net-list --all --name 2>/dev/null | grep -v '^$' || true)
NET_LABELS=()
for net in "${NET_LIST[@]}"; do
	NET_LABELS+=("${net}")
done
NET_LABELS+=("직접 입력")
log_info "네트워크를 선택하세요"
select_menu "${NET_LABELS[@]}"
if [ "${MENU_SELECTED}" -lt "${#NET_LIST[@]}" ]; then
	NETWORK="${NET_LIST[$MENU_SELECTED]}"
else
	ask_text "libvirt 네트워크 이름" "br0-net"
	NETWORK="${ASK_RESULT}"
fi

# ----- 9. virt-type -----
echo
if [ -e /dev/kvm ]; then
	KVM_NOTE="가속 사용 가능 (/dev/kvm 있음)"
else
	KVM_NOTE="가속 사용 불가 (/dev/kvm 없음)"
fi
log_info "virt-type 을 선택하세요"
select_menu "$(printf '%-6s %s' "qemu" "소프트웨어 에뮬레이션 (기본)")" \
            "$(printf '%-6s %s' "kvm" "${KVM_NOTE}")"
if [ "${MENU_SELECTED}" -eq 0 ]; then VIRT_TYPE="qemu"; else VIRT_TYPE="kvm"; fi

# ----- 요약 및 확인 -----
echo
log_info "생성 요약"
log_info "  VM 이름       : ${VM_NAME}"
log_info "  OS            : ${OS_VARIANT}"
log_info "  vCPU / RAM    : ${VCPUS} / ${RAM_SIZE}MB"
log_info "  디스크        : ${DISK_SIZE}GB (${DISK_TYPE}) → ${STORAGE_POOL_PATH}/${VM_NAME}"
log_info "  cloud-init    : ${CLOUD_INIT_FOLDER_PATH}"
log_info "  네트워크      : ${NETWORK}"
log_info "  virt-type     : ${VIRT_TYPE}"
read -rp "$(echo -e "${BLUE}[INFO]${NC} 계속할까요? [Y/n] ")" CONFIRM
case "${CONFIRM}" in
	""|[Yy]*) ;;
	*) log_warn "취소했습니다."; exit 1 ;;
esac

step_header "Ubuntu VM 생성 시작 (${VM_NAME})"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"

# sudo mkdir -p "/var/lib/libvirt/images/${VM_NAME}"
sudo mkdir -p "${STORAGE_POOL_PATH}/${VM_NAME}"

# BASE_IMG_PATH="/var/lib/libvirt/images/${VM_NAME}/${VM_NAME}-base.qcow2"
# SEED_PATH="/var/lib/libvirt/images/${VM_NAME}/${VM_NAME}-seed.img"
# CLOUD_INIT_BASE_PATH="/var/lib/libvirt/images/${VM_NAME}"
BASE_IMG_PATH="${STORAGE_POOL_PATH}/${VM_NAME}/${VM_NAME}-base.qcow2"
SEED_PATH="${STORAGE_POOL_PATH}/${VM_NAME}/${VM_NAME}-seed.img"
CLOUD_INIT_BASE_PATH="${STORAGE_POOL_PATH}/${VM_NAME}"

step_header "Step 1/4: cloud-init 파일 복사"
# copy cloud-init folder
sudo cp "${CLOUD_INIT_FOLDER_PATH}"/* "${CLOUD_INIT_BASE_PATH}"

step_header "Step 2/4: base 이미지 생성"
# create base image
sudo qemu-img create -F qcow2 -b "${OS_IMG_PATH}" -f qcow2 "${BASE_IMG_PATH}" "${DISK_SIZE}G"

# base-image info check
sudo qemu-img info "${BASE_IMG_PATH}"

step_header "Step 3/4: cloud-init seed 이미지 생성"
# create cloud-init file
sudo cloud-localds -v --network-config="${CLOUD_INIT_BASE_PATH}/network-config" \
	"${SEED_PATH}" \
	"${CLOUD_INIT_BASE_PATH}/user-data" \
	"${CLOUD_INIT_BASE_PATH}/meta-data"

step_header "Step 4/4: virt-install 로 VM 생성"
sudo virt-install --connect qemu:///system \
	--name "${VM_NAME}" \
	--ram "${RAM_SIZE}" \
	--vcpus "${VCPUS}" \
	--os-variant "${OS_VARIANT}" \
	--disk path="${BASE_IMG_PATH}",device=disk \
	--disk path="${SEED_PATH}",device=cdrom \
	--import \
	--network "network:${NETWORK}" \
	--noautoconsole \
	--virt-type "${VIRT_TYPE}"

step_header "VM 생성이 완료되었습니다 (${VM_NAME})"
