import { ExtensionType } from '../../../extensions/Extensions';
import { LoaderParserPriority } from './LoaderParser';
/**
 * A simple loader plugin for loading json data
 * @category assets
 * @advanced
 */
export declare const loadJson: {
    extension: {
        type: ExtensionType.LoadParser;
        priority: LoaderParserPriority;
    };
    /** used for deprecation purposes */
    name: string;
    id: string;
    test(url: string): boolean;
    load<T>(url: string): Promise<T>;
};
