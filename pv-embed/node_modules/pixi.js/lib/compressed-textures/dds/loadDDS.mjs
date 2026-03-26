import { LoaderParserPriority } from '../../assets/loader/parsers/LoaderParser.mjs';
import { createTexture } from '../../assets/loader/parsers/textures/utils/createTexture.mjs';
import { checkExtension } from '../../assets/utils/checkExtension.mjs';
import { ExtensionType } from '../../extensions/Extensions.mjs';
import { CompressedSource } from '../../rendering/renderers/shared/texture/sources/CompressedSource.mjs';
import { getSupportedTextureFormats } from '../../rendering/renderers/shared/texture/utils/getSupportedTextureFormats.mjs';
import { getResolutionOfUrl } from '../../utils/network/getResolutionOfUrl.mjs';
import { parseDDS } from './parseDDS.mjs';

"use strict";
const loadDDS = {
  extension: {
    type: ExtensionType.LoadParser,
    priority: LoaderParserPriority.High,
    name: "loadDDS"
  },
  /** used for deprecation purposes */
  name: "loadDDS",
  id: "dds",
  test(url) {
    return checkExtension(url, [".dds"]);
  },
  async load(url, asset, loader) {
    const supportedTextures = await getSupportedTextureFormats();
    const ddsResponse = await fetch(url);
    const ddsArrayBuffer = await ddsResponse.arrayBuffer();
    const textureOptions = parseDDS(ddsArrayBuffer, supportedTextures);
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

export { loadDDS };
//# sourceMappingURL=loadDDS.mjs.map
