#!/bin/bash
###############################################################################
# NVIDIA Driver 자동 설치 스크립트
# - NVIDIA 공식 .run 파일을 내려받아 드라이버 설치 (kernel-open 모듈)
# - Ubuntu 환경 기준
#
# 실행 방법: bash install-nvidia-driver.sh   → 화살표 메뉴에서 버전 선택 (터미널 필요)
#
# 사전 점검: Secure Boot / apt 드라이버 충돌 / nouveau / 사용 중인 nvidia 모듈
# 설치 옵션: --silent --dkms -m=kernel-open (DKMS 고정), 32비트 라이브러리 / nvidia-xconfig 는 실행 시 선택
# 설치 로그: /var/log/nvidia-installer.log
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

# ----- 종료 시 정리: 커서 복원 + 다운로드한 .run 삭제 -----
RUN_FILE=""
cleanup() {
    tput cnorm 2>/dev/null || true
    if [ -n "${RUN_FILE}" ] && [ -f "${RUN_FILE}" ]; then
        rm -f "${RUN_FILE}"
    fi
}
trap cleanup EXIT

# ----- 화살표 선택 메뉴 -----
# 사용: select_menu "항목1" "항목2" ...  → 선택한 인덱스(0부터)가 MENU_SELECTED 에 저장. q/Ctrl-C 면 종료
MENU_SELECTED=0
select_menu() {
    local items=("$@") n=$# idx=0 key seq i
    tput civis 2>/dev/null || true

    while true; do
        for ((i = 0; i < n; i++)); do
            if [ "$i" -eq "$idx" ]; then
                printf '  \033[7m ▶ %s \033[0m\n' "${items[i]}"
            else
                printf '     %s\n' "${items[i]}"
            fi
        done

        IFS= read -rsn1 key || true
        if [ "$key" = $'\x1b' ]; then
            seq=""
            IFS= read -rsn2 -t 0.2 seq || true
            case "$seq" in
                '[A') idx=$(( (idx - 1 + n) % n )) ;;
                '[B') idx=$(( (idx + 1) % n )) ;;
            esac
        else
            case "$key" in
                k) idx=$(( (idx - 1 + n) % n )) ;;
                j) idx=$(( (idx + 1) % n )) ;;
                "") break ;;                       # Enter
                q|Q) tput cnorm 2>/dev/null || true; echo; log_warn "취소했습니다."; exit 1 ;;
            esac
        fi
        printf '\033[%dA' "$n"                     # 메뉴 줄 수만큼 커서 위로 → 다시 그림
    done

    tput cnorm 2>/dev/null || true
    MENU_SELECTED=$idx
}

# ----- 사전 점검 -----
. /etc/os-release

if [ "$NAME" != "Ubuntu" ]; then
    log_error "이 스크립트는 Ubuntu 환경에서만 동작합니다."
    exit 1
fi

if [ ! -t 0 ]; then
    log_error "이 스크립트는 터미널에서 실행해야 합니다. (버전을 메뉴에서 선택)"
    exit 1
fi

step_header "사전 점검"

# Secure Boot — .run 으로 빌드한 모듈은 서명되지 않아 SB 가 켜져 있으면 로드되지 않음
SB_STATE="unknown"
if command -v mokutil &>/dev/null; then
    if mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then SB_STATE="enabled"; else SB_STATE="disabled"; fi
elif [ -d /sys/firmware/efi/efivars ]; then
    SB_FILE=$(ls /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | head -n1 || true)
    if [ -n "${SB_FILE}" ]; then
        if [ "$(od -An -tu1 -j4 -N1 "${SB_FILE}" 2>/dev/null | tr -d ' ')" = "1" ]; then SB_STATE="enabled"; else SB_STATE="disabled"; fi
    fi
else
    SB_STATE="disabled"   # legacy BIOS
fi
if [ "${SB_STATE}" = "enabled" ]; then
    log_error "Secure Boot 가 켜져 있습니다. .run 으로 설치한 커널 모듈은 서명되지 않아 로드되지 않습니다."
    log_info  "BIOS 에서 Secure Boot 를 끄거나, MOK 로 모듈을 서명한 뒤 재실행하세요."
    exit 1
fi
log_success "Secure Boot: ${SB_STATE}"

