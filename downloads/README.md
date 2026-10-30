# Viral downloads

**Latest: [Viral-2.8.dmg](Viral-2.8.dmg)** (macOS 12 or newer)

## Install

1. Download the DMG and open it.
2. Drag **Viral** into **Applications**.
3. Open Viral. macOS blocks it the first time because the app isn't signed with an Apple Developer ID yet. Click **Done**.
4. Go to **System Settings > Privacy & Security**, scroll down and click **Open Anyway** next to Viral. You only do this once.

If "Open Anyway" doesn't show up, run this in Terminal:

```
xattr -cr /Applications/Viral.app
```

Viral is a fork of [Beat](https://github.com/lmparppei/Beat) by Lauri-Matti Parppei (GPL).
