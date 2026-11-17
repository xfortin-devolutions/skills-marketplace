"""VM dashboard: what the VM toolkit keeps on this Mac, to see it and clean it up from a browser.

Started by `vmt dashboard`. Reads the VM root (lib/config.sh's VM_ROOT): each guest OS's images, checkpoints and slots,
and the VM folders callers made under it (the MCP server's mcp/, other tools' own folders: any <root>/<group>/<name>/
with a guest.conf). Serves them as JSON to index.html. Standard library only; listens on 127.0.0.1. Every change goes
through vmt (down, rm, checkpoint rm, gc, show), so its refusals hold here too: a running VM's folder, a checkpoint a
VM or another checkpoint is built on.
"""

import argparse
import glob
import json
import mimetypes
import os
import re
import shlex
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
# A down VM folder unused this long is offered for cleanup.
STALE_DAYS = 7
ARGS = None


def plugin_version():
    """The vm-toolkit version this server runs (its plugin.json, four folders up), shown on the page."""
    try:
        with open(os.path.join(SCRIPTS, "..", "..", "..", ".claude-plugin", "plugin.json")) as f:
            return json.load(f).get("version") or "unknown"
    except (OSError, ValueError):
        return "unknown"


VERSION = plugin_version()


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def conf(path):
    """A guest.conf or checkpoint .conf (KEY=value lines, values quoted by printf %q) as a dict."""
    out = {}
    for line in (read(path) or "").splitlines():
        m = re.match(r"^([A-Z_]+)=(.*)$", line)
        if not m:
            continue
        try:
            out[m.group(1)] = " ".join(shlex.split(m.group(2)))
        except ValueError:
            out[m.group(1)] = m.group(2)
    return out


def pid_alive(path):
    try:
        os.kill(int((read(path) or "").strip()), 0)
        return True
    except (OSError, ValueError):
        return False


def mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0


def blocks_kb(path):
    try:
        return os.stat(path).st_blocks // 2
    except OSError:
        return 0


_sizes = {}
_sizes_lock = threading.Lock()


def du_kb(path, ttl=30):
    """Disk use of a folder (allocated blocks: a qcow2 is sparse), cached for ttl seconds: the page polls."""
    now = time.time()
    with _sizes_lock:
        hit = _sizes.get(path)
        if hit and now - hit[0] < ttl:
            return hit[1]
    total = 0
    for top, dirs, files in os.walk(path):
        for f in files:
            try:
                total += os.lstat(os.path.join(top, f)).st_blocks // 2
            except OSError:
                pass
    with _sizes_lock:
        _sizes[path] = (now, total)
    return total


_chains = {}


def chain(image, running=False):
    """The image files under a qcow2 (itself first), or None when one is missing. A checkpoint's chain is cached by its
    mtime (it never changes); a running VM's disk is read with -U (QEMU holds its lock)."""
    key = (image, mtime(image))
    if not running and key in _chains:
        return _chains[key]
    cmd = ["qemu-img", "info", "--backing-chain", "--output=json"] + (["-U"] if running else []) + [image]
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        files = [os.path.realpath(i.get("filename")) for i in json.loads(p.stdout)] if p.returncode == 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        files = None
    if not running:
        _chains[key] = files
    return files


def homes():
    """Guest OS image folders under the root: <root>/<os>/ with a golden image or slots."""
    out = []
    for h in sorted(glob.glob(os.path.join(ARGS.root, "*", ""))):
        h = h.rstrip("/")
        if os.path.exists(os.path.join(h, "base.qcow2")) or os.path.isdir(os.path.join(h, "slots")):
            out.append(h)
    return out


def rel(path):
    return os.path.relpath(path, ARGS.root)


def last_used(d):
    """The newest file at a VM folder's top, in app/ or vm/: its last build, test, screenshot or boot."""
    t = mtime(os.path.join(d, "guest.conf"))
    for sub in ("", "app", "vm"):
        try:
            with os.scandir(os.path.join(d, sub)) as it:
                for e in it:
                    if e.is_file(follow_symlinks=False):
                        t = max(t, e.stat(follow_symlinks=False).st_mtime)
        except OSError:
            pass
    return t


