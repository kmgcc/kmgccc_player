@preconcurrency import CrashReporter
import CryptoKit
import Foundation

nonisolated enum PLCrashReportConversionError: Error {
    case invalidReport
    case missingCrashedThread
}

nonisolated enum PLCrashReportConverter {
    static func convert(
        data: Data,
        anonymousInstallID: String,
        importedAt: Date = Date()
    ) throws -> CrashReportEnvelope {
        let source = try PLCrashReport(data: data)
        let occurredAt = source.systemInfo?.timestamp ?? importedAt
        let threads = convertThreads(source)
        guard let crashedThread = threads.first(where: \.isCrashed) else {
            throw PLCrashReportConversionError.missingCrashedThread
        }
        let images = convertImages(source)
        let executableImage = executableImage(from: images)
        let appInfo = source.applicationInfo
        let processInfo = source.hasProcessInfo ? source.processInfo : nil
        let snapshot = decodeSnapshot(source.customData)

        let machCodes = (source.machExceptionInfo?.codes as? [NSNumber]) ?? []
        let exceptionInfo = source.hasExceptionInfo ? source.exceptionInfo : nil
        let signalInfo = source.signalInfo
        let systemInfo = source.systemInfo
        let machineInfo = source.hasMachineInfo ? source.machineInfo : nil

        return CrashReportEnvelope(
            schemaVersion: 1,
            reportID: stableReportID(for: data),
            anonymousInstallID: anonymousInstallID,
            sessionID: nil,
            occurredAt: occurredAt,
            importedAt: importedAt,
            app: CrashAppInfo(
                bundleID: appInfo?.applicationIdentifier ?? Bundle.main.bundleIdentifier ?? "kmgccc.player",
                version: appInfo?.applicationMarketingVersion
                    ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                    ?? "unknown",
                build: appInfo?.applicationVersion
                    ?? Bundle.main.infoDictionary?["CFBundleVersion"] as? String
                    ?? "unknown",
                architecture: currentArchitecture,
                executableUUID: executableImage?.uuid ?? "00000000-0000-0000-0000-000000000000"
            ),
            system: CrashSystemInfo(
                osVersion: systemInfo?.operatingSystemVersion ?? ProcessInfo.processInfo.operatingSystemVersionString,
                modelIdentifier: machineInfo?.modelName,
                locale: Locale.current.identifier
            ),
            process: CrashProcessInfo(
                uptimeSeconds: processInfo?.processStartTime.map {
                    max(0, occurredAt.timeIntervalSince($0))
                }
            ),
            exception: CrashExceptionInfo(
                signal: signalInfo?.name,
                machType: source.machExceptionInfo.map { hex($0.type) },
                machCode: machCodes.first.map { hex($0.uint64Value) },
                machSubcode: machCodes.dropFirst().first.map { hex($0.uint64Value) },
                name: exceptionInfo?.exceptionName,
                reason: exceptionInfo?.exceptionReason ?? signalInfo?.code
            ),
            threads: threads,
            crashedThread: CrashRegisterSet(
                threadIndex: crashedThread.index,
                values: convertRegisters(source)
            ),
            binaryImages: images,
            appContext: snapshot?.appContext,
            breadcrumbs: snapshot?.breadcrumbs ?? [],
            clientRedaction: CrashRedactionInfo(version: CrashReportSanitizer.redactionVersion, replacementCounts: [:]),
            uploadMode: .automatic,
            userDescription: nil
        )
    }

    private static func convertThreads(_ report: PLCrashReport) -> [CrashThread] {
        (report.threads as? [PLCrashReportThreadInfo] ?? []).prefix(128).map { thread in
            let frames = (thread.stackFrames as? [PLCrashReportStackFrameInfo] ?? []).prefix(256).map { frame in
                let image = report.image(forAddress: frame.instructionPointer)
                let symbol = frame.symbolInfo
                return CrashFrame(
                    instructionAddress: hex(frame.instructionPointer),
                    imageUUID: image?.hasImageUUID == true ? image?.imageUUID : nil,
                    imageName: image?.imageName,
                    imageBaseAddress: image.map { hex($0.imageBaseAddress) },
                    imageRelativeAddress: image.map { hex(frame.instructionPointer &- $0.imageBaseAddress) },
                    symbolName: symbol?.symbolName,
                    symbolOffset: symbol.map { Int(clamping: frame.instructionPointer &- $0.startAddress) }
                )
            }
            return CrashThread(
                index: thread.threadNumber,
                id: nil,
                name: nil,
                queueName: nil,
                isCrashed: thread.crashed,
                frames: Array(frames)
            )
        }
    }

    private static func convertRegisters(_ report: PLCrashReport) -> [String: String] {
        guard let crashed = (report.threads as? [PLCrashReportThreadInfo])?.first(where: \.crashed) else {
            return [:]
        }
        var result: [String: String] = [:]
        for register in (crashed.registers as? [PLCrashReportRegisterInfo] ?? []).prefix(128) {
            result[register.registerName] = hex(register.registerValue)
        }
        return result
    }

    private static func convertImages(_ report: PLCrashReport) -> [CrashBinaryImage] {
        (report.images as? [PLCrashReportBinaryImageInfo] ?? []).prefix(512).compactMap { image in
            guard image.hasImageUUID else { return nil }
            return CrashBinaryImage(
                uuid: image.imageUUID,
                basename: image.imageName,
                architecture: currentArchitecture,
                loadAddress: hex(image.imageBaseAddress),
                size: Int64(clamping: image.imageSize),
                version: nil
            )
        }
    }

    private static func executableImage(from images: [CrashBinaryImage]) -> CrashBinaryImage? {
        let executableName = Bundle.main.executableURL?.lastPathComponent
        return images.first { image in
            guard let executableName else { return false }
            return URL(fileURLWithPath: image.basename).lastPathComponent == executableName
        } ?? images.first
    }

    private static func decodeSnapshot(_ data: Data?) -> CrashCaptureSnapshot? {
        guard let data else { return nil }
        return try? JSONDecoder.crashReportDecoder().decode(CrashCaptureSnapshot.self, from: data)
    }

    private static func stableReportID(for data: Data) -> String {
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let value: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: value).uuidString.lowercased()
    }

    private static func hex(_ value: UInt64) -> String {
        String(format: "0x%llx", value)
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
