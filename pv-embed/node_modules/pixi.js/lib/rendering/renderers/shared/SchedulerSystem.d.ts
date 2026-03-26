import { ExtensionType } from '../../../extensions/Extensions';
import type { System } from './system/System';
/**
 * The SchedulerSystem manages scheduled tasks with specific intervals.
 * @category rendering
 * @advanced
 */
export declare class SchedulerSystem implements System<null> {
    /** @ignore */
    static extension: {
        readonly type: readonly [ExtensionType.WebGLSystem, ExtensionType.WebGPUSystem, ExtensionType.CanvasSystem];
        readonly name: "scheduler";
        readonly priority: 0;
    };
    private readonly _tasks;
    /** a small off set to apply to the repeat schedules. This is just to make sure they run at slightly different times */
    private _offset;
    /** Initializes the scheduler system and starts the ticker. */
    init(): void;
    /**
     * Schedules a repeating task.
     * @param func - The function to execute.
     * @param duration - The interval duration in milliseconds.
     * @param useOffset - this will spread out tasks so that they do not all run at the same time
     * @returns The unique identifier for the scheduled task.
     */
    repeat(func: (elapsed: number) => void, duration: number, useOffset?: boolean): number;
    /**
     * Cancels a scheduled task.
     * @param id - The unique identifier of the task to cancel.
     */
    cancel(id: number): void;
    /**
     * Updates and executes the scheduled tasks.
     * @private
     */
    private _update;
    /**
     * Destroys the scheduler system and removes all tasks.
     * @internal
     */
    destroy(): void;
}
