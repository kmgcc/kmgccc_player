import { extensions } from '../extensions/Extensions.mjs';
import { Container } from '../scene/container/Container.mjs';
import { AccessibilitySystem } from './AccessibilitySystem.mjs';
import { accessibilityTarget } from './accessibilityTarget.mjs';

"use strict";
extensions.add(AccessibilitySystem);
extensions.mixin(Container, accessibilityTarget);
//# sourceMappingURL=init.mjs.map
