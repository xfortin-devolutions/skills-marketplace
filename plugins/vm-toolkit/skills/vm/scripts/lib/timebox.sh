# timebox <seconds> <command...>: runs the command in its own process group and kills the whole group on time out
# (exit 142). A plain alarm + exec only signals the top process, and a hung ssh or tool child then wedges the run.
# Polls the wall clock rather than alarm(): on macOS an alarm doesn't count time asleep, so a run that spans a host
# sleep never timed out (GAPS V43); the wall clock does, and the run is stopped on the first wake past its time box.
timebox() {
  perl -MPOSIX=:sys_wait_h -e '$t = shift; $p = fork; if (!$p) { setpgrp(0, 0); exec @ARGV; exit 127 }
    $end = time + $t;
    while (1) {
      if (waitpid($p, WNOHANG) == $p) { exit($? >> 8) }
      if (time >= $end) { kill "TERM", -$p; sleep 5; kill "KILL", -$p; waitpid($p, 0); exit 142 }
      sleep 2;
    }' "$@"
}
