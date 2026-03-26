import { LoaderParserPriority } from '../../../assets/loader/parsers/LoaderParser';
import { ExtensionType } from '../../../extensions/Extensions';
import type { Loader } from '../../../assets/loader/Loader';
import type { ResolvedAsset } from '../../../assets/types';
import type { BitmapFont } from '../BitmapFont';
/**
 * simple loader plugin for loading in bitmap fonts!
 * @category assets
 * @internal
 */
export declare const bitmapFontCachePlugin: {
    extension: {
        type: ExtensionType.CacheParser;
        name: string;
    };
    test: (asset: BitmapFont) => boolean;
    getCacheableAssets(keys: string[], asset: BitmapFont): Record<string, BitmapFont>;
};
/**
 * Loader plugin for loading bitmap fonts.
 * It supports both XML and text formats, and can handle distance field fonts.
 * @category assets
 * @advanced
 */
export declare const loadBitmapFont: {
    extension: {
        type: ExtensionType.LoadParser;
        priority: LoaderParserPriority;
    };
    /** used for deprecation purposes */
    name: string;
    id: string;
    test(url: string): boolean;
    testParse(data: string): Promise<boolean>;
    parse<T>(asset: string, data: ResolvedAsset, loader: Loader): Promise<BitmapFont>;
    load<T>(url: string, _options: ResolvedAsset): Promise<string>;
    unload(bitmapFont: BitmapFont, _resolvedAsset: ResolvedAsset<any>, loader: Loader): Promise<void>;
};
