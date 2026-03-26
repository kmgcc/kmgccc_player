import { extensions } from '../extensions/Extensions.mjs';
import { Container } from '../scene/container/Container.mjs';
import { EventSystem } from './EventSystem.mjs';
import { FederatedContainer } from './FederatedEventTarget.mjs';

"use strict";
extensions.add(EventSystem);
extensions.mixin(Container, FederatedContainer);
//# sourceMappingURL=init.mjs.map
