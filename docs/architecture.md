# Architecture

```text
SwiftUI App / NSStatusItem / Commands
                │
             AppModel
        ┌───────┼────────┐
 EditorDocument │   SettingsStore
        │        │
 AppKit canvas   ├─ CaptureService (ScreenCaptureKit)
        │        ├─ RegionCaptureCoordinator (AppKit)
 ExportRenderer  ├─ ExportService (CoreGraphics/AppKit)
                 ├─ LibraryService (FileManager)
                 ├─ GlobalHotkeyService (Carbon)
                 ├─ Cloud uploaders (CryptoKit/URLSession/Network)
                 ├─ KeychainStore (Security)
                 ├─ UpdateService (URLSession)
                 └─ CaptureLineController (AppKit panel)
                      ├─ CaptureLine (model) + CaptureLineView / CaptureLineFlight
                      ├─ ScreenshotFolderWatcher + SystemScreenshotRouting
                      └─ SystemMarkupService (NSSharingService)
```

`EditorDocument` is the source of truth for the current image, annotation list, crop state, styling defaults, and history. The interactive AppKit view translates pointer coordinates into source-image coordinates. The same `ExportRenderer` produces the on-screen preview and final exported pixels, preventing preview/export drift.

`EditorProject` is the versioned `.isnap` document format. `ProjectStore` writes atomically and embeds bitmap assets, annotations, original crop state, and canvas configuration. `AppModel+Workspace` handles debounced recovery snapshots and archives the outgoing document before an editor switch. An unsuccessful preservation prevents that switch. Project backgrounds are imported using a content digest to avoid duplicate asset files. Drafts and project assets are user data, not cache.

`WorkspaceFeatures` persists named presets, path-keyed Library tags/favorites and capture preferences separately from legacy settings. `LibrarySearchIndex` is an actor that caches local Vision text by path, modification time and file size; `AppModel` publishes incremental indexing progress. `BatchExportService` renders selected saved images serially off the main actor, optionally resizes them, and writes unique filenames without overwriting existing data.

Privacy annotations are rendered after other annotations. Solid masks use opaque black; blur/pixelation use Core Image, with an opaque fallback if filtering cannot render. Vision suggestions retain top-left pixel rectangles and require explicit selection before redaction. Projects retain original image data; rendered exports do not retain annotation layers.

`ScrollCaptureController` owns a floating manual-capture session. `ScrollingStitcher` estimates vertical overlap from sampled grayscale images, rejects ambiguous matches, and composites accepted frames at original resolution. Users review and can override each seam; there is no automatic scrolling or sticky-header removal. `PinnedImageController` owns independent floating image panels with opacity and position lock.

Editor Save and Copy toolbar/menu actions both render through `ExportService`. Their defaults are `⌘S` and `⌘C`; `SettingsStore` persists user-defined replacements and the SwiftUI command menu observes changes immediately.

Inserted overlay images are PNG-backed `Annotation` values, so selection, transforms, opacity, history, crop translation, preview, and export use the existing document pipeline. Watermarks live in `CanvasConfiguration`; `ExportRenderer` composites text or image stamps last, either at an anchored position or tiled across the complete output.

System services remain independent from SwiftUI views. This keeps Screen Recording permission, file access, hotkey registration, and launch-at-login behavior testable and replaceable.

The Capture Line is a second destination for captures. `AppModel.accept` archives each fresh capture (to the Library, or to the line's own folder when archiving is off) and hands the file plus its on-screen origin to `CaptureLineController`, which owns the floating panel, pointer tracking, full-screen detection, and the optional macOS screenshot routing. `CaptureLine` only references files; double-click returns a file to `EditorDocument` through `AppModel.editCapture(at:)`.

Localization uses `Sources/iSnap/Resources/Localizable.xcstrings` (English source, Vietnamese translations). SwiftUI literals are localized automatically; status messages, errors, enum titles, and AppKit menus go through `String(localized:)`. `AppLanguage` stores the user's choice in iSnap's own `AppleLanguages` default and the app relaunches to apply it. After adding UI strings, build with Xcode (`SWIFT_EMIT_LOC_STRINGS=YES`) and run `xcrun xcstringstool sync Sources/iSnap/Resources/Localizable.xcstrings --stringsdata <DerivedData>/**/*.stringsdata` to add the new keys, then translate them.

Display capture matches `SCDisplay` and `NSScreen` by display ID, never by frame: ScreenCaptureKit frames use a top-left origin and AppKit frames a bottom-left one, so frames only agree on the main display.

`ShareService` builds one Share menu for any file (direct AirDrop/Messages/Mail services, the system share extensions via `NSSharingServicePicker.standardShareMenuItem`, Open With, copy variants, and upload targets supplied by `AppModel`). The editor renders to `~/Library/Caches/<bundle id>/Share` first; prepared files older than an hour are removed on the next share. `StorageService` measures iSnap's folders off the main thread and clears only rebuildable data (URL cache, Vision model cache, share files, widget thumbnails).
