#!/usr/bin/env python3
"""Drive the QEMU VM through QMP: screenshots, absolute mouse, keyboard.

  vm.py shot OUT.png              screenshot (PNG)
  vm.py click X Y [right|double]  click at screenshot pixel X,Y
  vm.py move X Y
  vm.py drag X1 Y1 X2 Y2          press at X1,Y1, move to X2,Y2 as a hand would, release (a tree's drag and drop)
  vm.py type TEXT                 type text (US layout)
  vm.py key COMBO [COMBO...]      e.g. ctrl-n  ret  esc  tab  alt-f4  meta_l
  vm.py scroll X Y N              wheel at X,Y; N>0 down, N<0 up
  vm.py wait-ssh [SECONDS]        block until the guest's sshd answers (default 300 s)
  vm.py qmp COMMAND [JSON-ARGS]    raw QMP command (vmctl.sh: quit, change-vnc-password)
  vm.py sleep SECONDS             pause (the shell's own sleep may be blocked)

Which VM: QMP_SOCK, VM_SSH_PORT and VM_RUN_DIR (set by vmctl.sh env <run dir>); without them, a golden/start.sh
VM (QMP socket in VM_HOME, port 2222). A VM with no QMP (tart's macOS VMs: VM_VNC_PASS_FILE, VM_VNC_PORT and
VM_SSH_HOST set by tartctl.sh env) is driven over its VNC server instead (vnc.py).
"""
import json
import os
import socket
import struct
import sys
import time

VM_HOME = os.environ.get("VM_HOME") or os.environ.get("FACTORY_VM_HOME") or os.path.expanduser("~/VMs/factory/windows")
SOCK = os.environ.get("QMP_SOCK") or os.path.join(VM_HOME, "qmp.sock")
SSH_PORT = int(os.environ.get("VM_SSH_PORT") or 2222)
SSH_HOST = os.environ.get("VM_SSH_HOST") or "127.0.0.1"
VNC_PASS_FILE = os.environ.get("VM_VNC_PASS_FILE")
# Per VM, never next to this script: the skill folder is versioned (and read-only once installed as a plugin).
SIZE_CACHE = os.path.join(os.environ.get("VM_RUN_DIR") or VM_HOME, ".screen-size")
# While record.py records: its start time and the events file captions and clicks go to.
RECORDING = os.path.join(os.environ.get("VM_RUN_DIR") or VM_HOME, "recording")
# Where the pointer was last put, so a recorded click glides there from it.
CURSOR = os.path.join(os.environ.get("VM_RUN_DIR") or VM_HOME, ".cursor")
GLIDE_S = 0.5
DRAG_S = 0.8  # a drag's move, start to drop


class Qmp:
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(SOCK)
        self.f = self.s.makefile("rw")
        self.f.readline()
        self.cmd("qmp_capabilities")

    def cmd(self, name, args=None):
        msg = {"execute": name}
        if args is not None:
            msg["arguments"] = args
        self.f.write(json.dumps(msg) + "\n")
        self.f.flush()
        while True:
            r = json.loads(self.f.readline())
            if "return" in r:
                return r["return"]
            if "error" in r:
                raise RuntimeError(r["error"])

    def events(self, evs):
        self.cmd("input-send-event", {"events": evs})


def connect():
    """The VM's control channel: QMP, or the VNC server of a VM that has no QMP (vnc.py answers the same commands)."""
    if VNC_PASS_FILE:
        import vnc
        return vnc.Vnc(int(os.environ["VM_VNC_PORT"]), open(VNC_PASS_FILE).read().strip())
    return Qmp()


def png_size(path):
    with open(path, "rb") as fh:
        head = fh.read(24)
    return struct.unpack(">II", head[16:24])


def screen_size(q):
    if os.path.exists(SIZE_CACHE):
        w, h = open(SIZE_CACHE).read().split()
        return int(w), int(h)
    tmp = SIZE_CACHE + ".png"
    q.cmd("screendump", {"filename": tmp, "format": "png"})
    w, h = png_size(tmp)
    os.remove(tmp)
    return w, h


def add_event(ev):
    """Note an event (a click, a caption) on the running recording, timed from its start; False when none runs."""
    try:
        start, events = open(RECORDING).read().split("\n", 1)
    except OSError:
        return False
    ev["t"] = round(time.time() - float(start), 2)
    with open(events.strip(), "a") as fh:
        fh.write(json.dumps(ev) + "\n")
    return True


def abs_events(q, x, y):
    w, h = screen_size(q)
    ax = round(x * 32767 / max(w - 1, 1))
    ay = round(y * 32767 / max(h - 1, 1))
    return [{"type": "abs", "data": {"axis": "x", "value": ax}},
            {"type": "abs", "data": {"axis": "y", "value": ay}}]


def path(q, x0, y0, x, y, seconds, steps=24):
    """The pointer from (x0, y0) to (x, y) in seconds, eased: starts and lands slowly."""
    for i in range(1, steps):
        f = i / steps
        f = f * f * (3 - 2 * f)  # smoothstep
        q.events(abs_events(q, round(x0 + (x - x0) * f), round(y0 + (y - y0) * f)))
        pause(seconds / steps)
    q.events(abs_events(q, x, y))


