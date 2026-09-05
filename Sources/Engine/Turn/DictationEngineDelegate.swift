public protocol DictationEngineDelegate: AnyObject, Sendable {
  func engineDidEmit(_ event: EngineEvent)
}
