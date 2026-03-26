'use strict';

"use strict";
function checkChildrenDidChange(container, previousData) {
  const children = container.children;
  for (let i = 0; i < children.length; i++) {
    const child = children[i];
    const uid = child.uid;
    const didChange = (child._didViewChangeTick & 65535) << 16 | child._didContainerChangeTick & 65535;
    const index = previousData.index;
    if (previousData.data[index] !== uid || previousData.data[index + 1] !== didChange) {
      previousData.data[previousData.index] = uid;
      previousData.data[previousData.index + 1] = didChange;
      previousData.didChange = true;
    }
    previousData.index = index + 2;
    if (child.children.length) {
      checkChildrenDidChange(child, previousData);
    }
  }
  return previousData.didChange;
}

exports.checkChildrenDidChange = checkChildrenDidChange;
//# sourceMappingURL=checkChildrenDidChange.js.map
