# Sync Task App

A Flutter task manager for desktop and mobile, synchronized through PocketBase. Tung Tung Sahur helps create and update tasks using a self-hosted Ollama chatbot; changes are proposed for review and require confirmation before saving.

## Windows download

[Download a Windows build from GitHub Actions](https://github.com/pchoke99-afk/sync_task_app_between_different_OS/actions/workflows/windows.yml).

Choose a successful **Windows download** run, download **Sync-Task-Windows-x64** under Artifacts, and extract both ZIP layers. Keep the executable, DLLs, and `data` folder together. While this work is on its feature branch, select `feature/ai-assistant-sahur`.

[Windows setup and server connection](docs/WINDOWS.md) covers Tailscale, the SSH tunnel, Google Calendar, prerequisites, and building locally. Windows builds are produced on a Windows runner. Microphone dictation and pasted-image OCR are currently Mac-only.

## Desktop development

Use Flutter **3.47.2** (Dart 3.13.2) and the platform's native build tools.

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d macos --dart-define=AI_BACKEND_URL=http://127.0.0.1:18080
```

Run the AI tunnel in a separate terminal:

```sh
ssh -N -L 18080:127.0.0.1:8080 n8@100.117.123.116
```

The default PocketBase address is `http://100.117.123.116:8090`, reachable through your Tailscale network. `POCKETBASE_URL` and `AI_BACKEND_URL` can be overridden with Flutter `--dart-define` arguments. The AI endpoint must be HTTPS or local loopback HTTP.

## Assistant and Calendar

- A floating Sahur mascot opens chat; approved proposals create, update, complete, or delete tasks.
- Ubuntu runs only the Python assistant backend and Ollama. The current local model is `qwen2.5:3b`; no paid AI API key is required. CPU inference may take several minutes.
- Google Calendar uses **Desktop OAuth**, not an API key. It reads only primary-calendar busy times for 14 days. Google credentials and tokens stay in each desktop's secure storage; only validated busy intervals are sent to the assistant.
- Mac dictation uses on-device speech recognition; image paste uses local OCR and sends extracted text, not images. The current model is not a vision model.
- Scheduling metadata remains disabled on production until a separate schema migration is approved. Study times can be proposed in task descriptions.

## Server updates

On the **Mac**, upload only the backend source:

```sh
scp backend/service.py n8@100.117.123.116:services/sync-task-ai/
```

On **Ubuntu**, update only the assistant container:

```sh
cd ~/services/sync-task-ai
sudo docker compose -p sync-task-ai build assistant
sudo docker compose -p sync-task-ai up -d --no-deps assistant
```

These commands retain Docker volumes and do not mount, replace, or migrate PocketBase data. Back up production data and configurations separately. Never commit `.env`, OAuth JSON files, tokens, or databases.

## Verification and references

```sh
cd backend
python3 -m unittest discover -s tests
```

Backend tests isolate fake task data and temporary history. Real PocketBase integration checks require an explicitly configured disposable test instance. `backend/smoke_ollama.py` checks a real local model against synthetic tasks without connecting to production PocketBase.

- [Deployment and migration guidance](docs/AI_DEPLOYMENT.md)
- [Implementation status](docs/IMPLEMENTATION_STATUS.md)
- [Free iPhone signing](docs/TESTFLIGHT.md)
- [Flutter Windows packaging](https://docs.flutter.dev/platform-integration/windows/building)
