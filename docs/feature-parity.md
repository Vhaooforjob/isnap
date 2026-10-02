# WinShot → iSnap feature mapping

This document records the translation from the public WinShot repository (reviewed from its current `main` branch on 2026-10-02) to native macOS APIs.

| WinShot area | iSnap native implementation | Status |
|---|---|---|
| Fullscreen / multi-display capture | ScreenCaptureKit display capture and CoreGraphics stitching | Implemented |
| Region overlay | Borderless AppKit windows on each `NSScreen` | Implemented |
| Window enumeration, thumbnails, capture | `SCShareableContent` and `SCScreenshotManager` | Implemented |
| Global hotkeys | Carbon `RegisterEventHotKey` | Implemented |
| System tray | `NSStatusItem` menu | Implemented |
| Rectangle, ellipse, arrow, line, text | CoreGraphics/CoreText annotation renderer | Implemented |
| Number and spotlight tools | CoreGraphics marker and even-odd dim overlay | Implemented |
| Transform tools | AppKit hit testing, move/resize, rotation inspector | Implemented |
| Undo / redo | Snapshot history in `EditorDocument` | Implemented |
| Non-destructive crop | Original-image snapshot plus annotation translation | Implemented |
| Gradient/background controls | 24 native gradient presets and live renderer | Implemented |
| Padding, inset, corners, shadow, border | `CanvasConfiguration` + CoreGraphics | Implemented |
| Output ratio presets | Renderer geometry for all 9 presets | Implemented |
| PNG/JPEG and quality | `NSBitmapImageRep` | Implemented |
| Quick save and naming | Application settings + atomic file writes | Implemented |
| Clipboard open/copy | `NSPasteboard` | Implemented |
| Screenshot library | SwiftUI grid over configured save directory | Implemented |
| Capture-to-editor flow | Main window restoration and foreground activation after every capture | Implemented |
| Automatic capture history | Lossless PNG archive into configured Library folder | Implemented |
| Startup behavior | `SMAppService.mainApp` | Implemented |
| Settings persistence | Codable JSON in Application Support | Implemented |
| Update checks | GitHub Releases API service | Implemented; repository endpoint must match release hosting |
| Cloudflare R2 upload | Keychain secrets + native AWS SigV4 PUT | Implemented |
| Google Drive upload | Loopback OAuth + Drive multipart upload/public permission | Implemented |
| Custom background images | Compressed Application Support library (max 8) | Implemented |

## Deliberate platform adaptations

- Windows `PrintScreen` shortcuts are replaced with macOS-safe defaults: `⌃⌥1`, `⌃⌥2`, and `⌃⌥3`.
- The Windows taskbar tray becomes an `NSStatusItem` menu.
- Win32/GDI and Wails IPC are removed; system capture and rendering run in-process through Apple frameworks.
- Deleted library items go to Trash instead of being permanently deleted.

## Next parity slice

1. Add automated UI tests for region selection and editor gestures.
2. Add signed release packaging and Sparkle-style unattended updates.
