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
#   ./Install.sh [--check] [--verbose] [--yes] [--strict] [--version]
#   --check    Only check and report, no changes.
#   --verbose  Show detailed logs.
#   --yes      Assume "yes" for every prompt (non-interactive).
#   --strict   Exit non-zero when the environment is not fully ready.
#   --version  Print the script version and exit.

set -o pipefail

# ----------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------
TOOL_NAME="arm64-android-build-env"
TOOL_VERSION="25.0.0"
STATE_DIR="${HOME}/.local/share/${TOOL_NAME}"
STATE_FILE="${STATE_DIR}/state.json"
LOG_DIR="${STATE_DIR}/logs"
LOG_FILE="${LOG_DIR}/install-$(date +%Y-%m-%d).log"
# Sourcing this file gives any shell (or CI step) the full environment:
# ANDROID_HOME, ANDROID_SDK_ROOT, JAVA_HOME, PATH and GRADLE_OPTS.
ENV_FILE="${STATE_DIR}/env.sh"

# Java packages (target OpenJDK 21, falling back to 17 which is the
# minimum supported by current AGP). Each list is tried in order and the
# first package that installs wins; JDK packages are preferred over JRE
# ones because some builds need `javac`.
JAVA_PKGS_TERMUX=("openjdk-21" "openjdk-17")
JAVA_PKGS_DEBIAN=("openjdk-21-jdk" "openjdk-17-jdk" "default-jdk")
JAVA_PKGS_ARCH=("jdk-openjdk" "jdk21-openjdk" "jdk17-openjdk")
JAVA_PKGS_FEDORA=("java-21-openjdk-devel" "java-21-openjdk" "java-17-openjdk-devel")
JAVA_PKGS_ALPINE=("openjdk21" "openjdk17")
JAVA_MIN_MAJOR=17

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
# NOTE: stderr is deliberately NOT redirected globally any more. `read -p`
# writes its prompt to STDERR, so the old `exec 2>>"${LOG_FILE}"` made every
# interactive question invisible and left the script looking hung. Command
# output is logged explicitly by run_visible()/run_quietly() instead.
if ! mkdir -p "${LOG_DIR}" 2>/dev/null || ! : >> "${LOG_FILE}" 2>/dev/null; then
    LOG_DIR="${TMPDIR:-/tmp}/${TOOL_NAME}"
    LOG_FILE="${LOG_DIR}/install-$(date +%Y-%m-%d).log"
    mkdir -p "${LOG_DIR}" 2>/dev/null || LOG_FILE="/dev/null"
fi

VERBOSE=false
CHECK_ONLY=false
ASSUME_YES=false
STRICT=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)   CHECK_ONLY=true ;;
        --verbose) VERBOSE=true ;;
        -y|--yes)  ASSUME_YES=true ;;
        --strict)  STRICT=true ;;
        --version) echo "${TOOL_NAME} ${TOOL_VERSION}"; exit 0 ;;
        --help|-h) cat <<EOF
Usage: $0 [--check] [--verbose] [--yes] [--strict] [--version]
  --check    Only check and report, no changes.
  --verbose  Show detailed output.
  --yes      Assume "yes" for every prompt (non-interactive).
  --strict   Exit non-zero when the environment is not fully ready.
  --version  Print the script version and exit.
EOF
            exit 0 ;;
        *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
    shift
done

# True only when stdin is a terminal and --yes was not given. Every
# prompt goes through ask_yes_no(), which uses the default answer when
# the script runs non-interactively (CI, `curl | bash`, </dev/null).
INTERACTIVE=false
if [[ "${ASSUME_YES}" != "true" && -t 0 ]]; then INTERACTIVE=true; fi

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] [%s] %s\n' "${ts}" "${level}" "${msg}" >> "${LOG_FILE}" 2>/dev/null
    if [[ "${VERBOSE}" == "true" || "${level}" != "DEBUG" ]]; then
        # Colour only on a terminal, so piped/CI output stays readable.
        if [[ -t 1 ]]; then
            case "${level}" in
                ERROR)   printf '\033[31m[ERROR]\033[0m %s\n' "${msg}" ;;
                WARNING) printf '\033[33m[WARNING]\033[0m %s\n' "${msg}" ;;
                INFO)    printf '\033[32m[INFO]\033[0m %s\n' "${msg}" ;;
                DEBUG)   printf '\033[90m[DEBUG]\033[0m %s\n' "${msg}" ;;
                *)       printf '%s\n' "${msg}" ;;
            esac
        else
            case "${level}" in
                ERROR|WARNING|INFO|DEBUG) printf '[%s] %s\n' "${level}" "${msg}" ;;
                *)                        printf '%s\n' "${msg}" ;;
            esac
        fi
    fi
}
info()  { log "INFO" "$@"; }
warn()  { log "WARNING" "$@"; }
error() { log "ERROR" "$@"; }
debug() { log "DEBUG" "$@"; }

