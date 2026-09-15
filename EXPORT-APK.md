# Exporting Your Built APK from Termux

After you build an Android APK inside Termux, the file lives inside Termux's private storage, which your phone's file manager cannot see by default. This guide shows you how to copy the APK to your phone's shared **Downloads** folder so you can install or share it like any normal file.

This guide complements the main [ARM64 Android Build Environment Setup](README.md) — see that README first if you have not set up your build environment yet.

---

## Step 1: Grant Termux Access to Shared Storage

Termux is sandboxed. To read/write your phone's shared storage (Downloads, DCIM, etc.), run this command **once** inside Termux:

    termux-setup-storage

## Step 2: Accept the Storage Permission Dialog

After running the command above, Android will show a dialog asking whether Termux may **"Access photos, media and files on your device"**:

1. Tap **Allow** (on some Android versions you may need to tap the back-arrow in the dialog first to expand it, then Allow).
2. If you accidentally tapped **Deny**, just run `termux-setup-storage` again.

When it succeeds, a `storage` directory appears in your Termux home containing shortcuts to your phone's shared folders. Verify it:

    ls ~/storage

You should see shortcuts such as `downloads`, `shared`, `dcim`, `music`, `pictures`.

If `~/storage/downloads` is missing, see the **Troubleshooting** section at the bottom of this guide.

## Step 3: Copy the APK to Downloads

Builds normally finish with a message such as `BUILD SUCCESSFUL`, and the APK is written inside your project folder. A typical debug build path looks like:

    ~/my-project/app/build/outputs/apk/debug/app-debug.apk

Use `cp` to copy it into your phone's Downloads folder:

    cp ~/my-project/app/build/outputs/apk/debug/app-debug.apk ~/storage/downloads/

**Common APK output locations** (relative to your project root):

| Build type | Typical path |
| :--- | :--- |
| Debug | `app/build/outputs/apk/debug/app-debug.apk` |
| Release (unsigned) | `app/build/outputs/apk/release/app-release-unsigned.apk` |
| Release (signed) | `app/build/outputs/apk/release/app-release.apk` |
| AAB (Play Store bundle) | `app/build/outputs/bundle/release/app-release.aab` |

Tip: if you don't know where the APK ended up, find it from your project root:

    find . -name "*.apk" 2>/dev/null

## Step 4: Verify and Locate the APK on Your Phone

Confirm the copy succeeded:

    ls -lh ~/storage/downloads/

Now open your phone's **file manager** (e.g. Files by Google, Samsung My Files, or any other):

1. Go to **Internal storage → Downloads**.
2. You should see `app-debug.apk` (with the file size shown).
3. Tap it to install (you may need to allow "install from unknown sources" for your file manager), or long-press to share it via Bluetooth, WhatsApp, etc.

> **Alternative without the file manager:** open the APK directly from Termux — no extra app required:
>
>     termux-open ~/storage/downloads/app-debug.apk

---

## Troubleshooting

**`termux-setup-storage` does nothing / no dialog appears**
- The permission was already granted previously. Check if `ls ~/storage` shows the shortcuts — if yes, you are already set up.
- If not, go to Android **Settings → Apps → Termux → Permissions** and enable **Files and media** (or **Storage**), then run `termux-setup-storage` again.

**`ls ~/storage/downloads` shows nothing after copying**
- Media scanners may take a moment; reopen the file manager or pull to refresh.
- The path `~/storage/downloads` points to `/storage/emulated/0/Download` — verify with `ls /storage/emulated/0/Download`.

**`Permission denied` when copying**
- Re-run `termux-setup-storage` and make sure you tapped **Allow** in the dialog.

**You forgot which folder your project is in**
- Run `ls ~` to list your Termux home directory, or use the `find` command shown in Step 3.

---

## Quick Recap (Copy-Paste)

    # 1. One-time storage permission
    termux-setup-storage

    # 2. Copy your APK (adjust the source path to your project)
    cp ~/my-project/app/build/outputs/apk/debug/app-debug.apk ~/storage/downloads/

    # 3. Verify
    ls -lh ~/storage/downloads/

The APK is now in your phone's **Downloads** folder and visible in any file manager.