def folder(d):
    c = conf(os.path.join(d, "guest.conf"))
    vm = os.path.join(d, "vm")
    running = pid_alive(os.path.join(vm, "qemu.pid"))
    image = c.get("VM_IMAGE") or "base.qcow2"
    image_path = os.path.join(c.get("VM_HOME") or "", image)
    wt = c.get("WORKTREE") or ""
    app = os.path.join(d, "app")
    videos = sorted(glob.glob(os.path.join(app, "video-*.mp4")), key=mtime)
    shots = sorted(glob.glob(os.path.join(app, "shot-*.png")), key=mtime)
    used = last_used(d)
    kept_disk = not running and os.path.exists(os.path.join(vm, "disk.qcow2"))
    stale = []
    if not running:
        if wt and not os.path.isdir(wt):
            stale.append("worktree gone")
        if not os.path.exists(image_path):
            stale.append("checkpoint gone" if image.startswith("checkpoints/") else "image gone")
        if time.time() - used > STALE_DAYS * 86400:
            stale.append(f"unused {int((time.time() - used) // 86400)}d")
    busy = any(pid_alive_name(u) for u in glob.glob(os.path.join(d, "lease.users", "*")))
    return {
        "id": rel(d), "group": os.path.basename(os.path.dirname(d)), "name": os.path.basename(d),
        "title": c.get("VM_TITLE") or "", "product": c.get("PRODUCT") or "", "app": c.get("APP_NAME") or "",
        "worktree": wt, "worktree_ok": bool(wt) and os.path.isdir(wt),
        "image": image, "image_ok": os.path.exists(image_path),
        "checkpoint": image[len("checkpoints/"):-len(".qcow2")] if image.startswith("checkpoints/") else None,
        "running": running, "keep": os.path.exists(os.path.join(d, "keep")), "busy": busy,
        "recording": pid_alive(os.path.join(vm, "record.pid")),
        "last_used": used, "kb": du_kb(d), "kept_disk_kb": blocks_kb(os.path.join(vm, "disk.qcow2")) if kept_disk else 0,
        "videos": [{"path": rel(v), "kb": blocks_kb(v), "t": mtime(v)} for v in videos],
        "shots": len(shots), "last_shot": rel(shots[-1]) if shots else None,
        "stale": stale,
    }


def pid_alive_name(path):
    try:
        os.kill(int(os.path.basename(path)), 0)
        return True
    except (OSError, ValueError):
        return False


