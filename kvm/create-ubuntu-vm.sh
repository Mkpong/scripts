#!/bin/bash
###############################################################################
# Ubuntu VM 생성 스크립트 (KVM / cloud-init)
# - Ubuntu cloud image 를 backing file 로 qcow2 디스크 생성
# - cloud-init seed 이미지 생성 후 virt-install 로 VM 정의 및 기동
#
# 실행 방법: bash create-ubuntu-vm.sh   → 항목을 차례로 입력/선택 (터미널 필요)
#   VM 이름 / OS 버전 / vCPU / RAM / 디스크 크기 / 디스크 타입 / cloud-init(호스트명·IP·계정) / 네트워크 / virt-type
#
# 주의
# - cloud-init 파일(meta-data / user-data / network-config)은 입력값으로 VM 디렉터리에 직접 생성함
#   (user-data 에 비밀번호가 평문으로 들어가므로 600 권한, VM 디렉터리는 root 소유)
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

# ----- 스토리지 경로 상태 조사 -----
# 사용: probe_pool_path <경로>  → PROBE_MOUNT(마운트포인트) / PROBE_SOURCE(장치) / PROBE_AVAIL_H(여유, 사람용) / PROBE_AVAIL_GB
# 경로가 아직 없으면 존재하는 가장 가까운 상위 디렉터리를 기준으로 조사
probe_pool_path() {
	local path="$1" base="$1"
	while [ ! -d "${base}" ] && [ "${base}" != "/" ]; do base="$(dirname "${base}")"; done
	PROBE_MOUNT=$(findmnt -n -o TARGET --target "${base}" 2>/dev/null || echo "/")
	PROBE_SOURCE=$(findmnt -n -o SOURCE --target "${base}" 2>/dev/null | sed 's|^/dev/||' || true)
	PROBE_AVAIL_H=$(df -h --output=avail "${base}" 2>/dev/null | tail -n1 | tr -d ' ' || true)
	PROBE_AVAIL_GB=$(df -BG --output=avail "${base}" 2>/dev/null | tail -n1 | tr -dc '0-9' || true)
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
		log_warn "같은 이름의 VM 이 이미 존재합니다: ${ASK_RESULT}  (삭제: ./delete-vm.sh)"
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

# OS image existence check → 없으면 download-ubuntu-image.sh 로 바로 다운로드
if [ ! -f "${OS_IMG_PATH}" ]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	DOWNLOAD_SCRIPT="${SCRIPT_DIR}/download-ubuntu-image.sh"
	log_warn "OS 이미지가 없습니다: ${OS_IMG_PATH}"
	if [ ! -x "${DOWNLOAD_SCRIPT}" ]; then
		log_error "다운로드 스크립트를 찾을 수 없습니다: ${DOWNLOAD_SCRIPT}"
		exit 1
	fi
	read -rp "$(echo -e "${BLUE}[INFO]${NC} 지금 다운로드할까요? (download-ubuntu-image.sh ${OS_VARIANT}) [Y/n] ")" DL_CONFIRM
	case "${DL_CONFIRM}" in
		""|[Yy]*) ;;
		*) log_warn "취소했습니다."; exit 1 ;;
	esac
	if ! "${DOWNLOAD_SCRIPT}" "${OS_VARIANT}"; then
		log_error "이미지 다운로드에 실패했습니다."
		exit 1
	fi
	if [ ! -f "${OS_IMG_PATH}" ]; then
		log_error "다운로드 후에도 이미지가 없습니다: ${OS_IMG_PATH}"
		exit 1
	fi
	echo
fi
log_success "OS 이미지 확인: ${OS_IMG_PATH}"

# 호스트 osinfo-db 가 이 os-variant 를 아는지 확인 (모르면 virt-install 이 "Unknown OS name" 으로 실패)
if command -v virt-install >/dev/null 2>&1; then
	# 출력 형식: "ubuntu24.04, ubuntunoble" (한 줄에 별칭까지) → 쉼표로 나눠 정확히 일치하는 항목 검사
	if ! virt-install --osinfo list 2>/dev/null | tr ',' '\n' | sed 's/^[[:space:]]*//' | grep -qx "${OS_VARIANT}"; then
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
# ssd: 루트 FS 의 libvirt 기본 경로. hdd: 별도 디스크가 마운트되어 있어야 함 (호스트에서 fstab 으로 미리 준비)
echo
probe_pool_path "${SSD_POOL_PATH}"
SSD_LABEL=$(printf '%-6s %-26s 여유 %-7s (%s)' "ssd" "${SSD_POOL_PATH}" "${PROBE_AVAIL_H:-?}" "${PROBE_SOURCE:-?}")
SSD_AVAIL_GB="${PROBE_AVAIL_GB}"

