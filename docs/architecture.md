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

`EditorDocument` is the source of truth for the current image, annotation list, crop state, styling defaults, and history. The interactive AppKit view translates pointer coordinates into source-image coordinates. The same `ExportRenderer` produces previews and exports. `EditorPreviewCache` retains a bounded background and composite bitmap, invalidating on source, canvas, annotations, background modification time or resolution changes. Preview rendering scales the bitmap context while retaining logical output coordinates; privacy filters convert to bitmap coordinates. Exports retain full resolution. Selection and pan changes reuse the composite. Multi-selection transforms share one history checkpoint.

`SnapEngine` computes nearest edge/center, neighbor-gap and size candidates in source pixels; the canvas converts a view-space tolerance and draws guides. Group drags use their original union frame to avoid accumulating snap offsets. Optional layer metadata preserves compatibility with existing projects; hidden annotations are filtered by the shared renderer and locked objects are excluded from geometry mutations.

`EditorProject` is the versioned `.isnap` document format. `ProjectStore` writes atomically and embeds bitmap assets, annotations, original crop state, and canvas configuration. `AppModel+Workspace` captures immutable CGImage/value snapshots for `DraftWriter`, whose serial queue encodes and atomically writes autosaves off the main actor. It caches the latest two encoded image assets. Synchronous lifecycle saves invalidate queued autosaves and serialize behind active writes, so old work cannot overwrite the final state. The outgoing document is archived before an editor switch. An unsuccessful preservation prevents that switch. Project backgrounds are imported using a content digest to avoid duplicate asset files. `DraftCatalog` backs the manager with thumbnails, sizes, rename and Trash actions. Retention is opt-in (UserDefaults `draftRetentionDays`), runs on launch/manager opening, and excludes both `Latest.isnap` and `Previous.isnap`. Drafts and project assets are user data, not cache.

`WorkspaceFeatures` persists named presets, path-keyed Library tags/favorites and capture preferences separately from legacy settings. `LibrarySearchIndex` is an actor that caches local Vision text by path, modification time and file size; `AppModel` publishes incremental indexing progress. Reloads use a generation check; metadata and OCR pruning are scoped to the successfully read Library folder. Bulk tag edits and metadata removal persist once per operation. Single and all-image deletions share the same cleanup path. Library foreground refresh also cleans entries for externally removed files. Keyboard navigation and range selection follow the active sort/filter order, and Quick Look uses an embedded native `QLPreviewView`. `BatchExportService` renders selected saved images serially off the main actor, optionally resizes them, and writes unique filenames without overwriting existing data.

Privacy annotations are rendered after other annotations. Solid masks use opaque black; blur/pixelation use Core Image, with an opaque fallback if filtering cannot render. Vision suggestions retain top-left pixel rectangles and require explicit selection before redaction. Projects retain original image data; rendered exports do not retain annotation layers.

`ScrollCaptureController` owns a floating capture session and registers ⌃⌥N only for its lifetime, using a separate hotkey signature. `ScrollingStitcher` estimates vertical overlap from sampled grayscale images, rejects ambiguous matches, and composites accepted frames at original resolution. Users review every seam with a zoomable full-resolution strip. Fixed top/bottom areas can be trimmed consistently from every frame before matching; settings lock after the first frame. Optional `ScrollEventService` posts one scroll event into the selected display region after checking macOS event-posting permission, then waits before capture. Automatic scrolling never accepts a seam automatically. `PinnedImageController` owns independent floating image panels with opacity and position lock.

Editor Save and Copy toolbar/menu actions both render through `ExportService`. Their defaults are `⌘S` and `⌘C`; `SettingsStore` persists user-defined replacements and the SwiftUI command menu observes changes immediately.

Inserted overlay images are PNG-backed `Annotation` values, so selection, transforms, opacity, history, crop translation, preview, and export use the existing document pipeline. Watermarks live in `CanvasConfiguration`; `ExportRenderer` composites text or image stamps last, either at an anchored position or tiled across the complete output.

System services remain independent from SwiftUI views. This keeps Screen Recording permission, file access, hotkey registration, and launch-at-login behavior testable and replaceable.

The Capture Line is a second destination for captures. `AppModel.accept` archives each fresh capture (to the Library, or to the line's own folder when archiving is off) and hands the file plus its on-screen origin to `CaptureLineController`, which owns the floating panel, pointer tracking, full-screen detection, and the optional macOS screenshot routing. `CaptureLine` only references files; double-click returns a file to `EditorDocument` through `AppModel.editCapture(at:)`.

Localization uses `Sources/iSnap/Resources/Localizable.xcstrings` (English source, Vietnamese translations). SwiftUI literals are localized automatically; status messages, errors, enum titles, and AppKit menus go through `String(localized:)`. `AppLanguage` stores the user's choice in iSnap's own `AppleLanguages` default and the app relaunches to apply it. After adding UI strings, build with Xcode (`SWIFT_EMIT_LOC_STRINGS=YES`) and run `xcrun xcstringstool sync Sources/iSnap/Resources/Localizable.xcstrings --stringsdata <DerivedData>/**/*.stringsdata` to add the new keys, then translate them.

Display capture matches `SCDisplay` and `NSScreen` by display ID, never by frame: ScreenCaptureKit frames use a top-left origin and AppKit frames a bottom-left one, so frames only agree on the main display.

`ShareService` builds one Share menu for any file (direct AirDrop/Messages/Mail services, the system share extensions via `NSSharingServicePicker.standardShareMenuItem`, Open With, copy variants, and upload targets supplied by `AppModel`). The editor renders to `~/Library/Caches/<bundle id>/Share` first; prepared files older than an hour are removed on the next share. `StorageService` measures iSnap's folders off the main thread and clears only rebuildable data (URL cache, Vision model cache, share files, widget thumbnails).

## Background export, workflows and composition

`BackgroundExportService` renders immutable CGImage/value snapshots and encodes/writes output on its actor. The main actor owns clipboard/menu/UI work; completion marks a document saved only when its source identity and revision still match. Upload provider methods accept a task delegate for byte progress. AppModel retains retry bytes and a bounded local link history; cancellation propagates to the active URLSession task. History write failures do not turn successful remote uploads into retryable failures.

`CaptureWorkflow` lives in the workspace state with upload disabled by default. A dedicated global-hotkey service registers unique action IDs and reports conflicts. Workflows preflight presets/provider state, capture region/screen, render a preset/watermark, save/copy and optionally upload. Region overlays have a frozen loupe source, pixel-aligned bounds and Space-drag translation, with immediate completion on mouse release.

`OCRLayout` groups Vision boxes into rows and infers CSV columns from x positions, with quoted cell escaping. The OCR viewer uses the rendered source (with masks), presents selectable boxes and copies layout-aware text. `CompositionService` reads images serially at bounded resolution, combines horizontal/vertical layouts and CoreText captions, or writes a multipage PDF with a per-page image cap of 4096 pixels.

Draft manifests use optional asset references, storing image bytes by SHA-256 in `.Assets`; legacy embedded projects still decode. `ProjectStore.read` hydrates and verifies assets. Portable project saves embed those bytes. A shared recursive lock serializes manifest writes, recovery rotation and asset collection. Trash first materializes a portable draft. Collection scans all remaining manifests, including recovery, and aborts on corruption. `recover` validates the source and falls back to Previous. `DraftCatalog` caches rendered thumbnails by path, modification time and file size.
