#!/bin/bash

# Download Ubuntu cloud images for KVM VM creation.
# Usage:
#   ./download-ubuntu-image.sh                 # download 20.04, 22.04, 24.04 (default)
#   ./download-ubuntu-image.sh ubuntu24.04     # download only 24.04
#   ./download-ubuntu-image.sh 22.04 24.04     # download multiple versions

# ---- pretty output helpers ----
info() { printf "\033[1;32m[ OK ]\033[0m %s\n" "$1"; }
warn() { printf "\033[1;33m[SKIP]\033[0m %s\n" "$1"; }
err()  { printf "\033[1;31m[FAIL]\033[0m %s\n" "$1" >&2; }
step() { printf "\033[1;36m[ .. ]\033[0m %s\n" "$1"; }

IMAGE_DIR="/var/lib/libvirt/images"
BASE_URL="https://cloud-images.ubuntu.com"

usage() {
	cat <<EOF
$(printf "\033[1;36mdownload-ubuntu-image.sh\033[0m") - Download Ubuntu cloud images for KVM

Usage:
  ./download-ubuntu-image.sh [VERSION ...]

Arguments:
  VERSION    Ubuntu version to download. Accepts: ubuntu24.04 | 24.04 | noble
                                                  ubuntu22.04 | 22.04 | jammy
                                                  ubuntu20.04 | 20.04 | focal
             If omitted, all supported versions are downloaded.

Options:
  -h, --help   Show this help message and exit.

Behavior:
  - Already-downloaded images are skipped (no re-download).
  - Images are saved to: ${IMAGE_DIR}

Examples:
  ./download-ubuntu-image.sh                  # download 20.04, 22.04, 24.04
  ./download-ubuntu-image.sh ubuntu24.04      # download only 24.04
  ./download-ubuntu-image.sh 22.04 24.04      # download multiple versions
EOF
}

# Map os-variant -> "codename:image-filename"
get_image_info() {
	case "$1" in
		ubuntu24.04|24.04|noble)
			echo "noble:noble-server-cloudimg-amd64.img"
			;;
		ubuntu22.04|22.04|jammy)
			echo "jammy:jammy-server-cloudimg-amd64.img"
			;;
		ubuntu20.04|20.04|focal)
			echo "focal:focal-server-cloudimg-amd64.img"
			;;
		*)
			echo ""
			;;
	esac
}

# Help option
for arg in "$@"; do
	case "$arg" in
		-h|--help)
			usage
			exit 0
			;;
	esac
done

# Default: all supported versions
if [ "$#" -eq 0 ]; then
	set -- ubuntu20.04 ubuntu22.04 ubuntu24.04
fi

sudo mkdir -p "${IMAGE_DIR}"

for VERSION in "$@"; do
	INFO=$(get_image_info "${VERSION}")

	if [ -z "${INFO}" ]; then
		err "Unsupported version: ${VERSION}"
		printf "       supported: ubuntu20.04, ubuntu22.04, ubuntu24.04\n" >&2
		exit 1
	fi

	CODENAME="${INFO%%:*}"
	IMG_NAME="${INFO##*:}"
	IMG_PATH="${IMAGE_DIR}/${IMG_NAME}"
	IMG_URL="${BASE_URL}/${CODENAME}/current/${IMG_NAME}"

	if [ -f "${IMG_PATH}" ]; then
		warn "${VERSION} already exists: ${IMG_PATH}"
		continue
	fi

	step "${VERSION} downloading: ${IMG_URL}"
	if sudo wget -q --show-progress -O "${IMG_PATH}" "${IMG_URL}"; then
		info "${VERSION} done: ${IMG_PATH}"
	else
		err "${VERSION} download failed"
		sudo rm -f "${IMG_PATH}"
		exit 1
	fi
done
