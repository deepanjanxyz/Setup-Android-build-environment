#!/usr/bin/env bash
#
# ARM64 Android Build Environment Setup
# -------------------------------------
# Detects OS, package manager, architecture (must be aarch64).
# Ensures Java 21 (installs if missing or older than 17).
# Installs Android SDK (official Google) and system AAPT2.
# Prompts for ReVanced AAPT2 (simplified logic per OS).
# Configures Gradle overrides. Never touches project source code.
#
# Usage:
#   ./install.sh [--check] [--verbose]
#   --check    Only check and report, no changes.
#   --verbose  Show detailed logs.

set -o pipefail

# ----------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------
TOOL_NAME="arm64-android-build-env"
TOOL_VERSION="24.2.0"
STATE_DIR="${HOME}/.local/share/${TOOL_NAME}"
STATE_FILE="${STATE_DIR}/state.json"
LOG_DIR="${STATE_DIR}/logs"
LOG_FILE="${LOG_DIR}/install-$(date +%Y-%m-%d).log"
# Sourcing this file gives any shell (or CI step) the full environment:
# ANDROID_HOME, ANDROID_SDK_ROOT, JAVA_HOME, PATH and GRADLE_OPTS.
ENV_FILE="${STATE_DIR}/env.sh"

# Java packages (target OpenJDK 21)
JAVA_PKG_TERMUX="openjdk-21"
JAVA_PKG_DEBIAN="openjdk-21-jdk"
JAVA_PKG_ARCH="jdk-openjdk"          # Arch rolling, usually 21+
JAVA_PKG_FEDORA="java-21-openjdk"
JAVA_PKG_ALPINE="openjdk21"

# AAPT2 packages
AAPT2_PKG_TERMUX="aapt2"
AAPT2_PKG_DEBIAN=("aapt2" "aapt" "android-sdk-build-tools")
AAPT2_PKG_ARCH="android-tools"
AAPT2_PKG_FEDORA=("aapt2" "aapt")
AAPT2_PKG_ALPINE=("aapt2" "aapt")

# Official Android SDK command line tools (Google)
SDKMANAGER_URL="https://dl.google.com/android/repository/commandlinetools-linux-15859902_latest.zip"
SDKMANAGER_SHA256=""   # optional

# ReVanced modern ARM64 AAPT2 binary
REVANCED_AAPT2_URL="https://github.com/ReVanced/aapt2/releases/download/v1.1.0/aapt2-arm64-v8a"

# ----------------------------------------------------------------------
# AAPT2 minimum version requirement (issue #13)
# ----------------------------------------------------------------------
# Modern AGP (8.x/9.x) invokes `aapt2 compile --source-path`, so a usable
# AAPT2 MUST support that flag. Note that every upstream AAPT2 reports
# version "2.19-<build>" (Debian's reports "2.19-debian"), so the reliable
# minimum-requirement test is the capability probe below;
# AAPT2_MIN_BUILD only acts as an additional floor for binaries that DO
# report a numeric build id (it is 0 = disabled by default).
AAPT2_MIN_BUILD=0

# ----------------------------------------------------------------------
# Logging & Args
# ----------------------------------------------------------------------
mkdir -p "${LOG_DIR}" 2>/dev/null
exec 2>>"${LOG_FILE}"

VERBOSE=false
CHECK_ONLY=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)   CHECK_ONLY=true ;;
        --verbose) VERBOSE=true ;;
        --help)    cat <<EOF
Usage: $0 [--check] [--verbose]
  --check    Only check and report, no changes.
  --verbose  Show detailed output.
EOF
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

log() {
    local level="$1"; shift
    local msg="$*"
    local ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] [${level}] ${msg}" >> "${LOG_FILE}"
    if [[ "${VERBOSE}" == "true" || "${level}" != "DEBUG" ]]; then
        case "${level}" in
            ERROR)   echo -e "\e[31m[ERROR]\e[0m ${msg}" ;;
            WARNING) echo -e "\e[33m[WARNING]\e[0m ${msg}" ;;
            INFO)    echo -e "\e[32m[INFO]\e[0m ${msg}" ;;
            DEBUG)   echo -e "\e[90m[DEBUG]\e[0m ${msg}" ;;
            *)       echo "${msg}" ;;
        esac
    fi
}
info()  { log "INFO" "$@"; }
warn()  { log "WARNING" "$@"; }
error() { log "ERROR" "$@"; }
debug() { log "DEBUG" "$@"; }

