import Foundation

/// The gate: TypeSafe judgments run only once a key is configured and the models probe has
/// succeeded for that key. Everything else in `Engine/Judgment` goes through this type;
/// callers only ever see `isAvailable`/`awaitAvailability` and `ask`.
///
/// Never touches `sessionQueue` or main: probing and dispatch both happen on `queue`, and the
/// transport's own completions land on its background delegate queue. With no key, `configure`
/// never touches `queue` or the network at all.
final class JudgmentService {
  let queue = DispatchQueue(label: "com.adhishthite.tok.judgment", qos: .utility)
  private let lock = NSLock()
  private var client: JudgmentTransport?
  private var currentKey = ""
  private var available = false
  private var probing = false
  private var waiters: [(Bool) -> Void] = []
  private let makeTransport: (String) -> JudgmentTransport

  /// Thread-safe snapshot; false until the probe for the current key has succeeded.
  var isAvailable: Bool {
    lock.lock()
    defer { lock.unlock() }
    return available
  }

  init(
    apiKey: String,
    makeTransport: @escaping (String) -> JudgmentTransport = { TypeSafeClient(apiKey: $0) }
  ) {
    self.makeTransport = makeTransport
    configure(apiKey: apiKey)
  }

  /// Rebuilds the transport and reruns the probe only when the key actually changed. Safe to
  /// call from any thread. A key that fails its probe stays disabled until this is called
  /// again with a different key (CLAUDE.md: "disabled for the process lifetime until the key
  /// changes").
  func configure(apiKey: String) {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    lock.lock()
    let unchanged = trimmed == currentKey
    lock.unlock()
    guard !unchanged else { return }
    // Built before the lock is taken: never construct a transport (and its URLSession) while
    // holding the lock. An empty key builds nothing at all, so no session and no request can
    // exist without a key.
    let newClient = trimmed.isEmpty ? nil : makeTransport(trimmed)
    lock.lock()
    guard trimmed != currentKey else {
      // A concurrent configure won the race; discard this transport unused.
      lock.unlock()
      return
    }
    // `client` is mutated only under `lock`, the same lock `ask` reads it under.
    currentKey = trimmed
    available = false
    probing = newClient != nil
    client = newClient
    let staleWaiters = waiters
    waiters = []
    lock.unlock()
    // Never call out while holding the lock.
    for waiter in staleWaiters { waiter(false) }
    guard let newClient else { return }
    queue.async { [weak self] in
      guard let service = self else { return }
      newClient.probe { [weak service] result in
        guard let service else { return }
        service.queue.async { service.finishProbe(key: trimmed, result: result) }
      }
    }
  }

  private func finishProbe(key: String, result: Result<Void, TypeSafeError>) {
    lock.lock()
    guard currentKey == key else {
      // Superseded by a newer key while the probe was in flight.
      lock.unlock()
      return
    }
    switch result {
    case .success: available = true
    case .failure: available = false
    }
    probing = false
    let pending = waiters
    waiters = []
    let ok = available
    lock.unlock()
    // Logging happens after the lock is released (never hold a lock while logging).
    switch result {
    case .success:
      Log.info("Jev", "TypeSafe judgments available.")
    case .failure(let error):
      Log.warn("Jev", "Probe failed: \(error.diagnosticDescription); judgments disabled.")
    }
    for waiter in pending { waiter(ok) }
  }

  /// Waits for an in-flight probe to settle. Only for call sites that already run in an async
  /// context and can afford one round trip before deciding whether to use Jev (the offline
  /// vocabulary analyzer). The live turn path uses `isAvailable`'s immediate snapshot instead
  /// and never blocks on this.
  func awaitAvailability() async -> Bool {
    await withCheckedContinuation { continuation in
      lock.lock()
      guard !currentKey.isEmpty else {
        lock.unlock()
        continuation.resume(returning: false)
        return
      }
      guard probing else {
        let ok = available
        lock.unlock()
        continuation.resume(returning: ok)
        return
      }
      waiters.append { ok in continuation.resume(returning: ok) }
      lock.unlock()
    }
  }

  /// No-ops with `.unavailable` until the probe has succeeded for the current key.
  @discardableResult
  func ask(
    state: JudgmentValue, questions: [String: JudgmentQuestion], label: String,
    completion: @escaping (Result<JudgmentResponse, TypeSafeError>) -> Void
  ) -> CancellableRequest? {
    lock.lock()
    let ready = available
    let activeClient = client
    lock.unlock()
    guard ready, let activeClient else {
      completion(.failure(.unavailable))
      return nil
    }
    return activeClient.ask(
      state: state, questions: questions, label: label, completion: completion)
  }
}
