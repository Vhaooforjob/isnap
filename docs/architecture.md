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

`ScrollCaptureController` owns a floating capture session and registers ⌃⌥N only for its lifetime, using a separate hotkey signature. `ScrollingStitcher` estimates vertical overlap from sampled grayscale images, rejects ambiguous matches, and composites accepted frames at original resolution. Users review every seam with a zoomable full-resolution strip. Fixed top/bottom areas can be trimmed consistently from every frame before matching; settings lock after the first frame. Optional `ScrollEventService` posts one scroll event into the selected display region after checking macOS event-posting permission, then waits before capture. Single-step capture always requires seam review. Continuous capture waits for stable frames and refines overlap at full height before accepting a confident seam. Uncertain seams pause for review; unchanged content, frame/pixel limits or ⌃⌥N stop the loop. An operation token prevents cancelled loops from updating a later session. `PinnedImageController` owns independent floating image panels with opacity and position lock.

Editor Save and Copy toolbar/menu actions both render through `ExportService`. Their defaults are `⌘S` and `⌘C`; `SettingsStore` persists user-defined replacements and the SwiftUI command menu observes changes immediately.

Inserted overlay images are PNG-backed `Annotation` values, so selection, transforms, opacity, history, crop translation, preview, and export use the existing document pipeline. Watermarks live in `CanvasConfiguration`; `ExportRenderer` composites text or image stamps last, either at an anchored position or tiled across the complete output.

System services remain independent from SwiftUI views. This keeps Screen Recording permission, file access, hotkey registration, and launch-at-login behavior testable and replaceable.

