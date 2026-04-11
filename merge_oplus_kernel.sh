#!/usr/bin/env bash
# merge_oplus_kernel.sh
# Strategy: Google android15-6.6 as base, overlay all OEM-specific content from cctv18
# Usage: ./merge_oplus_kernel.sh [--push]
set -euo pipefail

###############################################################################
# CONFIG — override via env vars if needed
###############################################################################
GOOGLE_REPO="https://android.googlesource.com/kernel/common"
GOOGLE_BRANCH="android15-6.6"
CCTV18_REPO="https://github.com/cctv18/android_kernel_common_oneplus_sm8750"
CCTV18_BRANCH="oneplus/sm8750_v_16.0.0_oneplus_13_6.6.89"
WORKDIR="${WORKDIR:-$(pwd)/kernel_merge_workdir}"
TARGET_BRANCH="${TARGET_BRANCH:-merge/android15-6.6-oplus}"
PUSH="${1:-}"   # pass --push to actually push at end
GIT_USER="${GIT_USER:-github-actions[bot]}"
GIT_EMAIL="${GIT_EMAIL:-github-actions[bot]@users.noreply.github.com}"

###############################################################################
# OEM directory/file patterns to overlay from cctv18
# Covers: oplus, oppo, oneplus, coloros, sm8750-specific trees
###############################################################################
OEM_DIRS=(
    "drivers/vendor/oplus"
    "drivers/vendor/qcom"       # sm8750 qcom vendor drivers
    "drivers/input/touchscreen/oplus_touchscreen_v2"
    "drivers/misc/oplus_motor"
    "drivers/soc/oplus"
    "drivers/gpu/drm/oplus"
    "drivers/net/wireless/qualcomm/qca_cld3_oplus"
    "sound/soc/oplus"
    "fs/proc/oplus_fs_utils.c"
    "fs/proc/oplus_fs_utils.h"
)

# Top-level dirs that may exist in cctv18 entirely
OEM_TOPLEVEL_DIRS=(
    "oplus"
    "oppo"
    "coloros"
)

# Kconfig/defconfig/Makefile patterns (grep-based scan, see detect_oem_files())
OEM_PATTERNS=(
    "oplus"
    "oppo"
    "oneplus"
    "coloros"
    "sm8750"
)

# arch configs
OEM_ARCH_CONFIGS=(
    "arch/arm64/configs/gki_defconfig_oplus"
    "arch/arm64/configs/vendor/oplus"
    "arch/arm64/configs/vendor/sm8750"
    "arch/arm64/configs/oplus_gki.config"
)

###############################################################################
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

###############################################################################
setup_git() {
    git config --global user.name  "$GIT_USER"
    git config --global user.email "$GIT_EMAIL"
    git config --global advice.detachedHead false
    git config --global merge.conflictStyle diff3
}

###############################################################################
clone_bases() {
    log "Cloning Google GKI base ($GOOGLE_BRANCH) — depth=1 ..."
    git clone --depth=1 -b "$GOOGLE_BRANCH" "$GOOGLE_REPO" "$WORKDIR/google" \
        || die "Failed to clone Google GKI"

    log "Cloning cctv18 OEM source ($CCTV18_BRANCH) — depth=1 ..."
    git clone --depth=1 -b "$CCTV18_BRANCH" "$CCTV18_REPO" "$WORKDIR/cctv18" \
        || die "Failed to clone cctv18"
}

###############################################################################
# Detect any extra OEM paths in cctv18 that aren't in our explicit list
detect_oem_files() {
    local src="$WORKDIR/cctv18"
    log "Scanning cctv18 for OEM-specific paths not in explicit list ..."

    # Find top-level dirs unique to cctv18 (not in google)
    while IFS= read -r d; do
        local name
        name=$(basename "$d")
        local already=false
        for pattern in "${OEM_PATTERNS[@]}"; do
            if echo "$name" | grep -qi "$pattern"; then
                already=true; break
            fi
        done
        if $already && [[ ! -d "$WORKDIR/google/$name" ]]; then
            log "  Auto-detected top-level OEM dir: $name"
            OEM_TOPLEVEL_DIRS+=("$name")
        fi
    done < <(find "$src" -maxdepth 1 -mindepth 1 -type d)

    # Scan drivers/ for oem subdirs
    if [[ -d "$src/drivers" ]]; then
        while IFS= read -r d; do
            local rel="${d#$src/}"
            # Check if this path exists in google — if not, it's OEM-only
            if [[ ! -d "$WORKDIR/google/$rel" ]]; then
                local is_oem=false
                for p in "${OEM_PATTERNS[@]}"; do
                    if echo "$rel" | grep -qi "$p"; then is_oem=true; break; fi
                done
                if $is_oem; then
                    # deduplicate
                    local dup=false
                    for existing in "${OEM_DIRS[@]}"; do
                        [[ "$existing" == "$rel" ]] && dup=true && break
                    done
                    $dup || OEM_DIRS+=("$rel")
                fi
            fi
        done < <(find "$src/drivers" -mindepth 1 -maxdepth 3 -type d)
    fi
}

