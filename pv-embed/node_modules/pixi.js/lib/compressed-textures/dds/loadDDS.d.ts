import { LoaderParserPriority } from '../../assets/loader/parsers/LoaderParser';
import { ExtensionType } from '../../extensions/Extensions';
import type { Loader } from '../../assets/loader/Loader';
import type { ResolvedAsset } from '../../assets/types';
import type { Texture } from '../../rendering/renderers/shared/texture/Texture';
/**
 * Loads DDS textures.
 * @category assets
 * @advanced
 */
export declare const loadDDS: {
    extension: {
        type: ExtensionType.LoadParser;
        priority: LoaderParserPriority;
        name: string;
    };
    /** used for deprecation purposes */
    name: string;
    id: string;
    test(url: string): boolean;
    load<T>(url: string, asset: ResolvedAsset, loader: Loader): Promise<Texture | Texture[]>;
    unload(texture: Texture | Texture[]): void;
};
