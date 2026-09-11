#!/usr/bin/env python3
"""Summarize an xctrace time-profile table (not the environment-bearing TOC)."""
import collections
import json
import sys
import xml.etree.ElementTree as ET

tree = ET.parse(sys.argv[1])
ids = {e.attrib["id"]: e for e in tree.iter() if "id" in e.attrib}


def resolve(e):
    return ids.get(e.attrib.get("ref"), e) if e is not None else None


totals = collections.Counter()
frames = collections.Counter()
for row in tree.findall(".//row"):
    thread = resolve(row.find("thread"))
    if thread is None or "Main Thread" not in thread.attrib.get("fmt", ""):
        continue
    weight = resolve(row.find("weight"))
    ms = float(weight.text or 0) / 1e6 if weight is not None else 1
    trace = resolve(row.find("tagged-backtrace"))
    backtrace = resolve(trace.find("backtrace")) if trace is not None else None
    if backtrace is None:
        continue
    names = {resolve(f).attrib.get("name", "") for f in backtrace.findall("frame")}
    totals["mainRunningMS"] += ms
    for name in names:
        frames[name] += ms
    if any("CA::Transaction::commit" in n for n in names):
        totals["commitInclusiveMS"] += ms
    if any("Filter::encode" in n or "CIFilter encodeWithCoder" in n for n in names):
        totals["filterSerializationInclusiveMS"] += ms
print(json.dumps({"totals": dict(totals), "topInclusiveFrames": frames.most_common(12)}, indent=2))
