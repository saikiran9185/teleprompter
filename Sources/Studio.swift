import AVFoundation
import Foundation
import Speech

/// Shared between the audio thread (tap) and the main thread.
final class TapSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    var onLevel: ((Float) -> Void)?

    func setFile(_ f: AVAudioFile?) { lock.lock(); file = f; lock.unlock() }
    func setRequest(_ r: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = r; lock.unlock() }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var peak: Float = 0
        // mono mix for the file / meter
        let mono = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                                             channels: 1, interleaved: false)!, frameCapacity: buffer.frameLength)!
        mono.frameLength = buffer.frameLength
        let out = mono.floatChannelData![0]
        for i in 0..<n {
            var s: Float = 0
            for c in 0..<channels { s += ch[c][i] }
            s /= Float(channels)
            out[i] = s
            peak = max(peak, abs(s))
        }
        lock.lock()
        let f = file, r = request
        lock.unlock()
        if let f { try? f.write(from: mono) }
        r?.append(buffer)
        onLevel?(peak)
    }
}

@MainActor
final class Studio: ObservableObject {
    @Published var level: Float = 0
    @Published var peakHold: Float = 0
    @Published var clipped = false
    @Published var recording = false
    @Published var countdown: Int?
    @Published var elapsed: Double = 0
    @Published var heard = ""
    @Published var followPos = 0
    @Published var readSet = Set<Int>()
    @Published var inputName = "Microphone"
    @Published var sampleRate: Double = 0
    @Published var micAllowed = true
    @Published var speechAllowed = true
    @Published var speechNote = ""
    @Published var checking = Set<String>()   // take file names being checked

    private let engine = AVAudioEngine()
    private let sink = TapSink()
    private var engineRunning = false
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var timer: Timer?
    private var startedAt = Date()
    private var lastHeardAt = Date()
    private var peakAt = Date()
    private var fileURL: URL?
    private var scriptWords: [String] = []
    var autoStop = true
    var onTakeFinished: ((URL) -> Void)?

    var lowQualityInput: Bool { sampleRate > 0 && sampleRate < 44_100 }

