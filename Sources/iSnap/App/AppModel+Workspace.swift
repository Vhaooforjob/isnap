import AppKit
import UniformTypeIdentifiers

extension AppModel {
    func batchExport(to folder: URL, options: BatchExportOptions) {
        guard !isBatchExporting else { return }
        let items = batchItems
        isBatchExporting = true
        batchProgress = ""
        batchTask = Task {
            let exporter = BatchExportService()
            var completed = 0
            var failures: [String] = []
            for (index, item) in items.enumerated() {
                if Task.isCancelled { break }
                do {
                    _ = try await exporter.export(item.url, to: folder, index: index + 1, options: options)
                    completed += 1
                } catch is CancellationError { break }
                catch { failures.append(item.name) }
                batchProgress = String(localized: "Exporting: \(index + 1)/\(items.count)")
            }
            let stopped = Task.isCancelled
            batchProgress = stopped
                ? String(localized: "Stopped. \(completed) images were exported; completed files are kept.")
                : String(localized: "Exported \(completed) images.")
            if !failures.isEmpty { batchProgress += "\n" + String(localized: "Failed: \(failures.joined(separator: ", "))") }
            isBatchExporting = false
            await reloadLibrary()
        }
    }

    func findSensitiveInformation() async {
        guard !isParsingScreenshot, let image = document.image,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        isParsingScreenshot = true
        defer { isParsingScreenshot = false }
        do {
            let result = try await ScreenshotParserService().parse(cg, includeGlyphs: true, recognizeCodes: false)
            guard document.image === image else { return }
            redactionRegions = result.regions
            redactionMatches = try await RedactionMatcher().match(result.regions, rules: features.state.redactionRules ?? [], wholeLines: true)
            guard document.image === image else { return }
            sensitiveRegions = redactionMatches.map(\.region)
            redactionSource = image
            isShowingRedactionReview = true
        } catch { errorMessage = error.localizedDescription }
    }

    func redactRegions(_ ids: Set<UUID>) {
        guard document.image === redactionSource else {
            errorMessage = String(localized: "The image changed. Scan it again before applying redactions.")
            return
        }
        // Cover glyph edges and keep applying a group undoable in one step.
        document.addPrivacyMasks(sensitiveRegions.filter { ids.contains($0.id) }.map { $0.rect.insetBy(dx: -4, dy: -4) })
        isShowingRedactionReview = false
        sensitiveRegions = []; redactionRegions = []; redactionSource = nil
    }

    func saveDraft() {
        guard connectsServices, !isRestoringProject, document.image != nil else { return }
        do { try draftWriter.save(document.projectSnapshot(), to: [ProjectStore.latestURL]) }
        catch { errorMessage = String(localized: "Draft could not be saved: \(error.localizedDescription)") }
    }

    func scheduleDraft() {
        guard connectsServices, !isRestoringProject, document.image != nil else { return }
        do {
            let id = draftID
            draftWriter.enqueue(try document.projectSnapshot(), to: ProjectStore.latestURL) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in
                    guard let self, self.draftID == id else { return }
                    self.errorMessage = String(localized: "Draft could not be saved: \(error.localizedDescription)")
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// A failed disk write must never silently discard the current document.
    func preserveCurrentDraft() -> Bool {
        guard connectsServices, document.image != nil else { return true }
        do {
            let snapshot = try document.projectSnapshot()
            let name = String(document.sourceName.prefix(60)).replacingOccurrences(of: "/", with: "-")
            let url = ProjectStore.directory.appendingPathComponent("\(name)-\(draftID).isnap")
            try draftWriter.save(snapshot, to: [url, ProjectStore.latestURL])
            drafts = ProjectStore.drafts
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func restoreLatestDraft() {
        drafts = ProjectStore.drafts
        guard FileManager.default.fileExists(atPath: ProjectStore.latestURL.path) ||
            FileManager.default.fileExists(atPath: ProjectStore.previousURL.path) else { return }
        isRestoringProject = true
        defer { isRestoringProject = false }
        do {
            try document.loadProject(ProjectStore.recover())
            statusText = String(localized: "Restored last editing session")
        } catch { errorMessage = String(localized: "Draft could not be restored: \(error.localizedDescription)") }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "isnap") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    func openProject(at url: URL) {
        do {
            let project = try ProjectStore.read(url)
            guard preserveCurrentDraft() else { return }
            try document.loadProject(project)
            draftID = UUID()
            recognizedText = ""
            isShowingParsedData = false
            section = .editor
            saveDraft()
            presentMainWindow?()
        } catch { errorMessage = error.localizedDescription }
    }

    func saveProject() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "isnap") ?? .data]
        panel.nameFieldStringValue = "\(document.sourceName).isnap"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProjectStore.write(document.project(), to: url)
            document.markSaved()
            statusText = String(localized: "Saved editable project")
        } catch { errorMessage = error.localizedDescription }
    }

    func waitForCapture() async throws {
        let delay = features.state.captureDelay.clamped(to: 0...10)
        if delay > 0 {
            for remaining in stride(from: delay, through: 1, by: -1) {
                statusText = String(localized: "Capturing in \(remaining)…")
                try await Task.sleep(for: .seconds(1))
            }
        } else { try await Task.sleep(for: .milliseconds(200)) }
    }