# ----------------------------------------------------------------------
# OS / Package Manager Detection
# ----------------------------------------------------------------------
detect_os() {
    info "Detecting OS and package manager..."

    # ------------------------------------------------------------------
    # Privilege detection (issue #5):
    # When the script runs as a non-root user, prepend sudo to the
    # system package manager commands so installation does not fail
    # with permission errors. Termux never uses sudo (no root by design).
    # ------------------------------------------------------------------
    SUDO=""
    if [[ ${EUID} -eq 0 ]]; then
        info "Running as root; package commands will be executed directly."
    elif command -v sudo &>/dev/null; then
        SUDO="sudo"
        info "Running as non-root; sudo will be used for package installation."
    else
        warn "Running as non-root and sudo is not available; package installation may fail."
    fi

    OS_NAME="unknown"
    PKG_MANAGER="none"
    INSTALL_CMD=""
    UPDATE_CMD=""

    # Termux detection
    if [[ -n "${PREFIX}" && "${PREFIX}" == *"com.termux"* ]]; then
        OS_NAME="termux"
        PKG_MANAGER="pkg"
        INSTALL_CMD="pkg install -y"
        UPDATE_CMD="pkg update -y && pkg upgrade -y"
    elif command -v pacman &>/dev/null; then
        OS_NAME="arch"
        PKG_MANAGER="pacman"
        INSTALL_CMD="${SUDO} pacman -S --noconfirm"
        UPDATE_CMD="${SUDO} pacman -Syu --noconfirm"
    elif command -v apt-get &>/dev/null; then
        OS_NAME="debian"
        PKG_MANAGER="apt-get"
        INSTALL_CMD="${SUDO} apt-get install -y"
        UPDATE_CMD="${SUDO} apt-get update"
    elif command -v dnf &>/dev/null; then
        OS_NAME="fedora"
        PKG_MANAGER="dnf"
        INSTALL_CMD="${SUDO} dnf install -y"
        UPDATE_CMD="${SUDO} dnf check-update || true"
    elif command -v apk &>/dev/null; then
        OS_NAME="alpine"
        PKG_MANAGER="apk"
        INSTALL_CMD="${SUDO} apk add"
        UPDATE_CMD="${SUDO} apk update"
    else
        OS_NAME="unknown"
        PKG_MANAGER="none"
    fi

    ARCH="$(uname -m)"
    case "${ARCH}" in
        aarch64|arm64) ARCH_LABEL="ARM64"; ARCH="aarch64" ;;
        *) ARCH_LABEL="unknown"; ARCH="unknown" ;;
    esac

    info "OS: ${OS_NAME} (${ARCH_LABEL})"
    info "Package Manager: ${PKG_MANAGER}"
    if [[ "${ARCH}" != "aarch64" ]]; then
        error "This script only supports ARM64 (aarch64). Detected: ${ARCH_LABEL}."
        exit 1
    fi
    if [[ "${PKG_MANAGER}" == "none" ]]; then
        error "No supported package manager detected."
        exit 1
    fi
}

run_cmd() {
    "$@"
}

run_update() {
    info "Running system update..."
    [[ -n "${UPDATE_CMD}" ]] && run_cmd bash -c "${UPDATE_CMD}"
}

install_pkg() {
    local pkg="$1"
    info "Installing ${pkg} via ${PKG_MANAGER}..."
    run_cmd ${INSTALL_CMD} "${pkg}"
}

# ----------------------------------------------------------------------
# Java version check (returns major version number, 0 if not found)
# ----------------------------------------------------------------------
get_java_major() {
    local java_bin="$1"
    if [[ -z "${java_bin}" || ! -x "${java_bin}" ]]; then
        echo "0"
        return
    fi
    local version_output
    version_output="$( "${java_bin}" -version 2>&1 | head -n 1 )"
    local major=""
    major=$(echo "${version_output}" | sed -n 's/.*version "\([0-9]*\)\..*/\1/p')
    if [[ -z "${major}" ]]; then
        major=$(echo "${version_output}" | sed -n 's/.*version "1\.\([0-9]*\)\..*/\1/p')
    fi
    if [[ -z "${major}" || ! "${major}" =~ ^[0-9]+$ ]]; then
        major="0"
    fi
    echo "${major}"
}

