#!/bin/bash
set -e

. /etc/os-release

if [ "$NAME" != "Ubuntu" ]; then
	echo "This Script is for Ubuntu."
	exit 1
fi

echo "[1/4] Add CUDA Repository"
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-ubuntu2204.pin
sudo mv cuda-ubuntu2204.pin /etc/apt/preferences.d/cuda-repository-pin-600

sudo apt-key adv --fetch-keys https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/3bf863cc.pub

sudo add-apt-repository \
"deb https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/ /"


echo "[2/4] CUDA Install.."
sudo apt update
sudo apt install -y cuda-12-1


echo "[3/4] Set Environment Variable"
echo 'export PATH=/usr/local/cuda-12.1/bin:$PATH' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH=/usr/local/cuda-12.1/lib64:$LD_LIBRARY_PATH' >> ~/.bashrc
source ~/.bashrc

echo "[4/4] Check CUDA"
nvcc --version