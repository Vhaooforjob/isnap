# iSnap

![iSnap logo](docs/assets/isnap-logo-v1.png)

iSnap is a native macOS screenshot editor inspired by the workflows and feature set of [WinShot](https://github.com/mrgoonie/winshot). It is implemented in Swift with SwiftUI, AppKit, ScreenCaptureKit, CoreGraphics, Carbon hotkeys, and ServiceManagement—without a web view or JavaScript runtime.

## Current feature set

- Capture the screen under the pointer (`⌃⌥1`), a dragged region on any display (`⌃⌥2`), a selected application window (`⌃⌥3`), or all displays stitched into one image
- Automatically reopen the editor after capture and archive captures into the screenshot library
- Menu-bar actions plus configurable global capture and editor keyboard shortcuts
- Native annotation canvas: rectangle, ellipse, arrow, line, popup text editing, numeric/alphabetic markers, and spotlight
- Movable, resizable, rotatable image overlays with per-image opacity
- Built-in sticker palette with movable, resizable, rotatable, and opacity-adjustable stickers
- Text or image watermarks with opacity, size, nine anchored positions, and full-image tiling
- Inline text editing plus a zoomable, pannable editor preview
- Select, move, resize, rotate, delete, undo, and redo annotations
- Non-destructive crop selection with aspect-ratio presets
- 24 gradient backgrounds, padding, inset, rounded corners, shadow, output ratio, and border controls
- Background styling is opt-in; new and migrated installations start with Show Background disabled
- PNG/JPEG export, quick save with `⌘S`, rendered-image copy with `⌘C`, clipboard import/export, and filename patterns
- On-device screenshot text extraction with macOS Vision, including Vietnamese and English recognition
- Capture Line: recent captures hang on a line tucked under the menu bar; rest the pointer in the menu bar (or press `⌃⌥T`) to bring it down. Click to copy, double-click to edit in iSnap, press and hold for Markup, drag into apps or folders, drag to Trash or click the cross to take down. New captures fly up to the line; the line hides during full-screen apps
- Optional pickup of macOS screenshots (`⇧⌘3/4/5`) onto the Capture Line, following the save location set in `⇧⌘5`, with an opt-in mode that keeps them off the Desktop and restores the original screenshot settings on quit. Screenshots copied to the clipboard (`⌃⇧⌘3/4`) are saved to the line folder and hung too. Three display modes, chosen from the menu bar icon's Capture Line submenu or Settings: Show on Hover (rest the pointer in the menu bar), Always Show, and Hide. `⌃⌥T` shows or hides it right away in any mode, and the menu bar icon lists every capture shortcut
- Share from Capture Line cards (hover button or right-click), the editor toolbar and status bar, and the Library: AirDrop, Messages, Mail, every share extension, Open With any app, copy image/file/path, or upload to R2, Google Drive, or DocVault and copy the link
- Storage overview in Settings → Storage (Library, Capture Line, cache, widget thumbnails, backgrounds, settings), refreshed live, with Clear Cache and Capture Line cleanup
- English and Vietnamese interface, switchable in Settings → Startup or from the menu bar icon (iSnap relaunches to apply)
- Recent-screenshot quick access with one-click Editor/Library navigation and move-to-Trash actions
- Native macOS small and medium widgets for recent screenshots and quick Editor/Library access
- Screenshot library with open, reveal, individual delete, and confirmed delete-all actions
- Responsive editor controls that collapse labels and move contextual styling into a compact popover
- Persistent settings, launch at login, and update checks
- Cloudflare R2 uploads using native AWS SigV4 signing
- Google Drive OAuth, upload, and public-link sharing
- DocVault native PKCE sign-in, workspace uploads, linked Drive account selection, and live quota display
- Up to eight compressed custom background images

See [docs/feature-parity.md](docs/feature-parity.md) for the source-to-native mapping and remaining integration work.
WinShot attribution and its BSD terms, and Tendedero attribution and its MIT terms, are preserved in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Requirements

- macOS 14 or later
- Xcode 16 or later (validated with the locally installed Xcode 27 SDK)
- Screen Recording permission for display/window capture

## Build

```bash
swift build
swift test
```

For an Xcode application project:

```bash
xcodegen generate
xcodebuild -project iSnap.xcodeproj -scheme iSnap -configuration Debug build
```

For reliable Screen Recording permission, sign the app with the configured Apple Development team and run a fixed copy from `/Applications/iSnap.app`. On first capture, macOS asks for access; enable iSnap under System Settings → Privacy & Security → Screen & System Audio Recording, then restart iSnap from its recovery alert. If an older ad-hoc build is still listed, reset only its stale record with `tccutil reset ScreenCapture dev.isnap.app` and grant the installed build once.

## Architecture

The source is split into `App`, `Models`, `Services`, and `Views`. System operations are isolated behind native services; `EditorDocument` owns editable state; `ExportRenderer` is the single rendering path shared by preview, clipboard, and file export.
