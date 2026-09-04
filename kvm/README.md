# KVM

Ubuntu 호스트에 KVM/libvirt 를 설치하고, cloud-init 기반 Ubuntu VM 을 만들고, GPU 를 패스스루하는 스크립트 모음.
모든 스크립트는 **터미널에서 실행**하며 화살표 메뉴(↑/↓ 이동 · Enter 선택 · q 취소)로 항목을 고른다.

## 스크립트

| 스크립트 | 역할 | 재부팅 |
|---|---|---|
| `install-kvm.sh` | qemu/libvirt 설치, 사용자를 libvirt·kvm 그룹에 추가, KVM 가속 확인 | 재로그인 |
| `setup-bridge-network.sh` | 물리 NIC 을 브리지(`br0`)로 묶고 libvirt 네트워크(`br0-net`) 정의 — VM 을 LAN 에 직접 연결할 때 | — |
| `setup-gpu-passthrough-host.sh` | GRUB IOMMU, vfio 모듈, GPU 를 vfio-pci 에 바인딩, (선택) 호스트 NVIDIA 드라이버 블랙리스트 | **필요** |
| `download-ubuntu-image.sh` | Ubuntu cloud image(20.04/22.04/24.04) 다운로드 — `create-vm.sh` 가 없으면 알아서 호출 | — |
| `create-vm.sh` | VM 생성: 이름/OS/vCPU/RAM/디스크/cloud-init(호스트명·IP·계정)/네트워크 입력 → 디스크·seed 생성 → virt-install | — |
| `delete-vm.sh` | VM 삭제: VM 선택 → 범위(전부 / 디스크까지 / 정의만) → 스토리지 풀·디렉터리까지 정리 | — |
| `gpu-passthrough.sh` | GPU 상태 표시, VM 에 GPU attach / detach | — |

## 새 호스트 순서

```bash
./install-kvm.sh                      # 1. 설치 → 로그아웃/로그인
./setup-bridge-network.sh             # 2. 브리지 (NAT 만 쓸 거면 생략, VM 에서 'default' 선택)
./setup-gpu-passthrough-host.sh       # 3. GPU 패스스루 호스트 설정 → sudo reboot → 다시 실행해 '검증만'
./create-vm.sh                        # 4. VM 생성 (이미지 없으면 다운로드 여부 물어봄)
./gpu-passthrough.sh                  # 5. GPU 연결 → VM 재시작
```
게스트 안에서는 `../nvidia/install-nvidia-driver.sh` 로 드라이버 설치.

## 사전 조건 (스크립트 밖)

- BIOS: VT-x/SVM, VT-d/AMD-Vi, Above 4G Decoding 활성화 (GPU 패스스루 시)
- HDD 풀을 쓰려면 `/mnt/data` 에 디스크를 fstab 으로 마운트해 둘 것. 경로 상수: `create-vm.sh` `HDD_POOL_PATH`, `delete-vm.sh` `POOL_ROOTS`
- `setup-bridge-network.sh` 는 SSH 로 쓰는 NIC 을 고르면 적용 순간 끊길 수 있음 → 콘솔(IPMI) 권장. `netplan try` 가 120초 안에 확인 안 되면 자동 원복

## 저장 위치

| 항목 | 경로 |
|---|---|
| 원본 cloud image | `/var/lib/libvirt/images/{noble,jammy,focal}-server-cloudimg-amd64.img` — **삭제/교체 금지** (모든 VM 의 backing file) |
| VM 디스크·seed·cloud-init | `/var/lib/libvirt/images/<VM>/` (ssd) 또는 `/mnt/data/images/<VM>/` (hdd) |
| netplan | `/etc/netplan/60-kvm-bridge.yaml`, 백업 `/etc/netplan/backup-<시각>/` |
| vfio | `/etc/modprobe.d/vfio.conf`, `/etc/modules-load.d/vfio.conf`, `/etc/initramfs-tools/modules` |

## 자주 쓰는 확인 명령

```bash
virsh list --all                       # VM 목록
virsh net-list --all                   # 네트워크 (br0-net active / autostart yes)
virsh pool-list --all                  # 스토리지 풀 (VM 마다 자동 생성됨)
virsh console <VM>                     # 콘솔 접속 (종료 Ctrl+])
./gpu-passthrough.sh                   # GPU 상태 표 (상태만 보기)
```
