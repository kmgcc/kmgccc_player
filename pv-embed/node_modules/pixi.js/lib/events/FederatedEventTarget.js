'use strict';

var EventSystem = require('./EventSystem.js');
var FederatedEvent = require('./FederatedEvent.js');

"use strict";
const FederatedContainer = {
  onclick: null,
  onmousedown: null,
  onmouseenter: null,
  onmouseleave: null,
  onmousemove: null,
  onglobalmousemove: null,
  onmouseout: null,
  onmouseover: null,
  onmouseup: null,
  onmouseupoutside: null,
  onpointercancel: null,
  onpointerdown: null,
  onpointerenter: null,
  onpointerleave: null,
  onpointermove: null,
  onglobalpointermove: null,
  onpointerout: null,
  onpointerover: null,
  onpointertap: null,
  onpointerup: null,
  onpointerupoutside: null,
  onrightclick: null,
  onrightdown: null,
  onrightup: null,
  onrightupoutside: null,
  ontap: null,
  ontouchcancel: null,
  ontouchend: null,
  ontouchendoutside: null,
  ontouchmove: null,
  onglobaltouchmove: null,
  ontouchstart: null,
  onwheel: null,
  get interactive() {
    return this.eventMode === "dynamic" || this.eventMode === "static";
  },
  set interactive(value) {
    this.eventMode = value ? "static" : "passive";
  },
  _internalEventMode: void 0,
  get eventMode() {
    return this._internalEventMode ?? EventSystem.EventSystem.defaultEventMode;
  },
  set eventMode(value) {
    this._internalEventMode = value;
  },
  isInteractive() {
    return this.eventMode === "static" || this.eventMode === "dynamic";
  },
  interactiveChildren: true,
  hitArea: null,
  addEventListener(type, listener, options) {
    const capture = typeof options === "boolean" && options || typeof options === "object" && options.capture;
    const signal = typeof options === "object" ? options.signal : void 0;
    const once = typeof options === "object" ? options.once === true : false;
    const context = typeof listener === "function" ? void 0 : listener;
    type = capture ? `${type}capture` : type;
    const listenerFn = typeof listener === "function" ? listener : listener.handleEvent;
    const emitter = this;
    if (signal) {
      signal.addEventListener("abort", () => {
        emitter.off(type, listenerFn, context);
      });
    }
    if (once) {
      emitter.once(type, listenerFn, context);
    } else {
      emitter.on(type, listenerFn, context);
    }
  },
  removeEventListener(type, listener, options) {
    const capture = typeof options === "boolean" && options || typeof options === "object" && options.capture;
    const context = typeof listener === "function" ? void 0 : listener;
    type = capture ? `${type}capture` : type;
    listener = typeof listener === "function" ? listener : listener.handleEvent;
    this.off(type, listener, context);
  },
  dispatchEvent(e) {
    if (!(e instanceof FederatedEvent.FederatedEvent)) {
      throw new Error("Container cannot propagate events outside of the Federated Events API");
    }
    e.defaultPrevented = false;
    e.path = null;
    e.target = this;
    e.manager.dispatchEvent(e);
    return !e.defaultPrevented;
  }
};

exports.FederatedContainer = FederatedContainer;
//# sourceMappingURL=FederatedEventTarget.js.map
