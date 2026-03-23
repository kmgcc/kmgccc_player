//
//  NCMConverter.swift
//  myPlayer2
//
//  kmgccc_player - NCM 文件解密转换器
//  将网易云音乐 NCM 格式转换为 MP3/FLAC
//

import CommonCrypto
import Foundation

final class NCMConverter: @unchecked Sendable {
    
    private let coreKey: [UInt8] = [
        0x68, 0x7A, 0x48, 0x52, 0x41, 0x6D, 0x73, 0x6F,
        0x35, 0x6B, 0x49, 0x6E, 0x62, 0x61, 0x78, 0x57
    ]
    
    private let modifyKey: [UInt8] = [
        0x23, 0x31, 0x34, 0x6C, 0x6A, 0x6B, 0x5F, 0x21,
        0x5C, 0x5D, 0x26, 0x30, 0x55, 0x3C, 0x27, 0x28
    ]
    
    private var fileHandle: FileHandle?
    private var keyBox: [UInt8] = []
    private var metadata: NCMMetadata?
    private var albumPicUrl: String = ""
    private var imageData: Data?
    private var format: NCMFormat = .mp3
    private var filePath: String = ""
    
    nonisolated init() {}
    
    func convert(
        from sourceURL: URL,
        outputDir: URL? = nil,
        fetchCover: Bool = true,
        progressHandler: ((NCMConversionStep, Double) -> Void)? = nil
    ) async throws -> NCMConversionResult {
        
        self.filePath = sourceURL.path
        
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw NCMConverterError.invalidFile
        }
        
        progressHandler?(.waiting, 0.0)
        
        let fileHandle = try FileHandle(forReadingFrom: sourceURL)
        self.fileHandle = fileHandle
        defer {
            fileHandle.closeFile()
            self.fileHandle = nil
        }
        
        progressHandler?(.decrypting, 0.05)
        
        try validateMagicHeader()
        progressHandler?(.decrypting, 0.1)
        
        let currentOffset = fileHandle.offsetInFile
        try fileHandle.seek(toOffset: currentOffset + 2)
        progressHandler?(.decrypting, 0.15)
        
        let keyData = try decryptKey()
        self.keyBox = buildKeyBox(key: keyData)
        progressHandler?(.decrypting, 0.2)
        
        try decryptMetadata()
        progressHandler?(.decrypting, 0.25)
        
        try readCoverData()
        progressHandler?(.decrypting, 0.3)
        
        if fetchCover && imageData == nil && !albumPicUrl.isEmpty {
            progressHandler?(.downloadingCover, 0.7)
            var coverUrl = albumPicUrl
            if coverUrl.hasPrefix("http://") {
                coverUrl = "https://" + String(coverUrl.dropFirst(7))
            }
            imageData = try? await downloadCover(from: coverUrl)
            progressHandler?(.downloadingCover, 0.95)
        }
        
        let outputURL = try await decryptAudio(
            outputDir: outputDir,
            progressHandler: { audioProgress in
                let baseProgress = 0.3
                let audioRange = 0.4
                let stepProgress = baseProgress + audioProgress * audioRange
                progressHandler?(.decrypting, stepProgress)
            }
        )
        
        guard let metadata = self.metadata else {
            throw NCMConverterError.invalidMetadata
        }
        
        progressHandler?(.completed, 1.0)
        
