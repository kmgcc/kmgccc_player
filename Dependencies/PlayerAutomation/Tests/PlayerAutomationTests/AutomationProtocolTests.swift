import Darwin
import Foundation
import Testing
@testable import PlayerAutomationIPC
@testable import PlayerAutomationProtocol

@Test
func wireRoundTripPreservesRequestAndUnknownJSONFields() throws {
    let requestID = UUID()
    let request = AutomationRequest(
        method: AutomationMethod.systemInfo,
        params: .object([
            "futureField": .string("ignored by the App until supported"),
            "limit": .number(10)
        ]),
        context: AutomationRequestContext(
            libraryID: UUID(),
            deadline: Date(timeIntervalSince1970: 1_700_000_000)
        ),
        requestID: requestID
    )
    let data = try AutomationWireCoding.encoder().encode(request)
    let decoded = try AutomationWireCoding.decoder().decode(AutomationRequest.self, from: data)
    #expect(decoded == request)
}

@Test
func frameDecoderHandlesPartialAndMultipleFrames() throws {
    let codec = try AutomationIPCFrameCodec(maximumFrameBytes: 128)
    let first = try codec.encode(Data("first".utf8))
    let second = try codec.encode(Data("second".utf8))
    var buffer = Data()
    var decoded: [Data] = []
    for byte in first + second {
        buffer.append(byte)
        while let payload = try codec.decodeNext(from: &buffer) {
            decoded.append(payload)
        }
    }
    #expect(decoded == [Data("first".utf8), Data("second".utf8)])
    #expect(buffer.isEmpty)
}

@Test
func frameCodecRejectsOversizeAndNonFiniteNumbers() throws {
    let codec = try AutomationIPCFrameCodec(maximumFrameBytes: 3)
    #expect(throws: AutomationIPCError.frameTooLarge(4)) {
        _ = try codec.encode(Data(repeating: 0x01, count: 4))
    }

    #expect(throws: AutomationCodingError.nonFiniteNumber) {
        _ = try AutomationWireCoding.encoder().encode(AutomationJSONValue.number(.infinity))
    }
}

@Test
func responseFactoriesKeepRequestID() {
    let request = AutomationRequest(method: AutomationMethod.systemPing)
    let success = AutomationResponse.success(for: request, result: .null)
    let failure = AutomationResponse.failure(
        for: request,
        error: AutomationError(code: .methodNotFound, message: "missing")
    )
    #expect(success.requestID == request.requestID)
    #expect(failure.requestID == request.requestID)
}

@Test
func unixSocketListenerRoundTripsARequest() async throws {
    let socketURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("player-automation-\(UUID().uuidString)", isDirectory: false)
    let configuration = try AutomationIPCConfiguration(
        maximumFrameBytes: 4_096,
        maximumConcurrentConnections: 2,
        ioTimeout: 2
    )
    let listener = try AutomationIPCListener(
        socketPath: socketURL.path,
        configuration: configuration
    )
    try await listener.start { request in
        AutomationResponse.success(
            for: request,
            result: .object(["echo": .string(request.method)])
        )
    }
    defer {
        Task {
            await listener.stop()
        }
    }

    let client = try AutomationIPCClient(
        socketPath: socketURL.path,
        configuration: configuration
    )
    let request = AutomationRequest(method: AutomationMethod.systemPing)
    let response = try client.send(request)
    #expect(response.requestID == request.requestID)
    #expect(response.error == nil)
    #expect(response.result == .object(["echo": .string(AutomationMethod.systemPing)]))
}

@Test
func unixSocketHandshakeRejectsWrongSecretAndAcceptsCorrectSecret() async throws {
    let socketURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("pa-secret-\(UUID().uuidString.prefix(12))", isDirectory: false)
    let secret = Data("test-install-secret".utf8)
    let configuration = try AutomationIPCConfiguration(
        maximumFrameBytes: 4_096,
        maximumConcurrentConnections: 2,
        ioTimeout: 2,
        sharedSecret: secret
    )
    let listener = try AutomationIPCListener(
        socketPath: socketURL.path,
        configuration: configuration
    )
    try await listener.start { request in
        AutomationResponse.success(
            for: request,
            result: .object(["echo": .string(request.method)])
        )
    }
    defer {
        Task { await listener.stop() }
    }

    let wrongConfiguration = try AutomationIPCConfiguration(
        maximumFrameBytes: 4_096,
        maximumConcurrentConnections: 2,
        ioTimeout: 2,
        sharedSecret: Data("wrong-secret".utf8)
    )
    let wrongResponse = try AutomationIPCClient(
        socketPath: socketURL.path,
        configuration: wrongConfiguration
    ).send(AutomationRequest(method: AutomationMethod.systemPing))
    #expect(wrongResponse.error?.code == .authorizationRequired)

    let response = try AutomationIPCClient(
        socketPath: socketURL.path,
        configuration: configuration
    ).send(AutomationRequest(method: AutomationMethod.systemPing))
    #expect(response.error == nil)
    #expect(response.result == .object(["echo": .string(AutomationMethod.systemPing)]))
}

@Test
func secretStoreCreatesPrivateStableCredential() throws {
    let socketURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("pa-store-\(UUID().uuidString.prefix(12))", isDirectory: false)
    defer {
        try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent())
    }

    let first = try AutomationIPCSecretStore.loadOrCreate(forSocketPath: socketURL.path)
    let second = try AutomationIPCSecretStore.load(forSocketPath: socketURL.path)
    #expect(first.count == AutomationIPCSecretStore.defaultByteCount)
    #expect(second == first)

    var info = stat()
    #expect(lstat(try AutomationIPCSecretStore.url(forSocketPath: socketURL.path).path, &info) == 0)
    #expect((info.st_mode & mode_t(0o077)) == 0)
}
