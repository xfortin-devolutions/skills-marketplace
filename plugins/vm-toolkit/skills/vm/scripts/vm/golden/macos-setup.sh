#!/bin/bash
# macos-setup.sh: the macOS golden image, a tart VM named base in <VM root>/macos/tart (vmctl.sh drives any guest OS
# folder that has a tart/ home with tart). It starts from Cirrus Labs' vanilla image (macOS, SSH on, user admin with
# passwordless sudo and auto-login, no Xcode or Homebrew) and is made leaner for VMs that only run an app the Mac built:
# no Spotlight indexing, no software update checks or downloads, no sleep or screen saver, a bare desktop (no windows
# restored at login, no widgets), SSH by key only (the VMs' key in <VM root>/macos/id_ed25519). It also carries
# Cirrus's guest agent (its clipboard part only, --run-vdagent), installed but never started: vmctl.sh show starts it,
# so only a VM a person opens shares this Mac's clipboard.
#   macos-setup.sh [--image <OCI ref>] [--clean | --update]
# --image: another macOS (default ghcr.io/cirruslabs/macos-tahoe-vanilla:latest; never newer than this Mac's macOS).
# --clean: delete the existing base first. VMs already cloned from it keep running (APFS clones are independent).
# --update: apply this script's settings to the existing base again (after a change to them), with no download.
# Needs: tart (brew install openai/tools/tart). The vanilla image is ~25 GB to download, once. bash 3.2 compatible.
set -u
X=$(cd "$(dirname "$0")" && pwd)
VMT_DIR=$(cd "$X/../../.." && pwd)
. "$VMT_DIR/scripts/lib/config.sh"
VM_HOME=${VM_HOME:-$VM_ROOT/macos}
IMAGE=ghcr.io/cirruslabs/macos-tahoe-vanilla:latest CLEAN=no UPDATE=no
# The guest agent (FSL-1.1, as tart): a pinned release and its checksum, from openai/tart-guest-agent's checksums file
AGENT_VERSION=0.15.0
AGENT_SHA256=eb47f402f18e742a8ea96344115ca776179f9c4c67494bc0c46a10a68db280b7
while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE=${2:-}; shift ;;
    --clean) CLEAN=yes ;;
    --update) UPDATE=yes ;;
    *) sed -n '2,12p' "$0" >&2; exit 2 ;;
  esac
  shift
done
die() { echo "macos-setup: $*" >&2; exit 1; }
export TART_HOME=$VM_HOME/tart TART_NO_AUTO_PRUNE=1
command -v tart > /dev/null || die "tart missing: brew install openai/tools/tart"
mkdir -p "$TART_HOME"
KEY=$VM_HOME/id_ed25519
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C vmt-macos -f "$KEY" || die "ssh-keygen failed"
# The guest agent, downloaded once into installers/ and checked
AGENT_TGZ=$VM_HOME/installers/tart-guest-agent-$AGENT_VERSION-darwin-all.tar.gz
if [ ! -f "$AGENT_TGZ" ] || [ "$(shasum -a 256 "$AGENT_TGZ" | cut -d' ' -f1)" != "$AGENT_SHA256" ]; then
  mkdir -p "$VM_HOME/installers"
  curl -fsSL -o "$AGENT_TGZ.part" \
    "https://github.com/openai/tart-guest-agent/releases/download/v$AGENT_VERSION/tart-guest-agent-darwin-all.tar.gz" \
    || die "could not download the guest agent"
  [ "$(shasum -a 256 "$AGENT_TGZ.part" | cut -d' ' -f1)" = "$AGENT_SHA256" ] \
    || { rm -f "$AGENT_TGZ.part"; die "the guest agent download does not match its checksum"; }
  mv "$AGENT_TGZ.part" "$AGENT_TGZ"
fi

if [ "$UPDATE" = yes ]; then
  [ -d "$TART_HOME/vms/base" ] || die "no base in $TART_HOME to update: build it first (no --update)"
else
  if [ -d "$TART_HOME/vms/base" ]; then
    [ "$CLEAN" = yes ] || die "$TART_HOME/vms/base exists: --clean to build it again, --update to apply the settings again"
    tart delete base || die "could not delete the old base"
  fi
  echo "== cloning $IMAGE (pulls it the first time: ~25 GB)"
  tart clone "$IMAGE" base || die "tart clone failed"
  # Small: the guest only runs the app (vmctl.sh sizes each clone again: VM_MACOS_CPUS, VM_MACOS_MEM).
  tart set base --cpu 4 --memory 8192 --display 1600x900px || die "tart set failed"
fi

echo "== booting base for its setup"
log=$VM_HOME/setup.log
tart run --no-graphics base > "$log" 2>&1 < /dev/null &
pid=$!
trap 'kill $pid 2> /dev/null' EXIT
ip=$(tart ip --wait 300 base) || die "base got no address in 5 min ($log)"
VM_SSH_HOST=$ip VM_SSH_PORT=22 python3 "$X/../vm.py" wait-ssh 300 > /dev/null || die "base's SSH did not answer in 5 min"

