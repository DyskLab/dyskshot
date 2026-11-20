# DyskShot

Menu bar screenshot tool for macOS 15+ (Swift / AppKit / ScreenCaptureKit, no Xcode needed).

## Build & run

```bash
./scripts/build-app.sh
open build/DyskShot.app
```

First capture asks for **Screen Recording** permission (System Settings → Privacy & Security → Screen & System Audio Recording). Relaunch after granting. System audio is covered by that same permission (DyskShot uses ScreenCaptureKit, so it is listed in the top section, not "System Audio Recording Only").

Run `./scripts/setup-signing.sh` once: it creates a local self-signed "DyskShot Local Signing" identity so permissions survive rebuilds (ad-hoc builds lose them every time). Remove with `security delete-identity -c "DyskShot Local Signing"`.

## Shortcuts (default, change in Settings → Shortcuts)

| Action | Key |
|---|---|
| Capture area | ⌃⇧4 |
| Capture window | ⌃⇧5 |
| Capture fullscreen | ⌃⇧3 |
| Capture text (OCR → clipboard) | ⌃⇧2 |
| Record screen (press again to stop) | ⌃⇧6 |

Also available (no default key): Capture Previous Area, Self-Timer, Record GIF, Toggle Desktop Icons, Capture History, Open Settings.

In the selection overlay: drag = area, **Space** = window mode, **Shift** = square, **Esc** / right-click = cancel. Window click: hold **Shift** to swap wallpaper/transparent, **Option** to drop the shadow.

## Recording

Select an area (click = fullscreen, Space = window) → adjust the area (drag/resize handles, or type W × H) → HUD toggles for microphone (device menu), system audio, camera bubble (device menu), click highlights, keystrokes → **↩ Record Video** or **⌥↩ Record GIF**. Stop from the floating controls, the menu bar icon or the record shortcut.

## Cloud (Google Drive)

Settings → Cloud: paste an OAuth Client ID (Google Cloud Console → enable Drive API → Credentials → OAuth client ID, type "Desktop app"), then click "Sign in with Google…". Sign-in uses a loopback redirect with PKCE, and the refresh token is stored in the Keychain. Uploads go into a "DyskShot" folder (scope `drive.file`), are optionally shared as anyone-with-link, and the link is copied. To upload, use:
- the cloud button in Quick Access
- ⌘U in the editor
- the "Capture Area & Upload" shortcut
- After capture → Upload to Cloud

## Compress video

"Compress Video…" (menu), the Quick Access compress button, "Keep original quality" in the Video Editor, or Settings → Recording → Video → "Compress after recording". It re-encodes to HEVC at constant quality 0.70 and keeps the same resolution, frame timing and colour tags. Audio is passed through untouched. Measured on a hard clip: about 45–48 dB PSNR and SSIM 0.99, with files 37–56% smaller. The original is kept if the result isn't smaller.

## Self-test

`open -n --env DYSKSHOT_SELFTEST=/tmp/dyskshot-selftest/report.txt build/DyskShot.app` runs an end-to-end test inside the app, covering capture, encode, annotate, OCR, overlays, settings, hotkeys, recording with audio, GIF, editor, compression, Keychain and the OAuth loopback. Artifacts are written next to the report.

## Icon

`docs/icon.svg` follows the Dysk product style (rounded square, open ring, glyph). Run `swift scripts/make-icon.swift` to regenerate `docs/icon.png` and `Resources/AppIcon.icns`.

## Video editor

Open it from Quick Access (scissors button on a recording), the menu ("Open Video to Edit…"), or automatically after recording (Settings → General → After capture → "Open Video Editor"). It can trim with the filmstrip handles, set quality (bitrate), set dimensions (presets or custom W×H with the aspect ratio locked), and change audio (don't change / convert to mono / mute / volume 0–200%). It shows an estimated file size. Convert writes an MP4 to the recordings folder.

## Annotate editor

Crop (C), background (presets + padding), select & move (V), rectangle (R), filled rectangle (F), ellipse (O), line (L), arrow (A, 4 styles), text (T), pixelate (B), spotlight (S), counter (N), pencil (P), highlighter (H); color / stroke / arrow-style menus; zoom; "Drag Me"; share, pin, copy; Save as… and Done (⌘↩).

## Settings

- **General** – start at login, sounds + shutter sound, menu bar icon, export location, hide desktop icons while capturing, after-capture matrix (Quick Access / copy / save / annotate / pin / open video)
- **Wallpaper** – desktop / custom / plain color; window screenshots with wallpaper or transparent, padding, shadow
- **Shortcuts** – recordable global hotkeys
- **Quick Access** – left/right, active screen, size, auto-close (close / save & close, interval), close after drag, save button behavior
- **Recording** – controls, menu bar timer, 1x scaling, cursor, click highlights, keystrokes, remember area, dim, countdown; video FPS/quality/codec/system audio/mic; GIF FPS/width/loop
- **Screenshots** – PNG/JPEG/HEIC/TIFF, 1x scaling, sRGB, 1px border, background preset, self-timer, cursor, freeze screen, crosshair, magnifier
- **Annotate** – inverse arrow, smooth pen, remember background, object shadow, always on top, Dock icon
- **Advanced** – file name template, ask name, @2x suffix, clipboard mode, pin style, history retention, OCR language/line breaks, URL scheme API
- **About**

Not implemented: cloud upload, update checks.

## URL scheme

Enable in Settings → Advanced, then e.g. `open dyskshot://capture-area`. Commands: `capture-area`, `capture-previous`, `capture-window`, `capture-fullscreen`, `self-timer`, `capture-text`, `record-screen`, `record-gif`, `history`, `toggle-desktop-icons`, `settings`.

## Layout

```
Sources/DyskShot/
  AppDelegate.swift        status menu, URL scheme, main menu
  Prefs.swift              all preference keys/defaults
  PreferencesWindow.swift  tabbed Settings window
  HotKeyManager.swift      hotkey actions, recorder field, Carbon registration
  Recorder.swift           screen recording (MP4/GIF), controls, click/keystroke overlays
  RecordSetup.swift        pre-record area editor, HUD, camera bubble
  History.swift            capture history storage + window
  Capture.swift            ScreenCaptureKit, image ops, wallpaper, file/clipboard output
  CaptureController.swift  capture flows, self-timer countdown, desktop icon cover
  SelectionOverlay.swift   area / window picker
  QuickAccess.swift        post-capture thumbnails
  Annotation.swift         annotation model + renderer + export
  Editor.swift             annotate window
  PinPanel.swift, OCR.swift, Toast.swift
scripts/build-app.sh, scripts/make-icon.swift
```
