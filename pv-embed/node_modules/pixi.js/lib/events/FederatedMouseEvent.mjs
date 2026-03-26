import { Point } from '../maths/point/Point.mjs';
import { FederatedEvent } from './FederatedEvent.mjs';

"use strict";
class FederatedMouseEvent extends FederatedEvent {
  constructor() {
    super(...arguments);
    /** The coordinates of the mouse event relative to the canvas. */
    this.client = new Point();
    /** The movement in this pointer relative to the last `mousemove` event. */
    this.movement = new Point();
    /** The offset of the pointer coordinates w.r.t. target Container in world space. This is not supported at the moment. */
    this.offset = new Point();
    /** The pointer coordinates in world space. */
    this.global = new Point();
    /**
     * The pointer coordinates in the renderer's {@link AbstractRenderer.screen screen}. This has slightly
     * different semantics than native PointerEvent screenX/screenY.
     */
    this.screen = new Point();
  }
  /** @readonly */
  get clientX() {
    return this.client.x;
  }
  /** @readonly */
  get clientY() {
    return this.client.y;
  }
  /**
   * Alias for {@link FederatedMouseEvent.clientX this.clientX}.
   * @readonly
   */
  get x() {
    return this.clientX;
  }
  /**
   * Alias for {@link FederatedMouseEvent.clientY this.clientY}.
   * @readonly
   */
  get y() {
    return this.clientY;
  }
  /** @readonly */
  get movementX() {
    return this.movement.x;
  }
  /** @readonly */
  get movementY() {
    return this.movement.y;
  }
  /** @readonly */
  get offsetX() {
    return this.offset.x;
  }
  /** @readonly */
  get offsetY() {
    return this.offset.y;
  }
  /** @readonly */
  get globalX() {
    return this.global.x;
  }
  /** @readonly */
  get globalY() {
    return this.global.y;
  }
  /**
   * The pointer coordinates in the renderer's screen. Alias for `screen.x`.
   * @readonly
   */
  get screenX() {
    return this.screen.x;
  }
  /**
   * The pointer coordinates in the renderer's screen. Alias for `screen.y`.
   * @readonly
   */
  get screenY() {
    return this.screen.y;
  }
  /**
   * Converts global coordinates into container-local coordinates.
   *
   * This method transforms coordinates from world space to a container's local space,
   * useful for precise positioning and hit testing.
   * @param container - The Container to get local coordinates for
   * @param point - Optional Point object to store the result. If not provided, a new Point will be created
   * @param globalPos - Optional custom global coordinates. If not provided, the event's global position is used
   * @returns The local coordinates as a Point object
   * @example
   * ```ts
   * // Basic usage - get local coordinates relative to a container
   * sprite.on('pointermove', (event: FederatedMouseEvent) => {
   *     // Get position relative to the sprite
   *     const localPos = event.getLocalPosition(sprite);
   *     console.log('Local position:', localPos.x, localPos.y);
   * });
   * // Using custom global coordinates
   * const customGlobal = new Point(100, 100);
   * sprite.on('pointermove', (event: FederatedMouseEvent) => {
   *     // Transform custom coordinates
   *     const localPos = event.getLocalPosition(sprite, undefined, customGlobal);
   *     console.log('Custom local position:', localPos.x, localPos.y);
   * });
   * ```
   * @see {@link Container.worldTransform} For the transformation matrix
   * @see {@link Point} For the point class used to store coordinates
   */
  getLocalPosition(container, point, globalPos) {
    return container.worldTransform.applyInverse(globalPos || this.global, point);
  }
  /**
   * Whether the modifier key was pressed when this event natively occurred.
   * @param key - The modifier key.
   */
  getModifierState(key) {
    return "getModifierState" in this.nativeEvent && this.nativeEvent.getModifierState(key);
  }
  /**
   * Not supported.
   * @param _typeArg
   * @param _canBubbleArg
   * @param _cancelableArg
   * @param _viewArg
   * @param _detailArg
   * @param _screenXArg
   * @param _screenYArg
   * @param _clientXArg
   * @param _clientYArg
   * @param _ctrlKeyArg
   * @param _altKeyArg
   * @param _shiftKeyArg
   * @param _metaKeyArg
   * @param _buttonArg
   * @param _relatedTargetArg
   * @deprecated since 7.0.0
   * @ignore
   */
  // eslint-disable-next-line max-params
  initMouseEvent(_typeArg, _canBubbleArg, _cancelableArg, _viewArg, _detailArg, _screenXArg, _screenYArg, _clientXArg, _clientYArg, _ctrlKeyArg, _altKeyArg, _shiftKeyArg, _metaKeyArg, _buttonArg, _relatedTargetArg) {
    throw new Error("Method not implemented.");
  }
}

export { FederatedMouseEvent };
//# sourceMappingURL=FederatedMouseEvent.mjs.map
