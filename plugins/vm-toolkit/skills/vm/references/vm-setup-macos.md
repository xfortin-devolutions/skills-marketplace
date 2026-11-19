# One-time golden image (macOS on tart)

A macOS guest can't run on QEMU: an Apple Silicon Mac boots macOS VMs only through Apple's Virtualization.framework.
The toolkit drives those with [tart](https://tart.run) (FSL-1.1 licence: internal use is free). A guest OS folder that
holds a `tart/` home (`<VM root>/macos/tart`) is a tart one, and everything else stays the same: `vmt init`, `vmt up`,
`vmt guest`, the MCP tools, slots, the idle reaper. `G=<skill dir>/scripts/vm/golden`, `H=~/VMs/factory/macos`.

What differs from the Windows VMs:
- **Clones**: each VM is an APFS clone of the tart VM `base` (instant, copy-on-write, no read-only freeze needed: a
  clone never sees later changes to `base`), deleted at `down`.
- **Two at a time**: Apple's licence allows two macOS VMs on a Mac, and the kernel enforces it: `VM_MAX` is capped at 2
  for macOS (Windows VMs have their own slots).
- **No SDK in the guest**: the Mac builds the app (the target's `HOST_BUILD`), and the guest only runs it. Tests of Mac
  code run on the Mac itself, the same OS. Size: `VM_MACOS_CPUS` (4) and `VM_MACOS_MEM` (8G).
- **The share**: tart mounts the worktree in the guest at `/Volumes/My Shared Files/wt` (virtiofs; `$R` in a guest
  command), not over SMB.
- **Screen and input**: Virtualization.framework's own VNC server on 127.0.0.1 (`tart run --vnc-experimental`, a new
  password per VM); `vm.py` drives it through `vnc.py` the way it drives QEMU's QMP. Command is `cmd` in `app key`
  (`cmd-q`, `cmd-shift-4`).
- **Guest commands** are bash, over SSH to the VM's own address (192.168.64.x), as `admin`.

## 1. Prerequisites (user)
- `brew install openai/tools/tart` (Homebrew asks to `brew trust openai/tools` first).
- Disk: ~30 GB for `base`; clones cost only what they change.
- To build the app: a .NET 10 SDK with the `macos` workload, and the Xcode that workload asks for. A newer workload
  than Xcode fails every build with "requires Xcode X.Y" (`guest build` says so, as a harness error): update Xcode.
- Recommended: a shorter DHCP lease. Every clone gets a new MAC address, and macOS's NAT keeps each lease a day, so
  heavy use can run out of addresses: `sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.InternetSharing.default.plist bootpd -dict DHCPLeaseTimeSecs -int 600`

## 2. Build it (unattended, ~10 min after the download)
`$G/macos-setup.sh` (`--clean` builds it again; `--image <OCI ref>` another macOS, never newer than this Mac's). It
pulls Cirrus Labs' vanilla image (`ghcr.io/cirruslabs/macos-tahoe-vanilla`: macOS with SSH, `admin` signed in
automatically, passwordless sudo, no Xcode or Homebrew), clones it as `base`, and makes it lean: Spotlight indexing,
Software Update checks and downloads, sleep, the screen saver and crash dialogs off; a bare desktop (no apps reopened at
login, no widgets); SSH by key only (`$H/id_ed25519`). After a change to those settings, `--update` applies them to the
existing `base` (no download).
It then deletes the downloaded image from tart's cache.

## 3. Warm it (recommended)
Go through the app's first-run dialogs once in `base`, so every clone starts at the main window. Build the app on the
Mac first (`vmt guest <vm dir> build` on any macOS VM folder), then:
```
export TART_HOME=$H/tart
tart run --dir=wt:/path/to/worktree base &          # a window opens on base itself
```
In the window, open the app from `/Volumes/My Shared Files/wt/...` and go through its dialogs the way a fresh user
would (skip sign-in and registration); quit it, then shut the guest down (Apple menu > Shut Down).

## 4. Check
```
D=$(bash $V/vmt root)/mcp/mac-check
bash $V/vmt init $D /path/to/worktree --product rdm --target macos
bash $V/vmt up $D && bash $V/vmt guest $D info
bash $V/vmt guest $D app launch; bash $V/vmt guest $D app wait 15; bash $V/vmt guest $D app shot
bash $V/vmt show $D        # TigerVNC, else Screen Sharing
bash $V/vmt down $D
```

## Checkpoints
`vmt checkpoint` works as on Windows (SKILL.md, checkpoints): the VM's clone is kept as the tart VM `ck-<name>`, with
`checkpoints/<name>.tart` naming it and `<name>.conf` describing it, and later VMs clone it instead of `base`. Taking
one is instant once the guest is off, and costs only what the VM changed (APFS). The guest shuts down the way the
Apple menu does (loginwindow's shut down event, which needs no permission from SSH), so apps quit and save; one that
asks before quitting holds the shutdown up, and the checkpoint is refused with a screenshot of the question, the VM
still up. `shutdown -h now` would kill the apps instead: `--force` does that, when a crash report on the next start is
acceptable.

## Not yet
The shared clipboard is Windows-only for now (GAPS.md).
