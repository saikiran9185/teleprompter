import AppKit
import SwiftUI

enum Palette {
    static let bg = Color(red: 0.055, green: 0.055, blue: 0.063)
    static let panel = Color(red: 0.09, green: 0.09, blue: 0.106)
    static let panel2 = Color(red: 0.12, green: 0.12, blue: 0.145)
    static let line = Color.white.opacity(0.09)
    static let ink = Color(red: 0.957, green: 0.945, blue: 0.918)
    static let dim = Color(red: 0.55, green: 0.54, blue: 0.58)
    static let yellow = Color(red: 1, green: 0.827, blue: 0.102)
    static let pink = Color(red: 1, green: 0.247, blue: 0.643)
    static let lime = Color(red: 0.651, green: 0.89, blue: 0.353)
    static let cyan = Color(red: 0.204, green: 0.776, blue: 0.949)
    static let red = Color(red: 1, green: 0.294, blue: 0.294)
    static let sections = [cyan, yellow, pink, lime]
    static func section(_ i: Int) -> Color { sections[((i % 4) + 4) % 4] }
}

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            if app.project == nil {
                WelcomeView()
            } else {
                NavigationSplitView {
                    Sidebar().navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 380)
                } detail: {
                    VStack(spacing: 0) {
                        if app.editing { EditorView() } else { PrompterView() }
                        TransportBar()
                    }
                    .background(Palette.bg)
                }
                .toolbar { Toolbar() }
                .navigationTitle(app.script.title)
            }
        }
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) {
            if let t = app.toast {
                Text(t).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Palette.panel2, in: Capsule()).padding(.top, 12)
                    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { app.toast = nil } }
            }
        }
    }
}

// MARK: - toolbar

struct Toolbar: ToolbarContent {
    @EnvironmentObject var app: AppState
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            let ready = app.lines.filter { (app.takes[$0.id] ?? []).contains(where: \.chosen) }.count
            Text("\(ready) / \(app.lines.count) ready").font(.callout).foregroundStyle(Palette.dim)
            if !app.editing {
                Slider(value: $app.fontSize, in: 28...96).frame(width: 110).help("Text size")
                Toggle("Mirror", isOn: $app.mirror).help("Flip horizontally for teleprompter glass")
                Toggle("3-2-1", isOn: $app.countIn)
                Toggle("Auto-stop", isOn: $app.autoStop)
            }
            Button(app.editing ? "Done" : "Edit script") {
                if app.editing { app.saveScript() }
                app.editing.toggle()
            }
            .keyboardShortcut("e", modifiers: .command)
        }
    }
}

// MARK: - sidebar

struct Sidebar: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        List(selection: Binding(get: { app.line?.id }, set: { id in
            if let id, !app.studio.recording, let i = app.lines.firstIndex(where: { $0.id == id }) { app.index = i }
        })) {
            ForEach(app.script.sections) { sec in
                Section {
                    ForEach(sec.lines) { line in
                        let t = app.takes[line.id] ?? []
                        HStack(alignment: .top, spacing: 10) {
                            Text(line.id).font(.caption.weight(.bold)).foregroundStyle(Palette.dim).frame(width: 34, alignment: .leading)
                            Text(line.plain).font(.callout).lineLimit(2).foregroundStyle(Palette.ink.opacity(0.85))
                            Spacer(minLength: 4)
                            Circle()
                                .strokeBorder(t.isEmpty ? Palette.line : Palette.yellow, lineWidth: 2)
                                .background(Circle().fill(t.contains(where: \.chosen) ? Palette.lime : .clear))
                                .frame(width: 11, height: 11).padding(.top, 4)
                        }
                        .padding(.vertical, 3)
                        .tag(line.id)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Rectangle().fill(Palette.section(sec.color)).frame(width: 8, height: 8).rotationEffect(.degrees(45))
                        Text(sec.name.uppercased()).font(.caption2.weight(.bold)).tracking(1.2)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { app.exportChosen() } label: { Label("Export chosen", systemImage: "square.and.arrow.up") }
                Spacer()
                Button { if let p = app.project { NSWorkspace.shared.activateFileViewerSelecting([p.folder]) } } label: { Image(systemName: "folder") }
                    .help("Show project in Finder")
                Button { app.closeProject() } label: { Image(systemName: "xmark.circle") }.help("Close project")
            }
            .buttonStyle(.borderless).padding(12)
        }
    }
}

// MARK: - prompter

