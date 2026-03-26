import { ExtensionType } from '../../../extensions/Extensions';
import { LoaderParserPriority } from './LoaderParser';
/**
 * A simple loader plugin for loading text data
 * @category assets
 * @advanced
 */
export declare const loadTxt: {
    /** used for deprecation purposes */
    name: string;
    id: string;
    extension: {
        type: ExtensionType.LoadParser;
        priority: LoaderParserPriority;
        name: string;
    };
    test(url: string): boolean;
    load<T>(url: string): Promise<string>;
};
