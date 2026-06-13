#!/bin/bash
###############################################################################
# NVIDIA Container Toolkit 자동 설치 스크립트
# - Container에서 GPU를 사용하기 위한 toolkit 설치 (Worker Node)
# - Ubuntu/Debian 환경 기준
#
# 실행 방법: sudo bash install-nvidia-container-toolkit.sh
###############################################################################

set -euo pipefail  # 에러 발생/미정의 변수/파이프 에러 시 즉시 종료

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

# ----- 사전 점검 -----
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "이 스크립트는 root 권한으로 실행해야 합니다."
        log_info  "실행 예: sudo bash $0"
        exit 1
    fi
}

check_os() {
    if ! command -v apt-get &>/dev/null; then
        log_error "apt-get을 찾을 수 없습니다. Ubuntu/Debian 환경에서만 동작합니다."
        exit 1
    fi
}

# ----- GPU + Driver 통합 확인 (nvidia-smi 기반) -----
check_nvidia_gpu_driver() {
    log_info "NVIDIA Driver 및 GPU 확인 (nvidia-smi 기반)..."

    # nvidia-smi 존재 확인
    if ! command -v nvidia-smi &>/dev/null; then
        log_error "nvidia-smi를 찾을 수 없습니다. NVIDIA Driver를 먼저 설치하세요."
        exit 1
    fi

    # GPU 감지 확인 (실행은 되나 GPU 미감지/드라이버 비정상이면 실패)
    if ! nvidia-smi -L &>/dev/null; then
        log_error "nvidia-smi 실행은 되나 GPU가 감지되지 않았습니다."
        log_error "드라이버 상태를 확인하세요: nvidia-smi"
        exit 1
    fi

    log_success "NVIDIA GPU 및 Driver 확인 완료"
    nvidia-smi -L
    nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
}

# ----- Step 1: NVIDIA Container Toolkit 설치 -----
install_container_toolkit() {
    step_header "Step 1: NVIDIA Container Toolkit 설치"

    # 이미 설치되어 있는지 확인
    if dpkg -l nvidia-container-toolkit 2>/dev/null | grep -q '^ii'; then
        log_warn "nvidia-container-toolkit이 이미 설치되어 있습니다. (재설치 진행)"
    fi

    log_info "GPG 키 등록..."
    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

    log_info "APT repository 등록..."
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

    log_info "Experimental 채널 활성화..."
    sed -i -e '/experimental/ s/^#//g' /etc/apt/sources.list.d/nvidia-container-toolkit.list

    log_info "패키지 업데이트 및 설치..."
    apt-get update -y
    apt-get install -y nvidia-container-toolkit

    log_success "NVIDIA Container Toolkit 설치 완료"
    nvidia-ctk --version || true
}

# ----- Step 2: Container Runtime 설정 -----
configure_runtime() {
    step_header "Step 2: NVIDIA Container Runtime 설정"

    # Docker
    if command -v docker &>/dev/null; then
        log_info "Docker runtime 설정..."
        nvidia-ctk runtime configure --runtime=docker
        systemctl restart docker
        log_success "Docker runtime 설정 완료"
    else
        log_warn "Docker 미설치 - Docker 설정 건너뜀"
    fi

    # Containerd
    if command -v containerd &>/dev/null; then
        log_info "Containerd runtime 설정 (default runtime = nvidia)..."
        nvidia-ctk runtime configure --runtime=containerd --set-as-default
        systemctl restart containerd
        log_success "Containerd runtime 설정 완료"
    else
        log_warn "Containerd 미설치 - Containerd 설정 건너뜀"
    fi
}

# ----- Step 3: GPU 인식 테스트 -----
test_gpu_in_container() {
    step_header "Step 3: Containerd 재시작 후 GPU 인식 테스트"

    if ! command -v ctr &>/dev/null; then
        log_warn "ctr 명령을 찾을 수 없습니다. GPU 인식 테스트 건너뜀"
        return 0
    fi

    local CUDA_IMAGE="docker.io/nvidia/cuda:11.8.0-base-ubuntu22.04"

    log_info "Containerd 재시작..."
    systemctl restart containerd

    log_info "CUDA 베이스 이미지 pull: ${CUDA_IMAGE}"
    ctr image pull "${CUDA_IMAGE}"

    log_info "컨테이너 내부에서 nvidia-smi 실행..."
    ctr run --rm -t \
        --runc-binary=/usr/bin/nvidia-container-runtime \
        --env NVIDIA_VISIBLE_DEVICES=all \
        "${CUDA_IMAGE}" \
        gpu-test \
        nvidia-smi

    log_success "GPU 인식 테스트 통과"
}

# ----- main -----
main() {
    step_header "NVIDIA Container Toolkit 자동 설치 시작"
    log_info "$(date '+%Y-%m-%d %H:%M:%S')"
    log_info "Host: $(hostname)"

    check_root
    check_os
    check_nvidia_gpu_driver

    install_container_toolkit
    configure_runtime
    test_gpu_in_container

    step_header "모든 설치 및 설정이 완료되었습니다"
}

main "$@"
