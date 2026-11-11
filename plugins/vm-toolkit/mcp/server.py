#!/usr/bin/env python3
"""vm-toolkit's MCP server: the VM toolkit's commands (skills/vm/scripts/vmt) as tools, for any MCP client.

Stdio transport, newline-delimited JSON-RPC; standard library only. Every tool runs vmt and returns what it printed:
the VMs, their images, the build and test scripts and their time boxes are the toolkit's, not this file's.
A VM is named: its folder is <VM root>/mcp/<name> (vmt root), so a session, an agent or a person can pick it up again.
"""

import base64
import json
import os
import re
import shlex
import subprocess
import sys
import threading

VERSION = "0.2.0"
HERE = os.path.dirname(os.path.abspath(__file__))
VMT = os.environ.get("VMT_BIN") or os.path.join(HERE, "..", "skills", "vm", "scripts", "vmt")
LOG_TAIL = 80

INSTRUCTIONS = """Throwaway QEMU VMs of a product's target OS (Windows 11 ARM64 today), on the machine this server runs on.
Start with vm_products on the repo or worktree, then vm_up the worktree (the VM shares it live as R:), and build and
test in it with vm_build / vm_test: nothing needs building on the host. vm_app_launch starts the built app in the
guest's desktop; vm_screenshot, vm_click, vm_type, vm_key and vm_scroll drive it. Exit meanings: green (0), red (1,
the change), harness error (3, the VM or the share, not the change: retry or say so). vm_down when done. A VM not
started with keep powers off after some idle minutes; the next build, test or app command boots it again."""


def name_ok(name):
    return bool(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", name or ""))


def default_name(worktree):
    n = re.sub(r"[^a-z0-9-]+", "-", os.path.basename(os.path.normpath(worktree)).lower()).strip("-")
    return (n or "vm")[:63]


def vmt(*args, repo=None):
    cmd = [VMT] + (["--repo", repo] if repo else []) + list(args)
    p = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).strip()


def vm_root():
    rc, out = vmt("root")
    if rc != 0:
        raise ToolError(out or "vmt root failed")
    return out.splitlines()[-1]


def vm_dir(name):
    if not name_ok(name):
        raise ToolError(f"bad VM name {name!r}: lowercase letters, digits and dashes")
    return os.path.join(vm_root(), "mcp", name)


def existing(name):
    d = vm_dir(name)
    if not os.path.isfile(os.path.join(d, "guest.conf")):
        raise ToolError(f"no VM named {name!r}: vm_up a worktree first (vm_list shows the VMs)")
    return d


class ToolError(Exception):
    pass


def text(s, error=False):
    return {"content": [{"type": "text", "text": s or "(no output)"}], "isError": error}


def verdict(rc, out, log=None):
    meaning = {0: "green", 1: "red (the build or tests fail)", 2: "usage error",
               3: "harness error (the VM, the share or a restore, not the change)"}.get(rc, f"exit {rc}")
    s = f"{meaning}\n{out}"
    if log and os.path.isfile(log) and rc != 0:
        with open(log, errors="replace") as f:
            tail = f.readlines()[-LOG_TAIL:]
        s += f"\n--- last {len(tail)} lines of {log}\n" + "".join(tail)
    return text(s, error=rc not in (0, 1))


# Each tool: description, input properties, required, handler(args) -> result.
def t_products(a):
    rc, out = vmt("products", repo=a["path"])
    if rc == 0 and a.get("files"):
        rc2, out2 = vmt("which", *a["files"], repo=a["path"])
        out += "\n" + out2
        rc = rc or rc2
    return text(out, rc != 0)


