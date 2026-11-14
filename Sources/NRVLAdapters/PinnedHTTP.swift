import CryptoKit
import Foundation
import NRVLCore

/// The TLS rule for talking to infrastructure.
enum TLSPolicy {
    /// - With an approved fingerprint: accept exactly that certificate and nothing else.
    /// - Without one: accept only what the system already trusts (a public or user-installed authority).
    /// A self-signed certificate is therefore refused until the user has seen and approved its fingerprint.
    static func accepts(pinned: String?, presented: String, systemTrusted: Bool) -> Bool {
        if let pinned { return pinned.lowercased() == presented.lowercased() }
        return systemTrusted
    }
}

/// HTTPS to one configured host with certificate pinning. Certificate validation is never switched off.
public final class PinnedHTTP: NSObject, URLSessionDelegate, @unchecked Sendable {
    public let baseURL: URL
    private let pinned: String?
    private let lock = NSLock()
    private var presented: String?
    private var session: URLSession!

    /// `protocolClasses` exists so tests can serve canned replies; production code never passes it.
    public init(host: String, port: Int?, pinnedCertificate: String?, timeout: TimeInterval = 10,
                protocolClasses: [AnyClass]? = nil) throws {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port
        guard !host.isEmpty, let url = components.url else { throw AdapterError.unreachable("\"\(host)\" is not a valid address.") }
        baseURL = url
        pinned = pinnedCertificate
        super.init()
        let configuration = URLSessionConfiguration.ephemeral   // no cookies, cache or credentials on disk
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
            return (.performDefaultHandling, nil)
        }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        lock.withLock { presented = fingerprint }
        let accepted = TLSPolicy.accepts(pinned: pinned, presented: fingerprint, systemTrusted: SecTrustEvaluateWithError(trust, nil))
        return accepted ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }

    /// Sends a request to a path on the configured host and maps every failure to `AdapterError`.
    public func send(_ method: String = "GET", _ path: String, headers: [String: String] = [:], body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: baseURL), url.host == baseURL.host else {
            throw AdapterError.protocolError("Refusing to contact a different host.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AdapterError.protocolError("Not an HTTP response.") }
            switch http.statusCode {
            case 401: throw AdapterError.authenticationFailed
            case 403: throw AdapterError.permissionDenied(path)
            default: return (data, http)
            }
        } catch let error as AdapterError {
            throw error
        } catch let error as URLError {
            let fingerprint = lock.withLock { presented }
            switch error.code {
            case .cancelled, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .secureConnectionFailed:
                if let fingerprint {
                    throw pinned == nil ? AdapterError.tlsUntrusted(fingerprint: fingerprint) : AdapterError.tlsChanged(fingerprint: fingerprint)
                }
                throw AdapterError.unreachable(error.localizedDescription)
            case .timedOut: throw AdapterError.timeout
            default: throw AdapterError.unreachable(error.localizedDescription)
            }
        }
    }

    /// Decodes a JSON reply, treating a non-2xx status or undecodable body as a protocol error.
    public func json<T: Decodable>(_ type: T.Type, _ method: String = "GET", _ path: String, headers: [String: String] = [:], body: Data? = nil) async throws -> T {
        let (data, response) = try await send(method, path, headers: headers, body: body)
        guard (200..<300).contains(response.statusCode) else {
            throw AdapterError.protocolError("HTTP \(response.statusCode) for \(path)")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw AdapterError.protocolError("The answer for \(path) was not in the expected format.")
        }
    }
}
