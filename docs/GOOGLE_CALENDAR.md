# Connecting Polly to Google Calendar

Polly looks up the meeting you're recording in your calendar to get its
**title** and **invitees**, which helps Claude put names to the voices in the
transcript. It only ever asks for **read-only access to calendar events**.

There are two ways to connect.

## Option A — Add Google to macOS Calendar (no setup)

If your organization allows it: **System Settings → Internet Accounts → Add
Account → Google**, sign in, and turn on **Calendars**. Polly reads macOS
Calendar automatically (it asks for Calendar access the first time). Nothing
else to configure.

## Option B — Connect Polly directly (works when Option A is blocked)

Google requires every app that reads Calendar to have its own OAuth client.
You create one once, in about five minutes, in a Google Cloud project you own.

1. Open the [Google Cloud console](https://console.cloud.google.com/) and
   create a project (for example "Polly").
2. **Enable the API:** APIs & Services → Library → search **Google Calendar
   API** → **Enable**.
3. **Configure the consent screen:** Google Auth Platform → Get started.
   - App name: `Polly`; support email: yours.
   - Audience: **Internal** if you use Google Workspace (only people in your
     organization can use it; no Google review needed). Otherwise choose
     **External** and add your own address under **Test users**.
4. **Create the client:** Google Auth Platform → Clients → **Create client**
   → Application type **Desktop app** → name `Polly` → **Create**. Copy the
   **Client ID** and **Client secret**.
5. In Polly: **Settings → Calendar → OAuth client**, paste both, **Save**,
   then **Connect Google Calendar…**. Your browser opens; sign in and allow
   read-only calendar access. When it says *Polly is connected*, close the tab.

Polly stores the client secret and the sign-in token in your macOS Keychain.
**Disconnect** in Settings revokes the token.

### Notes

- **External apps in "Testing"** — Google expires sign-ins after 7 days for
  apps whose publishing status is *Testing*. Use an **Internal** app
  (Workspace), or publish the app, to avoid reconnecting weekly.
- **Workspace admins** can block third-party apps. If sign-in says the app is
  blocked, ask your admin to trust the OAuth client ID under Admin console →
  Security → API controls → App access control.
- Polly reads your **primary** calendar, looks for an event that is in
  progress (or starts within 15 minutes) when you start recording, and
  ignores all-day events, rooms and people who declined.
- Only the invitees' **names** are included when the transcript is sent to
  Claude.

### How it works

Polly uses Google's OAuth flow for desktop apps: it opens your browser and
briefly listens on `http://127.0.0.1:<random port>` for Google's redirect,
using PKCE. Scopes requested: `openid email` (to show which account is
connected) and `https://www.googleapis.com/auth/calendar.events.readonly`.
