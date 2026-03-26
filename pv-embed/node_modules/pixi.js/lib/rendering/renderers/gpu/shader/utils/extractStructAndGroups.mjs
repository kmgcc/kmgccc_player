"use strict";
function extractStructAndGroups(wgsl) {
  const linePattern = /(^|[^/])@(group|binding)\(\d+\)[^;]+;/g;
  const groupPattern = /@group\((\d+)\)/;
  const bindingPattern = /@binding\((\d+)\)/;
  const namePattern = /var(<[^>]+>)? (\w+)/;
  const typePattern = /:\s*([\w<>]+)/;
  const structPattern = /struct\s+(\w+)\s*{([^}]+)}/g;
  const structMemberPattern = /(\w+)\s*:\s*([\w\<\>]+)/g;
  const structName = /struct\s+(\w+)/;
  const groups = wgsl.match(linePattern)?.map((item) => ({
    group: parseInt(item.match(groupPattern)[1], 10),
    binding: parseInt(item.match(bindingPattern)[1], 10),
    name: item.match(namePattern)[2],
    isUniform: item.match(namePattern)[1] === "<uniform>",
    type: item.match(typePattern)[1]
  }));
  if (!groups) {
    return {
      groups: [],
      structs: []
    };
  }
  const structs = wgsl.match(structPattern)?.map((struct) => {
    const name = struct.match(structName)[1];
    const members = struct.match(structMemberPattern).reduce((acc, member) => {
      const [name2, type] = member.split(":");
      acc[name2.trim()] = type.trim();
      return acc;
    }, {});
    if (!members) {
      return null;
    }
    return { name, members };
  }).filter(({ name }) => groups.some(
    (group) => (
      // Handle both direct type matches and generic types like array<StructName>
      group.type === name || group.type.includes(`<${name}>`)
    )
  )) ?? [];
  return {
    groups,
    structs
  };
}

export { extractStructAndGroups };
//# sourceMappingURL=extractStructAndGroups.mjs.map
