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

private enum LabSurface: String, CaseIterable, Identifiable {
    case recall
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recall: "Recall"
        case .settings: "Settings"
        }
    }
}

private struct VisualLabView: View {
    @State private var surface: LabSurface = CommandLine.arguments.contains("--settings") ? .settings : .recall
    @State private var settingsPage: AfterRaySettingsPage = CommandLine.arguments.contains("--models") ? .models : .general
    @State private var settingsModel = SettingsPreviewModel()
    @State private var scenario: RecallScenario = .long
    @State private var playheadMs = RecallScenario.long.moments[12].capturedAtMs
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
        VStack(spacing: 0) {
            Picker("Surface", selection: $surface) {
                ForEach(LabSurface.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))

            switch surface {
            case .recall:
                recallLab
            case .settings:
                settingsLab
            }
        }
        .onChange(of: scenario) { _, newScenario in
            favoriteOverrides = []
            let moments = newScenario.moments
            let index = min(max(moments.count / 2, 0), max(moments.count - 1, 0))
            playheadMs = moments.indices.contains(index) ? moments[index].capturedAtMs : 0
        }
    }

    private var recallLab: some View {
        HSplitView {
            RecallView(
                moments: moments,
                playheadMs: $playheadMs,
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
    }

    private var settingsLab: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            AfterRaySettingsView(
                model: settingsModel,
                onClose: { settingsModel.message = "Close is a no-op in Visual Lab." },
                initialPage: settingsPage
            )
        }
        .background(Color(red: 0.025, green: 0.022, blue: 0.026))
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
                    TuneSlider(title: "Top scrim", value: $tuning.topScrimOpacity, range: 0...1)
                    TuneSlider(title: "Bottom scrim", value: $tuning.bottomScrimOpacity, range: 0...1)
                    TuneSlider(title: "Timeline density", value: $tuning.timelineDensity, range: 0.04...0.36)
                    TuneSlider(title: "Segment height", value: $tuning.timelineSegmentHeight, range: 30...72)
                    TuneSlider(title: "Segment gap", value: $tuning.timelineSegmentGap, range: 0...8)
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
        guard let selected = RecallPlayhead.resolve(playheadMs: playheadMs, moments: moments) else { return }
        let id = selected.id
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
