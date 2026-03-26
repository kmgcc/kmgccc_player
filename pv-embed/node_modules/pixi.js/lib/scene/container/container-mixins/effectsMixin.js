'use strict';

var FilterEffect = require('../../../filters/FilterEffect.js');
var MaskEffectManager = require('../../../rendering/mask/MaskEffectManager.js');

"use strict";
const effectsMixin = {
  _maskEffect: null,
  _maskOptions: {
    inverse: false
  },
  _filterEffect: null,
  effects: [],
  _markStructureAsChanged() {
    const renderGroup = this.renderGroup || this.parentRenderGroup;
    if (renderGroup) {
      renderGroup.structureDidChange = true;
    }
  },
  addEffect(effect) {
    const index = this.effects.indexOf(effect);
    if (index !== -1) return;
    this.effects.push(effect);
    this.effects.sort((a, b) => a.priority - b.priority);
    this._markStructureAsChanged();
    this._updateIsSimple();
  },
  removeEffect(effect) {
    const index = this.effects.indexOf(effect);
    if (index === -1) return;
    this.effects.splice(index, 1);
    this._markStructureAsChanged();
    this._updateIsSimple();
  },
  set mask(value) {
    const effect = this._maskEffect;
    if (effect?.mask === value) return;
    if (effect) {
      this.removeEffect(effect);
      MaskEffectManager.MaskEffectManager.returnMaskEffect(effect);
      this._maskEffect = null;
    }
    if (value === null || value === void 0) return;
    this._maskEffect = MaskEffectManager.MaskEffectManager.getMaskEffect(value);
    this.addEffect(this._maskEffect);
  },
  get mask() {
    return this._maskEffect?.mask;
  },
  setMask(options) {
    this._maskOptions = {
      ...this._maskOptions,
      ...options
    };
    if (options.mask) {
      this.mask = options.mask;
    }
    this._markStructureAsChanged();
  },
  set filters(value) {
    if (!Array.isArray(value) && value) value = [value];
    const effect = this._filterEffect || (this._filterEffect = new FilterEffect.FilterEffect());
    value = value;
    const hasFilters = value?.length > 0;
    const hadFilters = effect.filters?.length > 0;
    const didChange = hasFilters !== hadFilters;
    value = Array.isArray(value) ? value.slice(0) : value;
    effect.filters = Object.freeze(value);
    if (didChange) {
      if (hasFilters) {
        this.addEffect(effect);
      } else {
        this.removeEffect(effect);
        effect.filters = value ?? null;
      }
    }
  },
  get filters() {
    return this._filterEffect?.filters;
  },
  set filterArea(value) {
    this._filterEffect || (this._filterEffect = new FilterEffect.FilterEffect());
    this._filterEffect.filterArea = value;
  },
  get filterArea() {
    return this._filterEffect?.filterArea;
  }
};

exports.effectsMixin = effectsMixin;
//# sourceMappingURL=effectsMixin.js.map
