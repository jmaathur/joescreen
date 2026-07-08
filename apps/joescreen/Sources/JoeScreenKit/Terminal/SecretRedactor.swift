import Foundation

/// Best-effort pre-transmit secret redaction for the shared terminal (spec F12 / D14).
///
/// IMPORTANT: this is documented as best-effort and is NEVER a security boundary. It reduces the
/// chance of casually leaking an obvious credential into a shared PTY stream; it does not and
/// cannot guarantee no secret is transmitted. It is applied BEFORE the terminal channel sees any
/// bytes. It is fail-open: on any internal error it passes bytes through rather than crashing the
/// byte pump (a dropped terminal is worse than an un-redacted one, and it's not a boundary).
public struct SecretRedactor: Sendable {

    public struct Config: Sendable {
        /// Replace matched secrets with this marker.
        public var mask: String
        /// Minimum length for the entropy scan to consider a token.
        public var entropyMinLength: Int
        /// Shannon-entropy (bits/char) threshold above which a long token is masked.
        public var entropyBitsThreshold: Double
        public var enableEntropyScan: Bool
        public init(mask: String = "«redacted»",
                    entropyMinLength: Int = 20,
                    entropyBitsThreshold: Double = 4.0,
                    enableEntropyScan: Bool = true) {
            self.mask = mask; self.entropyMinLength = entropyMinLength
            self.entropyBitsThreshold = entropyBitsThreshold; self.enableEntropyScan = enableEntropyScan
        }
    }

    private let config: Config
    private let patterns: [NSRegularExpression]

    public init(config: Config = Config()) {
        self.config = config
        // Obvious credential shapes. Deliberately conservative; false-negatives are expected.
        let sources = [
            #"(?i)\b(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{16,}\b"#,   // Stripe-style keys
            #"\bAKIA[0-9A-Z]{16}\b"#,                                   // AWS access key id
            #"\bghp_[A-Za-z0-9]{36}\b"#,                                // GitHub PAT
            #"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#,                       // Slack token
            #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#, // JWT
            #"\b(?:\d[ -]?){13,16}\b"#,                                 // card-ish digit runs
            #"\b\d{3}-\d{2}-\d{4}\b"#,                                  // US SSN
            #"(?i)\b(?:password|passwd|secret|token|api[_-]?key)\s*[:=]\s*\S+"#, // key: value
        ]
        self.patterns = sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }

    /// Redact a UTF-8 terminal chunk. Non-UTF-8 bytes pass through untouched (fail-open).
    public func redact(_ bytes: Data) -> Data {
        guard let text = String(data: bytes, encoding: .utf8) else { return bytes }
        let redacted = redact(text)
        return redacted.data(using: .utf8) ?? bytes
    }

    /// Redact a string. Applies regex patterns, then the entropy scan on remaining long tokens.
    public func redact(_ text: String) -> String {
        var out = text
        for re in patterns {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: config.mask)
        }
        guard config.enableEntropyScan else { return out }
        return maskHighEntropyTokens(out)
    }

    private func maskHighEntropyTokens(_ text: String) -> String {
        // Split on whitespace, mask individual high-entropy long tokens, rejoin preserving spacing.
        // We rebuild by scanning tokens and their trailing separators.
        var result = ""
        var token = ""
        func flushToken() {
            if !token.isEmpty {
                result += shouldMask(token) ? config.mask : token
                token = ""
            }
        }
        for ch in text {
            if ch.isWhitespace {
                flushToken()
                result.append(ch)
            } else {
                token.append(ch)
            }
        }
        flushToken()
        return result
    }

    private func shouldMask(_ token: String) -> Bool {
        guard token.count >= config.entropyMinLength else { return false }
        // Only consider "credential-shaped" tokens (no spaces, mixed alnum) to avoid masking prose.
        let alnum = token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "+" || $0 == "/" || $0 == "=" }
        guard alnum else { return false }
        return Self.shannonEntropy(token) >= config.entropyBitsThreshold
    }

    /// Shannon entropy in bits per character.
    static func shannonEntropy(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0.0) { acc, c in
            let p = Double(c) / n
            return acc - p * log2(p)
        }
    }
}
