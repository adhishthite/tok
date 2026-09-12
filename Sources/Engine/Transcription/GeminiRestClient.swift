import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

struct GeminiRestClient {
  /// The documented ceiling for an inline generateContent request body is 20 MB. Audio is
  /// 16 kHz mono PCM (32 KB per second) wrapped in base64, which adds a third, so the cap
  /// lands near seven and a half minutes of speech. Fail before the encode and the upload
  /// instead of after a 400 that costs the whole round trip.
  static let maxInlineAudioBytes = 20 * 1024 * 1024

  /// Seconds of 16 kHz 16-bit mono audio that fit under maxInlineAudioBytes once the WAV
  /// header and base64 expansion are counted: about 491 s. The engine caps every turn here.
  static let maxInlineAudioSeconds: Double =
    Double(maxInlineAudioBytes * 3 / 4 - 44) / 32_000.0

  /// Bytes the base64 audio part will occupy for a PCM buffer of this size. 44 is the WAV
  /// header WAVEncoder prepends; base64 emits 4 characters per 3 input bytes, padded.
  static func inlineAudioBytes(pcmByteCount: Int) -> Int {
    let wavBytes = pcmByteCount + 44
    return ((wavBytes + 2) / 3) * 4
  }

  @discardableResult
  static func transcribe(
    pcmData: Data, apiKey: String, model: String, languageCodes: [String] = [],
    customVocabulary: [String] = [], smartTranscription: Bool = false, isRetry: Bool = false,
    completion:
      @escaping (
        Result<(text: String, latencyMs: Double, inputTokens: Int?, outputTokens: Int?), Error>
      ) -> Void
  ) -> CancellableRequest {
    let request = CancellableRequest()
    perform(
      pcmData: pcmData, apiKey: apiKey, model: model, languageCodes: languageCodes,
      customVocabulary: customVocabulary, smartTranscription: smartTranscription, isRetry: isRetry,
      scope: request, completion: completion)
    return request
  }