# ----------------------------------------------------------------------
# Java installation and configuration
# ----------------------------------------------------------------------
install_java() {
    info "Installing Java (target OpenJDK 21)..."
    case "${OS_NAME}" in
        termux)
            install_pkg "${JAVA_PKG_TERMUX}"
            ;;
        debian)
            install_pkg "${JAVA_PKG_DEBIAN}"
            ;;
        arch)
            install_pkg "${JAVA_PKG_ARCH}"
            ;;
        fedora)
            install_pkg "${JAVA_PKG_FEDORA}"
            ;;
        alpine)
            install_pkg "${JAVA_PKG_ALPINE}"
            ;;
        *) error "No Java package defined for ${OS_NAME}"; return 1 ;;
    esac

    # After installation, find Java binary and determine its major version
    local java_bin
    java_bin="$(command -v java || true)"
    if [[ -z "${java_bin}" ]]; then
        error "Java installation failed: java not found in PATH."
        return 1
    fi
    local major
    major=$(get_java_major "${java_bin}")
    if [[ ${major} -lt 17 ]]; then
        error "Installed Java version ${major} is still less than 17. Please install JDK 21 manually."
        return 1
    fi

    # Set Java 21 as default if multiple versions exist (Linux only)
    if [[ "${OS_NAME}" != "termux" && -x "/usr/sbin/update-alternatives" ]]; then
        local jdk21_bin=""
        local jdk21_javac=""
        for dir in /usr/lib/jvm/*21*; do
            if [[ -x "${dir}/bin/java" ]]; then
                jdk21_bin="${dir}/bin/java"
                jdk21_javac="${dir}/bin/javac"
                break
            fi
        done
        if [[ -n "${jdk21_bin}" ]]; then
            info "Setting Java 21 as default via update-alternatives..."
            ${SUDO} update-alternatives --set java "${jdk21_bin}" || warn "update-alternatives failed, but continuing."
            if [[ -x "${jdk21_javac}" ]]; then
                ${SUDO} update-alternatives --set javac "${jdk21_javac}" || warn "Failed to set javac alternative."
            else
                warn "javac not found in JDK 21 directory; skipping javac alternative."
            fi
        else
            warn "Could not locate JDK 21 directory for alternatives."
        fi
    fi

    # Export JAVA_HOME
    local java_home=""
    if [[ -x "${java_bin}" ]]; then
        java_home="$(dirname "$(dirname "$(readlink -f "${java_bin}")")")"
    fi
    if [[ -z "${java_home}" || ! -d "${java_home}" ]]; then
        warn "Could not determine JAVA_HOME automatically. You may need to set it manually."
    else
        info "Setting JAVA_HOME=${java_home} in shell rc files and current session."
        for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
            if [[ -f "${rc}" ]]; then
                sed -i '/^export JAVA_HOME=/d' "${rc}"
                echo "export JAVA_HOME=\"${java_home}\"" >> "${rc}"
            else
                echo "export JAVA_HOME=\"${java_home}\"" > "${rc}"
            fi
        done
        export JAVA_HOME="${java_home}"
    fi

    JAVA_STATUS="VALID"
    JAVA_INFO="$( ${java_bin} -version 2>&1 | head -n 1 )"
}

# ----------------------------------------------------------------------
# Component Checks (for reporting)
# ----------------------------------------------------------------------
check_java() {
    if command -v java &>/dev/null; then
        local java_bin
        java_bin="$(command -v java)"
        local major
        major=$(get_java_major "${java_bin}")
        if [[ ${major} -ge 17 ]]; then
            JAVA_STATUS="VALID"
            JAVA_INFO="$( ${java_bin} -version 2>&1 | head -n1 )"
        else
            JAVA_STATUS="INVALID"
            JAVA_INFO="Java major version ${major} is too old (need 17+). Will install JDK 21."
        fi
    else
        JAVA_STATUS="MISSING"
        JAVA_INFO="No Java found"
    fi
}

check_sdk() {
    local sdk_root=""
    [[ -n "${ANDROID_HOME}" && -d "${ANDROID_HOME}" ]] && sdk_root="${ANDROID_HOME}"
    [[ -z "${sdk_root}" && -n "${ANDROID_SDK_ROOT}" && -d "${ANDROID_SDK_ROOT}" ]] && sdk_root="${ANDROID_SDK_ROOT}"
    if [[ -z "${sdk_root}" ]]; then
        for candidate in "${HOME}/Android/Sdk" "${HOME}/android-sdk" "/usr/lib/android-sdk" "/opt/android-sdk" "${PREFIX}/share/android-sdk"; do
            [[ -d "${candidate}" ]] && { sdk_root="${candidate}"; break; }
        done
    fi
    if [[ -z "${sdk_root}" ]]; then
        SDK_STATUS="MISSING"
        SDK_INFO="Android SDK not found"
    else
        SDK_ROOT="${sdk_root}"
        if [[ -d "${sdk_root}/platform-tools" || -d "${sdk_root}/build-tools" ]]; then
            SDK_STATUS="VALID"
            SDK_INFO="SDK at ${sdk_root}"
        else
            SDK_STATUS="INCOMPLETE"
            SDK_INFO="SDK dir exists but missing components"
        fi
    fi
}

check_aapt2() {
    local bin=""
    if command -v aapt2 &>/dev/null; then bin="$(command -v aapt2)";
    elif command -v aapt &>/dev/null; then bin="$(command -v aapt)"; fi
    if [[ -n "${bin}" ]] && aapt2_meets_minimum "${bin}"; then
        AAPT2_STATUS="VALID"
        AAPT2_INFO="$( ${bin} version 2>&1 | head -n1 )"
        AAPT2_PATH="${bin}"
    else
        AAPT2_STATUS="MISSING"
        AAPT2_INFO="No working AAPT2 (with --source-path) found"
    fi
}

# ----------------------------------------------------------------------
# AAPT2 support checks / minimum version threshold (issue #13)
# ----------------------------------------------------------------------

# Raw first line of `aapt2 version`, e.g. "Android Asset Packaging Tool
# (aapt) 2.19-11315950" or "2.19-debian". Fails (returns 1) when the
# binary cannot be executed at all (missing, wrong architecture, ...).
aapt2_version_string() {
    local bin="$1"
    [[ -x "${bin}" ]] || return 1
    "${bin}" version 2>&1 | head -n1
}

# Numeric build id out of the version string ("2.19-11315950" ->
# "11315950"). Empty for non-numeric suffixes like "2.19-debian".
aapt2_build_number() {
    local ver build
    ver="$(aapt2_version_string "$1" 2>/dev/null)" || return 0
    build="$(echo "${ver}" | sed -n 's/.*2\.19-\([0-9]\{4,\}\).*/\1/p')"
    echo "${build}"
}

# Capability probe: the binary must expose --source-path on `compile`.
#
# NOTE: `aapt2 compile --help` prints its usage but EXITs with status 1
# (both Google's and ReVanced's builds do). Combined with the global
# `set -o pipefail` this made the old `... | grep -q` pipeline fail for
# EVERY binary — the root cause of issue #13. The output is therefore
# captured with `|| true` and matched as a string.
aapt2_supports_source_path() {
    local bin="$1" help_output
    [[ -x "${bin}" ]] || return 1
    help_output="$("${bin}" compile --help 2>&1 || true)"
    [[ "${help_output}" == *"--source-path"* ]]
}

