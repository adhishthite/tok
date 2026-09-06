import Foundation

final class PostProcessingRedirectPolicy: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // The API key must only go to the fixed Google endpoint.
    completionHandler(nil)
  }
}
