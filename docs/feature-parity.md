# WinShot → iSnap feature mapping

This document records the translation from the public WinShot repository (reviewed from its current `main` branch on 2026-10-02) to native macOS APIs.

| WinShot area | iSnap native implementation | Status |
|---|---|---|
| Fullscreen / multi-display capture | ScreenCaptureKit display capture and CoreGraphics stitching | Implemented |
| Region overlay | Borderless AppKit windows on each `NSScreen` | Implemented |
| Window enumeration, thumbnails, capture | `SCShareableContent` and `SCScreenshotManager` | Implemented |
| Screenshot text extraction (OCR) | Vision text recognition, processed on device | Implemented |
| Global hotkeys | Carbon `RegisterEventHotKey` | Implemented |
| System tray | `NSStatusItem` menu | Implemented |
| Rectangle, ellipse, arrow, line, text | CoreGraphics/CoreText renderer with directional endpoints and inline text editing | Implemented |
| Editor preview | Fit, zoom in/out, trackpad pinch, and pan while zoomed | Implemented |
| Number/letter and spotlight tools | Editable auto-sequenced numeric/alphabetic marker plus even-odd dim overlay | Implemented |
| Image overlay | Embedded PNG annotation with move, resize, rotate, opacity, undo/redo | Implemented |
| Text/image watermark | Persistent canvas configuration with anchored and tiled placement | Implemented |
| Transform tools | AppKit hit testing, move/resize, rotation inspector | Implemented |
| Undo / redo | Snapshot history in `EditorDocument` | Implemented |
| Non-destructive crop | Original-image snapshot plus annotation translation | Implemented |
| Gradient/background controls | 24 native gradient presets and live renderer | Implemented |
| Padding, inset, corners, shadow, border | `CanvasConfiguration` + CoreGraphics | Implemented |
| Output ratio presets | Renderer geometry for all 9 presets | Implemented |
| PNG/JPEG and quality | `NSBitmapImageRep` | Implemented |
| Quick save and naming | Application settings + atomic file writes | Implemented |
| Clipboard open/copy | `NSPasteboard`, editor toolbar button, and configurable app shortcut | Implemented |
| Screenshot library | SwiftUI grid over configured save directory | Implemented |
| Capture-to-editor flow | Main window restoration and foreground activation after every capture | Implemented |
| Automatic capture history | Lossless PNG archive into configured Library folder | Implemented |
| Startup behavior | `SMAppService.mainApp` | Implemented |
| Settings persistence | Codable JSON in Application Support | Implemented |
| Update checks | GitHub Releases API service | Implemented; repository endpoint must match release hosting |
| Cloudflare R2 upload | Keychain secrets + native AWS SigV4 PUT | Implemented |
| Google Drive upload | Loopback OAuth + Drive multipart upload/public permission | Implemented |
| Custom background images | Compressed Application Support library (max 8) | Implemented |

## Tendedero → iSnap Capture Line

Reviewed from the public Tendedero repository (`main`, 2026-10-08). Tendedero never captures; it hangs screenshots taken by macOS on a line under the menu bar. iSnap keeps its own capture pipeline and adds the line as a destination.

| Tendedero area | iSnap implementation | Status |
|---|---|---|
| Line under the menu bar, auto-hiding like the Dock | `CaptureLineController` + non-activating `CaptureLinePanel`; reveal after resting 0.25 s in the menu bar, retract 0.5 s after leaving; click in the menu bar tucks it away | Implemented |
| Peek after a new capture | 2.5 s reveal on the screen the capture was taken on | Implemented |
| Capture flies to the line / card falls when discarded | `CaptureLineFlight` (Core Animation overlay window); region and window captures use their real screen rect | Implemented |
| Click copy, double-click open, press-and-hold Markup | Click copies PNG + file URL; **double-click opens in the iSnap editor**; hold opens system Markup and writes back | Implemented (adapted) |
| Drag to app / folder / Trash | `NSDraggingSource`: apps get a copy; folders move line-only captures but only **copy** Library files; Trash discards | Implemented (adapted) |
| Toggle shortcut `⌃⌥T` | Global Carbon hotkey, configurable in Settings → Hotkeys | Implemented |
| Watch macOS screenshot folder | `ScreenshotFolderWatcher` (DispatchSource), Desktop limited to files tagged as screen captures | Implemented, on by default |
| Inbox mode (route screenshots, disable floating thumbnail) | `SystemScreenshotRouting`, opt-in toggle, restored on quit/SIGTERM/disable | Implemented, off by default |
| Hide during full-screen Spaces | Private `CGSCopyManagedDisplaySpaces` Space type check | Implemented |
| Breeze, tilt, glass cards, clip, sounds | SwiftUI `CaptureLineView`; sounds toggle in Settings | Implemented |
| Persist line across launches | `UserDefaults` (`captureLine.items`), missing files pruned | Implemented |
| Localization (es, zh-Hans) | iSnap ships English and Vietnamese through `Localizable.xcstrings`; Spanish and Chinese are not translated | Adapted |

iSnap-specific choices: captures can skip the editor (`Open the editor after each capture` off) and live only on the line; with Library archiving off they are written to `~/Library/Application Support/iSnap/Line` and trashed when taken down. Library files are never deleted from the line.

## Deliberate platform adaptations

- Windows `PrintScreen` shortcuts are replaced with macOS-safe defaults: `⌃⌥1` (screen under the pointer), `⌃⌥2`, and `⌃⌥3`. Stitching every display stays available from the Capture menu and toolbar.
- The Windows taskbar tray becomes an `NSStatusItem` menu.
- Win32/GDI and Wails IPC are removed; system capture and rendering run in-process through Apple frameworks.
- Deleted library items go to Trash instead of being permanently deleted.

## Next parity slice

1. Add automated UI tests for region selection and editor gestures.
2. Add signed release packaging and Sparkle-style unattended updates.
