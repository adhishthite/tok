import Foundation

/// One dictation as the stats database keeps it: counts and timing, never text.
struct StatsTurn: Sendable, Equatable {
  var date: Date
  var success: Bool
  var words: Int
  var characters: Int
  var audioSeconds: Double?
  var totalMs: Double?
  var app: String
}
