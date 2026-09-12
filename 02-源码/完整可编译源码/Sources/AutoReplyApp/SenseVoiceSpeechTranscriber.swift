import CustomerReplyBatchAppSupport
import Foundation

enum SenseVoiceSpeechError: LocalizedError {
    case invalidReady(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidReady(let value): return "SenseVoice 预热失败：\(value)"
        case .invalidResponse(let value): return "SenseVoice 识别结果无效：\(value)"
        }
    }
}

private struct SenseVoiceReady: Decodable {
    let type: String
    let model: String
}

private struct SenseVoiceResponse: Decodable {
    let id: String?
    let ok: Bool
    let text: String?
    let durationSeconds: Double?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id, ok, text, error
        case durationSeconds = "duration_seconds"
    }
}

actor SenseVoiceSpeechTranscriber: VideoSpeechTranscribing, VideoSpeechPrewarming {
    private let pythonURL: URL
    private let workerScriptURL: URL
    private let sitePackagesURL: URL
    private let modelURL: URL
    private let tokensURL: URL
    private var worker: PersistentJSONLWorker?

    init(
        pythonURL: URL,
        workerScriptURL: URL,
        sitePackagesURL: URL,
        modelURL: URL,
        tokensURL: URL
    ) {
        self.pythonURL = pythonURL
        self.workerScriptURL = workerScriptURL
        self.sitePackagesURL = sitePackagesURL
        self.modelURL = modelURL
        self.tokensURL = tokensURL
    }

    func prepareSpeechRecognition() async throws {
        _ = try await activeWorker()
    }

    func transcribe(_ videoURL: URL) async -> [VideoTranscriptSegment] {
        for attempt in 0...1 {
            do {
                let active = try await activeWorker()
                let requestID = UUID().uuidString
                let payload = try JSONSerialization.data(withJSONObject: [
                    "id": requestID,
                    "audio_path": videoURL.path,
                ])
                let data = try await active.request(payload)
                let response = try JSONDecoder().decode(SenseVoiceResponse.self, from: data)
                guard response.id == requestID, response.ok else {
                    throw SenseVoiceSpeechError.invalidResponse(response.error ?? "响应 ID 不匹配")
                }
                let text = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return [] }
                return [VideoTranscriptSegment(
                    startSeconds: 0,
                    durationSeconds: max(0, response.durationSeconds ?? 0),
                    text: text
                )]
            } catch {
                if let worker { await worker.stop() }
                worker = nil
                if attempt == 1 { return [] }
            }
        }
        return []
    }

    private func activeWorker() async throws -> PersistentJSONLWorker {
        if let worker { return worker }
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = sitePackagesURL.path
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        let candidate = PersistentJSONLWorker(
            executable: pythonURL,
            arguments: [
                workerScriptURL.path,
                "--model", modelURL.path,
                "--tokens", tokensURL.path,
            ],
            environment: environment,
            startupDeadline: .seconds(30),
            queryDeadline: .seconds(15)
        )
        let data = try await candidate.start()
        let ready = try JSONDecoder().decode(SenseVoiceReady.self, from: data)
        guard ready.type == "ready", ready.model == "sensevoice-int8" else {
            await candidate.stop()
            throw SenseVoiceSpeechError.invalidReady(String(decoding: data, as: UTF8.self))
        }
        worker = candidate
        return candidate
    }
}
