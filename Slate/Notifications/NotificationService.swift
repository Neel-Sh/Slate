import Foundation
import UserNotifications
import UIKit

nonisolated enum PreviewPrivacy: String, CaseIterable, Identifiable, Codable, Sendable {
    case none, sender, senderAndSubject, full
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "Hidden"
        case .sender: "Sender Only"
        case .senderAndSubject: "Sender and Subject"
        case .full: "Sender, Subject and Preview"
        }
    }
}

/// Local alerts produced by Slate's own sync, Later reminders, and the app badge.
/// Alerts while Slate is not running require the push backend described in docs/NOTIFICATIONS.md.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var onOpen: ((URL) -> Void)?
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        center.delegate = self
        let open = UNNotificationAction(identifier: "open", title: "Open")
        center.setNotificationCategories([UNNotificationCategory(identifier: "mail", actions: [open], intentIdentifiers: [], options: [])])
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        await refreshAuthorization()
        return granted
    }

    func postNewMail(_ messages: [MailMessage], account: Account, privacy: PreviewPrivacy, multipleAccounts: Bool) async {
        guard authorization == .authorized || authorization == .provisional else { return }
        for m in messages.prefix(5) {
            let content = UNMutableNotificationContent()
            let sender = m.from?.displayName ?? "New mail"
            switch privacy {
            case .none:
                content.title = "New mail"
            case .sender:
                content.title = sender
            case .senderAndSubject:
                content.title = sender
                content.body = m.subject.isEmpty ? "(No subject)" : m.subject
            case .full:
                content.title = sender
                content.subtitle = m.subject
                content.body = m.snippet
            }
            if multipleAccounts { content.title += " · \(account.shortLabel)" }
            content.sound = .default
            content.categoryIdentifier = "mail"
            content.threadIdentifier = "\(account.id)/\(m.threadID)"
            content.userInfo = ["url": DeepLink.thread(ThreadRef(accountID: account.id, threadID: m.threadID)).absoluteString]
            try? await center.add(UNNotificationRequest(identifier: "mail-\(account.id)-\(m.id)", content: content, trigger: nil))
        }
    }

    func scheduleLaterReminder(_ ref: ThreadRef, subject: String, at date: Date, privacy: PreviewPrivacy) async {
        let content = UNMutableNotificationContent()
        content.title = "Back in your Inbox"
        content.body = privacy == .none || privacy == .sender ? "A conversation you set for later is back." : subject
        content.sound = .default
        content.threadIdentifier = "later"
        content.userInfo = ["url": DeepLink.thread(ref).absoluteString]
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let request = UNNotificationRequest(identifier: Self.laterID(ref), content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        try? await center.add(request)
    }

    func cancelLaterReminder(_ ref: ThreadRef) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.laterID(ref)])
    }

    func postOutboxWaiting(count: Int) async {
        let content = UNMutableNotificationContent()
        content.title = count == 1 ? "1 message is waiting to send" : "\(count) messages are waiting to send"
        content.body = "Open Slate to finish sending."
        content.userInfo = ["url": DeepLink.mailbox(.outbox).absoluteString]
        try? await center.add(UNNotificationRequest(identifier: "outbox-waiting", content: content, trigger: nil))
    }

    func removeAll(for accountID: String) async {
        let delivered = await center.deliveredNotifications().map(\.request.identifier).filter { $0.contains(accountID) }
        center.removeDeliveredNotifications(withIdentifiers: delivered)
        let pending = await center.pendingNotificationRequests().filter {
            ($0.content.userInfo["url"] as? String)?.contains(accountID) == true
        }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: pending)
    }

    func setBadge(_ count: Int) {
        center.setBadgeCount(count)
    }

    private static func laterID(_ ref: ThreadRef) -> String { "later-\(ref.accountID)-\(ref.threadID)" }

    // MARK: Delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) else { return }
        await MainActor.run { self.onOpen?(url) }
    }
}

nonisolated enum DeepLink {
    static func thread(_ ref: ThreadRef) -> URL {
        URL(string: "slate://thread/\(ref.accountID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")/\(ref.threadID)")!
    }
    static func mailbox(_ m: Mailbox) -> URL { URL(string: "slate://mailbox/\(m.title.lowercased().replacingOccurrences(of: " ", with: "-"))")! }
    static let compose = URL(string: "slate://compose")!

    enum Target: Equatable { case thread(ThreadRef), mailbox(Mailbox), compose(to: [EmailAddress], subject: String, body: String) }

    static func parse(_ url: URL) -> Target? {
        if url.scheme == "mailto" {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let to = EmailAddress.parseList(comps?.path.removingPercentEncoding ?? "")
            let q = Dictionary((comps?.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            return .compose(to: to + EmailAddress.parseList(q["to"] ?? ""), subject: String((q["subject"] ?? "").prefix(500)), body: String((q["body"] ?? "").prefix(20_000)))
        }
        guard url.scheme == "slate" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host {
        case "thread" where parts.count == 2:
            return .thread(ThreadRef(accountID: parts[0].removingPercentEncoding ?? parts[0], threadID: parts[1]))
        case "mailbox" where parts.count == 1:
            return Mailbox.standard.first { $0.title.lowercased().replacingOccurrences(of: " ", with: "-") == parts[0] }.map(Target.mailbox)
        case "compose":
            return .compose(to: [], subject: "", body: "")
        default:
            return nil
        }
    }
}
