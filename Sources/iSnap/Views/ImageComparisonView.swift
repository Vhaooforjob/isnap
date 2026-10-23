import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComparisonImages {
    let before: CGImage
    let after: CGImage
    let difference: CGImage
    let size: CGSize
    var changedPixels: Int = 0
}

actor ImageComparisonService {
    private var cachedURLs: [URL] = []
    private var cached: [CGImage] = []
    private var revisions: [FileRevision] = []

    func load(_ urls: [URL], threshold: Int = 0, ignored: [CGRect] = []) throws -> ComparisonImages {
        guard urls.count == 2 else { throw ExportError.invalidImage }
        let current = try urls.map(FileRevision.read)
        if cachedURLs != urls || revisions != current {
            let images = try urls.map { try ImageIOService.fullImage(at: $0) }
            guard try urls.map(FileRevision.read) == current else { throw CocoaError(.fileReadUnknown) }
            cached = images; cachedURLs = urls; revisions = current
        }
        return try Self.compare(cached[0], cached[1], threshold: threshold, ignored: ignored)
    }

    static func compare(_ a: CGImage, _ b: CGImage, threshold: Int = 0, ignored: [CGRect] = []) throws -> ComparisonImages {
        let width = max(a.width, b.width), height = max(a.height, b.height)
        guard width <= 60_000, height <= 60_000, width * height <= 80_000_000, ignored.count <= 100 else { throw ExportError.invalidImage }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        func context() throws -> CGContext {
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else { throw ExportError.invalidImage }
            return ctx
        }
        func padded(_ image: CGImage) throws -> CGContext {
            let ctx = try context()
            ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Top-left pixel alignment, independent of Retina scale and window points.
            ctx.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
            return ctx
        }
        let left = try padded(a), right = try padded(b), diff = try context()
        guard let l = left.data?.assumingMemoryBound(to: UInt8.self), let r = right.data?.assumingMemoryBound(to: UInt8.self),
              let d = diff.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.invalidImage }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let ignores = ignored.filter { [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) }.map { $0.intersection(bounds).integral }
        let tolerance = threshold.clamped(to: 0...255)
        var changed = 0
        for y in 0..<height {
            if y % 32 == 0 { try Task.checkCancellation() }
            let intervals = Self.mergedIntervals(ignores.filter { !$0.isNull && CGFloat(y) >= $0.minY && CGFloat(y) < $0.maxY }
                .map { Int($0.minX)..<Int($0.maxX) })
            var interval = 0
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let red = abs(Int(l[offset]) - Int(r[offset]))
                let green = abs(Int(l[offset + 1]) - Int(r[offset + 1]))
                let blue = abs(Int(l[offset + 2]) - Int(r[offset + 2]))
                while interval < intervals.count && x >= intervals[interval].upperBound { interval += 1 }
                let ignored = interval < intervals.count && x >= intervals[interval].lowerBound
                let different = max(red, green, blue) > tolerance && !ignored
                if different { changed += 1 }
                d[offset] = different ? UInt8(red) : 0
                d[offset + 1] = different ? UInt8(green) : 0
                d[offset + 2] = different ? UInt8(blue) : 0
                d[offset + 3] = 255
            }
        }
        guard let before = left.makeImage(), let after = right.makeImage(), let difference = diff.makeImage() else { throw ExportError.invalidImage }
        return ComparisonImages(before: before, after: after, difference: difference, size: bounds.size, changedPixels: changed)
    }

    static func mergedIntervals(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.filter({ !$0.isEmpty }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { result.append(range) }
        }
        return result
    }

    func png(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw ExportError.encodingFailed }
        return data
    }
}

