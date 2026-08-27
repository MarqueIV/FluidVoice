import AVFoundation
import Foundation

enum LocalAPIAudioDecoder {
    static let sampleRate: Double = 16_000
    static let maxChunkDurationSeconds: Double = 20 * 60

    actor ChunkReader {
        private let audioFile: AVAudioFile
        private let sourceFramesPerChunk: AVAudioFrameCount

        init(
            fileURL: URL,
            chunkDurationSeconds: Double = LocalAPIAudioDecoder.maxChunkDurationSeconds
        ) throws {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let sourceSampleRate = audioFile.processingFormat.sampleRate
            guard sourceSampleRate > 0, chunkDurationSeconds > 0 else {
                throw NSError(
                    domain: "LocalAPIAudioDecoder",
                    code: -6,
                    userInfo: [NSLocalizedDescriptionKey: "Audio file has an invalid sample rate or chunk duration."]
                )
            }

            self.audioFile = audioFile
            self.sourceFramesPerChunk = AVAudioFrameCount(sourceSampleRate * chunkDurationSeconds)
        }

        func nextSamples() throws -> [Float] {
            guard self.audioFile.framePosition < self.audioFile.length else { return [] }

            let remainingFrames = self.audioFile.length - self.audioFile.framePosition
            let framesToRead = AVAudioFrameCount(min(
                AVAudioFramePosition(self.sourceFramesPerChunk),
                remainingFrames
            ))
            guard let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: self.audioFile.processingFormat,
                frameCapacity: framesToRead
            ) else {
                throw NSError(
                    domain: "LocalAPIAudioDecoder",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to allocate audio buffer."]
                )
            }

            try self.audioFile.read(into: sourceBuffer, frameCount: framesToRead)
            return try AudioBufferConverter.monoSamples(
                from: sourceBuffer,
                targetSampleRate: LocalAPIAudioDecoder.sampleRate
            )
        }
    }

    static func samples(from fileURL: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: fileURL)
        let sourceFormat = file.processingFormat
        let framesToRead = file.length
        guard framesToRead > 0 else { return [] }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(framesToRead)
        ) else {
            throw NSError(domain: "LocalAPIAudioDecoder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to allocate audio buffer."])
        }

        try file.read(into: sourceBuffer, frameCount: AVAudioFrameCount(framesToRead))
        return try AudioBufferConverter.monoSamples(
            from: sourceBuffer,
            targetSampleRate: self.sampleRate
        )
    }

    static func samples(fromAudioData data: Data, suggestedExtension: String) throws -> [Float] {
        let ext = suggestedExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". \n\t")).isEmpty
            ? "wav"
            : suggestedExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". \n\t"))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluidvoice-api-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        return try self.samples(from: url)
    }

    static func estimatedSampleCount(for fileURL: URL) throws -> Int {
        let file = try AVAudioFile(forReading: fileURL)
        let sourceFormat = file.processingFormat
        guard sourceFormat.sampleRate > 0 else {
            throw NSError(domain: "LocalAPIAudioDecoder", code: -6, userInfo: [NSLocalizedDescriptionKey: "Audio file has an invalid sample rate."])
        }

        return Int((Double(file.length) * self.sampleRate / sourceFormat.sampleRate).rounded())
    }
}
