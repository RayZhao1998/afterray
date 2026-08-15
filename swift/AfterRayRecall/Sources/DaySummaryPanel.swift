import SwiftUI

/// How the panel is being hosted. The overlay pins its size and wears
/// glass; a standalone window fills whatever the user resizes it to.
public enum DaySummaryPanelStyle: Sendable {
    case overlay
    case window
}

/// The history-summary panel is deliberately a single lazy scroll view: it
/// can keep walking toward the earliest capture without retaining every row
/// in the SwiftUI view tree or asking each row to hit the daemon.
public struct DaySummaryPanel: View {
    var style: DaySummaryPanelStyle = .overlay
    var onPopOut: (() -> Void)? = nil
    let summaries: [DaySummary]
    let playheadMs: Int64
    let nowMs: Int64
    let hasMore: Bool
    let isLoadingMore: Bool
    /// Bumped by the overlay when a scrub settles; the one moment the list
    /// follows the playhead. Following every half-hour crossing mid-glide
    /// was a scrollTo storm that churned rows (and their thumbnails) faster
    /// than the main thread could keep up.
    let followPulse: Int
    let thumbnailLoader: RecallThumbnailLoader?
    let onSelectSlot: (Int64) -> Void
    let onLoadMore: () -> Void

    public init(
        style: DaySummaryPanelStyle = .overlay,
        onPopOut: (() -> Void)? = nil,
        summaries: [DaySummary],
        playheadMs: Int64,
        nowMs: Int64,
        hasMore: Bool,
        isLoadingMore: Bool,
        followPulse: Int,
        thumbnailLoader: RecallThumbnailLoader?,
        onSelectSlot: @escaping (Int64) -> Void,
        onLoadMore: @escaping () -> Void
    ) {
        self.style = style
        self.onPopOut = onPopOut
        self.summaries = summaries
        self.playheadMs = playheadMs
        self.nowMs = nowMs
        self.hasMore = hasMore
        self.isLoadingMore = isLoadingMore
        self.followPulse = followPulse
        self.thumbnailLoader = thumbnailLoader
        self.onSelectSlot = onSelectSlot
        self.onLoadMore = onLoadMore
    }

    private var highlightedStart: Int64? {
        summaries.lazy.compactMap {
            DaySummaryLayout.highlightedSlotStartMs(playheadMs: playheadMs, slots: $0.slots)
        }.first
    }

    private var dayCountLabel: String {
        let count = summaries.count
        return count == 1 ? "1 DAY" : "\(count) DAYS"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if summaries.isEmpty {
                emptyState
            } else {
                historyList
            }
        }
        .modifier(DaySummaryPanelChrome(style: style))
        .accessibilityIdentifier("history-summary-panel")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("HISTORY")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(RecallPalette.ray.opacity(0.78))
                Text("Summaries")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            Spacer(minLength: 8)
            if !summaries.isEmpty {
                Text(dayCountLabel)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.38))
            }
            if let onPopOut {
                Button(action: onPopOut) {
                    Image(systemName: "macwindow.on.rectangle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open as a window")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing recorded yet.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.74))
            Text("Your past days will appear here as AfterRay captures them.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.42))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: style == .window) {
                // Pinned headers: while a day's rows scroll, its date stays
                // put at the top of the list — the reader always knows which
                // day they are inside.
                LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                    ForEach(summaries, id: \.dayStartMs) { summary in
                        DaySummarySection(
                            summary: summary,
                            playheadMs: playheadMs,
                            nowMs: nowMs,
                            thumbnailLoader: thumbnailLoader,
                            onSelectSlot: onSelectSlot
                        )
                        .id(summary.dayStartMs)
                    }
                    if hasMore {
                        HistorySummaryLoadTrigger(isLoading: isLoadingMore, onAppear: onLoadMore)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: style == .overlay ? RecallGeometry.daySummaryListMaxHeight : .infinity)
            .onAppear { scrollToCurrent(proxy) }
            .onChange(of: followPulse) { _, _ in
                scrollToCurrent(proxy)
            }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let highlightedStart else { return }
        // The user reading the panel outranks the playhead: yanking the list
        // to the highlighted slot mid-read is the jank being reported.
        if ScrollFenceRegistry.shared.pointerInsideAnyFence() { return }
        // LazyVStack cannot scroll to a row inside an unmaterialised day
        // section; target the section first so its rows exist, then the row.
        if let day = summaries.first(where: {
            DaySummaryLayout.highlightedSlotStartMs(playheadMs: playheadMs, slots: $0.slots) != nil
        }) {
            proxy.scrollTo(day.dayStartMs, anchor: .top)
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(highlightedStart, anchor: .center)
        }
    }
}

