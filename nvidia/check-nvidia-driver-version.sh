#!/bin/bash
set -e

. /etc/os-release

if [ "$NAME" != "Ubuntu" ]; then
	echo "This Script is for Ubuntu."
	exit 1
fi

echo "[1/N] Update apt"
sudo apt-get update

echo "[2/N] Install Ubuntu-Drivers-Common for Check Recommanded Driver Version"
sudo apt-get install -y ubuntu-drivers-common

echo "[3/N] Check your recommended version"
ubuntu-drivers devices

echo "And you Install nvidia-dirver to run [install-nvidia-driver.sh]"
