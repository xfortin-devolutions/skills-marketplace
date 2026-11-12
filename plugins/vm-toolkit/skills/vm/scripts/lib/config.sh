# config.sh: the VM toolkit's machine settings, sourced by vmt (bash 3.2 compatible). Set before sourcing: VMT_DIR (the
# skill folder). Layers, later wins: defaults < ~/.factory/config.sh (setups from before the toolkit kept their VM
# settings there) < ~/.vm-toolkit/config.sh. A caller that drives vmctl.sh itself (the factory) exports its own values.

VM_ROOT=${VM_ROOT:-} VM_CPUS=8 VM_MEM=16G VM_MAX=2 VM_SLOT_WAIT_MIN=120 VM_IDLE_MIN=10 VM_BOOT_MIN=10
VM_XRES=1600 VM_YRES=900 GUEST_BUILD_MIN=30 APP_SHOT_CAP=200 VM_RECORD_MAX_MIN=10
for _c in "${FACTORY_USER_CONFIG:-$HOME/.factory/config.sh}" "${VMT_USER_CONFIG:-$HOME/.vm-toolkit/config.sh}"; do
  # shellcheck disable=SC1090
  [ -f "$_c" ] && . "$_c"
done
# One golden image folder per guest OS under the root: <VM root>/<guest os>/base.qcow2 (and its layers).
VM_ROOT=${VM_ROOT:-${FACTORY_VM_ROOT:-$HOME/VMs/factory}}
export VM_ROOT VM_CPUS VM_MEM VM_MAX VM_SLOT_WAIT_MIN VM_IDLE_MIN VM_BOOT_MIN VM_XRES VM_YRES VM_RECORD_MAX_MIN
