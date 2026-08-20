#!/bin/bash
set -e

. /etc/os-release
if [ "$NAME" != "Ubuntu" ]; then
    echo "This script is for Ubuntu."
    exit 1
fi

echo "[1/8] Update apt"
sudo apt-get update

echo "[2/8] Install dependencies"
sudo apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

echo "[3/8] Add Docker GPG key"
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "[4/8] Add Docker repository"
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $VERSION_CODENAME stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "[5/8] Install Docker (latest stable)"
sudo apt-get update
sudo apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

echo "[6/8] Configure Docker daemon"
sudo mkdir -p /etc/docker
cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

echo "[7/8] Configure containerd (CRI enable + systemd cgroup)"
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

echo "[8/8] Start Docker"
sudo systemctl daemon-reexec
sudo systemctl restart docker
sudo systemctl enable docker

echo "Add user to docker group"
sudo usermod -aG docker $USER

echo "Docker installation completed. Please log out and log back in."
