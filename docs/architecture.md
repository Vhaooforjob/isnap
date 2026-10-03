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
                 └─ UpdateService (URLSession)
```

`EditorDocument` is the source of truth for the current image, annotation list, crop state, styling defaults, and history. The interactive AppKit view translates pointer coordinates into source-image coordinates. The same `ExportRenderer` produces the on-screen preview and final exported pixels, preventing preview/export drift.

Editor Save and Copy toolbar/menu actions both render through `ExportService`. Their defaults are `⌘S` and `⌘C`; `SettingsStore` persists user-defined replacements and the SwiftUI command menu observes changes immediately.

Inserted overlay images are PNG-backed `Annotation` values, so selection, transforms, opacity, history, crop translation, preview, and export use the existing document pipeline. Watermarks live in `CanvasConfiguration`; `ExportRenderer` composites text or image stamps last, either at an anchored position or tiled across the complete output.

System services remain independent from SwiftUI views. This keeps Screen Recording permission, file access, hotkey registration, and launch-at-login behavior testable and replaceable.
