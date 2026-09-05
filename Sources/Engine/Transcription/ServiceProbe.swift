import Foundation

public enum ServiceProbe {
  public static func validate(configuration: EngineConfiguration) async throws {
    guard !configuration.geminiApiKey.isEmpty else {
      throw NSError(
        domain: "Tok.Setup", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Enter an API key first."])
    }
    let client = GeminiLiveClient(
      apiKey: configuration.geminiApiKey, model: configuration.geminiLiveModel,
      smartTranscription: configuration.smartTranscription,
      languageCodes: configuration.languageCodes,
      vadMode: configuration.vadMode, vadSilenceMs: configuration.vadSilenceMs,
      endpointAligned: configuration.wsEndpointAligned)
    defer { client.shutdown() }
    client.connect()
    for _ in 0..<120 {
      try Task.checkCancellation()
      if client.isReady { return }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw NSError(
      domain: "Tok.Setup", code: 2,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Could not connect. Check your API key, live model, and internet connection."
      ])
  }
}
