"""A VNC (RFB 3.8) client that stands in for QEMU's QMP where a VM has no QMP: tart's macOS VMs, whose screen and input
are Virtualization.framework's own VNC server (tart run --vnc-experimental, on 127.0.0.1 with a password).

Vnc(port, password) answers the few QMP commands vm.py and record.py send: screendump (PNG or PPM) and
input-send-event (QMP's abs, btn and key events, with QEMU's key names). Standard library only.
"""
import socket
import struct
import subprocess
import zlib

# QEMU qcodes (vm.py's key names) to X11 keysyms, which RFB sends.
KEYSYMS = {
    'ret': 0xff0d, 'kp_enter': 0xff8d, 'esc': 0xff1b, 'tab': 0xff09, 'backspace': 0xff08, 'delete': 0xffff,
    'insert': 0xff63, 'home': 0xff50, 'end': 0xff57, 'pgup': 0xff55, 'pgdn': 0xff56,
    'left': 0xff51, 'up': 0xff52, 'right': 0xff53, 'down': 0xff54, 'spc': 0x20,
    'shift': 0xffe1, 'shift_r': 0xffe2, 'ctrl': 0xffe3, 'ctrl_r': 0xffe4,
    # Apple's VNC server (Virtualization.framework) reads Alt as Command and Meta as Option, and ignores Super (checked
    # on macOS 26: Alt_L-q quits, Meta_L-g types ©). vm.py's names keep their Mac meaning: alt is Option; cmd, and
    # meta_l (vm.py's win), are Command.
    'alt': 0xffe7, 'alt_r': 0xffe8, 'meta_l': 0xffe9, 'meta_r': 0xffea, 'cmd': 0xffe9,
    'minus': ord('-'), 'equal': ord('='), 'bracket_left': ord('['), 'bracket_right': ord(']'),
    'backslash': ord('\\'), 'semicolon': ord(';'), 'apostrophe': ord("'"), 'comma': ord(','), 'dot': ord('.'),
    'slash': ord('/'), 'grave_accent': ord('`'),
}
KEYSYMS.update({f'f{i}': 0xffbe + i - 1 for i in range(1, 13)})
BUTTONS = {'left': 1, 'middle': 2, 'right': 4, 'wheel-up': 8, 'wheel-down': 16}


def keysym(qcode):
    if qcode in KEYSYMS:
        return KEYSYMS[qcode]
    if len(qcode) == 1:
        return ord(qcode)
    raise ValueError(f"no key {qcode!r}")


def vnc_response(password, challenge):
    """VNC authentication: the challenge DES-encrypted under the password (8 bytes, each byte's bits reversed)."""
    key = bytes(int(f"{b:08b}"[::-1], 2) for b in password.encode()[:8].ljust(8, b"\0"))
    return subprocess.run(["/usr/bin/openssl", "enc", "-des-ecb", "-nopad", "-K", key.hex()],
                          input=challenge, capture_output=True, check=True).stdout


