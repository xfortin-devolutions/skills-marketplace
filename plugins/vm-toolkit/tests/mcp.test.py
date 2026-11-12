#!/usr/bin/env python3
"""mcp.test.py: mcp/server.py over its stdio transport, on a fake vmt (VMT_BIN) that logs its arguments and answers
like the real one. Checks the handshake, the tool list, how calls map to vmt, the verdicts, and that a screenshot comes
back as an image. No VM.
  python3 -I tests/mcp.test.py
"""

import base64
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "..", "mcp", "server.py")
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")

FAKE = r"""#!/bin/bash
echo "$*" >> "$FAKE_LOG"
case "$1" in
  root) echo "$FAKE_ROOT" ;;
  init) mkdir -p "$2" && printf 'WORKTREE=%s\nPRODUCT=rdm\nPLATFORM=windows\n' "$3" > "$2/guest.conf"
        ck=$(echo "$*" | sed -n 's/.*--checkpoint \([a-z0-9-]*\).*/\1/p')
        [ -n "$ck" ] && echo "VM_IMAGE=checkpoints/$ck.qcow2" >> "$2/guest.conf"; echo "$2: RDM on windows" ;;
  checkpoint)
    case "$2" in
      list) echo "NAME SIZE"; echo "devex-610 4.9 GB" ;;
      show) echo "note for $3" ;;
      *) echo "VM_IMAGE=checkpoints/$3.qcow2" >> "$2/guest.conf"; echo "checkpoint $3" ;;
    esac ;;
  up) echo "slot 1: SSH 127.0.0.1:2231" ;;
  alive) exit 1 ;;
  list) ;;
  guest)
    case "$3 $4" in
      "build "*|"build") [ -f "$FAKE_ROOT/red" ] && { echo "error CS1002"; echo "BUILD EXIT CODE: 1" > "$2/build.log"; exit 1; }
                         [ -f "$FAKE_ROOT/harness" ] && { echo "HARNESS ERROR: no BUILD EXIT CODE"; echo "ssh died" > "$2/build.log"; exit 3; }
                         echo "Build succeeded."; exit 0 ;;
      "app shot") mkdir -p "$2/app"; cp "$FAKE_PNG" "$2/app/shot-1.png"; echo "$2/app/shot-1.png 1600x900" ;;
      *) echo ok ;;
    esac ;;
  *) echo "fake: $*" ;;
esac
"""

fails = 0


def check(what, got, want):
    global fails
    if got == want:
        print(f"✓ {what}")
    else:
        fails += 1
        print(f"✗ {what}: wanted {want!r}, got {got!r}")