struct PrompterView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var studio: Studio

    var body: some View {
        let lines = app.lines
        ZStack {
          VStack(spacing: 8) {
            Group {
                if !studio.micAllowed {
                    Banner(text: "Microphone access is off. Allow Teleprompter in System Settings › Privacy & Security › Microphone, then reopen the app.")
                } else if studio.lowQualityInput {
                    Banner(text: "“\(studio.inputName)” records at \(Int(studio.sampleRate / 1000)) kHz — phone quality. This is usually a Bluetooth headset or AirPods. For a clean voice-over pick the Mac's microphone or a wired/USB mic in System Settings › Sound › Input.")
                }
                if !studio.speechNote.isEmpty { Banner(text: studio.speechNote) }
            }
            .padding(.horizontal, 16)
            if let line = app.line {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        if app.index > 0 {
                            Text(lines[app.index - 1].plain).font(.system(size: app.fontSize * 0.42)).foregroundStyle(Palette.dim.opacity(0.55))
                        }
                        HStack(spacing: 10) {
                            let sec = app.script.sections.first(where: { $0.lines.contains(where: { $0.id == line.id }) })
                            Text(line.id).font(.caption.weight(.heavy)).padding(.horizontal, 10).padding(.vertical, 3)
                                .background(Palette.section(sec?.color ?? 0), in: Capsule()).foregroundStyle(.black)
                            Text(sec?.name ?? "").foregroundStyle(Palette.dim)
                            if !line.note.isEmpty { Text("— \(line.note)").italic().foregroundStyle(Palette.ink.opacity(0.7)) }
                        }
                        .font(.callout)
                        Text(attributed(line))
                            .font(.system(size: app.fontSize, weight: .semibold))
                            .lineSpacing(app.fontSize * 0.28)
                            .textSelection(.disabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if studio.recording || !studio.heard.isEmpty {
                            Text(studio.heard.isEmpty ? " " : "hearing: \(studio.heard)")
                                .font(.callout).foregroundStyle(Palette.cyan).lineLimit(1).truncationMode(.head)
                        }
                        if app.index < lines.count - 1 {
                            Text(lines[app.index + 1].plain).font(.system(size: app.fontSize * 0.42)).foregroundStyle(Palette.dim.opacity(0.55))
                        }
                    }
                    .padding(.horizontal, 64).padding(.vertical, 48)
                    .frame(maxWidth: 1250, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scaleEffect(x: app.mirror ? -1 : 1, y: 1)
            }
          }
          .padding(.top, 10)
            if let n = studio.countdown {
                Text("\(n)").font(.system(size: 220, weight: .black)).foregroundStyle(Palette.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.bg.opacity(0.6))
            }
        }
    }

    /// Words you've read turn white with an underline, the next word is yellow, missed words (after a check) red.
    private func attributed(_ line: ScriptLine) -> AttributedString {
        let check = (app.takes[line.id] ?? []).last?.check
        let live = studio.recording
        var out = AttributedString()
        var k = 0
        for tok in line.tokens {
            if !tok.isWord {
                var p = AttributedString("/ ")
                p.foregroundColor = Palette.pink
                out += p
                continue
            }
            var w = AttributedString(tok.display)
            var state = 0 // 0 upcoming, 1 read, 2 now, 3 missed
            if live {
                state = k == studio.followPos ? 2 : studio.readSet.contains(k) ? 1 : 0
            } else if let words = check?.words, check?.state == "done", words.indices.contains(k) {
                state = words[k].ok ? 1 : 3
            }
            switch state {
            case 1: w.foregroundColor = Palette.ink; w.underlineStyle = Text.LineStyle(pattern: .solid, color: Palette.lime)
            case 2: w.foregroundColor = .black; w.backgroundColor = Palette.yellow
            case 3: w.foregroundColor = Palette.red; w.underlineStyle = Text.LineStyle(pattern: .solid, color: Palette.red)
            default: w.foregroundColor = Palette.ink.opacity(0.42)
            }
            if tok.emphasis { w.font = .system(size: app.fontSize, weight: .heavy) }
            out += w
            out += AttributedString(" ")
            k += 1
        }
        return out
    }
}

struct Banner: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(Color(red: 0.95, green: 0.84, blue: 0.48))
            .padding(12).frame(maxWidth: 900, alignment: .leading)
            .background(Color(red: 0.16, green: 0.13, blue: 0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(red: 0.35, green: 0.29, blue: 0.07)))
    }
}

// MARK: - transport

