import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import QianniuOCRAppSupport
import UniformTypeIdentifiers

struct CustomerVideoFrame: Codable, Equatable, Sendable {
    let timestampSeconds: Double
    let fileName: String
    let sha256: String
}

struct CustomerVideoEvidenceManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let messageHash: String
    let durationSeconds: Double
    let width: Int
    let height: Int
    let frames: [CustomerVideoFrame]
    let audioFileName: String?
    let transcript: [VideoTranscriptSegment]
}

struct VideoTranscriptSegment: Codable, Equatable, Sendable {
    let startSeconds: Double
    let durationSeconds: Double
    let text: String
}

protocol VideoSpeechTranscribing: Sendable {
    func transcribe(_ videoURL: URL) async -> [VideoTranscriptSegment]
}

protocol VideoSpeechPrewarming: Sendable {
    func prepareSpeechRecognition() async throws
}

protocol CustomerVideoEvidencePreparing: Sendable {
    func prepare(receipt: DownloadedCustomerVideo) async throws -> CustomerVideoEvidenceManifest
}

struct NoVideoSpeechTranscriber: VideoSpeechTranscribing {
    func transcribe(_ videoURL: URL) async -> [VideoTranscriptSegment] { [] }
}

struct AppleThenFallbackVideoSpeechTranscriber: VideoSpeechTranscribing {
    let primary: any VideoSpeechTranscribing
    let fallback: any VideoSpeechTranscribing

    func transcribe(_ videoURL: URL) async -> [VideoTranscriptSegment] {
        let primaryResult = await primary.transcribe(videoURL)
        guard primaryResult.isEmpty else { return primaryResult }
        return await fallback.transcribe(videoURL)
    }
}

enum CustomerVideoEvidenceError: LocalizedError {
    case invalidDuration
    case missingVideoTrack
    case frameExtractionFailed

    var errorDescription: String? {
        switch self {
        case .invalidDuration: return "视频时长无效"
        case .missingVideoTrack: return "视频没有可读取的画面"
        case .frameExtractionFailed: return "无法提取视频关键画面"
        }
    }
}

private struct CustomerVideoAudioExporter: Sendable {
    func export(from asset: AVURLAsset, to outputURL: URL) async throws -> Bool {
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { return false }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return false
        }
        if #available(macOS 15.0, *) {
            try await exporter.export(to: outputURL, as: .m4a)
        } else {
            exporter.outputURL = outputURL
            exporter.outputFileType = .m4a
            await exporter.export()
            guard exporter.status == .completed else {
                throw exporter.error ?? CustomerVideoEvidenceError.frameExtractionFailed
            }
        }
        return FileManager.default.fileExists(atPath: outputURL.path)
    }
}

private enum HEVCContainerCompatibility {
    private static let hev1 = Data("hev1".utf8)
    private static let hvc1 = Data("hvc1".utf8)

    static func normalizedURLIfNeeded(sourceURL: URL, stagingURL: URL) throws -> URL {
        let source = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        guard let markerRange = source.range(of: hev1),
              isVisualSampleEntry(markerRange: markerRange, in: source) else {
            return sourceURL
        }

        let outputURL = stagingURL.appendingPathComponent("hevc-hvc1-compatible.mp4")
        try FileManager.default.copyItem(at: sourceURL, to: outputURL)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(markerRange.lowerBound))
        try handle.write(contentsOf: hvc1)
        return outputURL
    }

    private static func isVisualSampleEntry(markerRange: Range<Data.Index>, in data: Data) -> Bool {
        let typeOffset = markerRange.lowerBound
        guard typeOffset >= 4, markerRange.upperBound + 8 <= data.endIndex else { return false }
        let sizeBytes = data[(typeOffset - 4)..<typeOffset]
        let entrySize = sizeBytes.reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
        guard entrySize >= 86, typeOffset - 4 + Int(entrySize) <= data.endIndex else { return false }

        // ISO BMFF visual sample entries begin with six reserved zero bytes and
        // a non-zero data-reference index immediately after the fourcc.
        let reserved = data[markerRange.upperBound..<(markerRange.upperBound + 6)]
        let reference = data[(markerRange.upperBound + 6)..<(markerRange.upperBound + 8)]
        return reserved.allSatisfy { $0 == 0 } && reference.contains { $0 != 0 }
    }
}

struct CustomerVideoEvidencePreparer: CustomerVideoEvidencePreparing {
    let rootURL: URL
    let transcriber: any VideoSpeechTranscribing
    let maximumFrames: Int

