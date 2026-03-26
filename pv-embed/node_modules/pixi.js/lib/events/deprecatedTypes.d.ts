import type EventEmitter from 'eventemitter3';
import type { EventMode, FederatedOptions } from './FederatedEventTarget';
/**
 * A simplified shape of an interactive object for the `eventTarget` property of a {@link FederatedEvent}
 * @category events
 * @deprecated since 8.1.4
 * @internal
 */
export interface FederatedEventTarget extends EventEmitter, EventTarget, Required<FederatedOptions> {
    /** The parent of this event target. */
    readonly parent?: FederatedEventTarget;
    /** The children of this event target. */
    readonly children?: ReadonlyArray<FederatedEventTarget>;
    _internalEventMode: EventMode;
    /** Returns true if the Container has interactive 'static' or 'dynamic' */
    isInteractive: () => boolean;
    /** Remove all listeners, or those of the specified event. */
    removeAllListeners(event?: string | symbol): this;
}
