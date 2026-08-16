import SwiftUI

struct ChatLatestButton: View {
    let action: () -> Void

    var body: some View {
        Button("Latest", systemImage: "arrow.down", action: action)
            .font(.callout)
            .bold()
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Color.black.opacity(0.78), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(RecallPalette.ray.opacity(0.48), lineWidth: 1)
            }
            .buttonStyle(.plain)
            .help("Jump to the latest response")
            .accessibilityIdentifier("chat-jump-to-latest")
    }
}