    init(rootURL: URL, transcriber: any VideoSpeechTranscribing = NoVideoSpeechTranscriber(), maximumFrames: Int = 20) {
        self.rootURL = rootURL
        self.transcriber = transcriber
        self.maximumFrames = max(1, min(20, maximumFrames))
    }

    static func sampleTimes(duration: Double, maximumFrames: Int = 20) -> [Double] {
        guard duration.isFinite, duration > 0 else { return [] }
        let limit = max(1, min(20, maximumFrames))
        let count: Int
        if duration < 2 {
            count = min(3, limit)
        } else if duration <= 10 {
            count = min(limit, max(4, Int(ceil(duration))))
        } else if duration <= 30 {
            count = min(limit, max(4, Int(ceil(duration / 2)) + 1))
        } else {
            count = limit
        }
        if count == 1 { return [duration * 0.5] }
        let start = min(0.20, duration * 0.1)
        let end = max(start, duration - min(0.20, duration * 0.1))
        return (0..<count).map { index in
            start + (end - start) * Double(index) / Double(count - 1)
        }.reduce(into: [Double]()) { values, value in
            if values.last.map({ abs($0 - value) >= 0.04 }) ?? true { values.append(value) }
        }
    }

    static func transcriptionInputURL(
        stagingURL: URL,
        audioFileName: String?,
        fallbackVideoURL: URL
    ) -> URL {
        guard let audioFileName else { return fallbackVideoURL }
        return stagingURL.appendingPathComponent(audioFileName)
    }

    func prepare(receipt: DownloadedCustomerVideo) async throws -> CustomerVideoEvidenceManifest {
        let staging = rootURL.appendingPathComponent(".\(receipt.messageHash).\(UUID().uuidString)", isDirectory: true)
        let final = rootURL.appendingPathComponent(receipt.messageHash, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let compatibleURL = try HEVCContainerCompatibility.normalizedURLIfNeeded(
                sourceURL: receipt.fileURL,
                stagingURL: staging
            )
            let asset = AVURLAsset(url: compatibleURL)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw CustomerVideoEvidenceError.invalidDuration }
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw CustomerVideoEvidenceError.missingVideoTrack
            }
            let naturalSize = try await track.load(.naturalSize)
            let times = Self.sampleTimes(duration: duration, maximumFrames: maximumFrames)
            let frames = try await Task.detached(priority: .utility) {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.12, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.12, preferredTimescale: 600)
                var output: [CustomerVideoFrame] = []
                for (index, seconds) in times.enumerated() {
                    try Task.checkCancellation()
                    var actual = CMTime.zero
                    let image = try generator.copyCGImage(
                        at: CMTime(seconds: seconds, preferredTimescale: 600),
                        actualTime: &actual
                    )
                    let name = String(format: "frame-%02d-%06.2f.jpg", index + 1, actual.seconds)
                    let url = staging.appendingPathComponent(name)
                    guard let destination = CGImageDestinationCreateWithURL(
                        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
                    ) else { throw CustomerVideoEvidenceError.frameExtractionFailed }
                    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
                    guard CGImageDestinationFinalize(destination) else {
                        throw CustomerVideoEvidenceError.frameExtractionFailed
                    }
                    let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                    output.append(CustomerVideoFrame(timestampSeconds: actual.seconds, fileName: name, sha256: digest))
                }
                return output
            }.value
            guard !frames.isEmpty else { throw CustomerVideoEvidenceError.frameExtractionFailed }
            let audioName = "audio.m4a"
            let audioSaved = (try? await CustomerVideoAudioExporter().export(
                from: asset,
                to: staging.appendingPathComponent(audioName)
            )) == true
            let transcript = await transcriber.transcribe(Self.transcriptionInputURL(
                stagingURL: staging,
                audioFileName: audioSaved ? audioName : nil,
                fallbackVideoURL: receipt.fileURL
            ))
            let manifest = CustomerVideoEvidenceManifest(
                schemaVersion: 2,
                messageHash: receipt.messageHash,
                durationSeconds: duration,
                width: Int(abs(naturalSize.width)),
                height: Int(abs(naturalSize.height)),
                frames: frames,
                audioFileName: audioSaved ? audioName : nil,
                transcript: transcript
            )
            if compatibleURL != receipt.fileURL {
                try? FileManager.default.removeItem(at: compatibleURL)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: staging) }
            else { try FileManager.default.moveItem(at: staging, to: final) }
            return manifest
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
}
