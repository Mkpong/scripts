#!/bin/bash
###############################################################################
# 호스트 브리지 네트워크 설정 스크립트 (KVM)
# - 물리 NIC 을 브리지(br0)에 넣고 IP 를 브리지로 이전 → VM 이 LAN 에 직접 연결
# - netplan 으로 영구 설정 (재부팅 후 유지), netplan try 로 실패 시 자동 원복
# - libvirt 네트워크(br0-net) 정의 + autostart
#
# 실행 방법: bash setup-bridge-network.sh   → 메뉴에서 NIC / 이름 / IP 방식 선택 (터미널 필요)
#
# 주의
# - SSH 로 접속 중인 NIC 을 브리지로 바꾸면 적용 순간 연결이 끊길 수 있음.
#   가능하면 콘솔(IPMI)에서 실행하거나, SSH 와 다른 NIC 을 브리지할 것
# - cloud-init 이 netplan 을 관리하는 호스트(50-cloud-init.yaml)는 재부팅 시 원복되지 않도록
#   cloud-init 네트워크 설정을 비활성화함
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

trap 'tput cnorm 2>/dev/null || true' EXIT

# ----- 화살표 선택 메뉴 -----
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
			seq=""; IFS= read -rsn2 -t 0.2 seq || true
			case "$seq" in
				'[A') idx=$(( (idx - 1 + n) % n )) ;;
				'[B') idx=$(( (idx + 1) % n )) ;;
			esac
		else
			case "$key" in
				k) idx=$(( (idx - 1 + n) % n )) ;;
				j) idx=$(( (idx + 1) % n )) ;;
				"") break ;;
				q|Q) tput cnorm 2>/dev/null || true; echo; log_warn "취소했습니다."; exit 1 ;;
			esac
		fi
		printf '\033[%dA' "$n"
	done
	tput cnorm 2>/dev/null || true
	MENU_SELECTED=$idx
}

ASK_RESULT=""
ask_text() {
	local prompt="$1" default="$2" input
	if [ -n "${default}" ]; then
		read -rp "$(echo -e "${BLUE}[INFO]${NC} ${prompt} [${default}]: ")" input
	else
		read -rp "$(echo -e "${BLUE}[INFO]${NC} ${prompt}: ")" input
	fi
	ASK_RESULT="${input:-$default}"
}

# ----- 사전 점검 -----
if [ ! -t 0 ]; then
	log_error "이 스크립트는 터미널에서 실행해야 합니다."
	exit 1
fi
for cmd in ip netplan virsh python3; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		log_error "'$cmd' 명령을 찾을 수 없습니다. install_kvm.sh 를 먼저 실행하세요."
		exit 1
	fi
done
if ! python3 -c 'import yaml' 2>/dev/null; then
	log_error "python3-yaml 이 필요합니다: sudo apt-get install -y python3-yaml"
	exit 1
fi

NETPLAN_DIR="/etc/netplan"
NETPLAN_FILE="${NETPLAN_DIR}/60-kvm-bridge.yaml"
VIRSH="sudo virsh -c qemu:///system"

step_header "브리지 네트워크 설정"

# 현재 상태
DEFAULT_DEV=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1 || true)
SSH_LOCAL_IP=$(echo "${SSH_CONNECTION:-}" | awk '{print $3}')
mapfile -t EXISTING_BRIDGES < <(ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep -vE '^(virbr|docker)' || true)
if [ "${#EXISTING_BRIDGES[@]}" -gt 0 ]; then
	log_info "기존 브리지: ${EXISTING_BRIDGES[*]}"
fi

