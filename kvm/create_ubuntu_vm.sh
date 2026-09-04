#!/bin/bash
###############################################################################
# Ubuntu VM 생성 스크립트 (KVM / cloud-init)
# - Ubuntu cloud image 를 backing file 로 qcow2 디스크 생성
# - cloud-init seed 이미지 생성 후 virt-install 로 VM 정의 및 기동
#
# 실행 방법: bash create_ubuntu_vm.sh   → 항목을 차례로 입력/선택 (터미널 필요)
#   VM 이름 / OS 버전 / vCPU / RAM / 디스크 크기 / 디스크 타입 / cloud-init 폴더 / 네트워크 / virt-type
#
# 주의
# - cloud-init 폴더는 VM 마다 별도로 준비 (meta-data 의 호스트명, network-config 의 IP 가 들어 있으므로 공용 사용 금지)
# - VM 디스크는 /var/lib/libvirt/images 의 원본 cloud image 를 backing file 로 참조함.
#   원본을 삭제/교체하면 그 이미지로 만든 VM 전부가 손상되므로 원본은 건드리지 말 것
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

# ----- 종료 시 정리: 커서 복원 + 실패 시 이번 실행에서 만든 VM 디렉터리 삭제 -----
CREATED_VM_DIR=""      # Step 시작 시 설정, 성공 완료 시 비움
cleanup() {
	local rc=$?
	tput cnorm 2>/dev/null || true
	if [ "${rc}" -ne 0 ] && [ -n "${CREATED_VM_DIR}" ] && [ -d "${CREATED_VM_DIR}" ]; then
		log_warn "실패로 종료 — 생성 중이던 디렉터리를 정리합니다: ${CREATED_VM_DIR}"
		sudo rm -rf "${CREATED_VM_DIR}"
	fi
}
trap cleanup EXIT

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

step_header "Ubuntu VM 생성"

