// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

/// Plain-language names for the delivery and outcome codes stored with a dictation.
/// History and the menu showed the raw database strings (audit F08, F04).
enum DeliveryLabel {
  /// The history wording, matching the Diagnostics pane.
  static func delivery(_ code: String) -> String {
    switch code {
    case "dispatched": "Paste dispatched"
    case "copied": "Copied to clipboard"
    case "failed": "Delivery failed"
    default: "Delivery not confirmed"
    }
  }

  /// The short menu wording. Nil when the turn reported no delivery at all.
  static func menuDelivery(_ code: String?) -> String? {
    switch code {
    case "dispatched": "Pasted"
    case "copied": "Copied to clipboard"
    case "failed": "Could not deliver"
    default: nil
    }
  }

  static func outcome(_ code: String) -> String {
    switch code {
    case "success": "Completed"
    case "delivery_failed": "Could not deliver"
    case "empty": "No speech"
    case "error": "Failed"
    case "cancelled": "Cancelled"
    default: code.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }
}
