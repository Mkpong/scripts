#!/bin/bash
set -e
. /etc/os-release

if [ "$NAME" != "Ubuntu" ]; then
    echo "This Script is for Ubuntu"
    exit 1
fi

# Version mapping
declare -A DRIVER_VERSIONS
DRIVER_VERSIONS[550]="550.120"
DRIVER_VERSIONS[595]="595.58.03"

# Parse arguments
DRIVER_KEY="${1:-550}"

if [ -z "${DRIVER_VERSIONS[$DRIVER_KEY]}" ]; then
    echo "Unsupported version: $DRIVER_KEY"
    echo "Usage: $0 [550|595]"
    echo "  550 - ${DRIVER_VERSIONS[550]} (default)"
    echo "  595 - ${DRIVER_VERSIONS[595]} (Blackwell)"
    exit 1
fi

DRIVER_VERSION="${DRIVER_VERSIONS[$DRIVER_KEY]}"

echo "[1/4] Download NVidia Driver Version: $DRIVER_VERSION"
BASE_URL="https://download.nvidia.com/XFree86/Linux-x86_64"
RUN_FILE="NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"
wget "${BASE_URL}/${DRIVER_VERSION}/${RUN_FILE}"
chmod +x "$RUN_FILE"

echo "[2/4] Install required packages for installation"
sudo apt update
sudo apt install -y build-essential gcc make dkms

echo "[3/4] Install Nvidia Driver"
sudo "./${RUN_FILE}" -m=kernel-open

echo "[4/4] Check NVIDIA Driver & Remove Install File"
nvidia-smi
rm "$RUN_FILE"
