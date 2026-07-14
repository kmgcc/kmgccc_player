//
//  ArtRuntimeLoader.swift
//  myPlayer2
//
//  Loads an optional local art runtime when one is present. A missing or
//  invalid runtime is a normal fallback, not an error.
//

import CryptoKit
import Darwin
import Foundation

nonisolated private struct ArtRuntimeManifest: Decodable, Sendable {
    let schemaVersion: Int
    let runtimeVersion: String
    let abiVersion: Int
    let architectures: [String]
    let entryPoints: [String]
    let librarySHA256: String
}

private enum ArtRuntimeContract {
    nonisolated static let bundleName = "ArtRuntime"
    nonisolated static let runtimeFileName = "ArtRuntime"
    nonisolated static let manifestFileName = "ArtRuntime.manifest.json"
    nonisolated static let schemaVersion = 1
    nonisolated static let runtimeVersion = "1.0.0"
    nonisolated static let abiVersion: Int32 = 1
    nonisolated static let requiredEntryPoints = [
        "kmg_art_runtime_abi_version",
        "kmg_art_runtime_decrypt",
        "kmg_art_runtime_free"
    ]
}

final class ArtRuntimeLoader: @unchecked Sendable {
    nonisolated static let shared = ArtRuntimeLoader()

    enum Availability: Equatable {
        case ready
        case unavailable(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    private typealias ABIVersionFunction = @convention(c) () -> Int32
    private typealias DecryptFunction = @convention(c) (
        UnsafePointer<UInt8>?,
        Int,
        UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
        UnsafeMutablePointer<Int>?
    ) -> Int32
    private typealias FreeFunction = @convention(c) (
        UnsafeMutablePointer<UInt8>?,
        Int
    ) -> Void

    nonisolated let availability: Availability
    nonisolated private let decryptFunction: DecryptFunction?
    nonisolated private let freeFunction: FreeFunction?
    nonisolated(unsafe) private let runtimeHandle: UnsafeMutableRawPointer?

    nonisolated private init() {
        do {
            let loaded = try Self.loadRuntime()
            availability = .ready
            decryptFunction = loaded.decrypt
            freeFunction = loaded.free
            runtimeHandle = loaded.handle
        } catch {
            availability = .unavailable(error.localizedDescription)
            decryptFunction = nil
            freeFunction = nil
            runtimeHandle = nil
        }
    }

    nonisolated func decrypt(_ data: Data, logicalName: String) throws -> Data {
        guard let decryptFunction, let freeFunction else {
            throw ArtRuntimeError.unavailable(
                availabilityReason ?? "art runtime is unavailable"
            )
        }

        var output: UnsafeMutablePointer<UInt8>?
        var outputLength = 0
        let status = data.withUnsafeBytes { rawBuffer in
            decryptFunction(
                rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                rawBuffer.count,
                &output,
                &outputLength
            )
        }

        guard status == 0, let output, outputLength >= 0 else {
            throw ArtRuntimeError.decodingFailed(logicalName)
        }
        defer { freeFunction(output, outputLength) }
        return Data(bytes: output, count: outputLength)
    }

    nonisolated private var availabilityReason: String? {
        guard case let .unavailable(reason) = availability else { return nil }
        return reason
    }

    private struct LoadedRuntime {
        nonisolated(unsafe) let handle: UnsafeMutableRawPointer
        nonisolated let decrypt: DecryptFunction
        nonisolated let free: FreeFunction
    }

    nonisolated private static func loadRuntime() throws -> LoadedRuntime {
        guard let bundleURL = Bundle.main.url(
            forResource: ArtRuntimeContract.bundleName,
            withExtension: "bundle"
        ),
        let bundle = Bundle(url: bundleURL),
        let resourceURL = bundle.resourceURL else {
            throw ArtRuntimeError.missingBundle
        }

        let manifestURL = resourceURL.appendingPathComponent(
            ArtRuntimeContract.manifestFileName
        )
        let runtimeURL = bundle.executableURL
            ?? resourceURL
                .appendingPathComponent("../MacOS", isDirectory: true)
                .appendingPathComponent(ArtRuntimeContract.runtimeFileName)

        guard FileManager.default.fileExists(atPath: manifestURL.path),
              FileManager.default.fileExists(atPath: runtimeURL.path) else {
            throw ArtRuntimeError.missingBundle
        }

        let manifest = try JSONDecoder().decode(
            ArtRuntimeManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.schemaVersion == ArtRuntimeContract.schemaVersion,
              manifest.runtimeVersion == ArtRuntimeContract.runtimeVersion,
              manifest.abiVersion == Int(ArtRuntimeContract.abiVersion),
              manifest.architectures.contains(Self.currentArchitecture),
              Set(ArtRuntimeContract.requiredEntryPoints).isSubset(
                  of: Set(manifest.entryPoints)
              ) else {
            throw ArtRuntimeError.invalidManifest
        }

        let runtimeData = try Data(contentsOf: runtimeURL)
        let hash = SHA256.hash(data: runtimeData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard hash.caseInsensitiveCompare(manifest.librarySHA256) == .orderedSame else {
            throw ArtRuntimeError.invalidManifest
        }

        guard let handle = dlopen(runtimeURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw ArtRuntimeError.loadFailed(String(cString: dlerror()))
        }

        guard let abiVersion = symbol(
            "kmg_art_runtime_abi_version",
            in: handle,
            as: ABIVersionFunction.self
        ),
        let decrypt = symbol(
            "kmg_art_runtime_decrypt",
            in: handle,
            as: DecryptFunction.self
        ),
        let free = symbol(
            "kmg_art_runtime_free",
            in: handle,
            as: FreeFunction.self
        ),
        abiVersion() == ArtRuntimeContract.abiVersion else {
            throw ArtRuntimeError.missingEntryPoint
        }

        return LoadedRuntime(handle: handle, decrypt: decrypt, free: free)
    }

    nonisolated private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer, as type: T.Type) -> T? {
        name.withCString { pointer in
            guard let address = dlsym(handle, pointer) else { return nil }
            return unsafeBitCast(address, to: type)
        }
    }

    nonisolated private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private enum ArtRuntimeError: LocalizedError {
        case missingBundle
        case invalidManifest
        case missingEntryPoint
        case loadFailed(String)
        case unavailable(String)
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingBundle:
                return "art runtime bundle is unavailable"
            case .invalidManifest:
                return "art runtime manifest is invalid"
            case .missingEntryPoint:
                return "art runtime entry point is unavailable"
            case let .loadFailed(reason):
                return "art runtime failed to load: \(reason)"
            case let .unavailable(reason):
                return reason
            case let .decodingFailed(logicalName):
                return "art runtime could not decode asset: \(logicalName)"
            }
        }
    }
}