struct TransportBar: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var studio: Studio

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            Button { app.toggleRecord() } label: {
                ZStack {
                    Circle().fill(Color(red: 0.16, green: 0.08, blue: 0.08)).overlay(Circle().strokeBorder(Palette.red, lineWidth: 2))
                    RoundedRectangle(cornerRadius: studio.recording ? 5 : 13).fill(Palette.red)
                        .frame(width: studio.recording ? 22 : 26, height: studio.recording ? 22 : 26)
                }
                .frame(width: 62, height: 62)
                .shadow(color: studio.recording ? Palette.red.opacity(0.5) : .clear, radius: 10)
            }
            .buttonStyle(.plain)
            .disabled(app.editing)
            .help("Record / stop (Space)")

            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "%.1fs", studio.elapsed)).font(.system(size: 28, weight: .bold).monospacedDigit())
                let target = app.line?.target ?? 5
                Text("target ≈ \(target, specifier: "%.1f")s").font(.caption).foregroundStyle(Palette.dim)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.line)
                        Capsule().fill(studio.elapsed > target * 1.15 ? Palette.red : studio.elapsed > target * 0.9 ? Palette.yellow : Palette.lime)
                            .frame(width: min(g.size.width, g.size.width * 0.77 * studio.elapsed / max(target, 0.5)))
                        Rectangle().fill(.white).frame(width: 2).offset(x: g.size.width * 0.77)
                    }
                }
                .frame(width: 170, height: 5)
            }

            TakesStrip()

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.line)
                        LinearGradient(colors: [Palette.lime, Palette.lime, Palette.yellow, Palette.red], startPoint: .leading, endPoint: .trailing)
                            .mask(alignment: .leading) { Capsule().frame(width: g.size.width * CGFloat(studio.level)) }
                        Rectangle().fill(.white).frame(width: 2).offset(x: g.size.width * CGFloat(studio.peakHold))
                    }
                }
                .frame(width: 210, height: 9)
                HStack {
                    Text(studio.inputName).lineLimit(1)
                    Text(studio.sampleRate > 0 ? "\(Int(studio.sampleRate / 1000)) kHz" : "")
                        .foregroundStyle(studio.lowQualityInput ? Palette.red : Palette.dim)
                    Spacer()
                    if studio.clipped { Text("CLIP").bold().foregroundStyle(Palette.red) }
                }
                .font(.caption).foregroundStyle(Palette.dim).frame(width: 210)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(Palette.panel)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

struct TakesStrip: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var studio: Studio

    var body: some View {
        let list = (app.takes[app.line?.id ?? ""] ?? []).reversed()
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if list.isEmpty {
                    Text("No takes yet — press Space and read the yellow word.  ←/→ line · P play · U use · R retake")
                        .font(.callout).foregroundStyle(Palette.dim)
                }
                ForEach(Array(list)) { t in TakeCard(take: t, checking: studio.checking.contains(t.id)) }
            }
        }
        .frame(maxWidth: 640)
    }
}

struct TakeCard: View {
    @EnvironmentObject var app: AppState
    let take: Take
    let checking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Take \(take.number)").font(.callout.weight(.heavy))
                Spacer()
                Text(String(format: "%.1fs", take.duration)).font(.caption).foregroundStyle(Palette.dim)
            }
            Group {
                if checking {
                    Text("checking…").foregroundStyle(Palette.dim)
                } else if let c = take.check, c.state == "done", let acc = c.accuracy {
                    let pct = Int((acc * 100).rounded())
                    HStack(spacing: 4) {
                        Text("\(pct)% words").bold().foregroundStyle(pct >= 95 ? Palette.lime : pct >= 80 ? Palette.yellow : Palette.red)
                        if let w = c.wpm { Text("· \(w) wpm").foregroundStyle(Palette.dim) }
                    }
                    if let cv = c.covers, acc < 0.95, cv.count == 2 {
                        Text("pickup: words \(cv[0] + 1)–\(cv[1] + 1)").foregroundStyle(Palette.cyan)
                    }
                } else {
                    Text("no check").foregroundStyle(Palette.dim)
                }
            }
            .font(.caption)
            HStack(spacing: 6) {
                Button(app.playing == take.url ? "■" : "▶") { app.play(take) }
                Button(take.chosen ? "✓ Chosen" : "Use") { app.use(take) }
                Button("✕") { app.delete(take) }.help("Delete take")
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(width: 168)
        .background(Palette.panel2, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(take.chosen ? Palette.lime : Palette.line, lineWidth: take.chosen ? 1.5 : 1))
    }
}

// MARK: - editor