    func captureLastRegion() async {
        guard !isCapturing, let selection = lastRegion else { return }
        isCapturing = true
        defer { isCapturing = false; NSApp.unhide(nil) }
        do {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == selection.displayID }),
                  CGRect(origin: .zero, size: screen.frame.size).contains(selection.rect) else {
                throw CaptureError.displayUnavailable
            }
            NSApp.hide(nil)
            try await waitForCapture()
            let result = try await captureService.capture(displayID: selection.displayID,
                region: selection.rect, showsCursor: features.state.showsCursor)
            NSApp.unhide(nil)
            accept(result, isCapture: true)
        } catch { errorMessage = error.localizedDescription }
    }

    func startIndexing(_ items: [LibraryItem]) {
        indexTask?.cancel()
        let urls = Set(items.map(\.url))
        indexedText = indexedText.filter { urls.contains($0.key) }
        indexTask = Task { [weak self] in
            guard let self else { return }
            isIndexing = true
            var failures = 0
            do { try await searchIndex.prune(in: settings.value.quickSave.folder, keeping: urls) }
            catch { errorMessage = error.localizedDescription }
            guard !Task.isCancelled else { return }
            for (offset, item) in items.enumerated() {
                guard !Task.isCancelled else { return }
                do {
                    let text = try await searchIndex.text(for: item.url, modifiedAt: item.modifiedAt)
                    guard !Task.isCancelled else { return }
                    indexedText[item.url] = text
                } catch is CancellationError { return }
                catch { failures += 1 }
                indexingProgress = String(localized: "Indexing text: \(offset + 1)/\(items.count)")
            }
            guard !Task.isCancelled else { return }
            do { try await searchIndex.save() }
            catch { errorMessage = error.localizedDescription }
            guard !Task.isCancelled else { return }
            indexingProgress = failures == 0 ? "" : String(localized: "\(failures) images could not be indexed. Refresh to retry.")
            isIndexing = false
        }
    }

    func toggleFavorite(_ item: LibraryItem) {
        var metadata = features.metadata(for: item.url)
        metadata.favorite.toggle()
        features.setMetadata(metadata, for: item.url)
    }

    func editTags(for items: [LibraryItem]) {
        guard !items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Edit Tags")
        alert.informativeText = String(localized: "Separate tags with commas. This replaces tags for the selected images.")
        let input = NSTextField(string: items.count == 1 ? features.metadata(for: items[0].url).tags.joined(separator: ", ") : "")
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let tags = Array(Set(input.stringValue.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        features.setTags(tags, for: items.map(\.url))
    }

    func saveCanvasPreset(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let data = try document.canvas.backgroundImageURL.map { try Data(contentsOf: $0) }
            features.state.presets.append(CanvasPreset(name: name, canvas: document.canvas, backgroundImage: data))
        } catch { errorMessage = error.localizedDescription }
    }

    func resolvedCanvas(for preset: CanvasPreset) throws -> CanvasConfiguration {
        var canvas = preset.canvas
        if let data = preset.backgroundImage {
            let folder = ProjectStore.directory.deletingLastPathComponent().appendingPathComponent("Project Backgrounds")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(ProjectAsset.digest(data) + ".png")
            if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
            canvas.backgroundImageURL = url
        }
        return canvas
    }

    func applyPreset(_ preset: CanvasPreset) {
        do {
            let canvas = try resolvedCanvas(for: preset)
            document.updateCanvas { $0 = canvas }
            settings.value.canvas = canvas
        } catch { errorMessage = error.localizedDescription }
    }

    func pinImage(at url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        pinnedImages.pin(image, title: url.lastPathComponent)
    }

    func pinEditedImage() {
        do {
            let image = try exportService.render(document: document, includeBackground: settings.value.export.includeBackground)
            pinnedImages.pin(image, title: document.sourceName)
        } catch { errorMessage = error.localizedDescription }
    }

    func showGuide() {
        guideController.show { [weak self] in
            guard let self, !self.isCapturing else { throw CaptureError.cancelled }
            self.isCapturing = true
            let windows = NSApp.windows.filter(\.isVisible)
            windows.forEach { $0.orderOut(nil) }
            defer { windows.forEach { $0.orderFront(nil) }; self.isCapturing = false }
            guard let selection = await self.regionCoordinator.selectRegion() else { return nil }
            try await Task.sleep(for: .milliseconds(250))
            let result = try await self.captureService.capture(displayID: selection.displayID, region: selection.rect, excludingOwnWindows: true)
            try Task.checkCancellation()
            return result.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
    }

    func beginScrollingCapture() async {
        guard !isCapturing else { return }
        isCapturing = true
        let windows = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }
        windows.forEach { $0.orderOut(nil) }
        do {
            guard let selection = await regionCoordinator.selectRegion() else { throw CaptureError.cancelled }
            lastRegion = selection
            try await Task.sleep(for: .milliseconds(250))
            let sourceGuard = ScrollSourceGuard(selection: selection)
            let first = try await captureService.capture(displayID: selection.displayID, region: selection.rect, excludingOwnWindows: true)
            guard let image = first.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ExportError.invalidImage }
            scrollCapture.begin(first: image, capture: { [weak self] in
                guard let self else { throw CaptureError.cancelled }
                try sourceGuard.validate()
                try await Task.sleep(for: .milliseconds(300))
                try sourceGuard.validate()
                let result = try await captureService.capture(displayID: selection.displayID, region: selection.rect, excludingOwnWindows: true)
                guard let image = result.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ExportError.invalidImage }
                return image
            }, scroll: { [weak self] in
                try sourceGuard.validate()
                try await ScrollEventService.scroll(selection, direction: self?.scrollCapture.direction ?? .down)
            }, completion: { [weak self] image in
                windows.forEach { $0.orderFront(nil) }
                guard let self else { return }
                isCapturing = false
                if let image { accept(CaptureResult(image: image, sourceName: String(localized: "Scrolling Capture")), isCapture: true) }
            })
        } catch CaptureError.cancelled {
            windows.forEach { $0.orderFront(nil) }
            isCapturing = false
        } catch {
            windows.forEach { $0.orderFront(nil) }
            isCapturing = false
            errorMessage = error.localizedDescription
        }
    }
}