# ----- 1. VM 이름 (같은 이름의 VM 이 있으면 기존 디스크를 덮어쓰게 되므로 여기서 차단) -----
while true; do
	ask_text "VM 이름" ""
	if [ -z "${ASK_RESULT}" ]; then
		log_warn "VM 이름은 필수입니다."
		continue
	fi
	if [[ ! "${ASK_RESULT}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
		log_warn "VM 이름은 영문/숫자로 시작하고 영문·숫자·'.'·'_'·'-' 만 사용할 수 있습니다. (디렉터리명과 도메인명에 그대로 사용됨)"
		continue
	fi
	if sudo virsh -c qemu:///system dominfo "${ASK_RESULT}" >/dev/null 2>&1; then
		log_warn "같은 이름의 VM 이 이미 존재합니다: ${ASK_RESULT}  (삭제: VM=${ASK_RESULT} ./delete_vm.sh)"
		continue
	fi
	break
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

# 호스트 osinfo-db 가 이 os-variant 를 아는지 확인 (모르면 virt-install 이 "Unknown OS name" 으로 실패)
if command -v virt-install >/dev/null 2>&1; then
	if ! virt-install --osinfo list 2>/dev/null | grep -qx "${OS_VARIANT}"; then
		log_error "이 호스트의 osinfo-db 가 '${OS_VARIANT}' 를 인식하지 못합니다."
		log_info  "업데이트 후 재실행하세요:  sudo apt install -y osinfo-db   또는   sudo osinfo-db-import --latest"
		exit 1
	fi
	log_success "os-variant 인식 확인: ${OS_VARIANT}"
fi

# 원본 이미지 가상 크기 → 디스크 크기 하한 (오버레이가 원본보다 작으면 qemu-img 가 거부)
MIN_DISK_GB=""
VIRTUAL_BYTES=$(sudo qemu-img info --output=json "${OS_IMG_PATH}" 2>/dev/null | grep -o '"virtual-size": *[0-9]*' | grep -o '[0-9]*$' || true)
if [ -n "${VIRTUAL_BYTES}" ]; then
	MIN_DISK_GB=$(( (VIRTUAL_BYTES + 1024*1024*1024 - 1) / (1024*1024*1024) ))
fi

# ----- 3~5. vCPU / RAM / 디스크 크기 -----
echo
ask_number "vCPU 수" "2";           VCPUS="${ASK_RESULT}"
ask_number "메모리 (MB)" "2048";    RAM_SIZE="${ASK_RESULT}"
if [ -n "${MIN_DISK_GB}" ]; then
	log_info "디스크 크기는 원본 이미지 가상 크기(${MIN_DISK_GB}GB) 이상이어야 합니다."
fi
while true; do
	ask_number "디스크 크기 (GB)" "128"
	if [ -n "${MIN_DISK_GB}" ] && [ "${ASK_RESULT}" -lt "${MIN_DISK_GB}" ]; then
		log_warn "최소 ${MIN_DISK_GB}GB 이상 입력하세요."
		continue
	fi
	break
done
DISK_SIZE="${ASK_RESULT}"

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

# ----- 7. cloud-init 폴더 (meta-data / user-data / network-config 3개 파일 필수) -----
echo
while true; do
	ask_text "cloud-init 폴더 (meta-data / user-data / network-config 포함)" ""
	if [ -z "${ASK_RESULT}" ]; then
		log_warn "cloud-init 폴더는 필수입니다."
		continue
	fi
	if [ ! -d "${ASK_RESULT}" ]; then
		log_warn "폴더가 없습니다: ${ASK_RESULT}"
		continue
	fi
	MISSING=""
	for f in meta-data user-data network-config; do
		[ -f "${ASK_RESULT}/${f}" ] || MISSING="${MISSING} ${f}"
	done
	if [ -n "${MISSING}" ]; then
		log_warn "폴더에 파일이 없습니다:${MISSING}"
		continue
	fi
	break
done
CLOUD_INIT_FOLDER_PATH="${ASK_RESULT}"
log_success "cloud-init 파일 확인: meta-data / user-data / network-config"

# ----- 8. 네트워크 (libvirt 네트워크 목록에서 선택) -----
echo
mapfile -t NET_LIST < <(sudo virsh -c qemu:///system net-list --all --name 2>/dev/null | grep -v '^$' || true)
if [ "${#NET_LIST[@]}" -eq 0 ]; then
	log_error "libvirt 네트워크가 없습니다. 먼저 네트워크를 정의하세요. (확인: sudo virsh net-list --all)"
	exit 1
fi
log_info "네트워크를 선택하세요"
select_menu "${NET_LIST[@]}"
NETWORK="${NET_LIST[$MENU_SELECTED]}"

# ----- 9. virt-type (/dev/kvm 이 있으면 kvm 을 기본으로) -----
echo
log_info "virt-type 을 선택하세요"
if [ -e /dev/kvm ]; then
	select_menu "$(printf '%-6s %s' "kvm" "하드웨어 가속 (기본, /dev/kvm 있음)")" \
	            "$(printf '%-6s %s' "qemu" "소프트웨어 에뮬레이션 (느림)")"
	if [ "${MENU_SELECTED}" -eq 0 ]; then VIRT_TYPE="kvm"; else VIRT_TYPE="qemu"; fi
else
	select_menu "$(printf '%-6s %s' "qemu" "소프트웨어 에뮬레이션 (기본, /dev/kvm 없음 → 가속 불가)")" \
	            "$(printf '%-6s %s' "kvm" "하드웨어 가속 — 이 호스트에서는 실패할 수 있음")"
	if [ "${MENU_SELECTED}" -eq 0 ]; then VIRT_TYPE="qemu"; else VIRT_TYPE="kvm"; fi
fi

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
if [ ! -d "${STORAGE_POOL_PATH}/${VM_NAME}" ]; then
	sudo mkdir -p "${STORAGE_POOL_PATH}/${VM_NAME}"
	CREATED_VM_DIR="${STORAGE_POOL_PATH}/${VM_NAME}"
else
	log_warn "디렉터리가 이미 있습니다 (이전 실행 잔여물?): ${STORAGE_POOL_PATH}/${VM_NAME} — 실패해도 삭제하지 않습니다."
fi

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
	--memory "${RAM_SIZE}" \
	--vcpus "${VCPUS}" \
	--os-variant "${OS_VARIANT}" \
	--disk path="${BASE_IMG_PATH}",device=disk \
	--disk path="${SEED_PATH}",device=cdrom \
	--import \
	--network "network:${NETWORK}" \
	--noautoconsole \
	--virt-type "${VIRT_TYPE}"

CREATED_VM_DIR=""

# cloud-init 부팅이 끝나 IP 를 받을 때까지 대기 (최대 90초)
log_info "VM 부팅 및 IP 할당 대기 중... (최대 90초)"
VM_IP=""
for _ in $(seq 1 18); do
	VM_IP=$(sudo virsh -c qemu:///system domifaddr "${VM_NAME}" 2>/dev/null \
		| awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -n1 || true)
	[ -n "${VM_IP}" ] && break
	sleep 5
done

step_header "VM 생성이 완료되었습니다 (${VM_NAME})"
if [ -n "${VM_IP}" ]; then
	log_success "IP: ${VM_IP}"
else
	log_warn "아직 IP 가 확인되지 않았습니다. 잠시 후 확인하세요:  sudo virsh domifaddr ${VM_NAME}"
fi
log_info "콘솔 접속:  sudo virsh console ${VM_NAME}   (종료: Ctrl+])"
