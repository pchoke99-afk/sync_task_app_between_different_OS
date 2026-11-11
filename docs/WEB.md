# iPhone and browser access

The native iOS target has been retired. `web/` is a standalone HTML, CSS, and JavaScript app; it does not require Flutter, an Apple Developer subscription, certificates, or periodic re-signing. Mac, Windows, Android, and Linux source remain available.

The web app connects to the **same existing PocketBase tasks and Python/Ollama assistant**. No new database or migration is needed. It includes the dark theme, Halo's blue rings, hover animation, task creation/editing/completion/deletion, filters, confetti, offline edits, conversation history, and explicit AI proposal approval.

The daily goal is three completed tasks, resetting at local midnight. Completing more tasks keeps the bar at 100%. Deleting a completed task keeps its daily credit, while reopening it removes that credit. An “All caught up” message shows when there are no open tasks. Today's completion IDs are saved per account on each device or browser. Other devices count completions when they sync the task records. A completion deleted before another device sees it cannot be recovered there. The Mac and Windows apps use the same goal.

## Build

Use Node.js 22 or later. From the repository root:

```sh
cd web
npm ci --ignore-scripts
npm run check
npm test
npm run build
```

`web/dist/` is generated and ignored by Git. OCR dependencies are pinned in `package-lock.json` and bundled from installed packages; browser images never go to a CDN or the AI server. OCR downloads only when you attach an image. GitHub's **Browser app** workflow also provides a ready-to-deploy `Sync-Task-Web` artifact.

For a visual preview, run `python3 -m http.server 8141 --bind 127.0.0.1 --directory web/dist` from the repository root. A static-only preview cannot sign in without the configured reverse proxy.

## Deploy to the existing Ubuntu server

These instructions assume PocketBase listens on host port 8090 and the assistant listens on **127.0.0.1:8080**, as in the existing deployment. The new service uses **127.0.0.1:8081**. It does not mount any PocketBase directories, create database volumes, change PocketBase rules, or restart the AI services.

On the development Mac, after building:

```sh
ssh YOUR_USER@YOUR_SERVER 'mkdir -p ~/services/sync-task-web'
scp -r web/dist web/deploy web/compose.yaml web/.dockerignore \
  YOUR_USER@YOUR_SERVER:services/sync-task-web/
```

On Ubuntu:

```sh
cd ~/services/sync-task-web
sh deploy/start.sh
```

The script uses sudo for Docker and Tailscale. It creates the separate Compose project **sync-task-web**, validates the configuration, builds/starts only `web`, checks local HTTP, and enables private Tailscale HTTPS. It refuses to overwrite an existing Tailscale service on port 443. On subsequent updates, if that route already belongs to Sync Task, rebuild only the web container:

```sh
cd ~/services/sync-task-web
sudo docker compose -p sync-task-web build web
sudo docker compose -p sync-task-web up -d --no-deps web
```

Check the address with `tailscale serve status`. Open its **https://…ts.net/** URL with Tailscale connected on your iPhone, then sign in with your existing task account. Safari → Share → **Add to Home Screen** adds the browser app. Delete the old native iOS app on the phone only after confirming the browser shows your tasks; any unsynced native edits should be synchronized first.

The server must remain powered on and connected for synchronization and AI. The browser frontend does not require the Mac or its SSH tunnel. Tailscale Serve shares inside your tailnet; do **not** use Funnel or open router ports for this deployment.

## Google Calendar for the browser

Desktop OAuth credentials cannot be reused here. In your existing Google Cloud project:

1. Keep Google Calendar API enabled.
2. Google Auth Platform → Clients → Create client → **Web application**.
3. Add your exact Tailscale HTTPS origin under **Authorized JavaScript origins** (no path or trailing slash). This browser token flow does not use a client secret or a redirect endpoint.
4. Add your Google account under Audience → Test users while the OAuth app is in testing.
5. Copy only the **client ID** into Sync Task's Settings, save it, then open Halo and select **Connect Calendar**.

Google credentials/tokens are not synced from the desktop Keychain. The public client ID is saved locally; Google access tokens remain in memory until expiry, sign-out, or page reload. Only primary-calendar busy intervals for the next 14 days go to the assistant, never Google tokens or event names. Reconnect Calendar when the token expires.

See Google's [browser token flow documentation](https://developers.google.com/identity/oauth2/web/guides/use-token-model).

## Input, offline behavior, and privacy

- **Microphone:** use Safari/iPhone keyboard dictation. Browsers that provide SpeechRecognition expose a dictation button after an explicit audio-processing notice. Browser speech recognition may use the browser vendor's service; it is not claimed to be local. Recording never auto-sends a message.
- **Images:** paste an image into the message field or attach one. Tesseract runs OCR locally and inserts editable extracted text. Review before sending; Qwen2.5:3B cannot see the image. Images are not uploaded. The bundled OCR language is English.
- **Offline:** the app shell is cached after the first visit. Task copies and queued edits are stored in browser local storage, partitioned by task account. Lost create/delete responses are reconciled without duplicate writes. Conflicting remote edits stop the queue; Settings lets you export your offline copy before explicitly discarding queued edits and reloading server data.
- **Authentication:** By default, PocketBase login tokens live in tab-scoped session storage. Selecting **Remember me on this device** opts into persistent browser storage for up to 30 days, subject to the server token expiring or being revoked earlier. Restored sessions are checked with PocketBase; refreshing an active session does not extend the local 30-day cap. Only the token and account ID are stored, never the password or Google tokens. Browser storage can be read by scripts on this origin; use Remember me only on a trusted personal device. Sign-out clears the session, assistant messages, drafts, and Google tokens from memory. Offline task copies intentionally remain for later synchronization. Browser storage is not macOS Keychain: use a trusted device and device encryption.
- **Caching:** the service worker never caches API requests, OAuth requests, or URLs with query strings. API calls use explicit bearer authorization. CSP, no-referrer, anti-framing, no-sniff, and method/path restrictions are set by Nginx. The proxy deliberately excludes PocketBase's admin routes.
- **Concurrency:** server update timestamps help catch conflicts during offline replay. They do not provide a server-side atomic compare-and-swap transaction; PocketBase owner-only API rules remain essential.
- **AI:** existing account/ownership checks and preview/confirm flow remain server-side. Long requests stay bounded. A failed/ambiguous confirmation is never automatically replayed; inspect tasks before retrying.
- **Cross-device updates:** the web app polls while visible every 30 seconds and refreshes when brought to the foreground. Open the new version after a reload if a service-worker update is waiting.

No new paid AI provider, subscription, or Apple enrollment is introduced. Existing hardware, internet, electricity, and any provider quotas still apply. The web deployment files use loopback upstreams and do not bundle credentials or Google tokens.

## Rollback

To stop only the new web service:

```sh
cd ~/services/sync-task-web
sudo docker compose -p sync-task-web stop web
```

Remove the HTTPS route only if it still points to this web service:

```sh
sudo tailscale serve --https=443 off
```

Neither command deletes PocketBase data, AI history, models, or Docker volumes.
