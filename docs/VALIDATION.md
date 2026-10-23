# Validation of the feature refinement batch

Date: 2026-10-23. Local Apple silicon macOS/Xcode build; timings below are observations on this development machine, not release-mode benchmarks or an SLA.

## Automated checks

`Tests/iSnapTests/PolishTests.swift` covers filesystem identity across rename/move/copy/replacement, swapped filenames, metadata backup/import/relinking, rename traversal/collision rejection, OCR tile coverage, long-image PDF pagination/search, masked text, QR recognition and safe link handling, glyph-based redaction with whole-line fallback, pathological regex cancellation, native 4K one-pixel differences, exact ignored regions/tolerance, stroke smoothing/partial erasing/undo, highlighter text preservation, source-pixel sampling/ruler units, Cut Out pixels/privacy/undo, four-direction transforms, guide persistence/Markdown/PDF output, invalid updater configuration, 10,000-record metadata processing, disk-write failure and canvas accessibility/keyboard actions.

The 1.0.5 release suite passed: **122 tests, 4 opt-in marketing screenshot tests skipped, 0 failures** (118 executed successfully). The enhanced-workspace screenshot test was enabled in this run and passed, including command search and duplicate-file review. A focused GUI/accessibility run passed 2 tests in the earlier refinement batch. The four-direction controller test checks complete capture/add/finish flow against expected pixels and verifies that a source-change error preserves the session.

The follow-up `OptimizationTests.swift` adds 10 tests for bounded batch rendering with original canvas proportions, EXIF orientation, comparison/thumbnail invalidation after atomic replacement, merged ignored intervals, stroke-stack traversal, streaming exact duplicates/cancellation, bilingual command matching, disabled commands, deferred execution and the batch benchmark.

Repeat with:

```sh
ISNAP_BENCHMARK_PATH=/tmp/isnap-benchmarks.json swift test --disable-sandbox
ISNAP_ENHANCEMENT_SHOTS=/tmp/isnap-ui swift test --disable-sandbox --filter EnhancementTests/testRenderEnhancedWorkspace
```

A restricted automation sandbox may block Vision, AppKit, macro plugins or image capture; use a native macOS test environment. Tests do not grant privacy permissions or install iSnap.

Observed Debug measurements from one run:

| Workload | Time |
| --- | ---: |
| Reconcile, export and import 10,000 metadata records | 0.225 s |
| OCR and searchable A4 PDF, 1000 × 20,000 px fixture with sparse English/Vietnamese text | 0.396 s |
| Three comparisons of 4096 × 2160 images, including a one-pixel change and ignored region | 3.612 s |
| Render/PNG encode 500 smoothed strokes on 2400 × 1600 pixels | 0.048 s |
| Apply a canvas preset and export eight 1000 × 800 inputs at max 600 px | 0.089 s |

The OCR fixture is sparse and does not establish accuracy or speed for dense documents. It asserts top/middle/bottom English markers and absence of masked text; Vietnamese text is included but exact Vietnamese transcription is not asserted. Regex `^(a+)+$` on 4,001 characters stopped with the expected error within the test’s 3-second limit (0.285 s at an earlier checkpoint). No partial suggestions were returned.

The follow-up 24 MP → 600 px batch fixture measured **0.1755 s** for full rendering then resize/encode and **0.0502 s** for bounded rendering in the release test run. An earlier run measured 0.1803/0.0513 s. The baseline starts with a decoded CGImage and does not write a file; the new path includes decode and writing. The fixture is a white PNG, timings are Debug and peak resident memory was not measured. Treat these as local microbenchmarks, not a general 3.5× product speed claim. Source/geometry preservation is asserted separately.

## GUI and build evidence

- Xcode Debug app build succeeded with Sparkle 2.10.0 and the embedded widget.
- The opt-in renderer generated editor, Library, comparison, composition/PDF, Cut Out, redaction, guide, OCR, workflows, drafts and settings screenshots at the configured window sizes. The follow-up adds command search and a duplicate group with five files. New screens were inspected for clipped controls and missing content. These are rendered UI checks, not a substitute for interactive end-to-end tests; interactive command-key routing and the handoff of selected duplicates to Library still need a native app smoke test.
- Canvas semantic selection and keyboard movement have an automated test. A full spoken VoiceOver audit remains a manual acceptance check.
- The earlier refinement batch's universal Release pipeline completed in `/tmp/isnap-polish-release`. ZIP and DMG integrity and SHA-256 checks passed. The ZIP was extracted into a fresh directory; deep/strict code-sign verification passed, and both the app and widget contain arm64 + x86_64 binaries. App/widget versions agree (1.0.4, build 24). These local ad-hoc artifacts predate the command-search/duplicate/optimization follow-up; that follow-up has a Debug app build, not a newly packaged release.
- The extracted bundle contains all three AppIntents action records (`ExportScreenshotIntent`, `ExtractScreenshotTextIntent`, `RunCaptureWorkflowIntent`), licenses and provenance. Nothing was installed or published.

## Device acceptance checks still required

These need an interactive installed/signed application and/or external devices/accounts; they have **not** been claimed as passing:

| Scenario | Acceptance criterion |
| --- | --- |
| Safari and Chrome, ordinary pages and lazy-loaded pages | Four directions where supported; seams reviewed; Stop/Pause excluded from captured pixels; unstable pages pause without losing frames. |
| Chat, VS Code, Terminal and custom scrolling utilities | Manual fallback works; unsupported automatic scroll never implies that the end of content was reached. |
| Source moved, resized, covered or display disconnected mid-session | Source guard pauses; existing frames remain reviewable. Restore geometry before continuing. |
| Multiple monitors with mixed scale factors | Region coordinates and stitched pixels stay aligned; switching display geometry pauses capture. |
| Shortcuts with app closed/open, canceled selection and deleted preset/workflow | Actions are discoverable from the built bundle; results/errors/cancellation propagate correctly. Metadata extraction and action unit tests are separate from this system-level check. |
| VoiceOver and keyboard-only complete workflow | Traverse layers and named controls, numeric ignored areas, Cut Out and guide ordering without a mouse. |
| Previous signed version → new version through Sparkle | Correct feed/key, verified download, preserved settings/projects, successful relaunch. |
| Apple notarization | Developer ID + notarization profile required; the release machine has an Apple Development identity but no Developer ID Application identity. |
| Intel runtime | Universal compilation does not prove execution on Intel hardware. |

Video/GIF, automatic click recording and cloud remain deferred scope. Cut Out intentionally flattens visible layers when a cut crosses artwork or includes rotated layers/spotlights/magnifiers; Undo restores all editability. Cross-volume metadata recovery is explicit relinking, not content-based guessing.
