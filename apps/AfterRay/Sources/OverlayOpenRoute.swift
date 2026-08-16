import AfterRayRecall

enum OverlayOpenRoute: Equatable {
    case summary(DaySlotSummary)
    case selectedSearch
    case live

    static func resolve(summarySlot: DaySlotSummary?, hasSelectedSearch: Bool) -> Self {
        if let summarySlot { return .summary(summarySlot) }
        if hasSelectedSearch { return .selectedSearch }
        return .live
    }
}
