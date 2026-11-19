#!/usr/bin/env bash
# Fast function-level tests for Install.sh.
# No root, no network, no ARM hardware needed: the script is sourced with
# `main` stripped and every external binary is replaced by a stub.
#
# Run locally with:  bash tests/unit.sh
set -o pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

export HOME="${WORK}/home"
mkdir -p "${HOME}" "${WORK}/bin"

# Source the script without executing main().
sed '${/^main /d}' "${REPO_DIR}/Install.sh" > "${WORK}/lib.sh"
# shellcheck source=/dev/null
source "${WORK}/lib.sh"

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1  (got: $2)"; fail=$((fail + 1)); }

T="${WORK}/t"; mkdir -p "${T}/bin"

# ---------------------------------------------------------------- Java ----
mk_java() { # name, version line (quotes preserved literally)
    { echo '#!/bin/sh'; printf 'echo %q >&2\n' "$2"; } > "${T}/bin/$1"
    chmod +x "${T}/bin/$1"
}
mk_java j21  'openjdk version "21.0.4" 2024-07-16'
mk_java j17  'openjdk version "17.0.11" 2024-04-16'
mk_java j8   'java version "1.8.0_402"'
mk_java jbad 'garbage output'

r=$(get_java_major "${T}/bin/j21");  [[ "${r}" == 21 ]] && ok "get_java_major 21"        || bad "get_java_major 21" "${r}"
r=$(get_java_major "${T}/bin/j17");  [[ "${r}" == 17 ]] && ok "get_java_major 17"        || bad "get_java_major 17" "${r}"
r=$(get_java_major "${T}/bin/j8");   [[ "${r}" == 8  ]] && ok "get_java_major 1.8 -> 8"  || bad "get_java_major 1.8" "${r}"
r=$(get_java_major "${T}/bin/jbad"); [[ "${r}" == 0  ]] && ok "get_java_major garbage"    || bad "get_java_major garbage" "${r}"
r=$(get_java_major /nonexistent);    [[ "${r}" == 0  ]] && ok "get_java_major missing"    || bad "get_java_major missing" "${r}"
r=$(java_version_line "${T}/bin/j21")
[[ "${r}" == 'openjdk version "21.0.4" 2024-07-16' ]] && ok "java_version_line" || bad "java_version_line" "${r}"

# --------------------------------------------------------------- AAPT2 ----
cat > "${T}/bin/aapt2" <<'EOF'
#!/bin/sh
case "$1" in
  version) echo "Android Asset Packaging Tool (aapt) 2.19-11315950"; echo "Copyright (C) 2016";;
  compile) echo "usage: aapt2 compile --source-path DIR -o out"; exit 1;;
  link) exit 0;;
esac
EOF
chmod +x "${T}/bin/aapt2"

r=$(aapt2_version_string "${T}/bin/aapt2")
[[ "${r}" == "Android Asset Packaging Tool (aapt) 2.19-11315950" ]] \
    && ok "aapt2_version_string (2-line output, pipefail safe)" || bad "aapt2_version_string" "${r}"
aapt2_supports_source_path "${T}/bin/aapt2" && ok "aapt2_supports_source_path" \
    || bad "aapt2_supports_source_path" "false"
r=$(aapt2_build_number "${T}/bin/aapt2"); [[ "${r}" == 11315950 ]] \
    && ok "aapt2_build_number" || bad "aapt2_build_number" "${r}"
SDK_ROOT="${T}/nosdk"
aapt2_meets_minimum "${T}/bin/aapt2" && ok "aapt2_meets_minimum (good binary)" \
    || bad "aapt2_meets_minimum good" "false"

cat > "${T}/bin/aapt2_old" <<'EOF'
#!/bin/sh
case "$1" in
  version) echo "Android Asset Packaging Tool (aapt) 2.19-debian";;
  compile) echo "usage: aapt2 compile -o out"; exit 1;;
esac
EOF
chmod +x "${T}/bin/aapt2_old"
aapt2_meets_minimum "${T}/bin/aapt2_old" && bad "aapt2_meets_minimum old (must reject)" "true" \
    || ok "aapt2_meets_minimum rejects binary without --source-path"

printf '#!/bin/sh\nexit 3\n' > "${T}/bin/aapt2_dead"; chmod +x "${T}/bin/aapt2_dead"
aapt2_version_string "${T}/bin/aapt2_dead" && bad "aapt2_version_string dead (must fail)" "true" \
    || ok "aapt2_version_string returns non-zero for unrunnable binary"

# ------------------------------------------------------- ELF machine ------
python3 - "${T}" <<'PY'
import os, sys
t = sys.argv[1]

def elf(path, machine):
    b = bytearray(64)
    b[0:4] = b'\x7fELF'
    b[4] = 2   # 64-bit
    b[5] = 1   # little endian
    b[18] = machine & 0xFF
    b[19] = (machine >> 8) & 0xFF
    open(path, 'wb').write(bytes(b))

elf(os.path.join(t, 'elf_arm64'), 0xB7)
elf(os.path.join(t, 'elf_x86_64'), 0x3E)
PY
r=$(elf_machine "${T}/elf_arm64");  [[ "${r}" == aarch64 ]] && ok "elf_machine aarch64" || bad "elf_machine aarch64" "${r}"
r=$(elf_machine "${T}/elf_x86_64"); [[ "${r}" == x86_64  ]] && ok "elf_machine x86_64"  || bad "elf_machine x86_64" "${r}"

