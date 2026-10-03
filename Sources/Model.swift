import AVFoundation
import Foundation

// MARK: - Script (same JSON as the original VO Studio web version)

struct ScriptLine: Codable, Identifiable, Hashable {
    var id: String
    var text: String
    var note: String = ""
    var target: Double = 5

    init(id: String, text: String, note: String = "", target: Double? = nil) {
        self.id = id
        self.text = text
        self.note = note
        self.target = target ?? ScriptLine.estimate(text)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        target = try c.decodeIfPresent(Double.self, forKey: .target) ?? ScriptLine.estimate(text)
    }

    /// Seconds at a comfortable narration pace (~150 words a minute).
    static func estimate(_ text: String) -> Double {
        let n = Token.parse(text).filter { $0.isWord }.count
        return max(1.5, (Double(n) / 2.5 * 2).rounded() / 2)
    }

    var tokens: [Token] { Token.parse(text) }
    var words: [Token] { tokens.filter { $0.isWord } }
    var plain: String { tokens.map { $0.isWord ? $0.display : "" }.filter { !$0.isEmpty }.joined(separator: " ") }
}

struct ScriptSection: Codable, Identifiable, Hashable {
    var name: String
    var color: Int = 0
    var lines: [ScriptLine]
    var id: String { name }

    enum CodingKeys: String, CodingKey { case name, color, store, lines }

    init(name: String, color: Int = 0, lines: [ScriptLine]) {
        self.name = name
        self.color = color
        self.lines = lines
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(Int.self, forKey: .color) ?? c.decodeIfPresent(Int.self, forKey: .store) ?? 0
        lines = try c.decode([ScriptLine].self, forKey: .lines)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(color, forKey: .color)
        try c.encode(lines, forKey: .lines)
    }
}

struct Script: Codable {
    var title: String
    var lang: String = "en-IN"
    var sections: [ScriptSection]

    var allLines: [ScriptLine] { sections.flatMap { $0.lines } }

    /// Plain text → script: blank lines separate lines to record, "# Heading" starts a section.
    static func fromPlainText(_ text: String, title: String) -> Script {
        var sections: [ScriptSection] = []
        var current = ScriptSection(name: "Script", lines: [])
        var paragraph: [String] = []
        var n = 0
        func flush() {
            let t = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { n += 1; current.lines.append(ScriptLine(id: "VO\(n)", text: t)) }
            paragraph = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                flush()
                if !current.lines.isEmpty { sections.append(current) }
                current = ScriptSection(name: line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")),
                                        color: sections.count % 4, lines: [])
            } else if line.isEmpty {
                flush()
            } else {
                paragraph.append(line)
            }
        }
        flush()
        if !current.lines.isEmpty { sections.append(current) }
        return Script(title: title, sections: sections)
    }

    static let sample = Script(title: "My first script", sections: [
        ScriptSection(name: "How it works", color: 0, lines: [
            ScriptLine(id: "VO1", text: "Press *space* and wait for three, two, one. / Then just read — the yellow word follows your voice.",
                       note: "relaxed"),
            ScriptLine(id: "VO2", text: "When you reach the last word, recording stops by itself, and every take is checked word by word.",
                       note: "steady pace"),
        ]),
        ScriptSection(name: "Your turn", color: 1, lines: [
            ScriptLine(id: "VO3", text: "Click *Edit script* to write your own lines. / Wrap a word in stars for emphasis, and put a slash where you want to breathe.",
                       note: "try marking a pause"),
        ]),
    ])
}

/// One piece of a line: a word (with emphasis) or a breath mark "/".
struct Token: Hashable {
    let display: String
    let norm: String
    let emphasis: Bool
    let isWord: Bool

    static func parse(_ text: String) -> [Token] {
        text.split(whereSeparator: { $0.isWhitespace }).map { piece in
            let s = String(piece)
            if s == "/" { return Token(display: "/", norm: "", emphasis: false, isWord: false) }
            let emph = s.hasPrefix("*") && s.contains("*", after: 1)
            let display = s.replacingOccurrences(of: "*", with: "")
            return Token(display: display, norm: Words.norm(display), emphasis: emph, isWord: true)
        }
    }
}