def t_up(a):
    w = os.path.abspath(os.path.expanduser(a["worktree"]))
    name = a.get("name") or default_name(w)
    d = vm_dir(name)
    conf = os.path.join(d, "guest.conf")
    if os.path.isfile(conf) and vmt("alive", d)[0] == 0:
        shared = re.search(r"^WORKTREE=(.*)$", open(conf).read(), re.M)
        # guest.conf is bash (vmt init writes printf %q): shlex reads its quoting back.
        shared = (shlex.split(shared.group(1)) or ["?"])[0] if shared else "?"
        if os.path.realpath(shared) != os.path.realpath(w):
            return text(f"VM {name!r} is running and shares {shared}: vm_down it first, or give this one another name", True)
        return text(f"VM {name!r} is already running, sharing {w}")
    # A VM that took a checkpoint starts from it from then on (vmt checkpoint), unless told another one.
    ck = a.get("from_checkpoint")
    if not ck and os.path.isfile(conf):
        m = re.search(r"^VM_IMAGE=checkpoints/([a-z0-9-]+)\.qcow2$", open(conf).read(), re.M)
        # ...as long as it exists: a deleted one leaves the product's image.
        ck = m.group(1) if m and vmt("checkpoint", "show", m.group(1))[0] == 0 else None
    os.makedirs(d, exist_ok=True)
    init = ["init", d, w]
    for k in ("product", "target"):
        if a.get(k):
            init += [f"--{k}", a[k]]
    if ck:
        init += ["--checkpoint", ck]
    init += ["--title", f"{name} - {os.path.basename(w)}"]
    rc, out = vmt(*init)
    if rc != 0:
        return text(out, True)
    rc, up = vmt("up", d, *(["--keep"] if a.get("keep") else []))
    return text(f"VM {name!r}: {out}\n{up}", rc != 0)


def t_build(a):
    d = existing(a["name"])
    args = ["guest", d, "build"] + ([a["project"]] if a.get("project") else []) + (["--clean"] if a.get("clean") else [])
    rc, out = vmt(*args)
    return verdict(rc, out, os.path.join(d, "build.log"))


def t_test(a):
    d = existing(a["name"])
    args = ["guest", d, "test"] + (["--no-build"] if a.get("no_build") else []) + [a["project"]]
    if a.get("filter"):
        args.append(a["filter"])
    rc, out = vmt(*args)
    return verdict(rc, out, os.path.join(d, "test.log"))


def t_run(a):
    rc, out = vmt("guest", existing(a["name"]), "run", a["powershell"])
    return text(f"exit {rc}\n{out}", rc != 0)


def t_app_launch(a):
    rc, out = vmt("guest", existing(a["name"]), "app", "launch")
    return text(out, rc != 0)


def t_app_stop(a):
    rc, out = vmt("guest", existing(a["name"]), "app", "stop")
    return text(out, rc != 0)


def t_screenshot(a):
    rc, out = vmt("guest", existing(a["name"]), "app", "shot")
    m = re.search(r"(\S+\.png) (\d+)x(\d+)", out)
    if rc != 0 or not m:
        return text(out, True)
    with open(m.group(1), "rb") as f:
        data = base64.b64encode(f.read()).decode()
    return {"content": [{"type": "image", "data": data, "mimeType": "image/png"},
                        {"type": "text", "text": f"{m.group(1)} ({m.group(2)}x{m.group(3)}; click coordinates are in these pixels)"}],
            "isError": False}


def t_click(a):
    args = ["guest", existing(a["name"]), "app", "click", str(int(a["x"])), str(int(a["y"]))]
    if a.get("button") in ("right", "double"):
        args.append(a["button"])
    rc, out = vmt(*args)
    return text(out or "clicked", rc != 0)


def t_type(a):
    rc, out = vmt("guest", existing(a["name"]), "app", "type", a["text"])
    return text(out or "typed", rc != 0)


def t_key(a):
    rc, out = vmt("guest", existing(a["name"]), "app", "key", *a["keys"])
    return text(out or "sent", rc != 0)


def t_scroll(a):
    rc, out = vmt("guest", existing(a["name"]), "app", "scroll", str(int(a["x"])), str(int(a["y"])), str(int(a["amount"])))
    return text(out or "scrolled", rc != 0)


def t_apply(a):
    args = ["apply", existing(a["name"]), os.path.abspath(os.path.expanduser(a["folder"]))]
    if a.get("guest_folder"):
        args.append(a["guest_folder"])
    rc, out = vmt(*args)
    return text(out, rc != 0)


def t_show(a):
    rc, out = vmt("show", existing(a["name"]))
    return text(out, rc != 0)


def t_list(a):
    root = os.path.join(vm_root(), "mcp")
    lines = []
    for n in sorted(os.listdir(root)) if os.path.isdir(root) else []:
        conf = os.path.join(root, n, "guest.conf")
        if not os.path.isfile(conf):
            continue
        rc, _ = vmt("alive", os.path.join(root, n))
        fields = {k: (shlex.split(v) or [""])[0] for k, v in re.findall(r"^(WORKTREE|PRODUCT|PLATFORM)=(.*)$", open(conf).read(), re.M)}
        lines.append(f"{n}: {'running' if rc == 0 else 'down'}, {fields.get('PRODUCT', '?')} on "
                     f"{fields.get('PLATFORM', '?')}, sharing {fields.get('WORKTREE', '?')}")
    rc, slots = vmt("list")
    return text("\n".join(lines or ["no named VMs"]) + ("\n-- slots (every VM on this machine)\n" + slots if slots else ""))


