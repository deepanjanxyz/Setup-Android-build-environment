#!/usr/bin/env bash
# End-to-end runs of Install.sh on a simulated ARM64 machine.
# Every external dependency (uname, apt-get, curl, java, aapt2, the SDK) is
# stubbed, so this runs in seconds on any x86_64 CI runner without root,
# network access or an ARM device.
#
# Run locally with:  bash tests/e2e.sh
set -o pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${REPO_DIR}/Install.sh"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1  (${2})"; fail=$((fail + 1)); }

# ------------------------------------------------------------- stubs ------
printf '#!/bin/sh\n[ "$1" = "-m" ] && echo aarch64 || /usr/bin/uname "$@"\n' > "${T}/uname"
printf '#!/bin/sh\nexit 0\n' > "${T}/apt-get"        # pretend package installs succeed
printf '#!/bin/sh\nexit 22\n' > "${T}/curl"          # simulate "network refused"
printf '#!/bin/sh\necho "openjdk version \\"17.0.11\\" 2024-04-16" >&2\n' > "${T}/java"
cat > "${T}/aapt2" <<'EOF'
#!/bin/sh
case "$1" in
  version) echo "Android Asset Packaging Tool (aapt) 2.19-11315950";;
  compile) echo "usage: aapt2 compile --source-path DIR -o out"; exit 1;;
  link) exit 0;;
esac
EOF
chmod +x "${T}/uname" "${T}/apt-get" "${T}/curl" "${T}/java" "${T}/aapt2"

# A sandboxed machine: stub bin dir first on PATH, throwaway HOME.
mk_machine() { # $1 = name, $2 = "with-sdk" | "bare"
    local dir="${T}/$1"
    mkdir -p "${dir}/bin" "${dir}/home"
    cp "${T}/uname" "${T}/apt-get" "${T}/curl" "${T}/java" "${dir}/bin/"
    if [[ "$2" == "with-sdk" ]]; then
        mkdir -p "${dir}/home/Android/Sdk/platform-tools" \
                 "${dir}/home/Android/Sdk/cmdline-tools/latest/bin"
    fi
    printf 'export PATH=$PATH\n' > "${dir}/home/.bashrc"
    echo "${dir}"
}

run_in() { # $1 = machine dir, rest = script args
    local dir="$1"; shift
    HOME="${dir}/home" PATH="${dir}/bin:/usr/bin:/bin" "${INSTALL}" "$@" < /dev/null 2>&1
}

echo "=== A: fully provisioned machine, non-interactive ==="
A="$(mk_machine a with-sdk)"
cp "${T}/aapt2" "${A}/bin/aapt2"
out="$(run_in "${A}")"; rc=$?
[[ ${rc} -eq 0 ]] && ok "A exit 0" || bad "A exit 0" "rc=${rc}"
grep -q 'Environment is ready' <<<"${out}" && ok "A reports ready" || bad "A ready" "$(tail -3 <<<"${out}")"
grep -q "aapt2FromMavenOverride=${A}/bin/aapt2" "${A}/home/.gradle/gradle.properties" \
    && ok "A gradle.properties override" || bad "A gradle.properties" "missing"
grep -q "${A}/bin/aapt2" "${A}/home/.gradle/init.d/aapt2_override.init.gradle.kts" \
    && ok "A init.gradle.kts bakes in the verified path" || bad "A init.gradle.kts" "missing"
[[ -f "${A}/home/.local/share/arm64-android-build-env/env.sh" ]] && ok "A env.sh written" || bad "A env.sh" "missing"
python3 -c "import json;json.load(open('${A}/home/.local/share/arm64-android-build-env/state.json'))" \
    && ok "A state.json valid" || bad "A state.json" "invalid"
grep -q 'aapt2FromMavenOverride' "${A}/home/.bashrc" && ok "A rc GRADLE_OPTS written" || bad "A rc" "missing"
[[ ! -f "${A}/home/.zshrc" ]] && ok "A does not create ~/.zshrc" || bad "A .zshrc" "was created"

echo
echo "=== A2: re-running is idempotent ==="
run_in "${A}" >/dev/null
n=$(grep -c 'aapt2FromMavenOverride' "${A}/home/.bashrc")
[[ "${n}" == 1 ]] && ok "A2 single managed GRADLE_OPTS line" || bad "A2 rc duplicates" "${n} lines"
n=$(grep -c '^export ANDROID_HOME=' "${A}/home/.bashrc")
[[ "${n}" == 1 ]] && ok "A2 single ANDROID_HOME line" || bad "A2 ANDROID_HOME dup" "${n}"

echo
echo "=== B: no AAPT2 and no network -> graceful fallback ==="
B="$(mk_machine b with-sdk)"
outb="$(run_in "${B}")"; rcb=$?
[[ ${rcb} -eq 0 ]] && ok "B default exits 0 (graceful fallback)" || bad "B exit" "rc=${rcb}"
grep -q 'AAPT2  *: INVALID' <<<"${outb}" && ok "B reports AAPT2 not ready" \
    || bad "B report" "$(grep AAPT2 <<<"${outb}" | head -2)"
grep -q 'Some components are still not ready' <<<"${outb}" && ok "B warns instead of crashing" || bad "B warn" "missing"
run_in "${B}" --strict >/dev/null 2>&1; rcb2=$?
[[ ${rcb2} -eq 1 ]] && ok "B --strict exits 1 when not ready" || bad "B --strict" "rc=${rcb2}"

echo
echo "=== C: --check makes no changes ==="
C="$(mk_machine c bare)"
outc="$(run_in "${C}" --check)"; rcc=$?
[[ ${rcc} -eq 0 ]] && ok "C exit 0" || bad "C exit" "rc=${rcc}"
grep -q 'INITIAL ENVIRONMENT REPORT' <<<"${outc}" && ok "C prints the report" || bad "C report" "missing"
[[ ! -d "${C}/home/Android" && ! -f "${C}/home/.gradle/gradle.properties" ]] \
    && ok "C changed nothing" || bad "C changed nothing" "files created"
grep -q 'Check mode: no changes made' <<<"${outc}" && ok "C says check mode" || bad "C check mode msg" "missing"

echo
echo "=== D: a non-ARM64 machine is refused ==="
D="${T}/d"; mkdir -p "${D}/bin" "${D}/home"
printf '#!/bin/sh\necho x86_64\n' > "${D}/bin/uname"; chmod +x "${D}/bin/uname"
outd="$(HOME="${D}/home" PATH="${D}/bin:/usr/bin:/bin" "${INSTALL}" < /dev/null 2>&1)"; rcd=$?
[[ ${rcd} -eq 1 ]] && ok "D refuses x86_64 (exit 1)" || bad "D arch refusal" "rc=${rcd}"
grep -q 'only supports ARM64' <<<"${outd}" && ok "D explains why" || bad "D message" "missing"

echo
echo "e2e tests: passed=${pass} failed=${fail}"
[[ ${fail} -eq 0 ]]
