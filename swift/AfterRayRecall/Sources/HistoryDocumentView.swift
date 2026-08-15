import AppKit
import SwiftUI

/// The text view that draws the timeline rule behind the document.
///
/// The spine has to be drawn rather than typeset: a continuous line down a
/// scrolling document is not something a text run can be, and a per-row
/// border would break at every paragraph — the seams are exactly what the
/// eye reads as "misaligned".
final class HistoryTextView: NSTextView {
    /// The current half hour's extent in view coordinates, lit on the spine
    /// instead of washing the row in a background colour.
    var highlightRect: NSRect?

    override func draw(_ dirtyRect: NSRect) {
        let x = (textContainerInset.width + DaySummaryDocument.spineX).rounded()
        NSColor.white.withAlphaComponent(0.09).setFill()
        NSRect(x: x, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()

        if let highlightRect, highlightRect.intersects(dirtyRect) {
            let ray = NSColor(red: 1, green: 0.34, blue: 0.25, alpha: 1)
            ray.setFill()
            NSRect(
                x: x,
                y: highlightRect.minY,
                width: 2,
                height: highlightRect.height
            ).fill()
            // A dot at the top of the lit segment: the playhead's position on
            // the timeline, readable at a glance from across the panel.
            let dot = NSRect(x: x - 2.5, y: highlightRect.minY + 4, width: 7, height: 7)
            NSBezierPath(ovalIn: dot).fill()
        }

        super.draw(dirtyRect)
    }
}

/// Hosts the history document in an `NSTextView`: document-grade selection
/// across bullets, rows and days — the thing a stack of SwiftUI `Text`
/// views structurally cannot do. Non-editable, dark, link clicks jump the
/// timeline, app icons fill in asynchronously.
struct HistoryDocumentView: NSViewRepresentable {
    let summaries: [DaySummary]
    let playheadMs: Int64
    let nowMs: Int64
    let hasMore: Bool
    let isLoadingMore: Bool
    let followPulse: Int
    /// A window fills whatever height it is given, so the timeline rule runs
    /// the full panel; the overlay card hugs its content instead of
    /// stretching a glass panel around two rows.
    let fillsHeight: Bool
    let onSelectSlot: (Int64) -> Void
    let onLoadMore: () -> Void
    /// Reports the heading of the topmost visible day as the user scrolls,
    /// for the pinned-date chip the document flow cannot pin itself.
    let onTopDayChange: (String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(view: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = HistoryTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 14)
        // The time chips are links, but tinting every one of them would put a
        // column of coloured text down the panel; the document already gives
        // them their colour, and only the current one is meant to stand out.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.delegate = context.coordinator
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true

        context.coordinator.attach(textView: textView, scroll: scroll)
        context.coordinator.apply(view: self)
        return scroll
    }

    func updateNSView(_: NSScrollView, context: Context) {
        context.coordinator.apply(view: self)
    }

    /// A scroll view has no intrinsic size, so without this the overlay
    /// panel always stretches to its max height even around two rows of
    /// content. Hug the document until it genuinely needs to scroll.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSScrollView,
        context _: Context
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite,
              let textView = nsView.documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return nil }
        if fillsHeight, let height = proposal.height, height.isFinite {
            return CGSize(width: width, height: height)
        }
        layoutManager.ensureLayout(for: container)
        let content = layoutManager.usedRect(for: container).height
            + textView.textContainerInset.height * 2
        var size = CGSize(width: width, height: content)
        if let maxHeight = proposal.height, maxHeight.isFinite {
            size.height = min(size.height, maxHeight)
        }
        return size
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private var view: HistoryDocumentView
        private weak var textView: HistoryTextView?
        private weak var scroll: NSScrollView?
        private var frameObserver: NSObjectProtocol?
        private var layout = DaySummaryDocument.Layout()
        private var renderedSummaries: [DaySummary] = []
        private var renderedNowKey: Int64 = 0
        private var lastFollowPulse = 0
        private var highlightedSlot: Int64?
        private var boundsObserver: NSObjectProtocol?
        private var loadingAttachments: Set<ObjectIdentifier> = []
        /// One load-more request per document build: bounds-change fires on
        /// every scrolled point near the bottom, and the store's isLoading
        /// flag round-trips through SwiftUI too slowly to gate that alone.
        private var requestedLoadMore = false