# ----------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------
# Temp paths registered here are removed when the script exits.
TMP_PATHS=()
cleanup() {
    local p
    for p in "${TMP_PATHS[@]:-}"; do
        [[ -n "${p}" && -e "${p}" ]] && rm -rf "${p}"
    done
}
trap cleanup EXIT INT TERM

# Run a command showing its output on the terminal AND appending it to the
# log file. Returns the command's own exit status (not tee's).
run_visible() {
    "$@" 2>&1 | tee -a "${LOG_FILE}"
    return "${PIPESTATUS[0]}"
}

# Run a command logging its output only (silent unless --verbose).
run_quietly() {
    if [[ "${VERBOSE}" == "true" ]]; then
        run_visible "$@"
    else
        "$@" >> "${LOG_FILE}" 2>&1
    fi
}

# Run a pipeline in which a feeder such as `yes` gets SIGPIPE (exit 141)
# as soon as the consumer stops reading. Under `set -o pipefail` that 141
# would be reported as a failure of the whole pipeline, so pipefail is
# disabled for the duration and the status of the LAST command is used.
run_pipeline() {
    local had_pipefail=0 rc=0
    [[ -o pipefail ]] && had_pipefail=1
    set +o pipefail
    "$@"
    rc=$?
    [[ ${had_pipefail} -eq 1 ]] && set -o pipefail
    return ${rc}
}

# Ask a yes/no question without ever blocking a non-interactive run.
#   $1  question text (already containing the [y/N] hint)
#   $2  answer used when a human just presses Enter (default: Y)
#   $3  answer used for CI / `curl | bash` / </dev/null (default: Y)
# --yes answers everything with yes.
# Usage: ask_yes_no "Question? [y/N]:" N Y
ask_yes_no() {
    local prompt="$1" default="${2:-Y}" auto="${3:-Y}" answer=""
    if [[ "${ASSUME_YES}" == "true" ]]; then
        debug "--yes given: answering 'yes' to '${prompt}'"
        return 0
    fi
    if [[ "${INTERACTIVE}" != "true" ]]; then
        debug "Non-interactive run: answering '${auto}' to '${prompt}'"
        [[ "${auto}" =~ ^[Yy] ]]
        return $?
    fi
    read -r -p "${prompt} " answer || answer=""
    answer="${answer:-${default}}"
    [[ "${answer}" =~ ^[Yy] ]]
}

# Append a line to a shell rc file, creating the file only when allowed
# and keeping the file newline-terminated so the last line is not glued
# onto the appended one.
rc_set_line() {
    local rc="$1" line="$2" create="${3:-yes}"
    if [[ ! -f "${rc}" ]]; then
        [[ "${create}" == "yes" ]] || return 0
        : > "${rc}" || return 0
    fi
    if [[ -s "${rc}" && -n "$(tail -c 1 "${rc}")" ]]; then
        printf '\n' >> "${rc}"
    fi
    grep -qxF -- "${line}" "${rc}" && return 0
    printf '%s\n' "${line}" >> "${rc}"
}

# Remove the export lines this tool previously wrote to an rc file, so a
# re-run updates them instead of stacking duplicates. Lines the user
# wrote themselves (e.g. a plain GRADLE_OPTS=-Xmx2g) are left alone.
rc_drop_managed() {
    local rc="$1"
    [[ -f "${rc}" ]] || return 0
    sed -i \
        -e '/^# arm64-android-build-env/d' \
        -e '/^export JAVA_HOME=/d' \
        -e '/^export ANDROID_HOME=/d' \
        -e '/^export ANDROID_SDK_ROOT=/d' \
        -e '/^export GRADLE_OPTS=.*aapt2FromMavenOverride=/d' \
        -e '/^GRADLE_OPTS=.*aapt2FromMavenOverride=/d' \
        "${rc}" 2>/dev/null || warn "Could not clean ${rc}"
}

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
        # `sudo -n` in non-interactive runs: fail fast with a clear error
        # instead of blocking forever on a password prompt in CI.
        if [[ "${INTERACTIVE}" == "true" ]]; then SUDO="sudo"; else SUDO="sudo -n"; fi
        info "Running as non-root; '${SUDO}' will be used for package installation."
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
    [[ -n "${UPDATE_CMD}" ]] || return 0
    # A failing mirror must not abort the whole installation.
    run_visible bash -c "${UPDATE_CMD}" || warn "System update reported an error; continuing."
    return 0
}

