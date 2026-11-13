import Foundation

enum HTTP {
    static let decoder: JSONDecoder = JSONDecoder()

    static func data(_ request: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MailError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MailError.protocolError("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.errorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            if http.statusCode == 401 || http.statusCode == 403 {
                throw MailError.authFailed(message)
            }
            throw MailError.server("\(message) (HTTP \(http.statusCode))")
        }
        return data
    }

    static func json<T: Decodable>(_ type: T.Type, _ request: URLRequest) async throws -> T {
        let data = try await self.data(request)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw MailError.protocolError("Couldn't read server response (\(error.localizedDescription))")
        }
    }

    /// Google-style `{ "error": { "message": ... } }` or `{ "error_description": ... }`.
    private static func errorMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty == false && (text?.count ?? 0) < 200) ? text : nil
        }
        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
        if let desc = obj["error_description"] as? String { return desc }
        if let err = obj["error"] as? String { return err }
        return nil
    }

    static func formBody(_ params: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = params.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s, options: .ignoreUnknownCharacters)
    }
}
