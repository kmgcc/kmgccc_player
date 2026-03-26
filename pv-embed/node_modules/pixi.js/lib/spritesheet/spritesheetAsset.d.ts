import { LoaderParserPriority } from '../assets/loader/parsers/LoaderParser';
import { ExtensionType } from '../extensions/Extensions';
import { Texture } from '../rendering/renderers/shared/texture/Texture';
import { Spritesheet } from './Spritesheet';
import type { Loader } from '../assets/loader/Loader';
import type { ResolvedAsset } from '../assets/types';
import type { TextureSourceOptions } from '../rendering/renderers/shared/texture/sources/TextureSource';
import type { SpritesheetData } from './Spritesheet';
/**
 * Interface for the JSON data structure of a spritesheet.
 * This is used to define the structure of the JSON file that describes a spritesheet.
 * It includes metadata about the spritesheet and the frames it contains.
 * @see {@link Spritesheet}
 * @see {@link SpritesheetData}
 * @category assets
 * @advanced
 */
export interface SpriteSheetJson extends SpritesheetData {
    meta: {
        image: string;
        scale: string;
        related_multi_packs?: string[];
    };
}
/**
 * Asset extension for loading spritesheets
 * @example
 * import { Assets } from 'pixi.js';
 *
 * Assets.load({
 *     alias: 'spritesheet',
 *     src: 'path/to/spritesheet.json',
 *     data: {
 *         ignoreMultiPack: true,
 *         textureOptions: {
 *             scaleMode: "nearest"
 *         }
 *     }
 * })
 * @type {AssetExtension}
 * @category assets
 * @advanced
 */
export declare const spritesheetAsset: {
    extension: ExtensionType.Asset;
    /** Handle the caching of the related Spritesheet Textures */
    cache: {
        test: (asset: Spritesheet) => boolean;
        getCacheableAssets: (keys: string[], asset: Spritesheet) => Record<string, any>;
    };
    /** Resolve the resolution of the asset. */
    resolver: {
        extension: {
            type: ExtensionType.ResolveParser;
            name: string;
        };
        test: (value: string) => boolean;
        parse: (value: string) => {
            resolution: number;
            format: string;
            src: string;
        };
    };
    /**
     * Loader plugin that parses sprite sheets!
     * once the JSON has been loaded this checks to see if the JSON is spritesheet data.
     * If it is, we load the spritesheets image and parse the data into Spritesheet
     * All textures in the sprite sheet are then added to the cache
     */
    loader: {
        /** used for deprecation purposes */
        name: string;
        id: string;
        extension: {
            type: ExtensionType.LoadParser;
            priority: LoaderParserPriority;
            name: string;
        };
        testParse(asset: SpriteSheetJson, options: ResolvedAsset): Promise<boolean>;
        parse<T>(asset: SpriteSheetJson, options: ResolvedAsset<{
            texture?: Texture;
            imageFilename?: string;
            ignoreMultiPack?: boolean;
            textureOptions?: TextureSourceOptions;
            cachePrefix?: string;
        }>, loader?: Loader): Promise<Spritesheet>;
        unload(spritesheet: Spritesheet, _resolvedAsset: ResolvedAsset<any>, loader: Loader): Promise<void>;
    };
};
