// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What `JudgmentService` needs from a TypeSafe transport. `TypeSafeClient` is the real
/// implementation; tests inject a stub through `JudgmentService.init(makeTransport:)`.
protocol JudgmentTransport {
  @discardableResult
  func ask(
    state: JudgmentValue, questions: [String: JudgmentQuestion], label: String,
    completion: @escaping (Result<JudgmentResponse, TypeSafeError>) -> Void
  ) -> CancellableRequest

  @discardableResult
  func probe(completion: @escaping (Result<Void, TypeSafeError>) -> Void) -> CancellableRequest
}