private extension String {
    func contains(_ ch: Character, after offset: Int) -> Bool {
        dropFirst(offset).contains(ch)
    }
}

// MARK: - Takes and checks (same files as VO Studio: takes/<line>/take_N.wav + take_N.json + chosen.txt)

struct WordCheck: Codable, Hashable {
    var w: String
    var ok: Bool
    var start: Double?
    var end: Double?
}

struct CheckResult: Codable, Hashable {
    var state: String
    var accuracy: Double?
    var words: [WordCheck]?
    var heard: String?
    var speech_start: Double?
    var speech_end: Double?
    var wpm: Int?
    var covers: [Int]?   // first/last script word the take covers (pickups cover part of a line)
    var error: String?
}

struct Take: Identifiable, Hashable {
    let url: URL
    let number: Int
    var duration: Double
    var check: CheckResult?
    var chosen: Bool
    var id: String { url.lastPathComponent }
}

final class Project {
    let folder: URL
    init(folder: URL) { self.folder = folder }

    var name: String { folder.lastPathComponent }
    var scriptURL: URL { folder.appendingPathComponent("script.json") }
    var takesDir: URL { folder.appendingPathComponent("takes") }

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Teleprompter")
    }

    static func create(named name: String, script: Script = .sample) throws -> Project {
        var folder = root.appendingPathComponent(name)
        var k = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = root.appendingPathComponent("\(name) \(k)"); k += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let p = Project(folder: folder)
        var s = script
        s.title = s.title == Script.sample.title ? name : s.title
        try p.save(s)
        return p
    }

    func load() throws -> Script {
        try JSONDecoder().decode(Script.self, from: Data(contentsOf: scriptURL))
    }

    func save(_ script: Script) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if FileManager.default.fileExists(atPath: scriptURL.path) {
            let backup = folder.appendingPathComponent(".backups", isDirectory: true)
            try? FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: scriptURL, to: backup.appendingPathComponent("script-\(Int(Date().timeIntervalSince1970)).json"))
        }
        try enc.encode(script).write(to: scriptURL)
    }

    func lineDir(_ id: String) -> URL { takesDir.appendingPathComponent(id) }

    func takes(for id: String) -> [Take] {
        let dir = lineDir(id)
        let chosen = (try? String(contentsOf: dir.appendingPathComponent("chosen.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> Take? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "wav", name.hasPrefix("take_"), let n = Int(name.dropFirst(5)) else { return nil }
            let check = (try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")))
                .flatMap { try? JSONDecoder().decode(CheckResult.self, from: $0) }
            return Take(url: url, number: n, duration: Self.duration(url), check: check, chosen: url.lastPathComponent == chosen)
        }.sorted { $0.number < $1.number }
    }

    func newTakeURL(for id: String) throws -> URL {
        let dir = lineDir(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let n = (takes(for: id).map(\.number).max() ?? 0) + 1
        return dir.appendingPathComponent("take_\(n).wav")
    }

    func choose(_ take: Take, for id: String) {
        try? take.url.lastPathComponent.write(to: lineDir(id).appendingPathComponent("chosen.txt"), atomically: true, encoding: .utf8)
    }

    func delete(_ take: Take) {
        try? FileManager.default.removeItem(at: take.url)
        try? FileManager.default.removeItem(at: take.url.deletingPathExtension().appendingPathExtension("json"))
    }

    func saveCheck(_ check: CheckResult, for take: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        try? enc.encode(check).write(to: take.deletingPathExtension().appendingPathExtension("json"))
    }

    /// Copies every chosen take to `dir` as <line id>.wav. Returns how many were exported.
    func exportChosen(to dir: URL, lines: [ScriptLine]) -> Int {
        var n = 0
        for line in lines {
            guard let t = takes(for: line.id).first(where: \.chosen) else { continue }
            let dst = dir.appendingPathComponent("\(line.id).wav")
            try? FileManager.default.removeItem(at: dst)
            if (try? FileManager.default.copyItem(at: t.url, to: dst)) != nil { n += 1 }
        }
        return n
    }

    static func duration(_ url: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(f.length) / f.fileFormat.sampleRate
    }
}
