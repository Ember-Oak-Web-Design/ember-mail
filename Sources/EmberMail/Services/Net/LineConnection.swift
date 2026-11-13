@preconcurrency import Foundation
import Network

/// Fires exactly once — used to guard continuations against double-resume.
final class OnceFlag: @unchecked Sendable {
    private var fired = false
    private let lock = NSLock()
    func fire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

/// Async/await wrapper around NWConnection for line-oriented protocols (IMAP, SMTP).
/// Not thread-safe by itself: use it from a single actor.
final class LineConnection: @unchecked Sendable {
    private let connection: NWConnection
    private var buffer = Data()
    private let queue = DispatchQueue(label: "com.emberoak.mail.connection")
    private static let crlf = Data([13, 10])

    init(host: String, port: Int, useTLS: Bool) {
        let parameters: NWParameters
        if useTLS {
            parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        } else {
            parameters = .tcp
        }
        let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? .imaps
        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
    }

    func open(timeout: TimeInterval = 20) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.fire() { cont.resume() }
                case .failed(let error):
                    if once.fire() { cont.resume(throwing: MailError.network(error.localizedDescription)) }
                case .waiting(let error):
                    if once.fire() {
                        self?.connection.cancel()
                        cont.resume(throwing: MailError.network(error.localizedDescription))
                    }
                case .cancelled:
                    if once.fire() { cont.resume(throwing: MailError.connectionClosed) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                if once.fire() {
                    self?.connection.cancel()
                    cont.resume(throwing: MailError.timeout)
                }
            }
        }
    }

    func close() {
        connection.cancel()
    }

    private func receiveChunk(timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let watchdog = DispatchWorkItem { [weak self] in self?.connection.cancel() }
            queue.asyncAfter(deadline: .now() + timeout, execute: watchdog)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                watchdog.cancel()
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if let error {
                    cont.resume(throwing: MailError.network(error.localizedDescription))
                } else if isComplete {
                    cont.resume(throwing: MailError.connectionClosed)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    /// Reads one line, without the trailing CRLF.
    func readLine(timeout: TimeInterval = 90) async throws -> Data {
        var searchStart = 0
        while true {
            if buffer.count > searchStart,
               let range = buffer.range(of: Self.crlf, in: (buffer.startIndex + searchStart)..<buffer.endIndex) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer = buffer.subdata(in: range.upperBound..<buffer.endIndex)
                return line
            }
            searchStart = max(0, buffer.count - 1)
            buffer.append(try await receiveChunk(timeout: timeout))
        }
    }

    /// Reads exactly `count` bytes.
    func readBytes(_ count: Int, timeout: TimeInterval = 90) async throws -> Data {
        while buffer.count < count {
            buffer.append(try await receiveChunk(timeout: timeout))
        }
        let out = buffer.subdata(in: buffer.startIndex..<(buffer.startIndex + count))
        buffer = buffer.subdata(in: (buffer.startIndex + count)..<buffer.endIndex)
        return out
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: MailError.network(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    func send(line: String) async throws {
        try await send(Data((line + "\r\n").utf8))
    }
}

extension Data {
    /// Decodes as UTF-8, falling back to ISO Latin 1 so we never lose a line.
    var lenientString: String {
        String(data: self, encoding: .utf8) ?? String(data: self, encoding: .isoLatin1) ?? ""
    }
}
