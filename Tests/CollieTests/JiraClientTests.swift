import XCTest
@testable import Collie

final class JiraClientTests: XCTestCase {

    // MARK: - Multipart body

    func testMultipartBodyContainsFilePart() {
        let payload = Data([0xFF, 0xD8, 0xFF, 0xE0])   // JPEG SOI sentinel
        let (body, boundary) = JiraClient.makeMultipartBody(
            filename: "screenshot.jpg",
            mimeType: "image/jpeg",
            fileData: payload
        )
        let text = String(decoding: body, as: UTF8.self)

        XCTAssertTrue(boundary.hasPrefix("CollieBoundary-"))
        // Jira contract: the part name must be "file".
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"screenshot.jpg\""))
        XCTAssertTrue(text.contains("Content-Type: image/jpeg"))
        XCTAssertTrue(text.contains("--\(boundary)--"))
    }

    func testMultipartBodyForLogsJSON() {
        let payload = #"[{"a":1}]"#.data(using: .utf8)!
        let (body, _) = JiraClient.makeMultipartBody(
            filename: "collie-logs-x.json",
            mimeType: "application/json",
            fileData: payload
        )
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("filename=\"collie-logs-x.json\""))
        XCTAssertTrue(text.contains("Content-Type: application/json"))
        XCTAssertTrue(text.contains(#"[{"a":1}]"#))
    }

    // MARK: - Error classification

    private func isSuccess(_ r: JiraOperationResult<Data>) -> Bool {
        if case .success = r { return true }; return false
    }
    private func isPermanent(_ r: JiraOperationResult<Data>) -> Bool {
        if case .permanentFailure = r { return true }; return false
    }
    private func isTransient(_ r: JiraOperationResult<Data>) -> Bool {
        if case .transientFailure = r { return true }; return false
    }

    func testClassify2xxIsSuccess() {
        XCTAssertTrue(isSuccess(JiraClient.classify(statusCode: 201, responseBody: Data())))
    }

    func testClassify401IsPermanentWithPATMessage() {
        let result = JiraClient.classify(statusCode: 401, responseBody: Data())
        guard case .permanentFailure(let reason) = result else {
            return XCTFail("401 must be permanent")
        }
        XCTAssertTrue(reason.contains("PAT"))
    }

    func testClassify400IsPermanentAndIncludesBodySnippet() {
        let body = #"{"errors":{"parent":"Parent issue not found"}}"#.data(using: .utf8)!
        let result = JiraClient.classify(statusCode: 400, responseBody: body)
        guard case .permanentFailure(let reason) = result else {
            return XCTFail("400 must be permanent")
        }
        XCTAssertTrue(reason.contains("Parent issue not found"))
    }

    func testClassify408And429AreTransient() {
        XCTAssertTrue(isTransient(JiraClient.classify(statusCode: 408, responseBody: Data())))
        XCTAssertTrue(isTransient(JiraClient.classify(statusCode: 429, responseBody: Data())))
    }

    func testClassify5xxIsTransient() {
        XCTAssertTrue(isTransient(JiraClient.classify(statusCode: 500, responseBody: Data())))
        XCTAssertTrue(isTransient(JiraClient.classify(statusCode: 503, responseBody: Data())))
    }

    func testClassifyOther4xxIsPermanent() {
        XCTAssertTrue(isPermanent(JiraClient.classify(statusCode: 403, responseBody: Data())))
        XCTAssertTrue(isPermanent(JiraClient.classify(statusCode: 404, responseBody: Data())))
    }
}
