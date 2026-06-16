#!/bin/bash

VM_NAME=""
OS_VARIANT="ubuntu24.04"
VCPUS="2"
RAM_SIZE="2048"
DISK_SIZE="128"
CLOUD_INIT_FOLDER_PATH="" # Needs meta-data, user-data, network-config file
NETWORK="br0-net"
OS_IMG_PATH=""
VIRT_TYPE="qemu"

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
			echo "Unknown option: $1"
			echo "Use --help for usage information"
			exit 1
			;;
	esac
done

# Required input value Exception Handling
if [ -z "$VM_NAME" ]; then
	echo "Error: --name is empty. name field is a required value and must be provided."
	exit 1
fi

# If not entered cloud_init set default ubuntu folder path
if [ -z "$CLOUD_INIT_FOLDER_PATH" ]; then
	echo "Not entered cloud_init: set default ubuntu folder"
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
	echo "Unsupported OS_VARIANT: ${OS_VARIANT}"
	exit 1
fi

STORAGE_POOL_PATH="/mnt/data/images"

# sudo mkdir -p "/var/lib/libvirt/images/${VM_NAME}"
sudo mkdir -p "${STORAGE_POOL_PATH}/${VM_NAME}"

# BASE_IMG_PATH="/var/lib/libvirt/images/${VM_NAME}/${VM_NAME}-base.qcow2"
# SEED_PATH="/var/lib/libvirt/images/${VM_NAME}/${VM_NAME}-seed.img"
# CLOUD_INIT_BASE_PATH="/var/lib/libvirt/images/${VM_NAME}"

BASE_IMG_PATH="${STORAGE_POOL_PATH}/${VM_NAME}/${VM_NAME}-base.qcow2"
SEED_PATH="${STORAGE_POOL_PATH}/${VM_NAME}/${VM_NAME}-seed.img"
CLOUD_INIT_BASE_PATH="${STORAGE_POOL_PATH}/${VM_NAME}"

# copy cloud-init folder
sudo cp "${CLOUD_INIT_FOLDER_PATH}"/* "${CLOUD_INIT_BASE_PATH}"

# create base image
sudo qemu-img create -F qcow2 -b "${OS_IMG_PATH}" -f qcow2 "${BASE_IMG_PATH}" "${DISK_SIZE}G"

# base-image info check
sudo qemu-img info "${BASE_IMG_PATH}"

# create cloud-init file
sudo cloud-localds -v --network-config="${CLOUD_INIT_BASE_PATH}/network-config" \
	"${SEED_PATH}" \
	"${CLOUD_INIT_BASE_PATH}/user-data" \
	"${CLOUD_INIT_BASE_PATH}/meta-data"

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