struct EditorView: View {
    @EnvironmentObject var app: AppState
    @State private var importing = false
    @State private var importText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    TextField("Title", text: $app.script.title).font(.title2.weight(.bold)).textFieldStyle(.plain)
                    Picker("Language", selection: $app.script.lang) {
                        ForEach(["en-IN", "en-US", "en-GB", "en-AU", "hi-IN"], id: \.self) { Text($0) }
                    }
                    .frame(width: 180)
                    Button("Import text…") { importing = true }
                }
                Text("Wrap a word in *stars* for emphasis · a lone / marks a breath · target = seconds you're aiming for")
                    .font(.caption).foregroundStyle(Palette.dim)
                ForEach($app.script.sections) { $sec in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Rectangle().fill(Palette.section(sec.color)).frame(width: 10, height: 10).rotationEffect(.degrees(45))
                                .onTapGesture { sec.color = (sec.color + 1) % 4 }.help("Click to change colour")
                            TextField("Section", text: $sec.name).font(.headline).textFieldStyle(.plain)
                            Button { sec.lines.append(ScriptLine(id: nextID(), text: "New line")) } label: { Image(systemName: "plus") }
                                .help("Add a line")
                            Button(role: .destructive) { app.script.sections.removeAll { $0.id == sec.id } } label: { Image(systemName: "trash") }
                                .help("Delete section")
                        }
                        ForEach($sec.lines) { $line in
                            HStack(alignment: .top, spacing: 10) {
                                Text(line.id).font(.caption.weight(.bold)).foregroundStyle(Palette.dim).frame(width: 40).padding(.top, 8)
                                VStack(spacing: 6) {
                                    TextEditor(text: $line.text).font(.body).frame(minHeight: 54)
                                        .scrollContentBackground(.hidden).padding(6)
                                        .background(Palette.panel2, in: RoundedRectangle(cornerRadius: 8))
                                    TextField("direction for yourself (tone, pace…)", text: $line.note).textFieldStyle(.roundedBorder)
                                }
                                VStack {
                                    TextField("s", value: $line.target, format: .number).frame(width: 56).textFieldStyle(.roundedBorder)
                                    Button(role: .destructive) { sec.lines.removeAll { $0.id == line.id } } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                    .padding(14)
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
                }
                Button { app.script.sections.append(ScriptSection(name: "New section", color: app.script.sections.count % 4,
                                                                    lines: [ScriptLine(id: nextID(), text: "New line")])) }
                label: { Label("Add section", systemImage: "plus.rectangle.on.rectangle") }
            }
            .padding(32)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $importing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste your script").font(.headline)
                Text("A blank line starts a new line to record. A line starting with # starts a section. This replaces the current script.")
                    .font(.caption).foregroundStyle(Palette.dim)
                TextEditor(text: $importText).frame(width: 620, height: 320).font(.body)
                HStack {
                    Spacer()
                    Button("Cancel") { importing = false }
                    Button("Replace script") {
                        app.script = Script.fromPlainText(importText, title: app.script.title)
                        importing = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
        }
    }

    private func nextID() -> String {
        let used = Set(app.lines.map(\.id))
        var n = app.lines.count + 1
        while used.contains("VO\(n)") { n += 1 }
        return "VO\(n)"
    }
}

// MARK: - welcome

struct WelcomeView: View {
    @EnvironmentObject var app: AppState
    @State private var name = ""
    @State private var pasted = ""

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Rectangle().fill(Palette.pink).frame(width: 44, height: 44).rotationEffect(.degrees(45)).padding(.leading, 8)
                Text("Teleprompter").font(.system(size: 40, weight: .heavy))
                Text("A teleprompter that listens. The next word lights up as you read, every take is recorded losslessly and checked word by word, and you keep the best one for each line.")
                    .font(.title3).foregroundStyle(Palette.ink.opacity(0.8)).frame(maxWidth: 460, alignment: .leading)
                Spacer()
                Text("Your projects live in Documents › Teleprompter").font(.caption).foregroundStyle(Palette.dim)
            }
            .padding(48)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.panel)

            VStack(alignment: .leading, spacing: 14) {
                Text("New project").font(.headline)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                Text("Paste a script (optional) — blank line = new line, # = section").font(.caption).foregroundStyle(Palette.dim)
                TextEditor(text: $pasted).frame(height: 140).scrollContentBackground(.hidden).padding(6)
                    .background(Palette.panel2, in: RoundedRectangle(cornerRadius: 8))
                Button("Create") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    let t = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                    app.newProject(named: n.isEmpty ? "Untitled" : n, from: t.isEmpty ? nil : t)
                }
                .keyboardShortcut(.defaultAction)
                Divider().padding(.vertical, 6)
                HStack {
                    Text("Open").font(.headline)
                    Spacer()
                    Button("Choose folder…") { app.chooseProjectFolder() }
                }
                ForEach(app.recent, id: \.self) { path in
                    Button { app.open(URL(fileURLWithPath: path)) } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain).padding(8)
                    .background(Palette.panel2, in: RoundedRectangle(cornerRadius: 8))
                }
                Spacer()
            }
            .padding(36)
            .frame(width: 420)
            .frame(maxHeight: .infinity)
            .background(Palette.bg)
        }
    }
}
