import Foundation
import os

enum Log {
  private static let lock = NSLock()
  private static var verbose = true
  private static var privacy = false
  private static var secret = ""
  private static weak var delegate: DictationEngineDelegate?
  private static let system = os.Logger(subsystem: "com.adhishthite.tok", category: "engine")
  private static let writer = BoundedLogBuffer { line in
    lock.lock()
    let sink = delegate
    lock.unlock()
    system.debug("\(line, privacy: .private)")
    sink?.engineDidEmit(.diagnostic(line))
  }

  static var isVerbose: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return verbose
    }
    set {
      lock.lock()
      verbose = newValue
      lock.unlock()
    }
  }

  static func configure(delegate: DictationEngineDelegate?, apiKey: String, privacyMode: Bool) {
    lock.lock()
    self.delegate = delegate
    secret = apiKey
    privacy = privacyMode
    lock.unlock()
  }

  static func raw(_ message: String) {
    lock.lock()
    let key = secret
    lock.unlock()
    writer.submit(key.isEmpty ? message : message.replacingOccurrences(of: key, with: "[redacted]"))
  }

  static func flush() { writer.flush() }
  static func info(_ tag: String, _ message: String) { raw("[\(tag)] \(message)") }
  static func success(_ tag: String, _ message: String) { info(tag, message) }
  static func warn(_ tag: String, _ message: String) { info(tag, message) }
  static func error(_ tag: String, _ message: String) { info(tag, message) }
  static func debug(_ tag: String, _ message: @autoclosure () -> String) {
    if isVerbose { info(tag, message()) }
  }
  static func meter(_ message: @autoclosure () -> String) {
    lock.lock()
    let enabled = verbose && !privacy
    let key = secret
    lock.unlock()
    guard enabled else { return }
    let line = message()
    writer.submit(
      key.isEmpty ? line : line.replacingOccurrences(of: key, with: "[redacted]"), meter: true)
  }
  static func endMeter() { writer.submit("", endMeter: true) }
}
