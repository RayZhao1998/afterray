import AppKit
import Foundation

/// The history panel's content as one attributed document.
///
/// Cross-row text selection is why this exists: SwiftUI's `.textSelection`
/// is scoped to a single `Text` view, so a list of views can never extend a
/// selection across a bullet, a row, or a day. One `NSTextView` over one
/// backing store gives document-grade selection; app icons ride along as
/// text attachments, and the time chips become links.
///
/// The layout is a timeline: times sit in a left gutter, a continuous rule
/// runs down `spineX`, and every piece of prose — day heading, title,
/// bullets, status — starts on the single edge at `textX`, wrapped lines
/// included. One alignment edge is the whole point; a wrapped title that
/// jumps left of its own first line is what this replaced.
public enum DaySummaryDocument {
    /// Link scheme for jump affordances inside the document. The URL host
    /// carries the slot start in milliseconds.
    public static let slotLinkScheme = "afterray-slot"

    /// Where the timeline rule is drawn, in text-container coordinates.
    public static let spineX: CGFloat = 44
    /// The single left edge every line of prose starts on.
    public static let textX: CGFloat = 56
    /// Bullet bodies hang one step further in; their marker sits on `textX`.
    public static let bulletTextX: CGFloat = 68

    public static func slotLink(startMs: Int64) -> URL {
        URL(string: "\(slotLinkScheme)://\(startMs)")!
    }

    public static func slotStart(from url: URL) -> Int64? {
        guard url.scheme == slotLinkScheme else { return nil }
        return url.host.flatMap(Int64.init)
    }

    /// Where each piece of the document landed, for scroll-follow, the
    /// current-slot marker, and the structured copy commands.
    public struct Layout {
        public var slotRanges: [Int64: NSRange] = [:]
        /// Just the time chip of each slot, so the current one can be tinted
        /// without repainting a whole paragraph.
        public var timeRanges: [Int64: NSRange] = [:]
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
            let isFirstDay = layout.dayRanges.isEmpty
            let heading = DaySummaryLayout.dateHeading(dayStartMs: summary.dayStartMs, nowMs: nowMs)
            // Title case, never shouted: an all-caps run reads as an alarm
            // and is what the eye trips over in a dense list.
            let headingText = "\(heading.kicker.capitalized) · \(heading.title)"
            let headingStart = text.length
            text.append(NSAttributedString(
                string: headingText + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: heading.isToday
                        ? NSColor(red: 1, green: 0.34, blue: 0.25, alpha: 0.92)
                        : NSColor.white.withAlphaComponent(0.55),
                    .paragraphStyle: isFirstDay ? firstHeadingParagraph : headingParagraph,
                ]
            ))
            layout.dayRanges.append((
                summary.dayStartMs,
                headingText,
                NSRange(location: headingStart, length: text.length - headingStart)
            ))

