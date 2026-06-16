#!/usr/bin/env bash
set -euo pipefail

VM="${1:?사용법: bus=3b $0 <VM이름>}"
: "${bus:?bus 값을 지정하세요. 예: bus=3b $0 <VM이름>}"

bus="${bus#0x}"

# 1) VM 종료
state=$(virsh domstate "$VM")
if [ "$state" = "running" ]; then
    echo "[*] ${VM} 종료 요청..."
    virsh shutdown "$VM"
else
    echo "[*] ${VM} 이미 종료 상태(${state})."
fi

# 2) 종료 확인 (최대 60초 대기, 안 꺼지면 강제 종료)
echo "[*] 종료 대기 중..."
for i in $(seq 1 60); do
    if [ "$(virsh domstate "$VM")" = "shut off" ]; then
        break
    fi
    sleep 1
done

if [ "$(virsh domstate "$VM")" != "shut off" ]; then
    echo "[!] 60초 내 종료 안 됨 → 강제 종료(destroy)."
    virsh destroy "$VM"
    sleep 2
fi
echo "[*] 종료 확인 완료."

# 3) hostdev attach (function 0, 1)
for func in 0 1; do
    echo "[*] attach ${bus}:00.${func} ..."
    virsh attach-device "$VM" /dev/stdin --config <<EOF
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0x${bus}' slot='0x00' function='0x${func}'/>
  </source>
</hostdev>
EOF
done

# 4) VM 시작
echo "[*] ${VM} 시작..."
virsh start "$VM"

echo "완료: ${bus}:00.0, ${bus}:00.1 반영 후 ${VM} 재시작했습니다."