# Functional compatibility probe (issue #13): some distro AAPT2 builds
# (e.g. Ubuntu's, built from AOSP 14-beta) pass the --source-path check
# but cannot parse the resource tables of modern SDK platforms — the
# "RES_TABLE_TYPE_TYPE entry offsets overlap actual entry data" failure.
# Prove real-world compatibility by linking a minimal manifest against
# the NEWEST installed android.jar. Returns 0 (pass) when no platform is
# installed to probe against.
aapt2_can_link_platform() {
    local bin="$1"
    [[ -x "${bin}" ]] || return 1
    local sdk="${SDK_ROOT:-${ANDROID_HOME:-${ANDROID_SDK_ROOT:-${HOME}/Android/Sdk}}}"
    local best_api=-1 best_jar="" p n
    for p in "${sdk}"/platforms/android-*/android.jar; do
        [[ -f "${p}" ]] || continue
        n="$(basename "$(dirname "${p}")")"   # e.g. android-37.0
        n="${n#android-}"; n="${n%%.*}"
        [[ "${n}" =~ ^[0-9]+$ ]] || continue
        if (( n > best_api )); then best_api="${n}"; best_jar="${p}"; fi
    done
    if [[ -z "${best_jar}" ]]; then
        debug "No SDK platform installed yet; skipping the AAPT2 platform-link probe."
        return 0
    fi
    local probe_dir probe_rc
    probe_dir="$(mktemp -d 2>/dev/null)" || return 0
    cat > "${probe_dir}/AndroidManifest.xml" <<'MEOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.example.aapt2probe">
</manifest>
MEOF
    "${bin}" link -o "${probe_dir}/probe.apk" -I "${best_jar}" \
        --manifest "${probe_dir}/AndroidManifest.xml" >/dev/null 2>&1
    probe_rc=$?
    rm -rf "${probe_dir}"
    if [[ ${probe_rc} -ne 0 ]]; then
        info "AAPT2 '${bin}' cannot link against ${best_jar} (resource-table incompatibility)."
    fi
    return ${probe_rc}
}

# Minimum-version threshold evaluation (issue #13, requirement 1).
# A binary meets the requirement when:
#   1. it is executable and actually runs on this machine/architecture, and
#   2. it supports the --source-path flag required by modern AGP, and
#   3. its build id (when one is reported) is >= AAPT2_MIN_BUILD, and
#   4. it can link against the newest installed SDK platform (when one
#      exists) — this rejects distro AAPT2s that are too old for modern
#      android.jar resource tables.
aapt2_meets_minimum() {
    local bin="$1" ver build
    [[ -n "${bin}" && -x "${bin}" ]] || return 1
    ver="$(aapt2_version_string "${bin}" 2>/dev/null)" || {
        debug "'${bin}' produced no version output (not runnable on this machine?)"
        return 1
    }
    if ! aapt2_supports_source_path "${bin}"; then
        info "AAPT2 '${bin}' (${ver:-unknown version}) is below the minimum requirement: no --source-path support."
        return 1
    fi
    build="$(aapt2_build_number "${bin}")"
    if [[ -n "${build}" && "${AAPT2_MIN_BUILD}" -gt 0 && "${build}" -lt "${AAPT2_MIN_BUILD}" ]]; then
        info "AAPT2 '${bin}' (build ${build}) is below the configured minimum build ${AAPT2_MIN_BUILD}."
        return 1
    fi
    if ! aapt2_can_link_platform "${bin}"; then
        return 1
    fi
    debug "'${bin}' meets the minimum requirement (${ver:-version unknown})."
    return 0
}