  static func perform(
    pcmData: Data,
    apiKey: String,
    model: String,
    languageCodes: [String] = [],
    customVocabulary: [String] = [],
    smartTranscription: Bool = false,
    isRetry: Bool = false,
    scope: CancellableRequest,
    completion:
      @escaping (
        Result<(text: String, latencyMs: Double, inputTokens: Int?, outputTokens: Int?), Error>
      ) -> Void
  ) {
    guard !scope.isCancelled else { return }
    let startTime = ProcessInfo.processInfo.systemUptime
    guard !apiKey.isEmpty else {
      completion(
        .failure(
          NSError(
            domain: "Tok", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Add a Gemini API key in Tok Settings."])))
      return
    }

    // Size the request before building it: a turn past the inline limit can only fail, and
    // encoding megabytes first would delay that failure by seconds.
    guard inlineAudioBytes(pcmByteCount: pcmData.count) <= maxInlineAudioBytes else {
      Log.warn(
        "REST",
        "Recording is \(pcmData.count / 1024) KB of PCM, past the inline request limit - not sending."
      )
      completion(.failure(RESTResponse.recordingTooLongError()))
      return
    }

    let wavData = WAVEncoder.encode(from: pcmData, sampleRate: 16000, channels: 1)
    let base64Wav = wavData.base64EncodedString()

    let urlString =
      "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
    guard let url = URL(string: urlString) else {
      completion(
        .failure(
          NSError(
            domain: "Tok", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Invalid REST URL."])))
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
    request.timeoutInterval = 10.0

    // Base64's alphabet (A-Za-z0-9+/=) needs no JSON escaping, so the envelope is spliced
    // around the audio payload directly - running the multi-MB string through
    // JSONSerialization would escape-scan and copy it a second time for nothing. The
    // small prompt/system strings still go through JSONSerialization for real escaping.
    let audioPart = "{\"inlineData\":{\"mimeType\":\"audio/wav\",\"data\":\"" + base64Wav + "\"}}"

    let body: String
    if model.contains("transcribe") {
      // Dedicated STT Foundation Model (Pure Audio, zero developer instruction requirement)
      body = "{\"contents\":[{\"parts\":[" + audioPart + "]}]}"
    } else {
      // General Multimodal LLM (Prompt & System Instruction guided)
      // The live route polishes only when SMART transcription is on. Asking the fallback to
      // polish regardless made the same speech come back differently depending on which
      // route won the race, so the prompt now follows the same setting.
      var promptText =
        smartTranscription
        ? "Transcribe this audio precisely. Fix punctuation, capitalization, and grammar. Remove filler words (um, uh, you know). Preserve technical terms, acronyms, code snippets, numbers, and formatting. Output ONLY the polished transcription without commentary, explanations, or quotes."
        : "Transcribe this audio verbatim. Keep every spoken word, including fillers. Add only standard punctuation and capitalization. Output ONLY the transcription."
      var systemText =
        smartTranscription
        ? "You are a professional voice dictation engine. Transcribe and polish the spoken audio into clean text. Output ONLY the final text."
        : "You are a verbatim voice transcription engine. Write exactly what was said. Output ONLY the final text."

      if !languageCodes.isEmpty {
        let langList = languageCodes.joined(separator: ", ")
        promptText += "\nTarget language(s): \(langList)"
        systemText += "\nTarget language(s): \(langList)"
      }

      if !customVocabulary.isEmpty {
        let vocabList = customVocabulary.joined(separator: ", ")
        promptText += "\nCustom vocabulary & technical terms to recognize accurately: \(vocabList)"
        systemText += "\nCustom vocabulary: \(vocabList)"
      }

      guard let promptJson = jsonFragment(["text": promptText]),
        let systemJson = jsonFragment(["parts": [["text": systemText]]])
      else {
        completion(
          .failure(
            NSError(
              domain: "Tok", code: -3,
              userInfo: [NSLocalizedDescriptionKey: "Failed to serialize REST JSON."])))
        return
      }
      body =
        "{\"contents\":[{\"parts\":[" + audioPart + "," + promptJson + "]}],"
        + "\"generationConfig\":{\"temperature\":0},"
        + "\"systemInstruction\":" + systemJson + "}"
    }

    request.httpBody = Data(body.utf8)

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
      scope.completedTask()
      guard !scope.isCancelled else { return }
      let elapsedMs = (ProcessInfo.processInfo.systemUptime - startTime) * 1000.0

      if let error = error {
        completion(.failure(error))
        return
      }

      guard let data = data else {
        completion(
          .failure(
            NSError(
              domain: "Tok", code: -4,
              userInfo: [NSLocalizedDescriptionKey: "No data received from Gemini REST API."])))
        return
      }

      // 429: per-minute throttles carry a short retryDelay - honor it once. Only a real
      // daily/hard quota (quotaId contains "PerDay") is terminal; anything else clears on
      // its own and is worth one retry if the wait is short.
      if (response as? HTTPURLResponse)?.statusCode == 429 {
        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        if bodyStr.contains("PerDay") {
          completion(.failure(RESTResponse.dailyQuotaError()))
          return
        }
        let delay =
          Self.retryDelaySeconds(from: data, response: response as? HTTPURLResponse) ?? 2.0
        if !isRetry, delay <= 8.0 {
          Log.warn(
            "REST",
            "429 rate limited on \(model) - retrying once after \(String(format: "%.1f", delay))s.")
          scope.schedule(after: max(0, delay)) {
            Self.perform(
              pcmData: pcmData, apiKey: apiKey, model: model, languageCodes: languageCodes,
              customVocabulary: customVocabulary, smartTranscription: smartTranscription,
              isRetry: true, scope: scope, completion: completion)
          }
          return
        }
        completion(.failure(RESTResponse.error(code: 429)))
        return
      }

      // Other non-2xx statuses get named failures instead of a JSON-parse error whose
      // text buries the cause. 400/401/403 are key problems (an invalid API key comes
      // back as 400 API_KEY_INVALID), 404 is a wrong/retired model name - none of them
      // is retryable, so fail immediately with the fix in the message.
      if let status = (response as? HTTPURLResponse)?.statusCode, !(200...299).contains(status) {
        completion(.failure(RESTResponse.error(code: status)))
        return
      }

      let json: [String: Any]
      do {
        json = try RESTResponse.decode(data)
      } catch {
        completion(.failure(error))
        return
      }

      // API-metered usage rides on every generateContent response.
      var inputTokens: Int? = nil
      var outputTokens: Int? = nil
      if let usage = json["usageMetadata"] as? [String: Any] {
        inputTokens = usage["promptTokenCount"] as? Int
        outputTokens = usage["candidatesTokenCount"] as? Int
      }

      // One shared reader for both REST routes: it joins every non-thought part and reports
      // the finish reason, so a truncated or blocked answer can no longer pass as a whole one.
      switch GenerateContentDecoder.decode(json) {
      case .text(let text):
        // The REST path prompts a general-purpose model to transcribe; its documented
        // failure mode is answering instead of transcribing. Gate before this text
        // ever reaches insertion (Feature: RestValidationGate).
        let cleanedText = RestValidationGate.clean(text)
        if let reason = RestValidationGate.rejectionReason(cleanedText) {
          Log.warn(
            "GATE", "REST result rejected (\(reason)); \(cleanedText.count) characters withheld.")
          completion(
            .failure(
              NSError(
                domain: "Tok", code: -7,
                userInfo: [
                  NSLocalizedDescriptionKey: "REST result rejected by validation gate: \(reason)"
                ])))
        } else {
          completion(
            .success(
              (
                text: cleanedText, latencyMs: elapsedMs, inputTokens: inputTokens,
                outputTokens: outputTokens
              )))
        }
      case .empty:
        // Speech model returned empty transcription (e.g. silent or non-speech audio)
        completion(
          .success(
            (text: "", latencyMs: elapsedMs, inputTokens: inputTokens, outputTokens: outputTokens)
          ))
      case .truncated:
        Log.warn("REST", "Gemini stopped before the transcription finished; discarding it.")
        completion(.failure(RESTResponse.truncatedError()))
      case .blocked(let reason):
        Log.warn("REST", "Gemini blocked this transcription (\(reason)); nothing pasted.")
        completion(.failure(RESTResponse.blockedError()))
      case .malformed:
        completion(
          .failure(
            NSError(
              domain: "Tok", code: -6,
              userInfo: [
                NSLocalizedDescriptionKey: "Could not extract candidate text from response."
              ])))
      }
    }

    scope.start(task)
  }

  /// Serializes one small object to a JSON string for splicing into the hand-built envelope.
  private static func jsonFragment(_ obj: Any) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Extracts a short retry hint from a 429: the `Retry-After` header (seconds), else the
  /// google.rpc.RetryInfo "retryDelay": "2s" detail in the response body. nil if neither parses.
  private static func retryDelaySeconds(from data: Data, response: HTTPURLResponse?) -> Double? {
    if let header = response?.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(header)
    {
      return seconds
    }
    guard let body = String(data: data, encoding: .utf8) else { return nil }
    if let range = body.range(of: #""retryDelay"\s*:\s*"([0-9.]+)s""#, options: .regularExpression)
    {
      let match = String(body[range])
      let digits = match.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber || $0 == "." })
      return Double(digits)
    }
    return nil
  }
}
