import XCTest
@testable import AfterRayRecall

/// The document builder is the selection fix: one attributed string, so a
/// selection can run across bullets, rows and days. These tests pin the
/// structure the hosting `NSTextView` relies on — ranges, links, order —
/// without ever creating a view.
final class DaySummaryDocumentTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let dayMs: Int64 = 86_400_000

    func testDocumentIsOneContinuousStringAcrossDays() {
        let (document, layout) = DaySummaryDocument.build(
            summaries: [day(start: dayMs, titles: ["afternoon", "morning"]), day(start: 0, titles: ["earlier"])],
            nowMs: dayMs * 2,
            timeZone: utc
        )
        let text = document.string
        XCTAssertTrue(text.contains("afternoon"))
        XCTAssertTrue(text.contains("earlier"))
        XCTAssertEqual(layout.dayRanges.count, 2)
        // Days render in the order given (newest first); the second day's
        // heading sits after the first day's slots in the same string.
        XCTAssertLessThan(
            layout.dayRanges[0].range.location,
            layout.dayRanges[1].range.location
        )
    }

    func testSlotsRenderNewestFirstWithinADay() {
        let (document, _) = DaySummaryDocument.build(
            summaries: [day(start: 0, titles: ["morning", "noon"])],
            nowMs: dayMs,
            timeZone: utc
        )
        let text = document.string
        // Slot helper assigns ascending start times in title order, so
        // "noon" (later) must appear before "morning" in a newest-first doc.
        let noon = text.range(of: "noon")!.lowerBound
        let morning = text.range(of: "morning")!.lowerBound
        XCTAssertLessThan(noon, morning)
    }

    func testSlotRangesCoverTheirTextAndCarryLinks() {
        let summary = day(start: 0, titles: ["only slot"], bullets: ["read the code", "wrote a fix"])
        let (document, layout) = DaySummaryDocument.build(
            summaries: [summary],
            nowMs: dayMs,
            timeZone: utc
        )
        let slotStart = summary.slots[0].slotStartMs
        let range = try! XCTUnwrap(layout.slotRanges[slotStart])
        let slotText = (document.string as NSString).substring(with: range)
        XCTAssertTrue(slotText.contains("only slot"))
        XCTAssertTrue(slotText.contains("· read the code"))
        XCTAssertTrue(slotText.contains("· wrote a fix"))

        // The time chip links to the slot so clicking it jumps the timeline.
        var foundLink = false
        document.enumerateAttribute(.link, in: range) { value, _, _ in
            if let url = value as? URL,
               DaySummaryDocument.slotStart(from: url) == slotStart
            {
                foundLink = true
            }
        }
        XCTAssertTrue(foundLink, "the slot's time chip must link to it")
    }

    func testLayoutLookupsResolveCharacterPositions() {
        let first = day(start: dayMs, titles: ["newest"])
        let second = day(start: 0, titles: ["older"])
        let (document, layout) = DaySummaryDocument.build(
            summaries: [first, second],
            nowMs: dayMs * 2,
            timeZone: utc
        )
        let olderStart = second.slots[0].slotStartMs
        let olderRange = try! XCTUnwrap(layout.slotRanges[olderStart])
        XCTAssertEqual(layout.slotStart(at: olderRange.location + 1), olderStart)
        XCTAssertEqual(layout.dayStart(at: olderRange.location + 1), 0)
        XCTAssertEqual(layout.dayStart(at: layout.dayRanges[0].range.location), dayMs)
        XCTAssertNil(layout.slotStart(at: document.length + 10))
    }

    func testFallbackRowsCarryTheirBadge() {
        let summary = DaySummary(
            day: "1970-01-01",
            dayStartMs: 0,
            dayEndMs: dayMs,
            slots: [
                DaySlotSummary(
                    slotStartMs: 0,
                    slotEndMs: DaySummaryLayout.slotDurationMs,
                    state: "failed",
                    facts: DaySlotFacts(apps: [DayAppFact(name: "Zed", ms: 600_000)])
                ),
            ]
        )
        let (document, _) = DaySummaryDocument.build(
            summaries: [summary],
            nowMs: dayMs,
            timeZone: utc
        )
        XCTAssertTrue(document.string.contains("(Summary failed)"))
    }

    func testThumbnailAttachmentRidesTheAnchorMoment() {
        let summary = DaySummary(
            day: "1970-01-01",
            dayStartMs: 0,
            dayEndMs: dayMs,
            slots: [
                DaySlotSummary(
                    slotStartMs: 0,
                    slotEndMs: DaySummaryLayout.slotDurationMs,
                    state: "done",
                    anchorMomentId: "moment-42",
                    facts: DaySlotFacts(apps: []),
                    title: "titled"
                ),
            ]
        )
        let (document, _) = DaySummaryDocument.build(
            summaries: [summary],
            nowMs: dayMs,
            timeZone: utc
        )
        var thumbnail: DaySummaryDocument.ThumbnailAttachment?
        document.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: document.length)
        ) { value, _, _ in
            if let found = value as? DaySummaryDocument.ThumbnailAttachment {
                thumbnail = found
            }
        }
        XCTAssertEqual(thumbnail?.momentID, "moment-42")
        XCTAssertEqual(thumbnail?.slotStartMs, 0)
    }

    func testSlotLinkRoundTrips() {
        let url = DaySummaryDocument.slotLink(startMs: 1_786_698_000_000)
        XCTAssertEqual(DaySummaryDocument.slotStart(from: url), 1_786_698_000_000)
        XCTAssertNil(DaySummaryDocument.slotStart(from: URL(string: "https://example.com")!))
    }

    // ------------------------------------------------------------ helpers

    /// A day whose slots take ascending start times in `titles` order, so a
    /// test can reason about which title is "later".
    private func day(start: Int64, titles: [String], bullets: [String] = []) -> DaySummary {
        let slots = titles.enumerated().map { index, title in
            DaySlotSummary(
                slotStartMs: start + Int64(index) * DaySummaryLayout.slotDurationMs,
                slotEndMs: start + Int64(index + 1) * DaySummaryLayout.slotDurationMs,
                state: "done",
                facts: DaySlotFacts(apps: [DayAppFact(name: "Zed", ms: 600_000)], momentCount: 3),
                title: title,
                bullets: bullets
            )
        }
        return DaySummary(
            day: DaySummaryLayout.localDayKey(ms: start, timeZone: utc),
            dayStartMs: start,
            dayEndMs: start + dayMs,
            slots: slots
        )
    }
}