def t_checkpoint(a):
    args = ["checkpoint", existing(a["name"]), a["checkpoint"]]
    if a.get("note"):
        args += ["--note", a["note"]]
    if a.get("resume"):
        args.append("--resume")
    rc, out = vmt(*args)
    return text(out, rc != 0)


def t_checkpoints(a):
    rc, out = vmt("checkpoint", "show", a["checkpoint"]) if a.get("checkpoint") else vmt("checkpoint", "list")
    return text(out, rc != 0)


def t_down(a):
    rc, out = vmt("down", existing(a["name"]), *(["--keep-disk"] if a.get("keep_disk") else []))
    return text(out, rc != 0)


NAME = {"type": "string", "description": "The VM's name (vm_up returns it; vm_list lists them)."}
TOOLS = {
    "vm_products": ("The product VM definitions of a repo: its products, their guest targets and images, and whether "
                    "the images are on this machine. With files, which product each repo path belongs to.",
                    {"path": {"type": "string", "description": "A path inside the repo or one of its worktrees."},
                     "files": {"type": "array", "items": {"type": "string"},
                               "description": "Repo-relative paths to map to their product."}},
                    ["path"], t_products),
    "vm_up": ("Boot a throwaway VM (a copy-on-write clone of the product's image) that shares the worktree live as R:. "
              "Waits for a free VM slot. Returns the VM's name for the other tools.",
              {"worktree": {"type": "string", "description": "Absolute path of the worktree to share."},
               "product": {"type": "string", "description": "Needed when the repo has several (vm_products)."},
               "target": {"type": "string", "description": "Guest target, default the product's first (windows)."},
               "name": {"type": "string", "description": "Default: from the worktree's folder name."},
               "keep": {"type": "boolean", "description": "Never power it off when idle (until vm_down)."},
               "from_checkpoint": {"type": "string", "description": "Start from this checkpoint (vm_checkpoints) instead "
                                   "of the product's image: its sign-ins and setup are there. A VM that took a checkpoint "
                                   "starts from it anyway."}},
              ["worktree"], t_up),
    "vm_build": ("Build the shared worktree in the guest with the product's build script. Can take many minutes.",
                 {"name": NAME, "project": {"type": "string", "description": "One project; default what the target builds."},
                  "clean": {"type": "boolean", "description": "Delete the worktree's ignored files (bin/, obj/) first."}},
                 ["name"], t_build),
    "vm_test": ("Run one test project in the guest with the product's test script.",
                {"name": NAME, "project": {"type": "string", "description": "Repo-relative test project."},
                 "filter": {"type": "string", "description": "Test filter (dotnet test --filter syntax)."},
                 "no_build": {"type": "boolean", "description": "Run what the last build left."}},
                ["name", "project"], t_test),
    "vm_run": ("Run one PowerShell command in the guest (logs, settings, files), 5 minutes at most. The worktree is R:.",
               {"name": NAME, "powershell": {"type": "string"}}, ["name", "powershell"], t_run),
    "vm_app_launch": ("(Re)start the built app in the guest's desktop session with the product's launch script. The "
                      "window can take a while to show: take screenshots until it does.",
                      {"name": NAME}, ["name"], t_app_launch),
    "vm_app_stop": ("Stop the app running from the share (a build stops it too).", {"name": NAME}, ["name"], t_app_stop),
    "vm_screenshot": ("A screenshot of the guest's screen, and the PNG's path on this machine.",
                      {"name": NAME}, ["name"], t_screenshot),
    "vm_click": ("Click at a screenshot pixel.",
                 {"name": NAME, "x": {"type": "integer"}, "y": {"type": "integer"},
                  "button": {"type": "string", "enum": ["left", "right", "double"]}},
                 ["name", "x", "y"], t_click),
    "vm_type": ("Type text (US keyboard layout).", {"name": NAME, "text": {"type": "string"}}, ["name", "text"], t_type),
    "vm_key": ("Press keys or combos in order, e.g. [\"ctrl-n\"], [\"tab\", \"ret\"], [\"alt-f4\"].",
               {"name": NAME, "keys": {"type": "array", "items": {"type": "string"}}}, ["name", "keys"], t_key),
    "vm_scroll": ("Scroll the wheel at a screenshot pixel; amount > 0 scrolls down, < 0 up.",
                  {"name": NAME, "x": {"type": "integer"}, "y": {"type": "integer"}, "amount": {"type": "integer"}},
                  ["name", "x", "y", "amount"], t_scroll),
    "vm_apply": ("Put a setup folder (test data, settings, a resource) into the guest before launching the app: copies it, "
                 "then runs its check.ps1 and apply.ps1 if it has them ($Dir is the guest folder).",
                 {"name": NAME, "folder": {"type": "string", "description": "Local folder."},
                  "guest_folder": {"type": "string", "description": "Default C:\\factory\\setup\\<folder name>."}},
                 ["name", "folder"], t_apply),
    "vm_show": ("Open the VM's screen (TigerVNC with a shared clipboard, else Screen Sharing) on the machine running this server (for a person there; a remote "
                "client sees nothing).", {"name": NAME}, ["name"], t_show),
    "vm_list": ("The named VMs (running or down) and every VM slot in use on this machine.", {}, [], t_list),
    "vm_checkpoint": ("Freeze the VM's state as a named checkpoint other VMs can start from (vm_up from_checkpoint): "
                      "what is on its disk (sign-ins a person did in it, installed tools, data), not the shared worktree. "
                      "Shuts the guest down cleanly first (about a minute); the VM starts from the checkpoint from then on "
                      "(the next command boots it). Checkpoints are kept until a person deletes them (vmt checkpoint rm): "
                      "there is no tool for that.",
                      {"name": NAME,
                       "checkpoint": {"type": "string", "description": "Lowercase letters, digits and dashes, e.g. the "
                                      "branch's: devex-610 (devex-610-2 for a later one)."},
                       "note": {"type": "string", "description": "What was set up in it, for the VMs that start from it. "
                                "Never secrets."},
                       "resume": {"type": "boolean", "description": "Boot it again right away."}},
                      ["name", "checkpoint"], t_checkpoint),
    "vm_checkpoints": ("The checkpoints on this machine: size, age, product, branch and the VMs using them; with "
                       "checkpoint, one's details and its setup note.",
                       {"checkpoint": {"type": "string", "description": "One checkpoint's name."}}, [], t_checkpoints),
    "vm_down": ("Power the VM off and free its slot. Its folder stays, so vm_up can boot it again.",
                {"name": NAME, "keep_disk": {"type": "boolean", "description": "Keep the clone's disk for a look later."}},
                ["name"], t_down),
}