probe_pool_path "${HDD_POOL_PATH}"
HDD_MOUNTED=1
if [ "${PROBE_MOUNT}" = "/" ]; then
	HDD_MOUNTED=0
	HDD_LABEL=$(printf '%-6s %-26s 마운트 안 됨 — 선택 불가' "hdd" "${HDD_POOL_PATH}")
else
	HDD_LABEL=$(printf '%-6s %-26s 여유 %-7s (%s, %s)' "hdd" "${HDD_POOL_PATH}" "${PROBE_AVAIL_H:-?}" "${PROBE_SOURCE:-?}" "${PROBE_MOUNT}")
fi
HDD_AVAIL_GB="${PROBE_AVAIL_GB}"

log_info "디스크 타입을 선택하세요"
while true; do
	select_menu "${SSD_LABEL}" "${HDD_LABEL}"
	if [ "${MENU_SELECTED}" -eq 0 ]; then
		DISK_TYPE="ssd"; STORAGE_POOL_PATH="${SSD_POOL_PATH}"; POOL_AVAIL_GB="${SSD_AVAIL_GB}"
		break
	fi
	if [ "${HDD_MOUNTED}" -eq 0 ]; then
		log_warn "${HDD_POOL_PATH} 가 속한 파일시스템이 루트(/)입니다. HDD 가 마운트되지 않았습니다."
		log_info "확인: findmnt $(dirname "${HDD_POOL_PATH}")   /   마운트: sudo mount -a (fstab 등록 필요)"
		continue
	fi
	DISK_TYPE="hdd"; STORAGE_POOL_PATH="${HDD_POOL_PATH}"; POOL_AVAIL_GB="${HDD_AVAIL_GB}"
	if [ ! -d "${HDD_POOL_PATH}" ]; then
		sudo mkdir -p "${HDD_POOL_PATH}"
		log_info "디렉터리 생성: ${HDD_POOL_PATH}"
	fi
	break
done
log_success "디스크 타입: ${DISK_TYPE} → ${STORAGE_POOL_PATH}"
if [ -n "${POOL_AVAIL_GB}" ] && [ "${DISK_SIZE}" -gt "${POOL_AVAIL_GB}" ]; then
	log_warn "디스크 크기(${DISK_SIZE}GB)가 현재 여유 공간(${POOL_AVAIL_GB}GB)보다 큽니다. qcow2 는 사용한 만큼만 차지하지만 나중에 공간 부족이 날 수 있습니다."
fi

# ----- 7. cloud-init 정보 (VM 디렉터리에 meta-data / user-data / network-config 생성) -----
echo
log_info "cloud-init 설정 (게스트 OS 초기화)"
ask_text "게스트 호스트명" "${VM_NAME}";  CI_HOSTNAME="${ASK_RESULT}"

