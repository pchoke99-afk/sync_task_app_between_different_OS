import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Input stays on the device; only reviewed text is sent to the assistant.
class AssistantImage {
  const AssistantImage({required this.bytes, required this.text});
  final Uint8List bytes;
  final String text;
}

class AssistantMedia {
  const AssistantMedia();
  static const _channel = MethodChannel('sync_task/assistant_media');

  bool get isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  Future<bool> hasClipboardImage() async =>
      await _channel.invokeMethod<bool>('hasClipboardImage') ?? false;

  Future<AssistantImage?> pasteImage() async {
    final data = await _channel.invokeMapMethod<String, dynamic>('pasteImage');
    if (data == null) return null;
    return AssistantImage(
      bytes: data['bytes'] as Uint8List,
      text: data['text'] as String,
    );
  }

  Future<String?> dictate() => _channel.invokeMethod<String>('startSpeech');
  Future<void> stopDictation() => _channel.invokeMethod<void>('stopSpeech');
}
