#include "assistant_media.h"
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <gdiplus.h>
#include <objidl.h>
#include <coroutine>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.Streams.h>
#include <algorithm>
#include <chrono>
#include <stdexcept>

namespace {
constexpr UINT kSpeechMessage = WM_APP + 42;
constexpr UINT kImageMessage = WM_APP + 43;
constexpr UINT_PTR kSpeechTimer = 4242;
constexpr size_t kMaxImageBytes = 10 * 1024 * 1024;
void Check(HRESULT value) { if (FAILED(value)) throw std::runtime_error("Native input unavailable"); }
std::string Utf8(const wchar_t* text) {
  if (!text) return {};
  int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) return {};
  std::string output(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, output.data(), size, nullptr, nullptr);
  output.pop_back();
  return output;
}
struct ClipboardLock {
  explicit ClipboardLock(HWND hwnd) { if (!OpenClipboard(hwnd)) throw std::runtime_error("Clipboard is busy. Try again."); }
  ~ClipboardLock() { CloseClipboard(); }
};
std::vector<uint8_t> ClipboardPng(HWND window) {
  ClipboardLock lock(window);
  UINT png = RegisterClipboardFormatW(L"PNG");
  if (IsClipboardFormatAvailable(png)) {
    auto memory = GetClipboardData(png);
    size_t size = GlobalSize(memory);
    if (!size || size > kMaxImageBytes) throw std::runtime_error("Image must be smaller than 10 MB.");
    auto* bytes = static_cast<uint8_t*>(GlobalLock(memory));
    if (!bytes) throw std::runtime_error("Could not read clipboard image.");
    std::vector<uint8_t> copy(bytes, bytes + size);
    GlobalUnlock(memory);
    return copy;
  }
  auto bitmap_handle = static_cast<HBITMAP>(GetClipboardData(CF_BITMAP));
  if (!bitmap_handle) throw std::runtime_error("Copy an image or screenshot first.");
  Gdiplus::Bitmap bitmap(bitmap_handle, nullptr);
  if (bitmap.GetLastStatus() != Gdiplus::Ok || bitmap.GetWidth() > 8192 || bitmap.GetHeight() > 8192)
    throw std::runtime_error("Image dimensions must be at most 8192 pixels.");
  // The standard Windows PNG encoder; no external executable or upload.
  const CLSID png_encoder = {0x557cf406, 0x1a04, 0x11d3, {0x9a,0x73,0x00,0x00,0xf8,0x1e,0xf3,0x2e}};
  Microsoft::WRL::ComPtr<IStream> stream;
  Check(CreateStreamOnHGlobal(nullptr, TRUE, &stream));
  if (bitmap.Save(stream.Get(), &png_encoder) != Gdiplus::Ok) throw std::runtime_error("Could not encode image.");
  STATSTG stat{};
  Check(stream->Stat(&stat, STATFLAG_NONAME));
  if (stat.cbSize.QuadPart > kMaxImageBytes) throw std::runtime_error("Image must be smaller than 10 MB.");
  HGLOBAL memory = nullptr;
  Check(GetHGlobalFromStream(stream.Get(), &memory));
  auto* bytes = static_cast<uint8_t*>(GlobalLock(memory));
  if (!bytes) throw std::runtime_error("Could not read image.");
  std::vector<uint8_t> copy(bytes, bytes + static_cast<size_t>(stat.cbSize.QuadPart));
  GlobalUnlock(memory);
  return copy;
}
std::string RecognizeImage(const std::vector<uint8_t>& bytes) {
  using namespace winrt::Windows::Storage::Streams;
  using namespace winrt::Windows::Graphics::Imaging;
  using namespace winrt::Windows::Media::Ocr;
  InMemoryRandomAccessStream stream;
  DataWriter writer(stream);
  writer.WriteBytes(bytes);
  writer.StoreAsync().get();
  writer.DetachStream();
  stream.Seek(0);
  auto decoder = BitmapDecoder::CreateAsync(stream).get();
  if (decoder.PixelWidth() > 8192 || decoder.PixelHeight() > 8192)
    throw std::runtime_error("Image dimensions must be at most 8192 pixels.");
  auto engine = OcrEngine::TryCreateFromUserProfileLanguages();
  if (!engine) throw std::runtime_error("Install a Windows language pack with OCR support in Settings.");
  auto transform = BitmapTransform();
  double scale = std::min(1.0, static_cast<double>(OcrEngine::MaxImageDimension()) /
                                  std::max(decoder.PixelWidth(), decoder.PixelHeight()));
  transform.ScaledWidth(std::max(1u, static_cast<unsigned>(decoder.PixelWidth() * scale)));
  transform.ScaledHeight(std::max(1u, static_cast<unsigned>(decoder.PixelHeight() * scale)));
  auto bitmap = decoder.GetSoftwareBitmapAsync(BitmapPixelFormat::Bgra8, BitmapAlphaMode::Ignore,
      transform, ExifOrientationMode::RespectExifOrientation, ColorManagementMode::DoNotColorManage).get();
  return winrt::to_string(engine.RecognizeAsync(bitmap).get().Text());
}
}

