import { Container, UPDATE_VISIBLE, UPDATE_COLOR, UPDATE_BLEND } from '../Container.mjs';
import { clearList } from './clearList.mjs';
import { multiplyColors } from './multiplyColors.mjs';

"use strict";
const tempContainer = new Container();
const UPDATE_BLEND_COLOR_VISIBLE = UPDATE_VISIBLE | UPDATE_COLOR | UPDATE_BLEND;
function updateRenderGroupTransforms(renderGroup, updateChildRenderGroups = false) {
  updateRenderGroupTransform(renderGroup);
  const childrenToUpdate = renderGroup.childrenToUpdate;
  const updateTick = renderGroup.updateTick++;
  for (const j in childrenToUpdate) {
    const renderGroupDepth = Number(j);
    const childrenAtDepth = childrenToUpdate[j];
    const list = childrenAtDepth.list;
    const index = childrenAtDepth.index;
    for (let i = 0; i < index; i++) {
      const child = list[i];
      if (child.parentRenderGroup === renderGroup && child.relativeRenderGroupDepth === renderGroupDepth) {
        updateTransformAndChildren(child, updateTick, 0);
      }
    }
    clearList(list, index);
    childrenAtDepth.index = 0;
  }
  if (updateChildRenderGroups) {
    for (let i = 0; i < renderGroup.renderGroupChildren.length; i++) {
      updateRenderGroupTransforms(renderGroup.renderGroupChildren[i], updateChildRenderGroups);
    }
  }
}
function updateRenderGroupTransform(renderGroup) {
  const root = renderGroup.root;
  let worldAlpha;
  if (renderGroup.renderGroupParent) {
    const renderGroupParent = renderGroup.renderGroupParent;
    renderGroup.worldTransform.appendFrom(
      root.relativeGroupTransform,
      renderGroupParent.worldTransform
    );
    renderGroup.worldColor = multiplyColors(
      root.groupColor,
      renderGroupParent.worldColor
    );
    worldAlpha = root.groupAlpha * renderGroupParent.worldAlpha;
  } else {
    renderGroup.worldTransform.copyFrom(root.localTransform);
    renderGroup.worldColor = root.localColor;
    worldAlpha = root.localAlpha;
  }
  worldAlpha = worldAlpha < 0 ? 0 : worldAlpha > 1 ? 1 : worldAlpha;
  renderGroup.worldAlpha = worldAlpha;
  renderGroup.worldColorAlpha = renderGroup.worldColor + ((worldAlpha * 255 | 0) << 24);
}
function updateTransformAndChildren(container, updateTick, updateFlags) {
  if (updateTick === container.updateTick) return;
  container.updateTick = updateTick;
  container.didChange = false;
  const localTransform = container.localTransform;
  container.updateLocalTransform();
  const parent = container.parent;
  if (parent && !parent.renderGroup) {
    updateFlags |= container._updateFlags;
    container.relativeGroupTransform.appendFrom(
      localTransform,
      parent.relativeGroupTransform
    );
    if (updateFlags & UPDATE_BLEND_COLOR_VISIBLE) {
      updateColorBlendVisibility(container, parent, updateFlags);
    }
  } else {
    updateFlags = container._updateFlags;
    container.relativeGroupTransform.copyFrom(localTransform);
    if (updateFlags & UPDATE_BLEND_COLOR_VISIBLE) {
      updateColorBlendVisibility(container, tempContainer, updateFlags);
    }
  }
  if (!container.renderGroup) {
    const children = container.children;
    const length = children.length;
    for (let i = 0; i < length; i++) {
      updateTransformAndChildren(children[i], updateTick, updateFlags);
    }
    const renderGroup = container.parentRenderGroup;
    const renderable = container;
    if (renderable.renderPipeId && !renderGroup.structureDidChange) {
      renderGroup.updateRenderable(renderable);
    }
  }
}
function updateColorBlendVisibility(container, parent, updateFlags) {
  if (updateFlags & UPDATE_COLOR) {
    container.groupColor = multiplyColors(
      container.localColor,
      parent.groupColor
    );
    let groupAlpha = container.localAlpha * parent.groupAlpha;
    groupAlpha = groupAlpha < 0 ? 0 : groupAlpha > 1 ? 1 : groupAlpha;
    container.groupAlpha = groupAlpha;
    container.groupColorAlpha = container.groupColor + ((groupAlpha * 255 | 0) << 24);
  }
  if (updateFlags & UPDATE_BLEND) {
    container.groupBlendMode = container.localBlendMode === "inherit" ? parent.groupBlendMode : container.localBlendMode;
  }
  if (updateFlags & UPDATE_VISIBLE) {
    container.globalDisplayStatus = container.localDisplayStatus & parent.globalDisplayStatus;
  }
  container._updateFlags = 0;
}

export { updateRenderGroupTransform, updateRenderGroupTransforms, updateTransformAndChildren };
//# sourceMappingURL=updateRenderGroupTransforms.mjs.map
