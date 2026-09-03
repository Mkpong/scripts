# Kubernetes (kubeadm)

Ubuntu 노드에 kubeadm 기반 클러스터를 구성하는 스크립트 모음.
사전 조건: containerd 가 설치되어 있어야 함 → `../container/install-containerd.sh` 또는 `../container/install-docker.sh`

## 스크립트

| 스크립트 | 실행 위치 | 역할 |
|---|---|---|
| `install-kubeadm.sh` | **모든 노드** | kubeadm / kubelet / kubectl 설치, swap 해제, 커널 모듈·sysctl 설정 |
| `initialize-kubeadm.sh` | control-plane | `kubeadm init`, kubeconfig 설정, 단일 노드면 control-plane taint 제거 |
| `deploy-cni.sh` | control-plane | pod 네트워크(CNI) 배포 |
| `gpu/deploy_nvidia_device_plugin.sh` | control-plane | GPU 노드에 label 부여 후 NVIDIA device plugin 배포 |

## 사용 순서

### 단일 노드
```bash
./install-kubeadm.sh
./initialize-kubeadm.sh
CNI=calico ./deploy-cni.sh
```

### 멀티 노드
control-plane:
```bash
./install-kubeadm.sh
MULTI=true ./initialize-kubeadm.sh
CNI=calico ./deploy-cni.sh
kubeadm token create --print-join-command     # 워커용 join 명령 출력 (24시간 유효)
```
워커 (각 노드에서):
```bash
./install-kubeadm.sh
sudo kubeadm join <위에서 출력된 명령>
```

### GPU 노드가 있을 때
워커에서 NVIDIA driver + `../nvidia/install-nvidia-container-toolkit.sh` 설치 후, control-plane 에서:
```bash
./gpu/deploy_nvidia_device_plugin.sh --node <gpu-node-name> [--node ...]
```

## 옵션 (환경변수)

| 변수 | 스크립트 | 값 | 기본 |
|---|---|---|---|
| `VERSION` | `install-kubeadm.sh` | `1.33` (최신 patch) / `1.33.0` / `1.33.2-1.1` | 최신 stable |
| `MULTI` | `initialize-kubeadm.sh` | `true` = 워커 있음, control-plane taint 유지 | `false` |
| `CNI` | `deploy-cni.sh` | `flannel` / `calico` / `cilium` | 필수 |

pod CIDR 은 `initialize-kubeadm.sh` 와 `deploy-cni.sh` 안의 `POD_CIDR` 상수(`10.244.0.0/16`)로 고정. 바꾸려면 두 파일을 같이 수정.

## 재초기화

```bash
sudo kubeadm reset -f
rm ~/k8s_init.log          # initialize-kubeadm.sh 재실행 가드 해제
./initialize-kubeadm.sh    # 기존 ~/.kube/config 는 자동 백업 후 교체
```
