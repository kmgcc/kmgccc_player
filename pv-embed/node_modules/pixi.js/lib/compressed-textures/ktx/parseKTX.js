'use strict';

var _const = require('../ktx2/const.js');

"use strict";
function parseKTX(arrayBuffer, supportedFormats) {
  const dataView = new DataView(arrayBuffer);
  if (!validate(dataView)) {
    throw new Error("Invalid KTX identifier in header");
  }
  const {
    littleEndian,
    glType,
    glFormat,
    glInternalFormat,
    pixelWidth,
    pixelHeight,
    numberOfMipmapLevels,
    offset
  } = parseKTXHeader(dataView);
  const textureFormat = _const.KTX.INTERNAL_FORMAT_TO_TEXTURE_FORMATS[glInternalFormat];
  if (!textureFormat) {
    throw new Error(`Unknown texture format ${glInternalFormat}`);
  }
  if (!supportedFormats.includes(textureFormat)) {
    throw new Error(`Unsupported texture format: ${textureFormat}, supportedFormats: ${supportedFormats}`);
  }
  const imagePixelByteSize = getImagePixelByteSize(glType, glFormat, glInternalFormat);
  const imageBuffers = getImageBuffers(
    dataView,
    glType,
    imagePixelByteSize,
    pixelWidth,
    pixelHeight,
    offset,
    numberOfMipmapLevels,
    littleEndian
  );
  return {
    format: textureFormat,
    width: pixelWidth,
    height: pixelHeight,
    resource: imageBuffers,
    alphaMode: "no-premultiply-alpha"
  };
}
function getImageBuffers(dataView, glType, imagePixelByteSize, pixelWidth, pixelHeight, offset, numberOfMipmapLevels, littleEndian) {
  const alignedWidth = pixelWidth + 3 & ~3;
  const alignedHeight = pixelHeight + 3 & ~3;
  let imagePixels = pixelWidth * pixelHeight;
  if (glType === 0) {
    imagePixels = alignedWidth * alignedHeight;
  }
  let mipByteSize = imagePixels * imagePixelByteSize;
  let mipWidth = pixelWidth;
  let mipHeight = pixelHeight;
  let alignedMipWidth = alignedWidth;
  let alignedMipHeight = alignedHeight;
  let imageOffset = offset;
  const imageBuffers = new Array(numberOfMipmapLevels);
  for (let mipmapLevel = 0; mipmapLevel < numberOfMipmapLevels; mipmapLevel++) {
    const imageSize = dataView.getUint32(imageOffset, littleEndian);
    let elementOffset = imageOffset + 4;
    imageBuffers[mipmapLevel] = new Uint8Array(dataView.buffer, elementOffset, mipByteSize);
    elementOffset += mipByteSize;
    imageOffset += imageSize + 4;
    imageOffset = imageOffset % 4 !== 0 ? imageOffset + 4 - imageOffset % 4 : imageOffset;
    mipWidth = mipWidth >> 1 || 1;
    mipHeight = mipHeight >> 1 || 1;
    alignedMipWidth = mipWidth + 4 - 1 & ~(4 - 1);
    alignedMipHeight = mipHeight + 4 - 1 & ~(4 - 1);
    mipByteSize = alignedMipWidth * alignedMipHeight * imagePixelByteSize;
  }
  return imageBuffers;
}
function getImagePixelByteSize(glType, glFormat, glInternalFormat) {
  let imagePixelByteSize = _const.KTX.INTERNAL_FORMAT_TO_BYTES_PER_PIXEL[glInternalFormat];
  if (glType !== 0) {
    if (_const.KTX.TYPES_TO_BYTES_PER_COMPONENT[glType]) {
      imagePixelByteSize = _const.KTX.TYPES_TO_BYTES_PER_COMPONENT[glType] * _const.KTX.FORMATS_TO_COMPONENTS[glFormat];
    } else {
      imagePixelByteSize = _const.KTX.TYPES_TO_BYTES_PER_PIXEL[glType];
    }
  }
  if (imagePixelByteSize === void 0) {
    throw new Error("Unable to resolve the pixel format stored in the *.ktx file!");
  }
  return imagePixelByteSize;
}
function parseKTXHeader(dataView) {
  const littleEndian = dataView.getUint32(_const.KTX.FIELDS.ENDIANNESS, true) === _const.KTX.ENDIANNESS;
  const glType = dataView.getUint32(_const.KTX.FIELDS.GL_TYPE, littleEndian);
  const glFormat = dataView.getUint32(_const.KTX.FIELDS.GL_FORMAT, littleEndian);
  const glInternalFormat = dataView.getUint32(_const.KTX.FIELDS.GL_INTERNAL_FORMAT, littleEndian);
  const pixelWidth = dataView.getUint32(_const.KTX.FIELDS.PIXEL_WIDTH, littleEndian);
  const pixelHeight = dataView.getUint32(_const.KTX.FIELDS.PIXEL_HEIGHT, littleEndian) || 1;
  const pixelDepth = dataView.getUint32(_const.KTX.FIELDS.PIXEL_DEPTH, littleEndian) || 1;
  const numberOfArrayElements = dataView.getUint32(_const.KTX.FIELDS.NUMBER_OF_ARRAY_ELEMENTS, littleEndian) || 1;
  const numberOfFaces = dataView.getUint32(_const.KTX.FIELDS.NUMBER_OF_FACES, littleEndian);
  const numberOfMipmapLevels = dataView.getUint32(_const.KTX.FIELDS.NUMBER_OF_MIPMAP_LEVELS, littleEndian);
  const bytesOfKeyValueData = dataView.getUint32(_const.KTX.FIELDS.BYTES_OF_KEY_VALUE_DATA, littleEndian);
  if (pixelHeight === 0 || pixelDepth !== 1) {
    throw new Error("Only 2D textures are supported");
  }
  if (numberOfFaces !== 1) {
    throw new Error("CubeTextures are not supported by KTXLoader yet!");
  }
  if (numberOfArrayElements !== 1) {
    throw new Error("WebGL does not support array textures");
  }
  return {
    littleEndian,
    glType,
    glFormat,
    glInternalFormat,
    pixelWidth,
    pixelHeight,
    numberOfMipmapLevels,
    offset: _const.KTX.FILE_HEADER_SIZE + bytesOfKeyValueData
  };
}
function validate(dataView) {
  for (let i = 0; i < _const.KTX.FILE_IDENTIFIER.length; i++) {
    if (dataView.getUint8(i) !== _const.KTX.FILE_IDENTIFIER[i]) {
      return false;
    }
  }
  return true;
}

exports.parseKTX = parseKTX;
//# sourceMappingURL=parseKTX.js.map
