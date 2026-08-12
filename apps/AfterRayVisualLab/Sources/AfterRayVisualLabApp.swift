import AfterRayMockData
import AfterRayRecall
import SwiftUI

@main
struct AfterRayVisualLabApp: App {
    var body: some Scene {
        WindowGroup("AfterRay Visual Lab") {
            VisualLabView()
                .frame(minWidth: 1_080, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_320, height: 820)
    }
}

private struct VisualLabView: View {
    @State private var scenario: RecallScenario = .long
    @State private var selectedIndex = 12
    @State private var tuning = RecallVisualTuning.standard
    @State private var favoriteOverrides: Set<String> = []

    private var moments: [RecallMoment] {
        scenario.moments.map { moment in
            guard favoriteOverrides.contains(moment.id) else { return moment }
            var copy = moment
            copy.isFavorite.toggle()
            return copy
        }
    }

    var body: some View {
        HSplitView {
            RecallView(
                moments: moments,
                selectedIndex: $selectedIndex,
                loadState: scenario.loadState,
                tuning: tuning,
                imageLoader: MockArtifactFactory.loader,
                onToggleFavorite: toggleFavorite,
                onToggleAudio: { _ in }
            )
            .frame(minWidth: 760)

            tuningPanel
                .frame(minWidth: 250, idealWidth: 280, maxWidth: 320)
        }
        .onChange(of: scenario) { _, newScenario in
            favoriteOverrides = []
            selectedIndex = min(max(newScenario.moments.count / 2, 0), max(newScenario.moments.count - 1, 0))
        }
    }

    private var tuningPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("VISUAL LAB")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(.red)
                    Text("Recall tuning")
                        .font(.title2.weight(.semibold))
                }

                Picker("Scene", selection: $scenario) {
                    ForEach(RecallScenario.allCases) { scene in
                        Text(scene.title).tag(scene)
                    }
                }
                .pickerStyle(.menu)

                VStack(spacing: 18) {
                    TuneSlider(title: "Thumbnail width", value: $tuning.thumbnailWidth, range: 72...168)
                    TuneSlider(title: "Thumbnail spacing", value: $tuning.thumbnailSpacing, range: 2...28)
                    TuneSlider(title: "Selected scale", value: $tuning.selectedScale, range: 0.86...1.08)
                    TuneSlider(title: "Neighbor scale", value: $tuning.neighborScale, range: 0.64...1)
                    TuneSlider(title: "Dim opacity", value: $tuning.dimOpacity, range: 0...0.72)
                    TuneSlider(title: "Red glow", value: $tuning.glowStrength, range: 0...1)
                    TuneSlider(title: "Drag sensitivity", value: $tuning.dragPointsPerMoment, range: 20...120)
                }

                Button("Reset tuning") { tuning = .standard }
                    .buttonStyle(.bordered)
            }
            .padding(22)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func toggleFavorite() {
        guard moments.indices.contains(selectedIndex) else { return }
        let id = moments[selectedIndex].id
        if favoriteOverrides.contains(id) { favoriteOverrides.remove(id) }
        else { favoriteOverrides.insert(id) }
    }
}

private struct TuneSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(2)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}
