// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Async wrapper for call sites that already run inside an `async throws` context (the
/// offline vocabulary analyzer), instead of the completion-based API the live turn path uses.
extension JudgmentService {
  func ask(state: JudgmentValue, questions: [String: JudgmentQuestion], label: String) async
    -> Result<JudgmentResponse, TypeSafeError>
  {
    await withCheckedContinuation { continuation in
      _ = self.ask(state: state, questions: questions, label: label) { result in
        continuation.resume(returning: result)
      }
    }
  }
}
