import { deprecation, v8_0_0 } from '../../../utils/logging/deprecation.mjs';

"use strict";
const findMixin = {
  label: null,
  get name() {
    deprecation(v8_0_0, "Container.name property has been removed, use Container.label instead");
    return this.label;
  },
  set name(value) {
    deprecation(v8_0_0, "Container.name property has been removed, use Container.label instead");
    this.label = value;
  },
  getChildByName(name, deep = false) {
    return this.getChildByLabel(name, deep);
  },
  getChildByLabel(label, deep = false) {
    const children = this.children;
    for (let i = 0; i < children.length; i++) {
      const child = children[i];
      if (child.label === label || label instanceof RegExp && label.test(child.label)) return child;
    }
    if (deep) {
      for (let i = 0; i < children.length; i++) {
        const child = children[i];
        const found = child.getChildByLabel(label, true);
        if (found) {
          return found;
        }
      }
    }
    return null;
  },
  getChildrenByLabel(label, deep = false, out = []) {
    const children = this.children;
    for (let i = 0; i < children.length; i++) {
      const child = children[i];
      if (child.label === label || label instanceof RegExp && label.test(child.label)) {
        out.push(child);
      }
    }
    if (deep) {
      for (let i = 0; i < children.length; i++) {
        children[i].getChildrenByLabel(label, true, out);
      }
    }
    return out;
  }
};

export { findMixin };
//# sourceMappingURL=findMixin.mjs.map
