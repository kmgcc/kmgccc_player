'use strict';

"use strict";
function clearList(list, index) {
  index || (index = 0);
  for (let j = index; j < list.length; j++) {
    if (list[j]) {
      list[j] = null;
    } else {
      break;
    }
  }
}

exports.clearList = clearList;
//# sourceMappingURL=clearList.js.map
