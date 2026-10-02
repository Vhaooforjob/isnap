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

System services remain independent from SwiftUI views. This keeps Screen Recording permission, file access, hotkey registration, and launch-at-login behavior testable and replaceable.
