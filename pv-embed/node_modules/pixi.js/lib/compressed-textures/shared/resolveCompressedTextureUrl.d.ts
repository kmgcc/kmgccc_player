import { ExtensionType } from '../../extensions/Extensions';
/** @internal */
export declare const validFormats: string[];
/**
 * A parser that will resolve a compressed texture url
 * @category assets
 * @internal
 */
export declare const resolveCompressedTextureUrl: {
    extension: ExtensionType.ResolveParser;
    test: (value: string) => boolean;
    parse: (value: string) => {
        resolution: number;
        format: string;
        src: string;
    };
};