# The vanilla image's own password, once, to put the key in: OpenSSH reads it from SSH_ASKPASS.
known=$VM_HOME/setup.known_hosts
rm -f "$known"
if [ "$UPDATE" = yes ]; then
  ssh -i "$KEY" -o UserKnownHostsFile="$known" -o StrictHostKeyChecking=accept-new -o BatchMode=yes "admin@$ip" true \
    || die "the key doesn't open base: --clean to build it again"
else
askpass=$(mktemp) && printf '#!/bin/sh\necho admin\n' > "$askpass" && chmod +x "$askpass"
SSH_ASKPASS=$askpass SSH_ASKPASS_REQUIRE=force DISPLAY=none ssh -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$known" -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 "admin@$ip" \
  'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys' < "$KEY.pub" \
  || { rm -f "$askpass"; die "could not put the key in the guest (password admin)"; }
rm -f "$askpass"
fi

echo "== making it lean"
ssh -i "$KEY" -o UserKnownHostsFile="$known" -o BatchMode=yes "admin@$ip" 'bash -s' <<'GUEST' || die "the guest setup failed"
set -x
# Spotlight: indexing a fresh clone costs CPU and disk on every boot
sudo mdutil -a -i off > /dev/null
# Software Update: no checks, downloads or installs (a clone lives minutes)
sudo softwareupdate --schedule off > /dev/null 2>&1
for k in AutomaticCheckEnabled AutomaticDownload ConfigDataInstall CriticalUpdateInstall AutomaticallyInstallMacOSUpdates; do
  sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate "$k" -bool false
done
sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false
# Never sleep, dim or lock: an agent's screenshot must show the app
sudo pmset -a sleep 0 displaysleep 0 disksleep 0 powernap 0 > /dev/null
defaults -currentHost write com.apple.screensaver idleTime -int 0
sudo defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime -int 0
# No crash dialogs over the app under test (the crash report is still written)
defaults write com.apple.CrashReporter DialogType none
# A bare desktop for screenshots: no windows reopened at login (the vanilla image left a Terminal one), no widgets
defaults write com.apple.loginwindow TALLogoutSavesState -bool false
defaults write NSGlobalDomain NSQuitAlwaysKeepsWindows -bool false
defaults write com.apple.WindowManager StandardHideWidgets -bool true
defaults write com.apple.WindowManager StageManagerHideWidgets -bool true
defaults write com.apple.Terminal NSQuitAlwaysKeepsWindows -bool false
pkill -x Terminal
sleep 1
# Apps reopened at login (loginwindow's list: the vanilla image's Terminal), saved windows (macOS 26 keeps them under
# Daemon Containers), zsh's sessions, and what Spotlight indexed before it was turned off
rm -rf ~/Library/Group\ Containers/group.com.apple.loginwindow.persistent-apps/* ~/Library/Saved\ Application\ State/* \
  ~/Library/Daemon\ Containers/*/Data/Library/Saved\ Application\ State/* ~/.zsh_sessions ~/Library/Metadata/CoreSpotlight
# SSH by key only: the vanilla password is public
echo 'PasswordAuthentication no
KbdInteractiveAuthentication no' | sudo tee /etc/ssh/sshd_config.d/100-vmt.conf > /dev/null
# What the image came with and a clone never needs
sudo rm -rf /Library/Updates/* /Library/Caches/* ~/Library/Caches/* 2> /dev/null
sw_vers
df -h / | tail -1
GUEST

echo "== the guest agent (clipboard; started by vmctl.sh show only)"
tar -xzOf "$AGENT_TGZ" tart-guest-agent \
  | ssh -i "$KEY" -o UserKnownHostsFile="$known" -o BatchMode=yes "admin@$ip" \
    'sudo mkdir -p /usr/local/bin /Library/vmt && sudo tee /usr/local/bin/tart-guest-agent > /dev/null && sudo chmod 755 /usr/local/bin/tart-guest-agent' \
  || die "could not put the guest agent in the guest"
# Outside /Library/LaunchAgents: nothing loads it at login
ssh -i "$KEY" -o UserKnownHostsFile="$known" -o BatchMode=yes "admin@$ip" 'sudo tee /Library/vmt/tart-guest-agent.plist > /dev/null' <<'PLIST' \
  || die "could not put the guest agent's launchd file in the guest"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>org.cirruslabs.tart-guest-agent</string>
  <key>ProgramArguments</key><array><string>/usr/local/bin/tart-guest-agent</string><string>--run-vdagent</string></array>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/tart-guest-agent.log</string>
  <key>StandardErrorPath</key><string>/tmp/tart-guest-agent.log</string>
</dict>
</plist>
PLIST

echo "== shutting it down"
ssh -i "$KEY" -o UserKnownHostsFile="$known" -o BatchMode=yes "admin@$ip" 'sudo shutdown -h now' > /dev/null 2>&1
i=0
while kill -0 "$pid" 2> /dev/null && [ "$i" -lt 180 ]; do sleep 1; i=$((i + 1)); done
kill -0 "$pid" 2> /dev/null && die "base did not power off in 3 min"
trap - EXIT
rm -f "$known"
# The downloaded image: base holds everything now, and a clone of base is what every VM starts from.
tart prune --entries=caches --older-than=0 > /dev/null 2>&1
echo "base ready: $(du -sh "$TART_HOME/vms/base" | cut -f1) on disk ($TART_HOME/vms/base)"
