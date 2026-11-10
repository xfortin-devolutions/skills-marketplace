# vmt.sh: finds the VM toolkit (the vm-toolkit plugin's skills/vm folder), which owns the VMs and the product
# definitions the factory builds and tests with. Sourced by lib/config.sh, with SKILL_DIR set; sets VMT, or returns 2.
# In order: VM_TOOLKIT_DIR; the sibling plugin in the same checkout (the marketplace repo, and the engine's tests); the
# installed plugin (~/.claude/plugins/installed_plugins.json). bash 3.2 compatible.

# The oldest toolkit whose scripts and product layout this engine speaks.
VM_TOOLKIT_MIN=0.1.0

vmt_find() {
  local d
  for d in "${VM_TOOLKIT_DIR:-}" "$SKILL_DIR/../../../vm-toolkit/skills/vm"; do
    [ -n "$d" ] && [ -x "$d/scripts/vmt" ] && { (cd "$d" && pwd); return 0; }
  done
  python3 -I - "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json" <<'PY' 2> /dev/null
import json, os, sys
plugins = json.load(open(sys.argv[1])).get("plugins", {})
for key, installs in plugins.items():
    if key.split("@")[0] != "vm-toolkit":
        continue
    for i in installs if isinstance(installs, list) else [installs]:
        d = os.path.join(i.get("installPath", ""), "skills", "vm")
        if os.access(os.path.join(d, "scripts", "vmt"), os.X_OK):
            print(d)
            sys.exit(0)
sys.exit(1)
PY
}

# vmt_version <toolkit dir>: its plugin.json version
vmt_version() { sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$1/../../.claude-plugin/plugin.json" 2> /dev/null | head -1; }

VMT=$(vmt_find) || {
  echo "factory: the VM toolkit is missing: /plugin install vm-toolkit@xfortin-skills-marketplace (or set VM_TOOLKIT_DIR)" >&2
  return 2
}
_v=$(vmt_version "$VMT")
if [ -n "$_v" ] && [ "$(printf '%s\n%s\n' "$VM_TOOLKIT_MIN" "$_v" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" != "$VM_TOOLKIT_MIN" ]; then
  echo "factory: the VM toolkit in $VMT is $_v; this factory needs $VM_TOOLKIT_MIN or later: update vm-toolkit" >&2
  return 2
fi
unset _v
export VMT
