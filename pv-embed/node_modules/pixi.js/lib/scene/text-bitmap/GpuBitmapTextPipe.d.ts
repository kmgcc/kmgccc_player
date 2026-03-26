import { ExtensionType } from '../../extensions/Extensions';
import { SdfShader } from '../text/sdfShader/SdfShader';
import { AbstractBitmapTextPipe } from './AbstractBitmapTextPipe';
/** @internal */
export declare class BitmapTextPipe extends AbstractBitmapTextPipe {
    /** @ignore */
    static extension: {
        type: ExtensionType[];
        name: 'bitmapText';
    };
    protected getSdfShader(): SdfShader | null;
}
