import Foundation
import AVFoundation

/// Hands-free reading. Either reads the book aloud and turns the paper when the voice reaches the next page,
/// or turns a page every few seconds. Main thread only.
final class AutoReader: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum Mode: Equatable {
        case off
        case speech
        case timer(TimeInterval)
    }

    @Published private(set) var mode: Mode = .off
    /// AVSpeechUtterance rate (0...1, 0.5 is the system default).
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    /// Called when reading aloud finds no text at all (a scanned PDF, a picture book).
    var onNothingToRead: (() -> Void)?

    private weak var controller: CurlController?
    private let synth = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    /// Where each page starts inside the utterance being spoken (UTF-16 offsets, ascending).
    private var chunk: [(page: Int, start: Int)] = []
    private var chunkLastPage = -1
    /// Page the voice is on; -1 before the first word.
    private var spokenPage = -1
    /// Set while the reader itself turns the page, so the move is not mistaken for the user's.
    private var turningForVoice = false
    private var emptyPagesInARow = 0
    private var token = 0
    private var timer: Timer?

    private static let pagesPerChunk = 6

    override init() {
        super.init()
        synth.delegate = self
    }

    var isActive: Bool { mode != .off }

    // MARK: - Start / stop

    func startSpeech(controller c: CurlController) {
        stop()
        controller = c
        mode = .speech
        emptyPagesInARow = 0
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true)
        speak(from: c.visiblePages.lowerBound)
    }

    func startTimer(controller c: CurlController, interval: TimeInterval) {
        stop()
        controller = c
        mode = .timer(interval)
        scheduleTimer(interval)
    }

    func stop() {
        token += 1
        timer?.invalidate()
        timer = nil
        let wasSpeaking = mode == .speech
        utterance = nil
        chunk = []
        spokenPage = -1
        turningForVoice = false
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        if wasSpeaking { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        if mode != .off { mode = .off }
    }

    /// The reader's page changed (a turn, a jump, or a re-layout).
    func controllerMoved() {
        // @Published fires before the controller has stored the new page; look once it has.
        DispatchQueue.main.async { [weak self] in self?.handleMove() }
    }

    private func handleMove() {
        guard let c = controller else { return }
        switch mode {
        case .off:
            return
        case .timer(let interval):
            // Give every page the full interval, even after the reader turned one by hand.
            scheduleTimer(interval)
        case .speech:
            let visible = c.visiblePages
            if turningForVoice {
                turningForVoice = false
                if spokenPage > visible.upperBound { follow(page: spokenPage) }
                return
            }
            // The reader moved somewhere else (or the font changed the page numbers): read from there.
            if spokenPage >= 0, !visible.contains(spokenPage) {
                restartSpeech(at: visible.lowerBound)
            }
        }
    }

    // MARK: - Timer

    private func scheduleTimer(_ interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.timerFired()
        }
    }

    private func timerFired() {
        guard let c = controller else { stop(); return }
        if c.isLoading || c.isTurning { return }
        guard c.nextPageAvailable() else { stop(); return }
        _ = c.turn(direction: 1)
    }

    // MARK: - Speech

    private func restartSpeech(at page: Int) {
        token += 1
        utterance = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        spokenPage = -1
        speak(from: page)
    }

    private func speak(from page: Int) {
        guard let c = controller, mode == .speech else { return }
        token += 1
        let tk = token
        c.pageTexts(from: page, count: Self.pagesPerChunk) { [weak self] pages in
            guard let self, tk == self.token, self.mode == .speech else { return }
            guard let last = pages.last else {
                self.stop()   // end of the book
                return
            }
            let separator = c.sourceIsReflowable ? "" : "\n"
            var text = ""
            var map: [(page: Int, start: Int)] = []
            for p in pages {
                if !text.isEmpty, !p.text.isEmpty { text += separator }
                map.append((p.page, (text as NSString).length))
                text += p.text
            }
            self.chunkLastPage = last.page
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Picture pages: nothing to say. Skip ahead, but give up on a book without any text.
                self.emptyPagesInARow += pages.count
                if self.emptyPagesInARow >= 30 || last.page + 1 >= c.pageCount {
                    let callback = self.onNothingToRead
                    self.stop()
                    callback?()
                } else {
                    self.speak(from: last.page + 1)
                }
                return
            }
            self.emptyPagesInARow = 0
            self.chunk = map
            let u = AVSpeechUtterance(string: text)
            u.rate = min(max(self.rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
            u.voice = AVSpeechSynthesisVoice(language: Self.language(of: text))
            self.utterance = u
            self.synth.speak(u)
        }
    }

    /// Japanese text gets a Japanese voice whatever the device language is; anything else uses the system voice.
    private static func language(of text: String) -> String {
        let japanese = text.unicodeScalars.prefix(600).contains { s in
            (0x3040...0x30FF).contains(s.value) || (0x4E00...0x9FFF).contains(s.value)
        }
        return japanese ? "ja-JP" : AVSpeechSynthesisVoice.currentLanguageCode()
    }

    /// Keeps the open pages in step with the voice.
    private func follow(page p: Int) {
        guard let c = controller, mode == .speech else { return }
        spokenPage = p
        let visible = c.visiblePages
        guard p > visible.upperBound, !c.isLoading, !c.isTurning else { return }
        turningForVoice = true
        if p > visible.upperBound + 2 {
            c.goTo(page: p)
        } else if !c.turn(direction: 1) {
            turningForVoice = false
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance spoken: AVSpeechUtterance) {
        let location = characterRange.location
        DispatchQueue.main.async { [weak self] in
            guard let self, spoken === self.utterance else { return }
            guard let entry = self.chunk.last(where: { $0.start <= location }) else { return }
            self.follow(page: entry.page)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish spoken: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self, spoken === self.utterance, self.mode == .speech, let c = self.controller else { return }
            let next = self.chunkLastPage + 1
            if next >= c.pageCount {
                self.stop()
            } else {
                self.speak(from: next)
            }
        }
    }
}