def state():
    hs = homes()
    slots, running_chains = [], {}
    for h in hs:
        for s in sorted(glob.glob(os.path.join(h, "slots", "*"))):
            vm = (read(os.path.join(s, "vm")) or "").strip()
            if not vm:
                continue
            alive = pid_alive(os.path.join(vm, "qemu.pid"))
            run = os.path.dirname(vm)
            env = read(os.path.join(vm, "vm.env")) or ""
            m = re.search(r"VM_VNC_PORT=(\d+)", env)
            starting = bool(glob.glob(os.path.join(s, "starting")))
            if alive:
                running_chains[run] = chain(os.path.join(vm, "disk.qcow2"), running=True) or []
            c = conf(os.path.join(run, "guest.conf"))
            slots.append({
                "os": os.path.basename(h), "slot": os.path.basename(s), "id": rel(run), "alive": alive, "starting": starting,
                "title": c.get("VM_TITLE") or rel(run), "product": c.get("PRODUCT") or "",
                "since": mtime(os.path.join(vm, "qemu.pid")) if alive else None, "vnc": m.group(1) if m else None,
                "keep": os.path.exists(os.path.join(run, "keep")),
                "recording": pid_alive(os.path.join(vm, "record.pid")),
                "managed": os.path.exists(os.path.join(run, "guest.conf")),
            })

    home_set = set(hs)
    folders = []
    for g in glob.glob(os.path.join(ARGS.root, "*", "*", "guest.conf")):
        d = os.path.dirname(g)
        if os.path.dirname(d) in home_set:
            continue
        folders.append(folder(d))
    folders.sort(key=lambda f: f["last_used"], reverse=True)

    checkpoints, images = [], []
    for h in hs:
        cks = sorted(glob.glob(os.path.join(h, "checkpoints", "*.qcow2")))
        ck_chains = {c: chain(c) for c in cks}
        for c in cks:
            n = os.path.basename(c)[:-len(".qcow2")]
            meta = conf(c[:-len(".qcow2")] + ".conf")
            users = [rel(r) for r, ch in running_chains.items() if c in ch]
            built_on = [os.path.basename(o)[:-6] for o, ch in ck_chains.items() if o != c and ch and c in ch]
            booting = [f["id"] for f in folders if f["checkpoint"] == n and not f["running"]]
            wt = meta.get("WORKTREE") or ""
            try:
                created = int(meta.get("CREATED") or 0)
            except ValueError:
                created = 0
            checkpoints.append({
                "name": n, "os": os.path.basename(h), "kb": blocks_kb(c), "created": created or mtime(c),
                "product": meta.get("PRODUCT") or "", "branch": meta.get("BRANCH") or "", "note": meta.get("NOTE") or "",
                "worktree": wt, "worktree_ok": bool(wt) and os.path.isdir(wt), "from_image": meta.get("FROM_IMAGE") or "",
                "broken": ck_chains[c] is None, "running_users": users, "built_on": built_on, "booting": booting,
            })
        for img in sorted(glob.glob(os.path.join(h, "*.qcow2"))):
            images.append({"name": os.path.basename(img), "os": os.path.basename(h), "kb": blocks_kb(img),
                           "readonly": not os.access(img, os.W_OK), "t": mtime(img)})

    runs = [{"os": os.path.basename(h), "count": len(glob.glob(os.path.join(h, "runs", "*"))),
             "kb": du_kb(os.path.join(h, "runs"), ttl=300)} for h in hs if os.path.isdir(os.path.join(h, "runs"))]
    du = shutil.disk_usage(ARGS.root)
    return {
        "root": ARGS.root, "version": VERSION, "scripts": SCRIPTS, "now": time.time(), "stale_days": STALE_DAYS,
        "disk": {"free": du.free, "total": du.total},
        "slots": slots, "folders": folders, "checkpoints": checkpoints, "images": images, "factory_runs": runs,
    }


def run(cmd, env=None):
    p = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env, timeout=900)
    return p.returncode, (p.stdout + p.stderr).strip()


def vm_folder(id_):
    """A VM folder or run dir under the root, by its id (its path from the root); None for anything else."""
    path = safe_join(ARGS.root, id_)
    return path if path and os.path.isdir(path) else None


def home_of_run(d):
    """The guest OS home whose slots hold this run dir's VM (a VM with no guest.conf: a factory run's)."""
    for h in homes():
        for s in glob.glob(os.path.join(h, "slots", "*", "vm")):
            if os.path.dirname((read(s) or "").strip()) == d:
                return h
    return None


def action(op, ids):
    vmctl = os.path.join(os.path.dirname(ARGS.vmt), "vm", "vmctl.sh")
    if op == "gc":
        return run([ARGS.vmt, "gc"])
    if op == "ck-rm":
        if not ids or not all(re.fullmatch(r"[a-z0-9][a-z0-9-]*", n or "") for n in ids):
            return 2, "bad checkpoint names"
        return run([ARGS.vmt, "checkpoint", "rm"] + ids)
    dirs = [vm_folder(i) for i in ids]
    if not ids or None in dirs:
        return 2, "no such VM folder"
    if op == "rm":
        return run([ARGS.vmt, "rm"] + dirs)
    if op in ("down", "show") and len(dirs) == 1:
        d = dirs[0]
        if os.path.exists(os.path.join(d, "guest.conf")):
            return run([ARGS.vmt, op, d])
        # Not a vmt folder (a factory run's VM): vmctl.sh directly, with its guest OS home.
        h = home_of_run(d)
        if not h:
            return 2, "no slot holds this VM"
        return run([vmctl, op, d], env=dict(os.environ, VM_HOME=h))
    return 2, f"unknown action {op}"


