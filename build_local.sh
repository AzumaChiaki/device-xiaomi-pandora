#!/usr/bin/env bash
if [[ -z "${BASH_VERSION:-}" ]]; then
    exec bash "$0" "$@"
fi
set -euo pipefail

SOURCE_FILE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "${SOURCE_FILE}")" && pwd)"

MANIFEST_BRANCH="14.1"
WORK_ROOT="${HOME}/orangefox-local"
SOURCE_ROOT=""
SYNC_REPO_URL="https://gitlab.com/OrangeFox/sync.git"
DEVICE_TREE_DIR="${SCRIPT_DIR}"
DEVICE_PATH="device/xiaomi/pandora"
LUNCH_TARGET="twrp_pandora-eng"
BUILD_TARGET="recoveryimage"
JOBS="${NPROC:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 8)}"
CCACHE_SIZE="80G"
INSTALL_DEPS=0
RUN_SYNC=1
RUN_PREPARE=1
RUN_CLOBBER=0
IMAGES_DIR=""

usage() {
    cat <<'EOF'
Usage: ./build_local.sh [options]

Options:
  --branch <12.1|14.1>         OrangeFox manifest branch (default: 14.1)
  --work-root <path>           Work directory root (default: ~/orangefox-local)
  --source-root <path>         Explicit source directory (overrides --work-root)
  --device-tree <path>         OFRP device tree path (default: current repo)
  --device-path <path>         Device path in source tree (default: device/xiaomi/pandora)
  --lunch <target>             Lunch target (default: twrp_pandora-eng)
  --target <make-target>       Build target (default: recoveryimage)
  --jobs <n>                   Parallel jobs (default: host CPU threads)
  --ccache-size <size>         ccache max size (default: 80G)
  --images-dir <path>          Firmware images dir for prepare_from_plg.sh
  --install-deps               Install dependencies automatically (Arch/Ubuntu)
  --no-sync                    Skip source sync (use existing source tree)
  --no-prepare                 Skip prepare_from_plg.sh
  --clobber                    Run mka clobber before build
  -h, --help                   Show this help

Examples:
  ./build_local.sh --install-deps --branch 14.1 --target recoveryimage
  ./build_local.sh --no-sync --source-root ~/fox_14.1 --jobs 16
EOF
}

log() {
    printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch) MANIFEST_BRANCH="${2:?missing value}"; shift 2 ;;
        --work-root) WORK_ROOT="${2:?missing value}"; shift 2 ;;
        --source-root) SOURCE_ROOT="${2:?missing value}"; shift 2 ;;
        --device-tree) DEVICE_TREE_DIR="${2:?missing value}"; shift 2 ;;
        --device-path) DEVICE_PATH="${2:?missing value}"; shift 2 ;;
        --lunch) LUNCH_TARGET="${2:?missing value}"; shift 2 ;;
        --target) BUILD_TARGET="${2:?missing value}"; shift 2 ;;
        --jobs) JOBS="${2:?missing value}"; shift 2 ;;
        --ccache-size) CCACHE_SIZE="${2:?missing value}"; shift 2 ;;
        --images-dir) IMAGES_DIR="${2:?missing value}"; shift 2 ;;
        --install-deps) INSTALL_DEPS=1; shift ;;
        --no-sync) RUN_SYNC=0; shift ;;
        --no-prepare) RUN_PREPARE=0; shift ;;
        --clobber) RUN_CLOBBER=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

if [[ -z "${SOURCE_ROOT}" ]]; then
    SOURCE_ROOT="${WORK_ROOT}/fox_${MANIFEST_BRANCH}"
fi

if [[ -z "${IMAGES_DIR}" ]]; then
    IMAGES_DIR="${DEVICE_TREE_DIR}/plg/images"
fi

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