        return NCMConversionResult(
            audioFileURL: outputURL,
            format: self.format,
            metadata: metadata,
            coverData: self.imageData
        )
    }
    
    private func validateMagicHeader() throws {
        guard let fileHandle = self.fileHandle else {
            throw NCMConverterError.fileReadError
        }
        
        guard let headerData = try fileHandle.read(upToCount: 8) else {
            throw NCMConverterError.fileReadError
        }
        
        guard headerData.count == 8 else {
            throw NCMConverterError.invalidFile
        }
        
        let magic1 = headerData.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) }
        let magic2 = headerData.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
        
        guard magic1 == 0x4E455443 && magic2 == 0x4D414446 else {
            throw NCMConverterError.invalidMagic
        }
    }
    
    private func decryptKey() throws -> [UInt8] {
        guard let fileHandle = self.fileHandle else {
            throw NCMConverterError.fileReadError
        }
        
        guard let keyLenData = try fileHandle.read(upToCount: 4) else {
            throw NCMConverterError.fileReadError
        }
        let keyLen = keyLenData.withUnsafeBytes { $0.load(as: UInt32.self) }
        
        guard let keyData = try fileHandle.read(upToCount: Int(keyLen)) else {
            throw NCMConverterError.fileReadError
        }
        
        let xorKeyData = keyData.map { $0 ^ 0x64 }
        let decryptedKey = aesECBDecrypt(data: Data(xorKeyData), key: Data(coreKey))
        
        var finalKey = decryptedKey
        if let lastByte = decryptedKey.last, lastByte > 0 && lastByte <= 16 {
            let padLen = Int(lastByte)
            let padStart = decryptedKey.count - padLen
            if decryptedKey.suffix(padLen).allSatisfy({ $0 == lastByte }) {
                finalKey = decryptedKey.prefix(padStart)
            }
        }
        
        guard finalKey.count > 17 else {
            throw NCMConverterError.keyDecryptionFailed
        }
        
        return Array(finalKey[17...])
    }
    
    private func decryptMetadata() throws {
        guard let fileHandle = self.fileHandle else {
            throw NCMConverterError.fileReadError
        }
        
        guard let metaLenData = try fileHandle.read(upToCount: 4) else {
            throw NCMConverterError.fileReadError
        }
        let metaLen = metaLenData.withUnsafeBytes { $0.load(as: UInt32.self) }
        
        if metaLen == 0 {
            self.metadata = nil
            return
        }
        
        guard let metaData = try fileHandle.read(upToCount: Int(metaLen)) else {
            throw NCMConverterError.fileReadError
        }
        
        let xorMetaData = metaData.map { $0 ^ 0x63 }
        
        guard xorMetaData.count > 22 else {
            throw NCMConverterError.metadataDecryptionFailed
        }
        let base64Data = Data(xorMetaData[22...])
        
        guard let decodedData = Data(base64Encoded: base64Data) else {
            throw NCMConverterError.metadataDecryptionFailed
        }
        
        var decryptedMeta = aesECBDecrypt(data: decodedData, key: Data(modifyKey))
        
        if let lastByte = decryptedMeta.last {
            let paddingLength = Int(lastByte)
            if paddingLength > 0 && paddingLength <= kCCBlockSizeAES128 && paddingLength <= decryptedMeta.count {
                let paddingStart = decryptedMeta.count - paddingLength
                let isValidPadding = decryptedMeta[paddingStart...].allSatisfy { $0 == lastByte }
                if isValidPadding {
                    decryptedMeta = decryptedMeta.prefix(decryptedMeta.count - paddingLength)
                }
            }
        }
        
        guard decryptedMeta.count > 6 else {
            throw NCMConverterError.metadataDecryptionFailed
        }
        
        let jsonData = decryptedMeta[6...]
        let decoder = JSONDecoder()
        self.metadata = try decoder.decode(NCMMetadata.self, from: jsonData)
        
        if let metadata = self.metadata {
            self.albumPicUrl = metadata.albumPic
        }
    }
    
    private func readCoverData() throws {
        guard let fileHandle = self.fileHandle else {
            throw NCMConverterError.fileReadError
        }
        
        let gapOffset = fileHandle.offsetInFile
        try fileHandle.seek(toOffset: gapOffset + 5)
        
        guard let coverFrameLenData = try fileHandle.read(upToCount: 4) else {
            throw NCMConverterError.fileReadError
        }
        let coverFrameLen = coverFrameLenData.withUnsafeBytes { $0.load(as: UInt32.self) }
        
        guard let coverDataLenData = try fileHandle.read(upToCount: 4) else {
            throw NCMConverterError.fileReadError
        }
        let coverDataLen = coverDataLenData.withUnsafeBytes { $0.load(as: UInt32.self) }
        
        if coverDataLen > 0 && coverDataLen < 10 * 1024 * 1024 {
            guard let coverData = try fileHandle.read(upToCount: Int(coverDataLen)) else {
                throw NCMConverterError.fileReadError
            }
            self.imageData = coverData
        }
        
        let remainingSkip = Int(coverFrameLen) - Int(coverDataLen)
        if remainingSkip > 0 {
            let currentOffset = fileHandle.offsetInFile
            try fileHandle.seek(toOffset: currentOffset + UInt64(remainingSkip))
        }
    }
    
    private func decryptAudio(
        outputDir: URL?,
        progressHandler: ((Double) -> Void)?
    ) async throws -> URL {
        guard let fileHandle = self.fileHandle else {
            throw NCMConverterError.fileReadError
        }
        
        let sourceURL = URL(fileURLWithPath: filePath)
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let targetDir = outputDir ?? FileManager.default.temporaryDirectory
        
        let bufferSize = 0x8000
        guard var firstChunk = try fileHandle.read(upToCount: bufferSize) else {
            throw NCMConverterError.fileReadError
        }
        
        decryptChunk(&firstChunk)
        
        if let metadataFormat = self.metadata?.format.lowercased() {
            if metadataFormat == "mp3" {
                self.format = .mp3
            } else if metadataFormat == "flac" {
                self.format = .flac
            } else {
                self.format = detectFormatFromHeader(firstChunk)
            }
        } else {
            self.format = detectFormatFromHeader(firstChunk)
        }
        
        let outputFileName = "\(baseName).\(format.rawValue)"
        let outputURL = targetDir.appendingPathComponent(outputFileName)
        
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: nil) else {
            throw NCMConverterError.fileWriteError
        }
        
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { outputHandle.closeFile() }
        
        outputHandle.write(firstChunk)
        
        let fileSize = try FileManager.default.attributesOfItem(atPath: filePath)[.size] as? UInt64 ?? 0
        var processedSize: UInt64 = UInt64(firstChunk.count)
        
        while true {
            guard var chunk = try fileHandle.read(upToCount: bufferSize) else { break }
            if chunk.isEmpty { break }
            
            decryptChunk(&chunk)
            outputHandle.write(chunk)
            
            processedSize += UInt64(chunk.count)
            let totalProgress = Double(processedSize) / Double(fileSize)
            progressHandler?(min(totalProgress, 1.0))
            
            await Task.yield()
        }
        
        progressHandler?(1.0)
        return outputURL
    }
    
    private func decryptChunk(_ chunk: inout Data) {
        for i in 0..<chunk.count {
            let j = (i + 1) & 0xFF
            let idx1 = Int(keyBox[j])
            let idx2 = (idx1 + j) & 0xFF
            chunk[i] ^= keyBox[(idx1 + Int(keyBox[idx2])) & 0xFF]
        }
    }
    
    private func detectFormatFromHeader(_ data: Data) -> NCMFormat {
        guard data.count >= 4 else { return .mp3 }
        
        if data[0] == 0x49 && data[1] == 0x44 && data[2] == 0x33 {
            return .mp3
        }
        
        if data[0] == 0xFF && (data[1] & 0xE0) == 0xE0 {
            return .mp3
        }
        
        if data[0] == 0x66 && data[1] == 0x4C && data[2] == 0x61 && data[3] == 0x43 {
            return .flac
        }
        
        return .mp3
    }
    
    private func buildKeyBox(key: [UInt8]) -> [UInt8] {
        var keyBox = Array(0...255).map { UInt8($0) }
        var swap: UInt8 = 0
        var lastByte: UInt8 = 0
        var keyOffset: UInt8 = 0
        
        for i in 0..<256 {
            swap = keyBox[i]
            let c = (swap &+ lastByte &+ key[Int(keyOffset)]) & 0xFF
            keyOffset &+= 1
            if Int(keyOffset) >= key.count {
                keyOffset = 0
            }
            keyBox[i] = keyBox[Int(c)]
            keyBox[Int(c)] = swap
            lastByte = c
        }
        
        return keyBox
    }
    
    private func aesECBDecrypt(data: Data, key: Data) -> Data {
        guard data.count > 0, key.count == 16 else {
            return Data()
        }
        
        let dataCount = data.count
        let outputLength = dataCount + kCCBlockSizeAES128
        var decryptedBytes = [UInt8](repeating: 0, count: outputLength)
        var numBytesDecrypted: size_t = 0
        
        let keyBytes = Array(key)
        let dataBytes = Array(data)
        
        let cryptStatus = keyBytes.withUnsafeBufferPointer { keyPtr in
            dataBytes.withUnsafeBufferPointer { dataPtr in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyPtr.baseAddress,
                    key.count,
                    nil,
                    dataPtr.baseAddress,
                    dataCount,
                    &decryptedBytes,
                    outputLength,
                    &numBytesDecrypted
                )
            }
        }
        
        guard cryptStatus == kCCSuccess else {
            return Data()
        }
        
        return Data(decryptedBytes.prefix(Int(numBytesDecrypted)))
    }
    
    private func downloadCover(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw NCMConverterError.networkError
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw NCMConverterError.networkError
        }
        
        return data
    }
}