# ARM64 Android Build Environment Setup Script

An automated, robust Shell Script designed to set up a complete ARM64 Android build environment across various Linux distributions and Termux. It installs necessary build tools, sets up Java 21, configures official Android SDK components, handles AAPT2 workarounds, and safely overrides Gradle configurations without modifying project source code.

## 🌟 Key Features

- **Automated OS & Package Manager Detection:** Supports **Termux**, **Debian/Ubuntu**, **Arch Linux**, **Fedora**, and **Alpine Linux**.
- **Architecture Enforcement:** Strict validation to ensure the host system is **ARM64 (`aarch64`)**.
- **JDK Management:** Automatically checks and installs **OpenJDK 21** (ensuring version $\ge 17$) and configures `JAVA_HOME` and `update-alternatives`.
- **Android SDK Setup:** Automatically downloads Google's command-line tools, accepts SDK licenses, and installs `platform-tools`, `platforms;android-35`, and `build-tools;35.0.0`.
- **Modern AAPT2 Compatibility:** Handles outdated system AAPT2 binaries by offering automated download and validation of **ReVanced ARM64 AAPT2** binary (supporting `--source-path`).
- **Non-Intrusive Gradle Overrides:** Safely hooks into `~/.gradle/gradle.properties` and `~/.gradle/init.d/` to override AAPT2 globally without altering project files.

---

## 🚀 Quick Start

### 1. Clone the Repository
```bash
git clone https://github.com/deepanjanxyz/Setup-Android-build-environment.git
cd Setup-Android-build-environment

