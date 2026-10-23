import SwiftUI
import BackgroundTasks

@main
struct SlateApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    static let refreshTaskID = "com.neelsharma.Slate.refresh"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Color.slate.accent)
                .task { await model.start() }
                .onOpenURL { model.handle($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await model.refreshAll() }
                model.intelligence.refresh()
            case .background:
                model.didEnterBackground()
                Self.scheduleRefresh()
            default: break
            }
        }
        .backgroundTask(.appRefresh(Self.refreshTaskID)) {
            Self.scheduleRefresh()
            await model.backgroundRefresh()
        }
    }

    /// Opportunistic refresh. iOS decides when (or whether) this runs; it is not a substitute for push.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if let error = model.launchError {
                EmptyStateView(title: "Slate can't start", message: error, symbol: "exclamationmark.triangle")
            } else {
                NavigationStack(path: $model.path) {
                    MailListView()
                        .navigationDestination(for: ThreadRef.self) { ConversationView(ref: $0) }
                }
            }
        }
        .background(Color.slate.canvas)
        .overlay(alignment: .bottom) { StatusOverlay().padding(.bottom, 64) }
        .sheet(isPresented: $model.showMailboxes) { MailboxesView() }
        .sheet(isPresented: $model.showSettings) { SettingsView() }
        .sheet(item: $model.composer) { draft in
            ComposerView(draft: draft)
                .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: $model.showOnboarding) {
            // Onboarding is a single light, paper-like moment; the app itself follows the system appearance.
            OnboardingView().preferredColorScheme(.light)
        }
        .sensoryFeedback(trigger: model.feedback) { _, new in new?.sensory }
    }
}

/// Undo Send countdowns and undoable-action toasts. Lives above navigation so leaving a screen never removes it.
struct StatusOverlay: View {
    @Environment(AppModel.self) private var model
    @AccessibilityFocusState private var focused: Bool

    var body: some View {
        VStack(spacing: Spacing.xs) {
            ForEach(model.outboxItems.filter { $0.state == .pending || $0.state == .submitting }.suffix(3)) { item in
                SendingCapsule(item: item)
            }
            if let toast = model.toast {
                ToastCapsule(toast: toast)
                    .id(toast.id)
                    .task(id: toast.id) {
                        try? await Task.sleep(for: .seconds(toast.undo == nil ? 3 : 6))
                        if model.toast?.id == toast.id { withAnimation { model.toast = nil } }
                    }
            }
        }
        .padding(.horizontal, Spacing.md)
        .animation(.snappy, value: model.outboxItems.map(\.state))
        .animation(.snappy, value: model.toast)
    }
}

private struct SendingCapsule: View {
    @Environment(AppModel.self) private var model
    var item: OutboxItem

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(ceil(item.deadline.timeIntervalSince(context.date))))
            HStack(spacing: Spacing.sm) {
                if item.state == .submitting || remaining == 0 {
                    ProgressView().controlSize(.small)
                    Text("Sending…").font(.subheadline.weight(.medium))
                } else {
                    Image(systemName: "paperplane").foregroundStyle(Color.slate.inkSecondary).font(.subheadline)
                    Text("Sending in \(remaining) s")
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                    if model.hasMultipleAccounts, let a = model.account(item.accountID) {
                        Text("· \(a.shortLabel)").font(.footnote).foregroundStyle(Color.slate.inkMetadata).lineLimit(1)
                    }
                    Spacer(minLength: Spacing.xs)
                    Button("Undo") { Task { await model.undoSend(item) } }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.slate.link)
                        .frame(minWidth: Spacing.minHit, minHeight: Spacing.minHit)
                }
            }
            .padding(.horizontal, Spacing.md)
            .frame(minHeight: Spacing.minHit + 4)
            .frame(maxWidth: 480)
            .modifier(InkCapsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(item.state == .pending && remaining > 0 ? "Sending \(item.snapshot.subject) in \(remaining) seconds" : "Sending \(item.snapshot.subject)")
            .accessibilityAction(named: "Undo Send") { Task { await model.undoSend(item) } }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear { AccessibilityNotification.Announcement("Sending in \(model.prefs.undoSendSeconds) seconds. Undo available.").post() }
    }
}

private struct ToastCapsule: View {
    @Environment(AppModel.self) private var model
    var toast: Toast

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if toast.isError { Image(systemName: "exclamationmark.circle").foregroundStyle(Color.slate.destructive) }
            Text(toast.message).font(.subheadline).lineLimit(2)
            Spacer(minLength: Spacing.xs)
            if let undo = toast.undo {
                Button("Undo") {
                    model.toast = nil
                    Task { await undo() }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.slate.link)
                .frame(minWidth: Spacing.minHit, minHeight: Spacing.minHit)
            }
        }
        .padding(.horizontal, Spacing.md)
        .frame(minHeight: Spacing.minHit + 4)
        .frame(maxWidth: 480)
        .modifier(InkCapsule())
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Undo") { if let undo = toast.undo { model.toast = nil; Task { await undo() } } }
        .onAppear { AccessibilityNotification.Announcement(toast.message).post() }
    }
}

/// Solid, inverted capsule for transient status: ink on light appearance, paper on dark. Text inside uses the opposite scheme's tokens.
private struct InkCapsule: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, scheme == .dark ? .light : .dark)
            .background(Color.slate.inkPrimary, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}
