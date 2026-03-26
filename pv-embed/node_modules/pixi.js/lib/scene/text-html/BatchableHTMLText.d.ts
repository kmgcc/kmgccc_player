import { type Texture } from '../../rendering/renderers/shared/texture/Texture';
import { BatchableSprite } from '../sprite/BatchableSprite';
/**
 * The BatchableHTMLText class extends the BatchableSprite class and is used to handle HTML text rendering.
 * It includes a promise for the texture as generating the HTML texture takes some time.
 * @internal
 */
export declare class BatchableHTMLText extends BatchableSprite {
    texturePromise: Promise<Texture>;
    generatingTexture: boolean;
    currentKey: string;
    /** Destroys the BatchableHTMLText instance. Returns the texture promise to the renderer and cleans up references. */
    destroy(): void;
}
