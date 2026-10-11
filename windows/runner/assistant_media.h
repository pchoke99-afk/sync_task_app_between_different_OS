#ifndef RUNNER_ASSISTANT_MEDIA_H_
#define RUNNER_ASSISTANT_MEDIA_H_
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <sapi.h>
#include <wrl/client.h>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

// Native input produces drafts only; no audio or images leave this process.
class AssistantMedia {
 public:
  AssistantMedia(flutter::BinaryMessenger* messenger, HWND window);
  ~AssistantMedia();
  bool HandleMessage(UINT message, WPARAM wparam);
 private:
  using Result = flutter::MethodResult<flutter::EncodableValue>;
  void StartSpeech(std::unique_ptr<Result> result);
  void FinishSpeech();
  void PasteImage(std::unique_ptr<Result> result);
  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  Microsoft::WRL::ComPtr<ISpRecognizer> recognizer_;
  Microsoft::WRL::ComPtr<ISpRecoContext> context_;
  Microsoft::WRL::ComPtr<ISpRecoGrammar> grammar_;
  std::unique_ptr<Result> speech_result_;
  std::string transcript_;
  std::thread ocr_worker_;
  std::unique_ptr<Result> image_result_;
  std::vector<uint8_t> image_bytes_;
  std::string image_text_, image_error_;
  ULONG_PTR graphics_token_ = 0;
};
#endif
