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

## 👤 Author

Developed & Maintained by **[deepanjanxyz](https://github.com/deepanjanxyz)**
