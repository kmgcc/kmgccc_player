'use strict';

var Extensions = require('../extensions/Extensions.js');
var _const = require('../ticker/const.js');
var Ticker = require('../ticker/Ticker.js');

"use strict";
class TickerPlugin {
  /**
   * Initialize the plugin with scope of application instance
   * @private
   * @param {object} [options] - See application options
   */
  static init(options) {
    options = Object.assign({
      autoStart: true,
      sharedTicker: false
    }, options);
    Object.defineProperty(
      this,
      "ticker",
      {
        configurable: true,
        set(ticker) {
          if (this._ticker) {
            this._ticker.remove(this.render, this);
          }
          this._ticker = ticker;
          if (ticker) {
            ticker.add(this.render, this, _const.UPDATE_PRIORITY.LOW);
          }
        },
        get() {
          return this._ticker;
        }
      }
    );
    this.stop = () => {
      this._ticker.stop();
    };
    this.start = () => {
      this._ticker.start();
    };
    this._ticker = null;
    this.ticker = options.sharedTicker ? Ticker.Ticker.shared : new Ticker.Ticker();
    if (options.autoStart) {
      this.start();
    }
  }
  /**
   * Clean up the ticker, scoped to application.
   * @private
   */
  static destroy() {
    if (this._ticker) {
      const oldTicker = this._ticker;
      this.ticker = null;
      oldTicker.destroy();
    }
  }
}
/** @ignore */
TickerPlugin.extension = Extensions.ExtensionType.Application;

exports.TickerPlugin = TickerPlugin;
//# sourceMappingURL=TickerPlugin.js.map
