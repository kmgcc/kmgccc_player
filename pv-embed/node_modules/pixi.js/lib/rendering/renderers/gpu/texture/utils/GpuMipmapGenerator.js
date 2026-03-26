'use strict';

"use strict";
class GpuMipmapGenerator {
  constructor(device) {
    this.device = device;
    this.sampler = device.createSampler({ minFilter: "linear" });
    this.pipelines = {};
  }
  _getMipmapPipeline(format) {
    let pipeline = this.pipelines[format];
    if (!pipeline) {
      if (!this.mipmapShaderModule) {
        this.mipmapShaderModule = this.device.createShaderModule({
          code: (
            /* wgsl */
            `
                        var<private> pos : array<vec2<f32>, 3> = array<vec2<f32>, 3>(
                        vec2<f32>(-1.0, -1.0), vec2<f32>(-1.0, 3.0), vec2<f32>(3.0, -1.0));

                        struct VertexOutput {
                        @builtin(position) position : vec4<f32>,
                        @location(0) texCoord : vec2<f32>,
                        };

                        @vertex
                        fn vertexMain(@builtin(vertex_index) vertexIndex : u32) -> VertexOutput {
                        var output : VertexOutput;
                        output.texCoord = pos[vertexIndex] * vec2<f32>(0.5, -0.5) + vec2<f32>(0.5);
                        output.position = vec4<f32>(pos[vertexIndex], 0.0, 1.0);
                        return output;
                        }

                        @group(0) @binding(0) var imgSampler : sampler;
                        @group(0) @binding(1) var img : texture_2d<f32>;

                        @fragment
                        fn fragmentMain(@location(0) texCoord : vec2<f32>) -> @location(0) vec4<f32> {
                        return textureSample(img, imgSampler, texCoord);
                        }
                    `
          )
        });
      }
      pipeline = this.device.createRenderPipeline({
        layout: "auto",
        vertex: {
          module: this.mipmapShaderModule,
          entryPoint: "vertexMain"
        },
        fragment: {
          module: this.mipmapShaderModule,
          entryPoint: "fragmentMain",
          targets: [{ format }]
        }
      });
      this.pipelines[format] = pipeline;
    }
    return pipeline;
  }
  /**
   * Generates mipmaps for the given GPUTexture from the data in level 0.
   * @param {module:External.GPUTexture} texture - Texture to generate mipmaps for.
   * @returns {module:External.GPUTexture} - The originally passed texture
   */
  generateMipmap(texture) {
    const pipeline = this._getMipmapPipeline(texture.format);
    if (texture.dimension === "3d" || texture.dimension === "1d") {
      throw new Error("Generating mipmaps for non-2d textures is currently unsupported!");
    }
    let mipTexture = texture;
    const arrayLayerCount = texture.depthOrArrayLayers || 1;
    const renderToSource = texture.usage & GPUTextureUsage.RENDER_ATTACHMENT;
    if (!renderToSource) {
      const mipTextureDescriptor = {
        size: {
          width: Math.ceil(texture.width / 2),
          height: Math.ceil(texture.height / 2),
          depthOrArrayLayers: arrayLayerCount
        },
        format: texture.format,
        usage: GPUTextureUsage.TEXTURE_BINDING | GPUTextureUsage.COPY_SRC | GPUTextureUsage.RENDER_ATTACHMENT,
        mipLevelCount: texture.mipLevelCount - 1
      };
      mipTexture = this.device.createTexture(mipTextureDescriptor);
    }
    const commandEncoder = this.device.createCommandEncoder({});
    const bindGroupLayout = pipeline.getBindGroupLayout(0);
    for (let arrayLayer = 0; arrayLayer < arrayLayerCount; ++arrayLayer) {
      let srcView = texture.createView({
        baseMipLevel: 0,
        mipLevelCount: 1,
        dimension: "2d",
        baseArrayLayer: arrayLayer,
        arrayLayerCount: 1
      });
      let dstMipLevel = renderToSource ? 1 : 0;
      for (let i = 1; i < texture.mipLevelCount; ++i) {
        const dstView = mipTexture.createView({
          baseMipLevel: dstMipLevel++,
          mipLevelCount: 1,
          dimension: "2d",
          baseArrayLayer: arrayLayer,
          arrayLayerCount: 1
        });
        const passEncoder = commandEncoder.beginRenderPass({
          colorAttachments: [{
            view: dstView,
            storeOp: "store",
            loadOp: "clear",
            clearValue: { r: 0, g: 0, b: 0, a: 0 }
          }]
        });
        const bindGroup = this.device.createBindGroup({
          layout: bindGroupLayout,
          entries: [{
            binding: 0,
            resource: this.sampler
          }, {
            binding: 1,
            resource: srcView
          }]
        });
        passEncoder.setPipeline(pipeline);
        passEncoder.setBindGroup(0, bindGroup);
        passEncoder.draw(3, 1, 0, 0);
        passEncoder.end();
        srcView = dstView;
      }
    }
    if (!renderToSource) {
      const mipLevelSize = {
        width: Math.ceil(texture.width / 2),
        height: Math.ceil(texture.height / 2),
        depthOrArrayLayers: arrayLayerCount
      };
      for (let i = 1; i < texture.mipLevelCount; ++i) {
        commandEncoder.copyTextureToTexture({
          texture: mipTexture,
          mipLevel: i - 1
        }, {
          texture,
          mipLevel: i
        }, mipLevelSize);
        mipLevelSize.width = Math.ceil(mipLevelSize.width / 2);
        mipLevelSize.height = Math.ceil(mipLevelSize.height / 2);
      }
    }
    this.device.queue.submit([commandEncoder.finish()]);
    if (!renderToSource) {
      mipTexture.destroy();
    }
    return texture;
  }
}

exports.GpuMipmapGenerator = GpuMipmapGenerator;
//# sourceMappingURL=GpuMipmapGenerator.js.map
