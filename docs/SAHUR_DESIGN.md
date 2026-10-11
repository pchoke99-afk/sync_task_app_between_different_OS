# Tung Tung Sahur chat design

The assistant UI uses a friendly wooden Tung Tung Sahur mascot, amber highlights, dark brown surfaces, a welcome illustration, assistant message avatars, and suggested prompts. The theme is scoped to the chat screen; the existing task UI and completion animations remain intact. All task changes still require the same explicit confirmation.

Asset: `assets/assistant/tung_tung_sahur.png` (1024 × 1536 RGBA PNG, with verified transparent pixels). Generated with the built-in ImageGen tool. The original generated image was retained and copied into the repository; no API key was required for asset generation. The chat service itself still requires server-side AI configuration.

Final generation prompt:

> Use case: stylized-concept. Asset type: transparent PNG mascot for an existing Flutter task assistant chat UI. Primary request: recognizable Tung Tung Tung Sahur meme character as a friendly task assistant. Subject: anthropomorphic upright cylindrical wooden log, warm brown polished wood grain, oversized round expressive eyes, comical long nose and smiling human-like mouth, thin wooden arms and legs, holding his iconic simple wooden baseball bat down peacefully by his side. Full body, front three-quarter view, centered with comfortable clear padding; friendly and slightly goofy, high-quality stylized 3D game render, crisp silhouette legible as a small chat avatar. Warm amber lighting. Constraints: genuinely transparent background, no floor, no environment, no text, no watermark, one character only. Keep the recognizable wooden-log meme appearance.

The phone preview uses the actual Flutter chat widgets with mock conversation data and the bundled mascot. No production tasks or authentication were used to render it.
