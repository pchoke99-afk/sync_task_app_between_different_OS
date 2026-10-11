# Download and run on Windows

## Download

1. Open https://github.com/pchoke99-afk/sync_task_app_between_different_OS/actions/workflows/windows.yml.
2. Select a successful **Windows download** run for the branch you want. While the changes are under review, choose `feature/ai-assistant-sahur`.
3. Sign in to GitHub and download **Sync-Task-Windows-x64** under Artifacts.
4. Extract the downloaded archive and then extract `Sync-Task-Windows-x64.zip`. Keep the entire extracted folder together: the `.exe`, DLLs, and `data` directory are all required.
5. Run `sync_task_app.exe`. This portable ZIP is for Windows x64; it is not a Store installer and is not code-signed.

Artifacts expire after 30 days. After this workflow is merged to `main`, use **Run workflow** to make a fresh download if necessary. Never disable Windows security protections to run an unexpected file.

If Windows reports a missing Visual C++ runtime, install Microsoft's official x64 redistributable: https://aka.ms/vs/17/release/vc_redist.x64.exe.

## Connect to your existing server

Install Tailscale from its official site on Windows and sign in to the same tailnet as your Ubuntu server. PocketBase remains at `http://100.117.123.116:8090`. Use the same task account to synchronize tasks; each computer keeps its own offline cache.

The AI backend remains private on Ubuntu loopback. Open PowerShell and leave this connection running while using the chatbot:

```powershell
ssh -N -L 18080:127.0.0.1:8080 n8@100.117.123.116
```

If `ssh` is unavailable, install the Windows **OpenSSH Client** optional feature. Authenticate to your Ubuntu account. Closing this PowerShell connection disconnects the AI assistant; it does not delete tasks. The ZIP is built with `AI_BACKEND_URL=http://127.0.0.1:18080`. Never expose Ollama or remove the assistant's loopback restriction just to connect a client.

## Supported features

- Task sign-in, synchronization, offline task editing, and the cute Sahur chat UI.
- AI task proposals and explicit approval before task changes.
- Google Calendar busy-time access using Desktop OAuth and the Windows default browser. Connect separately on Windows; the Mac's Keychain and Google tokens are not copied. Enter the client ID and client secret from your local Desktop OAuth JSON in the app's setup dialog. Tokens are saved using the Windows secure-storage provider.
- Calendar reads your primary calendar's busy intervals for the next 14 days, never creates or edits Google events. Add your Google account as a test user while the OAuth app is in Testing. Google may require reconnection when test-mode authorization expires.
- Microphone dictation and pasted-image OCR currently use macOS native frameworks and are not available on Windows in this version.
- Scheduled times are advice in task descriptions while `TASK_SCHEDULING_ENABLED=false`; enabling structured scheduling requires a separately reviewed PocketBase migration.

## Build on Windows yourself

Install Flutter 3.47.2 and Visual Studio with **Desktop development with C++**, then:

```powershell
git clone https://github.com/pchoke99-afk/sync_task_app_between_different_OS.git
cd sync_task_app_between_different_OS
git switch feature/ai-assistant-sahur
flutter pub get
flutter analyze
flutter test
flutter build windows --release --dart-define=AI_BACKEND_URL=http://127.0.0.1:18080
```

Run `build/windows/x64/runner/Release/sync_task_app.exe` with its neighboring DLLs and `data` directory. Windows builds run on Windows, not on the Mac. See https://docs.flutter.dev/platform-integration/windows/building.

## Keep secrets and production data separate

Do not commit OAuth JSON files, `.env` files, access/refresh tokens, database exports, or server backups. The build needs no Google or AI API secrets. PocketBase data remains under `/DATA/AppData/pocketbase/pb_data` on Ubuntu, and this workflow does not connect to or deploy anything on that server.