private struct DaySummarySection: View {
    let summary: DaySummary
    let playheadMs: Int64
    let nowMs: Int64
    let thumbnailLoader: RecallThumbnailLoader?
    let onSelectSlot: (Int64) -> Void

    private var heading: DaySummaryHeading {
        DaySummaryLayout.dateHeading(dayStartMs: summary.dayStartMs, nowMs: nowMs)
    }

    private var highlightedStart: Int64? {
        DaySummaryLayout.highlightedSlotStartMs(playheadMs: playheadMs, slots: summary.slots)
    }

    var body: some View {
        // A real Section: `pinnedViews: [.sectionHeaders]` can only pin a
        // Section's header, so the date stays visible while its rows scroll
        // beneath it. The header wears an opaque backdrop for exactly that
        // moment of overlap.
        Section {
            content
        } header: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(heading.kicker)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(1.25)
                    .foregroundStyle(heading.isToday ? RecallPalette.ray.opacity(0.85) : .white.opacity(0.45))
                Text(heading.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 8)
                Text("\(summary.slots.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.32))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(red: 0.055, green: 0.05, blue: 0.06).opacity(0.94))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 1) {
            if summary.slots.isEmpty {
                Text("No recordings")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.38))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
            } else {
                ForEach(DaySummaryLayout.displayOrder(summary.slots)) { slot in
                    DaySummaryRow(
                        slot: slot,
                        isCurrent: slot.slotStartMs == highlightedStart,
                        thumbnailLoader: thumbnailLoader,
                        onSelect: { onSelectSlot(slot.slotStartMs) }
                    )
                    .id(slot.slotStartMs)
                }
            }
        }
        .padding(.vertical, 2)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Overlay hosting wears the glass card; a real window supplies its own
/// chrome, so the panel just fills it.
private struct DaySummaryPanelChrome: ViewModifier {
    let style: DaySummaryPanelStyle

    func body(content: Content) -> some View {
        switch style {
        case .overlay:
            content
                .frame(width: RecallGeometry.daySummaryPanelWidth, alignment: .topLeading)
                .frame(maxHeight: RecallGeometry.daySummaryMaxHeight, alignment: .top)
                .recallGlass(in: .rounded(RecallGeometry.daySummaryCornerRadius))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: RecallGeometry.daySummaryCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
        case .window:
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(red: 0.045, green: 0.04, blue: 0.05))
        }
    }
}

private struct HistorySummaryLoadTrigger: View {
    let isLoading: Bool
    let onAppear: () -> Void

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(RecallPalette.ray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                Color.clear
                    .frame(height: 1)
                    .onAppear(perform: onAppear)
            }
        }
        .accessibilityLabel(isLoading ? "Loading older summaries" : "Load older summaries")
    }
}

private struct DaySummaryRow: View {
    let slot: DaySlotSummary
    let isCurrent: Bool
    let thumbnailLoader: RecallThumbnailLoader?
    let onSelect: () -> Void
    @State private var isHovering = false

    private var text: DaySummaryRowText {
        DaySummaryLayout.rowText(slot: slot)
    }

