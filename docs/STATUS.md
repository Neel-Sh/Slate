# Slate: status and evidence (2026-10-23)

Legend: **Verified** = exercised and observed. **Unit-tested** = covered by `SlateTests` against fakes. **Implemented, unverified live** = code exists against the documented Gmail contract but has not run against a real Google account. **Blocked** / **Not started** as stated.

No live Gmail account has been connected yet: that needs the OAuth client in `docs/SETUP.md`.

## P0 checklist

| P0 feature | State | Evidence / gap |
| --- | --- | --- |
| Multiple Gmail accounts | Implemented, unverified live | OAuth PKCE + Keychain per account, reconnect detects wrong-account sign-in, removal revokes and clears local data (unit-tested store side). Needs two real accounts. |
| Unified inbox | Verified with sample, unit-tested | Keyset pagination across accounts tested with identical timestamps (50/50 unique). Account tag shown in All Accounts. Replies always use the receiving account. |
| Undo Send (5/10/20/30 s) | Unit-tested + verified in Simulator | 13 outbox tests: undo restores full draft, two independent sends, undo-vs-submit race, offline queue, ambiguous outcome reconciled via `rfc822msgid:`, auth failure, relaunch recovery, no cross-account fallback. Simulator: send → "Sending in 8 s · Undo" → undo reopened draft → resent once. |
| Complete compose/reply | Implemented; verified in Simulator with sample | To/Cc/Bcc tokens, reply/reply-all/forward (forward downloads attachments), subject, per-account signatures that swap on From change, bold/italic/bullets/links, quoted text toggle, Writing Tools enabled. Reply-all identity removal unit-tested. |
| Safe drafts and outbox | Implemented; partly unit-tested | Local autosave (0.6 s), Gmail draft sync (5 s) with "edited elsewhere → keep both". **Gap:** drafts created in Gmail web are not yet imported for editing. |
| Conversation reader | Verified with sample | Threading from provider thread IDs, collapsed earlier messages, recipient details, plain text with links, sandboxed HTML (no JS, CSP-blocked remote content, links open in Safari), inline `cid:` images, attachments via Quick Look + Share. MIME mapping unit-tested (charset, alternatives, inline vs attached). |
| Everyday organization | Implemented; verified with sample | Archive (never marks read — tested), Trash/Restore, read/unread, star, important; optimistic with durable replay queue and Undo. Unverified against Gmail. |
| Mailboxes and labels | Implemented | All required mailboxes; label create/rename/delete (delete keeps messages), apply/remove/Move Here, same-name labels per account kept distinct (tested). |
| Bulk actions | Implemented | Select mode, "Select All Visible" (no "select all matching" yet), archive/trash/mark/star/labels/Later/spam with one Undo. **Gap:** no per-item partial-failure report yet; failures fall back to the next sync restoring server truth. |
| Search | Implemented; local search unit-tested | Operators listed in the Search screen; dates sent to Gmail as epoch seconds (tested). Local FTS5 results first, then Gmail results beyond the cache. Gmail-side semantics unverified live. |
| Attachments | Implemented | Files + Photos, 25 MB total check, remove, progress. **Gap:** no upload progress or cancel for large sends (sent in one multipart upload). |
| Later | Implemented; tested | App-owned (Gmail unchanged, disclosed). Presets incl. configurable morning; DST-safe (tested). New reply resurfaces immediately. Local reminder notification. |
| Spam management | Implemented | Move to Spam = add SPAM, remove INBOX; Not Spam reverses. Worded as moving, not reporting/blocking. |
| Notifications and badges | **Partially blocked** | Local alerts from foreground/background-refresh sync, per-account modes, preview privacy, deep links, badge = unread Inbox conversations (deduped). Locked-phone push requires the backend in `docs/NOTIFICATIONS.md`. |
| Offline and sync | Implemented; partly tested | History delta with 404 → full resync preserving drafts/outbox/ops; offline banner; queued operations replay in order. Unverified live. |
| Essential settings | Implemented | Accounts, friendly names, default account, signatures, Undo Send duration, notification mode + previews, swipe actions, remote images, intelligence toggle, recent searches. |

## Intelligence

| Item | State |
| --- | --- |
| Suggested reply intentions → editable draft | **Verified in Simulator with the real on-device model** (pricing thread produced "Accept $18,000 / Keep the original terms / Propose something else"; choice 1 produced an editable, labelled draft; nothing sent). |
| Summaries with tap-through provenance | Implemented; not yet exercised on a real thread |
| Shorter / Warmer / More Direct, restore original, stale-response guard | Implemented |
| Guardrail finding | Default guardrails rejected the drafting prompt; drafting/rewriting now use `permissiveContentTransformations` (they transform the user's own mail). Errors map to plain messages; only error types are logged. |
| Prompt-injection fixture | Present in sample data (`t-phish`); not yet formally evaluated |

## Appearance evidence (`docs/screens/`)

Inbox dark, Inbox at Accessibility XL, newsletter in dark mode with remote images blocked, conversation after send. Colour contrast: 16 token pairs × 4 modes (light, dark, and both high-contrast variants) ≥ 4.5:1, asserted by `ContrastTests`.

## Not started (tracked, not hidden)

Widgets, App Intents, default-mail-app entitlement, share extension, scheduled send (needs backend), unsubscribe, mute, block, filters, categories view, aliases/send-as, Face ID lock, meeting context, PCC. Release journeys 1–10 have not been run on a real iPhone with real accounts.

## Commands used

```bash
xcodebuild test -project Slate.xcodeproj -scheme Slate -destination 'platform=iOS Simulator,id=<iPhone 18 Pro, iOS 27.0>'
# → Test run with 39 tests in 9 suites passed
```
