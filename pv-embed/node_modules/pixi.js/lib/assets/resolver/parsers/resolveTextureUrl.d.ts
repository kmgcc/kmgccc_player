import { ExtensionType } from '../../../extensions/Extensions';
/**
 * A parser that will resolve a texture url
 * @category assets
 * @internal
 */
export declare const resolveTextureUrl: {
    extension: {
        type: ExtensionType.ResolveParser;
        name: string;
    };
    test: (url: string, resolvedAsset?: import("../..").ResolvedAsset<import("../../..").TextureSourceOptions<any>>, loader?: import("../..").Loader) => boolean;
    parse: (value: string) => {
        resolution: number;
        format: string;
        src: string;
    };
};