# ---------------------------------------------------------- pipelines -----
run_pipeline bash -c 'yes | head -n 1' >/dev/null 2>&1 && ok "run_pipeline ignores feeder SIGPIPE" \
    || bad "run_pipeline ignores feeder SIGPIPE" "non-zero"
run_pipeline bash -c 'exit 7'
[[ $? -eq 7 ]] && ok "run_pipeline keeps the last status" || bad "run_pipeline last status" "wrong"

# ------------------------------------------------------------ rc files ----
printf 'export PATH=$PATH\nsome_last_line_without_newline' > "${HOME}/.bashrc"
rc_set_line "${HOME}/.bashrc" "# arm64-android-build-env (managed block)"
rc_set_line "${HOME}/.bashrc" 'export ANDROID_HOME="/x/Sdk"'
rc_set_line "${HOME}/.bashrc" 'export ANDROID_HOME="/x/Sdk"'
n=$(grep -c '^export ANDROID_HOME="/x/Sdk"$' "${HOME}/.bashrc")
[[ "${n}" == 1 ]] && ok "rc_set_line is idempotent" || bad "rc_set_line idempotent" "${n}"
grep -q '^some_last_line_without_newline$' "${HOME}/.bashrc" \
    && ok "rc_set_line does not glue onto the last line" || bad "rc_set_line newline handling" "glued"

printf 'GRADLE_OPTS="-Xmx2g"\n' >> "${HOME}/.bashrc"
rc_set_line "${HOME}/.bashrc" 'GRADLE_OPTS="${GRADLE_OPTS:+$GRADLE_OPTS }-Dandroid.aapt2FromMavenOverride=/x/aapt2"; export GRADLE_OPTS'
rc_drop_managed "${HOME}/.bashrc"
grep -q '^GRADLE_OPTS="-Xmx2g"$' "${HOME}/.bashrc" && ok "rc_drop_managed keeps user GRADLE_OPTS" \
    || bad "rc_drop_managed keeps user GRADLE_OPTS" "removed"
grep -q 'aapt2FromMavenOverride' "${HOME}/.bashrc" && bad "rc_drop_managed removes managed line" "still there" \
    || ok "rc_drop_managed removes managed line"

# -------------------------------------------------------------- env.sh ----
# shellcheck disable=SC2034  # read by the sourced functions
SDK_ROOT="${T}/Sdk"; mkdir -p "${SDK_ROOT}/platform-tools"
export AAPT2_PATH="${T}/bin/aapt2"
write_env_exports >/dev/null 2>&1

# ENV_FILE is generated at runtime, so shellcheck cannot follow it.
load_env() {
    # shellcheck source=/dev/null
    . "${ENV_FILE}"
}
( GRADLE_OPTS="-Xmx3g"; load_env
  [[ "${ANDROID_HOME}" == "${T}/Sdk" ]] || exit 1
  [[ "${GRADLE_OPTS}" == *"-Xmx3g"* && "${GRADLE_OPTS}" == *"aapt2FromMavenOverride=${T}/bin/aapt2"* ]] || exit 2
  case ":${PATH}:" in *":${ANDROID_HOME}/platform-tools:"*) ;; *) exit 3 ;; esac
) && ok "env.sh sets ANDROID_HOME, PATH and appends GRADLE_OPTS" || bad "env.sh" "bad content"

( load_env; load_env; printf '%s' "${PATH}" | tr ':' '\n' | grep -c 'platform-tools' ) > "${T}/n"
[[ "$(cat "${T}/n")" == 1 ]] && ok "env.sh is idempotent" || bad "env.sh idempotent" "$(cat "${T}/n")"

# ---------------------------------------------------------- state file ----
# exported: read by write_state()
export AAPT2_PROVENANCE=revanced OS_NAME=debian ARCH=aarch64 JAVA_HOME="${T}/jdk"
write_state
python3 -c "import json; d=json.load(open('${STATE_FILE}')); \
assert d['aapt2_path'] == '${T}/bin/aapt2', d; \
assert d['version'] == '${TOOL_VERSION}', d" \
    && ok "state.json is valid JSON" || bad "state.json" "invalid"

# ------------------------------------------------------------ prompts -----
# shellcheck disable=SC2034  # read by ask_yes_no()
INTERACTIVE=false; ASSUME_YES=false
ask_yes_no "Proceed?" N N && bad "ask_yes_no non-interactive N" "returned true" \
    || ok "ask_yes_no honours non-interactive N (CI abort)"
ask_yes_no "Proceed?" N Y && ok "ask_yes_no CI default Y (install proceeds)" \
    || bad "ask_yes_no CI default Y" "returned false"
# shellcheck disable=SC2034
export ASSUME_YES=true
ask_yes_no "Proceed?" N N && ok "--yes overrides a [y/N] prompt" || bad "--yes override" "returned false"
export ASSUME_YES=false

echo
echo "unit tests: passed=${pass} failed=${fail}"
[[ ${fail} -eq 0 ]]
