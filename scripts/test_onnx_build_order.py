#!/usr/bin/env python3
"""Check ONNX cleanup ordering in an actual Xcode build manifest.

Pass XCBuildData/<build>.xcbuilddata/manifest.json from the build being
validated. Phase list positions alone do not order SwiftPM's implicit tasks.

A signed graph (CODE_SIGNING_ALLOWED=YES) must order
copy -> framework CodeSign -> cleanup -> app CodeSign. An unsigned graph
(CODE_SIGNING_ALLOWED=NO) has no CodeSign tasks and therefore no signing race;
it only has to keep declaring the framework signature as the cleanup input so
that signed builds stay ordered. Unsigned builds do not get a copy -> cleanup
ordering guarantee (unchanged from the original cleanup phase).
"""

import argparse
import json
from pathlib import Path


def verify_order(manifest):
    commands = manifest["commands"]
    producers = {}
    for name, command in commands.items():
        for output in command.get("outputs", []):
            producers.setdefault(output, set()).add(name)

    def unique(label, predicate):
        matches = [name for name, command in commands.items()
                   if predicate(command.get("description", ""))]
        assert len(matches) == 1, f"expected one {label} task, found {len(matches)}"
        return matches[0]

    def depends_on(task, prerequisite):
        pending, visited = [task], set()
        while pending:
            current = pending.pop()
            if current in visited:
                continue
            visited.add(current)
            for node in commands[current].get("inputs", []):
                for producer in producers.get(node, ()):
                    if producer == prerequisite:
                        return True
                    pending.append(producer)
        return False

    framework = "/CatRobot.app/Frameworks/onnxruntime.framework"
    copy = unique("ONNX copy", lambda d: d.startswith("Copy ") and framework + " " in d)
    cleanup = unique("ONNX cleanup", lambda d: d.startswith("PhaseScriptExecution Remove codeless onnxruntime framework "))
    descriptions = [command.get("description", "") for command in commands.values()]
    if not any(d.startswith("CodeSign ") for d in descriptions):
        embedded = [output for output in commands[copy].get("outputs", []) if output.endswith(framework)]
        assert len(embedded) == 1, "ONNX copy must produce the embedded framework"
        assert embedded[0] + "/_CodeSignature" in commands[cleanup].get("inputs", []), \
            "cleanup must keep declaring the framework signature as its input"
        return "unsigned"
    sign = unique("ONNX CodeSign", lambda d: d.startswith("CodeSign ") and d.endswith(framework))
    app_sign = unique("app CodeSign", lambda d: d.startswith("CodeSign ") and d.endswith("/CatRobot.app"))

    for task, prerequisite, message in [
        (sign, copy, "framework CodeSign must wait for the embedded copy"),
        (cleanup, sign, "cleanup must wait for framework CodeSign; otherwise it can delete the signing input"),
        (app_sign, cleanup, "app CodeSign must wait for cleanup"),
    ]:
        assert depends_on(task, prerequisite), message
        assert not depends_on(prerequisite, task), f"dependency cycle: {message}"
    return "signed"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    mode = verify_order(json.loads(args.manifest.read_text()))
    if mode == "unsigned":
        print("PASS (unsigned graph): no CodeSign tasks; cleanup still declares the framework signature input")
    else:
        print("PASS: embedded ONNX copy -> framework CodeSign -> cleanup -> app CodeSign")
