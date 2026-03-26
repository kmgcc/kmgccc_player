import { ExtensionType } from '../../extensions/Extensions';
import { type SdfShader } from '../text/sdfShader/SdfShader';
import { AbstractBitmapTextPipe } from './AbstractBitmapTextPipe';
/** @internal */
export declare class CanvasBitmapTextPipe extends AbstractBitmapTextPipe {
    /** @ignore */
    static extension: {
        type: ExtensionType[];
        name: 'bitmapText';
    };
    protected getSdfShader(): SdfShader | null;
}
