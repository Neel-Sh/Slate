import SwiftUI
import AuthenticationServices

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var page = 0
    @State private var connecting = false
    @State private var error: String?

    private static let pages: [OnboardingStep] = [
        .init(eyebrow: "Welcome to Slate", title: "Mail, made calm.",
              message: "One quiet inbox for all your Gmail accounts. See what needs you and leave the rest.",
              palette: [Warm.blush, Warm.peach, Warm.amber, Warm.coral, Warm.ember, Warm.amber, Warm.peach, Warm.peach, Warm.peach],
              visual: .brand),
        .init(eyebrow: "01  Focus", title: "What matters, first.",
              message: "Focused shows mail from people. Later sets a conversation aside until you need it. Undo Send gives you ten seconds to reconsider.",
              palette: [Warm.peach, Warm.amber, Warm.peach, Warm.amber, Warm.ember, Warm.blush, Warm.peach, Warm.peach, Warm.peach],
              visual: .inbox),
        .init(eyebrow: "02  Private by design", title: "Help that stays on your iPhone.",
              message: "Summaries and suggested replies are written on-device and open as a draft you edit. Nothing is ever sent for you.",
              palette: [Warm.amber, Warm.blush, Warm.coral, Warm.peach, Warm.ember, Warm.blush, Warm.peach, Warm.peach, Warm.peach],
              visual: .reply),
    ]

    private var isLast: Bool { page == Self.pages.count - 1 }

    var body: some View {
        ZStack(alignment: .top) {
            Color.slate.canvas.ignoresSafeArea()
            WarmSky(palette: Self.pages[page].palette)
                .frame(height: 500)
                .ignoresSafeArea(edges: .top)
                .animation(.smooth(duration: 0.6), value: page)
                .id(page)
                .transition(.opacity)

            VStack(spacing: 0) {
                header
                TabView(selection: $page) {
                    ForEach(Array(Self.pages.enumerated()), id: \.offset) { i, step in
                        StepView(step: step, isActive: page == i).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                footer
            }
        }
        .sensoryFeedback(.selection, trigger: page)
        .alert("Couldn't connect", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
    }

    private var header: some View {
        HStack {
            Text("Slate")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.slate.inkPrimary)
            Spacer()
            if !isLast {
                Button("Skip") { withAnimation(Motion.standard) { page = Self.pages.count - 1 } }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.slate.inkPrimary)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(.thinMaterial, in: Capsule())
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.xs)
        .frame(minHeight: Spacing.minHit)
    }

    private var footer: some View {
        VStack(spacing: Spacing.sm) {
            if isLast {
                Button { Task { await connect() } } label: {
                    HStack(spacing: Spacing.xs) {
                        if connecting { ProgressView().tint(Color.slate.onAccent) }
                        Text(connecting ? "Connecting…" : "Connect Gmail")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryCapsuleStyle())
                .disabled(connecting)
                Button { Task { await model.addSampleAccount() } } label: {
                    Text("Try with sample mail").frame(maxWidth: .infinity)
                }
                .buttonStyle(QuietCapsuleStyle())
                .disabled(connecting)
            } else {
                Button { withAnimation(Motion.standard) { page += 1 } } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryCapsuleStyle())
            }
            PageDots(count: Self.pages.count, current: page)
                .frame(height: 20)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.bottom, Spacing.sm)
    }

    private func connect() async {
        connecting = true
        defer { connecting = false }
        do { try await model.connectGmail(using: webAuth) }
        catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {}
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
    }
}

private struct OnboardingStep {
    enum Visual { case brand, inbox, reply }
    var eyebrow: String
    var title: String
    var message: String
    var palette: [Color]
    var visual: Visual
}

private struct StepView: View {
    var step: OnboardingStep
    var isActive: Bool
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch step.visual {
                case .brand: BrandVisual()
                case .inbox: InboxVisual()
                case .reply: ReplyVisual()
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 12)

            Spacer(minLength: Spacing.md)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(step.eyebrow)
                    .font(.footnote.monospaced().weight(.medium))
                    .foregroundStyle(Color.slate.inkSecondary)
                Text(step.title)
                    .font(.largeTitle.weight(.regular))
                    .foregroundStyle(Color.slate.inkPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(step.message)
                    .font(.body)
                    .foregroundStyle(Color.slate.inkSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.lg)
            .accessibilityElement(children: .combine)
        }
        .onChange(of: isActive, initial: true) { _, active in
            if active { withAnimation(Motion.standard.delay(0.05)) { shown = true } }
        }
    }
}

