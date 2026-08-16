import CoreGraphics
import SwiftUI

/// A screenshot citation backed only by afterrayd's read-only thumbnail API.
/// The whole card remains a moment link when the capture was deleted or could
/// not be decoded, so missing media never erases the citation itself.
struct ChatMomentCitationView: View {
    let label: String
    let momentID: String
    let thumbnailLoader: RecallThumbnailLoader?
    let onOpenMoment: ((String) -> Void)?

    @State private var image: CGImage?
    @State private var loadFinished = false

    var body: some View {
        Button(action: openMoment) {
            ZStack(alignment: .bottomLeading) {
                thumbnail
                LinearGradient(
                    colors: [.clear, .black.opacity(0.82)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                HStack(alignment: .bottom, spacing: 8) {
                    Text(label.isEmpty ? "Captured moment" : label)
                        .font(.callout)
                        .bold()
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right")
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.white)
                .padding(12)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: 440)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(onOpenMoment == nil)
        .help("Open this captured moment")
        .accessibilityLabel("Open captured moment: \(label.isEmpty ? "Screenshot" : label)")
        .task(id: momentID, loadThumbnail)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .clipped()
        } else if loadFinished {
            Label("Screenshot unavailable", systemImage: "photo")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(RecallPalette.ray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func openMoment() {
        onOpenMoment?(momentID)
    }

    @MainActor
    private func loadThumbnail() async {
        image = nil
        loadFinished = false
        defer { loadFinished = true }
        guard let thumbnailLoader else { return }
        image = await RecallThumbnailCache.shared.image(
            momentID: momentID,
            loader: thumbnailLoader
        )
    }
}
