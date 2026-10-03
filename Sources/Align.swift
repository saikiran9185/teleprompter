import Foundation

/// Word matching between what you read (the script) and what speech recognition heard.
enum Words {
    static func norm(_ w: String) -> String {
        let folded = w.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "'" }.map(Character.init))
    }

    static func similar(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.count >= 3 && b.count >= 3 && (a.hasPrefix(b) || b.hasPrefix(a)) { return 0.85 }
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = Array(0...y.count), cur = Array(repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// Live follow: walk forward through the script; each heard word may match one of the next six script words.
    /// Returns the index of the next word to read and the set of words already read.
    static func follow(script: [String], heard: [String]) -> (pos: Int, read: Set<Int>) {
        var pos = 0
        var read = Set<Int>()
        for h in heard {
            var best = 0.0, bj = -1
            for j in pos..<min(script.count, pos + 6) {
                let s = similar(script[j], h)
                if s > best { best = s; bj = j }
            }
            if bj >= 0 && best >= 0.7 {
                for j in pos...bj { read.insert(j) }
                pos = bj + 1
            }
        }
        return (pos, read)
    }

    /// Take check: best-matching run of the take against ANY span of the script (Smith-Waterman), so a pickup
    /// that only re-reads the end of a line is recognised. Returns script index -> heard index.
    static func localAlign(script: [String], heard: [String]) -> [Int: Int] {
        let n = script.count, m = heard.count
        guard n > 0, m > 0 else { return [:] }
        var S = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
        var B = Array(repeating: Array(repeating: UInt8(0), count: m + 1), count: n + 1)
        var bestV = 0.0, bi = 0, bj = 0
        for i in 1...n {
            for j in 1...m {
                let sim = similar(script[i - 1], heard[j - 1])
                let diag = S[i - 1][j - 1] + (sim >= 0.85 ? 2 : sim >= 0.6 ? 1 : -1)
                let up = S[i - 1][j] - 1, left = S[i][j - 1] - 0.8
                let v = max(0, diag, up, left)
                S[i][j] = v
                B[i][j] = v == 0 ? 0 : v == diag ? 1 : v == up ? 2 : 3
                if v > bestV { bestV = v; bi = i; bj = j }
            }
        }
        var map: [Int: Int] = [:]
        var i = bi, j = bj
        while i > 0 && j > 0 && B[i][j] != 0 {
            switch B[i][j] {
            case 1:
                if similar(script[i - 1], heard[j - 1]) >= 0.6 { map[i - 1] = j - 1 }
                i -= 1; j -= 1
            case 2: i -= 1
            default: j -= 1
            }
        }
        return map
    }
}