install_pkg() {
    local pkg="$1"
    info "Installing ${pkg} via ${PKG_MANAGER}..."
    # ${INSTALL_CMD} is intentionally unquoted: it carries the command,
    # its flags and the optional sudo prefix.
    # shellcheck disable=SC2086
    run_visible ${INSTALL_CMD} "${pkg}"
}

# ----------------------------------------------------------------------
# Java version check (returns major version number, 0 if not found)
# ----------------------------------------------------------------------
# First line of `java -version` (which prints to stderr). Done without a
# pipe so that `set -o pipefail` cannot turn a SIGPIPE on `head` into a
# false failure.
java_version_line() {
    local bin="$1" out=""
    [[ -n "${bin}" && -x "${bin}" ]] || return 0
    out="$("${bin}" -version 2>&1 || true)"
    printf '%s\n' "${out%%$'\n'*}"
}

get_java_major() {
    local java_bin="$1" out=""
    if [[ -z "${java_bin}" || ! -x "${java_bin}" ]]; then
        echo "0"
        return
    fi
    out="$(java_version_line "${java_bin}")"
    # "openjdk version \"21.0.4\" 2024-07-16" -> 21
    # "java version \"1.8.0_402\""          -> 8  (legacy 1.x scheme)
    # The quotes are optional so that unquoted/garbled-but-numeric output
    # from vendor JDK builds still parses.
    if [[ "${out}" =~ [Vv]ersion\ \"?1\.([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "${out}" =~ [Vv]ersion\ \"?([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "0"
    fi
}

# ----------------------------------------------------------------------
# Java installation and configuration
# ----------------------------------------------------------------------
install_java() {
    info "Installing Java (target OpenJDK 21, minimum ${JAVA_MIN_MAJOR})..."
    local pkgs=() p installed=false
    case "${OS_NAME}" in
        termux) pkgs=("${JAVA_PKGS_TERMUX[@]}") ;;
        debian) pkgs=("${JAVA_PKGS_DEBIAN[@]}") ;;
        arch)   pkgs=("${JAVA_PKGS_ARCH[@]}") ;;
        fedora) pkgs=("${JAVA_PKGS_FEDORA[@]}") ;;
        alpine) pkgs=("${JAVA_PKGS_ALPINE[@]}") ;;
        *) error "No Java package defined for ${OS_NAME}"; return 1 ;;
    esac

    # Try each candidate: OpenJDK 21 is not packaged on every release
    # (e.g. Debian 12 bookworm ships 17), so a single hard-coded package
    # name used to fail the whole setup there.
    for p in "${pkgs[@]}"; do
        if install_pkg "${p}"; then
            installed=true
            break
        fi
        warn "Package '${p}' could not be installed; trying the next candidate."
    done
    if [[ "${installed}" != "true" ]]; then
        error "Could not install any JDK package (tried: ${pkgs[*]})."
        return 1
    fi

    # After installation, find Java binary and determine its major version
    local java_bin major
    java_bin="$(command -v java || true)"
    if [[ -z "${java_bin}" ]]; then
        error "Java installation failed: java not found in PATH."
        return 1
    fi
    major="$(get_java_major "${java_bin}")"
    if [[ ${major} -lt ${JAVA_MIN_MAJOR} ]]; then
        error "Installed Java major version ${major} is below the required ${JAVA_MIN_MAJOR}. Please install JDK 21 manually."
        return 1
    fi

    # Select the newest JDK when alternatives are available (Linux only)
    if [[ "${OS_NAME}" != "termux" ]] && command -v update-alternatives &>/dev/null; then
        local jdk_dir="" d
        for d in /usr/lib/jvm/*21* /usr/lib/jvm/*17*; do
            if [[ -x "${d}/bin/java" ]]; then jdk_dir="${d}"; break; fi
        done
        if [[ -n "${jdk_dir}" ]]; then
            info "Selecting ${jdk_dir} as the default JDK..."
            # --install registers the alternative when the distro never did;
            # a bare --set fails with "no alternatives for java" otherwise.
            run_quietly ${SUDO} update-alternatives --install /usr/bin/java java \
                "${jdk_dir}/bin/java" 2100 || warn "Could not register java with update-alternatives."
            if [[ -x "${jdk_dir}/bin/javac" ]]; then
                run_quietly ${SUDO} update-alternatives --install /usr/bin/javac javac \
                    "${jdk_dir}/bin/javac" 2100 || warn "Could not register javac with update-alternatives."
            else
                warn "javac not found in ${jdk_dir}; skipping javac alternative."
            fi
            run_quietly ${SUDO} update-alternatives --set java "${jdk_dir}/bin/java" || \
                warn "Could not set the java alternative; continuing."
        else
            warn "Could not locate a JDK directory for update-alternatives."
        fi
    fi

    # Export JAVA_HOME
    local java_home="" rc
    if [[ -x "${java_bin}" ]]; then
        java_home="$(dirname "$(dirname "$(readlink -f "${java_bin}")")")"
    fi
    if [[ -z "${java_home}" || ! -d "${java_home}" ]]; then
        warn "Could not determine JAVA_HOME automatically. You may need to set it manually."
    else
        info "Setting JAVA_HOME=${java_home} for this session and in shell rc files."
        for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
            # Never create a ~/.zshrc for users who do not use zsh.
            [[ "${rc}" == "${HOME}/.zshrc" && ! -f "${rc}" ]] && continue
            sed -i '/^export JAVA_HOME=/d' "${rc}" 2>/dev/null
            rc_set_line "${rc}" "# arm64-android-build-env (managed block)"
            rc_set_line "${rc}" "export JAVA_HOME=\"${java_home}\""
        done
        export JAVA_HOME="${java_home}"
    fi

    JAVA_STATUS="VALID"
    JAVA_INFO="$(java_version_line "${java_bin}")"
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
        if [[ ${major} -ge ${JAVA_MIN_MAJOR} ]]; then
            JAVA_STATUS="VALID"
            JAVA_INFO="$(java_version_line "${java_bin}")"
        else
            JAVA_STATUS="INVALID"
            JAVA_INFO="Java major version ${major} is too old (need ${JAVA_MIN_MAJOR}+). Will install JDK 21."
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
    command -v aapt2 &>/dev/null && bin="$(command -v aapt2)"
    if [[ -n "${bin}" ]] && aapt2_meets_minimum "${bin}"; then
        AAPT2_STATUS="VALID"
        AAPT2_INFO="$(aapt2_version_string "${bin}")"
        AAPT2_PATH="${bin}"
    else
        # `aapt` (v1) is deliberately NOT used as a fallback: it cannot
        # stand in for AAPT2 under AGP and only produced a false "VALID".
        AAPT2_STATUS="MISSING"
        AAPT2_INFO="No working AAPT2 (with --source-path support) found"
    fi
}

# ----------------------------------------------------------------------
# AAPT2 support checks / minimum version threshold (issue #13)
# ----------------------------------------------------------------------

# Raw first line of `aapt2 version`, e.g. "Android Asset Packaging Tool
# (aapt) 2.19-11315950" or "2.19-debian". Fails (returns 1) when the
# binary cannot be executed at all (missing, wrong architecture, ...).
aapt2_version_string() {
    local bin="$1" out=""
    [[ -x "${bin}" ]] || return 1
    # Captured in a variable rather than piped into `head`: the binary can
    # be killed by SIGPIPE once head closes the pipe, and pipefail would
    # then report a perfectly good binary as not runnable.
    out="$("${bin}" version 2>&1 || true)"
    [[ -z "${out}" ]] && return 1
    printf '%s\n' "${out%%$'\n'*}"
    return 0
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
    for p in "$(command -v aapt2 || true)" \
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
    local c candidates=()
    if [[ -n "${SDK_ROOT:-}" && -d "${SDK_ROOT}/build-tools" ]]; then
        for c in "${SDK_ROOT}"/build-tools/*/aapt2; do
            [[ -x "${c}" ]] && candidates+=("${c}")
        done
    fi
    candidates+=("$(command -v aapt2 || true)" /usr/local/bin/aapt2 "${HOME}/.local/bin/aapt2")
    for c in "${candidates[@]}"; do
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
    aapt2_bin="$(command -v aapt2 || true)"
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

