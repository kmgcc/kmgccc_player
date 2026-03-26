import { extensions } from '../../extensions/Extensions.mjs';
import { detectCompressed } from '../shared/detectCompressed.mjs';
import { resolveCompressedTextureUrl } from '../shared/resolveCompressedTextureUrl.mjs';
import { loadKTX2 } from './loadKTX2.mjs';

"use strict";
extensions.add(loadKTX2);
extensions.add(resolveCompressedTextureUrl);
extensions.add(detectCompressed);
//# sourceMappingURL=init.mjs.map
