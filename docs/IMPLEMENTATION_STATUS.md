# Implementation status

## Current working version

- Flutter 3.47.2 / Dart 3.13.2; branch `feature/ai-assistant-sahur`.
- Floating cute Sahur mascot, opaque Material chat, task proposals and explicit confirmation, paginated conversations, secure sign-in storage, user-scoped offline caches.
- Mac microphone dictation via on-device speech recognition and image paste via local Vision OCR. Both create editable drafts; extracted image text is sent to AI rather than image bytes. Windows now uses native Speech API for dictation and Windows OCR for pasted images. Native media still needs microphone/clipboard acceptance testing on a real Windows device.
- Google Calendar Desktop OAuth on Mac; Windows browser-launch support added. Only primary-calendar busy intervals for 14 days reach the assistant; Google tokens and event titles do not. Desktop credentials and tokens are saved locally via platform secure storage.
- Isolated Ubuntu Compose project `sync-task-ai` runs the assistant and Ollama `qwen2.5:3b`. User deployed it and confirmed working task proposals and Calendar-aware requests. PocketBase bind mounts and existing volumes were preserved.
- Native Ollama constrained JSON replaced unreliable OpenAI-compatible tool parsing. Empty/invalid responses are rejected. Prompt size is reduced and local model calls allow six minutes. On this CPU-only server responses can take minutes.
- The Mac release app was built, signature-verified, installed in Applications with app-bundle backups, and user screenshots confirmed functioning chat and Calendar connection. Native microphone permission and image OCR still need full user acceptance checks.

## Windows distribution

`.github/workflows/windows.yml` analyzes, tests, builds on a Windows x64 runner, and uploads a portable ZIP containing the executable, DLLs, and data. It runs on pushes to the main/feature branches, pull requests, or manual dispatch. Artifacts expire after 30 days. See [Windows setup](WINDOWS.md).

Windows native compilation and runtime behavior must be verified by the Windows workflow and a real Windows computer. The Mac cannot compile the Windows runner. No production backend deployment is performed by the workflow.

## Validation

- Flutter analyze: clean; 19 Flutter tests passed.
- Python: 38 tests discovered; 34 passed, 4 disposable-PocketBase integration checks skipped without the isolated test binary.
- Real Ubuntu model smoke checks passed for synthetic create/update proposals without any PocketBase connection.
- User confirmed live AI and Google Calendar behavior after backend updates.
- No production schema migration was applied. `TASK_SCHEDULING_ENABLED=false`; suggested study dates remain description text. Structured scheduling requires the separate staging/migration review described in [deployment guidance](AI_DEPLOYMENT.md).

## Data and credentials

OAuth JSON, `.env`, tokens, database exports, and local build directories are excluded from Git. GitHub stores application code and assets, not live task data. Back up PocketBase data, hooks, assistant history, and server configuration separately. Confirmations are serialized within one backend instance; multi-task mutations may partially fail, and uncertain writes must not be replayed automatically.

## iPhone

The user declined paid Apple Developer enrollment. No payment or TestFlight upload was performed. Existing bundle identifiers were retained; free development signing requires periodic renewal. [iPhone signing reference](TESTFLIGHT.md).
