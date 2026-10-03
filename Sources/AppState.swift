import AppKit
import AVFoundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var project: Project?
    @Published var script = Script.sample
    @Published var index = 0
    @Published var takes: [String: [Take]] = [:]
    @Published var editing = false
    @Published var fontSize: Double = UserDefaults.standard.object(forKey: "fontSize") as? Double ?? 52 {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") }
    }
    @Published var mirror = false
    @Published var countIn = UserDefaults.standard.object(forKey: "countIn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(countIn, forKey: "countIn") }
    }
    @Published var autoStop = UserDefaults.standard.object(forKey: "autoStop") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoStop, forKey: "autoStop"); studio.autoStop = autoStop }
    }
    @Published var playing: URL?
    @Published var toast: String?

    let studio = Studio()
    private var player: AVAudioPlayer?
    private var keyMonitor: Any?

    var lines: [ScriptLine] { script.allLines }
    var line: ScriptLine? { lines.indices.contains(index) ? lines[index] : nil }
    var recent: [String] { UserDefaults.standard.stringArray(forKey: "recentProjects") ?? [] }

    init() {
        studio.autoStop = autoStop
        studio.onTakeFinished = { [weak self] url in self?.finished(url) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.handle(e) else { return e }
            return nil
        }
        if let last = recent.first, FileManager.default.fileExists(atPath: last) {
            open(URL(fileURLWithPath: last))
        }
    }

    // MARK: projects

    func open(_ folder: URL) {
        let p = Project(folder: folder)
        guard let s = try? p.load() else { toast = "No script.json in \(folder.lastPathComponent)"; return }
        project = p
        script = s
        index = 0
        editing = false
        reloadTakes()
        var r = recent.filter { $0 != folder.path }
        r.insert(folder.path, at: 0)
        UserDefaults.standard.set(Array(r.prefix(8)), forKey: "recentProjects")
        studio.prepare(language: s.lang)
    }

    func newProject(named name: String, from text: String? = nil) {
        let script = text.map { Script.fromPlainText($0, title: name) } ?? .sample
        do { open(try Project.create(named: name, script: script).folder) } catch { toast = error.localizedDescription }
    }

    func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = Project.root
        panel.prompt = "Open Project"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func closeProject() {
        if studio.recording { studio.stop() }
        project = nil
    }

    func saveScript() {
        guard let project else { return }
        try? project.save(script)
        if !lines.indices.contains(index) { index = max(0, lines.count - 1) }
        reloadTakes()
        studio.setLanguage(script.lang)
    }

    func reloadTakes() {
        guard let project else { return }
        var t: [String: [Take]] = [:]
        for l in lines { t[l.id] = project.takes(for: l.id) }
        takes = t
    }

    func exportChosen() {
        guard let project else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Each line's chosen take is saved as <line id>.wav"
        if panel.runModal() == .OK, let dir = panel.url {
            let n = project.exportChosen(to: dir, lines: lines)
            toast = "Exported \(n) of \(lines.count) lines"
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    // MARK: recording

    func toggleRecord() {
        guard !editing, let line, let project else { return }
        if studio.recording { studio.stop(); return }
        guard let url = try? project.newTakeURL(for: line.id) else { return }
        stopPlayback()
        studio.start(to: url, words: line.words.map(\.norm), countIn: countIn)
    }

    private func finished(_ url: URL) {
        guard let project, let line = lines.first(where: { project.lineDir($0.id) == url.deletingLastPathComponent() }) else { return }
        reloadTakes()
        studio.checking.insert(url.lastPathComponent)
        Task {
            let result = await studio.check(take: url, line: line, language: script.lang)
            project.saveCheck(result, for: url)
            studio.checking.remove(url.lastPathComponent)
            reloadTakes()
        }
    }

    func use(_ take: Take) {
        guard let project, let line else { return }
        project.choose(take, for: line.id)
        reloadTakes()
    }

    func delete(_ take: Take) {
        guard let project else { return }
        if playing == take.url { stopPlayback() }
        project.delete(take)
        reloadTakes()
    }

    func play(_ take: Take) {
        if playing == take.url { stopPlayback(); return }
        player = try? AVAudioPlayer(contentsOf: take.url)
        player?.play()
        playing = take.url
        let d = take.duration
        DispatchQueue.main.asyncAfter(deadline: .now() + d + 0.1) { [weak self] in
            if self?.playing == take.url { self?.playing = nil }
        }
    }

    func stopPlayback() { player?.stop(); playing = nil }

    // MARK: keyboard

    private func handle(_ e: NSEvent) -> Bool {
        guard project != nil, !editing else { return false }
        if NSApp.keyWindow?.firstResponder is NSTextView { return false }
        if e.modifierFlags.contains(.command) { return false }
        switch e.keyCode {
        case 49: toggleRecord(); return true                              // space
        case 124: if !studio.recording { index = min(lines.count - 1, index + 1) }; return true  // →
        case 123: if !studio.recording { index = max(0, index - 1) }; return true                // ←
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "p": if let t = takes[line?.id ?? ""]?.last { play(t) }; return true
        case "u": if let t = takes[line?.id ?? ""]?.last { use(t) }; return true
        case "r": if !studio.recording { toggleRecord() }; return true
        default: return false
        }
    }
}
