#!/bin/bash
# Creates a qcow2 layer on the frozen golden image, for software one profile needs (e.g. devolutions-console: IIS,
# SQL Server Express, PostgreSQL, DVLS instances). The layer stores only its differences from base.qcow2, so it costs
# what is installed in it, not a second image.
#
#   layer.sh <name>              create <name>.qcow2 + <name>.vars.fd next to base.qcow2 (writable, for maintenance)
#   layer.sh <name> --freeze     make it read-only once its software is installed (vmctl refuses writable images)
#
# Fill it with start.sh --image <name>.qcow2. A target uses it with GOLDEN_IMAGE=<name>.qcow2 in its target.sh.
# base.qcow2 must never change while a layer exists (compact.sh refuses): the layer would no longer match it.
# bash 3.2 compatible.
set -euo pipefail

VM_HOME="${FACTORY_VM_HOME:-$HOME/VMs/factory/windows}"
NAME="${1:-}"
[ -n "$NAME" ] || { echo "usage: layer.sh <name> [--freeze]" >&2; exit 1; }
cd "$VM_HOME"
[ -f base.qcow2 ] && [ ! -w base.qcow2 ] || { echo "layer: base.qcow2 missing or writable: freeze it first" >&2; exit 1; }

if [ "${2:-}" = --freeze ]; then
    chmod a-w "$NAME.qcow2" "$NAME.vars.fd"
    qemu-img info "$NAME.qcow2" | sed -n 's/^disk size: /layer size: /p'
    exit 0
fi
[ -e "$NAME.qcow2" ] && { echo "layer: $NAME.qcow2 already exists" >&2; exit 1; }
qemu-img create -q -f qcow2 -b "$VM_HOME/base.qcow2" -F qcow2 "$NAME.qcow2"
cp vars.base.fd "$NAME.vars.fd" && chmod u+w "$NAME.vars.fd"
echo "created $VM_HOME/$NAME.qcow2 on base.qcow2; fill it with: start.sh --image $NAME.qcow2"
