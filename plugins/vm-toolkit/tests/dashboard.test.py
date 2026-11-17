#!/usr/bin/env python3
"""dashboard.test.py: the VM dashboard (scripts/dashboard/server.py) on a fake VM root, and vmt rm. The server runs on a
free port with a fake vmt that logs its arguments; checks what /api/state makes of the root (running VMs, stale
folders, what a checkpoint is used by), that actions map to vmt, that only the page can post, and that videos answer
byte ranges. vmt rm runs for real on throwaway folders. Needs qemu-img (the checkpoint chains). No VM.
  python3 -I tests/dashboard.test.py
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(HERE, "..", "skills", "vm", "scripts")
SERVER = os.path.join(SCRIPTS, "dashboard", "server.py")
VMT = os.path.join(SCRIPTS, "vmt")

FAKE = """#!/bin/bash
echo "$*" >> "$FAKE_LOG"
echo "fake: $*"
"""

fails = 0


def check(what, got, want):
    global fails
    if got == want:
        print(f"✓ {what}")
    else:
        fails += 1
        print(f"✗ {what}: wanted {want!r}, got {got!r}")


def write(path, text=""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def qcow(path, backing=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    cmd = ["qemu-img", "create", "-q", "-f", "qcow2"] + (["-b", backing, "-F", "qcow2"] if backing else []) + [path]
    subprocess.run(cmd + ([] if backing else ["1M"]), check=True)


def folder(root, rel, worktree, image="base.qcow2", pid=None):
    d = os.path.join(root, rel)
    write(os.path.join(d, "guest.conf"),
          f"WORKTREE={worktree}\nPRODUCT=rdm\nAPP_NAME=Acme\\ App\nVM_HOME={root}/windows\nVM_IMAGE={image}\n"
          f"VM_TITLE=t\\ {os.path.basename(d)}\n")
    os.makedirs(os.path.join(d, "vm"), exist_ok=True)
    if pid:
        write(os.path.join(d, "vm", "qemu.pid"), str(pid))
    return d


def main():
    if not shutil.which("qemu-img"):
        print("dashboard: skipped (no qemu-img)")
        return
    with tempfile.TemporaryDirectory(prefix="vmt-dash-test.") as t:
        t = os.path.realpath(t)
        root, log, wt = os.path.join(t, "vms"), os.path.join(t, "calls.log"), os.path.join(t, "wt")
        os.makedirs(wt)
        fake = os.path.join(t, "vmt")
        write(fake, FAKE)
        os.chmod(fake, 0o755)

        home = os.path.join(root, "windows")
        qcow(os.path.join(home, "base.qcow2"))
        qcow(os.path.join(home, "checkpoints", "ck-a.qcow2"), os.path.join(home, "base.qcow2"))
        write(os.path.join(home, "checkpoints", "ck-a.conf"), f"CREATED=1\nPRODUCT=rdm\nWORKTREE={wt}\nBRANCH=feat/a\n")
        qcow(os.path.join(home, "checkpoints", "ck-b.qcow2"), os.path.join(home, "base.qcow2"))
        write(os.path.join(home, "checkpoints", "ck-b.conf"), "CREATED=1\nPRODUCT=rdm\nWORKTREE=/nowhere\n")
        # A sleeping child stands in for QEMU: its pid is alive.
        qemu = subprocess.Popen(["sleep", "300"])
        try:
            run = folder(root, "mcp/dev", wt, "checkpoints/ck-a.qcow2", qemu.pid)
            qcow(os.path.join(run, "vm", "disk.qcow2"), os.path.join(home, "checkpoints", "ck-a.qcow2"))
            write(os.path.join(home, "slots", "1", "vm"), os.path.join(run, "vm"))
            folder(root, "mcp/qa", wt, "checkpoints/ck-b.qcow2")
            gone = folder(root, "office/old", "/nowhere", "checkpoints/ck-gone.qcow2")
            write(os.path.join(root, "mcp", "qa", "app", "video-1.mp4"), "0123456789")
            port = free_port()
            srv = subprocess.Popen([sys.executable, "-I", SERVER, "--vmt", fake, "--root", root, "--port", str(port)],
                                   stdout=subprocess.DEVNULL, env=dict(os.environ, FAKE_LOG=log))
            try:
                base = f"http://127.0.0.1:{port}"
                wait(base)
                s = get(base + "/api/state")
                f = {x["id"]: x for x in s["folders"]}
                c = {x["name"]: x for x in s["checkpoints"]}
                check("folders from every group, not the guest OS home", sorted(f), ["mcp/dev", "mcp/qa", "office/old"])
                check("a running VM's slot", [(x["id"], x["alive"], x["managed"]) for x in s["slots"]], [("mcp/dev", True, True)])
                check("a running folder is never stale", (f["mcp/dev"]["running"], f["mcp/dev"]["stale"]), (True, []))
                check("a folder whose worktree and checkpoint are gone is stale",
                      f["office/old"]["stale"], ["worktree gone", "checkpoint gone"])
                check("guest.conf values are unquoted", f["mcp/qa"]["app"], "Acme App")
                check("a folder's videos", [v["path"] for v in f["mcp/qa"]["videos"]], ["mcp/qa/app/video-1.mp4"])
                check("a checkpoint a running VM starts from is in use", c["ck-a"]["running_users"], ["mcp/dev"])
                check("a down folder that starts from a checkpoint", c["ck-b"]["booting"], ["mcp/qa"])
                check("a checkpoint's worktree gone", (c["ck-a"]["worktree_ok"], c["ck-b"]["worktree_ok"]), (True, False))
                check("the images", [i["name"] for i in s["images"]], ["base.qcow2"])

                check("a post without the page's header is refused", post(base, {"op": "gc"}, header=False), 403)
                post(base, {"op": "rm", "ids": ["office/old", "mcp/qa"]})
                post(base, {"op": "ck-rm", "ids": ["ck-b"]})
                post(base, {"op": "down", "ids": ["mcp/dev"]})
                post(base, {"op": "gc"})
                calls = open(log).read().splitlines()
                check("rm maps to vmt rm on the folders",
                      f"rm {gone} {os.path.join(root, 'mcp', 'qa')}" in calls, True)
                check("ck-rm maps to vmt checkpoint rm", "checkpoint rm ck-b" in calls, True)
                check("down maps to vmt down", f"down {run}" in calls, True)
                check("gc maps to vmt gc", "gc" in calls, True)
                n = len(calls)
                check("a folder outside the root is refused", post(base, {"op": "rm", "ids": ["../../etc"]})["ok"], False)
                check("a bad checkpoint name is refused", post(base, {"op": "ck-rm", "ids": ["-rf"]})["ok"], False)
                check("refusals never reach vmt", len(open(log).read().splitlines()), n)

                req = urllib.request.Request(base + "/file/mcp/qa/app/video-1.mp4", headers={"Range": "bytes=2-5"})
                with urllib.request.urlopen(req) as r:
                    check("a video answers a byte range", (r.status, r.read(), r.headers["Content-Range"]),
                          (206, b"2345", "bytes 2-5/10"))
                check("only media and logs are served", status(base + "/file/mcp/qa/guest.conf"), 404)
                env = dict(os.environ, VMT_DASHBOARD_PORT=str(port), VMT_USER_CONFIG="/dev/null", FACTORY_USER_CONFIG="/dev/null")
                p = subprocess.run(["bash", VMT, "dashboard", "stop"], capture_output=True, text=True, env=env)
                check("vmt dashboard stop stops it", (p.returncode, srv.wait(timeout=10) is not None), (0, True))
                p = subprocess.run(["bash", VMT, "dashboard", "stop"], capture_output=True, text=True, env=env)
                check("vmt dashboard stop with none running", (p.returncode, p.stdout.strip()), (0, f"no dashboard on port {port}"))
            finally:
                srv.terminate()

            # vmt rm, for real
            env = dict(os.environ, VMT_USER_CONFIG="/dev/null", FACTORY_USER_CONFIG="/dev/null", VM_ROOT=root)
            p = subprocess.run(["bash", VMT, "rm", run, gone, wt], capture_output=True, text=True, env=env)
            check("vmt rm deletes a down folder", os.path.exists(gone), False)
            check("vmt rm keeps a running one", os.path.isdir(run) and "its VM is running" in p.stderr, True)
            check("vmt rm keeps a folder with no guest.conf", os.path.isdir(wt) and "not a VM folder" in p.stderr, True)
            check("vmt rm fails when it kept one", p.returncode, 1)
        finally:
            qemu.kill()

    print("dashboard: all passed" if fails == 0 else f"dashboard: {fails} failed")
    sys.exit(1 if fails else 0)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait(base):
    for _ in range(50):
        try:
            return get(base + "/api/whoami")
        except OSError:
            time.sleep(0.1)
    raise SystemExit("the dashboard did not start")


def get(url):
    with urllib.request.urlopen(url) as r:
        return json.load(r)


def status(url):
    try:
        with urllib.request.urlopen(url) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


def post(base, body, header=True):
    req = urllib.request.Request(base + "/api/action", data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", **({"X-VM-Dashboard": "1"} if header else {})})
    try:
        with urllib.request.urlopen(req) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return e.code


if __name__ == "__main__":
    main()
