//
//  BokehTransitionMetalContext.swift
//  myPlayer2
//

import Metal
import MetalKit
import Foundation
import os

struct BokehTransitionMetalManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let libraryVersion: String
    let abiVersion: Int
    let composeUniformStride: Int
    let bokehUniformStride: Int
    let entryPoints: [String]
}

/// Contract shared by the public Swift boundary and the private enhancement
/// resource. The public target never loads its default Metal library; a private
/// build injects these two files into a bundle or nested resource bundle.
enum BokehTransitionMetalResourceContract {
    static let manifestSchemaVersion = 1
    static let libraryVersion = "1.0.0"
    static let abiVersion = 1
    static let manifestFileName = "BokehTransition.manifest.json"
    static let libraryFileName = "BokehTransition.metallib"
    static let resourceBundleName = "BokehTransitionResources"
    static let requiredEntryPoints = [
        "composeTransition",
        "basicBokehGather",
        "presentTransitionVertex",
        "presentTransitionFragment"
    ]
}

/// Process-wide immutable Metal state. Surfaces own their textures; this type
/// deliberately owns only the device, queue and compiled pipelines.
@MainActor
final class BokehTransitionMetalContext {
    enum Availability: Equatable {
        case ready
        case unavailable(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var reason: String? {
            if case let .unavailable(reason) = self { return reason }
            return nil
        }
    }

    static let shared = BokehTransitionMetalContext()

    let availability: Availability
    let device: MTLDevice?
    let commandQueue: MTLCommandQueue?
    let composePipeline: MTLComputePipelineState?
    let gatherPipeline: MTLComputePipelineState?
    let presentPipeline: MTLRenderPipelineState?
    let manifest: BokehTransitionMetalManifest?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.kmgccc.player",
        category: "BokehTransition"
    )

