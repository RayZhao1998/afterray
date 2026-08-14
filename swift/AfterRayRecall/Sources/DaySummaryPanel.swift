import SwiftUI

struct DaySummaryPanel: View {
    let summary: DaySummary
    let playheadMs: Int64
    let nowMs: Int64
    let onSelectSlot: (Int64) -> Void

    private var highlightedStart: Int64? {
        DaySummaryLayout.highlightedSlotStartMs(playheadMs: playheadMs, slots: summary.slots)
    }

    private var heading: DaySummaryHeading {
        DaySummaryLayout.dateHeading(dayStartMs: summary.dayStartMs, nowMs: nowMs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if summary.slots.isEmpty {
                emptyState
            } else {
                slotList
            }
        }
        .frame(width: RecallGeometry.daySummaryPanelWidth, alignment: .topLeading)
        .frame(maxHeight: RecallGeometry.daySummaryMaxHeight, alignment: .top)
        .recallGlass(in: .rounded(RecallGeometry.daySummaryCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: RecallGeometry.daySummaryCornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(heading.kicker)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(1.6)
                    .foregroundStyle(RecallPalette.ray.opacity(0.78))
                Text(heading.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
            Spacer(minLength: 8)
            if !summary.slots.isEmpty {
                Text("\(summary.slots.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.38))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing recorded this day.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.74))
            Text("Drag the timeline to a day AfterRay was watching.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.42))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private var slotList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(summary.slots) { slot in
                        DaySummaryRow(
                            slot: slot,
                            isCurrent: slot.slotStartMs == highlightedStart,
                            onSelect: { onSelectSlot(slot.slotStartMs) }
                        )
                        .id(slot.slotStartMs)
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: RecallGeometry.daySummaryListMaxHeight)
            .onAppear { scrollToCurrent(proxy) }
            .onChange(of: highlightedStart) { _, _ in
                scrollToCurrent(proxy)
            }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let highlightedStart else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(highlightedStart, anchor: .center)
        }
    }
}

private struct DaySummaryRow: View {
    let slot: DaySlotSummary
    let isCurrent: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    private var text: DaySummaryRowText {
        DaySummaryLayout.rowText(slot: slot)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(text.time)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isCurrent ? RecallPalette.ray : .white.opacity(0.38))
                    .frame(width: 42, alignment: .leading)
                Text(text.primary)
                    .font(.system(size: 12, weight: text.isT2 ? .medium : .regular))
                    .foregroundStyle(text.isT2 ? .white.opacity(0.92) : .white.opacity(0.56))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    private var rowFill: Color {
        if isCurrent { return RecallPalette.ray.opacity(0.13) }
        if isHovering { return Color.white.opacity(0.05) }
        return .clear
    }
}
