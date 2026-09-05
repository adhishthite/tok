import Foundation

enum BuildIdentity {
  static var revision: String {
    Bundle.main.object(forInfoDictionaryKey: "TokSourceRevision") as? String ?? "unversioned"
  }
}
