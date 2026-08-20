#!/bin/bash
set -e

# ---- pretty output helpers ----
info() { printf "\033[1;32m[ OK ]\033[0m %s\n" "$1"; }
warn() { printf "\033[1;33m[WARN]\033[0m %s\n" "$1"; }
err()  { printf "\033[1;31m[FAIL]\033[0m %s\n" "$1" >&2; }

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
Usage: ./deploy-nvidia-device-plugin.sh --node <node-name> [--node <node-name> ...]

Options:
  --node <name>    GPU node to label and target (repeatable, required)
  -h, --help       Show this help

Example:
  ./deploy-nvidia-device-plugin.sh --node dku-mlops-worker
  ./deploy-nvidia-device-plugin.sh --node worker1 --node worker2
USAGE
}

while [[ "$#" -gt 0 ]]; do
	case "$1" in
		--node)
			NODES+=("$2")
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			err "Unknown option: $1"
			usage
			exit 1
			;;
	esac
done

# ---- pre-flight ----
if [ "${#NODES[@]}" -eq 0 ]; then
	err "--node is required and must be provided."
	usage
	exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
	err "kubectl not found in PATH."
	exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
	err "Cannot reach the Kubernetes cluster. Check your kubeconfig."
	exit 1
fi
info "Cluster connection OK"

# node existence check
for node in "${NODES[@]}"; do
	if ! kubectl get node "${node}" >/dev/null 2>&1; then
		err "Node not found: ${node}"
		exit 1
	fi
done
info "Target nodes: ${NODES[*]}"

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
		printf "\r       waiting for GPU registration... %ds/%ds" "${elapsed}" "${GPU_WAIT_TIMEOUT}"
	done

	printf "\n"
	return 1
}

# ---- Step 1: label GPU nodes ----
echo "[1/5] Label GPU nodes (${LABEL_KEY}=${LABEL_VALUE})"
for node in "${NODES[@]}"; do
	kubectl label node "${node}" "${LABEL_KEY}=${LABEL_VALUE}" --overwrite
done

# ---- Step 2: deploy device plugin ----
echo "[2/5] Deploy NVIDIA device plugin (${PLUGIN_VERSION})"
kubectl apply -f "https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/${PLUGIN_VERSION}/deployments/static/nvidia-device-plugin.yml"

# ---- Step 3: patch nodeSelector ----
echo "[3/5] Patch nodeSelector into DaemonSet"
kubectl -n "${NAMESPACE}" patch daemonset "${DS_NAME}" \
	--type merge \
	-p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"${LABEL_KEY}\":\"${LABEL_VALUE}\"}}}}}"

# ---- Step 4: wait for rollout + GPU registration ----
echo "[4/5] Wait for rollout"
kubectl -n "${NAMESPACE}" rollout status daemonset "${DS_NAME}" --timeout=180s

echo "       Waiting for GPU resources to be registered"
GPU_READY=1
if wait_for_gpu; then
	info "GPU resources registered"
else
	GPU_READY=0
	warn "GPU not registered within ${GPU_WAIT_TIMEOUT}s"
fi

# ---- Step 5: verify ----
echo "[5/5] Verify"

echo
info "DaemonSet pods"
kubectl -n "${NAMESPACE}" get pods -l name=nvidia-device-plugin-ds -o wide

echo
info "Allocatable GPUs per node"
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu,LABEL:.metadata.labels.'"${LABEL_KEY}"

if [ "${GPU_READY}" -eq 0 ]; then
	echo
	warn "Diagnostics — check the following on the GPU node:"
	printf "       \033[1;36m1)\033[0m kubectl -n %s logs -l name=nvidia-device-plugin-ds --tail=50\n" "${NAMESPACE}"
	printf "       \033[1;36m2)\033[0m nvidia-smi                     # driver installed?\n"
	printf "       \033[1;36m3)\033[0m grep -A3 nvidia /etc/containerd/config.toml   # runtime registered?\n"
	printf "          \033[1;36m→\033[0m sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default\n"
	printf "          \033[1;36m→\033[0m sudo systemctl restart containerd\n"
	exit 1
fi

echo
info "Done."
