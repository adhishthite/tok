// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Owned by the turn's serial queue. Cancellation suppresses completion;
/// timeout/failure complete once with the original text.
final class PostProcessingStage {
  typealias Request = (
    String, EngineConfiguration, String?, String?, @escaping (PostProcessingResult) -> Void
  ) -> CancellableRequest
  private let queue: DispatchQueue
  private let request: Request
  private var generation: UInt64 = 0
  private var pending: CancellableRequest?
  private var timeout: DispatchWorkItem?
  private var completion: ((PostProcessingResult) -> Void)?

  init(queue: DispatchQueue, request: @escaping Request = PostProcessingClient.process) {
    self.queue = queue
    self.request = request
  }

  deinit {
    timeout?.cancel()
    pending?.cancel()
  }

  func process(
    text: String, configuration: EngineConfiguration, appName: String?, appBundleId: String?,
    completion: @escaping (PostProcessingResult) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    cancel()
    guard configuration.postProcessEnabled else {
      completion(PostProcessingResult(text: text, metrics: .off))
      return
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf16.count <= PostProcessingClient.maximumInputUTF16
    else {
      completion(
        PostProcessingResult(
          text: text,
          metrics: PostProcessingMetrics(
            status: "skipped", model: configuration.postProcessModel, costUSD: 0,
            errorCode: "input_limit")))
      return
    }
    self.completion = completion
    let token = generation
    let start = ProcessInfo.processInfo.systemUptime
    let deadline = DispatchWorkItem { [weak self] in
      self?.finish(
        PostProcessingResult(
          text: text,
          metrics: PostProcessingMetrics(
            status: "timed_out", model: configuration.postProcessModel, errorCode: "timeout",
            appContextUsed: configuration.postProcessAppContext
              && (appName != nil || appBundleId != nil))),
        generation: token, start: start)
    }
    timeout = deadline
    queue.asyncAfter(
      deadline: .now() + .milliseconds(configuration.postProcessTimeoutMs), execute: deadline)
    pending = request(text, configuration, appName, appBundleId) { [weak self] result in
      guard let self else { return }
      self.queue.async {
        let delivered =
          result.metrics.status == "completed"
          ? result
          : PostProcessingResult(text: text, metrics: result.metrics)
        self.finish(delivered, generation: token, start: start)
      }
    }
  }

  func cancel() {
    dispatchPrecondition(condition: .onQueue(queue))
    generation &+= 1
    timeout?.cancel()
    timeout = nil
    pending?.cancel()
    pending = nil
    completion = nil
  }

  private func finish(_ result: PostProcessingResult, generation token: UInt64, start: TimeInterval)
  {
    guard token == generation, let completion else { return }
    var measured = result
    measured.metrics.latencyMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
    cancel()
    completion(measured)
  }
}
