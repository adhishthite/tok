import Foundation

/// Talks to TypeSafe's Jev API: one judgment request (`ask`) and one availability probe
/// (`probe`). Always off the paste path: called only from `JudgmentService`'s own queue, the
/// vocabulary analyzer's offline task, and `CorrectionWatcher`'s worker queue - never
/// `sessionQueue`, never main.
final class TypeSafeClient: JudgmentTransport {
  static let systemOneURL = URL(string: "https://api.typesafe.ai/v1/systemone")!
  static let modelsURL = URL(string: "https://api.typesafe.ai/v1/models")!
  /// Off-path uses only: a slow judgment must never hold up a real dictation.
  static let timeoutSeconds = 5.0

  private let apiKey: String
  private let session: URLSession

  init(apiKey: String) {
    self.apiKey = apiKey
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = Self.timeoutSeconds
    configuration.timeoutIntervalForResource = Self.timeoutSeconds
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    self.session = URLSession(configuration: configuration)
  }

  @discardableResult
  func ask(
    state: JudgmentValue, questions: [String: JudgmentQuestion], label: String,
    completion: @escaping (Result<JudgmentResponse, TypeSafeError>) -> Void
  ) -> CancellableRequest {
    let scope = CancellableRequest()
    guard !apiKey.isEmpty else {
      completion(.failure(.unavailable))
      return scope
    }
    var request = URLRequest(url: Self.systemOneURL)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = Self.timeoutSeconds
    do {
      request.httpBody = try JSONEncoder().encode(
        JudgmentRequest(model: "jev-latest", state: state, questions: questions))
    } catch {
      completion(.failure(.decoding(error)))
      return scope
    }
    perform(request, label: label, scope: scope, retriesLeft: 1, completion: completion)
    return scope
  }

  // 429/529 are the two documented retryable statuses; every other failure (including 401
  // and 422) is returned as-is with no retry.
  private func perform(
    _ request: URLRequest, label: String, scope: CancellableRequest, retriesLeft: Int,
    completion: @escaping (Result<JudgmentResponse, TypeSafeError>) -> Void
  ) {
    let start = ProcessInfo.processInfo.systemUptime
    let task = session.dataTask(with: request) { [weak self] data, response, error in
      scope.completedTask()
      guard !scope.isCancelled else { return }
      guard let self else { return }
      if let error {
        completion(.failure(.network(error)))
        return
      }
      guard let http = response as? HTTPURLResponse else {
        completion(.failure(.network(URLError(.badServerResponse))))
        return
      }
      if http.statusCode == 429 || http.statusCode == 529, retriesLeft > 0 {
        scope.schedule(after: 0.3) {
          self.perform(
            request, label: label, scope: scope, retriesLeft: retriesLeft - 1,
            completion: completion)
        }
        return
      }
      guard (200...299).contains(http.statusCode) else {
        completion(.failure(TypeSafeError(status: http.statusCode)))
        return
      }
      guard let data else {
        completion(.failure(.network(URLError(.zeroByteResource))))
        return
      }
      do {
        let decoded = try JSONDecoder().decode(JudgmentResponse.self, from: data)
        let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
        // CLAUDE.md's required measured-latency line for this subsystem.
        Log.info(
          "Jev", "\(label) \(String(format: "%.0f", ms)) ms, \(decoded.usage.inputTokens ?? 0) in")
        completion(.success(decoded))
      } catch {
        completion(.failure(.decoding(error)))
      }
    }
    scope.start(task)
  }

  @discardableResult
  func probe(completion: @escaping (Result<Void, TypeSafeError>) -> Void) -> CancellableRequest {
    let scope = CancellableRequest()
    guard !apiKey.isEmpty else {
      completion(.failure(.unavailable))
      return scope
    }
    var request = URLRequest(url: Self.modelsURL)
    request.httpMethod = "GET"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = Self.timeoutSeconds
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let start = ProcessInfo.processInfo.systemUptime
    let task = session.dataTask(with: request) { data, response, error in
      scope.completedTask()
      guard !scope.isCancelled else { return }
      if let error {
        completion(.failure(.network(error)))
        return
      }
      guard let http = response as? HTTPURLResponse else {
        completion(.failure(.network(URLError(.badServerResponse))))
        return
      }
      guard (200...299).contains(http.statusCode) else {
        completion(.failure(TypeSafeError(status: http.statusCode)))
        return
      }
      let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
      Log.info("Jev", "probe \(String(format: "%.0f", ms)) ms, 0 in")
      completion(.success(()))
    }
    scope.start(task)
    return scope
  }
}
