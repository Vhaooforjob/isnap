import AppKit

extension AppModel {
    func cancelWorkflow() { workflowTask?.cancel(); regionCoordinator.cancelSelection() }

    func runWorkflow(_ workflow: CaptureWorkflow) {
        do { _ = try startWorkflow(workflow) }
        catch { errorMessage = error.localizedDescription }
    }

    func startWorkflow(_ workflow: CaptureWorkflow) throws -> Task<RenderedExport, Error> {
        guard !isCapturing, !isWorkflowRunning, !isUploading, !isExporting else { throw AutomationError.busy }
        isWorkflowRunning = true; isCapturing = true
        let task = Task<RenderedExport, Error> {
            let windows = NSApp.windows.filter(\.isVisible)
            defer {
                isWorkflowRunning = false; isCapturing = false
                windows.forEach { $0.orderFront(nil) }
            }
            do {
                if let provider = workflow.activeUploadProvider, !isAvailable(provider) { throw WorkflowError.unavailableProvider }
                var canvas = CanvasConfiguration(); canvas.cornerRadius = 0; canvas.shadowSize = 0
                if let id = workflow.presetID {
                    guard let preset = features.state.presets.first(where: { $0.id == id }) else { throw WorkflowError.missingPreset }
                    canvas = try resolvedCanvas(for: preset)
                }
                if !workflow.watermark.isEmpty {
                    var watermark = WatermarkConfiguration(); watermark.text = workflow.watermark
                    canvas.watermark = watermark
                }
                let preferences = settings.value
                windows.forEach { $0.orderOut(nil) }
                let result: CaptureResult
                if workflow.region {
                    guard let selection = await regionCoordinator.selectRegion() else { throw CancellationError() }
                    lastRegion = selection
                    try await waitForCapture()
                    result = try await captureService.capture(displayID: selection.displayID, region: selection.rect,
                        showsCursor: features.state.showsCursor, excludingOwnWindows: true)
                } else {
                    guard let id = NSScreen.underPointer?.displayID else { throw CaptureError.displayUnavailable }
                    try await waitForCapture()
                    result = try await captureService.capture(displayID: id, showsCursor: features.state.showsCursor, excludingOwnWindows: true)
                }
                try Task.checkCancellation()
                guard let image = result.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ExportError.invalidImage }
                statusText = String(localized: "Running workflow…")
                let snapshot = ImageRenderSnapshot(image: image, annotations: [], canvas: canvas, includeBackground: true)
                let output = try await backgroundExporter.render(snapshot, format: preferences.export.defaultFormat, quality: preferences.export.jpegQuality)
                try Task.checkCancellation()
                if workflow.saves {
                    let url = try await backgroundExporter.quickSave(output.data, settings: preferences)
                    if preferences.captureLine.isEnabled { captureLineController.hang(url, from: nil) }
                    await reloadLibrary()
                }
                try Task.checkCancellation()
                if workflow.copies {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([NSImage(cgImage: output.image, size: CGSize(width: output.image.width, height: output.image.height))])
                }
                guard loadIntoEditor(result) else { throw AutomationError.draftPreservation }
                document.updateCanvas { $0 = canvas }
                if let provider = workflow.activeUploadProvider {
                    try Task.checkCancellation()
                    await startUpload(data: output.data, fileExtension: preferences.export.defaultFormat.fileExtension, provider: provider)
                } else { statusText = String(localized: "Workflow completed") }
                return output
            } catch is CancellationError {
                statusText = String(localized: "Workflow cancelled"); throw CancellationError()
            } catch { errorMessage = error.localizedDescription; throw error }
        }
        workflowTask = task
        return task
    }
}

enum WorkflowError: LocalizedError {
    case missingPreset, unavailableProvider
    var errorDescription: String? {
        switch self {
        case .missingPreset: String(localized: "The workflow preset no longer exists. Choose another preset before running it.")
        case .unavailableProvider: String(localized: "Connect the workflow upload provider and select its workspace before running it.")
        }
    }
}
