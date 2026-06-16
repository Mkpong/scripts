#!/bin/bash

echo -n "Please enter your sudo password:"
read -s sudo_pass
echo 

sudo apt-get update

sudo apt-get install qemu-kvm \
		libvirt-daemon-system \
		libvirt-clients \
		bridge-utils \
		virt-manager \
		cloud-image-utils
		
sudo adduser $USER libvirt
sudo adduser $USER libvirt-qemu
sudo adduser $USER kvm

cpu_support=$(egrep -c '(vmx|svm)' /proc/cpuinfo)
echo "$sudo_pass" | sudo -S lsmod | grep -q kvm
kvm_loaded=$?

if [[ "$cpu_support" -gt 0 && "$kvm_loaded" -eq 0 ]]; then
	echo "KVM acceleration is available."
else
	echo "KVM accleration is not available."
	if [[ "$cpu_support" -eq 0 ]]; then
		echo "- Your CPU does not support hardware virtualization"
	fi
	if [[ "$kvm_loaded" -ne 0 ]]; then
		echo "- The KVM module is not loaded"
	fi
	echo "You can use --virt-type qemu options to create vm"
fi