def main():
    with tempfile.TemporaryDirectory(prefix="vmt-mcp-test.") as t:
        fake = os.path.join(t, "vmt")
        with open(fake, "w") as f:
            f.write(FAKE)
        os.chmod(fake, 0o755)
        png = os.path.join(t, "s.png")
        with open(png, "wb") as f:
            f.write(PNG)
        root, log = os.path.join(t, "vms"), os.path.join(t, "calls.log")
        env = dict(os.environ, VMT_BIN=fake, FAKE_ROOT=root, FAKE_LOG=log, FAKE_PNG=png)
        os.makedirs(root)

        def session(*calls):
            msgs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
                    {"jsonrpc": "2.0", "method": "notifications/initialized"}]
            msgs += [{"jsonrpc": "2.0", "id": i + 1, "method": "tools/call", "params": {"name": n, "arguments": a}}
                     for i, (n, a) in enumerate(calls)]
            out = subprocess.run([sys.executable, "-I", SERVER], input="".join(json.dumps(m) + "\n" for m in msgs),
                                 capture_output=True, text=True, env=env, timeout=60).stdout
            replies = {r["id"]: r for r in map(json.loads, out.splitlines())}
            return replies

        r = session()
        check("initialize echoes the protocol version", r[0]["result"]["protocolVersion"], "2025-06-18")
        check("initialize says it has tools", "tools" in r[0]["result"]["capabilities"], True)

        listing = subprocess.run([sys.executable, "-I", SERVER],
                                 input=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}) + "\n",
                                 capture_output=True, text=True, env=env, timeout=60).stdout
        names = [x["name"] for x in json.loads(listing)["result"]["tools"]]
        check("every tool is listed", {"vm_up", "vm_build", "vm_test", "vm_screenshot", "vm_click", "vm_down"} <= set(names), True)

        wt = os.path.join(t, "My Worktree")
        os.makedirs(wt)
        # Calls in one session run at once (the server threads them), as a client may send them: vm_up goes first, alone.
        up = session(("vm_up", {"worktree": wt, "product": "rdm"}))
        check("vm_up answers with the VM's name", "VM 'my-worktree'" in up[1]["result"]["content"][0]["text"], True)
        r = session(("vm_up", {"worktree": wt}), ("vm_build", {"name": "my-worktree"}),
                    ("vm_screenshot", {"name": "my-worktree"}), ("vm_click", {"name": "my-worktree", "x": 10, "y": 20, "button": "double"}),
                    ("vm_build", {"name": "../escape"}), ("vm_test", {"name": "my-worktree"}))
        calls = open(log).read().splitlines()
        d = os.path.join(root, "mcp", "my-worktree")
        check("vm_up names the VM after the worktree and inits it with the product",
              f"init {d} {wt} --product rdm --title my-worktree - My Worktree" in calls, True)
        check("vm_up boots it with an idle reaper (no --keep)", f"up {d}" in calls, True)
        check("vm_build: green", r[2]["result"]["content"][0]["text"].splitlines()[0], "green")
        shot = r[3]["result"]["content"]
        check("vm_screenshot returns an image", (shot[0]["type"], shot[0]["mimeType"], base64.b64decode(shot[0]["data"]) == PNG),
              ("image", "image/png", True))
        check("vm_screenshot gives the PNG's path", shot[1]["text"].startswith(os.path.join(d, "app", "shot-1.png")), True)
        check("vm_click maps to guest app click", f"guest {d} app click 10 20 double" in calls, True)
        check("a bad name is refused", (r[5]["result"]["isError"], "bad VM name" in r[5]["result"]["content"][0]["text"]), (True, True))
        check("a missing argument is refused", "missing: project" in r[6]["result"]["content"][0]["text"], True)

        r = session(("vm_checkpoint", {"name": "my-worktree", "checkpoint": "devex-610", "note": "signed in to the SSO tool",
                                       "resume": True}),
                    ("vm_checkpoints", {}), ("vm_checkpoints", {"checkpoint": "devex-610"}))
        calls = open(log).read().splitlines()
        check("vm_checkpoint maps to vmt checkpoint with its note and --resume",
              f"checkpoint {d} devex-610 --note signed in to the SSO tool --resume" in calls, True)
        check("vm_checkpoints lists", "devex-610 4.9 GB" in r[2]["result"]["content"][0]["text"], True)
        check("vm_checkpoints shows one", r[3]["result"]["content"][0]["text"], "note for devex-610")
        check("no tool deletes a checkpoint", any("rm" in n or "delete" in n for n in names), False)
        session(("vm_up", {"worktree": wt}))
        calls = open(log).read().splitlines()
        check("a VM that took a checkpoint starts from it on its next vm_up",
              f"init {d} {wt} --checkpoint devex-610 --title my-worktree - My Worktree" in calls, True)
        wt2 = os.path.join(t, "qa-wt")
        os.makedirs(wt2)
        session(("vm_up", {"worktree": wt2, "name": "qa-devex-610", "from_checkpoint": "devex-610"}))
        calls = open(log).read().splitlines()
        check("vm_up from_checkpoint inits from it",
              f"init {os.path.join(root, 'mcp', 'qa-devex-610')} {wt2} --checkpoint devex-610 --title qa-devex-610 - qa-wt" in calls, True)

        session(("vm_record_start", {"name": "my-worktree", "max_minutes": 5}),
                ("vm_caption", {"name": "my-worktree", "text": "Opening the entry's dialog", "seconds": 3}),
                ("vm_record_stop", {"name": "my-worktree"}))
        calls = open(log).read().splitlines()
        check("vm_record_start maps to app record start with its limit", f"guest {d} app record start 5" in calls, True)
        check("vm_caption maps to app caption with its text and seconds",
              f"guest {d} app caption Opening the entry's dialog 3" in calls, True)
        check("vm_record_stop maps to app record stop", f"guest {d} app record stop" in calls, True)

        open(os.path.join(root, "red"), "w").close()
        r = session(("vm_build", {"name": "my-worktree"}))
        res = r[1]["result"]
        check("a red build is a result, not a tool error", (res["isError"], res["content"][0]["text"].splitlines()[0]),
              (False, "red (the build or tests fail)"))
        check("a red build carries the log's tail", "BUILD EXIT CODE: 1" in res["content"][0]["text"], True)
        os.remove(os.path.join(root, "red"))
        open(os.path.join(root, "harness"), "w").close()
        res = session(("vm_build", {"name": "my-worktree"}))[1]["result"]
        check("a harness error is a tool error", (res["isError"], res["content"][0]["text"].startswith("harness error")), (True, True))

    print("mcp: all passed" if fails == 0 else f"mcp: {fails} failed")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
