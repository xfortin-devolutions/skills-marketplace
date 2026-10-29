"""Factory dashboard: a local, read-only view of factory runs, refreshed live by the page.

Started by `factory.sh dashboard`. Reads the run folders the runner writes (events.log, runs.md, <session>.prompt /
.jsonl / .json / .time / .err, verify logs, QA reports and screenshots) and the QA agents' live folders under the VM
root, and serves them as JSON to index.html. Standard library only; listens on 127.0.0.1. Writes nothing.
"""

import argparse
import glob
import json
import mimetypes
import os
import re
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
ROLES = {"build": "builder", "review": "reviewer", "charter": "charter", "qa": "qa", "explore": "explorer",
         "recheck": "recheck"}
# Stations of one round, in the order the runner goes through them.
ROUND = ["build", "verify", "review", "charter", "qa", "explore", "recheck"]
TITLES = {"build": "Builder", "verify": "Verify", "review": "Reviewer", "charter": "Charter", "qa": "Runtime QA",
          "explore": "Exploratory QA", "recheck": "Base re-check", "test": "Acceptance test"}

ARGS = None


def read(path, limit=None):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return None
    return text[-limit:] if limit and len(text) > limit else text


def pid_alive(run):
    pid = read(os.path.join(run, "runner.pid"))
    if not pid:
        return None
    try:
        os.kill(int(pid.strip()), 0)
        return True
    except (OSError, ValueError):
        return False


def events(run):
    text = read(os.path.join(run, "events.log")) or ""
    out = []
    for line in text.splitlines():
        m = re.match(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) (.*)$", line)
        if m:
            out.append({"t": m.group(1), "msg": m.group(2)})
    return out


def rows(run):
    """runs.md table rows: {n, role, min, subtype, turns, cost, denials, outcome}."""
    out = []
    for line in (read(os.path.join(run, "runs.md")) or "").splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) != 8 or not cells[0].isdigit():
            continue
        out.append(dict(zip(["n", "role", "min", "subtype", "turns", "cost", "denials", "outcome"], cells)))
    return out


