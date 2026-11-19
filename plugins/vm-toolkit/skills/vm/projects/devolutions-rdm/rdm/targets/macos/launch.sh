# Starts the Debug build from the shared worktree ($R, set by vmssh) in the guest's desktop session: admin is signed in
# (auto-login), and open from SSH starts an app in that session. A running instance is stopped first, so a launch after
# a build starts the new one.
app="$R/RDM/Mac/RemoteDesktopManager/Clients/RemoteDesktopManager/bin/ARM64/Debug/RemoteDesktopManager.app"
[ -d "$app" ] || { echo "Not built yet: $app"; exit 1; }
pkill -x RemoteDesktopManager && sleep 2
open -n "$app" || exit 1
for _ in 1 2 3 4 5 6 7 8 9 10; do
  pgrep -x RemoteDesktopManager > /dev/null && { echo "LAUNCH OK"; exit 0; }
  sleep 1
done
echo "RemoteDesktopManager did not start"