    init() {
        sink.onLevel = { [weak self] peak in
            DispatchQueue.main.async { self?.meter(peak) }
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restartEngine() }
        }
    }

    // MARK: permissions + engine

    func prepare(language: String) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            Task { @MainActor in
                self.micAllowed = ok
                if ok { self.startEngine() }
            }
        }
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                self.speechAllowed = status == .authorized
                self.setLanguage(language)
            }
        }
    }

    func setLanguage(_ code: String) {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: code)) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        if !speechAllowed {
            speechNote = "Speech recognition is off — allow it in System Settings › Privacy & Security › Speech Recognition for live word-following."
        } else if recognizer?.supportsOnDeviceRecognition == true {
            speechNote = ""
        } else {
            speechNote = "On-device recognition isn't available for \(code), so live following uses Apple's servers (needs internet). For fully offline use, set Language to en-US in Edit script."
        }
    }

    private func startEngine() {
        guard !engineRunning else { return }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return }
        sampleRate = fmt.sampleRate
        inputName = UserDefaults.standard.string(forKey: "displayMicName")   // for screenshots
            ?? AVCaptureDevice.default(for: .audio)?.localizedName ?? "Microphone"
        let sink = self.sink
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in sink.process(buf) }
        do {
            try engine.start()
            engineRunning = true
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    private func restartEngine() {
        if recording { stop() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engineRunning = false
        startEngine()
    }

    private func meter(_ peak: Float) {
        let db = 20 * log10(max(peak, 1e-6))
        let x = max(0, min(1, (db + 60) / 60))
        level = max(x, level * 0.88)
        if x >= peakHold || Date().timeIntervalSince(peakAt) > 1.5 { peakHold = x; peakAt = Date() }
        if peak > 0.98 { clipped = true; DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.clipped = false } }
    }

    // MARK: recording

    func start(to url: URL, words: [String], countIn: Bool) {
        guard !recording, engineRunning else { return }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 24,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) else { return }
        fileURL = url
        scriptWords = words
        heard = ""; followPos = 0; readSet = []; elapsed = 0
        sink.setFile(file)            // recording during the count-in gives clean handles
        recording = true
        Task { @MainActor in
            if countIn {
                for n in [3, 2, 1] {
                    countdown = n
                    try? await Task.sleep(nanoseconds: 650_000_000)
                    if !recording { countdown = nil; return }
                }
                countdown = nil
            }
            startedAt = Date(); lastHeardAt = Date()
            startRecognition()
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        }
    }

    private func startRecognition() {
        guard speechAllowed, let recognizer, recognizer.isAvailable else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        req.contextualStrings = Array(Set(scriptWords.filter { $0.count > 3 })).prefix(100).map { $0 }
        request = req
        sink.setRequest(req)
        task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            Task { @MainActor in self?.heardUpdate(text) }
        }
    }

    private func heardUpdate(_ text: String) {
        heard = text
        lastHeardAt = Date()
        let h = text.split(whereSeparator: { $0.isWhitespace }).map { Words.norm(String($0)) }.filter { !$0.isEmpty }
        let r = Words.follow(script: scriptWords, heard: h)
        followPos = r.pos
        readSet = r.read
    }

    private func tick() {
        guard recording else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        if autoStop && !scriptWords.isEmpty && followPos >= scriptWords.count && Date().timeIntervalSince(lastHeardAt) > 1.1 {
            stop()
        }
    }

    func stop() {
        guard recording else { return }
        timer?.invalidate(); timer = nil
        countdown = nil
        let url = fileURL
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)   // a little room tone after the last word
            sink.setFile(nil)
            sink.setRequest(nil)
            request?.endAudio()
            task?.cancel()
            request = nil; task = nil
            recording = false
            if let url { onTakeFinished?(url) }
        }
    }

    // MARK: take check (offline transcription of the file, aligned to the script)

    func check(take url: URL, line: ScriptLine, language: String) async -> CheckResult {
        let rec = SFSpeechRecognizer(locale: Locale(identifier: language)) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard speechAllowed, let rec else { return CheckResult(state: "error", error: "speech recognition not allowed") }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
        req.contextualStrings = Array(Set(line.words.map(\.display).filter { $0.count > 3 })).prefix(100).map { $0 }
        let segments: [SFTranscriptionSegment]? = await withCheckedContinuation { cont in
            var done = false
            rec.recognitionTask(with: req) { result, error in
                guard !done else { return }
                if let result, result.isFinal { done = true; cont.resume(returning: result.bestTranscription.segments) }
                else if error != nil { done = true; cont.resume(returning: nil) }
            }
        }
        guard let segments, !segments.isEmpty else {
            return CheckResult(state: "done", accuracy: 0, words: line.words.map { WordCheck(w: $0.display, ok: false) }, heard: "")
        }
        let heardN = segments.map { Words.norm($0.substring) }
        let script = line.words.map(\.norm)
        let map = Words.localAlign(script: script, heard: heardN)
        var words: [WordCheck] = []
        for (i, tok) in line.words.enumerated() {
            if let h = map[i] {
                words.append(WordCheck(w: tok.display, ok: true, start: segments[h].timestamp, end: segments[h].timestamp + segments[h].duration))
            } else {
                words.append(WordCheck(w: tok.display, ok: false))
            }
        }
        let timed = words.compactMap { $0.start == nil ? nil : $0 }
        let covered = map.keys.sorted()
        let span = (timed.last?.end ?? 0) - (timed.first?.start ?? 0)
        return CheckResult(state: "done", accuracy: Double(map.count) / Double(max(1, script.count)), words: words,
                           heard: segments.map(\.substring).joined(separator: " "),
                           speech_start: timed.first?.start, speech_end: timed.last?.end,
                           wpm: span > 0 ? Int(Double(timed.count) / span * 60) : nil,
                           covers: covered.isEmpty ? nil : [covered.first!, covered.last!])
    }
}
