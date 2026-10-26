#!/usr/bin/env python3
"""Offline structural check of scene v2 examples; never builds or launches the App.

The App's skin.check method is the authority for expression and component compilation.
"""
import argparse
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "docs/skin-package-v2.schema.json"


def check(directory):
    directory = directory.resolve()
    manifest = json.loads((directory / "manifest.json").read_text())
    schema = json.loads(SCHEMA.read_text())
    allowed = set(schema["$defs"]["node"]["properties"])
    node_types = set(schema["$defs"]["node"]["properties"]["type"]["enum"])
    components = set(schema["$defs"]["node"]["properties"]["component"]["enum"])
    if manifest.get("formatVersion") != 2 or manifest.get("hostAPIVersion") != 2:
        raise ValueError("manifest requires formatVersion 2 and hostAPIVersion 2")
    descriptor = manifest.get("descriptor", {})
    if not descriptor.get("id") or not descriptor.get("name"):
        raise ValueError("descriptor requires id and name")

    def resource(path):
        if not isinstance(path, str) or path.startswith(("/", "=")) or ".." in pathlib.PurePosixPath(path).parts or ":" in path:
            raise ValueError(f"invalid resource path: {path}")
        resolved = (directory / path).resolve()
        if not resolved.is_relative_to(directory) or not resolved.is_file():
            raise ValueError(f"missing or escaped resource: {path}")
        return resolved

    scenes = list(manifest.get("scenes", {}).values())
    if isinstance(manifest.get("scene"), str):
        scenes.append(json.loads(resource(manifest["scene"]).read_text()))
    elif manifest.get("scene"):
        scenes.append(manifest["scene"])
    if not scenes:
        raise ValueError("a v2 package requires a scene")
    for font in manifest.get("fonts", []):
        resource(font)
    count = 0

    def node(value, path, templates, chain=(), depth=0, repeated=False):
        nonlocal count
        count += 1
        if count > 2000 or depth >= 64:
            raise ValueError(f"{path}: scene limit exceeded")
        if not isinstance(value, dict) or value.get("type") not in node_types:
            raise ValueError(f"{path}: unknown or missing node type")
        unknown = set(value) - allowed
        if unknown:
            raise ValueError(f"{path}: unknown keys {sorted(unknown)}")
        kind = value["type"]
        if kind == "use":
            name = value.get("name")
            if name in chain or name not in templates:
                raise ValueError(f"{path}: missing or cyclic template {name}")
            return node(templates[name], path + ".use", templates, chain + (name,), depth + 1, repeated)
        if kind in ("image", "video", "shader"):
            resource(value.get("path"))
        if kind == "component" and value.get("component") not in components:
            raise ValueError(f"{path}: unknown component {value.get('component')}")
        native = kind == "lyrics" or value.get("component") in ("lyrics.native", "lyrics.panel")
        if native and repeated:
            raise ValueError(f"{path}: native lyrics cannot repeat")
        children = value.get("children", [])
        if kind == "repeat":
            if "template" not in value:
                raise ValueError(f"{path}: repeat requires template")
            children = [value["template"]]
        if kind == "switch":
            children = value.get("cases", []) + ([value["default"]] if "default" in value else [])
        ids = [c["id"] for c in children if "id" in c]
        if len(set(ids)) != len(ids):
            raise ValueError(f"{path}: duplicate sibling ids")
        totals = [node(child, f"{path}.children[{i}]", templates, chain, depth + 1, repeated or kind == "repeat") for i, child in enumerate(children)]
        if "mask" in value:
            totals.append(node(value["mask"], path + ".mask", templates, chain, depth + 1, repeated))
        return int(native) + (max(totals, default=0) if kind == "switch" else sum(totals))

    for scene in scenes:
        templates = dict(scene.get("components", {}))
        for path in (directory / "components").glob("*.json"):
            templates[path.stem] = json.loads(path.read_text())
        if node(scene["root"], "$.scene.root", templates) > 1:
            raise ValueError("a scene supports one native lyrics instance")
    for path in directory.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"symlink forbidden: {path.name}")
    return descriptor["id"], count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directories", nargs="*", type=pathlib.Path)
    parser.add_argument("--all-examples", action="store_true")
    args = parser.parse_args()
    directories = args.directories
    if args.all_examples:
        directories += sorted(p.parent for p in (ROOT / "docs/examples/skins").glob("*/manifest.json"))
    if not directories:
        parser.error("provide a directory or --all-examples")
    failed = False
    for directory in directories:
        try:
            identifier, count = check(directory)
            print(f"OK {identifier}: {count} nodes (structural check)")
        except (ValueError, KeyError, OSError, TypeError) as error:
            failed = True
            print(f"FAIL {directory}: {error}", file=sys.stderr)
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
