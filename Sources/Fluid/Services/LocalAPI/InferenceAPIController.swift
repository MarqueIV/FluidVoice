import Foundation

@MainActor
final class InferenceAPIController: LocalAPIRouteHandler {
    typealias FileTranscriptionOperation = @MainActor (URL) async throws -> TranscriptionResult

    struct TranscribeJSONRequest: Decodable {
        let path: String?
        let audioBase64: String?
        let filename: String?
    }

    struct TextRequest: Decodable {
        let text: String
    }

    struct TranscribeResponse: Encodable {
        let text: String
        let confidence: Float
        let sampleCount: Int
        let provider: String
    }

    struct PostprocessResponse: Encodable {
        let text: String
        let provider: String
        let model: String
    }

    private let fileTranscriptionOperation: FileTranscriptionOperation

    init(fileTranscriptionOperation: FileTranscriptionOperation? = nil) {
        self.fileTranscriptionOperation = fileTranscriptionOperation ?? { fileURL in
            let service = MeetingTranscriptionService(asrService: AppServices.shared.asr)
            return try await service.transcribeFile(fileURL)
        }
    }

    func handle(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        guard request.method == "POST" else {
            return LocalAPI.error("Method not allowed.", status: 405)
        }

        switch request.path {
        case "/v1/transcribe":
            return await self.transcribe(request)
        case "/v1/postprocess":
            return await self.postprocess(request)
        default:
            return LocalAPI.error("Route not found.", status: 404)
        }
    }

    private func transcribe(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        do {
            if let fileURL = try self.decodeFilePath(from: request) {
                return try await self.transcribeFile(fileURL)
            }

            let temporaryFile = try await self.writeUploadedAudioToTemporaryFile(from: request)
            do {
                let response = try await self.transcribeFile(temporaryFile.fileURL)
                await Self.removeTemporaryAudioFile(at: temporaryFile.cleanupURL)
                return response
            } catch {
                await Self.removeTemporaryAudioFile(at: temporaryFile.cleanupURL)
                throw error
            }
        } catch {
            return LocalAPI.error(error.localizedDescription, status: 400)
        }
    }

    private func transcribeFile(_ fileURL: URL) async throws -> LocalAPI.Response {
        let result = try await self.fileTranscriptionOperation(fileURL)
        return LocalAPI.json(
            TranscribeResponse(
                text: result.text,
                confidence: result.confidence,
                sampleCount: Self.sampleCount(forDuration: result.duration),
                provider: SettingsStore.shared.selectedSpeechModel.displayName
            )
        )
    }

    static func sampleCount(forDuration duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > 0 else { return 0 }
        let estimatedCount = duration * 16_000
        guard estimatedCount < Double(Int.max) else { return Int.max }
        return Int(estimatedCount.rounded())
    }

    private func decodeFilePath(from request: LocalAPI.Request) throws -> URL? {
        guard self.isJSON(request) else { return nil }
        let payload: TranscribeJSONRequest
        do {
            payload = try LocalAPI.decoder.decode(TranscribeJSONRequest.self, from: request.body)
        } catch {
            throw NSError(domain: "InferenceAPIController", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON audio payload."])
        }

        guard let path = payload.path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func postprocess(_ request: LocalAPI.Request) async -> LocalAPI.Response {
        do {
            let text = try self.decodeText(from: request)
            let result = try await DictationPostProcessingService.shared.process(text)
            return LocalAPI.json(
                PostprocessResponse(
                    text: result.text,
                    provider: result.providerID,
                    model: result.model
                )
            )
        } catch {
            return LocalAPI.error(error.localizedDescription, status: 400)
        }
    }

    private nonisolated struct TemporaryAudioFile: Sendable {
        let fileURL: URL
        let cleanupURL: URL
    }

    private func writeUploadedAudioToTemporaryFile(from request: LocalAPI.Request) async throws -> TemporaryAudioFile {
        let data: Data
        let filename: String
        if self.isJSON(request) {
            let payload: TranscribeJSONRequest
            do {
                payload = try LocalAPI.decoder.decode(TranscribeJSONRequest.self, from: request.body)
            } catch {
                throw NSError(domain: "InferenceAPIController", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON audio payload."])
            }

            if let audioBase64 = payload.audioBase64,
               let decodedData = Data(base64Encoded: audioBase64)
            {
                data = decodedData
                filename = payload.filename ?? "audio.wav"
            } else {
                throw NSError(domain: "InferenceAPIController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing audio path or audioBase64."])
            }
        } else {
            guard !request.body.isEmpty else {
                throw NSError(domain: "InferenceAPIController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing audio body."])
            }
            data = request.body
            filename = request.headers["x-filename"] ?? "audio.wav"
        }

        return try await Task.detached(priority: .utility) {
            let suppliedName = URL(fileURLWithPath: filename).lastPathComponent
            let safeName = suppliedName.isEmpty || suppliedName == "." || suppliedName == ".." ? "audio.wav" : suppliedName
            let temporaryDirectoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("fluidvoice-api-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: false)
            let temporaryFileURL = temporaryDirectoryURL.appendingPathComponent(safeName)
            do {
                try data.write(to: temporaryFileURL, options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: temporaryDirectoryURL)
                throw error
            }
            return TemporaryAudioFile(fileURL: temporaryFileURL, cleanupURL: temporaryDirectoryURL)
        }.value
    }

    private nonisolated static func removeTemporaryAudioFile(at cleanupURL: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: cleanupURL)
        }.value
    }

    private func decodeText(from request: LocalAPI.Request) throws -> String {
        if self.isJSON(request) {
            let payload: TextRequest
            do {
                payload = try LocalAPI.decoder.decode(TextRequest.self, from: request.body)
            } catch {
                throw NSError(domain: "InferenceAPIController", code: -4, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON text payload."])
            }
            return payload.text
        }

        guard let text = String(data: request.body, encoding: .utf8) else {
            throw NSError(domain: "InferenceAPIController", code: -2, userInfo: [NSLocalizedDescriptionKey: "Text body must be UTF-8."])
        }
        return text
    }

    private func isJSON(_ request: LocalAPI.Request) -> Bool {
        request.headers["content-type"]?.lowercased().contains("application/json") == true
    }
}
