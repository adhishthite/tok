// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

enum ReplacementEngine {
  // Sorted + regex-compiled once at config load; apply() runs on the paste path between
  // settlement and injection, so per-turn sorting/compilation was pure latency.

  static func compile(_ rules: [ReplacementRule]) -> [CompiledRule] {
    // Longest wrong-form first so "gemini api" wins over "gemini".
    return rules.sorted(by: { $0.wrong.count > $1.wrong.count }).compactMap { rule in
      guard !rule.wrong.isEmpty else { return nil }
      // Lookarounds instead of \b: word boundaries silently never match when the wrong
      // form starts/ends with punctuation ("e.g.", "c++").
      let pattern = "(?<![\\w])\(NSRegularExpression.escapedPattern(for: rule.wrong))(?![\\w])"
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
      else { return nil }
      return CompiledRule(regex: regex, wrong: rule.wrong, right: rule.right)
    }
  }

  static func apply(
    _ text: String, compiled: [CompiledRule], maximumOutputUTF16: Int = 1_000_000,
    maximumMatches: Int = 10_000, maximumScannedUTF16: Int = 16_000_000
  ) throws -> String {
    guard !compiled.isEmpty, !text.isEmpty else { return text }
    guard maximumOutputUTF16 >= 0, maximumMatches >= 0, maximumScannedUTF16 >= 0,
      (text as NSString).length <= maximumOutputUTF16
    else { throw ReplacementLimitError.budgetExceeded }
    var result = text
    var matchesLeft = maximumMatches
    var scanLeft = maximumScannedUTF16
    for rule in compiled {
      let ns = result as NSString
      guard ns.length <= scanLeft else { throw ReplacementLimitError.budgetExceeded }
      scanLeft -= ns.length
      var edits: [(range: NSRange, replacement: String)] = []
      var projectedLength = ns.length
      var rejected = false
      // Enumeration can stop before allocating an unbounded array of matches.
      rule.regex.enumerateMatches(in: result, range: NSRange(location: 0, length: ns.length)) {
        match, _, stop in
        guard let match else { return }
        guard matchesLeft > 0 else {
          rejected = true
          stop.pointee = true
          return
        }
        matchesLeft -= 1
        let original = ns.substring(with: match.range)
        let replacement = propagateCase(from: original, to: rule.right, wrong: rule.wrong)
        let length = (replacement as NSString).length
        let retained = projectedLength - match.range.length
        guard length <= maximumOutputUTF16 - retained else {
          rejected = true
          stop.pointee = true
          return
        }
        projectedLength = retained + length
        edits.append((match.range, replacement))
      }
      guard !rejected else { throw ReplacementLimitError.budgetExceeded }
      guard !edits.isEmpty else { continue }
      // Construct once in source order, rather than repeatedly shifting the growing string.
      let mutable = NSMutableString(capacity: projectedLength)
      var cursor = 0
      for edit in edits {
        mutable.append(
          ns.substring(with: NSRange(location: cursor, length: edit.range.location - cursor)))
        mutable.append(edit.replacement)
        cursor = NSMaxRange(edit.range)
      }
      mutable.append(ns.substring(from: cursor))
      result = mutable as String
    }
    return result
  }

  // "KUBERNETES"->"GRPC" stays caps; "Kubernetes"->"GRPC" follows the rule's canonical
  // casing unless the match was ALL-CAPS or the rule carries EXPLICIT casing. A rule is
  // explicitly cased when its right side contains uppercase (gRPC, iPhone) - or when its
  // WRONG side does ("NPM"->"npm" is a deliberate lowercase rule; ALL-CAPS propagation
  // would silently undo it) - or when wrong/right are the same word modulo case.
  static func propagateCase(from original: String, to replacement: String, wrong: String = "")
    -> String
  {
    let hasExplicitCasing =
      replacement.dropFirst().contains(where: { $0.isUppercase })
      || replacement.first?.isUppercase == true
      || wrong.contains(where: { $0.isUppercase })
      || (!wrong.isEmpty && wrong.lowercased() == replacement.lowercased())
    if hasExplicitCasing {
      return replacement  // dictionary term carries its own casing (gRPC, iPhone)
    }
    if original == original.uppercased(), original.count > 1 {
      return replacement.uppercased()
    }
    if original.first?.isUppercase == true {
      return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }
    return replacement
  }
}