// MARK: - Visuals (every piece of text sits on a card, never on the gradient)

private struct Card<Content: View>: View {
    var padding: CGFloat = Spacing.md
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(Color.slate.surfaceElevated, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.07), radius: 24, y: 10)
    }
}

private struct BrandVisual: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var float = false

    var body: some View {
        Card(padding: 28) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle().fill(Color.slate.signal).frame(width: 9, height: 9)
                    Capsule().fill(Color.slate.inkPrimary).frame(width: 110, height: 10)
                }
                Capsule().fill(Color.slate.inkPrimary.opacity(0.85)).frame(width: 92, height: 10).padding(.leading, 19)
                Capsule().fill(Color.slate.inkPrimary.opacity(0.7)).frame(width: 64, height: 10).padding(.leading, 19)
            }
        }
        .offset(y: float ? -6 : 6)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { float = true }
        }
        .accessibilityHidden(true)
    }
}

private struct InboxVisual: View {
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    row(unread: true, sender: "Elena Marsh", time: "4:17 PM", subject: "Renewal pricing")
                    Divider().overlay(Color.slate.separator).padding(.leading, 30)
                    row(unread: true, sender: "Priya, Sam", time: "12:20 PM", subject: "Wedding plans")
                    Divider().overlay(Color.slate.separator).padding(.leading, 30)
                    row(unread: false, sender: "Theo Lindqvist", time: "Yesterday", subject: "Sync latency")
                }
                .padding(.vertical, 6)
            }
            .frame(width: 290)

            HStack(spacing: 6) {
                pill("Focused", filled: true)
                pill("All", filled: false)
            }
            .offset(x: 14, y: -26)

            Label("Sending in 9 s · Undo", systemImage: "paperplane")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.slate.onAccent)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color.slate.accent, in: Capsule())
                .offset(x: -40, y: 190)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example inbox showing Focused mail and an Undo Send bar")
    }

    private func row(unread: Bool, sender: String, time: String, subject: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(unread ? Color.slate.signal : .clear).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(sender).font(.subheadline.weight(unread ? .semibold : .regular)).foregroundStyle(Color.slate.inkPrimary)
                    Spacer()
                    Text(time).font(.caption).foregroundStyle(Color.slate.inkMetadata)
                }
                Text(subject).font(.footnote).foregroundStyle(Color.slate.inkSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func pill(_ title: String, filled: Bool) -> some View {
        Text(title)
            .font(.caption.weight(filled ? .semibold : .regular))
            .foregroundStyle(filled ? Color.slate.inkPrimary : Color.slate.inkSecondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(filled ? Color.slate.surfaceElevated : Color.slate.surfaceSecondary, in: Capsule())
            .shadow(color: .black.opacity(filled ? 0.06 : 0), radius: 8, y: 3)
    }
}

private struct ReplyVisual: View {
    var body: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Elena Marsh").font(.subheadline.weight(.semibold)).foregroundStyle(Color.slate.inkPrimary)
                    Text("$20,000 is above our budget. Would $18,000 work instead?")
                        .font(.footnote).foregroundStyle(Color.slate.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                Divider().overlay(Color.slate.separator)
                GeneratedBadge(title: "Suggested reply")
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                option(1, "Accept $18,000")
                option(2, "Keep $20,000")
                option(3, "Propose something else")
                    .padding(.bottom, 6)
            }
        }
        .frame(width: 300)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example suggested reply with three choices")
    }

    private func option(_ n: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(n)").font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(Color.slate.inkSecondary)
                .frame(width: 22, height: 22)
                .background(Color.slate.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(text).font(.subheadline).foregroundStyle(Color.slate.inkPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}

private struct PageDots: View {
    var count: Int
    var current: Int
    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.slate.inkPrimary : Color.slate.separator)
                    .frame(width: i == current ? 18 : 6, height: 6)
            }
        }
        .animation(Motion.standard, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}