# Evaluate every pre-existing AAPT2 candidate (SDK build-tools, PATH,
# previously installed ReVanced binary, ...) against the minimum
# requirement. Returns 0 and sets AAPT2_PATH/AAPT2_PROVENANCE when a
# qualifying binary is found — BEFORE any external download happens.
find_compatible_aapt2() {
    local candidates=() c p
    if [[ -n "${SDK_ROOT:-}" && -d "${SDK_ROOT}/build-tools" ]]; then
        for c in "${SDK_ROOT}"/build-tools/*/aapt2; do
            [[ -x "${c}" ]] && candidates+=("${c}")
        done
    fi
    for p in "$(command -v aapt2 || true)" "$(command -v aapt || true)" \
             /usr/local/bin/aapt2 "${HOME}/.local/bin/aapt2" "${PREFIX:-}/bin/aapt2"; do
        [[ -n "${p}" && -x "${p}" ]] && candidates+=("${p}")
    done
    # de-duplicate while preserving order
    local seen="" unique=()
    for c in "${candidates[@]}"; do
        [[ " ${seen} " == *" ${c} "* ]] && continue
        seen="${seen} ${c}"
        unique+=("${c}")
    done
    for c in "${unique[@]}"; do
        if aapt2_meets_minimum "${c}"; then
            AAPT2_PATH="${c}"
            AAPT2_PROVENANCE="existing"
            info "Existing AAPT2 at ${c} meets the minimum requirement; no download needed."
            return 0
        fi
    done
    debug "No pre-existing AAPT2 meets the minimum requirement (checked: ${seen:-none})."
    return 1
}

# Last-resort fallback: pick any AAPT2 that at least runs, even if it is
# below the minimum requirement, so that the script can still finish
# with exit status 0 and configure Gradle (issue #13, requirement 3).
find_best_effort_aapt2() {
    local c
    for c in "$(command -v aapt2 || true)" "$(command -v aapt || true)" \
             /usr/local/bin/aapt2 "${HOME}/.local/bin/aapt2"; do
        if [[ -n "${c}" && -x "${c}" ]] && aapt2_version_string "${c}" &>/dev/null; then
            AAPT2_PATH="${c}"
            AAPT2_PROVENANCE="fallback"
            warn "Fallback AAPT2 (does NOT meet the --source-path requirement): ${c}"
            return 0
        fi
    done
    warn "No runnable AAPT2 binary found at all; skipping AAPT2-dependent configuration."
    return 1
}

# ----------------------------------------------------------------------
# Install system AAPT2
# ----------------------------------------------------------------------
install_system_aapt2() {
    info "Installing system AAPT2..."
    case "${OS_NAME}" in
        termux)
            install_pkg "${AAPT2_PKG_TERMUX}"
            ;;
        arch)
            install_pkg "${AAPT2_PKG_ARCH}"
            ;;
        debian)
            for pkg in "${AAPT2_PKG_DEBIAN[@]}"; do
                if install_pkg "${pkg}"; then
                    if command -v aapt2 &>/dev/null || command -v aapt &>/dev/null; then
                        break
                    fi
                fi
            done
            ;;
        fedora)
            for pkg in "${AAPT2_PKG_FEDORA[@]}"; do
                if install_pkg "${pkg}"; then break; fi
            done
            ;;
        alpine)
            for pkg in "${AAPT2_PKG_ALPINE[@]}"; do
                if install_pkg "${pkg}"; then break; fi
            done
            ;;
        *) error "No AAPT2 package defined for ${OS_NAME}"; return 1 ;;
    esac

    local aapt2_bin
    aapt2_bin="$(command -v aapt2 || command -v aapt || true)"
    if [[ -z "${aapt2_bin}" ]]; then
        error "Failed to install system AAPT2."
        return 1
    fi
    AAPT2_PATH="${aapt2_bin}"
    info "System AAPT2 installed at ${AAPT2_PATH}"

    if [[ "${OS_NAME}" == "termux" ]]; then
        info "Termux AAPT2 is maintained by the official repository; no additional action needed."
    elif ! aapt2_supports_source_path "${aapt2_bin}"; then
        warn "System AAPT2 does NOT support --source-path. Modern AGP builds will likely fail."
    fi
}

# ----------------------------------------------------------------------
# Install Android SDK (official Google)
# ----------------------------------------------------------------------
# Discover the newest stable platform package name (e.g.
# "platforms;android-37.0") advertised by sdkmanager. Falls back to an
# empty string so the caller can use its default. Only plain stable
# releases are considered — beta/ext/preview variants are filtered out.
resolve_newest_platform() {
    local sdkmanager_bin="$1" listing raw name best="" best_num=-1 num
    listing="$("${sdkmanager_bin}" --list 2>/dev/null || true)"
    [[ -z "${listing}" ]] && return 0
    while IFS= read -r raw; do
        name="${raw#platforms;android-}"
        [[ "${name}" == "${raw}" ]] && continue
        [[ "${name}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || continue
        num="${name%%.*}"
        if (( num > best_num )); then best_num="${num}"; best="${name}"; fi
    done < <(printf '%s\n' "${listing}" | \
        sed -n 's/^[[:space:]]*platforms;android-\([0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}\)[[:space:]].*/platforms;android-\1/p')
    [[ -n "${best}" ]] && echo "platforms;android-${best}"
    return 0
}

install_sdk() {
    info "Setting up Android SDK (official Google command line tools)..."
    local sdk_root="${SDK_ROOT:-${HOME}/Android/Sdk}"
    mkdir -p "${sdk_root}"

    local sdkmanager_bin="${sdk_root}/cmdline-tools/latest/bin/sdkmanager"
    if [[ ! -x "${sdkmanager_bin}" ]]; then
        info "Downloading command line tools from Google..."
        local tmp_zip="${sdk_root}/cmdline-tools.zip"
        if ! wget -q --show-progress -O "${tmp_zip}" "${SDKMANAGER_URL}"; then
            error "Download failed."
            return 1
        fi
        [[ -n "${SDKMANAGER_SHA256}" ]] && {
            local actual_sha
            actual_sha=$(sha256sum "${tmp_zip}" | awk '{print $1}')
            if [[ "${actual_sha}" != "${SDKMANAGER_SHA256}" ]]; then
                error "Checksum mismatch for command line tools."
                rm -f "${tmp_zip}"
                return 1
            fi
        }
        mkdir -p "${sdk_root}/cmdline-tools"
        unzip -q -o "${tmp_zip}" -d "${sdk_root}/cmdline-tools"
        mv "${sdk_root}/cmdline-tools/cmdline-tools" "${sdk_root}/cmdline-tools/latest"
        rm -f "${tmp_zip}"
        sdkmanager_bin="${sdk_root}/cmdline-tools/latest/bin/sdkmanager"
    fi

    info "Accepting Android SDK licenses..."
    yes | "${sdkmanager_bin}" --licenses > /dev/null 2>&1 || true

    info "Installing platform-tools..."
    yes | "${sdkmanager_bin}" --sdk_root="${sdk_root}" "platform-tools" > /dev/null

    # Install the newest stable platform available (issue #13): a modern
    # android.jar on disk is required both for building current apps and
    # for the AAPT2 minimum-requirement probe. Older platforms that a
    # specific project needs are auto-downloaded by AGP (licenses are
    # accepted above).
    local platform_pkg
    platform_pkg="$(resolve_newest_platform "${sdkmanager_bin}")"
    [[ -z "${platform_pkg}" ]] && platform_pkg="platforms;android-37.0"
    info "Installing ${platform_pkg} and build-tools 35.0.0..."
    yes | "${sdkmanager_bin}" --sdk_root="${sdk_root}" "${platform_pkg}" "build-tools;35.0.0" > /dev/null

    SDK_ROOT="${sdk_root}"
    SDK_STATUS="VALID"

    # Persist the SDK environment so that CI steps, fresh shells and
    # non-login shells all find the SDK (fixes "SDK location not found"
    # in downstream Gradle builds).
    write_env_exports
    info "Android SDK setup complete."
}