# Discover the newest stable build-tools package ("build-tools;35.0.0").
# Preview/rc builds are ignored; an empty result lets the caller fall back.
resolve_newest_build_tools() {
    local sdkmanager_bin="$1" listing best=""
    listing="$("${sdkmanager_bin}" --list 2>/dev/null || true)"
    [[ -z "${listing}" ]] && return 0
    best="$(printf '%s\n' "${listing}" | \
        sed -n 's/^[[:space:]]*build-tools;\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)[[:space:]].*/\1/p' | \
        sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
    [[ -n "${best}" ]] && echo "build-tools;${best}"
    return 0
}

# Download a URL to a file, retrying transient failures. Returns non-zero
# on HTTP errors (404/403/rate limit) so an error page is never written
# to disk as if it were the artifact.
download_file() {
    local url="$1" dest="$2"
    if command -v curl &>/dev/null; then
        curl -fsSL --retry 3 --retry-delay 2 --retry-all-errors \
             --connect-timeout 20 --max-time 600 -o "${dest}" "${url}"
    elif command -v wget &>/dev/null; then
        wget -q --tries=3 --timeout=30 -O "${dest}" "${url}"
    else
        error "Neither curl nor wget is available."
        return 1
    fi
}

# Install one or more SDK packages, auto-answering the license prompt.
# `yes` exits with SIGPIPE (141) as soon as sdkmanager stops reading;
# run_pipeline keeps that from looking like a failed installation.
sdkmanager_install() {
    local sdkmanager_bin="$1" sdk_root="$2"; shift 2
    export SDKMANAGER_BIN="${sdkmanager_bin}" SDK_ROOT_ARG="${sdk_root}"
    run_pipeline bash -c 'yes | "$SDKMANAGER_BIN" --sdk_root="$SDK_ROOT_ARG" "$@"' \
        _ "$@" >> "${LOG_FILE}" 2>&1
    local rc=$?
    unset SDKMANAGER_BIN SDK_ROOT_ARG
    return ${rc}
}