struct ImageComparisonView: View {
    let urls: [URL]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var images: ComparisonImages?
    @State private var error: String?
    @State private var mode = 0
    @State private var split = 0.5
    @State private var swapped = false
    @State private var zoom = 0.0
    @State private var threshold = 0.0
    @State private var ignores: [CGRect] = []
    @State private var selectingIgnore = false
    @State private var pendingIgnore: CGRect?
    @State private var busy = false
    @State private var revision = 0
    @State private var numericIgnore = false
    @State private var ignoreX = 0.0
    @State private var ignoreY = 0.0
    @State private var ignoreWidth = 100.0
    @State private var ignoreHeight = 100.0
    @State private var service = ImageComparisonService()

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Compare Screenshots").font(.title2.bold())
                Spacer()
                Button("Export Difference…", action: exportDifference).disabled(images == nil || busy)
                Button("Swap") { swapped.toggle() }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Text((swapped ? urls.last : urls.first)?.lastPathComponent ?? "").lineLimit(1)
                Spacer()
                Text((swapped ? urls.first : urls.last)?.lastPathComponent ?? "").lineLimit(1)
            }.font(.caption)
            Picker("Comparison", selection: $mode) {
                Text("Side by Side").tag(0); Text("Before / After").tag(1); Text("Difference").tag(2)
            }.pickerStyle(.segmented)
            HStack {
                Picker("Zoom", selection: $zoom) {
                    Text("Fit").tag(0.0); Text("100%").tag(1.0); Text("200%").tag(2.0); Text("400%").tag(4.0)
                }.frame(width: 170)
                Text("Tolerance")
                Slider(value: $threshold, in: 0...255, step: 1).onChange(of: threshold) { _, _ in revision += 1 }.frame(width: 120)
                Text("\(Int(threshold))").monospacedDigit().frame(width: 28)
                Toggle("Ignore Area", isOn: $selectingIgnore).toggleStyle(.button).disabled(mode == 0)
                Button("Add Area…") { numericIgnore = true }.popover(isPresented: $numericIgnore) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ignored rectangle in image pixels")
                        TextField("X", value: $ignoreX, format: .number)
                        TextField("Y", value: $ignoreY, format: .number)
                        TextField("Width", value: $ignoreWidth, format: .number)
                        TextField("Height", value: $ignoreHeight, format: .number)
                        Button("Add") {
                            guard let images, [ignoreX, ignoreY, ignoreWidth, ignoreHeight].allSatisfy(\.isFinite), ignoreWidth > 0, ignoreHeight > 0 else { return }
                            let rect = CGRect(x: ignoreX, y: ignoreY, width: ignoreWidth, height: ignoreHeight).intersection(CGRect(origin: .zero, size: images.size)).integral
                            if !rect.isNull && !rect.isEmpty && ignores.count < 100 { ignores.append(rect); revision += 1; numericIgnore = false }
                        }.disabled(ignores.count >= 100 || images == nil)
                    }.textFieldStyle(.roundedBorder).padding().frame(width: 260)
                }
                Button("Undo Ignore") { if !ignores.isEmpty { ignores.removeLast(); revision += 1 } }.disabled(ignores.isEmpty)
                Button("Clear") { ignores = []; revision += 1 }.disabled(ignores.isEmpty)
                if busy { ProgressView().controlSize(.small) }
            }.controlSize(.small)
            if let images {
                GeometryReader { geometry in
                    let width = mode == 0 ? (geometry.size.width - 12) / 2 : geometry.size.width
                    let scale = zoom == 0 ? min(width / images.size.width, geometry.size.height / images.size.height) : zoom / displayScale
                    let size = CGSize(width: images.size.width * scale, height: images.size.height * scale)
                    // A single scroll view pans both images together.
                    ScrollView([.horizontal, .vertical]) {
                        HStack(spacing: 12) {
                            if mode == 0 {
                                bitmap(swapped ? images.after : images.before).frame(width: size.width, height: size.height)
                                bitmap(swapped ? images.before : images.after).frame(width: size.width, height: size.height)
                            } else {
                                ZStack(alignment: .topLeading) {
                                    if mode == 1 {
                                        bitmap(swapped ? images.before : images.after)
                                        bitmap(swapped ? images.after : images.before)
                                            .mask(alignment: .leading) { Rectangle().frame(width: size.width * split) }
                                        Rectangle().fill(.orange).frame(width: 2).offset(x: size.width * split)
                                    } else { bitmap(images.difference) }
                                    ForEach(Array((ignores + (pendingIgnore.map { [$0] } ?? [])).enumerated()), id: \.offset) { _, rect in
                                        Rectangle().fill(.orange.opacity(0.15)).overlay(Rectangle().stroke(.orange, lineWidth: 1))
                                            .frame(width: rect.width * scale, height: rect.height * scale)
                                            .offset(x: rect.minX * scale, y: rect.minY * scale)
                                    }
                                    if selectingIgnore {
                                        Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 1)
                                            .onChanged { value in pendingIgnore = selection(value, scale: scale, size: images.size) }
                                            .onEnded { value in
                                                let rect = selection(value, scale: scale, size: images.size)
                                                if !rect.isEmpty && ignores.count < 100 { ignores.append(rect); revision += 1 }
                                                pendingIgnore = nil
                                            })
                                    }
                                }.frame(width: size.width, height: size.height)
                            }
                        }
                    }
                }
                if mode == 1 { Slider(value: $split, in: 0...1) { Text("Before / After") } }
                Text("\(images.changedPixels) changed pixels · \(Int(images.size.width)) × \(Int(images.size.height))")
                    .font(.caption).accessibilityLabel(String(localized: "\(images.changedPixels) changed pixels"))
                Text("Comparison and export use original pixels. At 100%, one image pixel equals one display pixel. Use Before / After or Difference to mark ignored areas.")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Spacer(); if busy { ProgressView() }; Spacer() }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(20).frame(width: 1000, height: 680)
        .task(id: revision) {
            busy = true; error = nil
            do {
                try await Task.sleep(for: .milliseconds(120))
                let result = try await service.load(urls, threshold: Int(threshold), ignored: ignores)
                try Task.checkCancellation(); images = result; busy = false
            } catch is CancellationError { }
            catch { images = nil; self.error = error.localizedDescription; busy = false }
        }
    }
    private func selection(_ value: DragGesture.Value, scale: CGFloat, size: CGSize) -> CGRect {
        CGRect(x: min(value.startLocation.x, value.location.x) / scale, y: min(value.startLocation.y, value.location.y) / scale,
            width: abs(value.location.x - value.startLocation.x) / scale, height: abs(value.location.y - value.startLocation.y) / scale)
            .intersection(CGRect(origin: .zero, size: size)).integral
    }
    private func bitmap(_ image: CGImage) -> some View {
        Image(nsImage: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)))
            .resizable().interpolation(zoom == 0 ? .high : .none)
            .accessibilityLabel(String(localized: "Screenshot comparison"))
    }
    private func exportDifference() {
        guard let images else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Difference.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do { let data = try await service.png(images.difference); try await BackgroundExportService().write(data, to: url, overwrite: true) }
            catch { self.error = error.localizedDescription }
        }
    }
}