def tool_list():
    return [{"name": n, "description": d, "inputSchema": {"type": "object", "properties": p, "required": r}}
            for n, (d, p, r, _) in TOOLS.items()]


def handle(msg):
    method, mid = msg.get("method"), msg.get("id")
    if mid is None:
        return None  # a notification (notifications/initialized, cancelled): nothing to answer
    try:
        if method == "initialize":
            client = (msg.get("params") or {}).get("protocolVersion") or "2025-06-18"
            result = {"protocolVersion": client, "capabilities": {"tools": {}},
                      "serverInfo": {"name": "vm-toolkit", "version": VERSION}, "instructions": INSTRUCTIONS}
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": tool_list()}
        elif method == "tools/call":
            p = msg.get("params") or {}
            tool = TOOLS.get(p.get("name"))
            if not tool:
                return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": f"unknown tool {p.get('name')}"}}
            args = p.get("arguments") or {}
            missing = [k for k in tool[2] if k not in args]
            try:
                result = text(f"missing: {', '.join(missing)}", True) if missing else tool[3](args)
            except ToolError as e:
                result = text(str(e), True)
        else:
            return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"no method {method}"}}
    except Exception as e:  # a bug here must not kill the server mid-session
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": f"{type(e).__name__}: {e}"}}
    return {"jsonrpc": "2.0", "id": mid, "result": result}


OUT = threading.Lock()


def reply(r):
    if r is not None:
        with OUT:
            sys.stdout.write(json.dumps(r) + "\n")
            sys.stdout.flush()


def main():
    # A build or a boot takes minutes: each call answers on its own thread, so a screenshot or vm_list isn't stuck
    # behind it. Two calls on the same VM serialize in the toolkit (its lease lock), not here.
    calls = []
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            reply({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})
            continue
        if msg.get("method") == "tools/call":
            t = threading.Thread(target=lambda m=msg: reply(handle(m)))
            t.start()
            calls.append(t)
        else:
            reply(handle(msg))
    # The client closed its end: finish the calls in flight (their VMs' state is on disk either way).
    for t in calls:
        t.join()


if __name__ == "__main__":
    main()
