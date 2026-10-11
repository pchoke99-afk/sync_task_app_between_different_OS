import Cocoa
import FlutterMacOS
import Speech
import AVFoundation
import Vision

class MainFlutterWindow: NSWindow {
  private var assistantMedia: AssistantMediaBridge?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    assistantMedia = AssistantMediaBridge(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}


/// Native, user-initiated input. Audio and images never go to the AI provider.
private final class AssistantMediaBridge {
  private let channel: FlutterMethodChannel
  private let engine = AVAudioEngine()
  private var task: SFSpeechRecognitionTask?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var completion: FlutterResult?
  private var transcript = ""
  private var timer: Timer?
  private var hasTap = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "sync_task/assistant_media", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "openGoogleUrl":
        guard let text = call.arguments as? String, let url = URL(string: text),
              url.scheme == "https", url.host == "accounts.google.com" else {
          result(FlutterError(code: "url", message: "Invalid Google sign-in address.", details: nil)); return
        }
        if NSWorkspace.shared.open(url) { result(nil) }
        else { result(FlutterError(code: "browser", message: "Could not open your browser.", details: nil)) }
      case "hasClipboardImage":
        result(NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil))
      case "pasteImage": self.pasteImage(result)
      case "startSpeech": self.startSpeech(result)
      case "stopSpeech": self.finishSpeech(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private func pasteImage(_ result: @escaping FlutterResult) {
    guard let images = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
          let image = images.first,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
      result(FlutterError(code: "clipboard", message: "Copy an image or screenshot first.", details: nil)); return
    }
    guard png.count <= 10 * 1024 * 1024, bitmap.pixelsWide <= 8192, bitmap.pixelsHigh <= 8192 else {
      result(FlutterError(code: "image_size", message: "Use an image smaller than 10 MB and 8192 pixels.", details: nil)); return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(data: png).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        DispatchQueue.main.async { result(["bytes": FlutterStandardTypedData(bytes: png), "text": text]) }
      } catch {
        DispatchQueue.main.async { result(FlutterError(code: "ocr", message: "Could not read this image. Try another screenshot.", details: nil)) }
      }
    }
  }

  private func startSpeech(_ result: @escaping FlutterResult) {
    guard completion == nil else { result(FlutterError(code: "busy", message: "Recording is already active.", details: nil)); return }
    completion = result
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      guard let self = self else { return }
      guard status == .authorized else {
        DispatchQueue.main.async { self.finishSpeech(error: "Allow speech recognition in System Settings to dictate.") }; return
      }
      AVCaptureDevice.requestAccess(for: .audio) { allowed in
        DispatchQueue.main.async {
          guard self.completion != nil else { return }
          guard allowed else { self.finishSpeech(error: "Allow microphone access in System Settings to dictate."); return }
          self.beginRecording()
        }
      }
    }
  }

  private func beginRecording() {
    guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable,
          recognizer.supportsOnDeviceRecognition else {
      finishSpeech(error: "On-device dictation is unavailable for this language. Enable or download dictation in macOS Settings, or type your message."); return
    }
    transcript = ""
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    self.request = request
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { finishSpeech(error: "No microphone is available."); return }
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
    hasTap = true
    task = recognizer.recognitionTask(with: request) { [weak self] response, error in
      DispatchQueue.main.async {
        guard let self = self, self.completion != nil else { return }
        if let response = response { self.transcript = response.bestTranscription.formattedString }
        if response?.isFinal == true { self.finishSpeech() }
        else if error != nil { self.finishSpeech(error: self.transcript.isEmpty ? "Dictation stopped. Please try again." : nil) }
      }
    }
    do { engine.prepare(); try engine.start() }
    catch { finishSpeech(error: "Could not start the microphone."); return }
    timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in self?.finishSpeech() }
  }

  private func finishSpeech(error: String? = nil) {
    let callback = completion
    completion = nil
    timer?.invalidate(); timer = nil
    engine.stop()
    if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
    request?.endAudio(); request = nil
    task?.cancel(); task = nil
    if let error = error { callback?(FlutterError(code: "speech", message: error, details: nil)) }
    else { callback?(transcript) }
  }
}
