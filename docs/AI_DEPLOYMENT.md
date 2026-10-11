# Task Assistant deployment

Status: implemented on a development branch. Nothing deployed to the Ubuntu server and no production migrations applied.

## Architecture

The existing Flutter task UI and animations remain in place. A visible AI Assistant button opens a responsive chat screen with conversation selection, cloud availability errors, operation previews, and explicit confirmation. Flutter sends only the current PocketBase user token to the private assistant backend. No provider key or administrator token is shipped in Flutter.

The Python backend verifies tokens with PocketBase `users/auth-refresh` on every request. It uses that user's token for all task reads/writes, checks ownership explicitly, and relies on PocketBase owner rules as the final authorization boundary. Six allowlisted tools support task creation, reading, updating, completion, deletion, and suggested organization. Model tool calls are independently validated. Every mutation requires a ten-minute, user-bound server proposal and a separate confirmation endpoint. Conversation prose cannot confirm operations. Conflicting task changes require a new proposal. Repeating a confirmed request returns its stored result. If the process dies mid-confirmation, the proposal cannot replay automatically; inspect tasks before recreating it.

History and proposals use a persistent SQLite volume on the assistant server, scoped by user. They synchronize across devices accessing the same server. Access uses HTTPS; SQLite files have restrictive permissions. Use encrypted disks/backups on the Ubuntu host for encryption at rest. Server administrators can access this database. No authentication tokens are stored there. History loads 40 messages at a time with a Load earlier messages button; older messages remain accessible across devices. The latest 20 proposals are displayed. This is a single-instance private backend, not a horizontally scaled service.

Organization returns a suggested order; it does not change the app's established priority sorting. Scheduling suggestions use due dates, estimated minutes and optional scheduled start. A model may ask for missing availability or duration. All scheduling writes remain previews. Due dates are optional. Metadata changes are refused until enabled after the schema migration.

OpenAI uses strict function schemas through Chat Completions. Ollama uses its native `/api/chat` endpoint with a constrained JSON task plan and the same server-side validators. The Ubuntu `qwen2.5:3b` model has passed synthetic create/update smoke checks and user testing. Local requests allow up to six minutes for CPU inference; the prompt avoids duplicating its output schema. Model choice is explicit in configuration. Limits: 20 chat requests per user per hour, 200 model calls across the server per day by default, 12 tool rounds, 10 proposed changes, 4,000 input characters, 1,200 output tokens per round, 250 tasks and bounded task context. Set a separate spending ceiling in the OpenAI project; call counts are not a dollar guarantee.

## Before approval to deploy

1. Export the production PocketBase collections schema and identify its server version. The Dart SDK version does not establish the server version. Verify `tasks.user` is a single relation to `users` and inspect any custom hooks/24-hour cleanup jobs. No cleanup implementation exists in the checked-in Flutter file; existing server behavior has not been changed.
2. Back up PocketBase data/accounts and separately back up each device's Hive boxes before app upgrades. Verify a restore on an isolated staging instance.
3. Apply `pb_migrations/1791676800_task_scheduling.js` to staging using the **same PocketBase version as production**. It adds optional `due_at`, `estimated_minutes`, `category`, `scheduled_at` fields and owner-only access rules. Review existing custom sharing/role rules before replacing them. It does not delete tasks/accounts. There is deliberately no destructive down migration. Roll back app/backend code while retaining additive fields, or restore the verified backup during a coordinated maintenance window.
4. Run tests on staging with two disposable users and verify ownership, real-time events, offline reconnection, and existing cleanup behavior.
5. Configure a server-only `.env`, TLS/Tailscale access, backups, spending ceiling, and the selected AI model. Never send keys or passwords in chat or commit them.
6. Obtain approval before production schema changes or deployment.

## Ubuntu Docker deployment (after approval)

From `backend/` on the Ubuntu host:

```sh
cp .env.example .env
chmod 600 .env
# Fill AI_MODEL and OPENAI_API_KEY using a local server editor.
# Set TASK_SCHEDULING_ENABLED=true only after the migration is applied and verified.
docker compose build
docker compose up -d
docker compose ps
curl http://127.0.0.1:8080/health
```

The service is deliberately published on host loopback only. Keep it private: put a TLS reverse proxy with request-size/connection limits in front of loopback, reachable through your tailnet, or configure Tailscale Serve to proxy `http://127.0.0.1:8080`. Do not enable Funnel or a public Internet port. Verify the phone and every desktop have tailnet access. `100.117.123.116` remains a private Tailscale address. Containers need a route to PocketBase through the Ubuntu host's Tailscale connection; verify reachability from inside the container.

Back up the `assistant-history` volume while using a consistent SQLite backup or while the service is stopped. Keep both PocketBase and assistant backups private and encrypted. SQLite WAL files belong to the database; never copy just the database during active writes.

Build each client with its actual private HTTPS URL:

```sh
flutter run --dart-define=AI_BACKEND_URL=https://YOUR-SERVER.YOUR-TAILNET.ts.net --dart-define=TASK_SCHEDULING_ENABLED=true
```

`AI_BACKEND_URL` and `POCKETBASE_URL` are endpoint configuration, not secrets. Scheduling defaults off so existing PocketBase schemas still support regular tasks. The assistant defaults to a helpful unconfigured state. The existing HTTP PocketBase host is permitted only as a specific platform networking exception; Tailscale protects its private network transport. Move PocketBase to HTTPS and set `POCKETBASE_URL` when that endpoint is available.

## Offline and authentication migration

New tasks and pending changes are user-scoped in Hive. Stable 15-character IDs allow safe create retries after a lost response. Reloading tasks overlays pending edits/deletions. A 30-second timer, foreground resume, and manual sync button retry synchronization. A server deletion with a pending edit is retained for reconciliation rather than silently discarded. Pending edits use local changes when synchronized; concurrent offline edits still need conflict reconciliation in edge cases.

Legacy SharedPreferences authentication moves to platform secure storage, removes the old copy only after verifying the secure write, and uses refresh on launch, foreground resume and every five minutes. Revoked sessions clear and navigate to login. A network outage retains local offline access even if a locally stored token has expired; cloud AI requires a valid session. Keychain on macOS uses the legacy system Keychain without cross-app sharing so a free account can still build locally. iOS uses the app's existing identifier and Keychain group. Windows needs Visual Studio's C++ ATL component for the secure-storage plugin.

The old app used shared Hive caches and unowned pending updates/deletes. Old boxes are preserved. On a successful online load, legacy pending updates/deletes migrate only when the server confirms the record belongs to the current user; user-tagged creates also migrate. Unprovable legacy data stays in the original boxes for manual recovery. **Before first upgrade, synchronize and back up legacy devices. A device upgraded while offline may need one online ownership check before its legacy cache is shown.** Do not uninstall the old iPhone app or clear its data to resolve signing.

## Validation commands

```sh
flutter analyze
flutter test
cd backend
python3 -m unittest discover -s tests -v
# Download a PocketBase binary from its official releases, then run integration tests:
POCKETBASE_TEST_BINARY=/absolute/path/to/pocketbase python3 -m unittest discover -s tests -v
```

Integration tests create and remove their own temporary localhost database; they never connect to production. Without `POCKETBASE_TEST_BINARY`, integration tests explicitly skip. The isolated baseline fixture is under `backend/tests/fixtures`; do not copy it to production.

Sources: [OpenAI function calling](https://developers.openai.com/api/docs/guides/function-calling), [PocketBase authentication](https://pocketbase.io/docs/authentication/), [migrations](https://pocketbase.io/docs/js-migrations/), [API authorization rules](https://pocketbase.io/docs/api-rules-and-filters/), [secure storage](https://pub.dev/packages/flutter_secure_storage).
