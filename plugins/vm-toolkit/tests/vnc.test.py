#!/usr/bin/env python3
"""vnc.test.py: scripts/vm/vnc.py and vm.py on a VM driven over VNC (tart's macOS VMs), against a fake VNC server
(RFB 3.8, VNC authentication, raw frames). No VM.
  python3 tests/vnc.test.py
"""
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
VMDIR = os.path.join(HERE, "..", "skills", "vm", "scripts", "vm")
sys.path.insert(0, VMDIR)
import vnc  # noqa: E402

W, H, PASSWORD = 8, 4, "word-pass-more"
FAILS = []


def check(cond, what):
    print(("  ✓ " if cond else "  ✗ ") + what)
    if not cond:
        FAILS.append(what)


def read(c, n):
    buf = b""
    while len(buf) < n:
        chunk = c.recv(n - len(buf))
        if not chunk:
            raise OSError("closed")
        buf += chunk
    return buf


class FakeServer:
    """One client at a time: handshake, then it answers update requests with the screen (a red pixel at 1,1) and logs
    pointer and key events as (kind, values)."""

    def __init__(self):
        self.ls = socket.socket()
        self.ls.bind(("127.0.0.1", 0))
        self.ls.listen()
        self.port = self.ls.getsockname()[1]
        self.events = []
        self.updates = []
        self.hold = False  # True: a request for what changed waits, as on a still screen, until change()
        self.waiting = None
        threading.Thread(target=self.serve, daemon=True).start()

    @staticmethod
    def frame(c):
        px = bytearray(W * H * 4)
        px[(1 * W + 1) * 4:(1 * W + 1) * 4 + 3] = b"\x00\x00\xff"  # red, as B G R
        c.sendall(struct.pack(">BxH", 0, 1) + struct.pack(">HHHHi", 0, 0, W, H, 0) + bytes(px))

    def change(self):
        """The screen changes: the request waiting for it is answered."""
        self.hold, c, self.waiting = False, self.waiting, None
        if c:
            self.frame(c)

    def serve(self):
        while True:
            c, _ = self.ls.accept()
            threading.Thread(target=self.client, args=(c,), daemon=True).start()

    def client(self, c):
        try:
            c.sendall(b"RFB 003.008\n")
            read(c, 12)
            c.sendall(b"\x01\x02")
            read(c, 1)
            challenge = os.urandom(16)
            c.sendall(challenge)
            ok = read(c, 16) == vnc.vnc_response(PASSWORD, challenge)
            c.sendall(struct.pack(">I", 0 if ok else 1))
            if not ok:
                return
            read(c, 1)
            # Like Apple's server: its own format (32 bits, little-endian, blue in the low byte), whatever is asked
            fmt = struct.pack(">BBBBHHHBBB3x", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0)
            c.sendall(struct.pack(">HH", W, H) + fmt + struct.pack(">I", 4) + b"fake")
            while True:
                t = read(c, 1)[0]
                if t == 0:
                    read(c, 19)
                elif t == 2:
                    read(c, 1)
                    read(c, 4 * struct.unpack(">H", read(c, 2))[0])
                elif t == 3:
                    inc, x, y, w, h = struct.unpack(">BHHHH", read(c, 9))
                    self.updates.append(inc)
                    if inc and self.hold:
                        self.waiting = c
                    else:
                        self.frame(c)
                elif t == 4:
                    down, sym = struct.unpack(">BxxI", read(c, 7))
                    self.events.append(("key", down, sym))
                elif t == 5:
                    self.events.append(("ptr",) + struct.unpack(">BHH", read(c, 5)))
        except OSError:
            pass


srv = FakeServer()
tmp = tempfile.mkdtemp()