class Vnc:
    def __init__(self, port, password, host="127.0.0.1"):
        self.s = socket.create_connection((host, port), timeout=30)
        self.s.recv(12)  # the server's version
        self.s.sendall(b"RFB 003.008\n")
        types = self.read(self.u8())
        if not types:
            raise RuntimeError("VNC: " + self.read(self.u32()).decode(errors="replace"))
        if 2 in types:
            self.s.sendall(b"\x02")
            self.s.sendall(vnc_response(password, self.read(16)))
        elif 1 in types:
            self.s.sendall(b"\x01")
        else:
            raise RuntimeError(f"VNC: no security type this client speaks ({list(types)})")
        if self.u32() != 0:
            raise RuntimeError("VNC: authentication failed")
        self.s.sendall(b"\x01")  # shared: a person's viewer and the recorder stay connected
        self.w, self.h = struct.unpack(">HH", self.read(4))
        fmt = self.read(16)
        self.name = self.read(self.u32()).decode(errors="replace")
        # Ask for 32 bits a pixel, bytes R G B x; Apple's server keeps its own format whatever it is asked, so the bytes
        # each colour is in come from the format it announced, unless it is not a 32-bit true-colour one.
        self.s.sendall(struct.pack(">B3xBBBBHHHBBB3x", 0, 32, 24, 0, 1, 255, 255, 255, 0, 8, 16))
        bpp, _, big, true, _, _, _, rs, gs, bs = struct.unpack(">BBBBHHHBBB", fmt[:13])
        self.order = (0, 1, 2)
        if bpp == 32 and true and all(x % 8 == 0 for x in (rs, gs, bs)):
            self.order = tuple(3 - x // 8 if big else x // 8 for x in (rs, gs, bs))
        # Raw, and DesktopSize (the guest changing its resolution)
        self.s.sendall(struct.pack(">BxHii", 2, 2, 0, -223))
        self.fb = bytearray(self.w * self.h * 4)
        self.mask = 0
        self.x = self.y = 0
        self.full = False

    def read(self, n):
        buf = bytearray()
        while len(buf) < n:
            chunk = self.s.recv(n - len(buf))
            if not chunk:
                raise OSError("VNC: connection closed")
            buf += chunk
        return bytes(buf)

    def u8(self):
        return self.read(1)[0]

    def u32(self):
        return struct.unpack(">I", self.read(4))[0]

    def update(self):
        """Bring the framebuffer up to date: the whole screen the first time, then what changed."""
        self.s.sendall(struct.pack(">BBHHHH", 3, 1 if self.full else 0, 0, 0, self.w, self.h))
        while True:
            t = self.u8()
            if t == 0:
                self.read(1)
                resized = False
                for _ in range(struct.unpack(">H", self.read(2))[0]):
                    x, y, w, h, enc = struct.unpack(">HHHHi", self.read(12))
                    if enc == 0:
                        data, row = self.read(w * h * 4), self.w * 4
                        for r in range(h):
                            o = (y + r) * row + x * 4
                            self.fb[o:o + w * 4] = data[r * w * 4:(r + 1) * w * 4]
                    elif enc == -223:
                        self.w, self.h = w, h
                        self.fb = bytearray(w * h * 4)
                        resized = True
                    else:
                        raise RuntimeError(f"VNC: unexpected encoding {enc}")
                if not resized:
                    self.full = True
                    return
                # A new size: the whole screen again
                self.full = False
                self.s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, self.w, self.h))
            elif t == 1:  # colour map: never with true colour
                self.read(3)
                self.read(6 * struct.unpack(">H", self.read(2))[0])
            elif t == 2:  # bell
                pass
            elif t == 3:  # the guest's clipboard
                self.read(3)
                self.read(self.u32())
            else:
                raise RuntimeError(f"VNC: unexpected message {t}")

    def rgb(self):
        out = bytearray(self.w * self.h * 3)
        r, g, b = self.order
        out[0::3], out[1::3], out[2::3] = self.fb[r::4], self.fb[g::4], self.fb[b::4]
        return out

    def ppm(self):
        return b"P6\n%d %d\n255\n" % (self.w, self.h) + self.rgb()

    def png(self):
        rgb, row = self.rgb(), self.w * 3
        raw = b"".join(b"\0" + rgb[i:i + row] for i in range(0, len(rgb), row))

        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))

    def pointer(self):
        self.s.sendall(struct.pack(">BBHH", 5, self.mask, self.x, self.y))

    # The QMP commands vm.py and record.py send.
    def cmd(self, name, args=None):
        if name == "screendump":
            self.update()
            with open(args["filename"], "wb") as fh:
                fh.write(self.ppm() if args.get("format") == "ppm" else self.png())
            return {}
        if name == "input-send-event":
            self.events(args["events"])
            return {}
        raise RuntimeError(f"{name}: not on a VNC-driven VM")

    def events(self, evs):
        moved = False
        for ev in evs:
            d = ev["data"]
            if ev["type"] == "abs":
                # vm.py scales screenshot pixels to QEMU's 0-32767 tablet range: back to pixels
                if d["axis"] == "x":
                    self.x = round(d["value"] * (self.w - 1) / 32767)
                else:
                    self.y = round(d["value"] * (self.h - 1) / 32767)
                moved = True
            elif ev["type"] == "btn":
                bit = BUTTONS[d["button"]]
                self.mask = self.mask | bit if d["down"] else self.mask & ~bit
                self.pointer()
                moved = False
            elif ev["type"] == "key":
                self.s.sendall(struct.pack(">BBxxI", 4, 1 if d["down"] else 0, keysym(d["key"]["data"])))
        if moved:
            self.pointer()
