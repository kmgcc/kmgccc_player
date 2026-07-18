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
        let hash = Self.sha256Hex(
            Self.codeSignatureIndependentData(from: runtimeData)
        )
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

    private struct MachHeaderLayout {
        let loadCommandsOffset: Int
        let is64Bit: Bool
    }

    /// Swift's compiler emits an ad-hoc signature for the runtime. The App's
    /// Release signing replaces it with a distribution signature, so hashing
    /// the complete Mach-O would make the manifest fail after packaging. This
    /// reconstructs the unsigned payload that the private build script hashes.
    nonisolated private static func codeSignatureIndependentData(from data: Data) -> Data {
        guard let header = machHeaderLayout(in: data),
              let commandCount = readUInt32LittleEndian(data, at: 16),
              let commandBytes = readUInt32LittleEndian(data, at: 20)
        else {
            return data
        }

        var cursor = header.loadCommandsOffset
        var payloadEnd: UInt64 = 0
        var codeSignatureCommand: (offset: Int, size: Int)?
        var linkEditSegment: (offset: Int, fileOffset: UInt64)?

        func includeRange(offset: UInt64, size: UInt64) {
            guard size > 0,
                  offset <= UInt64(data.count),
                  size <= UInt64(data.count) - offset
            else {
                return
            }
            payloadEnd = max(payloadEnd, offset + size)
        }

        for _ in 0..<commandCount {
            guard let command = readUInt32LittleEndian(data, at: cursor),
                  let commandSize = readUInt32LittleEndian(data, at: cursor + 4),
                  commandSize >= 8,
                  commandSize <= UInt32(data.count - cursor)
            else {
                return data
            }

            let size = Int(commandSize)
            let baseCommand = command & 0x7FFF_FFFF

            switch baseCommand {
            case 0x1D: // LC_CODE_SIGNATURE
                guard size >= 16,
                      readUInt32LittleEndian(data, at: cursor + 8) != nil,
                      readUInt32LittleEndian(data, at: cursor + 12) != nil
                else {
                    return data
                }
                codeSignatureCommand = (offset: cursor, size: size)

            case 0x01: // LC_SEGMENT
                guard !header.is64Bit, size >= 56,
                      let name = machOName(in: data, at: cursor + 8),
                      let fileOffset = readUInt32LittleEndian(data, at: cursor + 32),
                      let fileSize = readUInt32LittleEndian(data, at: cursor + 36)
                else {
                    break
                }
                if name == "__LINKEDIT" {
                    linkEditSegment = (cursor, UInt64(fileOffset))
                } else {
                    includeRange(offset: UInt64(fileOffset), size: UInt64(fileSize))
                }

            case 0x19: // LC_SEGMENT_64
                guard header.is64Bit, size >= 72,
                      let name = machOName(in: data, at: cursor + 8),
                      let fileOffset = readUInt64LittleEndian(data, at: cursor + 40),
                      let fileSize = readUInt64LittleEndian(data, at: cursor + 48)
                else {
                    break
                }
                if name == "__LINKEDIT" {
                    linkEditSegment = (cursor, fileOffset)
                } else {
                    includeRange(offset: fileOffset, size: fileSize)
                }

            case 0x02: // LC_SYMTAB
                guard size >= 24,
                      let symbolOffset = readUInt32LittleEndian(data, at: cursor + 8),
                      let symbolCount = readUInt32LittleEndian(data, at: cursor + 12),
                      let stringOffset = readUInt32LittleEndian(data, at: cursor + 16),
                      let stringSize = readUInt32LittleEndian(data, at: cursor + 20)
                else {
                    break
                }
                let symbolStride: UInt64 = header.is64Bit ? 16 : 12
                includeRange(
                    offset: UInt64(symbolOffset),
                    size: UInt64(symbolCount) * symbolStride
                )
                includeRange(offset: UInt64(stringOffset), size: UInt64(stringSize))

            case 0x0B: // LC_DYSYMTAB
                guard size >= 80 else { break }
                let tables: [(offset: Int, count: Int, stride: UInt64)] = [
                    (32, 36, 12),
                    (40, 44, header.is64Bit ? 56 : 52),
                    (48, 52, 4),
                    (56, 60, 4),
                    (64, 68, 8),
                    (72, 76, 8),
                ]
                for table in tables {
                    guard let offset = readUInt32LittleEndian(data, at: cursor + table.offset),
                          let count = readUInt32LittleEndian(data, at: cursor + table.count)
                    else {
                        return data
                    }
                    includeRange(
                        offset: UInt64(offset),
                        size: UInt64(count) * table.stride
                    )
                }

            case 0x22: // LC_DYLD_INFO / LC_DYLD_INFO_ONLY
                guard size >= 48 else { break }
                for pairOffset in stride(from: 8, through: 40, by: 8) {
                    guard let offset = readUInt32LittleEndian(data, at: cursor + pairOffset),
                          let size = readUInt32LittleEndian(data, at: cursor + pairOffset + 4)
                    else {
                        return data
                    }
                    includeRange(offset: UInt64(offset), size: UInt64(size))
                }

            case 0x1E, 0x26, 0x29, 0x2B, 0x2E, 0x33, 0x34:
                // Link-edit data commands with one offset/size pair.
                guard size >= 16,
                      let offset = readUInt32LittleEndian(data, at: cursor + 8),
                      let size = readUInt32LittleEndian(data, at: cursor + 12)
                else {
                    break
                }
                includeRange(offset: UInt64(offset), size: UInt64(size))

            default:
                break
            }

            cursor += size
        }

        guard let codeSignatureCommand,
              payloadEnd > 0,
              payloadEnd <= UInt64(data.count),
              codeSignatureCommand.offset + codeSignatureCommand.size <= Int(payloadEnd),
              commandCount > 0,
              commandBytes >= UInt32(codeSignatureCommand.size)
        else {
            return data
        }

        var canonical = Data(data.prefix(Int(payloadEnd)))
        canonical.replaceSubrange(
            codeSignatureCommand.offset..<(codeSignatureCommand.offset + codeSignatureCommand.size),
            with: Data(repeating: 0, count: codeSignatureCommand.size)
        )
        writeUInt32LittleEndian(commandCount - 1, to: &canonical, at: 16)
        writeUInt32LittleEndian(
            commandBytes - UInt32(codeSignatureCommand.size),
            to: &canonical,
            at: 20
        )

        if let linkEditSegment {
            let linkEditSize = payloadEnd - linkEditSegment.fileOffset
            if header.is64Bit {
                writeUInt64LittleEndian(
                    linkEditSize,
                    to: &canonical,
                    at: linkEditSegment.offset + 48
                )
            } else {
                writeUInt32LittleEndian(
                    UInt32(linkEditSize),
                    to: &canonical,
                    at: linkEditSegment.offset + 36
                )
            }
        }

        return canonical
    }

    nonisolated private static func machHeaderLayout(in data: Data) -> MachHeaderLayout? {
        guard let magic = readUInt32LittleEndian(data, at: 0) else { return nil }
        switch magic {
        case 0xFEED_FACE:
            return MachHeaderLayout(loadCommandsOffset: 28, is64Bit: false)
        case 0xFEED_FACF:
            return MachHeaderLayout(loadCommandsOffset: 32, is64Bit: true)
        default:
            return nil
        }
    }

    nonisolated private static func machOName(in data: Data, at offset: Int) -> String? {
        guard offset >= 0, offset + 16 <= data.count else { return nil }
        let bytes = data[offset..<(offset + 16)]
        let name = bytes.prefix { $0 != 0 }
        return String(bytes: name, encoding: .ascii)
    }

    nonisolated private static func readUInt32LittleEndian(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    nonisolated private static func readUInt64LittleEndian(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    nonisolated private static func writeUInt32LittleEndian(
        _ value: UInt32,
        to data: inout Data,
        at offset: Int
    ) {
        guard offset >= 0, offset + 4 <= data.count else { return }
        for index in 0..<4 {
            data[offset + index] = UInt8((value >> UInt32(index * 8)) & 0xFF)
        }
    }

    nonisolated private static func writeUInt64LittleEndian(
        _ value: UInt64,
        to data: inout Data,
        at offset: Int
    ) {
        guard offset >= 0, offset + 8 <= data.count else { return }
        for index in 0..<8 {
            data[offset + index] = UInt8((value >> UInt64(index * 8)) & 0xFF)
        }
    }

    nonisolated private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
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
