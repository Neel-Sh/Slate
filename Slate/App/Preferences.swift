import Foundation
import Observation

nonisolated enum SwipeAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, toggleRead, archive, later, trash, star
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .toggleRead: "Read / Unread"
        case .archive: "Archive"
        case .later: "Later"
        case .trash: "Move to Trash"
        case .star: "Star"
        }
    }
}

nonisolated enum RemoteImagePolicy: String, CaseIterable, Identifiable, Sendable {
    case ask, always
    var id: String { rawValue }
    var title: String { self == .ask ? "Ask for Each Message" : "Always Load" }
}

/// User preferences stored in UserDefaults. Nothing here is secret.
@MainActor @Observable
final class Preferences {
    private let defaults: UserDefaults

    var undoSendSeconds: Int { didSet { defaults.set(undoSendSeconds, forKey: "undoSendSeconds") } }
    var defaultAccountID: String? { didSet { defaults.set(defaultAccountID, forKey: "defaultAccountID") } }
    var morningHour: Int { didSet { defaults.set(morningHour, forKey: "morningHour") } }
    var morningMinute: Int { didSet { defaults.set(morningMinute, forKey: "morningMinute") } }
    var leadingSwipe: SwipeAction { didSet { defaults.set(leadingSwipe.rawValue, forKey: "leadingSwipe") } }
    var trailingSwipe: SwipeAction { didSet { defaults.set(trailingSwipe.rawValue, forKey: "trailingSwipe") } }
    var trailingSwipeSecondary: SwipeAction { didSet { defaults.set(trailingSwipeSecondary.rawValue, forKey: "trailingSwipe2") } }
    var previewPrivacy: PreviewPrivacy { didSet { defaults.set(previewPrivacy.rawValue, forKey: "previewPrivacy") } }
    var remoteImages: RemoteImagePolicy { didSet { defaults.set(remoteImages.rawValue, forKey: "remoteImages") } }
    var showFocused: Bool { didSet { defaults.set(showFocused, forKey: "showFocused") } }
    var rememberSearches: Bool { didSet { defaults.set(rememberSearches, forKey: "rememberSearches"); if !rememberSearches { recentSearches = [] } } }
    var recentSearches: [String] { didSet { defaults.set(recentSearches, forKey: "recentSearches") } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: "onboarded") } }

    static let undoChoices = [5, 10, 20, 30]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let undo = defaults.integer(forKey: "undoSendSeconds")
        undoSendSeconds = Self.undoChoices.contains(undo) ? undo : 10
        defaultAccountID = defaults.string(forKey: "defaultAccountID")
        morningHour = defaults.object(forKey: "morningHour") as? Int ?? 8
        morningMinute = defaults.object(forKey: "morningMinute") as? Int ?? 0
        leadingSwipe = SwipeAction(rawValue: defaults.string(forKey: "leadingSwipe") ?? "") ?? .toggleRead
        trailingSwipe = SwipeAction(rawValue: defaults.string(forKey: "trailingSwipe") ?? "") ?? .archive
        trailingSwipeSecondary = SwipeAction(rawValue: defaults.string(forKey: "trailingSwipe2") ?? "") ?? .later
        previewPrivacy = PreviewPrivacy(rawValue: defaults.string(forKey: "previewPrivacy") ?? "") ?? .senderAndSubject
        remoteImages = RemoteImagePolicy(rawValue: defaults.string(forKey: "remoteImages") ?? "") ?? .ask
        // All until the user chooses Focused; the choice is then remembered.
        showFocused = defaults.bool(forKey: "showFocused")
        rememberSearches = defaults.object(forKey: "rememberSearches") as? Bool ?? true
        recentSearches = defaults.stringArray(forKey: "recentSearches") ?? []
        hasCompletedOnboarding = defaults.bool(forKey: "onboarded")
    }

    var morning: DateComponents { DateComponents(hour: morningHour, minute: morningMinute) }

    func remember(search: String) {
        let s = search.trimmingCharacters(in: .whitespaces)
        guard rememberSearches, !s.isEmpty else { return }
        recentSearches = Array(([s] + recentSearches.filter { $0 != s }).prefix(8))
    }
}
