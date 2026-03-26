import { LoaderParserPriority } from '../../assets/loader/parsers/LoaderParser.mjs';
import { createTexture } from '../../assets/loader/parsers/textures/utils/createTexture.mjs';
import { checkExtension } from '../../assets/utils/checkExtension.mjs';
import { ExtensionType } from '../../extensions/Extensions.mjs';
import { CompressedSource } from '../../rendering/renderers/shared/texture/sources/CompressedSource.mjs';
import { getSupportedTextureFormats } from '../../rendering/renderers/shared/texture/utils/getSupportedTextureFormats.mjs';
import { getResolutionOfUrl } from '../../utils/network/getResolutionOfUrl.mjs';
import { loadBasisOnWorker } from './worker/loadBasisOnWorker.mjs';

"use strict";
const loadBasis = {
  extension: {
    type: ExtensionType.LoadParser,
    priority: LoaderParserPriority.High,
    name: "loadBasis"
  },
  /** used for deprecation purposes */
  name: "loadBasis",
  id: "basis",
  test(url) {
    return checkExtension(url, [".basis"]);
  },
  async load(url, asset, loader) {
    const supportedTextures = await getSupportedTextureFormats();
    const textureOptions = await loadBasisOnWorker(url, supportedTextures);
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

export { loadBasis };
//# sourceMappingURL=loadBasis.mjs.map
