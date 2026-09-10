#!/usr/bin/env python3
"""External, explicit AMLL absolute-time TTML -> standard parent-relative TTML conversion.

This is Demo tooling, never an engine fallback. Original bytes and their SHA256 remain local.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import xml.etree.ElementTree as ET

TT = "http://www.w3.org/ns/ttml"
ET.register_namespace("", TT)
ET.register_namespace("ttm", TT + "#metadata")
ET.register_namespace("tts", TT + "#styling")
ET.register_namespace("itunes", "http://music.apple.com/lyric-ttml-internal")
ET.register_namespace("amll", "http://www.example.com/ns/amll")


def seconds(value):
    if value.endswith("ms"):
        return float(value[:-2]) / 1000
    if value.endswith("s"):
        return float(value[:-1])
    parts = value.split(":")
    if len(parts) in (2, 3):
        return sum(float(part) * 60**i for i, part in enumerate(reversed(parts)))
    raise ValueError(f"Unsupported source time: {value}")


def normalize(root):
    structural = {"tt", "head", "body", "div", "p", "span", "br", "metadata", "styling", "style", "layout", "region"}
    for element in root.iter():
        if "}" not in element.tag and element.tag in structural:
            element.tag = "{" + TT + "}" + element.tag

    def visit(element, origin):
        absolute_start = seconds(element.attrib["begin"]) if "begin" in element.attrib else origin
        for key in ("begin", "end"):
            if key in element.attrib:
                element.set(key, f"{max(0, seconds(element.attrib[key]) - origin):.6f}s")
        if "dur" in element.attrib:
            element.set("dur", f"{seconds(element.attrib['dur']):.6f}s")
        for child in element:
            visit(child, absolute_start)

    body = root.find("{" + TT + "}body")
    if body is None:
        raise ValueError("Source has no TTML body")
    visit(body, 0)
    return root


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ttml", type=Path)
    parser.add_argument("--audio", type=Path)
    parser.add_argument("--title", default="")
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / ".local")
    args = parser.parse_args()
    original = args.ttml.read_bytes()
    root = normalize(ET.fromstring(original))
    if args.title:
        head = root.find("{" + TT + "}head")
        if head is None:
            head = ET.SubElement(root, "{" + TT + "}head")
        metadata = ET.SubElement(head, "{" + TT + "}metadata")
        ET.SubElement(metadata, "{" + TT + "#metadata}title").text = args.title
    args.output.mkdir(parents=True, exist_ok=True)
    target = args.output / "song.ttml"
    ET.ElementTree(root).write(target, encoding="utf-8", xml_declaration=True)
    (args.output / "original.ttml").write_bytes(original)
    manifest = {"originalSHA256": hashlib.sha256(original).hexdigest(), "normalizedSHA256": hashlib.sha256(target.read_bytes()).hexdigest(), "title": args.title, "conversion": "AMLL absolute times to standard TTML parent-relative; structural namespace repair"}
    if args.audio:
        shutil.copy2(args.audio, args.output / "audio.m4a")
        manifest["audioSHA256"] = hashlib.sha256(args.audio.read_bytes()).hexdigest()
    (args.output / "fixture.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(manifest, ensure_ascii=False))


if __name__ == "__main__":
    main()
