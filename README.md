# scripts

Ubuntu 기반 GPU 서버·KVM 호스트·Kubernetes 노드를 구성하는 Bash 스크립트 모음.
모든 스크립트는 독립 실행되며, 실행하면 단계별 진행 상황과 다음에 할 일을 출력한다.

```
container/    컨테이너 런타임
  install-docker.sh                Docker CE + containerd
  install-containerd.sh            containerd 만 (Kubernetes 노드용)

nvidia/       GPU 드라이버·툴킷
  check-nvidia-driver-version.sh   권장 드라이버 버전 확인
  install-nvidia-driver.sh         드라이버 설치 (메뉴에서 버전 선택)
  install-cuda.sh                  CUDA
  install-cudnn.sh                 cuDNN
  install-nvidia-container-toolkit.sh   컨테이너에서 GPU 사용 (worker node)

kubernetes/   kubeadm 클러스터            → kubernetes/README.md
  install-kubeadm.sh               kubeadm / kubelet / kubectl (모든 노드)
  initialize-kubeadm.sh            control-plane 초기화
  deploy-cni.sh                    CNI 배포 (flannel / calico / cilium)
  gpu/deploy-nvidia-device-plugin.sh   GPU 노드에 device plugin 배포

kvm/          KVM 호스트·VM·GPU 패스스루   → kvm/README.md
  install-kvm.sh                   qemu / libvirt 설치
  setup-bridge-network.sh          브리지 네트워크 (VM 을 LAN 에 직접 연결)
  setup-gpu-passthrough-host.sh    호스트 VFIO 설정
  download-ubuntu-image.sh         Ubuntu cloud image
  create-vm.sh                     VM 생성
  delete-vm.sh                     VM 삭제
  gpu-passthrough.sh               GPU attach / detach
```

## 용도별 순서

| 용도 | 순서 |
|---|---|
| GPU 서버 (베어메탈) | `nvidia/install-nvidia-driver.sh` → 재부팅 → `install-cuda.sh` → `install-cudnn.sh` |
| Kubernetes 노드 | `container/install-containerd.sh` → `kubernetes/…` (README 참조) |
| Kubernetes GPU 노드 | 드라이버 → `nvidia/install-nvidia-container-toolkit.sh` → `kubernetes/gpu/…` |
| KVM 호스트 + GPU VM | `kvm/…` (README 참조) → VM 안에서 `nvidia/install-nvidia-driver.sh` |

## 공통

- 대상: Ubuntu 22.04 / 24.04, x86_64
- 일반 사용자로 실행하면 필요한 곳에서 `sudo` 를 요청한다. `sudo bash` 로 실행하지 않는다.
- 선택 항목은 화살표 메뉴(↑/↓ 이동 · Enter 선택 · q 취소)로 고른다.
- 인자·환경변수 등 세부 사용법은 각 디렉터리의 README 와 스크립트 상단 주석에 있다.
