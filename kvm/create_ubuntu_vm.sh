#!/bin/bash
###############################################################################
# Ubuntu VM 생성 스크립트 (KVM / cloud-init)
# - Ubuntu cloud image 를 backing file 로 qcow2 디스크 생성
# - cloud-init seed 이미지 생성 후 virt-install 로 VM 정의 및 기동
#
# 실행 방법: bash create_ubuntu_vm.sh --name <VM이름> [옵션]
#   --os-variant  ubuntu24.04 | ubuntu22.04 | ubuntu20.04  (기본: ubuntu24.04)
#   --vcpus       vCPU 수                                  (기본: 2)
#   --ram         메모리(MB)                               (기본: 2048)
#   --disk        디스크 크기(GB)                          (기본: 128)
#   --disk-type   ssd | hdd                                (기본: ssd)
#   --cloud-init  meta-data / user-data / network-config 폴더
#   --network     libvirt 네트워크 이름                     (기본: br0-net)
#   --virt-type   kvm | qemu                               (기본: qemu)
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

VM_NAME=""
OS_VARIANT="ubuntu24.04"
VCPUS="2"
RAM_SIZE="2048"
DISK_SIZE="128"
DISK_TYPE="ssd"   # ssd | hdd
CLOUD_INIT_FOLDER_PATH="" # Needs meta-data, user-data, network-config file
NETWORK="br0-net"
OS_IMG_PATH=""
VIRT_TYPE="qemu"

# Storage path per disk type
SSD_POOL_PATH="/var/lib/libvirt/images"
HDD_POOL_PATH="/mnt/data/images"

while [[ "$#" -gt 0 ]]; do
	case "$1" in
		--name)
			VM_NAME="$2"
			shift 2
			;;
		--os-variant)
			OS_VARIANT="$2"
			shift 2
			;;
		--disk)
			DISK_SIZE="$2"
			shift 2
			;;
		--disk-type)
			DISK_TYPE="$2"
			shift 2
			;;
		--ram)
			RAM_SIZE="$2"
			shift 2
			;;
		--vcpus)
			VCPUS="$2"
			shift 2
			;;
		--cloud-init)
			CLOUD_INIT_FOLDER_PATH="$2"
			shift 2
			;;
		--network)
			NETWORK="$2"
			shift 2
			;;
		--virt-type)
			VIRT_TYPE="$2"
			shift 2
			;;
		*)
			log_error "알 수 없는 옵션입니다: $1"
			exit 1
			;;
	esac
done

# ----- 사전 점검 -----
# Required input value Exception Handling
if [ -z "$VM_NAME" ]; then
	log_error "--name 옵션은 필수입니다."
	exit 1
fi

# If not entered cloud_init set default ubuntu folder path
if [ -z "$CLOUD_INIT_FOLDER_PATH" ]; then
	log_warn "--cloud-init 미지정: 기본 폴더 /home/boan/kvm/data/ubuntu 를 사용합니다."
	CLOUD_INIT_FOLDER_PATH="/home/boan/kvm/data/ubuntu"
fi

# OS Version Check
if [ "$OS_VARIANT" = "ubuntu24.04" ]; then
	OS_IMG_PATH="/var/lib/libvirt/images/noble-server-cloudimg-amd64.img"
elif [ "$OS_VARIANT" = "ubuntu22.04" ]; then
	OS_IMG_PATH="/var/lib/libvirt/images/jammy-server-cloudimg-amd64.img"
elif [ "$OS_VARIANT" = "ubuntu20.04" ]; then
	OS_IMG_PATH="/var/lib/libvirt/images/focal-server-cloudimg-amd64.img"
else
	log_error "지원하지 않는 OS_VARIANT 입니다: ${OS_VARIANT}"
	exit 1
fi

# OS image existence check
if [ ! -f "${OS_IMG_PATH}" ]; then
	log_error "OS 이미지를 찾을 수 없습니다: ${OS_IMG_PATH}"
	log_info  "먼저 다운로드하세요: ./download-ubuntu-image.sh ${OS_VARIANT}"
	exit 1
fi
log_success "OS 이미지 확인: ${OS_IMG_PATH}"

# Disk type check → decide storage pool path
DISK_TYPE="$(printf '%s' "${DISK_TYPE}" | tr '[:upper:]' '[:lower:]')"
if [ "$DISK_TYPE" = "ssd" ]; then
	STORAGE_POOL_PATH="${SSD_POOL_PATH}"
elif [ "$DISK_TYPE" = "hdd" ]; then
	STORAGE_POOL_PATH="${HDD_POOL_PATH}"
else
	log_error "지원하지 않는 DISK_TYPE 입니다: ${DISK_TYPE} ('ssd' 또는 'hdd')"
	exit 1
fi
log_success "디스크 타입: ${DISK_TYPE} → ${STORAGE_POOL_PATH}"

step_header "Ubuntu VM 생성 시작 (${VM_NAME})"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"
log_info "OS: ${OS_VARIANT} / vCPU: ${VCPUS} / RAM: ${RAM_SIZE}MB / Disk: ${DISK_SIZE}GB (${DISK_TYPE})"
log_info "Network: ${NETWORK} / virt-type: ${VIRT_TYPE}"

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
