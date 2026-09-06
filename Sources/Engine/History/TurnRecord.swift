import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

public struct TurnRecord: Sendable {
  public var outcome: String
  public var text: String?
  public var charCount: Int
  public var wordCount: Int
  public var transport: String?
  public var model: String?
  public var isLiveRoute: Bool?
  public var fallbackReason: String?
  public var audioSeconds: Double?
  public var firstTokenMs: Double?
  public var roundtripMs: Double?
  public var captureFinalizeMs: Double?
  public var injectMs: Double?
  public var totalMs: Double?
  public var injected: Bool?
  public var inputTokens: Int?
  public var outputTokens: Int?
  public var tokensMetered: Bool?
  public var costUSD: Double?
  public var languageCodes: String
  public var smartMode: Bool
  public var vadMode: String
  public var error: String?
  // App that was frontmost at key-down - where the dictation was aimed.
  public var appBundleId: String?
  public var appName: String?
  // Capture device at key-down (CoreAudio name + transport: builtin/usb/bluetooth/...).
  public var inputDevice: String?
  public var inputTransport: String?
  // Silence-gate evidence for the clip (tunes TRAIL_SILENCE_DB / SILENCE_FLUSH_MS
  // against real dictations) and which settlement rule ended a WS turn (the thing
  // WS_ENDPOINT_ALIGNED changes). Defaulted so rows without the data store NULL.
  public var peakDb: Double? = nil
  public var speechFrames: Int? = nil
  public var settlePath: String? = nil
  // How the hold ended: "release" (plain push-to-talk), "lock_press" (hold-to-lock,
  // finished by the next press) or "lock_limit" (locked turn cut by LOCK_LIMIT).
  public var finishMode: String? = nil
  public var eventQueueMs: Double? = nil
  public var readyMs: Double? = nil
  public var deliveryOutcome: String? = nil
  public var postProcessing: PostProcessingMetrics? = nil
  public var transcriptionCostUSD: Double? = nil
}