def as_float(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return 0.0


def run_kind(run_id):
    if re.search(r"-qa-\d{8}T", run_id):
        return "qa"
    if re.search(r"-test-\d{8}T", run_id):
        return "test"
    return "loop"


def ticket_of(run_id):
    m = re.match(r"^([a-z]+-\d+)", run_id)
    return m.group(1).upper() if m else run_id


def handback_status(run):
    m = re.search(r"^- Status: (.*)$", read(os.path.join(run, "loop-handback.md")) or "", re.M)
    return m.group(1) if m else None


def run_summary(run):
    run_id = os.path.basename(run)
    evs = events(run)
    ended = next((e for e in reversed(evs) if e["msg"].startswith("end: ")), None)
    alive = pid_alive(run)
    if ended:
        state = "done"
        status = handback_status(run) or ended["msg"][5:].split(" · spent")[0]
    elif alive is False:
        state, status = "dead", "the runner stopped without an end line"
    elif alive is None and evs and time.time() - os.path.getmtime(os.path.join(run, "events.log")) > 7200:
        state, status = "stale", "no end line and no activity for 2 h"
    else:
        state, status = "running", evs[-1]["msg"] if evs else "starting"
    if os.path.exists(os.path.join(run, "WAITING-FOR-HUMAN")):
        state = "waiting"
    spent = sum(as_float(r["cost"]) for r in rows(run))
    # A finished run's dot shows how it ended, not just that it ended.
    cls = "neutral" if status.startswith("stopped") else outcome_class(status)
    return {"id": run_id, "ticket": ticket_of(run_id), "kind": run_kind(run_id), "state": state, "status": status,
            "cls": cls,
            "started": evs[0]["t"] if evs else None, "updated": evs[-1]["t"] if evs else None,
            "spent": round(spent, 2)}


def stream_activity(path, limit=40):
    """The last steps of a session's stream: what the agent read, ran, edited or said."""
    text = read(path)
    if text is None:
        return None, None
    steps, cost, turns = [], None, 0
    for line in text.splitlines():
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if o.get("type") == "result":
            cost = o.get("total_cost_usd")
        if o.get("type") != "assistant":
            continue
        turns += 1
        for c in (o.get("message") or {}).get("content") or []:
            if c.get("type") == "tool_use":
                steps.append({"kind": "tool", "text": describe_tool(c.get("name"), c.get("input") or {})})
            elif c.get("type") == "text" and c.get("text", "").strip():
                steps.append({"kind": "text", "text": c["text"].strip()[:600]})
    return steps[-limit:], {"turns": turns, "cost": cost}


def describe_tool(name, inp):
    if name == "Bash":
        return "$ " + str(inp.get("command", ""))[:300]
    for key in ("file_path", "path", "pattern"):
        if key in inp:
            return f"{name} {inp[key]}"
    return f"{name} {json.dumps(inp)[:200]}"


def vm_dir(run_id, sub):
    """The live folder a QA agent writes its screenshots to, under the VM root."""
    hits = glob.glob(os.path.join(ARGS.vm_root, "*", "runs", run_id, sub))
    return hits[0] if hits else None


def pngs(folder):
    if not folder or not os.path.isdir(folder):
        return []
    return sorted(f for f in os.listdir(folder) if f.endswith(".png"))


def session_state(run, name):
    if os.path.exists(os.path.join(run, name + ".time")):
        return "done"
    if os.path.exists(os.path.join(run, name + ".jsonl")) or os.path.exists(os.path.join(run, name + ".prompt")):
        return "running"
    return None


def outcome_class(text):
    t = (text or "").lower()
    if not t:
        return "neutral"
    if re.search(r"\b(fail|red|send back|error|harness|not met|blocker)", t) and "verify green" not in t:
        return "bad"
    if re.search(r"needs-human|waiting|can't tell|disputed", t):
        return "warn"
    return "good"


def nodes(run):
    """The run's stations, round by round, with their state and one-line outcome."""
    rs = rows(run)
    evs = events(run)
    kind = run_kind(os.path.basename(run))
    by = {}
    for r in rs:
        by.setdefault((r["role"], r["n"]), r)
    out = []
    # A session the run never saw end (killed, or the runner died) is stopped, not working.
    over = any(e["msg"].startswith("end: ") for e in evs) or pid_alive(run) is False
    if kind == "test":
        test = read(os.path.join(run, "test.out"))
        end = next((e["msg"][5:] for e in evs if e["msg"].startswith("end: ")), None)
        out.append({"key": "test", "title": TITLES["test"], "round": 1, "state": "done" if end else "running",
                    "outcome": end or (evs[-1]["msg"] if evs else ""), "cls": outcome_class(end),
                    "has_detail": test is not None})
        return out
    rounds = set()
    for f in os.listdir(run):
        m = re.match(r"^(build|review|charter|qa|explore|recheck)-(\d+)\.(prompt|time|jsonl|json)$", f)
        if m:
            rounds.add(int(m.group(2)))
        m = re.match(r"^qa-(\d+)$", f)
        if m:
            rounds.add(int(m.group(1)))
    for n in sorted(rounds):
        for st in ROUND:
            name = f"{st}-{n}"
            if st == "verify":
                b = by.get(("builder", str(n)))
                if b:
                    v = re.search(r"verify (.*)$", b["outcome"])
                    text = v.group(1) if v else b["outcome"]
                    out.append(node(st, n, "done", text, "good" if text.startswith("green") else outcome_class(text)))
                elif session_state(run, f"build-{n}") == "done":
                    out.append(node(st, n, "stopped", "stopped: the run ended first", "neutral") if over
                               else node(st, n, "running", "building and testing in the build VM", "neutral"))
                continue
            state = session_state(run, name)
            if st == "qa" and state is None:
                prep = [e["msg"] for e in evs if e["msg"].startswith(f"qa-{n}:")]
                if prep:
                    last = prep[-1][len(f"qa-{n}: "):]
                    done = any(e["msg"].startswith(f"qa-{n}: ") and re.match(r"(PASS|FAIL|ERROR|NEEDS)", e["msg"][len(f"qa-{n}: "):]) for e in evs)
                    if not done and over:
                        out.append(node(st, n, "stopped", "stopped: the run ended first", "neutral"))
                    else:
                        out.append(node(st, n, "done" if done else "preparing", last, outcome_class(last) if done else "neutral"))
                continue
            if state is None:
                continue
            r = by.get((ROLES[st], str(n)))
            text = r["outcome"] if r else ""
            if not text and state == "done":
                text = last_event(evs, name) or ""
            if state == "running" and over:
                state, text = "stopped", "stopped: the run ended first"
            if not text and state == "running":
                text = "working"
            out.append(node(st, n, state, text, outcome_class(text) if r else "neutral",
                            cost=r["cost"] if r else None, minutes=r["min"] if r else None))
    return out


def last_event(evs, name):
    hits = [e["msg"] for e in evs if f" {name}" in " " + e["msg"] or e["msg"].startswith(name)]
    return hits[-1] if hits else None


def node(st, n, state, outcome, cls, cost=None, minutes=None):
    return {"key": f"{st}-{n}", "station": st, "title": TITLES[st], "round": n, "state": state, "outcome": outcome,
            "cls": cls, "cost": cost, "minutes": minutes}


def run_detail(run):
    s = run_summary(run)
    rm = read(os.path.join(run, "runs.md")) or ""
    header = next((l for l in rm.splitlines() if l.startswith(("Base:", "Ref:"))), "")
    s.update({"header": header, "nodes": nodes(run), "events": events(run)[-30:],
              "handback": read(os.path.join(run, "loop-handback.md")),
              "spec": os.path.exists(os.path.join(run, "spec"))})
    return s


def node_detail(run, key):
    run_id = os.path.basename(run)
    st, _, n = key.partition("-")
    d = {"key": key, "files": []}
    if st == "test":
        d["output"] = read(os.path.join(run, "test.out"), 20000)
        return d
    if st == "verify":
        d["output"] = read(os.path.join(run, f"verify-{n}.log"), 20000)
        for f in (f"verify-{n}-build.log", f"verify-{n}-test.log"):
            if os.path.exists(os.path.join(run, f)):
                d["files"].append(f"/file/run/{run_id}/{f}")
        return d
    d["prompt"] = read(os.path.join(run, f"{key}.prompt"), 20000)
    if st == "build":
        d["changes"] = worktree_changes(run)
    d["stderr"] = read(os.path.join(run, f"{key}.err"), 4000)
    steps, live = stream_activity(os.path.join(run, f"{key}.jsonl"))
    d["steps"], d["live"] = steps, live
    try:
        d["result"] = json.loads(read(os.path.join(run, f"{key}.json")) or "{}").get("result")
    except ValueError:
        d["result"] = None
    for extra in (f"{key}.md", f"charter-{n}.md"):
        if st in ("review", "charter") and os.path.exists(os.path.join(run, extra)) and extra.startswith(st):
            d["result"] = d["result"] or read(os.path.join(run, extra))
    if st in ("qa", "explore", "recheck"):
        sub = {"qa": f"qa-{n}", "explore": f"qa-{n}/explore", "recheck": f"qa-{n}/recheck"}[st]
        kept = os.path.join(run, sub)
        live_dir = vm_dir(run_id, {"qa": f"qa-{n}", "explore": f"explore-{n}", "recheck": f"recheck-{n}"}[st])
        report = read(os.path.join(kept, "report.md")) or (read(os.path.join(live_dir, "report.md")) if live_dir else None)
        d["report"] = report
        shots = pngs(kept)
        if shots:
            d["shots"] = [f"/file/run/{run_id}/{sub}/{p}" for p in shots]
        elif live_dir:
            d["shots"] = [f"/file/vm/{os.path.relpath(live_dir, ARGS.vm_root)}/{p}" for p in pngs(live_dir)]
    if st == "qa" and n == "1" and os.path.exists(os.path.join(run, "qa-1", "exploratory.md")):
        d["files"].append(f"/file/run/{run_id}/qa-1/exploratory.md")
    return d


def worktree_changes(run):
    """What the builder has done so far in its worktree: commits since the base, then uncommitted files."""
    evs = events(run)
    start = next((e["msg"] for e in evs if e["msg"].startswith(("loop start:", "loop resume:"))), "")
    m = re.search(r"base (\S+) worktree (\S+)", start) or re.search(r"\(worktree (\S+)\)", start)
    if not m:
        return None
    base, wt = (m.group(1), m.group(2)) if m.lastindex == 2 else (None, m.group(1))
    if not os.path.isabs(wt):
        wt = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(ARGS.runs))), wt)
    if not os.path.isdir(wt):
        return "(the run's worktree is gone)"

    def git(*a):
        try:
            return subprocess.run(["git", "-C", wt, *a], capture_output=True, text=True, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            return ""
    # The run's branch, not HEAD: a builder in the middle of its negative run has HEAD detached on the base.
    branch = next((l.split("branch: ")[1].split(" ")[0] for l in (read(os.path.join(run, "runs.md")) or "").splitlines()
                   if "branch: " in l), None)
    tip = branch or "HEAD"
    head = git("symbolic-ref", "-q", "--short", "HEAD").strip()
    note = ""
    if branch and head != branch:
        note = (f"Note: the worktree is not on {branch} right now (HEAD {git('rev-parse', '--short', 'HEAD').strip()}"
                f"{', detached' if not head else ', on ' + head}): the builder may be running its negative test.\n\n")
    log = git("log", "--oneline", "--no-decorate", f"{base}..{tip}") if base else git("log", "--oneline", "-5", tip)
    stat = git("diff", "--stat", base, tip, "--", ".", ":(exclude)handback") if base else ""
    dirty = git("status", "--short")
    return (f"{note}Commits on the branch since the base:\n{log or '  none yet'}\n\nCommitted changes:\n{stat or '  none'}\n"
            f"Uncommitted in the worktree:\n{dirty or '  nothing'}")


def safe_join(root, rel):
    path = os.path.realpath(os.path.join(root, rel))
    return path if path.startswith(os.path.realpath(root) + os.sep) else None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parts = [unquote(p) for p in urlparse(self.path).path.strip("/").split("/") if p]
        try:
            if not parts:
                with open(os.path.join(HERE, "index.html"), "rb") as f:
                    return self.send(200, f.read(), "text/html; charset=utf-8")
            if parts == ["api", "runs"]:
                runs = [r for r in glob.glob(os.path.join(ARGS.runs, "*")) if os.path.exists(os.path.join(r, "events.log"))]
                runs.sort(key=lambda r: os.path.getmtime(os.path.join(r, "events.log")), reverse=True)
                return self.send(200, [run_summary(r) for r in runs[:60]])
            if len(parts) >= 3 and parts[:2] == ["api", "run"]:
                run = safe_join(ARGS.runs, parts[2])
                if not run or not os.path.isdir(run):
                    return self.send(404, {"error": "no such run"})
                if len(parts) == 3:
                    return self.send(200, run_detail(run))
                if len(parts) == 5 and parts[3] == "node":
                    return self.send(200, node_detail(run, parts[4]))
            if len(parts) >= 4 and parts[0] == "file":
                root = os.path.join(ARGS.runs, parts[2]) if parts[1] == "run" else ARGS.vm_root
                rel = "/".join(parts[3:]) if parts[1] == "run" else "/".join(parts[2:])
                path = safe_join(root, rel)
                if not path or not os.path.isfile(path):
                    return self.send(404, {"error": "no such file"})
                with open(path, "rb") as f:
                    return self.send(200, f.read(), mimetypes.guess_type(path)[0] or "text/plain; charset=utf-8")
            return self.send(404, {"error": "not found"})
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    global ARGS
    p = argparse.ArgumentParser()
    p.add_argument("--runs", required=True)
    p.add_argument("--vm-root", required=True)
    p.add_argument("--port", type=int, default=8765)
    ARGS = p.parse_args()
    for port in range(ARGS.port, ARGS.port + 20):
        try:
            server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        except OSError:
            continue
        print(f"factory dashboard: http://127.0.0.1:{port}/", flush=True)
        server.serve_forever()
    raise SystemExit("factory dashboard: no free port from %d" % ARGS.port)


if __name__ == "__main__":
    main()
