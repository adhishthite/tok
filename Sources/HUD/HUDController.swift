// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AppKit
import TokEngine

public final class HUDController {
  let hud = FloatingHUD()
  private var enabled = true
  private var generation: UInt64 = 0

  public init(configuration: EngineConfiguration) { update(configuration: configuration) }

  public func update(configuration: EngineConfiguration) {
    enabled = configuration.showHUD
    hud.privacyMode = configuration.privacyMode
    // Listening copy names the key the user must press in toggle mode, so both fields
    // ride every settings change.
    hud.hotkeyMode = configuration.hotkeyMode
    hud.shortcutLabel = configuration.shortcutLabel
    hud.revealStyle = configuration.hudRevealStyle
    hud.particlesEnabled = configuration.hudParticles
    if !enabled { hud.hide() }
  }

  public func handle(_ event: EngineEvent) {
    guard enabled else { return }
    switch event {
    case .starting:
      generation &+= 1
      hud.showStarting()
    case .listening(let lockAfter):
      generation &+= 1
      hud.showListening(lockAfter: lockAfter)
    case .locked: hud.showLocked()
    case .processing: hud.showProcessing()
    case .busy: hud.showBusy()
    case .hidden:
      generation &+= 1
      hud.hide()
    case .failure(let message): hud.showError(message: message)
    case .success(let text): hud.showSuccess(text: text)
    case .cancelled: hud.showCancelled()
    case .liveText(let text): hud.updateLiveText(text)
    case .processingStatus(let text): showProcessingStatus(text)
    case .audioLevel(let db): hud.updateAudioLevel(db: db)
    case .captureStarted(let pid, let followFocus):
      guard followFocus else { return }
      let expected = generation
      FocusScreenResolver.resolve(frontmostPID: pid) { [weak self] screen in
        guard let self, self.generation == expected, let screen else { return }
        self.hud.retarget(to: screen)
      }
    default: break
    }
  }

  // Progress inside a long finish. Changes only the processing header, so it is a no-op
  // once the HUD has left the processing state.
  public func showProcessingStatus(_ text: String) {
    guard enabled else { return }
    hud.updateProcessingStatus(text)
  }

  public func preview() {
    generation &+= 1
    let expected = generation
    hud.showListening(lockAfter: nil)
    for index in 0..<24 {
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.08) { [weak self] in
        guard let self, self.generation == expected else { return }
        self.hud.updateAudioLevel(db: -32 + 12 * sin(Double(index) * 0.8))
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      guard let self, self.generation == expected else { return }
      self.hud.updateLiveText("Your words, right where you need them.")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      guard let self, self.generation == expected else { return }
      self.hud.showSuccess(text: "Your words, right where you need them.")
    }
  }

  public func hide() {
    generation &+= 1
    hud.hide()
  }
}
