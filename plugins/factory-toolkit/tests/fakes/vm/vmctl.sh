#!/bin/bash
# Fake vmctl.sh for tests/run-loop.test.sh: a "VM" is a folder with a vm.env while it is up.
cmd=$1; d=${2:-}
case "$cmd" in
  up) mkdir -p "$d" && echo "export VM_SSH_PORT=0 FAKE_VM=$d" > "$d/vm.env" && echo "fake VM up: $d" ;;
  env) [ -f "$d/vm.env" ] && cat "$d/vm.env" ;;
  down) [ -f "$d/vm.env" ] && rm -f "$d/vm.env" && echo "vm down: $d (fake)"; exit 0 ;;
  *) exit 0 ;;
esac