            for slot in DaySummaryLayout.displayOrder(summary.slots) {
                let slotStart = text.length
                let timeRange = appendSlot(slot, to: text, timeZone: timeZone)
                layout.timeRanges[slot.slotStartMs] = timeRange
                layout.slotRanges[slot.slotStartMs] = NSRange(
                    location: slotStart,
                    length: text.length - slotStart
                )
            }
        }
        return (text, layout)
    }

    /// Appends one half hour and returns the range of its time chip.
    @discardableResult
    private static func appendSlot(
        _ slot: DaySlotSummary,
        to text: NSMutableAttributedString,
        timeZone: TimeZone
    ) -> NSRange {
        let row = DaySummaryLayout.rowText(slot: slot, timeZone: timeZone)

        // Time chip: the deliberate jump affordance, so it links. Monospaced
        // digits make every chip the same width, so the gutter is a column.
        let timeStart = text.length
        text.append(NSAttributedString(
            string: row.time,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.4),
                .link: slotLink(startMs: slot.slotStartMs),
                .paragraphStyle: titleParagraph,
            ]
        ))
        let timeRange = NSRange(location: timeStart, length: text.length - timeStart)

        text.append(NSAttributedString(string: "\t", attributes: [.paragraphStyle: titleParagraph]))
        text.append(NSAttributedString(
            string: row.primary + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: row.isT2 ? .semibold : .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(row.isT2 ? 0.92 : 0.58),
                .paragraphStyle: titleParagraph,
            ]
        ))

        for detail in row.detail {
            text.append(NSAttributedString(
                string: "·\t",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.34),
                    .paragraphStyle: bulletParagraph,
                ]
            ))
            text.append(NSAttributedString(
                string: detail + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.68),
                    .paragraphStyle: bulletParagraph,
                ]
            ))
        }

        // Status gets its own line. Sharing one with the icons made a row of
        // mixed sizes that aligned to nothing.
        if let badge = row.badge {
            text.append(NSAttributedString(
                string: badge + "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: badge == "Summary failed"
                        ? NSColor(red: 1, green: 0.34, blue: 0.25, alpha: 0.85)
                        : NSColor.white.withAlphaComponent(0.35),
                    .paragraphStyle: metaParagraph,
                ]
            ))
        }

        if !slot.facts.apps.isEmpty {
            let icons = NSMutableAttributedString()
            for app in slot.facts.apps.prefix(8) {
                let icon = NSMutableAttributedString(
                    attachment: AppIconAttachment(bundleIdentifier: app.bundleIdentifier)
                )
                icon.addAttribute(
                    .toolTip,
                    value: "\(app.name) · \(DaySummaryLayout.formatDuration(ms: app.ms))",
                    range: NSRange(location: 0, length: icon.length)
                )
                icons.append(icon)
                // The gap is kerning on a hairline font, not a space in a
                // readable one: the icons set the line's height, so if every
                // one of them collapses (all apps uninstalled since capture)
                // the line closes up instead of leaving a blank strip.
                icons.append(NSAttributedString(
                    string: " ",
                    attributes: [.font: NSFont.systemFont(ofSize: 1), .kern: 5]
                ))
            }
            icons.append(NSAttributedString(
                string: "\n",
                attributes: [.font: NSFont.systemFont(ofSize: 1)]
            ))
            icons.addAttribute(
                .paragraphStyle,
                value: metaParagraph,
                range: NSRange(location: 0, length: icons.length)
            )
            text.append(icons)
        }

        return timeRange
    }

    // ---------------------------------------------------------- paragraphs

    /// Everything hangs off `textX`; the tab interval repeats it so a chip
    /// that ever outgrows the gutter still lands on a known edge instead of
    /// pushing its line an arbitrary distance right.
    private static func indented(
        firstLine: CGFloat,
        wrap: CGFloat,
        tab: CGFloat
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = firstLine
        style.headIndent = wrap
        style.tabStops = [NSTextTab(textAlignment: .left, location: tab)]
        style.defaultTabInterval = tab
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private static let headingParagraph: NSParagraphStyle = {
        let style = indented(firstLine: textX, wrap: textX, tab: textX)
        // A day break is the largest gap in the document: space alone marks
        // the section, no rule needed.
        style.paragraphSpacingBefore = 24
        style.paragraphSpacing = 4
        return style
    }()

    /// The first day opens the document, so it separates nothing; its space
    /// comes from the text container's inset instead.
    private static let firstHeadingParagraph: NSParagraphStyle = {
        let style = indented(firstLine: textX, wrap: textX, tab: textX)
        style.paragraphSpacing = 4
        return style
    }()

    private static let titleParagraph: NSParagraphStyle = {
        let style = indented(firstLine: 0, wrap: textX, tab: textX)
        style.paragraphSpacingBefore = 14
        style.paragraphSpacing = 3
        style.lineSpacing = 1
        return style
    }()

    private static let bulletParagraph: NSParagraphStyle = {
        let style = indented(firstLine: textX, wrap: bulletTextX, tab: bulletTextX)
        style.paragraphSpacing = 3
        style.lineSpacing = 1
        return style
    }()

    private static let metaParagraph: NSParagraphStyle = {
        let style = indented(firstLine: textX, wrap: textX, tab: textX)
        style.paragraphSpacingBefore = 2
        style.paragraphSpacing = 1
        return style
    }()
}
