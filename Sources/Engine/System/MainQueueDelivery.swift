// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// QueueDelivery bound to the main queue, for consumers that own main-thread state (HUD
/// updates, capture-interruption presentation). Anything that owns its own queue should
/// use QueueDelivery directly.
final class MainQueueDelivery<Value>: QueueDelivery<Value> {
  init(_ consume: @escaping (Value) -> Void) { super.init(queue: .main, consume) }
}
