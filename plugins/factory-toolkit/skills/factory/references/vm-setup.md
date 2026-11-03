# One-time golden image (Windows 11 ARM64 on QEMU)

Every QA run boots its own VM as a copy-on-write overlay of one golden image, so the image is built once per Mac and
never written by a run. One image per guest OS, shared by every profile (see [profiles.md](profiles.md)). Budget about
an hour, mostly waiting. `G=<skill dir>/scripts/vm/golden`, `H=~/VMs/factory/windows` (or `FACTORY_VM_HOME`).

## 1. Prerequisites (user)
- `brew install qemu samba` (QEMU runs the VM; Samba serves each run's worktree to the guest as `R:`).
- The Windows 11 ARM64 ISO, **English (United States)**: https://www.microsoft.com/software-download/windows11arm64,
  saved as `$H/Win11_*rm64*.iso`.
- `$H/NuGet.Config` with the Artifactory credentials (same shape as `~/.nuget/NuGet/NuGet.Config`). It stays on this Mac:
  `install.sh` puts it on the local seed ISO and `setup-guest.ps1` copies it into the guest. Never commit it.
- Disk: ~30 GB for the image, a few GB per live run. RAM/CPU per VM: `VM_MEM`/`VM_CPUS` in `~/.factory/config.sh`.

## 2. Install (unattended, one keypress)
`$G/install.sh` (`--clean` starts over). **First boot only:** click into the window and press Enter at "Press any key to
boot from CD or DVD"; on later reboots press nothing (a keypress there restarts setup and wipes the disk).
Setup reboots a few times, signs in as `rdmtest`, installs OpenSSH, then `setup-guest.ps1` installs the .NET 10 SDK and
configures SMB, the intranet zone, Defender exclusions, NuGet and the `R:` mapping task. A blank blue window can sit a long
time (downloads). A console titled "Select …" is paused by QuickEdit: press Esc. Done when the console windows have
closed; check over SSH, then shut down (the window closes):
```
ssh -i $H/id_ed25519 -p 2222 -o UserKnownHostsFile=$H/known_hosts -o StrictHostKeyChecking=accept-new rdmtest@127.0.0.1 \
  'Test-Path C:\vmready.txt; dotnet --list-sdks; Test-Path $env:APPDATA\NuGet\NuGet.Config; shutdown /s /t 0'
```
Expected: True, a 10.0.x line, True.

## 3. Warm it (recommended: saves ~10 min and first-run dialogs on every QA run)
Boot the golden image itself, writable, sharing a worktree of master: `$G/start.sh /path/to/master-worktree` (window).
Then from the Mac (default single-VM mode: port 2222, `$H/qmp.sock`):
```
S=<skill dir>/scripts/vm; P=<project dir>/profiles/<profile>/targets/windows   # projects/<project>/ in the skill, or <repo>/.factory/
python3 $S/vm.py wait-ssh
$S/vmssh - < $P/build.ps1            # fills the guest's NuGet cache (~10-15 min the first time)
$S/vmssh - < $P/launch.ps1           # launch the app once
```
In the window, go through each profile's first-run dialogs the way a fresh user would (skip sign-in/registration), so
every clone starts at the main window. Close the app, `$S/vmssh 'shutdown /s /t 0'`.

## 4. Freeze it
`chmod a-w $H/base.qcow2 $H/vars.base.fd`. `vmctl.sh up` refuses a writable base: booting it while overlays exist would
corrupt them. To update the image later (SDK, cache, software a profile needs such as IIS, SQL Server Express and DVLS instances):
stop all factory VMs (`vmctl.sh list`), `chmod u+w`, step 3,
`chmod a-w` again.

## 4b. Compact it (when the disk is short)
`$G/compact.sh` cleans the guest up (component store, Windows Update and Delivery Optimization downloads, temp files,
crash dumps, NuGet's HTTP cache, hibernation, a 2 GB page file), trims, and rewrites `base.qcow2` compressed with zstd,
read-only again. It keeps the NuGet packages folder. First run on the Windows image: 42 GB to 18.3 GB, with clones
booting (12 s) and building RDM (400 s) as fast as before. `--keep-old` keeps the previous file; check one clone before
relying on the new one. It refuses while a layer is backed by `base.qcow2`: compact before adding layers, or merge them.

## 5. Check
```
S=<skill dir>/scripts/vm; R=$(mktemp -d)
$S/vmctl.sh up $R "$(git rev-parse --show-toplevel)"     # prints slot, SSH and VNC ports; returns when SSH answers
eval "$($S/vmctl.sh env $R)"; $S/vmssh 'hostname; Get-ChildItem R:\ | Select-Object -First 5'
python3 $S/vm.py shot $R/check.png                         # the desktop
$S/vmctl.sh show $R                                        # Screen Sharing opens on it
$S/vmctl.sh down $R                                        # overlay deleted; base.qcow2 untouched
```
Two `up`s in parallel must get different slots/ports (`VM_MAX` caps how many run at once). With every slot taken, `up`
waits for one (`VM_SLOT_WAIT_MIN`, default 120) and says so on stderr.

## Notes
- Screen: clones and `start.sh` use `virtio-gpu-pci` at `VM_XRES`×`VM_YRES` (default 1600×900; override in `~/.factory/config.sh`) with the
  `viogpudo` driver, which `autounattend.xml` installs from virtio-win.iso. `install.sh` keeps `ramfb` (Windows setup has
  no virtio-gpu driver yet); ramfb tops out at 1024×768. An image built before the driver step needs it added once: boot
  it with `start.sh`, `pnputil /add-driver <iso>\viogpudo\w11\ARM64\viogpudo.inf /install`, shut down.
- Windows inside each clone is the same installation; activation and the computer name are shared. Fine for local
  testing; don't expose the VMs to a network (they only listen on 127.0.0.1).
- QEMU's `-vnc` password is limited to 8 characters; it's random per run and kept in `<run>/vm-<n>/vm/vnc.pass`.