install_sdk() {
    info "Setting up Android SDK (official Google command line tools)..."
    local sdk_root="${SDK_ROOT:-${HOME}/Android/Sdk}"
    if ! mkdir -p "${sdk_root}"; then
        error "Cannot create the SDK directory ${sdk_root}."
        return 1
    fi

    local sdkmanager_bin="${sdk_root}/cmdline-tools/latest/bin/sdkmanager"
    if [[ ! -x "${sdkmanager_bin}" ]]; then
        info "Downloading command line tools from Google..."
        local tmp_zip
        tmp_zip="$(mktemp "${sdk_root}/cmdline-tools.XXXXXX.zip" 2>/dev/null)" || {
            error "Cannot create a temporary file in ${sdk_root}."
            return 1
        }
        TMP_PATHS+=("${tmp_zip}")
        if ! download_file "${SDKMANAGER_URL}" "${tmp_zip}"; then
            error "Download failed: ${SDKMANAGER_URL}"
            return 1
        fi
        # The archive must really be a ZIP, not an HTML error page.
        if ! unzip -tq "${tmp_zip}" > /dev/null 2>&1; then
            error "Downloaded command line tools archive is corrupt or not a ZIP file."
            return 1
        fi
        if [[ -n "${SDKMANAGER_SHA256}" ]]; then
            local actual_sha
            actual_sha="$(sha256sum "${tmp_zip}" | awk '{print $1}')"
            if [[ "${actual_sha}" != "${SDKMANAGER_SHA256}" ]]; then
                error "Checksum mismatch for command line tools (got ${actual_sha})."
                return 1
            fi
        fi
        # Drop a half-extracted tree left behind by an earlier failed run.
        rm -rf "${sdk_root}/cmdline-tools/latest" "${sdk_root}/cmdline-tools/cmdline-tools"
        if ! mkdir -p "${sdk_root}/cmdline-tools" || \
           ! unzip -q -o "${tmp_zip}" -d "${sdk_root}/cmdline-tools"; then
            error "Could not extract the command line tools."
            return 1
        fi
        if ! mv "${sdk_root}/cmdline-tools/cmdline-tools" "${sdk_root}/cmdline-tools/latest"; then
            error "Unexpected archive layout: cmdline-tools/ directory not found."
            return 1
        fi
        sdkmanager_bin="${sdk_root}/cmdline-tools/latest/bin/sdkmanager"
        if [[ ! -f "${sdkmanager_bin}" ]]; then
            error "sdkmanager is missing after extraction."
            return 1
        fi
        chmod +x "${sdkmanager_bin}" 2>/dev/null || true
        info "Command line tools installed."
    fi

    info "Accepting Android SDK licenses..."
    if ! sdkmanager_install "${sdkmanager_bin}" "${sdk_root}" --licenses; then
        warn "License acceptance reported an error; continuing."
    fi

    info "Installing platform-tools..."
    if ! sdkmanager_install "${sdkmanager_bin}" "${sdk_root}" "platform-tools"; then
        error "Could not install platform-tools (see ${LOG_FILE})."
        return 1
    fi

    # Install the newest stable platform available (issue #13): a modern
    # android.jar on disk is required both for building current apps and
    # for the AAPT2 minimum-requirement probe. Older platforms that a
    # specific project needs are auto-downloaded by AGP (licenses are
    # accepted above). Each candidate is tried in turn because the newest
    # advertised platform is not always installable from a given mirror.
    local platform_pkg build_tools_pkg platform_ok=false candidate
    local candidates=()
    platform_pkg="$(resolve_newest_platform "${sdkmanager_bin}")"
    build_tools_pkg="$(resolve_newest_build_tools "${sdkmanager_bin}")"
    [[ -z "${build_tools_pkg}" ]] && build_tools_pkg="build-tools;35.0.0"
    [[ -n "${platform_pkg}" ]] && candidates+=("${platform_pkg}")
    candidates+=("platforms;android-36" "platforms;android-35")

    for candidate in "${candidates[@]}"; do
        info "Installing ${candidate} and ${build_tools_pkg}..."
        if sdkmanager_install "${sdkmanager_bin}" "${sdk_root}" "${candidate}" "${build_tools_pkg}"; then
            platform_ok=true
            info "Installed ${candidate}."
            break
        fi
        warn "Could not install ${candidate}; trying the next candidate."
    done
    [[ "${platform_ok}" == "true" ]] || \
        warn "No SDK platform could be installed; AGP will try to download one at build time."

    SDK_ROOT="${sdk_root}"
    if [[ -d "${sdk_root}/platform-tools" || -d "${sdk_root}/build-tools" ]]; then
        SDK_STATUS="VALID"
    else
        SDK_STATUS="INCOMPLETE"
    fi

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
    if ! mkdir -p "$(dirname "${ENV_FILE}")"; then
        warn "Could not create ${STATE_DIR}; skipping ${ENV_FILE}."
        return 1
    fi

    info "Writing environment file ${ENV_FILE} ..."
    cat > "${ENV_FILE}" <<EOF
# Auto-generated by ${TOOL_NAME} ${TOOL_VERSION}. Source this file to use
# the Android build environment: . "${ENV_FILE}"
export ANDROID_HOME="${sdk_root}"
export ANDROID_SDK_ROOT="${sdk_root}"
for _dir in "\$ANDROID_HOME/cmdline-tools/latest/bin" "\$ANDROID_HOME/platform-tools"; do
    case ":\$PATH:" in
        *":\$_dir:"*) ;;
        *) PATH="\$_dir:\$PATH" ;;
    esac