    var body: some View {
        Button(action: onSelect) {
            // Top-aligned, never baseline: an image's "baseline" is its
            // bottom edge, so baseline alignment shoved every thumbnail
            // above its own row and inflated the row height — the giant
            // inter-row voids in the before state were exactly that.
            HStack(alignment: .top, spacing: 10) {
                Text(text.time)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? RecallPalette.ray : .white.opacity(0.38))
                    .frame(width: 42, alignment: .leading)
                    .padding(.top, 2) // optically align with the title's cap height
                VStack(alignment: .leading, spacing: 4) {
                    Text(text.primary)
                        .font(.system(size: 12, weight: text.isT2 ? .medium : .regular))
                        .foregroundStyle(text.isT2 ? .white.opacity(0.92) : .white.opacity(0.56))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !text.detail.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(text.detail.enumerated()), id: \.offset) { _, line in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("·")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.3))
                                    Text(line)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.66))
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .padding(.top, 1)
                    }

                    // One metadata line: status and app icons are both
                    // "about this row", so they share a row instead of
                    // stacking — grouped by proximity, and the row stays
                    // short for unsummarised slots.
                    if text.badge != nil || !slot.facts.apps.isEmpty {
                        HStack(spacing: 8) {
                            if let badge = text.badge {
                                Text(badge)
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .foregroundStyle(badgeTint(badge).opacity(0.9))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(badgeTint(badge).opacity(0.14), in: Capsule())
                                    .accessibilityLabel("Summary status: \(badge)")
                            }
                            if !slot.facts.apps.isEmpty {
                                SlotAppIconStrip(apps: slot.facts.apps)
                            }
                        }
                        .padding(.top, 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let anchorMomentId = slot.anchorMomentId, let thumbnailLoader {
                    SlotAnchorThumbnail(
                        momentID: anchorMomentId,
                        loader: thumbnailLoader
                    )
                    .padding(.top, 1)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowFill)
            }
            .overlay(alignment: .leading) {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(RecallPalette.ray)
                        .frame(width: 2)
                        .padding(.vertical, 6)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { isHovering = $0 }
        .help(text.primary)
    }

    private func badgeTint(_ badge: String) -> Color {
        badge == "Summary failed" ? RecallPalette.ray : .white.opacity(0.5)
    }

    private var rowFill: Color {
        if isCurrent { return RecallPalette.ray.opacity(0.13) }
        if isHovering { return Color.white.opacity(0.05) }
        return .clear
    }
}

/// The slot's opening frame, so a row is recognisable at a glance rather
/// than only describable. Loads through the shared thumbnail cache; a slot
/// scrolled past twice costs one decode.
private struct SlotAnchorThumbnail: View {
    let momentID: String
    let loader: RecallThumbnailLoader
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.05)
            }
        }
        .frame(width: 56, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        }
        .task(id: momentID) {
            image = RecallThumbnailCache.shared.cached(momentID: momentID)
            if image == nil {
                image = await RecallThumbnailCache.shared.image(momentID: momentID, loader: loader)
            }
        }
    }
}

/// Every application the half hour touched, as icons in time order — the
/// fastest possible "what was going on here" read, under the prose.
private struct SlotAppIconStrip: View {
    let apps: [DayAppFact]
    private static let iconLimit = 8

    var body: some View {
        HStack(spacing: 4) {
            ForEach(apps.prefix(Self.iconLimit), id: \.name) { app in
                SlotAppIcon(app: app)
            }
            if apps.count > Self.iconLimit {
                Text("+\(apps.count - Self.iconLimit)")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .accessibilityLabel("Apps used: \(apps.map(\.name).joined(separator: ", "))")
    }
}

/// One icon, loaded off the main thread on first sight. A row scrolling in
/// must never pay Launch Services on the render loop. An app whose icon
/// cannot resolve (uninstalled since capture) collapses to nothing — an
/// empty placeholder square communicates only "something failed here".
private struct SlotAppIcon: View {
    let app: DayAppFact

    private enum Resolution: Equatable {
        case loading
        case loaded(NSImage)
        case absent
    }

    @State private var resolution = Resolution.loading

    var body: some View {
        switch resolution {
        case .loading:
            Color.clear
                .frame(width: 14, height: 14)
                .task(id: app.bundleIdentifier) { await resolve() }
        case .loaded(let icon):
            Image(nsImage: icon)
                .resizable()
                .interpolation(.medium)
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .help("\(app.name) · \(DaySummaryLayout.formatDuration(ms: app.ms))")
        case .absent:
            EmptyView()
        }
    }

    private func resolve() async {
        if let hit = AppIconLookup.cachedIcon(bundleIdentifier: app.bundleIdentifier) {
            resolution = .loaded(hit)
            return
        }
        if let icon = await AppIconLookup.iconAsync(bundleIdentifier: app.bundleIdentifier) {
            resolution = .loaded(icon)
        } else {
            resolution = .absent
        }
    }
}