log_info "게스트 IP 설정 방식을 선택하세요"
select_menu "고정 IP" "DHCP"
if [ "${MENU_SELECTED}" -eq 0 ]; then
	CI_IP_MODE="static"
	while true; do
		ask_text "게스트 IP (CIDR, 예: 10.10.0.198/24)" ""
		[[ "${ASK_RESULT}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] && break
		log_warn "형식: a.b.c.d/prefix"
	done
	CI_ADDR="${ASK_RESULT}"
	GW_DEFAULT="$(echo "${CI_ADDR%%/*}" | awk -F. '{print $1"."$2"."$3".1"}')"
	ask_text "게이트웨이" "${GW_DEFAULT}";  CI_GW="${ASK_RESULT}"
	ask_text "DNS (공백 구분)" "8.8.8.8";   CI_DNS="${ASK_RESULT}"
else
	CI_IP_MODE="dhcp"
fi
# virt-install 기본(q35 + virtio-net)에서 게스트 NIC 이름은 enp1s0
log_info "게스트 NIC 이름은 VM 안에서 보이는 인터페이스명입니다. 기본 구성(q35 + virtio)이면 enp1s0 — 모르면 Enter"
ask_text "게스트 NIC 이름" "enp1s0";  CI_NIC="${ASK_RESULT}"

echo
ask_text "게스트 계정" "${USER}";  CI_USER="${ASK_RESULT}"
while true; do
	read -rsp "$(echo -e "${BLUE}[INFO]${NC} 게스트 비밀번호: ")" CI_PASS; echo
	read -rsp "$(echo -e "${BLUE}[INFO]${NC} 비밀번호 확인: ")" CI_PASS2; echo
	if [ -z "${CI_PASS}" ]; then log_warn "비밀번호는 비울 수 없습니다."; continue; fi
	if [ "${CI_PASS}" != "${CI_PASS2}" ]; then log_warn "비밀번호가 일치하지 않습니다."; continue; fi
	break
done
SSHKEY_DEFAULT=""
for k in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do [ -f "$k" ] && { SSHKEY_DEFAULT="$k"; break; }; done
ask_text "SSH 공개키 파일 (없으면 빈 값)" "${SSHKEY_DEFAULT}";  CI_SSHKEY_FILE="${ASK_RESULT}"
CI_SSHKEY=""
if [ -n "${CI_SSHKEY_FILE}" ]; then
	if [ ! -f "${CI_SSHKEY_FILE}" ]; then
		log_warn "공개키 파일이 없어 건너뜁니다: ${CI_SSHKEY_FILE}"
	else
		CI_SSHKEY="$(head -n1 "${CI_SSHKEY_FILE}")"
	fi
fi

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
log_info "  호스트명      : ${CI_HOSTNAME}"
if [ "${CI_IP_MODE}" = "static" ]; then
	log_info "  게스트 IP     : ${CI_ADDR}  gw ${CI_GW}  dns ${CI_DNS}  (${CI_NIC})"
else
	log_info "  게스트 IP     : DHCP (${CI_NIC})"
fi
log_info "  게스트 계정   : ${CI_USER}$([ -n "${CI_SSHKEY}" ] && echo '  + SSH 공개키')"
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

step_header "Step 1/4: cloud-init 파일 생성"
# meta-data
printf 'local-hostname: %s\n' "${CI_HOSTNAME}" | sudo tee "${CLOUD_INIT_BASE_PATH}/meta-data" > /dev/null

# network-config (v2)
{
	echo "ethernets:"
	echo "  ${CI_NIC}:"
	if [ "${CI_IP_MODE}" = "static" ]; then
		echo "    addresses:"
		echo "    - ${CI_ADDR}"
		echo "    dhcp4: no"
		echo "    gateway4: ${CI_GW}"
		echo "    nameservers:"
		echo "      addresses:"
		for d in ${CI_DNS}; do echo "      - ${d}"; done
	else
		echo "    dhcp4: yes"
	fi
	echo "version: 2"
} | sudo tee "${CLOUD_INIT_BASE_PATH}/network-config" > /dev/null

# user-data (비밀번호 평문 포함 → 600)
{
	echo "#cloud-config"
	echo "hostname: ${CI_HOSTNAME}"
	echo "manage_etc_hosts: true"
	echo "users:"
	echo "  - name: ${CI_USER}"
	echo "    sudo: ALL=(ALL) NOPASSWD:ALL"
	echo "    groups: users, admin"
	echo "    home: /home/${CI_USER}"
	echo "    shell: /bin/bash"
	echo "    lock_passwd: false"
	echo "    ssh_genkeytypes: ['rsa', 'ed25519']"
	if [ -n "${CI_SSHKEY}" ]; then
		echo "    ssh_authorized_keys:"
		echo "      - ${CI_SSHKEY}"
	else
		echo "    ssh_authorized_keys: []"
	fi
	echo "ssh_pwauth: true"
	echo "chpasswd:"
	echo "  list: |"
	echo "    ${CI_USER}:${CI_PASS}"
	echo "  expire: false"
	echo ""
	echo "runcmd:"
	echo "  - systemctl restart ssh"
} | sudo tee "${CLOUD_INIT_BASE_PATH}/user-data" > /dev/null
sudo chmod 600 "${CLOUD_INIT_BASE_PATH}/user-data"
log_success "생성: ${CLOUD_INIT_BASE_PATH}/{meta-data,network-config,user-data}"

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

# VM 이 running 상태가 될 때까지 대기 (최대 30초). IP 는 cloud-init 고정 설정이므로 조회하지 않음
log_info "VM 기동 대기 중..."
VM_STATE=""
for _ in $(seq 1 30); do
	VM_STATE=$(sudo virsh -c qemu:///system domstate "${VM_NAME}" 2>/dev/null || true)
	[ "${VM_STATE}" = "running" ] && break
	sleep 1
done

step_header "VM 생성이 완료되었습니다 (${VM_NAME})"
if [ "${VM_STATE}" = "running" ]; then
	log_success "VM 실행 중 (cloud-init 초기 설정은 부팅 후 1~2분 더 걸릴 수 있음)"
else
	log_warn "VM 상태가 running 이 아닙니다: ${VM_STATE:-unknown}   확인: sudo virsh domstate ${VM_NAME}"
fi
log_info "콘솔 접속:  sudo virsh console ${VM_NAME}   (종료: Ctrl+])"
