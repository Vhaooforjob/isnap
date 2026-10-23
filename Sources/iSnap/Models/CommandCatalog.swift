import Foundation

@MainActor
struct WorkspaceCommand: Identifiable {
    let id: String
    let title: String
    let category: String
    let symbol: String
    var keywords = ""
    var enabled = true
    let perform: () -> Void

    static func search(_ commands: [Self], query: String) -> [Self] {
        let tokens = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return commands }
        return commands.compactMap { command -> (Self, Int)? in
            let title = normalized(command.title), words = normalized(command.title + " " + command.category + " " + command.keywords)
            guard tokens.allSatisfy(words.contains) else { return nil }
            let score = tokens.reduce(0) { $0 + (title.hasPrefix($1) ? 4 : title.contains($1) ? 2 : 0) }
            return (command, score)
        }.sorted { $0.1 == $1.1 ? $0.0.title.localizedStandardCompare($1.0.title) == .orderedAscending : $0.1 > $1.1 }.map(\.0)
    }
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "đ", with: "d")
    }
}

extension AppModel {
    var workspaceCommands: [WorkspaceCommand] {
        let hasImage = document.image != nil, captureReady = !isCapturing && !isWorkflowRunning
        let captureKeywords: [CaptureMode: String] = [.fullScreen: "man hinh", .region: "vung", .window: "cua so", .allDisplays: "tat ca man hinh"]
        let toolKeywords: [EditorTool: String] = [
            .select: "chon", .crop: "cat", .rectangle: "chu nhat", .ellipse: "elip tron", .arrow: "mui ten", .line: "duong thang",
            .text: "van ban chu", .spotlight: "noi bat", .number: "danh so", .redact: "che thong tin", .blur: "lam mo",
            .pixelate: "pixel hoa", .freehand: "ve tu do", .magnifier: "kinh lup", .highlighter: "to sang danh dau",
            .eraser: "tay xoa net", .ruler: "thuoc do", .sampler: "lay mau"]
        var commands: [WorkspaceCommand] = CaptureMode.allCases.map { mode in
            WorkspaceCommand(id: "capture.\(mode.rawValue)", title: mode.title, category: String(localized: "Capture"), symbol: mode.symbol,
                keywords: "capture screenshot chup anh \(mode.rawValue) \(captureKeywords[mode] ?? "")", enabled: captureReady) { Task { await self.capture(mode) } }
        }
        commands += EditorTool.allCases.filter { $0 != .image }.map { tool in
            WorkspaceCommand(id: "tool.\(tool.rawValue)", title: tool.title, category: String(localized: "Tools"), symbol: tool.symbol,
                keywords: "tool cong cu \(tool.rawValue) \(toolKeywords[tool] ?? "")", enabled: hasImage) {
                self.section = .editor; self.document.tool = tool
                if tool != .select { self.document.selectedAnnotationID = nil }
                if tool == .highlighter { self.document.style.strokeWidth = 20 }
            }
        }
        func command(_ id: String, _ title: String, _ symbol: String, _ keywords: String, enabled: Bool = true, action: @escaping () -> Void) -> WorkspaceCommand {
            WorkspaceCommand(id: id, title: title, category: "iSnap", symbol: symbol, keywords: keywords, enabled: enabled, perform: action)
        }
        commands += [
            command("library", String(localized: "Screenshot Library"), "photo.stack", "library thu vien") { self.section = .library },
            command("open", String(localized: "Open Image…"), "folder", "open mo anh", action: openImage),
            command("paste", String(localized: "Paste Image"), "doc.on.clipboard", "paste dan anh", action: pasteImage),
            command("copy", String(localized: "Copy Edited Image"), "doc.on.doc", "copy sao chep", enabled: hasImage && !isExporting, action: copy),
            command("save", String(localized: "Quick Save"), "square.and.arrow.down", "save luu", enabled: hasImage && !isExporting, action: quickSave),
            command("undo", String(localized: "Undo"), "arrow.uturn.backward", "undo hoan tac", enabled: document.canUndo, action: document.undo),
            command("redo", String(localized: "Redo"), "arrow.uturn.forward", "redo lam lai", enabled: document.canRedo, action: document.redo),
            command("ocr", String(localized: "Extract Text / QR"), "text.viewfinder", "ocr text qr van ban", enabled: hasImage && !isParsingScreenshot) { Task { await self.parseScreenshot() } },
            command("redactions", String(localized: "Suggest Redactions…"), "rectangle.fill", "redact privacy che thong tin", enabled: hasImage && !isParsingScreenshot) { Task { await self.findSensitiveInformation() } },
            command("cutout", String(localized: "Cut Out…"), "scissors", "cut out cat bo", enabled: hasImage) { self.isShowingCutOut = true },
            command("scroll", String(localized: "Scrolling Capture…"), "scroll", "scroll cuon", enabled: captureReady) { Task { await self.beginScrollingCapture() } },
            command("guide", String(localized: "Step Guide…"), "list.number", "guide huong dan", action: showGuide),
            command("pdf", String(localized: "Combine Images / PDF…"), "doc.richtext", "pdf combine ghep") { self.compositionPages = []; self.isShowingComposition = true },
            command("duplicates", String(localized: "Find Duplicate Files…"), "doc.on.doc", "duplicate trung lap") { self.isShowingDuplicates = true },
            command("workflows", String(localized: "Manage Workflows…"), "arrow.triangle.branch", "workflow quy trinh") { self.isShowingWorkflows = true },
            command("settings", String(localized: "Settings…"), "gearshape", "settings cai dat", action: showSettings)
        ]
        commands += (features.state.workflows ?? []).map { workflow in
            WorkspaceCommand(id: "workflow.\(workflow.id)", title: workflow.name, category: String(localized: "Workflows"), symbol: "arrow.triangle.branch",
                keywords: "workflow quy trinh", enabled: captureReady && !isExporting) { self.runWorkflow(workflow) }
        }
        return commands
    }

    func finishCommandSearch() {
        let action = pendingCommand; pendingCommand = nil; action?()
    }
}
