@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class InferenceAPIControllerTests: XCTestCase {
    func testLongPathRequestUsesMeetingFileTranscription() async throws {
        let expectedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("one-hour-meeting-\(UUID().uuidString).wav")
        try Data([0, 1, 2, 3]).write(to: expectedURL)
        defer { try? FileManager.default.removeItem(at: expectedURL) }
        var receivedURL: URL?
        let controller = InferenceAPIController { fileURL in
            receivedURL = fileURL
            return Self.result(duration: 60 * 60, fileName: fileURL.lastPathComponent)
        }
        let body = try JSONSerialization.data(withJSONObject: ["path": expectedURL.path])
        let request = LocalAPI.Request(
            method: "POST",
            path: "/v1/transcribe",
            query: [:],
            headers: ["content-type": "application/json"],
            body: body
        )

        let response = await controller.handle(request)

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(receivedURL, expectedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedURL.path))
        XCTAssertEqual(try Self.responseJSON(response)["text"] as? String, "Test transcript")
        XCTAssertEqual(try Self.responseJSON(response)["sampleCount"] as? Int, 57_600_000)
    }

    func testRawUploadPreservesFilenameAndCleansUpTemporaryFile() async throws {
        var receivedURL: URL?
        var existedDuringTranscription = false
        let controller = InferenceAPIController { fileURL in
            receivedURL = fileURL
            existedDuringTranscription = FileManager.default.fileExists(atPath: fileURL.path)
            return Self.result(duration: 1, fileName: fileURL.lastPathComponent)
        }
        let request = LocalAPI.Request(
            method: "POST",
            path: "/v1/transcribe",
            query: [:],
            headers: ["x-filename": "meeting.m4a"],
            body: Data([0, 1, 2, 3])
        )

        let response = await controller.handle(request)

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(receivedURL?.lastPathComponent, "meeting.m4a")
        XCTAssertTrue(existedDuringTranscription)
        XCTAssertFalse(receivedURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
    }

    func testFailedRawUploadStillCleansUpTemporaryFile() async {
        var receivedURL: URL?
        let controller = InferenceAPIController { fileURL in
            receivedURL = fileURL
            throw NSError(domain: "InferenceAPIControllerTests", code: 1)
        }
        let request = LocalAPI.Request(
            method: "POST",
            path: "/v1/transcribe",
            query: [:],
            headers: ["x-filename": "meeting.wav"],
            body: Data([0, 1, 2, 3])
        )

        let response = await controller.handle(request)

        XCTAssertEqual(response.status, 400)
        XCTAssertFalse(receivedURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
    }

    func testHTTPBodySafetyLimitRemainsBounded() {
        XCTAssertEqual(LocalAPI.maxRequestBytes, 500 * 1024 * 1024)
    }

    func testInvalidDurationsDoNotOverflowSampleCount() {
        XCTAssertEqual(InferenceAPIController.sampleCount(forDuration: .nan), 0)
        XCTAssertEqual(InferenceAPIController.sampleCount(forDuration: -.infinity), 0)
        XCTAssertEqual(InferenceAPIController.sampleCount(forDuration: -1), 0)
        XCTAssertEqual(InferenceAPIController.sampleCount(forDuration: .greatestFiniteMagnitude), Int.max)
    }

    func testFileTranscriptionGateSerializesConcurrentCallers() async {
        let gate = FileTranscriptionGate()
        var activeOperations = 0
        var maximumActiveOperations = 0

        async let first: Void = gate.run {
            activeOperations += 1
            maximumActiveOperations = max(maximumActiveOperations, activeOperations)
            await Task.yield()
            activeOperations -= 1
        }
        async let second: Void = gate.run {
            activeOperations += 1
            maximumActiveOperations = max(maximumActiveOperations, activeOperations)
            await Task.yield()
            activeOperations -= 1
        }

        _ = await (first, second)
        XCTAssertEqual(maximumActiveOperations, 1)
    }

    private static func result(duration: TimeInterval, fileName: String) -> TranscriptionResult {
        TranscriptionResult(
            text: "Test transcript",
            confidence: 1,
            duration: duration,
            processingTime: 0.1,
            fileName: fileName
        )
    }

    private static func responseJSON(_ response: LocalAPI.Response) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }
}
