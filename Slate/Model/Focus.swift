import Foundation

/// Transparent, correctable Focused classification. It never hides or archives mail; All always shows everything.
nonisolated struct FocusClassifier: Sendable {
    /// address → "always" | "never"
    var senderRules: [String: String]
    /// "accountID|address" pairs the user has written to.
    var correspondents: Set<String>
    var identities: Set<String>

    func reason(for t: ThreadSummary) -> FocusReason? {
        let sender = t.latestFrom?.normalized ?? ""
        if let rule = senderRules[sender] { return rule == "always" ? .vip : nil }
        if identities.contains(sender) { return nil }
        let promotional = t.labelIDs.contains { $0.hasPrefix(SystemLabel.categoryPrefix) && $0 != "CATEGORY_PERSONAL" }
        if t.isImportant && !promotional && !t.isMailingList { return .important }
        if correspondents.contains(t.ref.accountID + "|" + sender) && !t.isMailingList { return .repliedBefore }
        if t.toMe && !t.isMailingList && !promotional && !looksAutomated(sender) { return .directCorrespondent }
        return nil
    }

    private func looksAutomated(_ address: String) -> Bool {
        let local = address.split(separator: "@").first.map(String.init) ?? ""
        return ["noreply", "no-reply", "donotreply", "notifications", "notification", "mailer", "billing", "itinerary", "updates", "news"]
            .contains { local.contains($0) }
    }
}

nonisolated enum LaterPreset: String, CaseIterable, Identifiable, Sendable {
    case laterToday, tomorrowMorning, nextWeek
    var id: String { rawValue }
    var title: String {
        switch self {
        case .laterToday: "Later Today"
        case .tomorrowMorning: "Tomorrow Morning"
        case .nextWeek: "Next Week"
        }
    }
    var symbol: String {
        switch self {
        case .laterToday: "clock"
        case .tomorrowMorning: "sunrise"
        case .nextWeek: "calendar"
        }
    }

    /// - Parameter morning: user-configured morning time (hour, minute).
    func date(from now: Date, morning: DateComponents, calendar: Calendar = .current) -> Date? {
        func atMorning(_ day: Date) -> Date {
            calendar.date(bySettingHour: morning.hour ?? 8, minute: morning.minute ?? 0, second: 0, of: day) ?? day
        }
        switch self {
        case .laterToday:
            let candidate = now.addingTimeInterval(3 * 3600)
            let rounded = calendar.date(bySetting: .minute, value: 0, of: candidate) ?? candidate
            let target = rounded < candidate ? rounded.addingTimeInterval(3600) : rounded
            // Not offered once "later today" would cross into tomorrow.
            return calendar.isDate(target, inSameDayAs: now) ? target : nil
        case .tomorrowMorning:
            return atMorning(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!)
        case .nextWeek:
            let start = calendar.startOfDay(for: now)
            let weekday = calendar.component(.weekday, from: start)
            let firstWeekday = calendar.firstWeekday == 1 ? 2 : calendar.firstWeekday // prefer Monday
            var delta = (firstWeekday - weekday + 7) % 7
            if delta == 0 { delta = 7 }
            return atMorning(calendar.date(byAdding: .day, value: delta, to: start)!)
        }
    }
}

nonisolated enum DateGrouping {
    enum Group: Hashable, Comparable {
        case today, yesterday, thisWeek, earlier(month: Date)
        static func < (a: Group, b: Group) -> Bool { a.rank < b.rank || (a.rank == b.rank && a.monthDate > b.monthDate) }
        private var rank: Int { switch self { case .today: 0; case .yesterday: 1; case .thisWeek: 2; case .earlier: 3 } }
        private var monthDate: Date { if case .earlier(let d) = self { return d }; return .distantFuture }

        var title: String {
            switch self {
            case .today: "Today"
            case .yesterday: "Yesterday"
            case .thisWeek: "Earlier This Week"
            case .earlier(let d):
                Calendar.current.isDate(d, equalTo: .now, toGranularity: .year)
                    ? d.formatted(.dateTime.month(.wide)) : d.formatted(.dateTime.month(.wide).year())
            }
        }
    }

    static func group(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Group {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return .yesterday }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekAgo { return .thisWeek }
        let month = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        return .earlier(month: month)
    }

    static func rowTime(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday" }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekAgo {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.month(.abbreviated).day()) }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