###############################################################################
copy_oem_overlay() {
    local src="$WORKDIR/cctv18"
    local dst="$WORKDIR/merged"

    log "Copying OEM directories ..."

    # Top-level dirs (oplus/, coloros/ etc.)
    for d in "${OEM_TOPLEVEL_DIRS[@]}"; do
        if [[ -d "$src/$d" ]]; then
            log "  Overlay: $d/"
            cp -a "$src/$d" "$dst/$d"
        fi
    done

    # Explicit sub-paths
    for rel in "${OEM_DIRS[@]}"; do
        if [[ -d "$src/$rel" ]]; then
            log "  Overlay dir: $rel"
            mkdir -p "$dst/$(dirname "$rel")"
            cp -a "$src/$rel" "$dst/$(dirname "$rel")/"
        elif [[ -f "$src/$rel" ]]; then
            log "  Overlay file: $rel"
            mkdir -p "$dst/$(dirname "$rel")"
            cp -a "$src/$rel" "$dst/$rel"
        fi
    done

    # Arch configs
    for rel in "${OEM_ARCH_CONFIGS[@]}"; do
        if [[ -e "$src/$rel" ]]; then
            log "  Overlay config: $rel"
            mkdir -p "$dst/$(dirname "$rel")"
            cp -a "$src/$rel" "$dst/$rel"
        fi
    done

    # Scan cctv18 Kconfig/Makefile for oplus/oppo includes pointing to paths
    # that don't exist in google → copy those paths too
    log "  Scanning Makefiles/Kconfigs for implicit OEM references ..."
    while IFS= read -r makefile; do
        local rel_mk="${makefile#$src/}"
        grep -oP '(?<=obj-\$\()[A-Z_]+\)[ \t]+=[ \t]+\K\S+' "$makefile" 2>/dev/null || true
        # find lines like: source "drivers/vendor/oplus/Kconfig"
        while IFS= read -r ref; do
            ref="${ref//\"/}"
            if [[ -e "$src/$ref" ]] && [[ ! -e "$WORKDIR/google/$ref" ]]; then
                local dup=false
                for existing in "${OEM_DIRS[@]}"; do
                    [[ "$existing" == "$ref" || "$ref" == "$existing"* ]] && dup=true && break
                done
                if ! $dup; then
                    log "    Pulled in via Kconfig ref: $ref"
                    mkdir -p "$dst/$(dirname "$ref")"
                    cp -a "$src/$ref" "$dst/$ref" 2>/dev/null || true
                fi
            fi
        done < <(grep -oP '(?<=source ")[^"]+' "$makefile" 2>/dev/null || true)
    done < <(find "$src" -name 'Kconfig' -o -name 'Makefile' | head -500)
}

###############################################################################
# Patch root Makefile/Kconfig in merged tree to include oplus entries
# if they're missing (cctv18 already has them, but google base may not)
patch_makefiles() {
    local dst="$WORKDIR/merged"
    log "Patching root Makefile / drivers/Makefile for OEM includes ..."

    # drivers/Makefile — add oplus vendor include if present but not referenced
    local drv_mk="$dst/drivers/Makefile"
    if [[ -f "$drv_mk" ]] && [[ -d "$dst/drivers/vendor/oplus" ]]; then
        if ! grep -q "vendor/oplus" "$drv_mk"; then
            echo "" >> "$drv_mk"
            echo "# OEM vendor drivers" >> "$drv_mk"
            echo 'obj-$(CONFIG_OPLUS_DRIVERS)	+= vendor/oplus/' >> "$drv_mk"
            log "  Patched drivers/Makefile → vendor/oplus"
        fi
    fi

    # drivers/Kconfig
    local drv_kc="$dst/drivers/Kconfig"
    if [[ -f "$drv_kc" ]] && [[ -f "$dst/drivers/vendor/oplus/Kconfig" ]]; then
        if ! grep -q "vendor/oplus" "$drv_kc"; then
            echo "" >> "$drv_kc"
            echo 'source "drivers/vendor/oplus/Kconfig"' >> "$drv_kc"
            log "  Patched drivers/Kconfig → vendor/oplus"
        fi
    fi
}

