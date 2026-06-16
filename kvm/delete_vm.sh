#!/bin/bash

if [ -z "$VM" ]; then
	echo "Error: Not enter vm name"
	exit 1
fi

echo -n "Please enter your sudo password:"

echo "Delete VM: $VM"

# 스냅샷 존재하는지 확인 후 삭제 or 실행 취소
snapshot_count=$(virsh snapshot-list "$VM" --name | wc -l)

if [[ "$snapshot_count" -gt 1 ]]; then
	echo "Snapshots exist.."
	while true; do
		read -p "Do you remove snapshot & delete VM continue? (Y/N): " choice
	
		case "$choice" in
			[Yy]* )
				echo "Delete all snapshot.."
				virsh snapshot-list "$VM" --name | xargs -I {} virsh snapshot-delete "$VM" --snapshotname {}
				break
				;;
			[Nn]* )
				echo "you should delete snapshot for delete vm"
				exit 1
				;;
			* )
				echo "Invalid input. Please enter Y or N."
				;;
		esac
	done
fi

# 삭제 옵션 선택
echo "Choose an option for VM deletion:"
echo "1) Delete the VM and all related files"
echo "2) Delete only the disk image file"
echo "3) Delete only the VM definition"
while true; do
	read -p "Enter your choice (1/2/3): " choice
	case "$choice" in
		1)
			echo "Deleteing VM and all related files.."
			virsh destroy "$VM"
			virsh undefine "$VM" --remove-all-storage
			virsh pool-destroy "$VM"
			virsh pool-undefine "$VM"
			sudo rm -rf "/var/lib/libvirt/images/${VM}"
			break
			;;
		2)
			echo "Delete VM and related image files.."
			virsh destroy "$VM"
			virsh undefine "$VM" --remove-all-storage
			break
			;;
		3)
			echo "Delete only the VM definition"
			virsh destroy "$VM"
			virsh undefine "$VM"
			break
			;;
		*)
			echo "Invalid input. Please enter 1,2,3."
			;;
	esac
done
