import { extensions } from '../extensions/Extensions.mjs';
import { AlphaMask } from './mask/alpha/AlphaMask.mjs';
import { ColorMask } from './mask/color/ColorMask.mjs';
import { StencilMask } from './mask/stencil/StencilMask.mjs';
import { BufferImageSource } from './renderers/shared/texture/sources/BufferImageSource.mjs';
import { CanvasSource } from './renderers/shared/texture/sources/CanvasSource.mjs';
import { ImageSource } from './renderers/shared/texture/sources/ImageSource.mjs';
import { VideoSource } from './renderers/shared/texture/sources/VideoSource.mjs';
import './renderers/shared/texture/utils/textureFrom.mjs';
import './mask/MaskEffectManager.mjs';

"use strict";
extensions.add(AlphaMask, ColorMask, StencilMask, VideoSource, ImageSource, CanvasSource, BufferImageSource);
//# sourceMappingURL=init.mjs.map
