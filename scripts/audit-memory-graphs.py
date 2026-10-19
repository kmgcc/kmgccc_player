#!/usr/bin/env python3
"""Read two saved memgraphs; never attach to, launch, or stop an app."""

import argparse
import json
from pathlib import Path
import re
import subprocess


def memgraph(value):
    path = Path(value).expanduser().resolve()
    if path.suffix != ".memgraph" or not path.is_file():
        raise argparse.ArgumentTypeError("Expected an existing .memgraph file")
    return path


def audit(before, after, output):
    # Exclusive creation protects earlier evidence from accidental replacement.
    output.mkdir(parents=True, exist_ok=False)
    results = []

    def run(name, command):
        destination = output / (name + ".txt")
        try:
            with destination.open("w") as stream:
                result = subprocess.run(
                    command, stdout=stream, stderr=subprocess.STDOUT,
                    timeout=60, check=False,
                )
            status = result.returncode
        except (OSError, subprocess.TimeoutExpired) as error:
            with destination.open("a") as stream:
                stream.write("\nAnalysis incomplete: " + str(error) + "\n")
            status = -1
        results.append({"file": destination.name, "command": command, "status": status})
        return destination, status

    for label, graph in (("before", before), ("after", after)):
        run(label + "-vmmap", ["/usr/bin/vmmap", "--summary", str(graph)])
        run(label + "-footprint", ["/usr/bin/footprint", str(graph)])
        run(label + "-zones", ["/usr/bin/heap", "--zones", "--sortBySize", str(graph)])

    run("new-objects", ["/usr/bin/heap", "--sortBySize", "--zones",
                        "--diffFrom=" + str(before), str(after)])
    hosts, status = run("hosting-addresses", ["/usr/bin/heap", "--noContent",
                                            "--addresses=NSHostingView", str(after)])
    addresses = []
    if status == 0:
        for line in hosts.read_text(errors="replace").splitlines():
            match = re.match(r"\s*(0x[0-9a-fA-F]+)\b", line)
            if match and match[1] not in addresses:
                addresses.append(match[1])
            if len(addresses) == 3:
                break
    for index, address in enumerate(addresses, 1):
        run("hosting-root-" + str(index), ["/usr/bin/leaks", "--noContent",
                                         "--traceTree=" + address, str(after)])

    summary = {
        "before": str(before), "after": str(after), "results": results,
        "sampledHostingAddresses": addresses,
        "limits": [
            "Compare captures from the same build, workload and settled window state.",
            "New objects are surviving candidates, not proof of a leak.",
            "--zones groups allocator zones; it does not select Malloc Small VM regions.",
            "A reference tree may include conservative pointer matches; inspect its roots.",
            "No host addresses may mean no matches, unsupported naming, or incomplete evidence.",
            "Allocation stacks require a capture with MallocStackLogging enabled.",
            "GPU and allocator residency cannot be attributed from object counts alone.",
        ],
    }
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    failures = sum(item["status"] != 0 for item in results)
    print(f"Saved {len(results)} analyses to {output}; failed: {failures}; hosting roots: {len(addresses)}")
    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=memgraph)
    parser.add_argument("after", type=memgraph)
    parser.add_argument("--out", type=Path, required=True, help="New evidence directory")
    args = parser.parse_args()
    try:
        return audit(args.before, args.after, args.out.expanduser().resolve())
    except FileExistsError:
        parser.error("Output directory already exists; choose a new --out path")


if __name__ == "__main__":
    raise SystemExit(main())
