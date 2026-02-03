#!/bin/bash
set -e

. /etc/os-release

DRIVER_VERSION="${DRIVER:-550.120}"


if [ "$NAME" != Ubuntu ]; then
    echo "This Script is for Ubuntu"
    exit 1
fi

echo "[1/4] Download NVidia Driver Version: $DRIVER_VERSION"
BASE_URL="https://download.nvidia.com/XFree86/Linux-x86_64"
RUN_FILE="NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"

wget "${BASE_URL}/${DRIVER_VERSION}/${RUN_FILE}"

chmod +x "$RUN_FILE"

echo "[2/4] Install required packages for installation"
sudo apt update
sudo apt install -y build-essential gcc make dkms

echo "[3/4] Install Nvidia Drvier"

sudo "./${RUN_FILE}" -m=kernel-open

echo "[4/4] Check NVIDIA Driver & Remove Install File"
nvidia-smi

rm "$RUN_FILE"