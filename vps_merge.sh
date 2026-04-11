#!/usr/bin/env bash
# vps_merge.sh — run on Rocky Linux aarch64 VPS as fallback
# Usage:
#   export GITHUB_TOKEN=ghp_xxx
#   export TARGET_REPO=palazik/your-new-repo
#   bash vps_merge.sh [--push]
set -euo pipefail

PUSH="${1:-}"
WORKDIR="${WORKDIR:-$HOME/kernel_merge_workdir}"
TARGET_BRANCH="${TARGET_BRANCH:-merge/android15-6.6-oplus}"
GOOGLE_BRANCH="android15-6.6"
CCTV18_BRANCH="oneplus/sm8750_v_16.0.0_oneplus_13_6.6.89"

###############################################################################
# Deps — Rocky Linux / RHEL
###############################################################################
install_deps() {
    echo "[*] Installing dependencies ..."
    sudo dnf install -y git curl rsync python3 || true
    # git-lfs if needed
    sudo dnf install -y git-lfs 2>/dev/null || true
    git config --global user.name  "palazik-bot"
    git config --global user.email "palazik@users.noreply.github.com"
    git config --global advice.detachedHead false
}

###############################################################################
# Disk check — kernel trees are ~2GB each
###############################################################################
check_disk() {
    local avail
    avail=$(df -BG "$HOME" | awk 'NR==2{print $4}' | tr -d 'G')
    if (( avail < 10 )); then
        echo "WARNING: Only ${avail}GB free — may not be enough for two kernel trees."
    else
        echo "[*] Disk OK: ${avail}GB available"
    fi
}

###############################################################################
clone_or_update() {
    local url="$1" branch="$2" dir="$3"
    if [[ -d "$dir/.git" ]]; then
        echo "[*] Updating $dir ..."
        git -C "$dir" fetch --depth=1 origin "$branch"
        git -C "$dir" checkout FETCH_HEAD
    else
        echo "[*] Cloning $url ($branch) → $dir ..."
        git clone --depth=1 -b "$branch" "$url" "$dir"
    fi
}

###############################################################################
main() {
    install_deps
    check_disk
    mkdir -p "$WORKDIR"
    cd "$WORKDIR"

    clone_or_update \
        "https://android.googlesource.com/kernel/common" \
        "$GOOGLE_BRANCH" \
        "google_src"

    clone_or_update \
        "https://github.com/cctv18/android_kernel_common_oneplus_sm8750" \
        "$CCTV18_BRANCH" \
        "cctv18_src"

    # Delegate to main script
    WORKDIR="$WORKDIR" \
    TARGET_BRANCH="$TARGET_BRANCH" \
    GOOGLE_REPO="https://android.googlesource.com/kernel/common" \
    CCTV18_REPO="https://github.com/cctv18/android_kernel_common_oneplus_sm8750" \
        bash "$(dirname "$0")/merge_oplus_kernel.sh" "$PUSH"
}

main "$@"
