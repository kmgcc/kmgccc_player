import { Matrix } from '../../../maths/matrix/Matrix';
import { Shader } from '../../../rendering/renderers/shared/shader/Shader';
import { Texture } from '../../../rendering/renderers/shared/texture/Texture';
/**
 * The shader used by the TilingSprite.
 * @internal
 */
export declare class TilingSpriteShader extends Shader {
    constructor();
    updateUniforms(width: number, height: number, matrix: Matrix, anchorX: number, anchorY: number, texture: Texture): void;
}
