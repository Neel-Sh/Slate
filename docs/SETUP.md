# Running Slate on your iPhone

## 1. Create a Google OAuth client (one time, ~10 minutes)

Slate talks to Gmail directly from the phone. Google requires a native **iOS** OAuth client that matches the bundle ID.

1. Open <https://console.cloud.google.com/> and create a project (for example "Slate Personal").
2. **APIs & Services → Library →** enable **Gmail API**.
3. **APIs & Services → OAuth consent screen (Google Auth Platform)**
   - User type: **External**. App name: Slate. Your email as support and developer contact.
   - **Data access / Scopes:** add `https://www.googleapis.com/auth/gmail.modify`.
   - **Audience → Test users:** add every Gmail address you want to connect (each personal account; Workspace accounts too if their admin allows third-party apps).
   - Leave publishing status as **Testing**. Restricted-scope verification is only required for public distribution; personal use with listed test users is allowed. Consequence: Google expires the sign-in **every 7 days**, and Slate will show "Reconnect" for that account. Other accounts keep working.
4. **Credentials → Create credentials → OAuth client ID → Application type: iOS**
   - Bundle ID: `com.neelsharma.Slate`
   - Copy the **Client ID** (ends in `.apps.googleusercontent.com`). There is no client secret for iOS clients.
5. In this repository create `Config/Local.xcconfig` (it is git-ignored):

   ```
   GOOGLE_IOS_CLIENT_ID = 1234567890-abc123def456.apps.googleusercontent.com
   ```

Slate uses the reversed client ID (`com.googleusercontent.apps.…:/oauth2redirect`) as the redirect through `ASWebAuthenticationSession`; no URL-type registration is needed.

## 2. Build and install

1. Open `Slate.xcodeproj` in Xcode 27.1 or later.
2. Select the **Slate** target → Signing & Capabilities → confirm your team (`Q672YJ8657` is pre-set). Automatic signing will register `com.neelsharma.Slate`.
3. Connect your iPhone (iOS 26 or later), enable Developer Mode if prompted, choose it as the run destination, and press Run.
4. In Slate: **Connect Gmail** → choose the account → allow access. Repeat from **Settings → Add Gmail Account** for each additional account.

To explore without Google: **Explore with Sample Mail** (clearly labelled, never touches the network). The Simulator launch argument `-SlateSampleData` does the same.

## 3. Tests

```bash
xcodebuild test -project Slate.xcodeproj -scheme Slate -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

## 4. Removing an account

Settings → the account → Remove Account. Slate revokes its token with Google, deletes the Keychain item, and clears that account's cached mail, drafts, outbox, Later reminders, attachments and notifications on the phone. Nothing is deleted from Gmail.
