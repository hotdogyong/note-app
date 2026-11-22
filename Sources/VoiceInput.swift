import Foundation
import UIKit
import AVFoundation
import Speech

// VoiceInput.swift（v12.16.0）：語音轉文字（使用者：白板腦力激盪時不讓想法消失、加快輸出；中文夾英文物理術語；不留錄音檔）。
// 優先用 iPadOS 26 新的 SpeechAnalyzer／SpeechTranscriber（裝置上的新模型，長一點的話也穩，邊講邊出字，講完一句就定稿一句）；
// 這台 iPad 或語言不支援的話，退回舊的 SFSpeechRecognizer（加了物理術語提示）。
// 聲音只在記憶體裡轉成文字，不存檔。

@MainActor
final class VoiceInput {
    static let shared = VoiceInput()

    /// 邊講邊出來的字（還會變）
    var onPartial: ((String) -> Void)?
    /// 定稿的一句
    var onFinal: ((String) -> Void)?
    /// 狀態文字（下載模型中、哪個引擎）或錯誤
    var onStatus: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var running = false
    private(set) var engineName = ""

    private let audio = AVAudioEngine()
    private var tapBox: TapBox?
    // 新的（iPadOS 26）
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    // 舊的
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// 物理常用詞（舊的辨識器用來提高辨識率；新的之後再看要不要加）
    static let terms = [
        "Griffiths", "Jackson", "Goldstein", "Sakurai", "Lagrangian", "Hamiltonian", "eigenvalue", "eigenstate",
        "eigenvector", "divergence", "curl", "gradient", "Laplacian", "Maxwell", "Schrödinger", "Heisenberg",
        "Fourier", "Legendre", "Bessel", "Hermite", "Gauss", "Stokes", "Green's function", "boundary condition",
        "harmonic oscillator", "angular momentum", "spin", "operator", "commutator", "perturbation", "WKB",
        "Lorentz", "tensor", "entropy", "partition function", "Boltzmann", "Fermi", "Bose", "dipole",
        "electric field", "magnetic field", "potential", "wave function", "Hilbert space", "matrix", "vector",
        "高斯定律", "安培定律", "法拉第", "電位", "電場", "磁場", "電通量", "邊界條件", "特徵值", "角動量",
        "微擾", "簡諧振子", "拉格朗日", "漢米爾頓", "薛丁格", "傅立葉", "勒壤得", "配分函數", "熵",
    ]

    // MARK: 開始、結束

    func start() async {
        guard !running else { return }
        guard await Self.microphoneAllowed() else {
            onError?("沒有麥克風權限。請到「設定 → 筆記 → 麥克風」打開")
            return
        }
        running = true
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            fail("麥克風開不起來：\(error.localizedDescription)")
            return
        }
        if await startAnalyzer() { return }
        if !running { return }                                 // 新的那條路已經回報錯誤了
        await startRecognizer()
    }

    /// 停下來：講到一半的那句也會定稿送出
    func stop() async {
        guard running else { return }
        running = false
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        tapBox?.finish()
        if let analyzer = analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        await resultsTask?.value
        recognitionTask?.finish()
        cleanUp()
    }

    private func cleanUp() {
        analyzer = nil
        resultsTask = nil
        tapBox = nil
        recognitionTask = nil
        recognizer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func fail(_ message: String) {
        if running {
            running = false
            audio.inputNode.removeTap(onBus: 0)
            audio.stop()
            tapBox?.finish()
            resultsTask?.cancel()
            recognitionTask?.cancel()
            cleanUp()
        }
        onError?(message)
    }

    // MARK: 新的：SpeechAnalyzer（iPadOS 26）

    private func startAnalyzer() async -> Bool {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-TW")) else { return false }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [])
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                onStatus?("第一次使用：下載中文語音模型中…（要網路，只下載一次）")
                try await request.downloadAndInstall()
            }
        } catch {
            onStatus?("語音模型下載不了，改用舊的辨識")
            return false
        }
        guard running else { return true }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return false }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self?.onFinal?(text)
                    } else {
                        self?.onPartial?(text)
                    }
                }
            } catch {
                self?.onError?("辨識中斷：\(error.localizedDescription)")
            }
        }
        do {
            try await analyzer.start(inputSequence: stream)
            let input = audio.inputNode
            let micFormat = input.outputFormat(forBus: 0)
            let box = TapBox(converter: AVAudioConverter(from: micFormat, to: format), format: format, builder: builder, request: nil)
            tapBox = box
            input.installTap(onBus: 0, bufferSize: 4096, format: micFormat, block: Self.makeTap(box))
            audio.prepare()
            try audio.start()
        } catch {
            fail("語音辨識開不起來：\(error.localizedDescription)")
            return true
        }
        engineName = "裝置上的新模型"
        onStatus?("聽寫中（\(engineName)）")
        return true
    }

    // MARK: 舊的：SFSpeechRecognizer

    private func startRecognizer() async {
        guard await Self.speechAllowed() else {
            fail("沒有語音辨識權限。請到「設定 → 筆記 → 語音辨識」打開")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-TW")), recognizer.isAvailable else {
            fail("這台 iPad 現在不能用中文語音辨識")
            return
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.contextualStrings = Self.terms
        let input = audio.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        let box = TapBox(converter: nil, format: micFormat, builder: nil, request: request)
        tapBox = box
        recognitionTask = recognizer.recognitionTask(with: request, resultHandler: Self.makeHandler(self))
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat, block: Self.makeTap(box))
        do {
            audio.prepare()
            try audio.start()
        } catch {
            fail("麥克風開不起來：\(error.localizedDescription)")
            return
        }
        engineName = "舊的辨識"
        onStatus?("聽寫中（\(engineName)）")
    }

    /// 舊的辨識器回報（在別的執行緒）：換回主執行緒處理
    fileprivate func handleRecognizer(text: String?, isFinal: Bool, failed: String?) {
        if let text = text {
            if isFinal { onFinal?(text) } else { onPartial?(text) }
        }
        if let failed = failed, running {
            fail("辨識中斷：\(failed)")
        }
    }

    nonisolated private static func makeHandler(_ owner: VoiceInput) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        return { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failed = error.map { $0.localizedDescription }
            Task { @MainActor in owner.handleRecognizer(text: text, isFinal: isFinal, failed: failed) }
        }
    }

    // MARK: 麥克風的聲音（在音訊的執行緒；不能碰主執行緒的東西）

    nonisolated private static func makeTap(_ box: TapBox) -> AVAudioNodeTapBlock {
        return { buffer, _ in box.feed(buffer) }
    }

    // MARK: 權限

    nonisolated static func microphoneAllowed() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    nonisolated static func speechAllowed() async -> Bool {
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        return status == .authorized
    }
}