# ----- 1. 물리 NIC 선택 -----
NIC_LIST=(); NIC_LABELS=()
for dev_path in /sys/class/net/*; do
	dev=$(basename "${dev_path}")
	[ -e "${dev_path}/device" ] || continue          # 물리 장치만 (가상 인터페이스 제외)
	case "${dev}" in lo|virbr*|br*|veth*|docker*|vnet*|vbox*) continue ;; esac
	ip4=$(ip -4 -o addr show dev "${dev}" 2>/dev/null | awk '{print $4}' | head -n1 || true)
	state=$(cat "${dev_path}/operstate" 2>/dev/null || echo "?")
	master=$(ip -o link show dev "${dev}" 2>/dev/null | grep -oE 'master [^ ]+' | awk '{print $2}' || true)
	note=""
	[ "${dev}" = "${DEFAULT_DEV}" ] && note="${note} 기본경로"
	[ -n "${SSH_LOCAL_IP}" ] && [ "${ip4%%/*}" = "${SSH_LOCAL_IP}" ] && note="${note} SSH접속중"
	[ -n "${master}" ] && note="${note} (${master} 소속)"
	NIC_LIST+=("${dev}")
	NIC_LABELS+=("$(printf '%-12s %-20s %-6s%s' "${dev}" "${ip4:-(IP 없음)}" "${state}" "${note}")")
done
if [ "${#NIC_LIST[@]}" -eq 0 ]; then
	log_error "물리 NIC 을 찾을 수 없습니다."
	exit 1
fi
log_info "브리지에 연결할 물리 NIC 을 선택하세요  (↑/↓ 이동 · Enter 선택 · q 취소)"
select_menu "${NIC_LABELS[@]}"
NIC="${NIC_LIST[$MENU_SELECTED]}"

NIC_MASTER=$(ip -o link show dev "${NIC}" | grep -oE 'master [^ ]+' | awk '{print $2}' || true)
NIC_IP4=$(ip -4 -o addr show dev "${NIC}" | awk '{print $4}' | head -n1 || true)
NIC_GW=$(ip -4 route show default dev "${NIC}" 2>/dev/null | awk '{print $3}' | head -n1 || true)
NIC_DNS=$(resolvectl dns "${NIC}" 2>/dev/null | sed 's/^[^:]*: *//' | tr ' ' '\n' | grep -E '^[0-9.]+$' | head -n3 | tr '\n' ' ' || true)
NIC_DNS="${NIC_DNS% }"

if [ "${NIC}" = "${DEFAULT_DEV}" ] || { [ -n "${SSH_LOCAL_IP}" ] && [ "${NIC_IP4%%/*}" = "${SSH_LOCAL_IP}" ]; }; then
	log_warn "${NIC} 은(는) 기본 경로/SSH 접속에 사용 중입니다. 적용 순간 연결이 끊길 수 있습니다."
	log_warn "netplan try 가 120초 안에 확인되지 않으면 자동 원복되지만, 콘솔(IPMI)에서 실행하는 것을 권장합니다."
fi

# ----- 2. 이름 -----
echo
ask_text "브리지 이름" "br0";            BRIDGE="${ASK_RESULT}"
ask_text "libvirt 네트워크 이름" "${BRIDGE}-net"; NETNAME="${ASK_RESULT}"

BRIDGE_EXISTS=0; ip link show "${BRIDGE}" >/dev/null 2>&1 && BRIDGE_EXISTS=1
NET_EXISTS=0;    ${VIRSH} net-info "${NETNAME}" >/dev/null 2>&1 && NET_EXISTS=1

# ----- 3. IP 방식 (브리지가 이미 있으면 건너뜀) -----
IP_MODE="skip"
if [ "${BRIDGE_EXISTS}" -eq 1 ]; then
	if [ "${NIC_MASTER}" = "${BRIDGE}" ]; then
		log_success "브리지 ${BRIDGE} 가 이미 있고 ${NIC} 이(가) 소속되어 있습니다. netplan 단계는 건너뜁니다."
	else
		log_warn "브리지 ${BRIDGE} 가 이미 있습니다 (${NIC} 은 미소속). 기존 netplan 설정을 확인하세요. netplan 단계는 건너뜁니다."
	fi
else
	echo
	log_info "브리지의 IP 설정 방식을 선택하세요"
	MOVE_LABEL="현재 ${NIC} 설정을 브리지로 이전"
	[ -n "${NIC_IP4}" ] && MOVE_LABEL="${MOVE_LABEL}   (${NIC_IP4}${NIC_GW:+, gw ${NIC_GW}}${NIC_DNS:+, dns ${NIC_DNS}})" || MOVE_LABEL="${MOVE_LABEL}   (현재 IP 없음 — 선택 불가)"
	while true; do
		select_menu "${MOVE_LABEL}" "DHCP" "직접 입력 (고정 IP)"
		case "${MENU_SELECTED}" in
			0)
				if [ -z "${NIC_IP4}" ]; then log_warn "${NIC} 에 IPv4 가 없어 이전할 설정이 없습니다."; continue; fi
				IP_MODE="static"; BR_ADDR="${NIC_IP4}"; BR_GW="${NIC_GW}"; BR_DNS="${NIC_DNS:-8.8.8.8}" ;;
			1)
				IP_MODE="dhcp" ;;
			2)
				IP_MODE="static"
				while true; do ask_text "IP 주소 (CIDR, 예: 10.10.0.32/24)" ""; [[ "${ASK_RESULT}" =~ ^[0-9.]+/[0-9]+$ ]] && break; log_warn "형식: a.b.c.d/prefix"; done; BR_ADDR="${ASK_RESULT}"
				ask_text "게이트웨이 (없으면 빈 값)" "${NIC_GW}"; BR_GW="${ASK_RESULT}"
				ask_text "DNS (공백 구분)" "${NIC_DNS:-8.8.8.8}"; BR_DNS="${ASK_RESULT}" ;;
		esac
		break
	done