# apt 로 설치된 NVIDIA 드라이버 — .run 과 섞이면 충돌
APT_NVIDIA=$(dpkg -l 2>/dev/null | awk '/^ii[[:space:]]+nvidia-driver-[0-9]+/ {print $2 " (" $3 ")"}' || true)
if [ -n "${APT_NVIDIA}" ]; then
    log_error "apt 로 설치된 NVIDIA 드라이버가 있습니다: ${APT_NVIDIA}"
    log_info  "제거 후 재부팅하고 재실행하세요:"
    log_info  "  sudo apt purge -y '^nvidia-driver-.*' '^nvidia-dkms-.*' '^nvidia-kernel-.*' '^libnvidia-.*' && sudo reboot"
    exit 1
fi
log_success "apt NVIDIA 드라이버: 없음"

# nouveau — 로드된 상태면 설치기가 거부. 블랙리스트 후 재부팅 필요
if lsmod | grep -q '^nouveau '; then
    log_warn "nouveau 드라이버가 로드되어 있습니다. NVIDIA 설치기는 이 상태에서 설치를 거부합니다."
    read -rp "$(echo -e "${BLUE}[INFO]${NC} nouveau 를 블랙리스트에 등록하고 initramfs 를 재생성할까요? (이후 재부팅 필요) [Y/n] ")" NOUVEAU_CONFIRM
    case "${NOUVEAU_CONFIRM}" in
        ""|[Yy]*)
            cat <<BLACKLIST | sudo tee /etc/modprobe.d/blacklist-nouveau.conf >/dev/null
blacklist nouveau
options nouveau modeset=0
BLACKLIST
            sudo update-initramfs -u
            log_success "nouveau 블랙리스트 등록 완료: /etc/modprobe.d/blacklist-nouveau.conf"
            log_warn "재부팅 후 이 스크립트를 다시 실행하세요:  sudo reboot"
            exit 0
            ;;
        *) log_warn "취소했습니다."; exit 1 ;;
    esac
fi
log_success "nouveau: 로드되지 않음"

# 기존 nvidia 모듈 — 사용 중인 프로세스가 있으면 설치기가 모듈을 내리지 못함
if lsmod | grep -q '^nvidia '; then
    GPU_PROCS=$(nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader 2>/dev/null || true)
    if [ -n "${GPU_PROCS}" ]; then
        log_error "GPU 를 사용 중인 프로세스가 있어 기존 드라이버를 교체할 수 없습니다:"
        echo "${GPU_PROCS}" | sed 's/^/       /'
        log_info  "프로세스 종료 후 재실행하세요."
        exit 1
    fi
    log_warn "기존 nvidia 모듈이 로드되어 있습니다 ($(cat /sys/module/nvidia/version 2>/dev/null || echo '버전 불명')). 설치기가 제거하고 교체합니다."
else
    log_success "기존 nvidia 모듈: 없음"
fi

BASE_URL="https://download.nvidia.com/XFree86/Linux-x86_64"

# 메뉴에 표시할 알려진 버전
declare -A DRIVER_VERSIONS
DRIVER_VERSIONS[550]="550.120"
DRIVER_VERSIONS[595]="595.58.03"

DRIVER_VERSION=""

step_header "NVIDIA Driver 자동 설치"

# NVIDIA 최신 버전 조회 (5초 제한, 실패하면 항목 생략)
LATEST_VERSION=$(curl -fsSL --max-time 5 "${BASE_URL}/latest.txt" 2>/dev/null | awk '{print $1}' || true)

MENU_LABELS=()
MENU_VALUES=()
MENU_LABELS+=("$(printf '%-12s %s' "${DRIVER_VERSIONS[550]}" "안정 버전 (기본)  — Ampere / Ada")");   MENU_VALUES+=("${DRIVER_VERSIONS[550]}")
MENU_LABELS+=("$(printf '%-12s %s' "${DRIVER_VERSIONS[595]}" "Blackwell (RTX 50xx / B200)")");         MENU_VALUES+=("${DRIVER_VERSIONS[595]}")
if [ -n "${LATEST_VERSION}" ] && [ "${LATEST_VERSION}" != "${DRIVER_VERSIONS[595]}" ]; then
    MENU_LABELS+=("$(printf '%-12s %s' "${LATEST_VERSION}" "최신  (NVIDIA latest.txt 조회)")");      MENU_VALUES+=("${LATEST_VERSION}")
fi
MENU_LABELS+=("$(printf '%-12s %s' "직접 입력" "예: 570.172.08")");                                    MENU_VALUES+=("__custom__")

log_info "설치할 드라이버 버전을 선택하세요  (↑/↓ 이동 · Enter 선택 · q 취소)"
echo
select_menu "${MENU_LABELS[@]}"
echo

