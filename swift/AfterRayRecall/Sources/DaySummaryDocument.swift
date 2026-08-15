import AppKit
import Foundation

/// The history panel's content as one attributed document.
///
/// Cross-row text selection is why this exists: SwiftUI's `.textSelection`
/// is scoped to a single `Text` view, so a list of views can never extend a
/// selection across a bullet, a row, or a day. One `NSTextView` over one
/// backing store gives document-grade selection; app icons ride along as
/// text attachments, and the time chips become links.
public enum DaySummaryDocument {
    /// Link scheme for jump affordances inside the document. The URL host
    /// carries the slot start in milliseconds.
    public static let slotLinkScheme = "afterray-slot"

    public static func slotLink(startMs: Int64) -> URL {
        URL(string: "\(slotLinkScheme)://\(startMs)")!
    }

    public static func slotStart(from url: URL) -> Int64? {
        guard url.scheme == slotLinkScheme else { return nil }
        return url.host.flatMap(Int64.init)
    }

    /// Where each piece of the document landed, for scroll-follow and the
    /// current-slot highlight.
    public struct Layout {
        public var slotRanges: [Int64: NSRange] = [:]
        /// Ascending by position: (dayStartMs, heading text, range).
        public var dayRanges: [(dayStartMs: Int64, heading: String, range: NSRange)] = []

        public init() {}

        /// The slot whose text contains this character position.
        public func slotStart(at characterIndex: Int) -> Int64? {
            slotRanges.first { NSLocationInRange(characterIndex, $0.value) }?.key
        }

        /// The day this character position falls inside: the last heading at
        /// or above it, since a day's rows run until the next heading.
        public func dayStart(at characterIndex: Int) -> Int64? {
            dayRanges.last { $0.range.location <= characterIndex }?.dayStartMs
        }
    }

    /// Attachment for one application icon in a slot's metadata line.
    public final class AppIconAttachment: NSTextAttachment {
        public let bundleIdentifier: String?

        public init(bundleIdentifier: String?) {
            self.bundleIdentifier = bundleIdentifier
            super.init(data: nil, ofType: nil)
            bounds = CGRect(x: 0, y: -3, width: 14, height: 14)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) { nil }
    }

    // ------------------------------------------------------------ builder

    public static func build(
        summaries: [DaySummary],
        nowMs: Int64,
        timeZone: TimeZone = .current
    ) -> (document: NSAttributedString, layout: Layout) {
        let text = NSMutableAttributedString()
        var layout = Layout()

        for summary in summaries {
            let heading = DaySummaryLayout.dateHeading(dayStartMs: summary.dayStartMs, nowMs: nowMs)
            let headingText = "\(heading.kicker) · \(heading.title)"
            let headingStart = text.length
            text.append(NSAttributedString(
                string: headingText + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: heading.isToday
                        ? NSColor(red: 1, green: 0.34, blue: 0.25, alpha: 0.9)
                        : NSColor.white.withAlphaComponent(0.5),
                    .kern: 1.1,
                    .paragraphStyle: headingParagraph,
                ]
            ))
            layout.dayRanges.append((
                summary.dayStartMs,
                headingText,
                NSRange(location: headingStart, length: text.length - headingStart)
            ))

            for slot in DaySummaryLayout.displayOrder(summary.slots) {
                let slotStart = text.length
                appendSlot(slot, to: text, timeZone: timeZone)
                layout.slotRanges[slot.slotStartMs] = NSRange(
                    location: slotStart,
                    length: text.length - slotStart
                )
            }
        }
        return (text, layout)
    }

    private static func appendSlot(
        _ slot: DaySlotSummary,
        to text: NSMutableAttributedString,
        timeZone: TimeZone
    ) {
        let row = DaySummaryLayout.rowText(slot: slot, timeZone: timeZone)

        // Time chip: the deliberate jump affordance, so it links. The tab
        // lands the title exactly on the 46pt edge that bullets and the
        // metadata line share — one alignment edge for the whole row.
        text.append(NSAttributedString(
            string: row.time,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.42),
                .link: slotLink(startMs: slot.slotStartMs),
                .paragraphStyle: titleParagraph,
            ]
        ))
        text.append(NSAttributedString(string: "\t", attributes: [.paragraphStyle: titleParagraph]))

        text.append(NSAttributedString(
            string: row.primary,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: row.isT2 ? .medium : .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(row.isT2 ? 0.92 : 0.56),
                .paragraphStyle: titleParagraph,
            ]
        ))

        text.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: titleParagraph]))

        for detail in row.detail {
            text.append(NSAttributedString(
                string: "·\t\(detail)\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.66),
                    .paragraphStyle: bulletParagraph,
                ]
            ))
        }

        if row.badge != nil || !slot.facts.apps.isEmpty {
            let meta = NSMutableAttributedString()
            if let badge = row.badge {
                // Uppercase micro-label, styled like the day kicker: status
                // is metadata about the row, not a parenthetical sentence.
                meta.append(NSAttributedString(
                    string: badge.uppercased() + "   ",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 8.5, weight: .semibold),
                        .kern: 0.8,
                        .foregroundColor: badge == "Summary failed"
                            ? NSColor(red: 1, green: 0.34, blue: 0.25, alpha: 0.85)
                            : NSColor.white.withAlphaComponent(0.32),
                    ]
                ))
            }
            for app in slot.facts.apps.prefix(8) {
                let icon = NSMutableAttributedString(
                    attachment: AppIconAttachment(bundleIdentifier: app.bundleIdentifier)
                )
                icon.addAttribute(
                    .toolTip,
                    value: "\(app.name) · \(DaySummaryLayout.formatDuration(ms: app.ms))",
                    range: NSRange(location: 0, length: icon.length)
                )
                meta.append(icon)
                // Small font on the separators keeps the line thin if every
                // icon collapses (all apps uninstalled since capture).
                meta.append(NSAttributedString(
                    string: " ",
                    attributes: [.font: NSFont.systemFont(ofSize: 9.5)]
                ))
            }
            meta.addAttribute(
                .paragraphStyle,
                value: metaParagraph,
                range: NSRange(location: 0, length: meta.length)
            )
            meta.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: metaParagraph]))
            text.append(meta)
        }
    }

    // ---------------------------------------------------------- paragraphs

    private static let headingParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 14
        style.paragraphSpacing = 6
        return style
    }()

    private static let titleParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 9
        style.paragraphSpacing = 1
        style.headIndent = 46
        style.tabStops = [NSTextTab(textAlignment: .left, location: 46)]
        style.lineBreakMode = .byWordWrapping
        return style
    }()

    private static let bulletParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 46
        style.headIndent = 56
        style.tabStops = [NSTextTab(textAlignment: .left, location: 56)]
        style.paragraphSpacing = 1
        return style
    }()

    private static let metaParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 46
        style.headIndent = 46
        style.paragraphSpacing = 2
        return style
    }()
}