    private init() {
        guard MemoryLayout<TransitionComposeUniforms>.stride == 40,
              MemoryLayout<TransitionBokehUniforms>.stride == 32 else {
            availability = .unavailable("Swift/Metal uniform stride mismatch")
            device = nil
            commandQueue = nil
            composePipeline = nil
            gatherPipeline = nil
            presentPipeline = nil
            manifest = nil
            return
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            availability = .unavailable("No Metal device")
            self.device = nil
            commandQueue = nil
            composePipeline = nil
            gatherPipeline = nil
            presentPipeline = nil
            manifest = nil
            return
        }
        guard let commandQueue = device.makeCommandQueue() else {
            availability = .unavailable("Unable to create Metal command queue")
            self.device = device
            self.commandQueue = nil
            composePipeline = nil
            gatherPipeline = nil
            presentPipeline = nil
            manifest = nil
            return
        }

        guard let resource = Self.locateExternalResource() else {
            availability = .unavailable(
                "External Bokeh manifest/library is unavailable; using Gaussian fallback"
            )
            self.device = device
            self.commandQueue = commandQueue
            composePipeline = nil
            gatherPipeline = nil
            presentPipeline = nil
            manifest = nil
            return
        }

        do {
            let manifest = try Self.loadAndValidateManifest(from: resource.manifestURL)
            let library = try device.makeLibrary(URL: resource.libraryURL)

            let composeFunction = try Self.requiredFunction(
                named: "composeTransition",
                type: .kernel,
                in: library
            )
            let gatherFunction = try Self.requiredFunction(
                named: "basicBokehGather",
                type: .kernel,
                in: library
            )
            let vertexFunction = try Self.requiredFunction(
                named: "presentTransitionVertex",
                type: .vertex,
                in: library
            )
            let fragmentFunction = try Self.requiredFunction(
                named: "presentTransitionFragment",
                type: .fragment,
                in: library
            )

            let composePipeline = try device.makeComputePipelineState(function: composeFunction)
            let gatherPipeline = try device.makeComputePipelineState(function: gatherFunction)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let presentPipeline = try device.makeRenderPipelineState(descriptor: descriptor)

            self.device = device
            self.commandQueue = commandQueue
            self.composePipeline = composePipeline
            self.gatherPipeline = gatherPipeline
            self.presentPipeline = presentPipeline
            self.manifest = manifest
            availability = .ready
            logger.debug(
                "Bokeh Metal enhancement loaded, version=\(manifest.libraryVersion, privacy: .public)"
            )
        } catch {
            availability = .unavailable("Metal pipeline creation failed: \(error.localizedDescription)")
            self.device = device
            self.commandQueue = commandQueue
            composePipeline = nil
            gatherPipeline = nil
            presentPipeline = nil
            manifest = nil
            logger.error("Bokeh Metal initialization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private struct ExternalResource {
        let manifestURL: URL
        let libraryURL: URL
    }

    private static func locateExternalResource() -> ExternalResource? {
        let fileManager = FileManager.default
        var bundles = [Bundle.main]

        if let resourceBundleURL = Bundle.main.url(
            forResource: BokehTransitionMetalResourceContract.resourceBundleName,
            withExtension: "bundle"
        ),
           let resourceBundle = Bundle(url: resourceBundleURL) {
            bundles.append(resourceBundle)
        }

        for bundle in bundles {
            guard let resourceURL = bundle.resourceURL else { continue }

            let directories = [
                resourceURL,
                resourceURL.appendingPathComponent("BokehTransition", isDirectory: true)
            ]
            for directory in directories {
                let manifestURL = directory.appendingPathComponent(
                    BokehTransitionMetalResourceContract.manifestFileName
                )
                let libraryURL = directory.appendingPathComponent(
                    BokehTransitionMetalResourceContract.libraryFileName
                )
                guard fileManager.fileExists(atPath: manifestURL.path) else { continue }
                guard fileManager.fileExists(atPath: libraryURL.path) else {
                    continue
                }
                return ExternalResource(manifestURL: manifestURL, libraryURL: libraryURL)
            }
        }

        return nil
    }

    private static func loadAndValidateManifest(from url: URL) throws -> BokehTransitionMetalManifest {
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(BokehTransitionMetalManifest.self, from: data)

        guard manifest.schemaVersion == BokehTransitionMetalResourceContract.manifestSchemaVersion else {
            throw BokehTransitionMetalError.invalidManifest("schema version mismatch")
        }
        guard manifest.libraryVersion == BokehTransitionMetalResourceContract.libraryVersion else {
            throw BokehTransitionMetalError.invalidManifest("library version mismatch")
        }
        guard manifest.abiVersion == BokehTransitionMetalResourceContract.abiVersion else {
            throw BokehTransitionMetalError.invalidManifest("ABI version mismatch")
        }
        guard manifest.composeUniformStride == MemoryLayout<TransitionComposeUniforms>.stride,
              manifest.bokehUniformStride == MemoryLayout<TransitionBokehUniforms>.stride else {
            throw BokehTransitionMetalError.invalidManifest("uniform stride mismatch")
        }
        guard Set(BokehTransitionMetalResourceContract.requiredEntryPoints).isSubset(
            of: Set(manifest.entryPoints)
        ) else {
            throw BokehTransitionMetalError.invalidManifest("required entry point missing")
        }
        return manifest
    }

    private static func requiredFunction(
        named name: String,
        type: MTLFunctionType,
        in library: MTLLibrary
    ) throws -> MTLFunction {
        guard let function = library.makeFunction(name: name) else {
            throw BokehTransitionMetalError.missingFunction(name)
        }
        guard function.functionType == type else {
            throw BokehTransitionMetalError.wrongFunctionType(name)
        }
        return function
    }

    private enum BokehTransitionMetalError: LocalizedError {
        case invalidManifest(String)
        case missingFunction(String)
        case wrongFunctionType(String)

        var errorDescription: String? {
            switch self {
            case let .invalidManifest(reason): "Invalid Bokeh manifest: \(reason)"
            case let .missingFunction(name): "Required Bokeh entry point is missing: \(name)"
            case let .wrongFunctionType(name): "Bokeh entry point has the wrong function type: \(name)"
            }
        }
    }
}
