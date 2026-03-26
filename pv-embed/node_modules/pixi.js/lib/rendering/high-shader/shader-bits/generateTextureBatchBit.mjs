"use strict";
const textureBatchBitGpuCache = {};
function generateBindingSrc(maxTextures) {
  const src = [];
  if (maxTextures === 1) {
    src.push("@group(1) @binding(0) var textureSource1: texture_2d<f32>;");
    src.push("@group(1) @binding(1) var textureSampler1: sampler;");
  } else {
    let bindingIndex = 0;
    for (let i = 0; i < maxTextures; i++) {
      src.push(`@group(1) @binding(${bindingIndex++}) var textureSource${i + 1}: texture_2d<f32>;`);
      src.push(`@group(1) @binding(${bindingIndex++}) var textureSampler${i + 1}: sampler;`);
    }
  }
  return src.join("\n");
}
function generateSampleSrc(maxTextures) {
  const src = [];
  if (maxTextures === 1) {
    src.push("outColor = textureSampleGrad(textureSource1, textureSampler1, vUV, uvDx, uvDy);");
  } else {
    src.push("switch vTextureId {");
    for (let i = 0; i < maxTextures; i++) {
      if (i === maxTextures - 1) {
        src.push(`  default:{`);
      } else {
        src.push(`  case ${i}:{`);
      }
      src.push(`      outColor = textureSampleGrad(textureSource${i + 1}, textureSampler${i + 1}, vUV, uvDx, uvDy);`);
      src.push(`      break;}`);
    }
    src.push(`}`);
  }
  return src.join("\n");
}
function generateTextureBatchBit(maxTextures) {
  if (!textureBatchBitGpuCache[maxTextures]) {
    textureBatchBitGpuCache[maxTextures] = {
      name: "texture-batch-bit",
      vertex: {
        header: `
                @in aTextureIdAndRound: vec2<u32>;
                @out @interpolate(flat) vTextureId : u32;
            `,
        main: `
                vTextureId = aTextureIdAndRound.y;
            `,
        end: `
                if(aTextureIdAndRound.x == 1)
                {
                    vPosition = vec4<f32>(roundPixels(vPosition.xy, globalUniforms.uResolution), vPosition.zw);
                }
            `
      },
      fragment: {
        header: `
                @in @interpolate(flat) vTextureId: u32;

                ${generateBindingSrc(maxTextures)}
            `,
        main: `
                var uvDx = dpdx(vUV);
                var uvDy = dpdy(vUV);

                ${generateSampleSrc(maxTextures)}
            `
      }
    };
  }
  return textureBatchBitGpuCache[maxTextures];
}
const textureBatchBitGlCache = {};
function generateSampleGlSrc(maxTextures) {
  const src = [];
  for (let i = 0; i < maxTextures; i++) {
    if (i > 0) {
      src.push("else");
    }
    if (i < maxTextures - 1) {
      src.push(`if(vTextureId < ${i}.5)`);
    }
    src.push("{");
    src.push(`	outColor = texture(uTextures[${i}], vUV);`);
    src.push("}");
  }
  return src.join("\n");
}
function generateTextureBatchBitGl(maxTextures) {
  if (!textureBatchBitGlCache[maxTextures]) {
    textureBatchBitGlCache[maxTextures] = {
      name: "texture-batch-bit",
      vertex: {
        header: `
                in vec2 aTextureIdAndRound;
                out float vTextureId;

            `,
        main: `
                vTextureId = aTextureIdAndRound.y;
            `,
        end: `
                if(aTextureIdAndRound.x == 1.)
                {
                    gl_Position.xy = roundPixels(gl_Position.xy, uResolution);
                }
            `
      },
      fragment: {
        header: `
                in float vTextureId;

                uniform sampler2D uTextures[${maxTextures}];

            `,
        main: `

                ${generateSampleGlSrc(maxTextures)}
            `
      }
    };
  }
  return textureBatchBitGlCache[maxTextures];
}

export { generateTextureBatchBit, generateTextureBatchBitGl };
//# sourceMappingURL=generateTextureBatchBit.mjs.map
