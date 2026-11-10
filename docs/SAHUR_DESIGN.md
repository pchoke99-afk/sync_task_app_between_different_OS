# Halo appearance

Tasks, sign-in, and chat share a dark navy Material theme with blue accents, defined in `lib/app_theme.dart`.

`AssistantRings` draws exactly three nested blue halo rings with a soft glow. The same vector widget appears in the floating chat button, chat header, welcome screen, and assistant message avatars. No mascot image or image decoding is required. A repaint boundary isolates animation; the painter listens directly to its controller without rebuilding the chat. Motion runs only while working, listening, or hovering over the launcher and respects reduced-motion settings.

Task completion keeps confetti. The dancing GIF, its delayed state updates, the old mascot PNG, and unused Lottie/Cupertino icon dependencies have been removed. Task synchronization, calendar access, dictation, clipboard import, and explicit task-change confirmation retain their existing behavior.
