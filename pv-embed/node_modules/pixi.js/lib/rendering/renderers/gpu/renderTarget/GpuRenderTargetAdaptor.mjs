import { CLEAR } from '../../gl/const.mjs';
import { CanvasSource } from '../../shared/texture/sources/CanvasSource.mjs';
import { TextureSource } from '../../shared/texture/sources/TextureSource.mjs';
import { GpuRenderTarget } from './GpuRenderTarget.mjs';

"use strict";
class GpuRenderTargetAdaptor {
  init(renderer, renderTargetSystem) {
    this._renderer = renderer;
    this._renderTargetSystem = renderTargetSystem;
  }
  copyToTexture(sourceRenderSurfaceTexture, destinationTexture, originSrc, size, originDest) {
    const renderer = this._renderer;
    const baseGpuTexture = this._getGpuColorTexture(
      sourceRenderSurfaceTexture
    );
    const backGpuTexture = renderer.texture.getGpuSource(
      destinationTexture.source
    );
    renderer.encoder.commandEncoder.copyTextureToTexture(
      {
        texture: baseGpuTexture,
        origin: originSrc
      },
      {
        texture: backGpuTexture,
        origin: originDest
      },
      size
    );
    return destinationTexture;
  }
  startRenderPass(renderTarget, clear = true, clearColor, viewport, mipLevel = 0, layer = 0) {
    const renderTargetSystem = this._renderTargetSystem;
    const gpuRenderTarget = renderTargetSystem.getGpuRenderTarget(renderTarget);
    if (layer !== 0 && gpuRenderTarget.msaaTextures?.length) {
      throw new Error("[RenderTargetSystem] Rendering to array layers is not supported with MSAA render targets.");
    }
    if (mipLevel > 0 && gpuRenderTarget.msaaTextures?.length) {
      throw new Error("[RenderTargetSystem] Rendering to mip levels is not supported with MSAA render targets.");
    }
    const descriptor = this.getDescriptor(renderTarget, clear, clearColor, mipLevel, layer);
    gpuRenderTarget.descriptor = descriptor;
    this._renderer.pipeline.setRenderTarget(gpuRenderTarget);
    this._renderer.encoder.beginRenderPass(gpuRenderTarget);
    this._renderer.encoder.setViewport(viewport);
  }
  finishRenderPass() {
    this._renderer.encoder.endRenderPass();
  }
  /**
   * returns the gpu texture for the first color texture in the render target
   * mainly used by the filter manager to get copy the texture for blending
   * @param renderTarget
   * @returns a gpu texture
   */
  _getGpuColorTexture(renderTarget) {
    const gpuRenderTarget = this._renderTargetSystem.getGpuRenderTarget(renderTarget);
    if (gpuRenderTarget.contexts[0]) {
      return gpuRenderTarget.contexts[0].getCurrentTexture();
    }
    return this._renderer.texture.getGpuSource(
      renderTarget.colorTextures[0].source
    );
  }
  getDescriptor(renderTarget, clear, clearValue, mipLevel = 0, layer = 0) {
    if (typeof clear === "boolean") {
      clear = clear ? CLEAR.ALL : CLEAR.NONE;
    }
    const renderTargetSystem = this._renderTargetSystem;
    const gpuRenderTarget = renderTargetSystem.getGpuRenderTarget(renderTarget);
    const colorAttachments = renderTarget.colorTextures.map(
      (texture, i) => {
        const context = gpuRenderTarget.contexts[i];
        let view;
        let resolveTarget;
        if (context) {
          if (layer !== 0) {
            throw new Error("[RenderTargetSystem] Rendering to array layers is not supported for canvas targets.");
          }
          const currentTexture = context.getCurrentTexture();
          const canvasTextureView = currentTexture.createView();
          view = canvasTextureView;
        } else {
          view = this._renderer.texture.getGpuSource(texture).createView({
            // Render attachments must be 2d views; for array/cube textures we select a single layer.
            dimension: "2d",
            baseMipLevel: mipLevel,
            mipLevelCount: 1,
            baseArrayLayer: layer,
            arrayLayerCount: 1
          });
        }
        if (gpuRenderTarget.msaaTextures[i]) {
          resolveTarget = view;
          view = this._renderer.texture.getTextureView(
            gpuRenderTarget.msaaTextures[i]
          );
        }
        const loadOp = clear & CLEAR.COLOR ? "clear" : "load";
        clearValue ?? (clearValue = renderTargetSystem.defaultClearColor);
        return {
          view,
          resolveTarget,
          clearValue,
          storeOp: "store",
          loadOp
        };
      }
    );
    let depthStencilAttachment;
    if ((renderTarget.stencil || renderTarget.depth) && !renderTarget.depthStencilTexture) {
      renderTarget.ensureDepthStencilTexture();
      renderTarget.depthStencilTexture.source.sampleCount = gpuRenderTarget.msaa ? 4 : 1;
    }
    if (renderTarget.depthStencilTexture) {
      const stencilLoadOp = clear & CLEAR.STENCIL ? "clear" : "load";
      const depthLoadOp = clear & CLEAR.DEPTH ? "clear" : "load";
      depthStencilAttachment = {
        view: this._renderer.texture.getGpuSource(renderTarget.depthStencilTexture.source).createView({
          dimension: "2d",
          baseMipLevel: mipLevel,
          mipLevelCount: 1,
          baseArrayLayer: layer,
          arrayLayerCount: 1
        }),
        stencilStoreOp: "store",
        stencilLoadOp,
        depthClearValue: 1,
        depthLoadOp,
        depthStoreOp: "store"
      };
    }
    const descriptor = {
      colorAttachments,
      depthStencilAttachment
    };
    return descriptor;
  }
  clear(renderTarget, clear = true, clearColor, viewport, mipLevel = 0, layer = 0) {
    if (!clear) return;
    const { gpu, encoder } = this._renderer;
    const device = gpu.device;
    const standAlone = encoder.commandEncoder === null;
    if (standAlone) {
      const commandEncoder = device.createCommandEncoder();
      const renderPassDescriptor = this.getDescriptor(renderTarget, clear, clearColor, mipLevel, layer);
      const passEncoder = commandEncoder.beginRenderPass(renderPassDescriptor);
      passEncoder.setViewport(viewport.x, viewport.y, viewport.width, viewport.height, 0, 1);
      passEncoder.end();
      const gpuCommands = commandEncoder.finish();
      device.queue.submit([gpuCommands]);
    } else {
      this.startRenderPass(renderTarget, clear, clearColor, viewport, mipLevel, layer);
    }
  }
  initGpuRenderTarget(renderTarget) {
    renderTarget.isRoot = true;
    const gpuRenderTarget = new GpuRenderTarget();
    gpuRenderTarget.colorTargetCount = renderTarget.colorTextures.length;
    renderTarget.colorTextures.forEach((colorTexture, i) => {
      if (colorTexture instanceof CanvasSource) {
        const context = colorTexture.resource.getContext(
          "webgpu"
        );
        const alphaMode = colorTexture.transparent ? "premultiplied" : "opaque";
        try {
          context.configure({
            device: this._renderer.gpu.device,
            usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_DST | GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC,
            format: "bgra8unorm",
            alphaMode
          });
        } catch (e) {
          console.error(e);
        }
        gpuRenderTarget.contexts[i] = context;
      }
      gpuRenderTarget.msaa = colorTexture.source.antialias;
      if (colorTexture.source.antialias) {
        const msaaTexture = new TextureSource({
          width: 0,
          height: 0,
          sampleCount: 4,
          arrayLayerCount: colorTexture.source.arrayLayerCount
        });
        gpuRenderTarget.msaaTextures[i] = msaaTexture;
      }
    });
    if (gpuRenderTarget.msaa) {
      gpuRenderTarget.msaaSamples = 4;
      if (renderTarget.depthStencilTexture) {
        renderTarget.depthStencilTexture.source.sampleCount = 4;
      }
    }
    return gpuRenderTarget;
  }
  destroyGpuRenderTarget(gpuRenderTarget) {
    gpuRenderTarget.contexts.forEach((context) => {
      context.unconfigure();
    });
    gpuRenderTarget.msaaTextures.forEach((texture) => {
      texture.destroy();
    });
    gpuRenderTarget.msaaTextures.length = 0;
    gpuRenderTarget.contexts.length = 0;
  }
  ensureDepthStencilTexture(renderTarget) {
    const gpuRenderTarget = this._renderTargetSystem.getGpuRenderTarget(renderTarget);
    if (renderTarget.depthStencilTexture && gpuRenderTarget.msaa) {
      renderTarget.depthStencilTexture.source.sampleCount = 4;
    }
  }
  resizeGpuRenderTarget(renderTarget) {
    const gpuRenderTarget = this._renderTargetSystem.getGpuRenderTarget(renderTarget);
    gpuRenderTarget.width = renderTarget.width;
    gpuRenderTarget.height = renderTarget.height;
    if (gpuRenderTarget.msaa) {
      renderTarget.colorTextures.forEach((colorTexture, i) => {
        const msaaTexture = gpuRenderTarget.msaaTextures[i];
        msaaTexture?.resize(
          colorTexture.source.width,
          colorTexture.source.height,
          colorTexture.source._resolution
        );
      });
    }
  }
}

export { GpuRenderTargetAdaptor };
//# sourceMappingURL=GpuRenderTargetAdaptor.mjs.map