def safe_join(root, rel_):
    path = os.path.realpath(os.path.join(root, rel_))
    return path if path.startswith(os.path.realpath(root) + os.sep) else None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json", headers=()):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def send_file(self, path):
        # Safari plays a video only from a server that answers byte ranges.
        size = os.path.getsize(path)
        ctype = mimetypes.guess_type(path)[0] or "text/plain; charset=utf-8"
        m = re.match(r"bytes=(\d*)-(\d*)$", self.headers.get("Range") or "")
        with open(path, "rb") as f:
            if not m or (not m.group(1) and not m.group(2)):
                return self.send(200, f.read(), ctype, [("Accept-Ranges", "bytes")])
            if m.group(1):
                start, end = int(m.group(1)), int(m.group(2) or size - 1)
            else:
                start, end = max(0, size - int(m.group(2))), size - 1
            end = min(end, size - 1)
            if start > end:
                return self.send(416, b"", ctype, [("Content-Range", f"bytes */{size}")])
            f.seek(start)
            return self.send(206, f.read(end - start + 1), ctype,
                             [("Accept-Ranges", "bytes"), ("Content-Range", f"bytes {start}-{end}/{size}")])

    def do_GET(self):
        parts = [unquote(p) for p in urlparse(self.path).path.strip("/").split("/") if p]
        try:
            if not parts:
                with open(os.path.join(HERE, "index.html"), "rb") as f:
                    return self.send(200, f.read(), "text/html; charset=utf-8")
            if parts == ["api", "whoami"]:
                # vmt dashboard asks before starting one: this copy's dashboard is already up, or the port is another's.
                return self.send(200, {"app": "vm-toolkit", "scripts": SCRIPTS, "root": ARGS.root, "version": VERSION})
            if parts == ["api", "state"]:
                return self.send(200, state())
            if len(parts) >= 2 and parts[0] == "file":
                path = safe_join(ARGS.root, "/".join(parts[1:]))
                if not path or not os.path.isfile(path) or not re.search(r"\.(png|mp4|log)$", path):
                    return self.send(404, {"error": "no such file"})
                return self.send_file(path)
            return self.send(404, {"error": "not found"})
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        # Only the dashboard page itself: the custom header makes another site's request need a CORS preflight, which
        # this server never grants, and the Host check keeps out a DNS-rebound name pointing at 127.0.0.1.
        host = (self.headers.get("Host") or "").split(":")[0]
        if self.headers.get("X-VM-Dashboard") != "1" or host not in ("127.0.0.1", "localhost", "vms.localhost"):
            return self.send(403, {"error": "forbidden"})
        if urlparse(self.path).path != "/api/action":
            return self.send(404, {"error": "not found"})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
            ids = body.get("ids") or []
            if not isinstance(ids, list) or not all(isinstance(i, str) for i in ids):
                raise ValueError
        except ValueError:
            return self.send(400, {"error": "bad request"})
        try:
            rc, out = action(body.get("op"), ids)
        except subprocess.TimeoutExpired:
            rc, out = 3, "vmt did not answer in 15 min"
        with _sizes_lock:
            _sizes.clear()
        return self.send(200, {"ok": rc == 0, "rc": rc, "out": out})


def main():
    global ARGS
    p = argparse.ArgumentParser()
    p.add_argument("--vmt", required=True)
    p.add_argument("--root", required=True)
    p.add_argument("--port", type=int, default=8766)
    ARGS = p.parse_args()
    ARGS.root = os.path.realpath(ARGS.root)
    try:
        server = ThreadingHTTPServer(("127.0.0.1", ARGS.port), Handler)
    except OSError as e:
        raise SystemExit(f"vm dashboard: port {ARGS.port} is not free ({e.strerror})")
    print(f"vm dashboard: http://vms.localhost:{ARGS.port}/ (VM root {ARGS.root})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