done
export PATH
unset _dir
if [ -z "\${JAVA_HOME:-}" ] && command -v java >/dev/null 2>&1; then
    _java_bin="\$(command -v java)"
    [ -L "\$_java_bin" ] && _java_bin="\$(readlink -f "\$_java_bin")"
    JAVA_HOME="\$(dirname "\$(dirname "\$_java_bin")")"
    export JAVA_HOME
    unset _java_bin
fi
EOF
    if [[ -n "${AAPT2_PATH:-}" && -x "${AAPT2_PATH}" ]]; then
        # Appended to any GRADLE_OPTS the user already set (e.g. -Xmx2g)
        # instead of overwriting them.
        cat >> "${ENV_FILE}" <<EOF
GRADLE_OPTS="\${GRADLE_OPTS:+\$GRADLE_OPTS }-Dandroid.aapt2FromMavenOverride=${AAPT2_PATH}"
export GRADLE_OPTS
EOF
    fi

    # Also export ANDROID_HOME in interactive shell rc files so that
    # Gradle finds the SDK in new terminals on every distro and Termux.
    local rc
    for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
        # Never create a ~/.zshrc for users who do not use zsh.
        [[ "${rc}" == "${HOME}/.zshrc" && ! -f "${rc}" ]] && continue
        rc_drop_managed "${rc}"
        rc_set_line "${rc}" "# arm64-android-build-env (managed block)"
        rc_set_line "${rc}" "export ANDROID_HOME=\"${sdk_root}\""
        rc_set_line "${rc}" "export ANDROID_SDK_ROOT=\"${sdk_root}\""
        if [[ -n "${AAPT2_PATH:-}" && -x "${AAPT2_PATH}" ]]; then
            rc_set_line "${rc}" "GRADLE_OPTS=\"\${GRADLE_OPTS:+\$GRADLE_OPTS }-Dandroid.aapt2FromMavenOverride=${AAPT2_PATH}\"; export GRADLE_OPTS"
        fi
    done
    export ANDROID_HOME="${sdk_root}"
    export ANDROID_SDK_ROOT="${sdk_root}"
}

# ----------------------------------------------------------------------
# Download and install ReVanced AAPT2 (robust, with graceful fallback)
# ----------------------------------------------------------------------
# Print the ELF machine type of a binary: aarch64, x86_64 or unknown.
# Bytes 18-19 of the ELF header hold e_machine (0xB7 = AArch64).
elf_machine() {
    local f="$1" m=""
    m="$(od -An -j18 -N2 -tx1 "${f}" 2>/dev/null | tr -d ' \n')"
    case "${m}" in
        b700) echo "aarch64" ;;
        3e00) echo "x86_64" ;;
        *)    echo "unknown" ;;
    esac
}

