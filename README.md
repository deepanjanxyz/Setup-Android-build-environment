# ARM64 Android Build Environment Setup Script

An automated, lightweight Shell Script designed to set up a complete Android build environment on **ARM64 (aarch64)** systems across any Linux distribution and Termux (Ubuntu, Debian, Arch, Fedora, Alpine, Termux, etc.).

---

## 🌐 GitHub Repository & Source File

- **Repository:** https://github.com/deepanjanxyz/Setup-Android-build-environment
- **Script File:** https://github.com/deepanjanxyz/Setup-Android-build-environment/blob/main/Install.sh

---

## ⚡ Quick One-Line Installation & Execution

Before running, ensure `curl` or `wget` is installed on your system.

### Step 1: Install Pre-requisites (If not already installed)

- **For Debian / Ubuntu / Linux Mint (Root User):**
    apt update && apt install -y curl wget git

- **For Debian / Ubuntu (Sudo / Non-Root User):**
    sudo apt update && sudo apt install -y curl wget git

- **For Termux Users:**
    pkg update && pkg install -y curl wget git

---

### Step 2: Run Installation Command

Choose the command according to your system privilege:

#### Option A: For Sudo Users (Ubuntu, Debian Sudo, Raspberry Pi OS)

    sudo bash -c "$(curl -sSL https://raw.githubusercontent.com/deepanjanxyz/Setup-Android-build-environment/main/Install.sh)"

#### Option B: For Pure Root Users (Direct Root Terminal / Debian Root)

    bash -c "$(curl -sSL https://raw.githubusercontent.com/deepanjanxyz/Setup-Android-build-environment/main/Install.sh)"

#### Option C: For Termux Users

    bash -c "$(curl -sSL https://raw.githubusercontent.com/deepanjanxyz/Setup-Android-build-environment/main/Install.sh)"

---

## 📦 Exporting Your Built APK (Termux Users)

Finished building an APK inside Termux and can't find it on your phone? See the step-by-step **[EXPORT-APK.md](EXPORT-APK.md)** guide — it covers granting Termux storage access with `termux-setup-storage`, copying the APK to your phone's Downloads folder, and locating it with your file manager.

---

## 🛑 Processor Architecture Requirements

This script is specifically written and patched for **ARM64 Architecture**. Please verify your device architecture before running:

| Architecture | Compatibility Status | Instruction |
| :--- | :--- | :--- |
| **ARM64 / AArch64** (`aarch64` / `arm64`) | ✅ **Fully Supported** | Ideal for Termux (Android devices), Raspberry Pi 4/5, Apple Silicon Linux VMs, and ARM Single Board Computers. |
| **x86_64 / AMD64** (`x86_64`) | ❌ **Not Supported** | Do **NOT** run on standard 64-bit Intel/AMD PCs. Standard x86_64 systems do not require custom ARM64 AAPT2 binary overrides. |

To check your system architecture, run:

    uname -m

*If it returns `aarch64` or `arm64`, your system is fully compatible.*

---

## 🛠 Supported Operating Systems

This installer is **Universal** and automatically detects your distribution's package manager:
- **Termux** (`pkg`)
- **Debian / Ubuntu / Kali / Mint** (`apt`)
- **Arch Linux / Manjaro** (`pacman`)
- **Fedora / RHEL** (`dnf`)
- **Alpine Linux** (`apk`)

---

## 🧰 AAPT2 Handling (modern AGP compatibility)

Modern Android Gradle Plugin versions invoke `aapt2 compile --source-path`, which most
distribution-packaged AAPT2 builds do not support. The installer therefore:

1. **Checks the existing local/system AAPT2 version first** — if it already meets the
   minimum requirement, **no external download happens at all**. The requirement is
   verified functionally: the binary must run, support `--source-path` **and** be able
   to link a minimal manifest against the newest installed SDK platform (this rejects
   distro AAPT2s that are too old for modern `android.jar` resource tables, e.g.
   Ubuntu's AOSP-14 build fails with `RES_TABLE_TYPE_TYPE entry offsets overlap`).
   On Termux the official repository AAPT2 usually qualifies,
   so the ReVanced step is skipped automatically.
2. **Falls back to the ReVanced ARM64 AAPT2 binary** only when the system AAPT2 is below
   the requirement. The download is verified (ELF binary, size, capability probe) before
   it is accepted.
3. **Never fails the installation** — if the ReVanced download or validation fails, the
   script keeps the best available AAPT2, still configures Gradle and always exits with
   status 0.
4. **Wires the verified binary into Gradle** — the chosen path is written to
   `~/.gradle/gradle.properties` (`android.aapt2FromMavenOverride`), the
   `~/.gradle/init.d/aapt2_override.init.gradle.kts` init script (which now prefers the
   verified binary instead of the SDK's x86_64-only build-tools AAPT2) and
   `GRADLE_OPTS`.

The installer also installs the newest stable SDK platform (discovered via
`sdkmanager --list`) so that a modern `android.jar` is available for building and for
the AAPT2 check; older platforms that a specific project needs are auto-downloaded by
AGP.

---

## 🌍 Reusing the Environment (CI, scripts, Termux)

The installer writes a portable environment file at:

    ~/.local/share/arm64-android-build-env/env.sh

Source it in any shell, CI step or script to get `ANDROID_HOME`, `ANDROID_SDK_ROOT`,
`JAVA_HOME`, the SDK `PATH` entries and `GRADLE_OPTS` (AAPT2 override):

    . "$HOME/.local/share/arm64-android-build-env/env.sh"

The same variables are also appended to `~/.bashrc` / `~/.zshrc` for interactive shells.
Non-interactive runs (CI, `curl | bash`) automatically take the recommended answers —
no prompt input is required.

---

## 👤 Author

Developed & Maintained by **[deepanjanxyz](https://github.com/deepanjanxyz)**
