import { LoaderParserPriority } from '../../assets/loader/parsers/LoaderParser.mjs';
import { createTexture } from '../../assets/loader/parsers/textures/utils/createTexture.mjs';
import { checkExtension } from '../../assets/utils/checkExtension.mjs';
import { ExtensionType } from '../../extensions/Extensions.mjs';
import { CompressedSource } from '../../rendering/renderers/shared/texture/sources/CompressedSource.mjs';
import { getSupportedTextureFormats } from '../../rendering/renderers/shared/texture/utils/getSupportedTextureFormats.mjs';
import { getResolutionOfUrl } from '../../utils/network/getResolutionOfUrl.mjs';
import { parseKTX } from './parseKTX.mjs';

"use strict";
const loadKTX = {
  extension: {
    type: ExtensionType.LoadParser,
    priority: LoaderParserPriority.High,
    name: "loadKTX"
  },
  /** used for deprecation purposes */
  name: "loadKTX",
  id: "ktx",
  test(url) {
    return checkExtension(url, ".ktx");
  },
  async load(url, asset, loader) {
    const supportedTextures = await getSupportedTextureFormats();
    const ktxResponse = await fetch(url);
    const ktxArrayBuffer = await ktxResponse.arrayBuffer();
    const textureOptions = parseKTX(ktxArrayBuffer, supportedTextures);
    const compressedTextureSource = new CompressedSource({
      ...textureOptions,
      resolution: asset.data?.resolution || getResolutionOfUrl(url)
    });
    return createTexture(compressedTextureSource, loader, url);
  },
  unload(texture) {
    if (Array.isArray(texture)) {
      texture.forEach((t) => t.destroy(true));
    } else {
      texture.destroy(true);
    }
  }
};

export { loadKTX };
//# sourceMappingURL=loadKTX.mjs.map