/// 麥克風的聲音交給辨識器（音訊執行緒用；裡面的東西只在那條執行緒碰）
private final class TapBox: @unchecked Sendable {
    let converter: AVAudioConverter?
    let format: AVAudioFormat
    let builder: AsyncStream<AnalyzerInput>.Continuation?
    let request: SFSpeechAudioBufferRecognitionRequest?
    private let lock = NSLock()
    private var finished = false

    init(converter: AVAudioConverter?, format: AVAudioFormat, builder: AsyncStream<AnalyzerInput>.Continuation?,
         request: SFSpeechAudioBufferRecognitionRequest?) {
        self.converter = converter
        self.format = format
        self.builder = builder
        self.request = request
    }

    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
        builder?.finish()
        request?.endAudio()
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let done = finished
        lock.unlock()
        guard !done else { return }
        if let request = request {
            request.append(buffer)
            return
        }
        guard let builder = builder else { return }
        guard let converter = converter else {
            builder.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let ratio = format.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        let source = OneShot(buffer)
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if let b = source.take() {
                status.pointee = .haveData
                return b
            }
            status.pointee = .noDataNow
            return nil
        }
        if error == nil, out.frameLength > 0 {
            builder.yield(AnalyzerInput(buffer: out))
        }
    }
}

/// 轉檔時只餵一次
private final class OneShot: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

/// 畫面下面的黑色膠囊：紅點（一閃一閃）、正在聽到的字、「完成」
final class VoiceBar: UIView {
    private let dot = UIView()
    private let label = UILabel()
    private let status = UILabel()
    private let done = UIButton(type: .system)
    private var hint = ""

    init(onDone: @escaping () -> Void) {
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.12, alpha: 0.96)
        layer.cornerRadius = 32
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 10
        dot.backgroundColor = UIColor.systemRed
        dot.layer.cornerRadius = 7
        addSubview(dot)
        label.textColor = .white
        label.font = UIFont.systemFont(ofSize: 17, weight: .medium)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingHead                    // 講很長：看得到最後講的
        addSubview(label)
        status.textColor = UIColor(white: 1, alpha: 0.55)
        status.font = UIFont.systemFont(ofSize: 12)
        addSubview(status)
        var config = UIButton.Configuration.filled()
        config.title = "完成"
        config.baseBackgroundColor = UIColor.systemOrange
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        done.configuration = config
        done.addAction(UIAction { _ in onDone() }, for: .touchUpInside)
        addSubview(done)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reset(hint: String) {
        self.hint = hint
        label.text = hint
        label.textColor = UIColor(white: 1, alpha: 0.6)
        status.text = "準備中…"
        dot.layer.removeAllAnimations()
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.25
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer.add(pulse, forKey: "pulse")
    }

    func show(text: String) {
        if text.isEmpty {
            label.text = hint
            label.textColor = UIColor(white: 1, alpha: 0.6)
        } else {
            label.text = text
            label.textColor = .white
        }
    }

    func show(status text: String) {
        status.text = text
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        dot.frame = CGRect(x: 22, y: (h - 14) / 2, width: 14, height: 14)
        done.frame = CGRect(x: bounds.width - 96, y: (h - 40) / 2, width: 80, height: 40)
        let x: CGFloat = 50
        let w = max(bounds.width - x - 110, 40)
        label.frame = CGRect(x: x, y: 10, width: w, height: 26)
        status.frame = CGRect(x: x, y: 36, width: w, height: 16)
    }
}
