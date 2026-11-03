#!/bin/bash
# Fake vmctl.sh for tests/run-loop.test.sh: a "VM" is a folder with a vm.env while it is up.
cmd=$1; d=${2:-}
case "$cmd" in
  up) mkdir -p "$d" && echo "export VM_SSH_PORT=0 FAKE_VM=$d" > "$d/vm.env" && : > "$d/running" && echo "fake VM up: $d"
      echo "vm up $(basename "$d")" >> "$FAKE_STATE/calls.log"
      # How many VMs the run holds at once: one per run is the rule.
      up=$(($(cat "$FAKE_STATE/vms-up" 2> /dev/null || echo 0) + 1)); echo "$up" > "$FAKE_STATE/vms-up"
      [ "$up" -gt "$(cat "$FAKE_STATE/vms-max" 2> /dev/null || echo 0)" ] && echo "$up" > "$FAKE_STATE/vms-max"; exit 0 ;;
  # Like the real one: env keeps answering after a down (it reads a file the down leaves); alive is the real state.
  env) [ -f "$d/vm.env" ] && cat "$d/vm.env" ;;
  alive) [ -f "$d/running" ] ;;
  down) [ -f "$d/running" ] && rm -f "$d/running" && echo "vm down: $d (fake)" \
          && echo $(($(cat "$FAKE_STATE/vms-up") - 1)) > "$FAKE_STATE/vms-up"; exit 0 ;;
  *) exit 0 ;;
esac
