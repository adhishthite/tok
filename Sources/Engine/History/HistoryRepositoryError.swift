import Foundation

public enum HistoryRepositoryError: LocalizedError {
  case databaseUnavailable
  case queryFailed
  public var errorDescription: String? {
    switch self {
    case .databaseUnavailable: "Could not open history. Check that the database is readable."
    case .queryFailed: "Could not update history. Try again after the current dictation."
    }
  }
}
