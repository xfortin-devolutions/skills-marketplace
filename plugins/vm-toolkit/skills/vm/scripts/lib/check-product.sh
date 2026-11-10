#!/bin/bash
# check-product.sh <repo> <product folder>: checks one product definition, its targets and its layer against
# references/products.md. One line per problem: ERROR fails the check, WARN doesn't (usually this machine lacks
# something, such as an image). Exit 1 on an ERROR. VM_ROOT says where the images are (lib/config.sh). Called by
# vmt check, and by callers that check their own settings around it (factory.sh check). bash 3.2 compatible.
set -u
REPO=$1 D=$2
VM_ROOT=${VM_ROOT:-${FACTORY_VM_ROOT:-$HOME/VMs/factory}}
errs=0 warns=0
err() { echo "  ERROR $*"; errs=$((errs + 1)); }
warn() { echo "  WARN  $*"; warns=$((warns + 1)); }
has() { grep -q -- "$2" "$1" 2> /dev/null; } # has <file> <text>

if [ ! -f "$D/product.sh" ]; then
  err "no product.sh in $D"; exit 1
fi
for f in "$D/product.sh" "$D"/targets/*/* "$D/layer/layer.conf" "$D/layer/setup.ps1"; do
  [ -f "$f" ] && has "$f" 'TODO' && err "${f#$D/}: TODO left to fill"
done

APP_NAME="" TARGETS="" CODE_PATHS=""
. "$D/product.sh" > /dev/null 2>&1 || err "product.sh fails when sourced"
[ -n "$APP_NAME" ] || err "product.sh: APP_NAME is empty"
[ -n "$TARGETS" ] || err "product.sh: TARGETS is empty"
if [ -z "$CODE_PATHS" ]; then
  err "product.sh: CODE_PATHS is empty (where the product's code is: how a path finds its product)"
else
  for c in $CODE_PATHS; do [ -e "$REPO/$c" ] || err "CODE_PATHS $c is not in the repo"; done
fi

for t in $TARGETS; do
  TD=$D/targets/$t
  if [ ! -f "$TD/target.sh" ]; then
    err "target $t: no targets/$t/target.sh"; continue
  fi
  (
    errs=0 warns=0
    TARGET_DIR=$TD GOLDEN_IMAGE="" GUEST_OS="" GUEST_DESC="" SHARE_CHECK="" GUEST_BUILD="" GUEST_TEST="" GUEST_LAUNCH=""
    . "$TD/target.sh"
    for v in GUEST_OS GUEST_DESC SHARE_CHECK GUEST_BUILD GUEST_TEST GUEST_LAUNCH; do
      eval "[ -n \"\$$v\" ]" || err "target $t: $v is empty"
    done
    [ -z "$SHARE_CHECK" ] || [ -e "$REPO/$SHARE_CHECK" ] || err "target $t: SHARE_CHECK $SHARE_CHECK is not in the repo"
    for pair in "GUEST_BUILD:BUILD EXIT CODE" "GUEST_TEST:TEST EXIT CODE" "GUEST_LAUNCH:LAUNCH OK"; do
      v=${pair%%:*} marker=${pair#*:}
      eval "f=\$$v"
      [ -n "$f" ] || continue
      if [ ! -f "$f" ]; then err "target $t: $v ${f#$D/} is missing"; continue; fi
      has "$f" "$marker" || err "target $t: ${f#$D/} never prints \"$marker\""
    done
    [ -f "$GUEST_BUILD" ] && ! has "$GUEST_BUILD" '\$Project' && err "target $t: ${GUEST_BUILD#$D/} ignores \$Project"
    [ -f "$GUEST_TEST" ] && { has "$GUEST_TEST" '\$Project' && has "$GUEST_TEST" '\$Filter'; } \
      || { [ -f "$GUEST_TEST" ] && err "target $t: ${GUEST_TEST#$D/} must read \$Project and \$Filter"; }
    img=${GOLDEN_IMAGE:-base.qcow2}
    if [ ! -f "$VM_ROOT/$GUEST_OS/$img" ]; then
      warn "target $t: no $img in $VM_ROOT/$GUEST_OS on this machine (vm-setup.md for base.qcow2, vmt layer for a layer)"
    elif [ -w "$VM_ROOT/$GUEST_OS/$img" ]; then
      warn "target $t: $img is writable: clones refuse it until it is frozen (chmod a-w)"
    fi
    if [ "$img" != base.qcow2 ]; then
      layer=$( (VM_HOME=$VM_ROOT/$GUEST_OS FACTORY_VM_HOME=$VM_ROOT/$GUEST_OS LAYER=""; . "$D/layer/layer.conf" > /dev/null 2>&1; echo "$LAYER") 2> /dev/null)
      [ "$layer.qcow2" = "$img" ] || warn "target $t: GOLDEN_IMAGE $img has no recipe in this product (layer/layer.conf LAYER=${img%.qcow2})"
    fi
    exit $(( errs > 0 ? 2 : (warns > 0 ? 1 : 0) ))
  )
  case $? in 2) errs=$((errs + 1)) ;; 1) warns=$((warns + 1)) ;; esac
done

if [ -d "$D/layer" ]; then
  if [ ! -f "$D/layer/layer.conf" ] || [ ! -f "$D/layer/setup.ps1" ]; then
    err "layer/ needs layer.conf and setup.ps1"
  else
    has "$D/layer/setup.ps1" 'LAYER SETUP OK' && has "$D/layer/setup.ps1" 'LAYER SETUP FAILED' \
      || err "layer/setup.ps1 must end its log with \"LAYER SETUP OK\" or \"LAYER SETUP FAILED: <why>\""
    msg=$( (VM_HOME=$VM_ROOT/windows FACTORY_VM_HOME=$VM_ROOT/windows LAYER=""; . "$D/layer/layer.conf" > /dev/null) 2>&1) \
      || warn "layer/layer.conf can't build on this machine: ${msg:-it returns an error}"
  fi
fi

[ "$errs" -eq 0 ]