###############################################################################
create_merged_repo() {
    log "Creating merged repo from Google base ..."
    cp -a "$WORKDIR/google" "$WORKDIR/merged"

    # Add cctv18 as remote (for proper git history / cherry-pick capability later)
    cd "$WORKDIR/merged"
    git remote add cctv18 "$CCTV18_REPO" 2>/dev/null || true

    # Create working branch
    git checkout -b "$TARGET_BRANCH"
}

###############################################################################
commit_oem_overlay() {
    cd "$WORKDIR/merged"
    git add -A
    if git diff --cached --quiet; then
        log "Nothing to commit — OEM overlay was empty or identical to Google base"
        return
    fi

    local google_sha cctv18_sha
    google_sha=$(git -C "$WORKDIR/google" rev-parse --short HEAD)
    cctv18_sha=$(git -C "$WORKDIR/cctv18" rev-parse --short HEAD)

    git commit -m "overlay: import OEM drivers from cctv18 onto Google GKI android15-6.6

Google base:  $GOOGLE_BRANCH @ $google_sha
OEM source:   $CCTV18_BRANCH @ $cctv18_sha

Imported directories:
$(printf '  - %s\n' "${OEM_TOPLEVEL_DIRS[@]}" "${OEM_DIRS[@]}" "${OEM_ARCH_CONFIGS[@]}" | sort -u)

Auto-patched: drivers/Makefile, drivers/Kconfig to include oplus entries.
Conflicts (if any) must be resolved manually before building."
    log "Committed OEM overlay."
}

###############################################################################
push_to_origin() {
    cd "$WORKDIR/merged"
    if [[ -z "${GITHUB_TOKEN:-}" ]] && [[ -z "$(git remote get-url origin 2>/dev/null || true)" ]]; then
        log "WARNING: No GITHUB_TOKEN and no origin remote — skipping push."
        log "Set GITHUB_TOKEN and TARGET_REPO env vars, or add origin manually."
        return
    fi

    if [[ -n "${TARGET_REPO:-}" ]]; then
        local push_url="https://${GITHUB_TOKEN}@github.com/${TARGET_REPO}.git"
        git remote set-url origin "$push_url" 2>/dev/null \
            || git remote add origin "$push_url"
    fi

    log "Pushing branch $TARGET_BRANCH to origin ..."
    git push -u origin "$TARGET_BRANCH" --force
    log "Push complete."
}

###############################################################################
print_conflict_hints() {
    log ""
    log "=== POST-MERGE CHECKLIST ==="
    log "If git reports conflicts after manual merge, resolve them:"
    log "  1. grep -r '<<<<<<' $WORKDIR/merged  # find conflict markers"
    log "  2. Check drivers/Makefile and drivers/Kconfig for duplicate entries"
    log "  3. Compare arch/arm64/configs/ — merge defconfigs manually"
    log "  4. Run: cd $WORKDIR/merged && git add -A && git commit"
    log ""
    log "Common conflict areas in GKI + OEM overlays:"
    log "  - include/linux/sched.h (oplus task extensions)"
    log "  - fs/proc/task_mmu.c    (oplus memory hooks)"
    log "  - kernel/fork.c         (oplus task_struct additions)"
    log "  - net/core/             (oplus network hooks)"
    log "  - drivers/android/      (binder oplus patches)"
    log ""
}

###############################################################################
main() {
    log "=== OEM Kernel Overlay Script ==="
    log "  Google: $GOOGLE_BRANCH"
    log "  OEM:    $CCTV18_BRANCH"
    log "  Output: $WORKDIR"
    mkdir -p "$WORKDIR"
    setup_git
    clone_bases
    detect_oem_files
    create_merged_repo
    copy_oem_overlay
    patch_makefiles
    commit_oem_overlay
    print_conflict_hints
    [[ "$PUSH" == "--push" ]] && push_to_origin || log "Dry run — pass --push to push."
    log "Done. Merged tree at: $WORKDIR/merged"
}

main "$@"
