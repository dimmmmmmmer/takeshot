import Foundation

/// What an operator types into the SRT address field, taken apart.
///
/// SRT keeps the host, the port and the role as separate parameters — the
/// protocol has no URL, and the three used to be three controls. But every tool
/// an operator has already met writes them as ONE string: OBS, ffmpeg and
/// libsrt's own tools all take `srt://host:port?mode=caller`, which is why the
/// mode looked to the owner like a setting OBS does not have (it is in the URL
/// there). Typing a host into one box and a port into another, and then picking
/// the mode from a third, is this app asking for the same thing in pieces.
///
/// So the address field accepts what those tools accept, and fills the other
/// controls in. They stay on screen and stay editable — this is a convenience
/// that ARRIVES at them, not a replacement that hides where the values went.
public enum SRTAddress {
    /// The pieces a typed address carries. Anything it does not name is nil,
    /// and the caller keeps whatever it already had — a pasted bare host must
    /// not silently reset a port the operator set on purpose.
    public struct Parsed: Equatable, Sendable {
        public var host: String
        public var port: Int?
        public var mode: String?
        public var latencyMs: Int?
        public var passphrase: String?
    }

    /// Ports below 1024 need root and above 65535 do not exist.
    public static let portRange = 1024...65535

    /// Take `typed` apart. Returns nil only for a string with no host in it at
    /// all, which is what an empty field and a stray "srt://" both are.
    ///
    /// Accepts, in the order an operator is likely to type them:
    /// `host`, `host:port`, `srt://host:port`, and any of those with libsrt's
    /// query parameters after them.
    public static func parse(_ typed: String) -> Parsed? {
        var rest = typed.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        if let scheme = rest.range(of: "://") { rest = String(rest[scheme.upperBound...]) }

        var query: Substring = ""
        if let mark = rest.firstIndex(of: "?") {
            query = rest[rest.index(after: mark)...]
            rest = String(rest[..<mark])
        }
        // A trailing path is not part of an SRT endpoint; libsrt has no path.
        if let slash = rest.firstIndex(of: "/") { rest = String(rest[..<slash]) }

        let (host, port) = splitHostAndPort(rest)
        guard !host.isEmpty else { return nil }

        var parsed = Parsed(host: host, port: port, mode: nil,
                            latencyMs: nil, passphrase: nil)
        apply(query: query, to: &parsed)
        return parsed
    }

    /// libsrt's query parameters, of which three matter here.
    private static func apply(query: Substring, to parsed: inout Parsed) {
        for pair in query.split(separator: "&") {
            let halves = pair.split(separator: "=", maxSplits: 1)
            guard halves.count == 2 else { continue }
            let value = String(halves[1])
            switch halves[0].lowercased() {
            case "mode": parsed.mode = value.lowercased()
            // libsrt spells the same number three ways depending on which side
            // is being configured; all three mean this link's delivery buffer.
            case "latency", "rcvlatency", "peerlatency":
                parsed.latencyMs = Int(value)
            case "passphrase": parsed.passphrase = value
            default: break
            }
        }
    }

    /// Host and port, with IPv6 in brackets kept whole.
    ///
    /// `[::1]:9000` is the case a plain `split(":")` gets wrong — it would read
    /// the address's own colons as separators and hand back a port of nothing.
    private static func splitHostAndPort(_ text: String) -> (String, Int?) {
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let after = text[text.index(after: close)...]
            guard after.hasPrefix(":") else { return (host, nil) }
            return (host, port(String(after.dropFirst())))
        }
        guard let colon = text.lastIndex(of: ":"),
              !text[..<colon].contains(":") else {
            // More than one colon and no brackets: a bare IPv6 literal, which
            // carries no port.
            return (text, nil)
        }
        return (String(text[..<colon]), port(String(text[text.index(after: colon)...])))
    }

    private static func port(_ text: String) -> Int? {
        guard let value = Int(text), portRange.contains(value) else { return nil }
        return value
    }
}
