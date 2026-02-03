#!/bin/bash
set -e

. /etc/os-release

if [ "$NAME" != "Ubuntu" ]; then
	echo "This Script is for Ubuntu."
	exit 1
fi

echo "[1/2] Add cudnn Package"
wget https://developer.download.nvidia.com/compute/cudnn/9.18.1/local_installers/cudnn-local-repo-ubuntu2204-9.18.1_1.0-1_amd64.deb
sudo dpkg -i cudnn-local-repo-ubuntu2204-9.18.1_1.0-1_amd64.deb
sudo cp /var/cudnn-local-repo-ubuntu2204-9.18.1/cudnn-*-keyring.gpg /usr/share/keyrings/
sudo apt-get update

echo "[2/2] Install cudnn"
sudo apt-get -y install cudnn9-cuda-12