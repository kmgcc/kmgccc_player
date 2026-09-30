import XCTest
@testable import kmgccc_player

@MainActor
final class DisplayHDRCapabilityTests: XCTestCase {
    func testCTA861PQMetadataIsRecognized() {
        XCTAssertTrue(DisplayHDRCapability.hasHDRStaticMetadata(in: makeEDID(eotfFlags: 0x04)))
        XCTAssertTrue(DisplayHDRCapability.hasHDRStaticMetadata(in: makeEDID(eotfFlags: 0x08)))
    }

    func testSDRMetadataAndInvalidChecksumAreRejected() {
        XCTAssertFalse(DisplayHDRCapability.hasHDRStaticMetadata(in: makeEDID(eotfFlags: 0x01)))

        var invalid = makeEDID(eotfFlags: 0x04)
        invalid[255] ^= 0x01
        XCTAssertFalse(DisplayHDRCapability.hasHDRStaticMetadata(in: invalid))
    }

    func testOnlyTrueHDRAllowsHDRHighlight() {
        XCTAssertFalse(HDRDisplayInfo.unsupported.allowsHDRHighlight)

        let edrOnly = HDRDisplayInfo(
            capability: .edrOnly,
            maximumPotentialEDR: 2,
            maximumCurrentEDR: 1,
            maximumReferenceEDR: 0,
            reason: "test"
        )
        XCTAssertFalse(edrOnly.allowsHDRHighlight)

        let trueHDR = HDRDisplayInfo(
            capability: .trueHDR,
            maximumPotentialEDR: 6,
            maximumCurrentEDR: 1,
            maximumReferenceEDR: 0,
            reason: "test"
        )
        XCTAssertTrue(trueHDR.allowsHDRHighlight)
    }

    private func makeEDID(eotfFlags: UInt8) -> [UInt8] {
        var base = [UInt8](repeating: 0, count: 128)
        base[126] = 1
        applyChecksum(to: &base)

        var extensionBlock = [UInt8](repeating: 0, count: 128)
        extensionBlock[0] = 0x02 // CTA-861 extension
        extensionBlock[1] = 0x03
        // Data block collection runs from byte 4 to byte 126.
        extensionBlock[2] = 0
        // Extended data block, length 3, HDR Static Metadata Data Block.
        extensionBlock[4] = 0xE3
        extensionBlock[5] = 0x06
        extensionBlock[6] = eotfFlags
        extensionBlock[7] = 0
        applyChecksum(to: &extensionBlock)
        return base + extensionBlock
    }

    private func applyChecksum(to block: inout [UInt8]) {
        let sum = block[0..<127].reduce(0) { partial, byte in
            (partial + Int(byte)) & 0xFF
        }
        block[127] = UInt8((256 - sum) & 0xFF)
    }
}
