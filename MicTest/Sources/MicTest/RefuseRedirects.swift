//  RefuseRedirects.swift
//
//  The one `URLSessionTaskDelegate` every loopback whisper session in this app is built
//  with, so that no request carrying microphone audio can be redirected off this Mac.
//
//  ── WHY A DELEGATE AT ALL ────────────────────────────────────────────────────────────
//
//  `WhisperClient` POSTs each finished utterance's WAV to `127.0.0.1:<port>/inference`,
//  and `WhisperServerManager` probes and warms the same port. A `URLSession` built from a
//  configuration alone follows HTTP redirects by default, and for a 307/308 it re-sends
//  the original body. So a process that had merely bound the loopback port before the
//  app's own `whisper-server` did — any unprivileged process can — could answer
//  `307 Location: https://<anywhere>` and have Foundation deliver the user's speech to
//  that host, with nothing in this app ever having named it. Loopback is not a trust
//  boundary against other processes of the same user; the redirect rule makes it one for
//  this traffic.
//
//  Refusing is `completionHandler(nil)`: the session then finishes the task with the 3xx
//  response as its final result and never issues the second request. `WhisperClient`
//  sees that as `ClientError.httpStatus(3xx)` and the manager's probe as "not ready",
//  which is the correct reading of a whisper-server that suddenly redirects — there is
//  no such thing.
//
//  Measured 2026-09-03 (this file's first build, `WhisperClient` compiled standalone):
//  a 307 from a stand-in listener on 127.0.0.1:8199 with `Location:
//  http://127.0.0.1:8198/inference` reached the client as `httpStatus(307)`, and
//  `nc -l 127.0.0.1 8198` received 0 bytes.

import Foundation

/// `URLSessionTaskDelegate` that refuses every HTTP redirect. Stateless, so `Sendable` is
/// trivially honest; `NSObject` because the delegate protocol demands it.
final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {

    /// Build a session that will never follow a redirect. The configuration is the
    /// caller's — timeouts and connection limits differ per use — and only the delegate
    /// is fixed here, so there is exactly one way to make a loopback whisper session.
    static func session(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: RefuseRedirects(),
                   delegateQueue: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