fi

# ----- 4. 요약 / 확인 -----
RENDERER=$(sudo grep -h 'renderer:' "${NETPLAN_DIR}"/*.yaml 2>/dev/null | head -n1 | awk '{print $2}' || true)
CLOUD_INIT_NETPLAN=0; [ -f "${NETPLAN_DIR}/50-cloud-init.yaml" ] && CLOUD_INIT_NETPLAN=1

echo
log_info "설정 요약"
log_info "  NIC              : ${NIC}"
log_info "  브리지           : ${BRIDGE}$([ "${BRIDGE_EXISTS}" -eq 1 ] && echo '  (이미 있음 → netplan 건너뜀)')"
case "${IP_MODE}" in
	static) log_info "  브리지 IP        : ${BR_ADDR}${BR_GW:+  gw ${BR_GW}}  dns ${BR_DNS}" ;;
	dhcp)   log_info "  브리지 IP        : DHCP" ;;
esac
[ "${IP_MODE}" != "skip" ] && log_info "  netplan          : ${NETPLAN_FILE}  (renderer: ${RENDERER:-networkd})"
[ "${IP_MODE}" != "skip" ] && [ "${CLOUD_INIT_NETPLAN}" -eq 1 ] && log_info "  cloud-init       : 네트워크 설정 비활성화 (99-disable-network-config.cfg)"
log_info "  libvirt 네트워크 : ${NETNAME}$([ "${NET_EXISTS}" -eq 1 ] && echo '  (이미 있음 → 건너뜀)')"
read -rp "$(echo -e "${YELLOW}[WARN]${NC} 호스트 네트워크를 변경합니다. 브리지 이름을 다시 입력하면 진행합니다 [${BRIDGE}]: ")" CONFIRM
if [ "${CONFIRM}" != "${BRIDGE}" ]; then
	log_warn "이름이 일치하지 않아 취소했습니다."
	exit 1
fi

step_header "브리지 네트워크 설정 시작"
log_info "$(date '+%Y-%m-%d %H:%M:%S')"
log_info "Host: $(hostname)"

# ----- Step 1: netplan -----
step_header "Step 1/3: netplan 설정"
if [ "${IP_MODE}" = "skip" ]; then
	log_info "건너뜀 (브리지 이미 존재)"
else
	BACKUP_DIR="${NETPLAN_DIR}/backup-$(date '+%Y%m%d%H%M%S')"
	sudo mkdir -p "${BACKUP_DIR}"
	sudo cp "${NETPLAN_DIR}"/*.yaml "${BACKUP_DIR}/" 2>/dev/null || true
	log_success "기존 netplan 백업: ${BACKUP_DIR}"

	# 기존 파일에서 이 NIC 의 IP 설정 제거 (다른 인터페이스 설정은 유지)
	log_info "기존 netplan 파일에서 ${NIC} 의 주소 설정 제거..."
	for f in "${NETPLAN_DIR}"/*.yaml; do
		[ "$f" = "${NETPLAN_FILE}" ] && continue
		sudo python3 - "${NIC}" "$f" <<'PYEDIT'
import sys, yaml
nic, path = sys.argv[1], sys.argv[2]
with open(path) as fh:
    data = yaml.safe_load(fh) or {}
eth = (data.get("network") or {}).get("ethernets") or {}
if nic in eth:
    eth[nic] = {"dhcp4": False}
    with open(path, "w") as fh:
        yaml.safe_dump(data, fh, sort_keys=False, default_flow_style=False)
    print(f"       수정: {path}")
PYEDIT
	done

	# 새 netplan 파일
	{
		echo "# generated by setup-bridge-network.sh — ${NIC} → ${BRIDGE}"
		echo "network:"
		echo "  version: 2"
		[ -n "${RENDERER}" ] && echo "  renderer: ${RENDERER}"
		echo "  ethernets:"
		echo "    ${NIC}:"
		echo "      dhcp4: no"
		echo "  bridges:"
		echo "    ${BRIDGE}:"
		echo "      interfaces: [${NIC}]"
		echo "      parameters:"
		echo "        stp: false"
		echo "        forward-delay: 0"
		if [ "${IP_MODE}" = "dhcp" ]; then
			echo "      dhcp4: yes"
		else
			echo "      dhcp4: no"
			echo "      addresses: [${BR_ADDR}]"
			if [ -n "${BR_GW}" ]; then
				echo "      routes:"
				echo "        - to: default"
				echo "          via: ${BR_GW}"
			fi
			echo "      nameservers:"
			echo "        addresses: [$(echo "${BR_DNS}" | sed 's/ \+/, /g')]"
		fi
	} | sudo tee "${NETPLAN_FILE}" > /dev/null
	sudo chmod 600 "${NETPLAN_FILE}"
	log_success "작성: ${NETPLAN_FILE}"

	# cloud-init 이 netplan 을 관리 중이면 재부팅 시 원복되지 않도록 비활성화
	if [ "${CLOUD_INIT_NETPLAN}" -eq 1 ]; then
		echo "network: {config: disabled}" | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg > /dev/null
		log_success "cloud-init 네트워크 설정 비활성화: /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"
	fi

	log_info "netplan 문법 검증..."
	sudo netplan generate

	log_warn "netplan try 를 실행합니다. 적용 후 연결이 정상이면 120초 안에 Enter 를 누르세요. (누르지 않으면 자동 원복)"
	if sudo netplan try --timeout 120; then
		log_success "netplan 적용 완료"
	else
		log_error "netplan try 가 확정되지 않았거나 실패했습니다 (원복됨). 백업: ${BACKUP_DIR}"
		exit 1
	fi
fi

# ----- Step 2: libvirt 네트워크 -----
step_header "Step 2/3: libvirt 네트워크 정의 (${NETNAME})"
if [ "${NET_EXISTS}" -eq 1 ]; then
	CUR_BRIDGE=$(${VIRSH} net-dumpxml "${NETNAME}" 2>/dev/null | sed -nE "s/.*<bridge name='([^']+)'.*/\1/p" | head -n1 || true)
	if [ "${CUR_BRIDGE}" = "${BRIDGE}" ]; then
		log_info "이미 정의되어 있음 (bridge=${CUR_BRIDGE}) → 건너뜀"
	else
		log_warn "이미 정의되어 있으나 다른 브리지를 가리킵니다 (bridge=${CUR_BRIDGE:-?}). 수동 확인 필요: virsh net-dumpxml ${NETNAME}"
	fi
	${VIRSH} net-autostart "${NETNAME}" >/dev/null 2>&1 || true
	${VIRSH} net-start "${NETNAME}" >/dev/null 2>&1 || true
else
	NET_XML=$(mktemp)
	cat > "${NET_XML}" <<NETXML
<network>
  <name>${NETNAME}</name>
  <forward mode='bridge'/>
  <bridge name='${BRIDGE}'/>
</network>
NETXML
	${VIRSH} net-define "${NET_XML}"
	rm -f "${NET_XML}"
	${VIRSH} net-autostart "${NETNAME}"
	${VIRSH} net-start "${NETNAME}"
	log_success "정의 + autostart + 시작 완료"
fi

# ----- Step 3: 검증 -----
step_header "Step 3/3: 검증"
ip -brief addr show "${BRIDGE}" || log_warn "브리지 ${BRIDGE} 를 찾을 수 없습니다."
if [ "$(ip -o link show dev "${NIC}" | grep -oE 'master [^ ]+' | awk '{print $2}')" = "${BRIDGE}" ]; then
	log_success "${NIC} → ${BRIDGE} 소속 확인"
else
	log_warn "${NIC} 이(가) ${BRIDGE} 에 소속되어 있지 않습니다."
fi
${VIRSH} net-list --all | grep -E "Name|${NETNAME}" || true
GW_CHECK="${BR_GW:-$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -n1)}"
if [ -n "${GW_CHECK}" ]; then
	if ping -c 2 -W 2 "${GW_CHECK}" >/dev/null 2>&1; then
		log_success "게이트웨이 응답: ${GW_CHECK}"
	else
		log_warn "게이트웨이 응답 없음: ${GW_CHECK}"
	fi
fi

step_header "모든 설정이 완료되었습니다"
log_info "VM 생성 시 네트워크에서 '${NETNAME}' 을 선택하세요.  (create_ubuntu_vm.sh)"
