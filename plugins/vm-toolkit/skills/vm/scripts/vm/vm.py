#!/usr/bin/env python3
"""Drive the QEMU VM through QMP: screenshots, absolute mouse, keyboard.

  vm.py shot OUT.png              screenshot (PNG)
  vm.py click X Y [right|double]  click at screenshot pixel X,Y
  vm.py move X Y
  vm.py type TEXT                 type text (US layout)
  vm.py key COMBO [COMBO...]      e.g. ctrl-n  ret  esc  tab  alt-f4  meta_l
  vm.py scroll X Y N              wheel at X,Y; N>0 down, N<0 up
  vm.py wait-ssh [SECONDS]        block until the guest's sshd answers (default 300 s)
  vm.py qmp COMMAND [JSON-ARGS]    raw QMP command (vmctl.sh: quit, change-vnc-password)
  vm.py sleep SECONDS             pause (the shell's own sleep may be blocked)

Which VM: QMP_SOCK, VM_SSH_PORT and VM_RUN_DIR (set by vmctl.sh env <run dir>); without them, a golden/start.sh
VM (QMP socket in VM_HOME, port 2222).
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
# Per VM, never next to this script: the skill folder is versioned (and read-only once installed as a plugin).
SIZE_CACHE = os.path.join(os.environ.get("VM_RUN_DIR") or VM_HOME, ".screen-size")
# While record.py records: its start time and the events file captions and clicks go to.
RECORDING = os.path.join(os.environ.get("VM_RUN_DIR") or VM_HOME, "recording")


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
            with socket.create_connection(("127.0.0.1", SSH_PORT), timeout=3) as s:
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
    q = Qmp()
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
        q.events(abs_events(q, x, y))
        pause(0.08)
        if op == "click":
            add_event({"click": [x, y]})
            button = "right" if mode == "right" else "left"
            for _ in range(2 if mode == "double" else 1):
                q.events([btn(button, True)])
                pause(0.05)
                q.events([btn(button, False)])
                pause(0.08)
    elif op == "scroll":
        x, y, n = int(a[0]), int(a[1]), int(a[2])
        q.events(abs_events(q, x, y))
        b = "wheel-down" if n > 0 else "wheel-up"
        for _ in range(abs(n)):
            q.events([btn(b, True)])
            q.events([btn(b, False)])
            pause(0.03)
    elif op == "type":
        for c in " ".join(a):
            mods, k = char_keys(c)
            press(q, mods, k)
    elif op == "key":
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
