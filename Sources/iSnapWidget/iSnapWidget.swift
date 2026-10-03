import AppKit
import Darwin
import SwiftUI
import WidgetKit

private let appGroupIdentifier = "group.dev.isnap.app"
private let widgetKind = "iSnapRecentWidget"

private struct RecentItem: Codable, Identifiable {
    let name: String
    let thumbnailName: String
    let modifiedAt: Date
    let width: Int
    let height: Int

    var id: String { name }
}

private struct RecentSnapshot: Codable {
    let updatedAt: Date
    let totalCount: Int
    let items: [RecentItem]

    static let empty = RecentSnapshot(updatedAt: .now, totalCount: 0, items: [])
}

private struct RecentEntry: TimelineEntry {
    let date: Date
    let snapshot: RecentSnapshot
    let directory: URL?
}

private struct RecentProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentEntry {
        RecentEntry(date: .now, snapshot: .empty, directory: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentEntry>) -> Void) {
        let entry = loadEntry()
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func loadEntry() -> RecentEntry {
        let directory = widgetDirectories().first { directory in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("snapshot.json").path)
        } ?? widgetDirectories().first
        let snapshot = directory
            .flatMap { try? Data(contentsOf: $0.appendingPathComponent("snapshot.json")) }
            .flatMap { try? JSONDecoder().decode(RecentSnapshot.self, from: $0) } ?? .empty
        return RecentEntry(date: .now, snapshot: snapshot, directory: directory)
    }

    private func widgetDirectories() -> [URL] {
        let fileManager = FileManager.default
        var directories: [URL] = []
        if let groupDirectory = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            directories.append(groupDirectory.appendingPathComponent("Widget", isDirectory: true))
        }
        if let userRecord = getpwuid(getuid()) {
            let homeDirectory = URL(fileURLWithPath: String(cString: userRecord.pointee.pw_dir))
            let fallback = homeDirectory.appendingPathComponent(
                "Library/Application Support/iSnap/Widget",
                isDirectory: true
            )
            if !directories.contains(fallback) { directories.append(fallback) }
        }
        return directories
    }
}

private struct RecentWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RecentEntry

    var body: some View {
        Group {
            if family == .systemSmall {
                smallWidget
            } else {
                mediumWidget
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var smallWidget: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let item = entry.snapshot.items.first {
                thumbnail(item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(item.name)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            } else {
                emptyState
            }
            Label("Open in iSnap", systemImage: "arrow.up.forward.app")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
        }
        .widgetURL(smallDestination)
    }

    private var mediumWidget: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                header
                Spacer()
                navigationLinks
            }
            if entry.snapshot.items.isEmpty {
                emptyState
            } else {
                HStack(spacing: 9) {
                    ForEach(entry.snapshot.items.prefix(3)) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            ZStack(alignment: .topTrailing) {
                                Link(destination: itemURL("open", item: item)) {
                                    thumbnail(item)
                                }
                                .buttonStyle(.plain)
                                Link(destination: itemURL("trash", item: item)) {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.58))
                                        .font(.system(size: 16, weight: .semibold))
                                        .padding(4)
                                }
                                .buttonStyle(.plain)
                            }
                            Text(item.name)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "camera.viewfinder")
                .foregroundStyle(.tint)
            Text("iSnap")
                .font(.headline)
            Text("\(entry.snapshot.totalCount)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var navigationLinks: some View {
        HStack(spacing: 6) {
            Link(destination: URL(string: "isnap://editor")!) {
                Image(systemName: "photo.on.rectangle.angled")
                    .frame(width: 24, height: 20)
            }
            .help("Open Editor")
            Link(destination: URL(string: "isnap://library")!) {
                Image(systemName: "photo.stack")
                    .frame(width: 24, height: 20)
            }
            .help("Open Library")
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        Link(destination: URL(string: "isnap://editor")!) {
            VStack(spacing: 6) {
                Image(systemName: "photo.badge.plus").font(.title2)
                Text("Save a screenshot to see it here")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func thumbnail(_ item: RecentItem) -> some View {
        Group {
            if let directory = entry.directory,
               let image = NSImage(contentsOf: directory.appendingPathComponent(item.thumbnailName)) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func itemURL(_ action: String, item: RecentItem) -> URL {
        var components = URLComponents()
        components.scheme = "isnap"
        components.host = action
        components.queryItems = [URLQueryItem(name: "name", value: item.name)]
        return components.url ?? URL(string: "isnap://library")!
    }

    private var smallDestination: URL {
        guard let item = entry.snapshot.items.first else {
            return URL(string: "isnap://editor")!
        }
        return itemURL("open", item: item)
    }
}

struct iSnapRecentWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: widgetKind, provider: RecentProvider()) { entry in
            RecentWidgetView(entry: entry)
        }
        .configurationDisplayName("Recent Screenshots")
        .description("Open, review, and remove recent iSnap screenshots.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct iSnapWidgetBundle: WidgetBundle {
    var body: some Widget {
        iSnapRecentWidget()
    }
}