# ----------------------------------------------------------------------
# Persist environment (env.sh + shell rc files)
# ----------------------------------------------------------------------
write_env_exports() {
    local sdk_root="${SDK_ROOT:-${HOME}/Android/Sdk}"
    mkdir -p "$(dirname "${ENV_FILE}")"

    info "Writing environment file ${ENV_FILE} ..."
    cat > "${ENV_FILE}" <<EOF
# Auto-generated by ${TOOL_NAME} ${TOOL_VERSION}. Source this file to use
# the Android build environment: . "${ENV_FILE}"
export ANDROID_HOME="${sdk_root}"
export ANDROID_SDK_ROOT="${sdk_root}"
case ":\$PATH:" in
    *":\$ANDROID_HOME/cmdline-tools/latest/bin:"*) ;;
    *) export PATH="\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools:\$PATH" ;;
esac
if [ -z "\${JAVA_HOME:-}" ] && command -v java >/dev/null 2>&1; then
    _java_bin="\$(command -v java)"
    [ -L "\$_java_bin" ] 2>/dev/null && _java_bin="\$(readlink -f "\$_java_bin")"
    export JAVA_HOME="\$(dirname "\$(dirname "\$_java_bin")")"
    unset _java_bin
fi
EOF
    if [[ -n "${AAPT2_PATH:-}" && -x "${AAPT2_PATH}" ]]; then
        echo "export GRADLE_OPTS=\"-Dandroid.aapt2FromMavenOverride=${AAPT2_PATH}\"" >> "${ENV_FILE}"
    fi

    # Also export ANDROID_HOME in interactive shell rc files so that
    # Gradle finds the SDK in new terminals on every distro and Termux.
    for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
        if [[ -f "${rc}" ]]; then
            sed -i '/^export ANDROID_HOME=/d; /^export ANDROID_SDK_ROOT=/d' "${rc}"
        fi
        {
            echo "export ANDROID_HOME=\"${sdk_root}\""
            echo "export ANDROID_SDK_ROOT=\"${sdk_root}\""
        } >> "${rc}"
    done
    export ANDROID_HOME="${sdk_root}"
    export ANDROID_SDK_ROOT="${sdk_root}"
}

