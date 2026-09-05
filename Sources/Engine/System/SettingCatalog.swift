import Foundation

public enum SettingCatalog {
  public static let all: [SettingDefinition] = [
    SettingDefinition(
      key: "HISTORY_RETENTION_DAYS", title: "History retention",
      help: "Days to retain history. Zero keeps it indefinitely.", group: .history,
      kind: .integer(0...3650), defaultValue: "0"
    ) { config, value in
      if let days = Int(value) { config.historyRetentionDays = min(3650, max(0, days)) }
    },
    SettingDefinition(
      key: "GEMINI_MODEL", title: "Fallback model",
      help: "Used when the live connection cannot finish a dictation.", group: .advanced,
      kind: .text, defaultValue: "gemini-3.5-flash-lite"
    ) { config, value in
      config.geminiModel = value
    },
    SettingDefinition(
      key: "GEMINI_LIVE_MODEL", title: "Live model", help: "Used for streaming transcription.",
      group: .advanced, kind: .text, defaultValue: "gemini-3.5-transcribe-live"
    ) { config, value in
      config.geminiLiveModel = value
    },
    SettingDefinition(
      key: "SMART_TRANSCRIPTION", title: "Clean up speech",
      help: "Remove fillers and format spoken numbers and dates.", group: .transcription,
      kind: .toggle, defaultValue: "true"
    ) { config, value in
      config.smartTranscription = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "LANGUAGE_CODES", title: "Languages",
      help:
        "Comma-separated language codes, such as en-IN,mr-IN. Use auto for unrestricted recognition.",
      group: .transcription, kind: .text, defaultValue: "en-IN,mr-IN"
    ) { config, value in
      config.languageCodes = EngineConfiguration.parseLanguages(
        value, fallback: config.languageCodes)
    },
    SettingDefinition(
      key: "CUSTOM_VOCABULARY", title: "Additional terms",
      help: "Comma-separated words or wrong => right replacements.", group: .vocabulary,
      kind: .text, defaultValue: ""
    ) { config, value in
      config.customVocabulary = EngineConfiguration.parseVocabulary(from: value)
    },
    SettingDefinition(
      key: "CUSTOM_VOCABULARY_FILE", title: "Vocabulary file",
      help: "Edit terms and replacements in the Vocabulary window.", group: .vocabulary,
      kind: .text, defaultValue: "vocabulary.txt"
    ) { config, value in
      config.customVocabularyFile = value
    },
    SettingDefinition(
      key: "HOTKEY", title: "Dictation shortcut",
      help: "Hold this key to dictate. Fn requires “Do Nothing” in Keyboard settings.",
      group: .general,
      kind: .choice([
        "fn", "right_option", "left_option", "right_control", "left_control", "right_cmd",
        "left_cmd", "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20",
      ]), defaultValue: "fn"
    ) { config, value in
      config.hotkey = value.lowercased()
    },
    SettingDefinition(
      key: "HOTKEY_MODE", title: "Shortcut behavior",
      help: "Hold to speak, or press once to start and again to finish.", group: .general,
      kind: .choice(["push_to_talk", "toggle"]), defaultValue: "push_to_talk"
    ) { config, value in
      config.hotkeyMode = value.lowercased()
    },
    SettingDefinition(
      key: "HOLD_TO_LOCK", title: "Hold to lock",
      help: "Seconds before a held shortcut locks recording. Zero disables it.", group: .general,
      kind: .integer(0...60), defaultValue: "15.0"
    ) { config, value in
      if let s = Double(value) { config.holdToLockSec = min(60.0, max(0.0, s)) }
    },
    SettingDefinition(
      key: "LOCK_LIMIT", title: "Locked recording limit",
      help: "Maximum seconds for hands-free recording. Zero removes the limit.", group: .general,
      kind: .integer(0...600), defaultValue: "120.0"
    ) { config, value in
      if let s = Double(value) { config.lockLimitSec = min(600.0, max(0.0, s)) }
    },
    SettingDefinition(
      key: "SOUND_FEEDBACK", title: "Play dictation sounds",
      help: "Quiet cues when recording starts, finishes, locks, or fails.", group: .general,
      kind: .toggle, defaultValue: "false"
    ) { config, value in
      config.soundFeedback = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "RELEASE_SOUND", title: "Play a release cue",
      help: "An additional short cue when you release the shortcut.", group: .general,
      kind: .toggle, defaultValue: "false"
    ) { config, value in
      config.releaseSound = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "SHOW_HUD", title: "Show dictation overlay",
      help: "A small overlay follows your dictation without taking keyboard focus.",
      group: .appearance, kind: .toggle, defaultValue: "true"
    ) { config, value in
      config.showHUD = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "HUD_FOLLOW_FOCUS", title: "Follow the focused display",
      help: "Show the overlay on the display where you are writing.", group: .appearance,
      kind: .toggle, defaultValue: "true"
    ) { config, value in
      config.hudFollowFocus = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "INPUT_DEVICE", title: "Microphone",
      help:
        "Empty uses the system default. Auto switches between built-in and external input with the lid.",
      group: .audio, kind: .text, defaultValue: ""
    ) { config, value in
      config.inputDevice = value
    },
    SettingDefinition(
      key: "HUD_REVEAL", title: "Overlay motion",
      help: "Preview the entrance and exit before choosing.", group: .appearance,
      kind: .choice(["drift", "slide", "bloom", "unfurl", "morph"]), defaultValue: "drift"
    ) { config, value in
      if ["slide", "bloom", "drift", "unfurl", "morph"].contains(value.lowercased()) {
        config.hudRevealStyle = value.lowercased()
      }
    },
    SettingDefinition(
      key: "HUD_PARTICLES", title: "Ambient particles",
      help: "Optional particles while listening. Disabled with Reduce Motion.", group: .appearance,
      kind: .toggle, defaultValue: "false"
    ) { config, value in
      config.hudParticles = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "PRIVACY_MODE", title: "Hide dictated words on screen",
      help: "Hide live words in the overlay and menu. Local history is controlled separately.",
      group: .appearance, kind: .toggle, defaultValue: "false"
    ) { config, value in
      config.privacyMode = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "DUCK_AUDIO", title: "Lower other audio while dictating",
      help: "Restore the volume after capture. Your manual volume changes take priority.",
      group: .audio, kind: .toggle, defaultValue: "false"
    ) { config, value in
      config.duckAudio = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "DUCK_FRACTION", title: "Background volume fraction",
      help: "How much output volume to keep while dictating, from zero to one.", group: .audio,
      kind: .decimal(0...1), defaultValue: "0.2"
    ) { config, value in
      if let f = Double(value) { config.duckFraction = min(1.0, max(0.0, f)) }
    },
    SettingDefinition(
      key: "ENABLE_LIVE_WEBSOCKET", title: "Stream while speaking",
      help: "Use the live connection for lower settlement latency.", group: .advanced,
      kind: .toggle, defaultValue: "true"
    ) { config, value in
      config.enableLiveWebSocket = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "RESTORE_CLIPBOARD", title: "Restore clipboard",
      help: "Put your previous clipboard back after pasting, unless you copied something new.",
      group: .general, kind: .toggle, defaultValue: "true"
    ) { config, value in
      config.restoreClipboard = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "TRAILING_SPACE", title: "Add a trailing space",
      help: "Keep consecutive dictations separated.", group: .general, kind: .toggle,
      defaultValue: "true"
    ) { config, value in
      config.trailingSpace = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "REST_FALLBACK_TIMEOUT", title: "Fallback delay",
      help: "Seconds to wait before also trying the fallback route.", group: .advanced,
      kind: .decimal(0.1...30), defaultValue: "4.0"
    ) { config, value in
      if let t = Double(value) { config.restFallbackTimeout = t }
    },
    SettingDefinition(
      key: "PRE_ROLL_MS", title: "Pre-roll",
      help: "Milliseconds retained before pressing the shortcut when warm capture is enabled.",
      group: .advanced, kind: .integer(0...1000), defaultValue: "400"
    ) { config, value in
      if let ms = Int(value) { config.preRollMs = min(1000, max(0, ms)) }
    },
    SettingDefinition(
      key: "POST_ROLL_MS", title: "Trailing quiet window",
      help: "Milliseconds of quiet needed before finishing capture.", group: .advanced,
      kind: .integer(0...500), defaultValue: "250"
    ) { config, value in
      if let ms = Int(value) { config.postRollMs = min(500, max(0, ms)) }
    },
    SettingDefinition(
      key: "POST_ROLL_MAX_MS", title: "Maximum trailing capture",
      help: "Milliseconds to wait for speech after release, at most.", group: .advanced,
      kind: .integer(0...5000), defaultValue: "1500"
    ) { config, value in
      if let ms = Int(value) { config.postRollMaxMs = min(5000, max(0, ms)) }
    },
    SettingDefinition(
      key: "TRAIL_SILENCE_DB", title: "Quiet threshold",
      help: "Audio below this level in dBFS counts as quiet.", group: .advanced,
      kind: .decimal((-80)...(-10)), defaultValue: "-40.0"
    ) { config, value in
      if let db = Double(value) { config.trailSilenceDb = min(-10.0, max(-80.0, db)) }
    },
    SettingDefinition(
      key: "VAD_MODE", title: "Speech boundary detection",
      help: "Manual uses the shortcut. Tuned and automatic use server speech detection.",
      group: .advanced, kind: .choice(["manual", "tuned", "auto"]), defaultValue: "manual"
    ) { config, value in
      if ["manual", "tuned", "auto"].contains(value.lowercased()) {
        config.vadMode = value.lowercased()
      }
    },
    SettingDefinition(
      key: "VAD_SILENCE_MS", title: "Server quiet window",
      help: "Milliseconds of silence before the tuned server mode finishes speech.",
      group: .advanced, kind: .integer(200...5000), defaultValue: "1500"
    ) { config, value in
      if let ms = Int(value) { config.vadSilenceMs = min(5000, max(200, ms)) }
    },
    SettingDefinition(
      key: "WS_ENDPOINT_ALIGNED", title: "Use aligned end signals",
      help:
        "Experimental endpoint signaling. Compare latency and last-word accuracy before adopting.",
      group: .advanced, kind: .toggle, defaultValue: "false"
    ) { config, value in
      config.wsEndpointAligned = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "CHUNK_MS", title: "Streaming frame size",
      help: "Milliseconds of audio sent in each streaming frame.", group: .advanced,
      kind: .integer(20...500), defaultValue: "150"
    ) { config, value in
      if let ms = Int(value) { config.chunkMs = min(500, max(20, ms)) }
    },
    SettingDefinition(
      key: "SILENCE_FLUSH_MS", title: "Trailing silence",
      help: "Milliseconds of synthetic silence sent to help finalize the final word.",
      group: .advanced, kind: .integer(0...2000), defaultValue: "700"
    ) { config, value in
      if let ms = Int(value) { config.silenceFlushMs = min(2000, max(0, ms)) }
    },
    SettingDefinition(
      key: "MIC_IDLE_TIMEOUT", title: "Release an idle microphone",
      help:
        "Seconds before releasing warm capture. Zero keeps it open. Applies only when “Keep microphone ready” is on.",
      group: .audio, kind: .integer(0...7200), defaultValue: "300"
    ) { config, value in
      if let sec = Int(value) { config.micIdleTimeoutSec = min(7200, max(0, sec)) }
    },
    SettingDefinition(
      key: "HISTORY", title: "Save dictation history",
      help: "Store dictations locally on this Mac.", group: .history, kind: .toggle,
      defaultValue: "true"
    ) { config, value in
      config.historyEnabled = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "HISTORY_DB", title: "History database path",
      help: "Empty uses Tok’s Application Support folder.", group: .advanced, kind: .text,
      defaultValue: ""
    ) { config, value in
      config.historyDbPath = value
    },
    SettingDefinition(
      key: "ANALYZE_MODEL", title: "Vocabulary analysis model",
      help: "Used only when you request suggestions from history.", group: .advanced, kind: .text,
      defaultValue: "gemini-3.7-flash"
    ) { config, value in
      config.analyzeModel = value
    },
    SettingDefinition(
      key: "ANALYZE_CONTEXT", title: "Your work and terminology",
      help: "Optional context to help vocabulary suggestions understand your domain.",
      group: .vocabulary, kind: .text, defaultValue: ""
    ) { config, value in
      config.analyzeContext = value
    },
    SettingDefinition(
      key: "LEARN_CORRECTIONS", title: "Learn from typed corrections",
      help:
        "Observe word corrections after a paste. Only word pairs are stored, never the surrounding field.",
      group: .vocabulary, kind: .toggle, defaultValue: "false"
    ) { config, value in
      config.learnCorrections = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "LEARN_DELAY_MS", title: "Correction observation delay",
      help: "Milliseconds after a paste before checking for a correction.", group: .vocabulary,
      kind: .integer(2000...60000), defaultValue: "8000"
    ) { config, value in
      if let ms = Int(value) { config.learnDelayMs = min(60000, max(2000, ms)) }
    },
    SettingDefinition(
      key: "LIVE_INPUT_PRICE_PER_1M", title: "Live input price",
      help: "US dollars per million tokens, used for cost estimates.", group: .advanced,
      kind: .decimal(0...1000), defaultValue: "3.50"
    ) { config, value in
      if let p = Double(value), p >= 0 { config.liveInputPricePer1M = p }
    },
    SettingDefinition(
      key: "LIVE_OUTPUT_PRICE_PER_1M", title: "Live output price",
      help: "US dollars per million tokens, used for cost estimates.", group: .advanced,
      kind: .decimal(0...1000), defaultValue: "21.00"
    ) { config, value in
      if let p = Double(value), p >= 0 { config.liveOutputPricePer1M = p }
    },
    SettingDefinition(
      key: "REST_INPUT_PRICE_PER_1M", title: "Rest input price",
      help: "US dollars per million tokens, used for cost estimates.", group: .advanced,
      kind: .decimal(0...1000), defaultValue: "0.30"
    ) { config, value in
      if let p = Double(value), p >= 0 { config.restInputPricePer1M = p }
    },
    SettingDefinition(
      key: "REST_OUTPUT_PRICE_PER_1M", title: "Rest output price",
      help: "US dollars per million tokens, used for cost estimates.", group: .advanced,
      kind: .decimal(0...1000), defaultValue: "2.50"
    ) { config, value in
      if let p = Double(value), p >= 0 { config.restOutputPricePer1M = p }
    },
    SettingDefinition(
      key: "LOG_LEVEL", title: "Diagnostic detail",
      help: "Normal records essential events. Verbose includes additional engineering detail.",
      group: .advanced, kind: .choice(["normal", "verbose"]), defaultValue: "normal"
    ) { config, value in
      config.logLevel = value.lowercased()
    },
    SettingDefinition(
      key: "KEEP_MICROPHONE_WARM", title: "Keep microphone ready",
      help:
        "Keep capturing between dictations for pre-roll. macOS will show microphone use while idle.",
      group: .audio, kind: .toggle, defaultValue: "false"
    ) { config, value in
      config.keepMicrophoneWarm = (value.lowercased() == "true" || value == "1")
    },
  ]
}
