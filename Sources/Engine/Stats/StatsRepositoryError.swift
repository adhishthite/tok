// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum StatsRepositoryError: LocalizedError {
  case databaseUnavailable
  case queryFailed
  public var errorDescription: String? {
    switch self {
    case .databaseUnavailable: "Could not open the stats database."
    case .queryFailed: "Could not read or update the stats database."
    }
  }
}