install_dependencies() {
    [[ "${INSTALL_DEPS}" -eq 1 ]] || return 0
    [[ -f /etc/os-release ]] || die "--install-deps requires Linux with /etc/os-release"
    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" == "arch" ]]; then
        log "Installing dependencies via pacman (Arch Linux)"
        sudo pacman -Syu --needed --noconfirm \
            base-devel git repo python python-pip unzip zip rsync ccache \
            bc bison flex gperf lz4 zstd cpio xmlstarlet openssl libxml2 \
            perl-switch perl-xml-simple inetutils
    elif [[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *"ubuntu"* || "${ID_LIKE:-}" == *"debian"* ]]; then
        log "Installing dependencies via apt (Ubuntu/Debian)"
        sudo apt-get update
        sudo apt-get install -y \
            git-core repo python3 python3-pip unzip zip rsync ccache \
            bc bison build-essential curl flex g++-multilib gcc-multilib gperf \
            liblz4-tool libncurses5-dev libncurses5 libxml2-utils lz4 zstd cpio \
            libssl-dev openjdk-11-jdk
    else
        die "unsupported distro for --install-deps: ${ID:-unknown}"
    fi
}

sync_sources() {
    [[ "${RUN_SYNC}" -eq 1 ]] || return 0
    mkdir -p "${WORK_ROOT}"
    local sync_dir="${WORK_ROOT}/sync"

    if [[ ! -d "${sync_dir}/.git" ]]; then
        log "Cloning OrangeFox sync utility"
        git clone "${SYNC_REPO_URL}" "${sync_dir}"
    else
        log "Updating OrangeFox sync utility"
        git -C "${sync_dir}" pull --ff-only
    fi

    log "Syncing OrangeFox source branch ${MANIFEST_BRANCH} to ${SOURCE_ROOT}"
    (
        cd "${sync_dir}"
        bash "./orangefox_sync.sh" --branch "${MANIFEST_BRANCH}" --path "${SOURCE_ROOT}"
    )
}

copy_device_tree() {
    [[ -d "${DEVICE_TREE_DIR}" ]] || die "device tree path not found: ${DEVICE_TREE_DIR}"
    local target_dir="${SOURCE_ROOT}/${DEVICE_PATH}"
    mkdir -p "${target_dir}"

    log "Syncing device tree into source: ${target_dir}"
    rsync -a --delete \
        --exclude ".git" \
        --exclude "out" \
        --exclude ".repo" \
        --exclude ".idea" \
        --exclude ".vscode" \
        "${DEVICE_TREE_DIR}/" "${target_dir}/"
}

run_prepare() {
    [[ "${RUN_PREPARE}" -eq 1 ]] || return 0
    local target_dir="${SOURCE_ROOT}/${DEVICE_PATH}"
    [[ -x "${target_dir}/prepare_from_plg.sh" ]] || die "prepare_from_plg.sh not executable in ${target_dir}"
    [[ -d "${IMAGES_DIR}" ]] || die "images dir not found: ${IMAGES_DIR}"

    log "Running prepare_from_plg.sh with images: ${IMAGES_DIR}"
    bash "${target_dir}/prepare_from_plg.sh" "${IMAGES_DIR}"
}

build_recovery() {
    [[ -f "${SOURCE_ROOT}/build/envsetup.sh" ]] || die "build/envsetup.sh not found: ${SOURCE_ROOT}"
    need_cmd bash
    need_cmd repo
    need_cmd rsync
    need_cmd python3
    need_cmd lz4
    need_cmd cpio
    need_cmd ccache

    log "Configuring ccache (${CCACHE_SIZE})"
    export USE_CCACHE=1
    ccache -M "${CCACHE_SIZE}" >/dev/null

    local build_cmd="
        set -euo pipefail
        cd '${SOURCE_ROOT}'
        source build/envsetup.sh
        lunch '${LUNCH_TARGET}'
        if [[ '${RUN_CLOBBER}' -eq 1 ]]; then
            mka clobber
        fi
        mka -j'${JOBS}' '${BUILD_TARGET}'
    "

    log "Starting build: lunch=${LUNCH_TARGET}, target=${BUILD_TARGET}, jobs=${JOBS}"
    bash -lc "${build_cmd}"
}

print_artifacts() {
    local product_out="${SOURCE_ROOT}/out/target/product/pandora"
    log "Build finished. Common artifact locations:"
    echo "  - ${product_out}/recovery.img"
    echo "  - ${product_out}/boot.img"
    echo "  - ${product_out}/OrangeFox*.zip"
}

install_dependencies
sync_sources
copy_device_tree
run_prepare
build_recovery
print_artifacts
