// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

/// One documented field of a usage metric event.
public struct MetricFieldDefinition: Sendable {
  public let name: String
  public let kind: String
  public let description: String
  public init(_ name: String, kind: String, _ description: String) {
    self.name = name
    self.kind = kind
    self.description = description
  }
}
