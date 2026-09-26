// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

enum TurnDeadline {
  static func budget(fallbackTimeout: Double) -> Double {
    max(10.0, min(30.0, fallbackTimeout + 10.0))
  }

  static func remaining(budget: Double, elapsed: Double) -> Double {
    max(0, budget - elapsed)
  }
}
