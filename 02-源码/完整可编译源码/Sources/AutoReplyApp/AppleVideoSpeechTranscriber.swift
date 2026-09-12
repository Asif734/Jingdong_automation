import Foundation
import Speech

private final class SpeechResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<[VideoTranscriptSegment], Never>?
    private var task: SFSpeechRecognitionTask?

    func install(_ continuation: CheckedContinuation<[VideoTranscriptSegment], Never>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    func install(_ task: SFSpeechRecognitionTask) {
        lock.lock(); defer { lock.unlock() }
        self.task = task
    }

    func finish(_ value: [VideoTranscriptSegment]) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        let task = self.task
        self.continuation = nil
        self.task = nil
        lock.unlock()
        task?.cancel()
        continuation?.resume(returning: value)
    }
}

struct AppleVideoSpeechTranscriber: VideoSpeechTranscribing {
    let locale: Locale
    let timeout: TimeInterval

    init(locale: Locale = Locale(identifier: "zh-CN"), timeout: TimeInterval = 45) {
        self.locale = locale
        self.timeout = timeout
    }

    private func authorizationGranted() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func transcribe(_ audioURL: URL) async -> [VideoTranscriptSegment] {
        guard await authorizationGranted(),
              let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { return [] }
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let box = SpeechResultBox()
        return await withCheckedContinuation { continuation in
            box.install(continuation)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    box.finish(result.bestTranscription.segments.compactMap { segment in
                        let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
                        return text.isEmpty ? nil : VideoTranscriptSegment(
                            startSeconds: segment.timestamp,
                            durationSeconds: segment.duration,
                            text: text
                        )
                    })
                } else if error != nil {
                    box.finish([])
                }
            }
            box.install(task)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                box.finish([])
            }
        }
    }
}
