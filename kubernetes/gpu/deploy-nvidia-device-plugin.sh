#!/bin/bash
###############################################################################
# NVIDIA Device Plugin 배포 스크립트
# - GPU 노드에 label 부여 후 nvidia-device-plugin DaemonSet 배포
# - nodeSelector 패치, GPU 리소스 등록 대기 및 검증
#
# 실행 방법: bash deploy-nvidia-device-plugin.sh --node <node-name> [--node <node-name> ...]
###############################################################################

set -e

# ----- 색상 출력 -----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[ OK ]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $1"; }

step_header() {
	echo ""
	echo "================================================================"
	echo " $1"
	echo "================================================================"
}

PLUGIN_VERSION="v0.17.1"
LABEL_KEY="gpu_nvidia"
LABEL_VALUE="true"
NAMESPACE="kube-system"
DS_NAME="nvidia-device-plugin-daemonset"
GPU_WAIT_TIMEOUT="180"
GPU_WAIT_INTERVAL="5"
NODES=()

usage() {
	cat <<'USAGE'
사용법: ./deploy-nvidia-device-plugin.sh --node <node-name> [--node <node-name> ...]

옵션:
  --node <name>    label 을 부여하고 plugin 을 배포할 GPU 노드 (반복 지정 가능, 필수)
  -h, --help       도움말 출력

예시:
  ./deploy-nvidia-device-plugin.sh --node dku-mlops-worker
  ./deploy-nvidia-device-plugin.sh --node worker1 --node worker2
USAGE
}

while [[ "$#" -gt 0 ]]; do
	case "$1" in
		--node)
			if [ -z "${2:-}" ]; then
				log_error "--node 옵션에 노드 이름이 필요합니다."
				usage
				exit 1
			fi
			NODES+=("$2")
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			log_error "알 수 없는 옵션입니다: $1"
			usage
			exit 1
			;;
	esac
done

# ----- 사전 점검 -----
if [ "${#NODES[@]}" -eq 0 ]; then
	log_error "--node 옵션은 필수입니다."
	usage
	exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
	log_error "kubectl 을 찾을 수 없습니다."
	exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
	log_error "Kubernetes 클러스터에 연결할 수 없습니다. kubeconfig 를 확인하세요."
	exit 1
fi
log_success "클러스터 연결 확인 완료"

# node existence check
for node in "${NODES[@]}"; do
	if ! kubectl get node "${node}" >/dev/null 2>&1; then
		log_error "노드를 찾을 수 없습니다: ${node}"
		exit 1
	fi
done
log_success "대상 노드: ${NODES[*]}"

# ---- wait until GPU resources are registered on every target node ----
wait_for_gpu() {
	local elapsed=0
	local gpu pending

	while [ "${elapsed}" -lt "${GPU_WAIT_TIMEOUT}" ]; do
		pending=0
		for node in "${NODES[@]}"; do
			gpu=$(kubectl get node "${node}" \
				-o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)
			if [ -z "${gpu}" ] || [ "${gpu}" = "0" ]; then
				pending=1
			fi
		done

		if [ "${pending}" -eq 0 ]; then
			printf "\n"
			return 0
		fi

		sleep "${GPU_WAIT_INTERVAL}"
		elapsed=$((elapsed + GPU_WAIT_INTERVAL))
		printf "\r       GPU 리소스 등록 대기 중... %ds/%ds" "${elapsed}" "${GPU_WAIT_TIMEOUT}"
	done

	printf "\n"
	return 1
}

step_header "NVIDIA Device Plugin 배포 시작"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"
log_info "Plugin 버전: ${PLUGIN_VERSION}"

# ---- Step 1: label GPU nodes ----
step_header "Step 1/5: GPU 노드 label 부여 (${LABEL_KEY}=${LABEL_VALUE})"
for node in "${NODES[@]}"; do
	kubectl label node "${node}" "${LABEL_KEY}=${LABEL_VALUE}" --overwrite
done

# ---- Step 2: deploy device plugin ----
step_header "Step 2/5: NVIDIA device plugin 배포 (${PLUGIN_VERSION})"
kubectl apply -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${PLUGIN_VERSION}/deployments/static/nvidia-device-plugin.yml"

# ---- Step 3: patch nodeSelector ----
step_header "Step 3/5: DaemonSet 에 nodeSelector 패치"
kubectl -n "${NAMESPACE}" patch daemonset "${DS_NAME}" \
	--type merge \
	-p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"${LABEL_KEY}\":\"${LABEL_VALUE}\"}}}}}"

# ---- Step 4: wait for rollout + GPU registration ----
step_header "Step 4/5: rollout 및 GPU 리소스 등록 대기"
# rollout 실패(대개 nvidia 런타임 미등록 → CrashLoopBackOff)해도 Step 5 의 진단 안내까지 진행되도록 set -e 에서 제외
GPU_READY=1
log_info "DaemonSet rollout 대기..."
if ! kubectl -n "${NAMESPACE}" rollout status daemonset "${DS_NAME}" --timeout=180s; then
	GPU_READY=0
	log_warn "DaemonSet rollout 이 180초 내에 완료되지 않았습니다."
fi

if [ "${GPU_READY}" -eq 1 ]; then
	log_info "GPU 리소스 등록 대기..."
	if wait_for_gpu; then
		log_success "GPU 리소스 등록 완료"
	else
		GPU_READY=0
		log_warn "${GPU_WAIT_TIMEOUT}초 내에 GPU 리소스가 등록되지 않았습니다."
	fi
fi

# ---- Step 5: verify ----
step_header "Step 5/5: 검증"

log_info "DaemonSet pod 상태"
kubectl -n "${NAMESPACE}" get pods -l name=nvidia-device-plugin-ds -o wide

echo
log_info "노드별 할당 가능 GPU"
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu,LABEL:.metadata.labels.'"${LABEL_KEY}"

if [ "${GPU_READY}" -eq 0 ]; then
	echo
	log_warn "진단 — GPU 노드에서 다음 항목을 확인하세요:"
	log_info "  1) kubectl -n ${NAMESPACE} logs -l name=nvidia-device-plugin-ds --tail=50"
	log_info "  2) nvidia-smi                                   # 드라이버 설치 여부"
	log_info "  3) grep -A3 nvidia /etc/containerd/config.toml  # nvidia runtime 등록 여부"
	log_info "     → sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default"
	log_info "     → sudo systemctl restart containerd"
	exit 1
fi

step_header "모든 설치 및 설정이 완료되었습니다"
