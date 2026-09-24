import XCTest
@testable import Ordlyd

final class IDUNAnalysisTests: XCTestCase {
    override func tearDown() {
        IDUNURLProtocolStub.reset()
        super.tearDown()
    }

    func testKeychainLogoutDeletesOnlyItsOwnCredential() throws {
        let service = "no.ordlyd.tests.idun.\(UUID().uuidString)"
        let keychain = IDUNKeychain(service: service)
        let neighboringKeychain = IDUNKeychain(service: service, account: "neighbor")
        defer {
            try? keychain.delete()
            try? neighboringKeychain.delete()
        }

        try keychain.save("test-api-key")
        try neighboringKeychain.save("keep-this-key")
        try keychain.delete()

        XCTAssertThrowsError(try keychain.load())
        XCTAssertEqual(try neighboringKeychain.load(), "keep-this-key")
    }

    func testLiveMinimalConnectionCheckWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_IDUN_CONNECTION_TEST"] == "1" else {
            throw XCTSkip("Kjør med RUN_IDUN_CONNECTION_TEST=1 for minimal IDUN-test.")
        }
        let result = try await IDUNConnectionCheck.run()
        XCTAssertEqual(result.reply.lowercased(), "idun fungerer")
        XCTAssertLessThan(result.elapsedSeconds, 60)
        print("IDUN_CONNECTION_RESULT: \(result.message)")
    }

    func testConnectionCheckSendsMinimalPromptToFastModel() throws {
        let request = try IDUNConnectionCheck.makeRequest()
        let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = object["messages"] as! [[String: String]]
        XCTAssertEqual(request.url?.absoluteString, "https://llm.hpc.ntnu.no/v1/chat/completions")
        XCTAssertEqual(object["model"] as? String, "mistralai/Mistral-Medium-3.5-128B")
        XCTAssertEqual(object["max_tokens"] as? Int, 32)
        XCTAssertEqual(messages, [["role": "user", "content": "Svar kun med: IDUN fungerer"]])
    }

    func testConnectionCheckReturnsVisibleReply() throws {
        let data = #"{"choices":[{"message":{"content":"IDUN fungerer"},"finish_reason":"stop"}]}"#.data(using: .utf8)!
        XCTAssertEqual(try IDUNConnectionCheck.reply(from: data), "IDUN fungerer")
    }

    func testLiveIDUNModelInventoryWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_IDUN_MODEL_TEST"] == "1" else {
            throw XCTSkip("Kjør med RUN_IDUN_MODEL_TEST=1 for modelloversikt.")
        }
        var request = URLRequest(url: IDUNSettings.baseURL.appendingPathComponent("models"))
        request.setValue("Bearer \(try IDUNKeychain().load())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let models = (object["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        print("IDUN_MODELS: \(models.sorted())")
        XCTAssertTrue(models.contains("Inferact/GLM-5.3-NVFP4"))
    }
    func testLiveIDUNRoundTripWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_IDUN_LIVE_TEST"] == "1" else {
            throw XCTSkip("Kjør med RUN_IDUN_LIVE_TEST=1 for en ekte IDUN-test.")
        }
        let transcript = [
            TranscriptSegment(id: "s1", start: 0, end: 5, speaker: "Veileder", text: "Vi skal snakke med to kunder."),
            TranscriptSegment(id: "s2", start: 5, end: 10, speaker: "Martin", text: "Jeg sender skjemaet fredag.")
        ]
        let analysis = try await IDUNAnalysisProvider().analyze(transcript: transcript)
        XCTAssertEqual(analysis.schemaVersion, "1.0")
        XCTAssertFalse(analysis.summary.isEmpty)
        XCTAssertFalse(analysis.actionItems.isEmpty)
        XCTAssertTrue(analysis.actionItems.allSatisfy { !$0.evidenceSegmentIDs.isEmpty })
    }

    func testLiveKimiFallbackWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_KIMI_LIVE_TEST"] == "1" else {
            throw XCTSkip("Kjør med RUN_KIMI_LIVE_TEST=1 for ekte Kimi-test.")
        }
        let transcript = [TranscriptSegment(id: "s1", start: 0, end: 5, speaker: "Veileder", text: "Vi bestemmer at Martin sender rapporten fredag.")]
        let meeting = Meeting(id: UUID(), title: "Kort test", date: .now, duration: 5, state: .transcriptReady, transcript: transcript, analysis: nil)
        let analysis = try await IDUNAnalysisProvider().analyze(meeting: meeting, model: .kimi)
        XCTAssertFalse(analysis.summary.isEmpty)
        XCTAssertFalse(analysis.actionItems.isEmpty)
        XCTAssertEqual(analysis.actionItems.first?.evidenceSegmentIDs, ["s1"])
    }

    func testProvidedTranscriptGetsLiveIDUNSummaryWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_IDUN_LIVE_TEST"] == "1",
              let path = ProcessInfo.processInfo.environment["IDUN_TEST_FILE"] else {
            throw XCTSkip("Kjør med RUN_IDUN_LIVE_TEST=1 og IDUN_TEST_FILE for ekte IDUN-test.")
        }
        let text = try ImportedTextDocument.read(from: URL(fileURLWithPath: path))
        let transcript = try ImportedTextDocument.segments(from: text)
        let meeting = Meeting(id: UUID(), title: "test", date: .now, duration: 0, state: .transcriptReady, transcript: transcript, analysis: nil)
        let analysis = try await IDUNAnalysisProvider().analyze(meeting: meeting)
        XCTAssertEqual(analysis.schemaVersion, "1.0")
        XCTAssertFalse(analysis.summary.isEmpty)
        XCTAssertFalse(analysis.keyPoints.isEmpty)
        XCTAssertTrue(analysis.keyPoints.allSatisfy { !$0.evidenceSegmentIDs.isEmpty })
        print("IDUN_SUMMARY: \(analysis.summary)")
        print("IDUN_DECISIONS: \(analysis.decisions.map(\.text))")
        print("IDUN_ACTION_ITEMS: \(analysis.actionItems.map(\.task))")
    }

    func testProvidedTranscriptGetsLiveBorealisSummaryWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_BOREALIS_LIVE_TEST"] == "1",
              let path = ProcessInfo.processInfo.environment["IDUN_TEST_FILE"] else {
            throw XCTSkip("Kjør med RUN_BOREALIS_LIVE_TEST=1 og IDUN_TEST_FILE for Borealis-test.")
        }
        let text = try ImportedTextDocument.read(from: URL(fileURLWithPath: path))
        let transcript = try ImportedTextDocument.segments(from: text)
        let meeting = Meeting(id: UUID(), title: "test", date: .now, duration: 0, state: .transcriptReady, transcript: transcript, analysis: nil)
        let analysis = try await IDUNAnalysisProvider().analyze(meeting: meeting, model: .borealis)
        XCTAssertFalse(analysis.summary.isEmpty)
        XCTAssertTrue(analysis.keyPoints.allSatisfy { !$0.evidenceSegmentIDs.isEmpty })
        print("BOREALIS_SUMMARY: \(analysis.summary)")
        print("BOREALIS_DECISIONS: \(analysis.decisions.map(\.text))")
        print("BOREALIS_ACTION_ITEMS: \(analysis.actionItems.map(\.task))")
    }

    func testProvidedTranscriptGetsSafeBorealisFirstSummaryWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_BOREALIS_PIPELINE_TEST"] == "1",
              let path = ProcessInfo.processInfo.environment["IDUN_TEST_FILE"] else {
            throw XCTSkip("Kjør med RUN_BOREALIS_PIPELINE_TEST=1 og IDUN_TEST_FILE for trygg Borealis-først-test.")
        }
        let text = try ImportedTextDocument.read(from: URL(fileURLWithPath: path))
        let transcript = try ImportedTextDocument.segments(from: text)
        let meeting = Meeting(id: UUID(), title: "test", date: .now, duration: 0, state: .transcriptReady, transcript: transcript, analysis: nil)
        let analysis = try await IDUNAnalysisProvider().analyze(meeting: meeting, mode: .borealisFirst)
        XCTAssertFalse(analysis.summary.isEmpty)
        XCTAssertTrue(analysis.keyPoints.allSatisfy { !$0.evidenceSegmentIDs.isEmpty })
        print("BOREALIS_FIRST_SUMMARY: \(analysis.summary)")
        print("BOREALIS_FIRST_DECISIONS: \(analysis.decisions.map(\.text))")
        print("BOREALIS_FIRST_ACTION_ITEMS: \(analysis.actionItems.map(\.task))")
    }

    func testRequestUsesChosenModelAndExcludesAudio() throws {
        let meeting = Meeting.sample
        let request = try IDUNRequestBuilder.make(meeting: meeting, model: .mistralMedium)
        let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let body = String(data: request.httpBody!, encoding: .utf8)!
        XCTAssertEqual(object["model"] as? String, "mistralai/Mistral-Medium-3.5-128B")
        XCTAssertTrue(body.contains("[s1 00:08]"))
        XCTAssertFalse(body.contains("recording-"))
        XCTAssertFalse(body.contains(".wav"))
        let messages = object["messages"] as! [[String: String]]
        XCTAssertEqual(messages[0]["content"], MeetingPrompt.system)
        XCTAssertEqual(messages[1]["content"], MeetingPrompt.user(meeting: meeting))
    }

    func testProgressStagesUseHonestLabels() {
        XCTAssertEqual(AnalysisStage.awaitingIDUN.title, "IDUN lager oppsummering")
        XCTAssertTrue(AnalysisStage.awaitingIDUN.detail.contains("Venter på svar"))
        XCTAssertTrue(AnalysisStage.awaitingIDUN.detail.contains("valgt IDUN-modell"))
        XCTAssertFalse(AnalysisStage.awaitingIDUN.detail.contains("GLM-modellen"))
        XCTAssertEqual(AnalysisStage.processingResponse.title, "Kontrollerer oppsummeringen")
    }

    func testIDUNRequestAllowsLongModelResponse() throws {
        let request = try IDUNRequestBuilder.make(meeting: .sample, model: .glm)
        let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(request.timeoutInterval, 600)
        XCTAssertEqual(object["max_tokens"] as? Int, 67_584)
        XCTAssertTrue(IDUNAnalysisError.timedOut.localizedDescription.contains("Transkripsjonen er bevart"))
    }


    func testRouterUsesMistralForSmallMeetings() {
        XCTAssertEqual(IDUNModelRouter.route(estimatedInputTokens: 7_999).first, .mistralMedium)
    }

    func testRouterUsesKimiForMediumMeetings() {
        XCTAssertEqual(IDUNModelRouter.route(estimatedInputTokens: 8_000).first, .kimi)
    }

    func testRouterUsesGLMForLargeMeetings() {
        XCTAssertEqual(IDUNModelRouter.route(estimatedInputTokens: 24_000).first, .glm)
    }

    func testRouterFallsBackToKimiBeyondGLMInputLimit() {
        XCTAssertEqual(IDUNModelRouter.route(estimatedInputTokens: 135_168).first, .kimi)
    }

    func testBorealisFirstModeTriesBorealisBeforeSafeAutomaticRoute() {
        XCTAssertEqual(
            IDUNAnalysisMode.borealisFirst.route(estimatedInputTokens: 2_000),
            [.borealis, .mistralMedium, .kimi, .glm]
        )
    }

    func testIDUNResponseParserIdentifiesExhaustedOutputBudget() throws {
        let data = #"{"choices":[{"message":{"content":null,"reasoning_content":"arbeider"},"finish_reason":"length"}]}"#.data(using: .utf8)!
        XCTAssertEqual(try IDUNResponseParser.finishReason(from: data), "length")
    }

    func testPromptSeparatesConfirmedTasksFromPossibleFollowUps() {
        let prompt = MeetingPrompt.system
        XCTAssertTrue(prompt.contains("Hva ble sagt"))
        XCTAssertTrue(prompt.contains("Hva ble bestemt å gjøre"))
        XCTAssertTrue(prompt.contains("mulige oppfølginger"))
        XCTAssertTrue(prompt.contains("upålitelige data"))
    }

    func testUnknownActionEvidenceRejectsOnlyUnsupportedAction() {
        let transcript = [TranscriptSegment(id: "s1", start: 0, end: 3, speaker: nil, text: "Jeg sender utkastet fredag.")]
        let analysis = MeetingAnalysis(summary: "Utkastet sendes.", keyPoints: [], decisions: [], actionItems: [
            ActionItem(task: "Send utkastet", owner: nil, deadline: nil, confidence: .high, evidenceSegmentIDs: ["s1"]),
            ActionItem(task: "Bestill rom", owner: nil, deadline: nil, confidence: .high, evidenceSegmentIDs: ["unknown"])
        ], openQuestions: [])
        let result = AnalysisValidator.validate(analysis, against: transcript)
        XCTAssertEqual(result.analysis.actionItems.map(\.task), ["Send utkastet"])
    }

    func testGLMPointAliasDecodesAsKeyPointText() throws {
        let json = #"{"schema_version":"1.0","summary":"Kort.","key_points":[{"point":"Spark tilbyr gratis veiledning.","evidence_segment_ids":["s1"]}],"decisions":[],"action_items":[],"open_questions":[]}"#.data(using: .utf8)!
        let analysis = try JSONDecoder().decode(MeetingAnalysis.self, from: json)
        XCTAssertEqual(analysis.keyPoints[0].text, "Spark tilbyr gratis veiledning.")
    }

    func testIDUNResponseParserReturnsContent() throws {
        let data = #"{"choices":[{"message":{"content":"{\"summary\":\"Kort\"}"}}]}"#.data(using: .utf8)!
        XCTAssertEqual(try IDUNResponseParser.content(from: data), #"{"summary":"Kort"}"#)
    }

    func testIDUNResponseParserAllowsNullContentForRetry() throws {
        let data = #"{"choices":[{"message":{"content":null,"reasoning_content":"arbeider"},"finish_reason":"length"}]}"#.data(using: .utf8)!
        XCTAssertNil(try IDUNResponseParser.content(from: data))
    }

    func testIDUNResponseParserJoinsOpenAITextContentParts() throws {
        let data = #"{"choices":[{"message":{"content":[{"type":"text","text":"{\"summary\":"},{"type":"text","text":"\"Kort\"}"}]},"finish_reason":"stop"}]}"#.data(using: .utf8)!
        XCTAssertEqual(try IDUNResponseParser.content(from: data), #"{"summary":"Kort"}"#)
    }

    func testIDUNResponseParserIgnoresNonTextContentParts() throws {
        let data = #"{"choices":[{"message":{"content":[{"type":"image_url","image_url":{"url":"data:image/png;base64,redacted"}},{"type":"text","text":"tekst"}]}}]}"#.data(using: .utf8)!
        XCTAssertEqual(try IDUNResponseParser.content(from: data), "tekst")
    }

    func testIDUNResponseParserAllowsMissingOrNullContent() throws {
        let missing = #"{"choices":[{"message":{},"finish_reason":"stop"}]}"#.data(using: .utf8)!
        let null = #"{"choices":[{"message":{"content":null},"finish_reason":"stop"}]}"#.data(using: .utf8)!
        XCTAssertNil(try IDUNResponseParser.content(from: missing))
        XCTAssertNil(try IDUNResponseParser.content(from: null))
    }

    func testMalformedJSONGetsExactlyOneRepairRequestAndThenSucceeds() async throws {
        IDUNURLProtocolStub.enqueue([
            Self.response(content: #"{"schema_version":"1.0","summary": "avbrutt"#),
            Self.response(content: Self.validAnalysisJSON)
        ])
        let provider = IDUNAnalysisProvider(session: Self.stubbedSession(), credential: { "sanitized-test-key" })

        let analysis = try await provider.analyze(meeting: .sample, model: .mistralMedium)

        XCTAssertEqual(analysis.summary, "Kort oppsummering.")
        let requests = IDUNURLProtocolStub.requests
        XCTAssertEqual(requests.count, 2)
        let repairBody = try XCTUnwrap(Self.bodyData(of: try XCTUnwrap(requests.last)))
        let repairJSON = try JSONSerialization.jsonObject(with: repairBody) as! [String: Any]
        let messages = repairJSON["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.last?["role"] as? String, "user")
        XCTAssertTrue((messages.last?["content"] as? String)?.localizedCaseInsensitiveContains("reparer") == true)
    }

    func testMissingRequiredFieldsGetsOneRepairThenRetryableError() async throws {
        let malformed = #"{"schema_version":"1.0","summary":"mangler påkrevde felt"}"#
        IDUNURLProtocolStub.enqueue([Self.response(content: malformed), Self.response(content: malformed)])
        let provider = IDUNAnalysisProvider(session: Self.stubbedSession(), credential: { "sanitized-test-key" })

        do {
            _ = try await provider.analyze(meeting: .sample, model: .mistralMedium)
            XCTFail("Forventet feil")
        } catch let error as IDUNAnalysisError {
            XCTAssertEqual(error, .invalidJSON)
            XCTAssertTrue(error.isRetryable)
        }
        XCTAssertEqual(IDUNURLProtocolStub.requests.count, 2)
    }

    func testWrongSchemaVersionGetsOneRepairThenRetryableError() async throws {
        let wrongSchema = Self.validAnalysisJSON.replacingOccurrences(of: #""1.0""#, with: #""2.0""#)
        IDUNURLProtocolStub.enqueue([Self.response(content: wrongSchema), Self.response(content: wrongSchema)])
        let provider = IDUNAnalysisProvider(session: Self.stubbedSession(), credential: { "sanitized-test-key" })

        await XCTAssertThrowsRetryableIDUNError {
            _ = try await provider.analyze(meeting: .sample, model: .mistralMedium)
        }
        XCTAssertEqual(IDUNURLProtocolStub.requests.count, 2)
    }

    func testRateLimitAndTemporaryServerErrorsAreRetryable() {
        XCTAssertTrue(IDUNAnalysisError.server(429).isRetryable)
        XCTAssertTrue(IDUNAnalysisError.server(503).isRetryable)
        XCTAssertFalse(IDUNAnalysisError.server(401).isRetryable)
        XCTAssertFalse(IDUNAnalysisError.server(400).isRetryable)
        XCTAssertTrue(IDUNAnalysisError.timedOut.isRetryable)
        XCTAssertTrue(IDUNAnalysisError.invalidJSON.isRetryable)
    }

    func testHTTPRateLimitIsRetryableAndDoesNotAttemptJSONRepair() async throws {
        IDUNURLProtocolStub.enqueue(statusesAndData: [(429, Data(#"{"error":{"message":"rate limited"}}"#.utf8))])
        let provider = IDUNAnalysisProvider(session: Self.stubbedSession(), credential: { "sanitized-test-key" })

        do {
            _ = try await provider.analyze(meeting: .sample, model: .mistralMedium)
            XCTFail("Forventet rate-limit-feil")
        } catch let error as IDUNAnalysisError {
            XCTAssertEqual(error, .server(429))
            XCTAssertTrue(error.isRetryable)
        }
        XCTAssertEqual(IDUNURLProtocolStub.requests.count, 1)
    }

    func testAutomaticRouteFallsBackToNextModelAfterTemporaryServerFailure() async throws {
        IDUNURLProtocolStub.enqueue(statusesAndData: [
            (503, Data(#"{"error":{"message":"temporary"}}"#.utf8)),
            (200, Self.response(content: Self.validAnalysisJSON))
        ])
        let provider = IDUNAnalysisProvider(session: Self.stubbedSession(), credential: { "sanitized-test-key" })

        let analysis = try await provider.analyze(meeting: .sample)

        XCTAssertEqual(analysis.summary, "Kort oppsummering.")
        let models = try IDUNURLProtocolStub.requests.map { request -> String in
            let body = try XCTUnwrap(Self.bodyData(of: request))
            return try XCTUnwrap((JSONSerialization.jsonObject(with: body) as? [String: Any])?["model"] as? String)
        }
        XCTAssertEqual(models, [IDUNModel.mistralMedium.rawValue, IDUNModel.kimi.rawValue])
    }

    func testBorealisFirstFallsBackWhenBorealisCannotProduceValidSchema() async throws {
        let invalid = #"Dette er norsk tekst, men ikke det avtalte JSON-formatet."#
        IDUNURLProtocolStub.enqueue([
            Self.response(content: invalid),
            Self.response(content: invalid),
            Self.response(content: Self.validAnalysisJSON)
        ])
        let provider = IDUNAnalysisProvider(session: Self.stubbedSession(), credential: { "sanitized-test-key" })

        let analysis = try await provider.analyze(meeting: .sample, mode: .borealisFirst)

        XCTAssertEqual(analysis.summary, "Kort oppsummering.")
        let models = try IDUNURLProtocolStub.requests.map { request -> String in
            let body = try XCTUnwrap(Self.bodyData(of: request))
            return try XCTUnwrap((JSONSerialization.jsonObject(with: body) as? [String: Any])?["model"] as? String)
        }
        XCTAssertEqual(models, [IDUNModel.borealis.rawValue, IDUNModel.borealis.rawValue, IDUNModel.mistralMedium.rawValue])
    }

    func testBorealisOutcomeReportsWhichModelActuallyProducedTheResult() async throws {
        let invalid = #"Ikke gyldig JSON."#
        IDUNURLProtocolStub.enqueue([
            Self.response(content: invalid),
            Self.response(content: invalid),
            Self.response(content: Self.validAnalysisJSON)
        ])
        let provider = IDUNAnalysisProvider(session: Self.stubbedSession(), credential: { "sanitized-test-key" })

        let outcome = try await provider.analyzeWithOutcome(meeting: .sample, mode: .borealisFirst)

        XCTAssertEqual(outcome.model, .mistralMedium)
        XCTAssertEqual(outcome.attemptedModels, [.borealis, .mistralMedium])
        XCTAssertEqual(outcome.analysis.summary, "Kort oppsummering.")
    }

    private static let validAnalysisJSON = #"{"schema_version":"1.0","summary":"Kort oppsummering.","key_points":[],"decisions":[],"action_items":[],"open_questions":[]}"#

    private static func response(content: String?) -> Data {
        let contentObject: Any = content ?? NSNull()
        return try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": contentObject], "finish_reason": "stop"]]])
    }

    private static func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IDUNURLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private static func bodyData(of request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[..<count])
        }
        return data
    }
}

private func XCTAssertThrowsRetryableIDUNError(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Forventet retrybar IDUN-feil", file: file, line: line)
    } catch let error as IDUNAnalysisError {
        XCTAssertEqual(error, .invalidJSON, file: file, line: line)
        XCTAssertTrue(error.isRetryable, file: file, line: line)
    } catch {
        XCTFail("Uventet feiltype: \(type(of: error))", file: file, line: line)
    }
}

private final class IDUNURLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var queuedResponses: [(status: Int, data: Data)] = []
    private static var capturedRequests: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { capturedRequests } }
    static func enqueue(_ responses: [Data]) { enqueue(statusesAndData: responses.map { (200, $0) }) }
    static func enqueue(statusesAndData: [(Int, Data)]) {
        lock.withLock { queuedResponses = statusesAndData; capturedRequests = [] }
    }
    static func reset() { lock.withLock { queuedResponses = []; capturedRequests = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let queued: (status: Int, data: Data)? = Self.lock.withLock {
            Self.capturedRequests.append(request)
            return Self.queuedResponses.isEmpty ? nil : Self.queuedResponses.removeFirst()
        }
        guard let queued else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: queued.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: queued.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
