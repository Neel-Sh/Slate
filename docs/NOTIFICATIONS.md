# New-mail notifications: what works today and what needs a backend

## Today (implemented)

- Slate syncs on launch, on returning to the foreground, on pull-to-refresh, when connectivity returns, and when iOS grants a `BGAppRefreshTask` (`com.neelsharma.Slate.refresh`).
- New Inbox messages found by those syncs produce **local** notifications, honouring per-account mode (All / Focused Only / Off) and the preview privacy setting (Hidden / Sender / Sender and Subject / Full). Each notification deep-links to `slate://thread/<account>/<thread>`.
- The badge is the number of unread **conversations** in Inbox, across accounts whose notifications are not Off, with each (account, thread) counted once, recomputed after every sync and action.
- Later reminders are scheduled `UNCalendarNotificationTrigger`s, independent of new-mail alerts.

**Limitation:** iOS decides when background refresh runs, and it never runs after the user force-quits the app. These alerts are therefore best-effort and can be hours late. They are not a substitute for push, and the app says so in Settings.

## Required for release journey 9 (blocked: needs infrastructure you own)

Gmail cannot send APNs pushes directly. The supported path is:

```
Gmail users.watch(topicName, labelIds:[INBOX])
   └─► Cloud Pub/Sub topic  (grant gmail-api-push@system.gserviceaccount.com Publisher)
          └─► push subscription → HTTPS endpoint (small service)
                 ├─ verify the Pub/Sub OIDC token (audience = endpoint)
                 ├─ dedupe by (emailAddress, historyId)
                 ├─ map emailAddress → device token(s) (registered by the app)
                 └─► APNs (token-based .p8 key), alert push with
                        mutable-content so a Notification Service Extension
                        can fetch the snippet on-device; payload carries only
                        account id + historyId, never message content
```

What you would need to provide:

1. A Google Cloud Pub/Sub topic and push subscription in the same project as the OAuth client.
2. A tiny HTTPS service (Cloud Run is the natural fit) with a database of device tokens.
3. An APNs authentication key (.p8) from your Apple Developer account and the **Push Notifications** capability on the app ID.
4. A decision on data handling: if the service ever fetches message content with the user's token it handles restricted-scope Gmail data and falls under Google's Workspace API User Data policy. The design above avoids that: the server only relays "something changed" and the phone fetches content itself in a Notification Service Extension.
5. Watch renewal: Gmail watches expire after 7 days and Google recommends renewing daily. Planned design: the app calls `watch` on each foreground and the service renews daily as a backstop. (Neither exists yet.)

Until that exists, the notification and badge P0 gate is **not met** for the locked-phone case.
