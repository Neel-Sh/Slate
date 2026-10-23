# Slate — Design & Feasibility Brief

Research baseline: 2026-10-23. Toolchain verified on this Mac: **Xcode 27.1 (27A9275), iOS 27.1 SDK, Swift 6.4**.
Simulators: iOS 26.2 and iOS 27.0 runtimes (iPhone 16e … iPhone 18 Pro Max).

## 0. Assumptions recorded

| Assumption | Basis | Consequence |
| --- | --- | --- |
| Gmail is the first and only provider for the initial release | Brief §2; no other provider context in repo | `MailProvider` protocol keeps the door open; only `GmailProvider` + `SampleProvider` exist |
| Working name **Slate** | Repository, target and README are already named Slate | Display name "Slate"; trivial to rename later |
| Minimum iOS **26.0** | Brief §4; Liquid Glass + Foundation Models are iOS 26 APIs. Repo template defaulted to 27.0 | iOS 27-only APIs (e.g. PCC, `LanguageModel` protocol) are not used |
| iPhone only | "native iPhone email app" | Template's macOS/visionOS/iPad destinations removed |
| Bundle ID `com.neelsharma.Slate` | Template placeholder `devplaceholder…` cannot be registered as a Google iOS OAuth client | Required for OAuth client + App Group |
| No third-party dependencies | Personal app, maintainability; system SQLite (FTS5), CryptoKit, AuthenticationServices, WebKit cover the needs | Small tested in-house MIME *builder*; incoming MIME is parsed server-side by Gmail (`format=full` payload tree) |

## 1. Screen inventory & navigation map

```
NavigationStack (root)
└─ MailListView  ── title: mailbox name, subtitle: account scope
   ├─ top-leading:  [Mailboxes]  → sheet: MailboxesView
   │                                 ├─ Mailboxes (Inbox, Later, Starred, Important, Drafts, Outbox,
   │                                 │             Sent, All Mail, Spam, Trash)
   │                                 ├─ Labels (per account; create / rename / delete)
   │                                 └─ Settings → Accounts, Sending, Notifications, Swipes,
   │                                               Reading, Intelligence, Privacy, About
   ├─ top-trailing: [Account menu: All Accounts / each account / Manage…]  [Select]
   ├─ header:       Focused | All  (Inbox only)
   ├─ rows → push ConversationView
   │         ├─ toolbar: Archive · Later · Move/Label · Reply menu · More
   │         ├─ Summary (on demand, labelled, Foundation Models)
   │         └─ Suggested reply (intentions → editable draft in Composer)
   ├─ bottom bar:   [Search (system search field)] ···status··· [Compose]
   │                 └─ search results replace the list (local + Gmail sections)
   ├─ edit mode:    bottom bar → Archive · Trash · Mark · More(Star, Label, Later, Spam)
   └─ overlay:      Undo Send / Undo action capsule (persists across navigation)

Sheets: ComposerView (new/reply/reply-all/forward/draft), LaterPicker, LabelPicker,
        AddAccount (OAuth), Onboarding (first launch)
Deep links: slate://thread/<accountID>/<threadID>, slate://compose, slate://mailbox/<id>
```

## 2. Design tokens

Colors live in `Assets.xcassets` as semantic color sets with **light / dark / high-contrast light / high-contrast dark** variants, exposed through `Color.slate.*`.

**Revision (warm palette).** Blue is no longer the interaction color. Controls, selection and the primary button use **ink** (near-black, near-white in dark); a single warm **ember** marks the few things that need attention (unread, generated content, Undo). Surfaces are warm neutrals; label tones are muted and warm, and cool Gmail label colors map to neutral stone.

