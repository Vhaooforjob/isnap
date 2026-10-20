import AppKit

extension AppModel {
    enum EditorExportAction { case quickSave, saveAs(URL), copy, share }

    func renderSnapshot(includeBackground: Bool? = nil) throws -> ImageRenderSnapshot {
        guard let image = document.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ExportError.invalidImage }
        return ImageRenderSnapshot(image: image, annotations: document.annotations, canvas: document.canvas,
            includeBackground: includeBackground ?? settings.value.export.includeBackground)
    }

    func performExport(_ action: EditorExportAction) {
        guard !isExporting else { return }
        do {
            let snapshot = try renderSnapshot()
            settings.value.canvas = document.canvas
            let revision = document.revision, source = document.image, preferences = settings.value
            isExporting = true
            statusText = String(localized: "Rendering export…")
            exportTask = Task {
                defer { isExporting = false }
                do {
                    let output = try await backgroundExporter.render(snapshot, format: preferences.export.defaultFormat, quality: preferences.export.jpegQuality)
                    try Task.checkCancellation()
                    let image = NSImage(cgImage: output.image, size: CGSize(width: output.image.width, height: output.image.height))
                    switch action {
                    case .copy:
                        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
                        statusText = String(localized: "Copied to clipboard")
                    case .share:
                        let data = output.data, ext = preferences.export.defaultFormat.fileExtension
                        let url = try await Task.detached { try ShareService.prepareFile(data, fileExtension: ext) }.value
                        try Task.checkCancellation()
                        showShareMenu(for: url)
                    case .quickSave, .saveAs:
                        let url: URL
                        if case .saveAs(let target) = action {
                            try await backgroundExporter.write(output.data, to: target, overwrite: true); url = target
                        } else { url = try await backgroundExporter.quickSave(output.data, settings: preferences) }
                        if source === document.image, revision == document.revision { document.markSaved() }
                        if preferences.export.autoCopyToClipboard {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
                        }
                        statusText = String(localized: "Saved \(url.lastPathComponent)")
                        await reloadLibrary()
                    }
                } catch is CancellationError { statusText = String(localized: "Export cancelled") }
                catch { errorMessage = error.localizedDescription }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func cancelUpload() { uploadTask?.cancel() }
    func retryUpload() {
        guard FeatureAvailability.cloud, !isUploading, let retryData else { return }
        Task { await startUpload(data: retryData.data, fileExtension: retryData.ext, provider: retryData.provider) }
    }

    func startUpload(data: Data, fileExtension: String, provider: CloudProvider) async {
        guard FeatureAvailability.cloud, !isUploading else { return }
        isUploading = true; uploadFraction = 0
        retryData = (data, fileExtension, provider)
        uploadTask = Task {
            defer { isUploading = false }
            do {
                try await uploadPayload(data, fileExtension: fileExtension, to: provider)
                retryData = nil
            } catch is CancellationError { statusText = String(localized: "Upload cancelled") }
            catch let error as URLError where error.code == .cancelled { statusText = String(localized: "Upload cancelled") }
            catch { errorMessage = error.localizedDescription }
        }
        await withTaskCancellationHandler { await uploadTask?.value } onCancel: {
            Task { @MainActor [weak self] in self?.cancelUpload() }
        }
    }
}