install_revanced_aapt2() {
    info "Downloading ReVanced ARM64 AAPT2..."
    local target_path="/usr/local/bin/aapt2"
    if [[ ! -w "$(dirname "${target_path}")" ]]; then
        target_path="${HOME}/.local/bin/aapt2"
        if ! mkdir -p "$(dirname "${target_path}")"; then
            error "Cannot create ${HOME}/.local/bin."
            return 1
        fi
    fi
    local tmp="${target_path}.tmp"
    TMP_PATHS+=("${tmp}")

    if ! download_file "${REVANCED_AAPT2_URL}" "${tmp}"; then
        error "Download failed (HTTP error or network failure): ${REVANCED_AAPT2_URL}"
        rm -f "${tmp}"
        return 1
    fi

    # Sanity: the file must be a reasonably sized ELF binary, not an HTML
    # error page, a truncated response or a binary for another CPU.
    local size magic machine
    size=$(stat -c%s "${tmp}" 2>/dev/null || echo 0)
    magic=$(head -c 4 "${tmp}" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \n')
    machine="$(elf_machine "${tmp}")"
    if [[ "${size}" -lt 1000000 || "${magic}" != "7f454c46" ]]; then
        error "Downloaded file is not a valid AAPT2 ELF binary (size=${size} bytes, magic=${magic:-none})."
        local first_bytes
        first_bytes=$(head -c 120 "${tmp}" 2>/dev/null | tr -d '\0' | head -n1)
        [[ -n "${first_bytes}" ]] && error "  downloaded content starts with: ${first_bytes}"
        rm -f "${tmp}"
        return 1
    fi
    if [[ "${machine}" != "aarch64" ]]; then
        error "Downloaded AAPT2 is built for '${machine}', not aarch64; refusing to install it."
        rm -f "${tmp}"
        return 1
    fi

    if ! chmod +x "${tmp}" 2>/dev/null; then
        error "Cannot make ${tmp} executable."
        rm -f "${tmp}"
        return 1
    fi

    if aapt2_meets_minimum "${tmp}"; then
        if ! mv -f "${tmp}" "${target_path}"; then
            error "Could not move the validated binary to ${target_path}."
            rm -f "${tmp}"
            return 1
        fi
        AAPT2_PATH="${target_path}"
        AAPT2_PROVENANCE="revanced"
        info "ReVanced AAPT2 installed and validated at ${AAPT2_PATH}"
        return 0
    fi

    # Keep diagnostics in the log before discarding the bad binary.
    error "Downloaded ReVanced binary did not pass the minimum-requirement validation."
    error "  version output: $(aapt2_version_string "${tmp}" 2>&1)"
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

    # Shell RC GRADLE_OPTS — appended to whatever the user already had;
    # a bare assignment used to wipe settings such as -Xmx2g.
    local rc gradle_line
    gradle_line="GRADLE_OPTS=\"\${GRADLE_OPTS:+\$GRADLE_OPTS }-Dandroid.aapt2FromMavenOverride=${aapt2_bin}\"; export GRADLE_OPTS"
    for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
        # Never create a ~/.zshrc for users who do not use zsh.
        [[ "${rc}" == "${HOME}/.zshrc" && ! -f "${rc}" ]] && continue
        sed -i '/^GRADLE_OPTS=.*aapt2FromMavenOverride=/d; /^export GRADLE_OPTS=.*aapt2FromMavenOverride=/d' \
            "${rc}" 2>/dev/null
        rc_set_line "${rc}" "# arm64-android-build-env (managed block)"
        rc_set_line "${rc}" "${gradle_line}"
    done
    case " ${GRADLE_OPTS:-} " in
        *"android.aapt2FromMavenOverride="*) ;;
        *) GRADLE_OPTS="${GRADLE_OPTS:+${GRADLE_OPTS} }-Dandroid.aapt2FromMavenOverride=${aapt2_bin}" ;;
    esac
    export GRADLE_OPTS

    # Stop running Gradle daemons so the override takes effect.
    # NOTE: the old code ran `./gradlew --stop` in the *current* directory
    # (not a Gradle project when the script runs from $HOME) and
    # `pkill -f gradle`, which also killed unrelated processes whose
    # command line merely contained "gradle" (editors, other builds).
    info "Stopping Gradle daemons..."
    if command -v gradle &>/dev/null; then
        run_quietly gradle --stop || debug "gradle --stop returned non-zero."
    fi
    pkill -f 'org\.gradle\.launcher\.daemon\.GradleDaemon' > /dev/null 2>&1 || true

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
# State file (records what this run installed; handy for support/debug)
# ----------------------------------------------------------------------
json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