| Token | Light | Dark | Role |
| --- | --- | --- | --- |
| canvas | #FFFFFF | #121110 | Reading surface |
| surfaceSecondary | #F6F4F1 | #1C1A18 | Panels, selected tab, filters |
| surfaceElevated | #FFFFFF | #262320 | Raised content in panels |
| inkPrimary | #1C1A17 | #F4F1EC | Text; also the interaction tint (`accent`) |
| inkSecondary | #66605A | #B5ADA4 | Previews, supporting text |
| inkMetadata | #6E6862 | #9E968D | Times, counts, quiet labels |
| onAccent | #FFFFFF | #121110 | Text on ink buttons |
| link | #A9401C | #F2A07E | Links in mail, Undo |
| signal | #D9542B | #F07A50 | Unread dot, attention cues (graphical, ≥ 3:1) |
| selectionFill | #F5EEE7 | #33291F | Pressed rows, recipient tokens |
| separatorDecorative | #ECE8E3 | #2E2B28 | Hairlines |
| destructive / positive / warning | #B3261E / #2F6B4F / #8A5300 | #FF9F94 / #8FD3AE / #F5C77E | Status |

Label tones (ink on fill, light): ember `#A13A18/#FBEDE6`, amber `#7F5200/#FBF1DE`, sage `#3D6448/#ECF2EC`, mauve `#7A4763/#F6ECF1`, stone `#5F5952/#F2EFEB`, each with dark and high-contrast variants.

Decorative gradients (`Warm.*`: peach, amber, blush, ember, coral) are used only in the onboarding aura, the app icon and the ring that marks generated content. They never carry text.

Every text pair is asserted ≥ 4.5:1 in all four appearance modes by `ContrastTests`; the signal dot ≥ 3:1.

**Interaction feel.** One smooth, bounce-free curve (`Motion.standard`, 0.28 s) for list changes, tabs and expansion; haptics only for organizing (light), sending (success), undo (soft) and errors. Transient status uses an inverted ink capsule rather than glass, so it stays legible over any message.

Spacing: `4 8 12 16 20 24 32` (`Spacing.xs … xxl`). Corner radius for app-owned panels: 14. Hit targets ≥ 44×44.

Typography roles (all semantic text styles, Dynamic Type through AX5, Bold Text honoured, no custom fonts):

| Role | Style | Weight |
| --- | --- | --- |
| Root title | `.largeTitle` (system nav bar) | system |
| Conversation subject | `.title2` | semibold |
| Row sender | `.headline` | semibold unread / regular read |
| Row subject | `.callout` | semibold unread / medium read |
| Row preview | `.subheadline` | regular, inkSecondary, 2 lines |
| Body / composer | `.body` | regular |
| Time, group headings | `.footnote` | regular / medium; monospaced digits for countdowns only |
| Chips | `.caption` | medium |

## 3. Representative layouts

Implemented as SwiftUI `#Preview`s (repository-native) backed by clearly-named sample fixtures, and captured from the Simulator into `docs/screens/`:
Inbox (light, dark, AX3), Conversation with suggested reply, Composer, Search, Mailboxes. Widget layout is specified below and built in Stage 5.

**Medium widget (Stage 5 spec):** title row "Inbox · All Accounts" + unread count (footnote, monospaced digits); three rows: sender (subheadline semibold), subject (caption, secondary), relative time trailing. Redacted state shows sender initials only and "3 new". Lock Screen accessory: count + envelope glyph, no text by default.

## 4. Capability matrix

| Capability | Status this build | Needs |
| --- | --- | --- |
| Gmail OAuth (PKCE, ASWebAuthenticationSession, Keychain) | **Implemented, unverified live** | A Google Cloud **iOS OAuth client ID** for `com.neelsharma.Slate` (blocker for live verification) |
| Read/sync (threads, history delta, 404 resync), labels, organize, spam/trash, drafts, send (multipart upload), attachments | **Implemented against REST contract, unit-tested with fixtures; unverified live** | Same OAuth client |
| Multiple accounts + unified inbox, account isolation | Implemented (tested with Sample + fixture accounts) | Two real accounts for release journey 1 |
| Undo Send (5/10/20/30 s), durable outbox, ambiguous-outcome reconciliation via `rfc822msgid:` | Implemented + unit-tested state machine | Live verification |
| Local drafts, autosave, crash recovery, Gmail draft sync | Implemented | Live verification of remote draft sync |
| Local search (SQLite FTS5 + operator parser) + Gmail provider search | Implemented | — |
| Later (app-owned visibility + local notification) | Implemented | Disclosed as not Gmail snooze |
| New-mail alerts when app is not running (locked phone) | **Blocked** | Backend: Gmail `watch` → Cloud Pub/Sub → small service → APNs; APNs key; Push entitlement. See `docs/NOTIFICATIONS.md` |
| Foreground/background-refresh local alerts + badge | Implemented (best-effort, disclosed) | — |
| Summaries & reply intentions (Foundation Models, on-device) | Implemented with availability gating | Apple-Intelligence-capable iPhone for real evaluation |
| Writing Tools in composer | Implemented via `UITextView` (`writingToolsBehavior = .complete`) | Supported device |
| Scheduled send, unsubscribe, mute, block, filters, categories, aliases | **Deferred (P1)** | Scheduled send needs a backend (no Gmail scheduling endpoint) |
| Widgets, App Intents, default-mail-app, share extension | **Deferred (Stage 5)** | Default mail entitlement request to Apple |
| PCC inference, meeting import/recording | **Deferred (Stage 6)** | PCC entitlement / eligibility |

