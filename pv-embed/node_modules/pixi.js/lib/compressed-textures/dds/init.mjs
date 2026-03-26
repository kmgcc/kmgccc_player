import { extensions } from '../../extensions/Extensions.mjs';
import { detectCompressed } from '../shared/detectCompressed.mjs';
import { resolveCompressedTextureUrl } from '../shared/resolveCompressedTextureUrl.mjs';
import { loadDDS } from './loadDDS.mjs';

"use strict";
extensions.add(loadDDS, detectCompressed, resolveCompressedTextureUrl);
//# sourceMappingURL=init.mjs.map