print("vnc.py")
v = vnc.Vnc(srv.port, PASSWORD)
check((v.w, v.h, v.name) == (W, H, "fake"), "authenticates and reads the screen's size")
png = os.path.join(tmp, "s.png")
v.cmd("screendump", {"filename": png, "format": "png"})
data = open(png, "rb").read()
check(data[:8] == b"\x89PNG\r\n\x1a\n" and struct.unpack(">II", data[16:24]) == (W, H), "screendump writes a PNG")
v.cmd("screendump", {"filename": png + ".ppm", "format": "ppm"})
ppm = open(png + ".ppm", "rb").read()
check(ppm.startswith(b"P6\n8 4\n255\n") and ppm[-W * H * 3:][(W + 1) * 3:(W + 1) * 3 + 3] == b"\xff\x00\x00",
      "screendump writes a PPM in RGB, from the server's own pixel format")
check(srv.updates == [0, 1], "the first update asks for the whole screen, later ones for what changed")
srv.hold = True
t = time.monotonic()
check(v.update(0.2) is False and 0.15 < time.monotonic() - t < 1, "a still screen: no answer within the wait is False")
check(v.update(0) is False and srv.updates == [0, 1, 1], "the request stays pending: the next wait sends no other")
srv.change()
check(v.update(1) is True and srv.updates == [0, 1, 1], "the screen changes: the pending request's answer is True")
check(v.update(1) is True and srv.updates == [0, 1, 1, 1], "then a new request")
try:
    vnc.Vnc(srv.port, "wrong")
    check(False, "a wrong password fails")
except RuntimeError as e:
    check("authentication failed" in str(e), "a wrong password fails")

print("vm.py over VNC")
pw = os.path.join(tmp, "vnc.pass")
open(pw, "w").write(PASSWORD + "\n")
env = dict(os.environ, VM_VNC_PASS_FILE=pw, VM_VNC_PORT=str(srv.port), VM_RUN_DIR=tmp)
env.pop("QMP_SOCK", None)


def vmpy(*args):
    srv.events.clear()
    r = subprocess.run([sys.executable, os.path.join(VMDIR, "vm.py"), *args], env=env, capture_output=True, text=True)
    time.sleep(0.2)
    return r


r = vmpy("shot", os.path.join(tmp, "a.png"))
check(r.returncode == 0 and r.stdout.strip().endswith(f"{W}x{H}"), "shot: " + (r.stdout + r.stderr).strip())
vmpy("click", "7", "3", "right")
check(srv.events == [("ptr", 0, 7, 3), ("ptr", 4, 7, 3), ("ptr", 0, 7, 3)],
      f"a right click lands on the screenshot's pixel: {srv.events}")
vmpy("click", "2", "1", "double")
check([e[1] for e in srv.events] == [0, 1, 0, 1, 0] and all(e[2:] == (2, 1) for e in srv.events),
      f"a double click is two clicks: {srv.events}")
vmpy("key", "cmd-q")
check(srv.events == [("key", 1, 0xffe9), ("key", 1, ord("q")), ("key", 0, ord("q")), ("key", 0, 0xffe9)],
      f"cmd-q is Command (Alt, to Apple's server) and q: {srv.events}")
vmpy("type", "A!")
syms = [e[2] for e in srv.events if e[1] == 1]
check(syms == [0xffe1, ord("a"), 0xffe1, ord("1")], f"typing shifts capitals and symbols: {syms}")
vmpy("scroll", "4", "2", "-2")
check([e[1] for e in srv.events] == [0, 8, 0, 8, 0], f"scroll up is wheel button 4: {srv.events}")
vmpy("drag", "1", "1", "6", "3")
masks = [e[1] for e in srv.events]
held = [e[2:] for e in srv.events if e[1] == 1]
check(srv.events[0] == ("ptr", 0, 1, 1) and masks[-1] == 0 and srv.events[-1][2:] == (6, 3)
      and held[0] == (1, 1) and held[-1] == (6, 3) and len(held) > 3,
      f"a drag presses at its start, moves held down, and releases at its end: {srv.events}")

print("vnc: all passed" if not FAILS else f"vnc: {len(FAILS)} failed")
sys.exit(1 if FAILS else 0)