## 5. Architecture

```
SwiftUI views ──► AppModel (@Observable, MainActor)  ── selection, scope, toasts
                    │
                    ├─ MailRepository (@Observable)   reads/writes via MailStore, optimistic state
                    ├─ AccountStore                   accounts, Keychain tokens (per account)
                    ├─ SyncCoordinator (actor/acct)   initial + history sync, op queue replay
                    ├─ Outbox (actor)                 Undo Send state machine, submission, reconcile
                    ├─ DraftStore                     local autosave, remote draft sync
                    ├─ IntelligenceService            Foundation Models (on demand)
                    └─ NotificationService            local alerts, badge, Later reminders
MailStore (actor) ── SQLite (WAL, FTS5, file protection: completeUntilFirstUserAuthentication)
MailProvider ◄── GmailProvider (REST via URLSession)  /  SampleProvider (in-memory, labelled)
```

**Storage choice — SQLite (system library) over SwiftData/Core Data:** FTS5 for fast local search, explicit
`UPDATE … WHERE state='pending'` compare-and-swap for the Undo/submit race, simple versioned migrations,
and predictable behaviour from background work. Cost: ~300 lines of wrapper code.

**Keychain / file protection tradeoff:** tokens use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
and the database uses `completeUntilFirstUserAuthentication` so background refresh and pending sends can run while
the phone is locked after its first unlock. Stricter `complete` protection would stop sync whenever the phone is locked.

## 6. Key semantics (decided)

* **Archive** = remove `INBOX` from the thread. Never changes read state.
* **Move to Spam** = add `SPAM`, remove `INBOX` (documented as manually applicable). **Not Spam** = remove `SPAM`, add `INBOX`. Wording never says "report phishing" or "block".
* **Trash** uses `threads.trash`; **Restore** uses `threads.untrash`. No permanent delete (scope `gmail.modify` cannot hard-delete).
* **Labels exist on messages**; thread labels are a union. Applying a label to a conversation applies it to the messages that exist now. Future replies do not inherit it (Gmail behaviour, stated in the label sheet).
* **Bulk actions target selected conversations**, enumerated at tap time.
* **Later** is app-owned: the conversation is hidden from Slate's Inbox until the chosen time, then returns with a local reminder. Gmail is not changed. A new incoming message resurfaces it immediately and clears Later.
* **Badge** = number of unread *conversations* in Inbox across accounts with notifications on, de-duplicated by (account, thread).
* **Undo Send** states: `pending(deadline) → queued → submitting → sent | failed | ambiguous`, `pending|queued → cancelled`. The claim for submission and the undo are both compare-and-swap updates in SQLite, so exactly one wins.

## 7. Phased plan & gates

1. **Design & feasibility** — this document. ✅
2. **Visual foundation** — all screens against Sample fixtures, dark, AX sizes, empty/error states. Gate: screenshots + previews.
3. **Core mail** — Gmail provider, sync, outbox, drafts, search, Later, bulk, spam/trash, notifications. Gate: unit tests + the 10 release journeys on a real device with real accounts (requires OAuth client + backend for journey 9).
4. **Productivity & intelligence** — P1 list, Focused corrections, summaries, intentions evaluation.
5. **System integration** — widgets, App Intents, default mail app, share extension.
6. **Advanced** — PCC, meeting import.
