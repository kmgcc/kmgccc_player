import AppKit
import CoreImage
import XCTest
@testable import kmgccc_player

@MainActor
final class MotionArtworkFrameRenderingTests: XCTestCase {
    func testFrameFlightGateAllowsOnlyOneActiveRenderUntilMatchingCompletion() throws {
        var gate = MotionArtworkFrameFlightGate()
        let firstRequest = try XCTUnwrap(gate.begin())

        XCTAssertTrue(gate.isInFlight)
        XCTAssertNil(gate.begin())
        XCTAssertFalse(gate.finish(UUID()))
        XCTAssertTrue(gate.isInFlight)

        XCTAssertTrue(gate.finish(firstRequest))
        XCTAssertFalse(gate.isInFlight)
        XCTAssertNotNil(gate.begin())
    }

    func testPortraitTrackTransformRotatesDecodedPixelsAndNormalizesOrigin() {
        let raw = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 80))
        let rotated = MotionArtworkFrameOrientation.apply(raw,
            preferredTransform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 80, ty: 0))
        XCTAssertEqual(rotated.extent, CGRect(x: 0, y: 0, width: 80, height: 120))
        XCTAssertEqual(MotionArtworkFrameOrientation.apply(raw, preferredTransform: .identity).extent, raw.extent)
    }

    func testCenterSquareCropKeepsTheMiddleOfWideAndTallFrames() throws {
        for source in [try bandedFrame(width: 8, height: 4), try bandedFrame(width: 4, height: 8)] {
            let cropped = MotionArtworkFrameGeometry.centerSquareCrop(source)
            XCTAssertEqual(cropped.width, 4)
            XCTAssertEqual(cropped.height, 4)
            let side = min(source.width, source.height)
            let expectedRect = CGRect(
                x: (source.width - side) / 2,
                y: (source.height - side) / 2,
                width: side,
                height: side
            )
            let expected = try XCTUnwrap(source.cropping(to: expectedRect))
            XCTAssertEqual(try rgbaBytes(from: cropped), try rgbaBytes(from: expected))
        }
    }

    func testCroppingBeforeRasterizationMatchesCenterCropOfRasterizedWideAndTallFrames() throws {
        let context = CIContext(options: nil)
        for size in [(8, 4), (4, 8), (9, 4), (4, 9)] {
            let source = try coordinateFrame(width: size.0, height: size.1)
            let expected = MotionArtworkFrameGeometry.centerSquareCrop(source)
            let ciImage = MotionArtworkFrameGeometry.centerSquareCrop(CIImage(cgImage: source))
            let actual = try XCTUnwrap(context.createCGImage(ciImage, from: ciImage.extent))
            XCTAssertEqual(actual.width, expected.width)
            XCTAssertEqual(actual.height, expected.height)
            let expectedBytes = try rgbaBytes(from: expected)
            let actualBytes = try rgbaBytes(from: actual)
            XCTAssertEqual(actualBytes.count, expectedBytes.count)
            for (actualByte, expectedByte) in zip(actualBytes, expectedBytes) {
                XCTAssertLessThanOrEqual(abs(Int(actualByte) - Int(expectedByte)), 1)
            }
        }
    }

    func testPanoramaUpdatesClearArtworkAndFarBlurFromSameFrame() throws {
        var config = CoverGradientBlurConfig.fullscreen
        config.colorOverlayOpacity = 0
        config.extensionFloorStrength = 0.16
        for placement in [CoverGradientBlurArtworkPlacement.leading, .centeredSymmetric] {
            config.artworkPlacement = placement
            let red = try XCTUnwrap(CoverGradientBlurRenderer.render(
                artworkCGImage: solidFrame(red: 1, blue: 0), targetSize: CGSize(width: 480, height: 240),
                dominantColor: nil, config: config, displayScale: 2))
            let blue = try XCTUnwrap(CoverGradientBlurRenderer.render(
                artworkCGImage: solidFrame(red: 0, blue: 1), targetSize: CGSize(width: 480, height: 240),
                dominantColor: nil, config: config, displayScale: 2))
            XCTAssertEqual(red.width, blue.width)
            XCTAssertEqual(red.height, blue.height)
            // Sample the clear cover and the opposite end of its blur extension.
            for fraction in [0.25, 0.95] {
                let first = try pixel(red, fraction: fraction)
                let second = try pixel(blue, fraction: fraction)
                XCTAssertGreaterThan(first.red, first.blue)
                XCTAssertGreaterThan(second.blue, second.red)
            }
        }
    }

    func testArtisticFrameProcessesEachDecodedImageThroughSameMaskAndScale() throws {
        let mask = try solidFrame(red: 1, blue: 1)
        let red = try XCTUnwrap(ClassicArtworkFrameExtendedArtworkRenderer.render(
            sourceImage: solidFrame(red: 1, blue: 0), mask: mask, outputPixel: 256,
            artworkScale: 0.82, edgeBlurEnabled: true))
        let blue = try XCTUnwrap(ClassicArtworkFrameExtendedArtworkRenderer.render(
            sourceImage: solidFrame(red: 0, blue: 1), mask: mask, outputPixel: 256,
            artworkScale: 0.82, edgeBlurEnabled: true))
        XCTAssertEqual(red.width, 256)
        XCTAssertEqual(blue.height, 256)
        let first = try pixel(red, fraction: 0.5)
        let second = try pixel(blue, fraction: 0.5)
        XCTAssertGreaterThan(first.red, first.blue)
        XCTAssertGreaterThan(second.blue, second.red)
    }

    private func solidFrame(red: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 512, height: 512,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        return try XCTUnwrap(context.makeImage())
    }

    private func bandedFrame(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let firstBand: CGRect
        let middleBand: CGRect
        let lastBand: CGRect
        if width > height {
            firstBand = CGRect(x: 0, y: 0, width: 2, height: height)
            middleBand = CGRect(x: 2, y: 0, width: 4, height: height)
            lastBand = CGRect(x: 6, y: 0, width: 2, height: height)
        } else {
            firstBand = CGRect(x: 0, y: 0, width: width, height: 2)
            middleBand = CGRect(x: 0, y: 2, width: width, height: 4)
            lastBand = CGRect(x: 0, y: 6, width: width, height: 2)
        }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(firstBand)
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(middleBand)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(lastBand)
        return try XCTUnwrap(context.makeImage())
    }

    private func coordinateFrame(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for y in 0..<height {
            for x in 0..<width {
                context.setFillColor(CGColor(
                    red: CGFloat(x) / CGFloat(max(1, width - 1)),
                    green: CGFloat(y) / CGFloat(max(1, height - 1)),
                    blue: 0, alpha: 1
                ))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func rgbaBytes(from image: CGImage) throws -> [UInt8] {
        let bytesPerRow = image.width * 4
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: data, count: bytesPerRow * image.height))
    }

    private func pixel(_ image: CGImage, fraction: Double) throws -> (red: UInt8, green: UInt8, blue: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let value = bytes.withUnsafeMutableBytes { buffer -> (UInt8, UInt8, UInt8)? in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.translateBy(x: -CGFloat(image.width) * fraction, y: -CGFloat(image.height) * 0.5)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return (buffer[0], buffer[1], buffer[2])
        }
        let result = try XCTUnwrap(value)
        return (result.0, result.1, result.2)
    }
}
