// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The subset of EngineConfiguration that a running DictationEngine re-reads per use
/// instead of at construction, so Settings changes to these keys apply without a restart.
public struct HotSettings: Sendable {
  public var soundFeedback: Bool
  public var releaseSound: Bool
  public var hudFollowFocus: Bool
  public var privacyMode: Bool
  public var liveInputPricePer1M: Double
  public var liveOutputPricePer1M: Double
  public var restInputPricePer1M: Double
  public var restOutputPricePer1M: Double
  public var experimentTag: String?

  public init(_ config: EngineConfiguration) {
    soundFeedback = config.soundFeedback
    releaseSound = config.releaseSound
    hudFollowFocus = config.hudFollowFocus
    privacyMode = config.privacyMode
    liveInputPricePer1M = config.liveInputPricePer1M
    liveOutputPricePer1M = config.liveOutputPricePer1M
    restInputPricePer1M = config.restInputPricePer1M
    restOutputPricePer1M = config.restOutputPricePer1M
    experimentTag = config.experimentTag
  }
}
