import SwiftUI

struct LibraryThumbnail: View {
    let item: LibraryItem
    let maxPixelSize: Int
    var placeholder = "photo"

    @State private var image: CGImage?

    private var loadID: String {
        "\(item.url.path)|\(item.fileIdentity ?? "")|\(item.byteCount)|\(item.modifiedAt.timeIntervalSinceReferenceDate)|\(maxPixelSize)"
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: placeholder)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: loadID) {
            image = nil
            let result = await ThumbnailCache.shared.image(for: item, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            image = result
        }
        .onDisappear { image = nil }
    }
}