AssistantMedia::AssistantMedia(flutter::BinaryMessenger* messenger, HWND window) : window_(window) {
  Gdiplus::GdiplusStartupInput input;
  Gdiplus::GdiplusStartup(&graphics_token_, &input, nullptr);
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "sync_task/assistant_media", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "hasClipboardImage") {
      result->Success(flutter::EncodableValue(IsClipboardFormatAvailable(CF_BITMAP) != FALSE ||
          IsClipboardFormatAvailable(RegisterClipboardFormatW(L"PNG")) != FALSE));
    } else if (call.method_name() == "pasteImage") {
      PasteImage(std::move(result));
    } else if (call.method_name() == "startSpeech") {
      StartSpeech(std::move(result));
    } else if (call.method_name() == "stopSpeech") {
      FinishSpeech(); result->Success();
    } else if (call.method_name() == "openGoogleUrl") {
      const auto* url = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
      if (!url || url->rfind("https://accounts.google.com/", 0) != 0) {
        result->Error("url", "Invalid Google sign-in address."); return;
      }
      auto wide = winrt::to_hstring(*url);
      auto opened = ShellExecuteW(nullptr, L"open", wide.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
      if (reinterpret_cast<INT_PTR>(opened) <= 32) result->Error("browser", "Could not open your browser.");
      else result->Success();
    } else result->NotImplemented();
  });
}
AssistantMedia::~AssistantMedia() {
  channel_->SetMethodCallHandler(nullptr);
  KillTimer(window_, kSpeechTimer);
  if (grammar_) grammar_->SetDictationState(SPRS_INACTIVE);
  if (ocr_worker_.joinable()) ocr_worker_.join();
  if (graphics_token_) Gdiplus::GdiplusShutdown(graphics_token_);
}
void AssistantMedia::StartSpeech(std::unique_ptr<Result> result) {
  if (speech_result_) { result->Error("speech", "Already listening."); return; }
  try {
    Check(CoCreateInstance(CLSID_SpSharedRecognizer, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&recognizer_)));
    Check(recognizer_->CreateRecoContext(&context_));
    Check(context_->SetNotifyWindowMessage(window_, kSpeechMessage, 0, 0));
    Check(context_->SetInterest(SPFEI(SPEI_RECOGNITION), SPFEI(SPEI_RECOGNITION)));
    Check(context_->CreateGrammar(1, &grammar_));
    Check(grammar_->LoadDictation(nullptr, SPLO_STATIC));
    Check(grammar_->SetDictationState(SPRS_ACTIVE));
    if (!SetTimer(window_, kSpeechTimer, 45000, nullptr)) throw std::runtime_error("Could not start speech timer.");
    transcript_.clear();
    speech_result_ = std::move(result);
  } catch (...) {
    grammar_.Reset(); context_.Reset(); recognizer_.Reset();
    result->Error("speech", "Enable microphone access for desktop apps and install a Windows speech language in Settings, then try again.");
  }
}
void AssistantMedia::FinishSpeech() {
  if (!speech_result_) return;
  KillTimer(window_, kSpeechTimer);
  if (grammar_) grammar_->SetDictationState(SPRS_INACTIVE);
  grammar_.Reset(); context_.Reset(); recognizer_.Reset();
  speech_result_->Success(flutter::EncodableValue(transcript_));
  speech_result_.reset();
}
void AssistantMedia::PasteImage(std::unique_ptr<Result> result) {
  if (image_result_) { result->Error("clipboard", "An image is already being read."); return; }
  try { image_bytes_ = ClipboardPng(window_); }
  catch (const std::exception& error) { result->Error("clipboard", error.what()); return; }
  if (ocr_worker_.joinable()) ocr_worker_.join();
  image_result_ = std::move(result);
  image_text_.clear(); image_error_.clear();
  ocr_worker_ = std::thread([this] {
    try {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      image_text_ = RecognizeImage(image_bytes_);
      winrt::uninit_apartment();
    } catch (const std::exception& error) { image_error_ = error.what(); }
      catch (...) { image_error_ = "Windows could not read this image. Check your OCR language pack."; }
    PostMessage(window_, kImageMessage, 0, 0);
  });
}
bool AssistantMedia::HandleMessage(UINT message, WPARAM wparam) {
  if (message == kSpeechMessage && context_) {
    SPEVENT event{}; ULONG count = 0;
    while (context_->GetEvents(1, &event, &count) == S_OK && count) {
      if (event.eEventId == SPEI_RECOGNITION) {
        auto* recognition = reinterpret_cast<ISpRecoResult*>(event.lParam);
        wchar_t* text = nullptr;
        if (SUCCEEDED(recognition->GetText(static_cast<ULONG>(SP_GETWHOLEPHRASE), static_cast<ULONG>(SP_GETWHOLEPHRASE), TRUE, &text, nullptr))) {
          if (!transcript_.empty()) transcript_ += " ";
          transcript_ += Utf8(text); CoTaskMemFree(text);
        }
      }
      if (event.elParamType == SPET_LPARAM_IS_OBJECT && event.lParam)
        reinterpret_cast<IUnknown*>(event.lParam)->Release();
      else if ((event.elParamType == SPET_LPARAM_IS_POINTER || event.elParamType == SPET_LPARAM_IS_STRING) && event.lParam)
        CoTaskMemFree(reinterpret_cast<void*>(event.lParam));
    }
    return true;
  }
  if (message == WM_TIMER && wparam == kSpeechTimer) { FinishSpeech(); return true; }
  if (message == kImageMessage && image_result_) {
    if (ocr_worker_.joinable()) ocr_worker_.join();
    if (!image_error_.empty()) image_result_->Error("ocr", image_error_);
    else image_result_->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("bytes"), flutter::EncodableValue(image_bytes_)},
        {flutter::EncodableValue("text"), flutter::EncodableValue(image_text_)}}));
    image_result_.reset(); image_bytes_.clear();
    return true;
  }
  return false;
}