def glide(q, x, y):
    """Move the pointer to (x, y): while recording, along an eased path from where it was, as a hand would (a pointer
    that jumps reads as a robot in a demo); else at once."""
    try:
        x0, y0 = map(int, open(CURSOR).read().split())
    except (OSError, ValueError):
        x0, y0 = x, y
    if os.path.exists(RECORDING) and (x0, y0) != (x, y):
        path(q, x0, y0, x, y, GLIDE_S)
        pause(0.15)  # the beat before the click
    else:
        q.events(abs_events(q, x, y))
    with open(CURSOR, "w") as fh:
        fh.write(f"{x} {y}")


def btn(button, down):
    return {"type": "btn", "data": {"down": down, "button": button}}


def key(qcode, down):
    return {"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": qcode}}}


def pause(seconds):
    end = time.time() + seconds
    while time.time() < end:
        time.sleep(0.01)


SHIFTED = {'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7', '*': '8', '(': '9', ')': '0',
           '_': 'minus', '+': 'equal', '{': 'bracket_left', '}': 'bracket_right', '|': 'backslash',
           ':': 'semicolon', '"': 'apostrophe', '<': 'comma', '>': 'dot', '?': 'slash', '~': 'grave_accent'}
PLAIN = {' ': 'spc', '-': 'minus', '=': 'equal', '[': 'bracket_left', ']': 'bracket_right', '\\': 'backslash',
         ';': 'semicolon', "'": 'apostrophe', ',': 'comma', '.': 'dot', '/': 'slash', '`': 'grave_accent',
         '\n': 'ret', '\t': 'tab'}
MODS = {'ctrl': 'ctrl', 'shift': 'shift', 'alt': 'alt', 'win': 'meta_l'}


def char_keys(c):
    if c.isalpha():
        return (['shift'] if c.isupper() else []), c.lower()
    if c.isdigit():
        return [], c
    if c in PLAIN:
        return [], PLAIN[c]
    if c in SHIFTED:
        return ['shift'], SHIFTED[c]
    raise ValueError(f"no key for {c!r}")


def press(q, mods, k):
    q.events([key(m, True) for m in mods] + [key(k, True)])
    pause(0.03)
    q.events([key(k, False)] + [key(m, False) for m in reversed(mods)])
    pause(0.03)


def wait_ssh(timeout):
    start = time.time()
    while time.time() - start < timeout:
        try:
            with socket.create_connection((SSH_HOST, SSH_PORT), timeout=3) as s:
                s.settimeout(5)
                if s.recv(64).startswith(b"SSH-"):
                    print(f"sshd up after {time.time() - start:.0f}s")
                    return 0
        except OSError:
            pass
        pause(3)
    print(f"sshd not up after {timeout:.0f}s")
    return 1


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    op, a = sys.argv[1], sys.argv[2:]
    if op == "sleep":
        pause(float(a[0]))
        return 0
    if op == "wait-ssh":
        return wait_ssh(float(a[0]) if a else 300)
    q = connect()
    if op == "qmp":
        print(json.dumps(q.cmd(a[0], json.loads(a[1]) if len(a) > 1 else None)))
        return 0
    if op == "shot":
        out = os.path.abspath(a[0])
        q.cmd("screendump", {"filename": out, "format": "png"})
        w, h = png_size(out)
        with open(SIZE_CACHE, "w") as fh:
            fh.write(f"{w} {h}")
        print(f"{out} {w}x{h}")
    elif op in ("click", "move"):
        x, y = int(a[0]), int(a[1])
        mode = a[2] if len(a) > 2 else "left"
        if op == "click":
            add_event({"input": "click"})  # before the glide: it is part of the step, not of the wait for it
        glide(q, x, y)
        pause(0.08)
        if op == "click":
            add_event({"click": [x, y]})
            button = "right" if mode == "right" else "left"
            for _ in range(2 if mode == "double" else 1):
                q.events([btn(button, True)])
                pause(0.05)
                q.events([btn(button, False)])
                pause(0.08)
    elif op == "drag":
        if len(a) != 4:
            print(__doc__)
            return 1
        x1, y1, x2, y2 = (int(v) for v in a)
        add_event({"input": "drag"})
        glide(q, x1, y1)
        pause(0.08)
        add_event({"click": [x1, y1]})
        q.events([btn("left", True)])
        pause(0.3)  # held a moment before moving, or many lists take it for a click
        path(q, x1, y1, x2, y2, DRAG_S, steps=30)
        pause(0.5)  # over the target long enough for it to show it accepts the drop
        add_event({"click": [x2, y2]})
        q.events([btn("left", False)])
        with open(CURSOR, "w") as fh:
            fh.write(f"{x2} {y2}")
    elif op == "scroll":
        x, y, n = int(a[0]), int(a[1]), int(a[2])
        add_event({"input": "scroll"})
        glide(q, x, y)
        b = "wheel-down" if n > 0 else "wheel-up"
        for _ in range(abs(n)):
            q.events([btn(b, True)])
            q.events([btn(b, False)])
            pause(0.03)
    elif op == "type":
        add_event({"input": "type"})  # input is a step: a narrated recording keeps it (record.py)
        for c in " ".join(a):
            mods, k = char_keys(c)
            press(q, mods, k)
    elif op == "key":
        add_event({"input": "key"})
        for combo in a:
            parts = combo.split("-")
            mods = [MODS.get(p, p) for p in parts[:-1]]
            press(q, mods, MODS.get(parts[-1], parts[-1]))
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