        init(view: HistoryDocumentView) {
            self.view = view
        }

        func attach(textView: HistoryTextView, scroll: NSScrollView) {
            self.textView = textView
            self.scroll = scroll
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scrolled()
                }
            }
            // A width change rewraps every paragraph, so the measured extent
            // of the current half hour moves with it.
            textView.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: textView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshHighlight(force: true)
                }
            }
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
        }

        func apply(view newView: HistoryDocumentView) {
            let summariesChanged = renderedSummaries != newView.summaries
            let followRequested = newView.followPulse != lastFollowPulse
            let playheadChanged = view.playheadMs != newView.playheadMs
            view = newView

            if summariesChanged {
                rebuild()
            }
            if playheadChanged || summariesChanged {
                refreshHighlight()
            }
            if followRequested {
                lastFollowPulse = newView.followPulse
                followPlayhead()
            }
        }

        // ------------------------------------------------------ document

        private func rebuild() {
            guard let textView else { return }
            renderedSummaries = view.summaries
            // Day headings depend on "today"; key the rebuild so a rollover
            // refreshes labels without rebuilding on every millisecond tick.
            renderedNowKey = view.nowMs / 60_000
            let built = DaySummaryDocument.build(summaries: view.summaries, nowMs: view.nowMs)
            layout = built.layout
            let selected = textView.selectedRanges
            textView.textStorage?.setAttributedString(built.document)
            // Restore what selection survives the new length; losing the
            // selection on a background refresh is how copies get eaten.
            let length = built.document.length
            let surviving = selected
                .map(\.rangeValue)
                .filter { NSMaxRange($0) <= length }
            if !surviving.isEmpty {
                textView.selectedRanges = surviving.map { NSValue(range: $0) }
            }
            highlightedSlot = nil
            requestedLoadMore = false
            refreshHighlight()
            fillAttachments()
            scrolled()
        }

        private func refreshHighlight(force: Bool = false) {
            guard let textView, let layoutManager = textView.layoutManager else { return }
            let current = view.summaries.lazy.compactMap {
                DaySummaryLayout.highlightedSlotStartMs(playheadMs: self.view.playheadMs, slots: $0.slots)
            }.first
            guard force || current != highlightedSlot else { return }
            if let previous = highlightedSlot, let range = layout.timeRanges[previous] {
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            }
            if let current, let range = layout.timeRanges[current] {
                layoutManager.addTemporaryAttribute(
                    .foregroundColor,
                    value: NSColor(red: 1, green: 0.34, blue: 0.25, alpha: 1),
                    forCharacterRange: range
                )
            }
            highlightedSlot = current
            textView.highlightRect = current.flatMap { boundingRect(ofSlot: $0) }
            textView.needsDisplay = true
        }

        /// The slot's extent in view coordinates, for the lit spine segment.
        private func boundingRect(ofSlot slotStartMs: Int64) -> NSRect? {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer,
                  let range = layout.slotRanges[slotStartMs]
            else { return nil }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            let origin = textView.textContainerOrigin
            return rect.offsetBy(dx: origin.x, dy: origin.y)
        }

        private func followPlayhead() {
            guard let textView,
                  !ScrollFenceRegistry.shared.pointerInsideAnyFence(),
                  let current = highlightedSlot ?? view.summaries.lazy.compactMap({
                      DaySummaryLayout.highlightedSlotStartMs(playheadMs: self.view.playheadMs, slots: $0.slots)
                  }).first,
                  let range = layout.slotRanges[current]
            else { return }
            textView.scrollRangeToVisible(range)
        }

        // ---------------------------------------------------- attachments

        private func fillAttachments() {
            guard let textView, let storage = textView.textStorage else { return }
            storage.enumerateAttribute(
                .attachment,
                in: NSRange(location: 0, length: storage.length)
            ) { value, range, _ in
                if let icon = value as? DaySummaryDocument.AppIconAttachment {
                    fill(icon: icon, at: range)
                }
            }
        }

        private func fill(icon: DaySummaryDocument.AppIconAttachment, at range: NSRange) {
            if let cached = AppIconLookup.cachedIcon(bundleIdentifier: icon.bundleIdentifier) {
                icon.image = cached
                return
            }
            let key = ObjectIdentifier(icon)
            guard !loadingAttachments.contains(key) else { return }
            loadingAttachments.insert(key)
            Task { @MainActor [weak self] in
                defer { self?.loadingAttachments.remove(key) }
                if let image = await AppIconLookup.iconAsync(
                    bundleIdentifier: icon.bundleIdentifier
                ) {
                    icon.image = image
                } else {
                    // Uninstalled app: collapse instead of holding an empty
                    // square — a blank box only says "something failed here".
                    icon.bounds = .zero
                }
                self?.invalidate(range: range)
            }
        }

        private func invalidate(range: NSRange) {
            guard let textView, let storage = textView.textStorage,
                  NSMaxRange(range) <= storage.length
            else { return }
            // Layout too, not just display: a collapsed attachment changes
            // the line's geometry, not only its pixels.
            textView.layoutManager?.invalidateLayout(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            textView.layoutManager?.invalidateDisplay(forCharacterRange: range)
            // Lines moved, so the lit spine segment has to be re-measured.
            refreshHighlight(force: true)
        }

        // -------------------------------------------------------- scroll

        /// Keeps the document at least as tall as the visible area, so the
        /// timeline rule it draws runs the full height of the panel rather
        /// than stopping where the last summary happens to end.
        private func syncMinimumHeight() {
            guard let textView, let scroll else { return }
            let visible = scroll.contentView.bounds.height
            guard visible > 0, textView.minSize.height != visible else { return }
            textView.minSize = NSSize(width: 0, height: visible)
            if textView.frame.height < visible {
                textView.setFrameSize(NSSize(width: textView.frame.width, height: visible))
            }
        }

        private func scrolled() {
            guard let textView, let scroll else { return }
            syncMinimumHeight()
            // Topmost visible character → its day heading, for the chip.
            if let layoutManager = textView.layoutManager,
               let container = textView.textContainer
            {
                let topPoint = CGPoint(
                    x: 4,
                    y: scroll.contentView.bounds.origin.y + 4
                )
                let glyph = layoutManager.glyphIndex(for: topPoint, in: container)
                let character = layoutManager.characterIndexForGlyph(at: glyph)
                let day = layout.dayRanges.last { $0.range.location <= character }
                // The chip stands in for the day's own heading, so it only
                // appears once that heading has scrolled off the top.
                let headingStillVisible = day.map { character < NSMaxRange($0.range) } ?? true
                view.onTopDayChange(headingStillVisible ? nil : day?.heading)
            }

            // Near the bottom with more history behind: pull the next page.
            let visibleBottom = scroll.contentView.bounds.maxY
            let documentHeight = textView.bounds.height
            if view.hasMore, !view.isLoadingMore, !requestedLoadMore,
               documentHeight - visibleBottom < 400
            {
                requestedLoadMore = true
                view.onLoadMore()
            }
        }

        // ------------------------------------------------------ delegate

        func textView(_: NSTextView, clickedOnLink link: Any, at _: Int) -> Bool {
            guard let url = link as? URL,
                  let slotStart = DaySummaryDocument.slotStart(from: url)
            else { return false }
            view.onSelectSlot(slotStart)
            return true
        }

        /// Native selection already gives arbitrary-range copy; these add the
        /// structured shortcuts (whole half hour, whole day) the row and
        /// section menus used to carry.
        func textView(
            _: NSTextView,
            menu: NSMenu,
            for _: NSEvent,
            at charIndex: Int
        ) -> NSMenu? {
            var inserted = 0
            if let slotStart = layout.slotStart(at: charIndex),
               let slot = view.summaries.lazy.flatMap(\.slots).first(where: { $0.slotStartMs == slotStart })
            {
                let item = NSMenuItem(
                    title: "Copy This Half Hour",
                    action: #selector(copySlotText(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = DaySummaryClipboard.slotText(slot)
                menu.insertItem(item, at: inserted)
                inserted += 1
            }
            if let dayStart = layout.dayStart(at: charIndex),
               let day = view.summaries.first(where: { $0.dayStartMs == dayStart })
            {
                let item = NSMenuItem(
                    title: "Copy This Day",
                    action: #selector(copySlotText(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = DaySummaryClipboard.dayText(day)
                menu.insertItem(item, at: inserted)
                inserted += 1
            }
            if inserted > 0 {
                menu.insertItem(.separator(), at: inserted)
            }
            return menu
        }

        @objc private func copySlotText(_ sender: NSMenuItem) {
            guard let text = sender.representedObject as? String else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
}