The Capture Line is a second destination for captures. `AppModel.accept` archives each fresh capture (to the Library, or to the line's own folder when archiving is off) and hands the file plus its on-screen origin to `CaptureLineController`, which owns the floating panel, pointer tracking, full-screen detection, and the optional macOS screenshot routing. `CaptureLine` only references files; double-click returns a file to `EditorDocument` through `AppModel.editCapture(at:)`.

Localization uses `Sources/iSnap/Resources/Localizable.xcstrings` (English source, Vietnamese translations). SwiftUI literals are localized automatically; status messages, errors, enum titles, and AppKit menus go through `String(localized:)`. `AppLanguage` stores the user's choice in iSnap's own `AppleLanguages` default and the app relaunches to apply it. After adding UI strings, build with Xcode (`SWIFT_EMIT_LOC_STRINGS=YES`) and run `xcrun xcstringstool sync Sources/iSnap/Resources/Localizable.xcstrings --stringsdata <DerivedData>/**/*.stringsdata` to add the new keys, then translate them.

Display capture matches `SCDisplay` and `NSScreen` by display ID, never by frame: ScreenCaptureKit frames use a top-left origin and AppKit frames a bottom-left one, so frames only agree on the main display.

`ShareService` builds one Share menu for any file (direct AirDrop/Messages/Mail services, the system share extensions via `NSSharingServicePicker.standardShareMenuItem`, Open With, copy variants; `AppModel` supplies no cloud upload targets while cloud is in backlog). The editor renders to `~/Library/Caches/<bundle id>/Share` first; prepared files older than an hour are removed on the next share. `StorageService` measures iSnap's folders off the main thread and clears only rebuildable data (URL cache, Vision model cache, share files, widget thumbnails).

## Background export, workflows and composition

`BackgroundExportService` renders immutable CGImage/value snapshots and encodes/writes output on its actor. The main actor owns clipboard/menu/UI work; completion marks a document saved only when its source identity and revision still match.

`CaptureWorkflow` lives in the workspace state. Legacy `uploadProvider` values remain serializable, but `activeUploadProvider` is nil while cloud is unavailable. A dedicated global-hotkey service registers unique action IDs and reports conflicts. Workflows preflight presets, capture region/screen, render a preset/watermark, and save/copy. Region overlays have a frozen loupe source, pixel-aligned bounds and Space-drag translation, with immediate completion on mouse release.

`OCRLayout` groups Vision boxes into rows and infers CSV columns from x positions, with quoted cell escaping. The OCR viewer uses the rendered source (with masks), presents selectable boxes and copies layout-aware text. `CompositionService` downscales sources to the requested combination size for horizontal/vertical layouts and CoreText captions. PDF export reads native-resolution sources up to 80 million pixels each, supports original/A4/Letter layouts and runs tiled OCR before pagination.

Draft manifests use optional asset references, storing image bytes by SHA-256 in `.Assets`; legacy embedded projects still decode. `ProjectStore.read` hydrates and verifies assets. Portable project saves embed those bytes. A shared recursive lock serializes manifest writes, recovery rotation and asset collection. Trash first materializes a portable draft. Collection scans all remaining manifests, including recovery, and aborts on corruption. `recover` validates the source and falls back to Previous. `DraftCatalog` caches rendered thumbnails by path, modification time and file size.

## Cloud backlog

`FeatureAvailability.cloud` is a source-controlled constant set to false, with no user preference to enable it. Cloud UI and upload history are hidden; startup connection checks, settings credential reads/polling, authentication, account updates and uploads are blocked at AppModel entry points. Existing workflows run local actions only. Provider code, serialized configuration, Keychain credentials and link history remain dormant for compatibility; this is not an available product feature. See [backlog](BACKLOG.md#cloud-integrations). macOS sharing services and update checks remain available.

## Library organization, comparison and automation

`WorkspaceState` adds optional collections, saved filters and redaction rules, and `LibraryMetadata` adds optional collection IDs so older workspace JSON remains readable. Collection deletion removes memberships and associated filters in one persistence operation, leaving files and tags intact. Quick tags append without replacing existing tags. Filters retain query, favorites, relative modification-date range, collection ID and sort. Legacy path-keyed metadata migrates to identity-aware records during Library reconciliation.

`ImageComparisonService` loads two native-resolution images, pads them at the top-left and produces a difference bitmap off the main actor. The comparison size is limited to 80 million pixels and 60,000 pixels per axis. It never mutates inputs. `FileRevision` invalidates the decode cache on ordinary edits and atomic replacement. Ignored rectangles are merged into horizontal intervals per row before visiting pixels.

`CompositionService.pdf` optionally recognizes each flattened page with Vision before adding an invisible CoreText layer. Text coordinates are converted from top-left OCR pixels into PDF page coordinates, including caption offsets. Cancellation is checked between recognition and drawing, and output is written only after all pages complete. Existing OCR index entries and project source assets are never used for the text layer.

Freehand annotations reuse local pixel `points`, with normalized bounds, group transforms, resizing and the common renderer. Magnifiers store an optional source rectangle and zoom; moving a lens preserves its source anchor. Their sampling image is rendered without magnifiers but with visible annotations and privacy masks. This avoids recursive lenses and prevents a moved lens from bypassing a mask. Cropping translates lens source coordinates along with the annotation frame.

`AutomationService` exposes three App Intents and entity queries with stable preset/workflow UUIDs. File OCR/export use actors and return text or `IntentFile` without a save dialog. Preset backgrounds can be rendered from embedded data without importing temporary files. Workflow intents call the same throwing/cancellable task as the UI, propagate errors to Shortcuts and return the rendered image. Xcode emits `Metadata.appintents` in the app bundle; Swift Package builds exercise the implementation but do not install system action metadata.


## Refinement services

`LibraryItem.fileIdentity` carries volume/inode/birth identity. `WorkspaceFeatures.reconcileLibrary` migrates path-keyed organization and retains detached records; UUIDs and identities drive backup merging, while cross-volume recovery uses explicit relinking. Existing Workspace JSON decodes without the new optional fields.

`ScreenshotParserService` scans overlapping native-resolution tiles, converts observations to global top-left pixel coordinates and deduplicates overlapping observations. Optional character bounds support phrase redaction; QR results use the same pass. `RedactionMatcher` runs on an actor with input/pattern limits, ICU progress callbacks and deadlines; failures expose no partial suggestions. `CompositionService` can break native screenshots into A4/Letter slices and align invisible OCR text per slice.

`ImageComparisonService` normalizes both images to sRGB with top-left alignment, computes channel differences at source resolution and applies threshold/ignored rectangles. One scroll view synchronizes both comparison panes. `StrokeGeometry` stores simplified/smoothed polylines and clips exact segment/circle intersections for partial erasing. `PixelSample` returns unpremultiplied sRGB values from the privacy-safe rendered image. `CutOutService` preserves unaffected editable layers; affected complex compositions are flattened from the sanitized render, with complete state retained by document Undo.

`ScrollDirection` rotates captures into a canonical downward-stitch coordinate system, then reverses the transform for output. `ScrollSourceGuard` checks display geometry and the original window at the scroll target before posting events/capturing. The floating Pause panel is owned by iSnap and excluded by ScreenCaptureKit.

`GuideService` writes an atomic local draft and owned PNG assets; Markdown exports stage a new directory and publish it with a filesystem move. Number headers are added outside source pixels. `GuideController` owns the session-only hotkey and serializes capture/import/export operations. `AppUpdater` initializes the pinned Sparkle framework only when a valid HTTPS feed/public key is embedded; Swift Package builds retain the GitHub notification fallback. See DISTRIBUTION.md for signing and artifact provenance.

## Command search and duplicate review

`WorkspaceCommand` assembles current actions and workflow IDs on the main actor. Search normalizes case/diacritics and matches every token against titles, categories and bilingual keywords without executing actions. The palette queues an enabled action; `ContentView` dispatches it after sheet dismissal so subsequent sheets can open. Commands observe document availability and busy state.

`DuplicateFileService` groups current file revisions by size, hashes only size candidates incrementally with CryptoKit, then verifies matching digests by comparing byte chunks. It checks cancellation during file reads and revisions around verification. Results are a point-in-time review, not a lock on external files. The sheet reloads Library before transferring explicit selection; deletion continues through Library's existing confirmation/Trash path.

`BatchExportService` downsamples with ImageIO before rendering when a maximum dimension is requested. `RenderRequest.sourcePixelSize` carries the logical original geometry separately from the decoded bitmap, preserving canvas proportions in a bounded output context. EXIF orientation is reflected both in metadata dimensions and decoded pixels. Thumbnail keys include identity, size, date and decode limit.