DRIVER_VERSION="${MENU_VALUES[$MENU_SELECTED]}"
if [ "${DRIVER_VERSION}" = "__custom__" ]; then
    while true; do
        read -rp "$(echo -e "${BLUE}[INFO]${NC} 드라이버 버전 입력 (예: 570.172.08): ")" DRIVER_VERSION
        if [[ "${DRIVER_VERSION}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
            break
        fi
        log_warn "형식이 올바르지 않습니다. 숫자.숫자[.숫자] 형태로 입력하세요."
    done
fi

RUN_FILE="NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run"
RUN_URL="${BASE_URL}/${DRIVER_VERSION}/${RUN_FILE}"

# NVIDIA 서버에 해당 버전이 있는지 다운로드 전에 확인
log_info "NVIDIA 서버에서 ${DRIVER_VERSION} 확인 중..."
if ! curl -fsIL --max-time 10 "${RUN_URL}" >/dev/null 2>&1; then
    log_error "NVIDIA 서버에 해당 버전이 없습니다: ${DRIVER_VERSION}"
    log_info  "확인: ${BASE_URL}/"
    exit 1
fi
log_success "버전 확인 완료: ${DRIVER_VERSION}"

# ----- 설치 옵션 선택 (DKMS 는 항상 등록 — 커널 업데이트 시 드라이버 유실 방지) -----
log_info "${DRIVER_VERSION} 설치 옵션"
read -rp "       32비트 호환 라이브러리 설치 (GPU 서버는 보통 불필요)  [y/N] " OPT_COMPAT32
read -rp "       nvidia-xconfig 실행 (X 디스플레이 설정 파일 생성)      [y/N] " OPT_XCONFIG

INSTALL_OPTS=(--silent --dkms -m=kernel-open)
case "${OPT_COMPAT32}" in
    [Yy]*) COMPAT32_LABEL="설치" ;;
    *)     COMPAT32_LABEL="설치 안 함"; INSTALL_OPTS+=(--no-install-compat32-libs) ;;
esac
case "${OPT_XCONFIG}" in
    [Yy]*) XCONFIG_LABEL="실행";        INSTALL_OPTS+=(--run-nvidia-xconfig) ;;
    *)     XCONFIG_LABEL="실행 안 함" ;;
esac

echo
log_info "설치 요약"
log_info "  버전            : ${DRIVER_VERSION}"
log_info "  DKMS 등록       : 예 (고정)"
log_info "  32비트 라이브러리: ${COMPAT32_LABEL}"
log_info "  nvidia-xconfig  : ${XCONFIG_LABEL}"
read -rp "$(echo -e "${BLUE}[INFO]${NC} 계속할까요? [Y/n] ")" CONFIRM
case "${CONFIRM}" in
    ""|[Yy]*) ;;
    *) log_warn "취소했습니다."; exit 1 ;;
esac

step_header "NVIDIA Driver 자동 설치 시작"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"
log_info "설치 버전: ${DRIVER_VERSION}"

step_header "Step 1/4: NVIDIA Driver 다운로드 (${DRIVER_VERSION})"
# -c: 같은 파일이 있으면 이어받기 (완전한 파일이면 재다운로드 없음), -O: .run.1 같은 중복 파일 방지
wget -c -O "${RUN_FILE}" "${RUN_URL}"
chmod +x "${RUN_FILE}"

step_header "Step 2/4: 빌드 의존 패키지 설치"
sudo apt update
sudo apt install -y build-essential gcc make dkms "linux-headers-$(uname -r)"

step_header "Step 3/4: NVIDIA Driver 설치"
# --silent: 설치기 질문 없이 진행 (32-bit / xconfig 는 위에서 선택한 값)
# --dkms  : 커널 업데이트 시 모듈 자동 재빌드
# -m=kernel-open: open kernel module (Turing 이상)
log_info "설치기 옵션: ${INSTALL_OPTS[*]}"
if ! sudo "./${RUN_FILE}" "${INSTALL_OPTS[@]}"; then
    log_error "드라이버 설치에 실패했습니다. 로그: /var/log/nvidia-installer.log"
    exit 1
fi
log_success "드라이버 설치 완료 (dkms 등록됨)"

step_header "Step 4/4: 드라이버 확인 및 설치 파일 정리"
if nvidia-smi; then
    log_success "nvidia-smi 정상"
else
    log_warn "nvidia-smi 가 아직 동작하지 않습니다. 재부팅 후 다시 확인하세요:  sudo reboot"
fi
rm -f "${RUN_FILE}"
log_info "설치 파일 정리 완료: ${RUN_FILE}"

step_header "모든 설치 및 설정이 완료되었습니다"
