//
//  BokehTransitionMetalContext.swift
//  myPlayer2
//

import Metal
import MetalKit
import os

/// Process-wide immutable Metal state. Surfaces own their textures; this type
/// deliberately owns only the device, queue and compiled pipelines.
@MainActor
final class BokehTransitionMetalContext {
    enum Availability: Equatable {
        case ready
        case unavailable(String)
    }

    static let shared = BokehTransitionMetalContext()

    let availability: Availability
    let device: MTLDevice?
    let commandQueue: MTLCommandQueue?
    let composePipeline: MTLComputePipelineState?
    let gatherPipeline: MTLComputePipelineState?
    let presentPipeline: MTLRenderPipelineState?

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
            return
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            availability = .unavailable("No Metal device")
            self.device = nil
            commandQueue = nil
            composePipeline = nil
            gatherPipeline = nil
            presentPipeline = nil
            return
        }
        guard let commandQueue = device.makeCommandQueue() else {
            availability = .unavailable("Unable to create Metal command queue")
            self.device = device
            self.commandQueue = nil
            composePipeline = nil
            gatherPipeline = nil
            presentPipeline = nil
            return
        }
        guard let library = device.makeDefaultLibrary() else {
            availability = .unavailable("Bokeh Metal library is unavailable")
            self.device = device
            self.commandQueue = commandQueue
            composePipeline = nil
            gatherPipeline = nil
            presentPipeline = nil
            return
        }

        do {
            guard let composeFunction = library.makeFunction(name: "composeTransition"),
                  let gatherFunction = library.makeFunction(name: "basicBokehGather"),
                  let vertexFunction = library.makeFunction(name: "presentTransitionVertex"),
                  let fragmentFunction = library.makeFunction(name: "presentTransitionFragment") else {
                throw BokehTransitionMetalError.missingFunction
            }

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
            availability = .ready
            logger.debug("Bokeh Metal pipelines warmed")
        } catch {
            availability = .unavailable("Metal pipeline creation failed: \(error.localizedDescription)")
            self.device = device
            self.commandQueue = commandQueue
            composePipeline = nil
            gatherPipeline = nil
            presentPipeline = nil
            logger.error("Bokeh Metal initialization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private enum BokehTransitionMetalError: LocalizedError {
        case missingFunction

        var errorDescription: String? {
            switch self {
            case .missingFunction: "Required Bokeh shader entry point is missing"
            }
        }
    }
}