write_state() {
    mkdir -p "${STATE_DIR}" 2>/dev/null || return 0
    local tmp="${STATE_FILE}.tmp"
    {
        printf '{\n'
        printf '  "tool": "%s",\n' "${TOOL_NAME}"
        printf '  "version": "%s",\n' "${TOOL_VERSION}"
        printf '  "updated_at": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '  "os": "%s",\n' "${OS_NAME:-unknown}"
        printf '  "arch": "%s",\n' "${ARCH:-unknown}"
        printf '  "java_home": "%s",\n' "$(json_escape "${JAVA_HOME:-}")"
        printf '  "android_sdk_root": "%s",\n' "$(json_escape "${SDK_ROOT:-}")"
        printf '  "aapt2_path": "%s",\n' "$(json_escape "${AAPT2_PATH:-}")"
        printf '  "aapt2_provenance": "%s"\n' "$(json_escape "${AAPT2_PROVENANCE:-}")"
        printf '}\n'
    } > "${tmp}" 2>/dev/null && mv -f "${tmp}" "${STATE_FILE}" 2>/dev/null
    debug "State written to ${STATE_FILE}"
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
    echo "Log file: ${LOG_FILE}"
    echo "=================================================="
    if ! ask_yes_no "Do you want to proceed with setup? [y/N]:" N Y; then
        info "Aborted by user."
        exit 0
    fi
    [[ "${INTERACTIVE}" != "true" ]] && \
        info "Non-interactive session detected; proceeding with setup automatically."

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
        if [[ "${JAVA_STATUS}" != "VALID" || "${SDK_STATUS}" != "VALID" || "${AAPT2_STATUS}" != "VALID" ]]; then
            echo ""
            echo "Run without --check to install and configure the missing parts."
        fi
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
            if [[ "${OS_NAME}" != "termux" ]]; then
                echo ""
                echo "============================================================"
                echo "WARNING: The AAPT2 shipped by Debian/Ubuntu/Kali/Arch repositories is outdated and lacks '--source-path' support required by modern AGP."
                echo "RECOMMENDED: ReVanced Team provides an open-source, up-to-date ARM64 AAPT2 binary."
                echo "============================================================"
                echo ""
            fi
            if ask_yes_no "Do you want to download and install ReVanced ARM64 AAPT2? [Y/n]:" Y Y; then
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
    if [[ -n "${AAPT2_PATH:-}" && -x "${AAPT2_PATH}" ]]; then
        AAPT2_STATUS="VALID"
        AAPT2_INFO="$(aapt2_version_string "${AAPT2_PATH}")"
    else
        AAPT2_STATUS="INVALID"
        AAPT2_INFO="AAPT2 not found or not executable"
    fi

    write_state

    echo ""
    echo "================================================"
    echo "  FINAL STATUS"
    echo "================================================"
    echo "Java                : ${JAVA_STATUS} - ${JAVA_INFO}"
    echo "Android SDK         : ${SDK_STATUS} - ${SDK_INFO}"
    echo "AAPT2               : ${AAPT2_STATUS} - ${AAPT2_INFO}"
    echo "AAPT2 Path          : ${AAPT2_PATH:-N/A} (${AAPT2_PROVENANCE:-n/a})"
    echo "Environment file    : ${ENV_FILE}"
    echo "Log file            : ${LOG_FILE}"
    echo "================================================"

    if [[ "${JAVA_STATUS}" == "VALID" && "${SDK_STATUS}" == "VALID" && "${AAPT2_STATUS}" == "VALID" ]]; then
        info "Environment is ready for ARM64 Android builds."
        info "Open a new shell, or run: . \"${ENV_FILE}\""
        exit 0
    fi

    warn "Some components are still not ready. Please review the output above."
    echo ""
    echo "Next steps:"
    echo "  - Re-run with --verbose, or read the log: ${LOG_FILE}"
    echo "  - Load the environment manually: . \"${ENV_FILE}\""
    echo "  - Use --strict to make this run exit non-zero."
    if [[ "${STRICT}" == "true" ]]; then
        error "--strict: exiting with status 1 because the environment is not fully ready."
        exit 1
    fi
    # Default behaviour is unchanged: a partially configured machine still
    # exits 0 so CI pipelines are not broken by an AAPT2 fallback.
    exit 0
}

main "$@"
