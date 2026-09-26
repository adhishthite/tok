// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum SettingCatalog {
  public static let all: [SettingDefinition] = [
    SettingDefinition(
      key: "HOTKEY", title: "Dictation shortcut",
      help: "Hold this key to dictate. Fn requires “Do Nothing” in Keyboard settings.",
      group: .general, section: "Shortcut",
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
      section: "Shortcut",
      kind: .choice(["push_to_talk", "toggle"]), defaultValue: "push_to_talk"
    ) { config, value in
      config.hotkeyMode = value.lowercased()
    },
    SettingDefinition(
      key: "HOLD_TO_LOCK", title: "Hold to lock",
      help: "Seconds before a held shortcut locks recording. Zero disables it.", group: .general,
      section: "Shortcut",
      kind: .decimal(0...60), unit: .seconds,
      enabledWhen: .equals("HOTKEY_MODE", "push_to_talk"), defaultValue: "15.0"
    ) { config, value in
      if let s = Double(value) { config.holdToLockSec = min(60.0, max(0.0, s)) }
    },
    SettingDefinition(
      key: "LOCK_LIMIT", title: "Locked recording limit",
      help:
        "Maximum seconds for hands-free recording. Zero removes the limit. Every dictation still ends before the 10 minute live session limit.",
      group: .general,
      section: "Shortcut",
      kind: .decimal(0...600), unit: .seconds,
      enabledWhen: .isPositive("HOLD_TO_LOCK").and(.equals("HOTKEY_MODE", "push_to_talk")),
      defaultValue: "120.0"
    ) { config, value in
      if let s = Double(value) { config.lockLimitSec = min(600.0, max(0.0, s)) }
    },
    SettingDefinition(
      key: "SOUND_FEEDBACK", title: "Play dictation sounds",
      help: "Quiet cues when recording starts, finishes, locks, or fails.", group: .general,
      section: "Sounds",
      kind: .toggle, defaultValue: "false", restartsEngine: false
    ) { config, value in
      config.soundFeedback = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "RELEASE_SOUND", title: "Play a release cue",
      help: "An additional short cue when you release the shortcut.", group: .general,
      section: "Sounds",
      kind: .toggle, enabledWhen: .isOn("SOUND_FEEDBACK"), defaultValue: "false",
      restartsEngine: false
    ) { config, value in
      config.releaseSound = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "RESTORE_CLIPBOARD", title: "Restore clipboard",
      help: "Put your previous clipboard back after pasting, unless you copied something new.",
      group: .general, section: "Pasting", kind: .toggle, defaultValue: "true"
    ) { config, value in
      config.restoreClipboard = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "TRAILING_SPACE", title: "Add a trailing space",
      help: "Keep consecutive dictations separated.", group: .general, section: "Pasting",
      kind: .toggle,
      defaultValue: "true"
    ) { config, value in
      config.trailingSpace = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "TYPING_WPM", title: "Typing speed",
      help: "Your typing speed. Stats uses it to estimate the time dictation saves.",
      group: .general, section: "Dictation stats", kind: .integer(10...200),
      unit: .wordsPerMinute, defaultValue: "40", restartsEngine: false
    ) { config, value in
      if let wpm = Int(value) { config.typingWordsPerMinute = min(200, max(10, wpm)) }
    },
    SettingDefinition(
      key: "SMART_TRANSCRIPTION", title: "Clean up during live transcription",
      help:
        "Ask the live model to remove fillers and format numbers and dates, using the existing transcription request.",
      group: .transcription, section: "Cleanup",
      kind: .toggle, defaultValue: "true"
    ) { config, value in
      config.smartTranscription = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "POST_PROCESS_ENABLED", title: "Polish dictations before pasting",
      help:
        "Send the transcript through an optional cleanup pass for punctuation, numbers, and lists. Adds response time and API usage. Off by default.",
      group: .transcription, section: "Cleanup", kind: .toggle, defaultValue: "false"
    ) { config, value in
      config.postProcessEnabled = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "POST_PROCESS_APP_CONTEXT", title: "Adapt formatting to the app",
      help:
        "When cleanup is enabled, include the destination app name and identifier. Window titles and contents are not sent.",
      group: .transcription, section: "Cleanup", kind: .toggle,
      enabledWhen: .isOn("POST_PROCESS_ENABLED"), defaultValue: "false"
    ) { config, value in
      config.postProcessAppContext = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "LANGUAGE_CODES", title: "Languages",
      help:
        "Comma-separated language codes, such as en-IN,hi-IN,mr-IN. Use auto for unrestricted recognition.",
      group: .transcription, section: "Languages", kind: .text, prompt: "en-IN,hi-IN,mr-IN",
      defaultValue: "en-IN,hi-IN,mr-IN"
    ) { config, value in
      config.languageCodes = EngineConfiguration.parseLanguages(
        value, fallback: config.languageCodes)
    },
    SettingDefinition(
      key: "INPUT_DEVICE", title: "Microphone",
      help:
        "System Default follows your Mac’s sound settings. Automatic uses the built-in microphone with the lid open and an external microphone with it closed.",
      group: .audio, section: "Microphone", kind: .microphone, defaultValue: ""
    ) { config, value in
      config.inputDevice = value
    },
    SettingDefinition(
      key: "KEEP_MICROPHONE_WARM", title: "Keep microphone ready",
      help:
        "Keep capturing between dictations for pre-roll. macOS will show microphone use while idle.",
      group: .audio, section: "Microphone", kind: .toggle, defaultValue: "false"
    ) { config, value in
      config.keepMicrophoneWarm = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "MIC_IDLE_TIMEOUT", title: "Release an idle microphone",
      help:
        "Seconds before releasing warm capture. Zero keeps it open. Applies only when “Keep microphone ready” is on.",
      group: .audio, section: "Microphone", kind: .integer(0...7200), unit: .seconds,
      enabledWhen: .isOn("KEEP_MICROPHONE_WARM"), defaultValue: "300"
    ) { config, value in
      if let sec = Int(value) { config.micIdleTimeoutSec = min(7200, max(0, sec)) }
    },
    SettingDefinition(
      key: "DUCK_AUDIO", title: "Lower other audio while dictating",
      help: "Restore the volume after capture. Your manual volume changes take priority.",
      group: .audio, section: "Other audio", kind: .toggle, defaultValue: "false"
    ) { config, value in
      config.duckAudio = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "DUCK_FRACTION", title: "Background volume fraction",
      help: "How much output volume to keep while dictating, from zero to one.", group: .audio,
      section: "Other audio",
      kind: .decimal(0...1), enabledWhen: .isOn("DUCK_AUDIO"), defaultValue: "0.2"
    ) { config, value in
      if let f = Double(value) { config.duckFraction = min(1.0, max(0.0, f)) }
    },
    SettingDefinition(
      key: "SHOW_HUD", title: "Show dictation overlay",
      help: "A small overlay follows your dictation without taking keyboard focus.",
      group: .appearance, section: "Overlay", kind: .toggle, defaultValue: "true",
      restartsEngine: false
    ) { config, value in
      config.showHUD = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "HUD_FOLLOW_FOCUS", title: "Follow the focused display",
      help: "Show the overlay on the display where you are writing.", group: .appearance,
      section: "Overlay",
      kind: .toggle, enabledWhen: .isOn("SHOW_HUD"), defaultValue: "true", restartsEngine: false
    ) { config, value in
      config.hudFollowFocus = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "HUD_REVEAL", title: "Overlay motion",
      help: "Preview the entrance and exit before choosing.", group: .appearance,
      section: "Overlay",
      kind: .choice(["drift", "slide", "bloom", "unfurl", "morph"]), enabledWhen: .isOn("SHOW_HUD"),
      defaultValue: "drift", restartsEngine: false
    ) { config, value in
      if ["slide", "bloom", "drift", "unfurl", "morph"].contains(value.lowercased()) {
        config.hudRevealStyle = value.lowercased()
      }
    },
    SettingDefinition(
      key: "HUD_PARTICLES", title: "Ambient particles",
      help: "Optional particles while listening. Disabled with Reduce Motion.", group: .appearance,
      section: "Overlay",
      kind: .toggle, enabledWhen: .isOn("SHOW_HUD"), defaultValue: "false", restartsEngine: false
    ) { config, value in
      config.hudParticles = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "PRIVACY_MODE", title: "Hide dictated words on screen",
      help: "Hide live words in the overlay and menu. Local history is controlled separately.",
      group: .privacy, section: "On screen", kind: .toggle, defaultValue: "false",
      restartsEngine: false
    ) { config, value in
      config.privacyMode = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "CUSTOM_VOCABULARY", title: "Additional terms",
      help: "Comma-separated words or wrong => right replacements.", group: .vocabulary,
      section: "Terms",
      kind: .text, prompt: "Kubernetes, gemini => Gemini", defaultValue: ""
    ) { config, value in
      config.customVocabulary = EngineConfiguration.parseVocabulary(from: value)
    },
    SettingDefinition(
      key: "CUSTOM_VOCABULARY_FILE", title: "Vocabulary file",
      help: "Edit terms and replacements in the Vocabulary window.", group: .vocabulary,
      section: "Terms",
      kind: .text, prompt: "vocabulary.txt", defaultValue: "vocabulary.txt"
    ) { config, value in
      config.customVocabularyFile = value
    },
    SettingDefinition(
      key: "ANALYZE_CONTEXT", title: "Your work and terminology",
      help: "Optional context to help vocabulary suggestions understand your domain.",
      group: .vocabulary, section: "Suggestions", kind: .text,
      prompt: "Cloud architecture and payments", defaultValue: ""
    ) { config, value in
      config.analyzeContext = value
    },
    SettingDefinition(
      key: "LEARN_CORRECTIONS", title: "Learn from typed corrections",
      help:
        "Observe word corrections after a paste. Only word pairs are stored, never the surrounding field.",
      group: .vocabulary, section: "Corrections", kind: .toggle, defaultValue: "false"
    ) { config, value in
      config.learnCorrections = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "LEARN_DELAY_MS", title: "Correction observation delay",
      help: "Milliseconds after a paste before checking for a correction.", group: .vocabulary,
      section: "Corrections",
      kind: .integer(2000...60000), unit: .milliseconds, enabledWhen: .isOn("LEARN_CORRECTIONS"),
      defaultValue: "8000"
    ) { config, value in
      if let ms = Int(value) { config.learnDelayMs = min(60000, max(2000, ms)) }
    },
    SettingDefinition(
      key: "HISTORY", title: "Save dictation history",
      help: "Store dictations locally on this Mac.", group: .privacy, section: "Local history",
      kind: .toggle,
      defaultValue: "true"
    ) { config, value in
      config.historyEnabled = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "HISTORY_RETENTION_DAYS", title: "History retention",
      help: "Days to retain history. Zero keeps it indefinitely.", group: .privacy,
      section: "Local history",
      kind: .integer(0...3650), unit: .days, defaultValue: "0", restartsEngine: false
    ) { config, value in
      if let days = Int(value) { config.historyRetentionDays = min(3650, max(0, days)) }
    },
    SettingDefinition(
      key: "STATS", title: "Track dictation stats",
      help:
        "Count words, dictations, speaking time, and time saved in a local stats database. No transcripts are stored there.",
      group: .privacy, section: "Dictation stats", kind: .toggle, defaultValue: "true",
      restartsEngine: false
    ) { config, value in
      config.statsEnabled = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "STATS_WORDS", title: "Track word usage",
      help:
        "Count how often each word is dictated for the most and least used lists. Stored as per-day counts, never as sentences.",
      group: .privacy, section: "Dictation stats", kind: .toggle, enabledWhen: .isOn("STATS"),
      defaultValue: "true", restartsEngine: false
    ) { config, value in
      config.statsWordsEnabled = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "SHARE_USAGE_METRICS", title: "Share anonymous usage metrics",
      help:
        "Off by default. Records counts, categories, and timing buckets only. Never transcripts, audio, vocabulary, or your API key. See PRIVACY.md.",
      group: .privacy, section: "Usage metrics", kind: .toggle, defaultValue: "false",
      restartsEngine: false
    ) { config, value in
      config.shareUsageMetrics = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "GEMINI_LIVE_MODEL", title: "Live model", help: "Used for streaming transcription.",
      group: .advanced, section: "Models", kind: .text, defaultValue: "gemini-3.5-transcribe-live"
    ) { config, value in
      config.geminiLiveModel = value
    },
    SettingDefinition(
      key: "GEMINI_MODEL", title: "Fallback model",
      help: "Used when the live connection cannot finish a dictation.", group: .advanced,
      section: "Models",
      kind: .text, defaultValue: "gemini-3.5-flash-lite"
    ) { config, value in
      config.geminiModel = value
    },
    SettingDefinition(
      key: "ANALYZE_MODEL", title: "Vocabulary analysis model",
      help: "Used only when you request suggestions from history.", group: .advanced,
      section: "Models", kind: .text,
      defaultValue: "gemini-3.7-flash"
    ) { config, value in
      config.analyzeModel = value
    },
    SettingDefinition(
      key: "POST_PROCESS_MODEL", title: "Cleanup model",
      help:
        "Default: Gemini 3.5 Flash-Lite. Update cleanup token prices if you choose another model.",
      group: .advanced, section: "Cleanup", kind: .text, enabledWhen: .isOn("POST_PROCESS_ENABLED"),
      defaultValue: "gemini-3.5-flash-lite"
    ) { config, value in
      config.postProcessModel = value.trimmingCharacters(in: .whitespacesAndNewlines)
    },
    SettingDefinition(
      key: "POST_PROCESS_TIMEOUT_MS", title: "Maximum cleanup wait",
      help:
        "Milliseconds before using the original transcript. Failed cleanup never blocks delivery indefinitely.",
      group: .advanced, section: "Cleanup", kind: .integer(500...10000), unit: .milliseconds,
      enabledWhen: .isOn("POST_PROCESS_ENABLED"), defaultValue: "2500"
    ) { config, value in
      if let value = Int(value) { config.postProcessTimeoutMs = min(10000, max(500, value)) }
    },
    SettingDefinition(
      key: "ENABLE_LIVE_WEBSOCKET", title: "Stream while speaking",
      help: "Use the live connection for lower settlement latency.", group: .advanced,
      section: "Streaming",
      kind: .toggle, defaultValue: "true"
    ) { config, value in
      config.enableLiveWebSocket = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "REST_FALLBACK_TIMEOUT", title: "Fallback delay",
      help: "Seconds to wait before also trying the fallback route.", group: .advanced,
      section: "Streaming",
      kind: .decimal(0.1...30), unit: .seconds, defaultValue: "4.0"
    ) { config, value in
      if let t = Double(value) { config.restFallbackTimeout = t }
    },
    SettingDefinition(
      key: "CHUNK_MS", title: "Streaming frame size",
      help: "Milliseconds of audio sent in each streaming frame.", group: .advanced,
      section: "Streaming",
      // Measured 2026-09-26 (PERFORMANCE.md, "Streaming frame size"): 100 ms, the size the
      // transcribe docs recommend, is 8 ms faster than 150 with no accuracy change.
      kind: .integer(20...500), unit: .milliseconds, defaultValue: "100"
    ) { config, value in
      if let ms = Int(value) { config.chunkMs = min(500, max(20, ms)) }
    },
    SettingDefinition(
      key: "SILENCE_FLUSH_MS", title: "Trailing silence",
      help: "Milliseconds of synthetic silence sent to help finalize the final word.",
      group: .advanced, section: "Streaming", kind: .integer(0...2000), unit: .milliseconds,
      // Measured 2026-09-26 (PERFORMANCE.md, "Silence flush"): each 100 ms of flush adds
      // about 23 ms of round trip with no accuracy gain. Below 200 ms, short Marathi clips
      // sometimes came back romanized.
      defaultValue: "200"
    ) { config, value in
      if let ms = Int(value) { config.silenceFlushMs = min(2000, max(0, ms)) }
    },
    SettingDefinition(
      key: "WS_ENDPOINT_ALIGNED", title: "Use aligned end signals",
      help:
        "Send only the documented end-of-turn signal. Turn off to compare latency and last-word accuracy with the earlier triple signal.",
      group: .advanced, section: "Streaming", kind: .toggle, defaultValue: "true"
    ) { config, value in
      config.wsEndpointAligned = (value.lowercased() == "true" || value == "1")
    },
    SettingDefinition(
      key: "PRE_ROLL_MS", title: "Pre-roll",
      help: "Milliseconds retained before pressing the shortcut when warm capture is enabled.",
      group: .advanced, section: "Capture timing", kind: .integer(0...1000), unit: .milliseconds,
      enabledWhen: .isOn("KEEP_MICROPHONE_WARM"), defaultValue: "400"
    ) { config, value in
      if let ms = Int(value) { config.preRollMs = min(1000, max(0, ms)) }
    },
    SettingDefinition(
      key: "POST_ROLL_MS", title: "Trailing quiet window",
      help: "Milliseconds of quiet needed before finishing capture.", group: .advanced,
      section: "Capture timing",
      kind: .integer(0...500), unit: .milliseconds, defaultValue: "250"
    ) { config, value in
      if let ms = Int(value) { config.postRollMs = min(500, max(0, ms)) }
    },
    SettingDefinition(
      key: "POST_ROLL_MIN_MS", title: "Minimum trailing capture",
      help: "Milliseconds recorded after release even when the room is already quiet.",
      group: .advanced, section: "Capture timing",
      // Measured 2026-09-26 (PERFORMANCE.md, "Trailing-capture floor"): the floor binds on
      // turns that were already quiet before release; there it is the whole wait. 30 ms
      // still covers the one hardware buffer in flight at key-up (1024 frames, about 21 ms).
      kind: .integer(0...250), unit: .milliseconds, defaultValue: "30"
    ) { config, value in
      if let ms = Int(value) { config.postRollMinMs = min(250, max(0, ms)) }
    },
    SettingDefinition(
      key: "POST_ROLL_MAX_MS", title: "Maximum trailing capture",
      help: "Milliseconds to wait for speech after release, at most.", group: .advanced,
      section: "Capture timing",
      kind: .integer(0...5000), unit: .milliseconds, defaultValue: "1500"
    ) { config, value in
      if let ms = Int(value) { config.postRollMaxMs = min(5000, max(0, ms)) }
    },
    SettingDefinition(
      key: "TRAIL_SILENCE_DB", title: "Quiet threshold",
      help: "Audio below this level in dBFS counts as quiet.", group: .advanced,
      section: "Capture timing",
      kind: .decimal((-80)...(-10)), unit: .decibels, defaultValue: "-40.0"
    ) { config, value in
      if let db = Double(value) { config.trailSilenceDb = min(-10.0, max(-80.0, db)) }
    },
    SettingDefinition(
      key: "QUIET_MARGIN_DB", title: "Noisy-room margin",
      help:
        "In a noisy room, audio this many dB above the room's own level still counts as quiet. 0 uses the quiet threshold alone.",
      group: .advanced, section: "Capture timing",
      kind: .decimal(0...20), unit: .decibels, defaultValue: "8"
    ) { config, value in
      if let db = Double(value) { config.quietMarginDb = min(20.0, max(0.0, db)) }
    },
    SettingDefinition(
      key: "VAD_MODE", title: "Speech boundary detection",
      help: "Manual uses the shortcut. Tuned and automatic use server speech detection.",
      group: .advanced, section: "Speech detection", kind: .choice(["manual", "tuned", "auto"]),
      defaultValue: "manual"
    ) { config, value in
      if ["manual", "tuned", "auto"].contains(value.lowercased()) {
        config.vadMode = value.lowercased()
      }
    },
    SettingDefinition(
      key: "VAD_SILENCE_MS", title: "Server quiet window",
      help: "Milliseconds of silence before the tuned server mode finishes speech.",
      group: .advanced, section: "Speech detection", kind: .integer(200...5000),
      unit: .milliseconds, enabledWhen: .equals("VAD_MODE", "tuned"), defaultValue: "1500"
    ) { config, value in
      if let ms = Int(value) { config.vadSilenceMs = min(5000, max(200, ms)) }
    },
    SettingDefinition(
      key: "LIVE_INPUT_PRICE_PER_1M", title: "Live input price",
      help: "US dollars per million tokens, used for cost estimates.", group: .advanced,
      section: "Pricing",
      kind: .decimal(0...1000), unit: .usdPerMillionTokens, defaultValue: "3.50",
      restartsEngine: false
    ) { config, value in
      if let p = Double(value), p >= 0 { config.liveInputPricePer1M = p }
    },
    SettingDefinition(
      key: "LIVE_OUTPUT_PRICE_PER_1M", title: "Live output price",
      help: "US dollars per million tokens, used for cost estimates.", group: .advanced,
      section: "Pricing",
      kind: .decimal(0...1000), unit: .usdPerMillionTokens, defaultValue: "21.00",
      restartsEngine: false
    ) { config, value in
      if let p = Double(value), p >= 0 { config.liveOutputPricePer1M = p }
    },
    SettingDefinition(
      key: "REST_INPUT_PRICE_PER_1M", title: "REST input price",
      help: "US dollars per million tokens, used for cost estimates.", group: .advanced,
      section: "Pricing",
      kind: .decimal(0...1000), unit: .usdPerMillionTokens, defaultValue: "0.30",
      restartsEngine: false
    ) { config, value in
      if let p = Double(value), p >= 0 { config.restInputPricePer1M = p }
    },
    SettingDefinition(
      key: "REST_OUTPUT_PRICE_PER_1M", title: "REST output price",
      help: "US dollars per million tokens, used for cost estimates.", group: .advanced,
      section: "Pricing",
      kind: .decimal(0...1000), unit: .usdPerMillionTokens, defaultValue: "2.50",
      restartsEngine: false
    ) { config, value in
      if let p = Double(value), p >= 0 { config.restOutputPricePer1M = p }
    },
    SettingDefinition(
      key: "POST_PROCESS_INPUT_PRICE_PER_1M", title: "Cleanup input price",
      help:
        "USD per million input tokens, for cost estimates. Default matches Gemini 3.5 Flash-Lite standard pricing.",
      group: .advanced, section: "Pricing", kind: .decimal(0...1000), unit: .usdPerMillionTokens,
      enabledWhen: .isOn("POST_PROCESS_ENABLED"), defaultValue: "0.30"
    ) { config, value in
      if let value = Double(value), value.isFinite {
        config.postProcessInputPricePer1M = min(1000, max(0, value))
      }
    },
    SettingDefinition(
      key: "POST_PROCESS_OUTPUT_PRICE_PER_1M", title: "Cleanup output price",
      help:
        "USD per million output tokens, including reported thinking tokens. Costs remain unknown when usage is not reported.",
      group: .advanced, section: "Pricing", kind: .decimal(0...1000), unit: .usdPerMillionTokens,
      enabledWhen: .isOn("POST_PROCESS_ENABLED"), defaultValue: "2.50"
    ) { config, value in
      if let value = Double(value), value.isFinite {
        config.postProcessOutputPricePer1M = min(1000, max(0, value))
      }
    },
    SettingDefinition(
      key: "HISTORY_DB", title: "History database path",
      help: "Empty uses Tok’s Application Support folder.", group: .advanced, section: "Storage",
      kind: .text, prompt: "Application Support folder",
      defaultValue: ""
    ) { config, value in
      config.historyDbPath = value
    },
    SettingDefinition(
      key: "LOG_LEVEL", title: "Diagnostic detail",
      help: "Normal records essential events. Verbose includes additional engineering detail.",
      group: .advanced, section: "Diagnostics", kind: .choice(["normal", "verbose"]),
      defaultValue: "normal", restartsEngine: false
    ) { config, value in
      config.logLevel = value.lowercased()
    },
    SettingDefinition(
      key: "EXPERIMENT_TAG", title: "Experiment label",
      help: "Stored with each dictation so measurements can be grouped. Leave empty normally.",
      group: .advanced, section: "Diagnostics", kind: .text, defaultValue: "",
      restartsEngine: false
    ) { config, value in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      config.experimentTag = trimmed.isEmpty ? nil : String(trimmed.prefix(64))
    },
  ]
}
