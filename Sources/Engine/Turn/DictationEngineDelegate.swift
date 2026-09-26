// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

public protocol DictationEngineDelegate: AnyObject, Sendable {
  func engineDidEmit(_ event: EngineEvent)
}
