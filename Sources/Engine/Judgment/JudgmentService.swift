// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The gate: TypeSafe judgments run only once a key is configured and the models probe has
/// succeeded for that key. Everything else in `Engine/Judgment` goes through this type;
/// callers only ever see `isAvailable`/`awaitAvailability` and `ask`.
///
/// Never touches `sessionQueue` or main: probing and dispatch both happen on `queue`, and the
/// transport's own completions land on its background delegate queue. With no key, `configure`
/// builds no transport and issues no request; it uses `queue` only to deliver the `.off`
/// availability notification, and only when a handler is installed.
final class JudgmentService {
  let queue = DispatchQueue(label: "com.adhishthite.tok.judgment", qos: .utility)
  private let lock = NSLock()
  private var client: JudgmentTransport?
  private var currentKey = ""
  private var available = false
  private var probing = false
  private var waiters: [(Bool) -> Void] = []
  private let makeTransport: (String) -> JudgmentTransport
  private var availabilityValue: JudgmentAvailability = .off
  // Bumped under `lock` on every write to `availabilityValue`, so a queued notification can
  // tell whether the state moved on before it was delivered.
  private var availabilityGeneration: UInt64 = 0
  private var availabilityChangeHandler: ((JudgmentAvailability) -> Void)?

  /// Thread-safe snapshot; false until the probe for the current key has succeeded.
  var isAvailable: Bool {
    lock.lock()
    defer { lock.unlock() }
    return available
  }

  /// Thread-safe snapshot of the richer state behind `isAvailable`, for surfaces (Settings)
  /// that need to show why judgments are off, not just whether.
  var availability: JudgmentAvailability {
    lock.lock()
    defer { lock.unlock() }
    return availabilityValue
  }

  /// Fired on `queue`, after `lock` is released, on every `availability` transition. Set once
  /// by `DictationEngine` at construction; reads and writes are lock-guarded so a probe
  /// completion racing a fresh `configure` call never tears the handler.
  var onAvailabilityChange: ((JudgmentAvailability) -> Void)? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return availabilityChangeHandler
    }
    set {
      lock.lock()
      availabilityChangeHandler = newValue
      lock.unlock()
    }
  }

  /// Never call out while holding `lock` (CLAUDE.md). Reads the handler under lock, then
  /// invokes it after releasing, on `queue`.
  ///
  /// The generation is re-checked on `queue` before delivery. `finishProbe` releases the lock
  /// (and logs) before it notifies, so a `configure` landing in that gap would otherwise have
  /// its `.checking` delivered first and the old key's verdict delivered after it, leaving the
  /// UI on a result the service itself has already discarded. A superseded generation is
  /// dropped instead; the newer write queued its own notification.
  private func emitAvailabilityChange(_ newValue: JudgmentAvailability, generation: UInt64) {
    lock.lock()
    let handler = availabilityChangeHandler
    lock.unlock()
    guard let handler else { return }
    queue.async { [weak self] in
      guard let service = self else { return }
      service.lock.lock()
      let superseded = service.availabilityGeneration != generation
      service.lock.unlock()
      guard !superseded else { return }
      handler(newValue)
    }
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
    availabilityValue = newClient == nil ? .off : .checking
    availabilityGeneration &+= 1
    let newAvailability = availabilityValue
    let newGeneration = availabilityGeneration
    let staleWaiters = waiters
    waiters = []
    lock.unlock()
    // Never call out while holding the lock.
    for waiter in staleWaiters { waiter(false) }
    emitAvailabilityChange(newAvailability, generation: newGeneration)
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
    switch result {
    case .success: availabilityValue = .available
    case .failure(let error): availabilityValue = .unavailable(reason: error.diagnosticDescription)
    }
    availabilityGeneration &+= 1
    let newAvailability = availabilityValue
    let newGeneration = availabilityGeneration
    lock.unlock()
    // Logging happens after the lock is released (never hold a lock while logging).
    switch result {
    case .success:
      Log.info("Jev", "TypeSafe judgments available.")
    case .failure(let error):
      Log.warn("Jev", "Probe failed: \(error.diagnosticDescription); judgments disabled.")
    }
    for waiter in pending { waiter(ok) }
    emitAvailabilityChange(newAvailability, generation: newGeneration)
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
