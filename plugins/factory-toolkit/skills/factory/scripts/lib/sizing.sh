# sizing.sh: the run's limits and where each comes from, sourced by run-loop.sh after lib/config.sh (bash 3.2).
# Later wins:
#   1. the config layers (engine defaults < project < profile < target < ~/.factory/config.sh): the base values
#   2. the size class's table entry (SIZE_<class>): the class from --size, else SIZE in the ticket .sh, else the
#      assessment's Size line (the assessor's suggestion, capped by SIZE_CEILING), else SIZE_DEFAULT
#   3. what the ticket .sh sets on purpose (B_MIN=240, …: TICKET_SET, from config.sh)
#   4. --set K=V on the command line, for this run only
# Values a human or an agent set (2 from --size or the ticket, 3, 4) may go above the ceiling: the log says so.
# Sets SRC_<var> for each limit, SIZE, SIZE_FROM, SIZE_NOTE and LIMITS_LOG (one "K=V (source)" a line).

# assessment_field <file> <field>: one "<Field>: value" line of an assessment
assessment_field() { sed -n "s/^$2: *//p" "$1" 2> /dev/null | head -1; }

is_cap() { case " $CAP_VARS " in *" $1 "*) return 0 ;; esac; return 1; }
# Dollars may have cents; minutes and counts are whole numbers (the time box is shell arithmetic).
is_num() { case "$1" in *_USD=*) echo "${1#*=}" | grep -qE '^[0-9]+(\.[0-9]+)?$' ;; *) echo "${1#*=}" | grep -qE '^[0-9]+$' ;; esac; }
num_gt() { python3 -c "import sys; sys.exit(0 if $1 > $2 else 1)"; }

# ceiling_of <var>: the SIZE_CEILING value for <var>, or ""
ceiling_of() {
  local kv
  for kv in $SIZE_CEILING; do [ "${kv%%=*}" = "$1" ] && { echo "${kv#*=}"; return; }; done
}

# set_cap <var> <value> <source> [clamp]: sets a limit, checking it; with clamp, SIZE_CEILING caps it
set_cap() {
  local v=$1 val=$2 src=$3 c
  is_cap "$v" || { echo "factory: $v is not a limit the size can set ($CAP_VARS)" >&2; return 2; }
  is_num "$v=$val" || { echo "factory: $v=$val: a limit is a number (whole, but for the _USD ones)" >&2; return 2; }
  c=$(ceiling_of "$v")
  if [ -n "$c" ] && num_gt "$val" "$c"; then
    if [ "${4:-}" = clamp ]; then
      src="$src, capped at the ceiling $c (was $val)"; val=$c
    else
      src="$src, above the ceiling $c"
    fi
  fi
  eval "$v=\$val SRC_$v=\$src"
}

# resolve_limits <assessment file | ""> <cli size | ""> <cli sets "K=V K=V" | "">
resolve_limits() {
  local afile=$1 cli_size=$2 cli_sets=$3 kv clamp="" entry
  local v
  for v in $CAP_VARS; do eval "SRC_$v=config"; done
  SIZE_NOTE=""
  if [ -n "$cli_size" ]; then
    SIZE=$cli_size SIZE_FROM="the command line (--size)"
  elif [ -n "${SIZE:-}" ]; then
    SIZE_FROM="the ticket .sh${SIZE_WHY:+: $SIZE_WHY}"
  elif [ -n "$afile" ] && [ -n "$(assessment_field "$afile" Size)" ]; then
    SIZE=$(assessment_field "$afile" Size | awk '{print $1}') SIZE_FROM="the assessor" clamp=clamp
    SIZE_NOTE=$(assessment_field "$afile" Why)
  else
    SIZE=$SIZE_DEFAULT SIZE_FROM="the default (no assessment)"
  fi
  case " $SIZE_CLASSES " in
    *" $SIZE "*) ;;
    *) if [ "$clamp" = clamp ]; then
         SIZE_NOTE="the assessor's size '$SIZE' is not one of $SIZE_CLASSES: $SIZE_DEFAULT instead" SIZE=$SIZE_DEFAULT
       else
         echo "factory: size '$SIZE' is not one of $SIZE_CLASSES (SIZE_CLASSES)" >&2; return 2
       fi ;;
  esac
  eval "entry=\${SIZE_$SIZE:-}"
  for kv in $entry; do set_cap "${kv%%=*}" "${kv#*=}" "size $SIZE" $clamp || return 2; done
  for kv in ${TICKET_SET:-}; do set_cap "${kv%%=*}" "${kv#*=}" "the ticket .sh${SIZE_WHY:+: $SIZE_WHY}" || return 2; done
  for kv in $cli_sets; do
    case "$kv" in *=*) ;; *) echo "factory: --set $kv: use --set NAME=VALUE" >&2; return 2 ;; esac
    set_cap "${kv%%=*}" "${kv#*=}" "the command line (--set)" || return 2
  done
  LIMITS_LOG=""
  for v in $CAP_VARS; do LIMITS_LOG="$LIMITS_LOG$v=${!v} ($(eval "echo \"\$SRC_$v\""))
"; done
}

# limits_changed: the limits that are not the config's, on one line ("B_USD 15, B_MIN 90 (size L), …"), or "none"
limits_changed() {
  local v s out=""
  for v in $CAP_VARS; do
    eval "s=\$SRC_$v"
    [ "$s" = config ] || out="$out, $v ${!v} ($s)"
  done
  echo "${out#, }" | grep . || echo "none"
}

# set_on_purpose <var>: true when a human or an agent set it: the ticket .sh, --set, or a size class they picked
set_on_purpose() {
  local s
  eval "s=\$SRC_$1"
  case "$s" in
    "the ticket"*|"the command line"*) return 0 ;;
    "size "*) case "$SIZE_FROM" in "the ticket"*|"the command line"*) return 0 ;; esac ;;
  esac
  return 1
}

# scale_factor <amount> <per>: ceil(amount / per), between 1 and SCALE_MAX
scale_factor() { python3 -c "import math; print(max(1, min($SCALE_MAX, math.ceil($1 / $2))))"; }

# scaled <var> <factor>: the limit times the factor, unless it was set on purpose
scaled() {
  if [ "$2" -le 1 ] || set_on_purpose "$1"; then echo "${!1}"
  else case "$1" in *_USD) python3 -c "print(round(${!1} * $2, 2))" ;; *) echo $(( ${!1} * $2 )) ;; esac; fi
}
