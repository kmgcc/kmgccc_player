import { extensions } from '../../extensions/Extensions.mjs';
import { detectCompressed } from '../shared/detectCompressed.mjs';
import { resolveCompressedTextureUrl } from '../shared/resolveCompressedTextureUrl.mjs';
import { loadKTX } from './loadKTX.mjs';

"use strict";
extensions.add(loadKTX);
extensions.add(resolveCompressedTextureUrl);
extensions.add(detectCompressed);
//# sourceMappingURL=init.mjs.map