# ----------------------------------------------------------------------
# Download and install ReVanced AAPT2 (robust, with graceful fallback)
# ----------------------------------------------------------------------
install_revanced_aapt2() {
    info "Downloading ReVanced ARM64 AAPT2 with redirect following..."
    local target_path="/usr/local/bin/aapt2"
    if [[ ! -w "$(dirname "${target_path}")" ]]; then
        target_path="${HOME}/.local/bin/aapt2"
        mkdir -p "$(dirname "${target_path}")"
    fi
    local tmp="${target_path}.tmp"

    local downloaded=false
    if command -v curl &>/dev/null; then
        # -f: an HTTP error (404/403 rate-limit/proxy page) must FAIL the
        # download instead of silently writing the error body to disk;
        # retries tolerate transient network failures.
        if curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors \
                -o "${tmp}" "${REVANCED_AAPT2_URL}"; then
            downloaded=true
        else
            error "curl download failed (HTTP error or network failure)."
        fi
    elif command -v wget &>/dev/null; then
        if wget -q --tries=3 -O "${tmp}" "${REVANCED_AAPT2_URL}"; then
            downloaded=true
        else
            error "wget download failed."
        fi
    else
        error "Neither curl nor wget is available."
        return 1
    fi

    if [[ "${downloaded}" != "true" ]]; then
        rm -f "${tmp}"
        return 1
    fi

    # Sanity: the file must be a reasonably sized ELF binary, not an HTML
    # error page or a truncated response.
    local size magic
    size=$(stat -c%s "${tmp}" 2>/dev/null || echo 0)
    magic=$(head -c 4 "${tmp}" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
    if [[ "${size}" -lt 1000000 || "${magic}" != "7f454c46" ]]; then
        error "Downloaded file is not a valid AAPT2 ELF binary (size=${size} bytes, magic=${magic:-none})."
        local first_bytes
        first_bytes=$(head -c 120 "${tmp}" 2>/dev/null | tr -d '\0' | head -n1)
        [[ -n "${first_bytes}" ]] && error "  downloaded content starts with: ${first_bytes}"
        rm -f "${tmp}"
        return 1
    fi

    chmod +x "${tmp}"

    if aapt2_meets_minimum "${tmp}"; then
        mv -f "${tmp}" "${target_path}"
        AAPT2_PATH="${target_path}"
        AAPT2_PROVENANCE="revanced"
        info "ReVanced AAPT2 installed and validated at ${AAPT2_PATH}"
        return 0
    fi

    # Keep diagnostics in the log before discarding the bad binary.
    error "Downloaded ReVanced binary did not pass the minimum-requirement validation."
    error "  validation output: $(${tmp} compile --help 2>&1 | head -n 3 | tr '\n' ' ')"
    rm -f "${tmp}"
    return 1
}

# ----------------------------------------------------------------------
# Gradle Override Configuration
# ----------------------------------------------------------------------
configure_gradle_override() {
    local aapt2_bin="${AAPT2_PATH}"
    if [[ -z "${aapt2_bin}" || ! -x "${aapt2_bin}" ]]; then
        # Issue #13, requirement 3: never abort the script here — report,
        # keep the exit status 0 and leave the machine unconfigured.
        error "No usable AAPT2 path to configure; skipping Gradle override configuration."
        return 0
    fi

    info "Configuring Gradle AAPT2 override..."

    # ~/.gradle/gradle.properties
    local gradle_props="${HOME}/.gradle/gradle.properties"
    mkdir -p "$(dirname "${gradle_props}")"
    [[ -f "${gradle_props}" ]] && sed -i '/^android\.aapt2FromMavenOverride=/d' "${gradle_props}"
    echo "android.aapt2FromMavenOverride=${aapt2_bin}" >> "${gradle_props}"
    grep -q '^android.sync.suppressAgpWarnings=' "${gradle_props}" || \
        echo "android.sync.suppressAgpWarnings=UNSUPPORTED_PROJECT_OPTION_USE" >> "${gradle_props}"

    # ~/.gradle/init.d safety net
    local hook_dir="${HOME}/.gradle/init.d"
    local hook_file="${hook_dir}/aapt2_override.init.gradle.kts"
    mkdir -p "${hook_dir}"
    # The VERIFIED, installer-validated binary is baked in as the first
    # choice (issue #13, requirement 4); SDK build-tools and PATH only
    # serve as fallbacks if that binary was removed later. This also
    # prevents Gradle from picking up an unusable SDK build-tools AAPT2
    # (Google ships x86_64-only build-tools for Linux, which cannot run
    # on ARM64 machines).
    cat > "${hook_file}" <<EOF
// Auto-generated by arm64-android-build-env
// Priority: (1) the AAPT2 binary verified by the installer, (2) newest
// Android SDK build-tools AAPT2, (3) first aapt2 found on PATH.
import java.io.File

val verifiedAapt2 = File("${aapt2_bin}")
var chosenAapt2: File? = if (verifiedAapt2.exists() && verifiedAapt2.canExecute()) verifiedAapt2 else null

if (chosenAapt2 == null) {
    val sdkHome = System.getenv("ANDROID_HOME") ?: System.getenv("ANDROID_SDK_ROOT") ?: ""
    if (sdkHome.isNotEmpty()) {
        val buildToolsDir = File(sdkHome, "build-tools")
        if (buildToolsDir.exists() && buildToolsDir.isDirectory) {
            chosenAapt2 = buildToolsDir.listFiles()
                ?.filter { it.isDirectory && File(it, "aapt2").canExecute() }
                ?.maxByOrNull { it.name }
                ?.let { File(it, "aapt2") }
        }
    }
}

if (chosenAapt2 == null) {
    val pathEnv = System.getenv("PATH") ?: ""
    chosenAapt2 = pathEnv.split(File.pathSeparator)
        .map { File(it, "aapt2") }
        .firstOrNull { it.exists() && it.canExecute() }
}

if (chosenAapt2 != null && chosenAapt2!!.exists()) {
    System.setProperty("android.aapt2FromMavenOverride", chosenAapt2!!.absolutePath)
}
EOF

    # Shell RC GRADLE_OPTS
    local export_line="export GRADLE_OPTS=\"-Dandroid.aapt2FromMavenOverride=${aapt2_bin}\""
    for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
        if [[ -f "${rc}" ]]; then
            sed -i '/^export GRADLE_OPTS=/d' "${rc}"
            echo "${export_line}" >> "${rc}"
        else
            echo "${export_line}" > "${rc}"
        fi
    done
    export GRADLE_OPTS="-Dandroid.aapt2FromMavenOverride=${aapt2_bin}"

    # Stop Gradle daemons
    info "Stopping Gradle daemons..."
    ./gradlew --stop > /dev/null 2>&1 || true
    pkill -f gradle > /dev/null 2>&1 || true

    # Refresh the environment file so CI steps also get GRADLE_OPTS
    write_env_exports

    echo ""
    echo "=================================================="
    echo "AAPT2 OVERRIDE CONFIGURED:"
    echo "- ${gradle_props}"
    echo "- ${hook_file}"
    echo "- AAPT2 binary: ${aapt2_bin}"
    echo "=================================================="
}

# ----------------------------------------------------------------------
# Main Flow
# ----------------------------------------------------------------------
main() {
    # Initial prompt
    echo ""
    echo "=================================================="
    echo "This script will set up the ARM64 Android build environment."
    echo "It will install required packages and configure Gradle."
    echo "=================================================="
    read -p "Do you want to proceed with setup? [y/N]: " -r initial_confirm || initial_confirm=""
    if [[ ! -t 0 && -z "${initial_confirm}" ]]; then
        # Non-interactive context (CI, `curl | bash`, piped stdin): the
        # recommended answer is applied automatically instead of aborting.
        initial_confirm="y"
        info "Non-interactive session detected; proceeding with setup automatically."
    fi
    if [[ ! "${initial_confirm}" =~ ^[Yy]$ ]]; then
        info "Aborted by user."
        exit 0
    fi

    detect_os

    # Ensure required tools
    for tool in sed wget curl unzip; do
        if ! command -v "${tool}" &>/dev/null; then
            if [[ "${CHECK_ONLY}" == "false" ]]; then
                info "Installing required tool: ${tool}"
                install_pkg "${tool}" || { error "Failed to install ${tool}."; exit 1; }
            else
                warn "Missing tool '${tool}' (but --check mode continues)."
            fi
        fi
    done

    # Initial checks for report
    check_java
    check_sdk
    check_aapt2

    echo ""
    echo "================================================"
    echo "  INITIAL ENVIRONMENT REPORT"
    echo "================================================"
    echo "OS                  : ${OS_NAME} (${ARCH_LABEL})"
    echo "Package Manager     : ${PKG_MANAGER}"
    echo "Java                : ${JAVA_INFO}"
    echo "AAPT2               : ${AAPT2_INFO}"
    echo "Android SDK         : ${SDK_INFO}"
    echo "================================================"
    echo ""

    if [[ "${CHECK_ONLY}" == "true" ]]; then
        info "Check mode: no changes made."
        exit 0
    fi

    # System update
    run_update

    # Install/upgrade Java if needed (missing or too old)
    if [[ "${JAVA_STATUS}" == "MISSING" || "${JAVA_STATUS}" == "INVALID" ]]; then
        install_java || exit 1
        check_java
    fi

    # Install Android SDK if missing/incomplete
    if [[ "${SDK_STATUS}" == "MISSING" || "${SDK_STATUS}" == "INCOMPLETE" ]]; then
        install_sdk || exit 1
        check_sdk
    fi

    # ----------------------------------------------------------------
    # AAPT2 provisioning (issue #13):
    #  1. Evaluate the existing local/system AAPT2 against the minimum
    #     version requirement BEFORE any external download.
    #  2. Skip the ReVanced download entirely when a local binary already
    #     qualifies (e.g. Termux's official aapt2 package).
    #  3. Graceful fallback: a failed ReVanced fetch NEVER aborts the
    #     script — fall back to the best available AAPT2, still finish
    #     with exit status 0 and configure Gradle with what we have.
    # ----------------------------------------------------------------
    if find_compatible_aapt2; then
        info "Local AAPT2 already satisfies the minimum version requirement; skipping all external AAPT2 downloads."
    else
        # Install system AAPT2 as a baseline.
        # Some distros cannot provide a system AAPT2 package (e.g. Arch's
        # android-tools ships adb/fastboot only, no aapt2/aapt). Do not
        # abort in that case: continue to the ReVanced AAPT2 option.
        if ! install_system_aapt2; then
            warn "System AAPT2 could not be installed. Continuing to the ReVanced AAPT2 option (recommended)."
        fi

        if find_compatible_aapt2; then
            info "System AAPT2 now satisfies the minimum version requirement; skipping ReVanced download."
        else
            if [[ "${OS_NAME}" == "termux" ]]; then
                echo ""
                read -p "Do you want to install ReVanced ARM64 AAPT2? [Y/n]: " -r use_revanced || use_revanced=""
            else
                echo ""
                echo "============================================================"
                echo "WARNING: System official repository's AAPT2 on Debian/Ubuntu/Kali/Arch is outdated and lacks '--source-path' support required by modern AGP."
                echo "RECOMMENDED: ReVanced Team provides an open-source, up-to-date ARM64 AAPT2 binary."
                echo "============================================================"
                echo ""
                read -p "Do you want to download and install ReVanced ARM64 AAPT2? [Y/n]: " -r use_revanced || use_revanced=""
            fi
            if [[ ! -t 0 && -z "${use_revanced}" ]]; then
                # Non-interactive (CI / piped stdin): take the recommended choice.
                use_revanced="Y"
                info "Non-interactive session detected; using the recommended ReVanced AAPT2."
            fi
            use_revanced="${use_revanced:-Y}"
            if [[ "${use_revanced}" =~ ^[Yy]$ ]]; then
                if ! install_revanced_aapt2; then
                    # Requirement 3: graceful fallback, keep exit status 0.
                    warn "ReVanced AAPT2 could not be installed; falling back to the best available AAPT2."
                fi
            else
                warn "Keeping system AAPT2. Build may fail due to missing --source-path."
            fi
        fi
    fi

    # If nothing qualified so far, make sure AAPT2_PATH points at the best
    # runnable binary (below-threshold is still better than nothing).
    if [[ -z "${AAPT2_PATH}" || ! -x "${AAPT2_PATH}" ]]; then
        find_best_effort_aapt2 || true
    fi

    # Configure Gradle override with the final verified AAPT2 path
    configure_gradle_override

    # Final status
    check_java
    check_sdk
    if [[ -n "${AAPT2_PATH}" && -x "${AAPT2_PATH}" ]]; then
        AAPT2_STATUS="VALID"
        AAPT2_INFO="$( ${AAPT2_PATH} version 2>&1 | head -n1 )"
    else
        AAPT2_STATUS="INVALID"
        AAPT2_INFO="AAPT2 not found or not executable"
    fi

    echo ""
    echo "================================================"
    echo "  FINAL STATUS"
    echo "================================================"
    echo "Java                : ${JAVA_STATUS} - ${JAVA_INFO}"
    echo "Android SDK         : ${SDK_STATUS} - ${SDK_INFO}"
    echo "AAPT2               : ${AAPT2_STATUS} - ${AAPT2_INFO}"
    echo "AAPT2 Path          : ${AAPT2_PATH:-N/A} (${AAPT2_PROVENANCE:-n/a})"
    echo "Environment file    : ${ENV_FILE}"
    echo "================================================"
    if [[ "${JAVA_STATUS}" == "VALID" && "${SDK_STATUS}" == "VALID" && "${AAPT2_STATUS}" == "VALID" ]]; then
        info "Environment is ready for ARM64 Android builds."
    else
        warn "Some components are still not ready. Please review the output above."
    fi
}

main "$@"
