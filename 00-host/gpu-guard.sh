#!/usr/bin/env bash
# gpu-guard — thermal guard for the passively-cooled V100 in sdf1.
#
# The V100 (Tesla PG500-216, GPU 1) has no onboard fan — nvidia-smi reports
# fan.speed as N/A. Its only cooling is an external fan on DLI outlet 6, which
# does not self-start when its outlet is restored and cannot be confirmed
# spinning from anywhere except the room. This daemon assumes the fan may be off
# at any moment and acts on temperature alone.
#
# It reads nvidia-smi, never Kubernetes resource state. ai/ollama is pinned to
# the V100 by UUID with empty resources{}, so the cluster reports
# nvidia.com/gpu allocated: 0 while the card is fully in use. The scheduler's
# view of this GPU is blind.
#
# Ladder, core / memory degrees C:
#   NOTIFY   70 / 70    alert only
#   CAP      75 / 75    power limit 250W -> 150W, no cluster interaction
#   STOP     80 / 80    pause Fleet bundles, scale V100 workloads to 0
#   FLOOR    85 / 83    power limit -> 100W, page, stop escalating
#   recover  <50/<50 held for RECOVER_POLLS: workloads back, power limit back
#
# Thresholds derive from the card's own reported limits: max operating 83C,
# slowdown 88C, shutdown 91C, HBM2 memory max 85C.
#
# No shutdown at any stage. `shutdown -h now` on this host hangs on Longhorn
# iSCSI teardown — measured at 21 minutes with no sign of completing — so an
# automated shutdown is a delayed unclean cut, not a shutdown.
#
# Escalation is one-way while hot. The guard does not step back down through the
# ladder as temperature wobbles; it holds the highest stage reached until a full
# recovery below RECOVER_TEMP, which stops it flapping between 78 and 82.

set -uo pipefail

CONF=${GPU_GUARD_CONF:-/etc/gpu-guard/gpu-guard.conf}
STATE_DIR=/var/lib/gpu-guard
STATE=$STATE_DIR/state

# ---- defaults, overridable in $CONF ----------------------------------------
GPU_UUID="GPU-a69c6398-0353-3234-9f35-af0e02865f33"   # Tesla PG500-216 (V100)
POLL_SECS=15
RECOVER_TEMP=50
RECOVER_POLLS=4                 # consecutive cool polls before restoring

CORE_NOTIFY=70;  MEM_NOTIFY=70
CORE_CAP=75;     MEM_CAP=75
CORE_STOP=80;    MEM_STOP=80
CORE_FLOOR=85;   MEM_FLOOR=83

PL_DEFAULT=250
PL_CAP=150
PL_FLOOR=100

KUBECTL=/usr/local/bin/kubectl
SDF1_CTX=sdf1
RANCHER_CTX=rancher
# Hard bound on every API call. An unreachable cluster must cost seconds, not
# minutes, during a thermal event.
KUBE_TIMEOUT=5s
FLEET_NS=fleet-default
ANNOT="lab.ash4d.com/prior-replicas"     # same key sdf1-toggle uses, on purpose

# Workloads that can put load on the V100. emby is deliberately absent: it is
# pinned to the GTX 1070 (GPU-5641c03a-...) and cannot heat this card.
TARGET_NS=ai
TARGET_DEPLOYS="ollama comfyui unsloth-studio"
TARGET_BUNDLES="lab-ai-04-ollama lab-ai-07-comfyui lab-ai-21-unsloth-studio"

SLACK_WEBHOOK_FILE=/etc/gpu-guard/slack-webhook
DRY_RUN=0

[[ -r $CONF ]] && . "$CONF"

# ---- logging ---------------------------------------------------------------
log(){ printf '%s %s\n' "$(date -Is)" "$*"; }

# ---- alerting --------------------------------------------------------------
# Absent or unreadable webhook degrades to journal-only. A thermal guard that
# refuses to run because it cannot reach Slack would be worse than a quiet one.
slack(){
  local text=$1 url
  if [[ ! -r $SLACK_WEBHOOK_FILE ]]; then
    log "ALERT (slack unconfigured, journal only): $text"
    return 0
  fi
  url=$(< "$SLACK_WEBHOOK_FILE"); url=${url//[$'\r\n']/}
  if [[ -z $url ]]; then
    log "ALERT (slack webhook file empty, journal only): $text"
    return 0
  fi
  if (( DRY_RUN )); then
    log "DRY-RUN would slack: $text"
    return 0
  fi
  if ! curl -sS -m 10 -X POST -H 'Content-type: application/json' \
        --data "$(printf '{"text":%s}' "$(json_str "$text")")" "$url" >/dev/null; then
    log "WARN slack delivery failed; message was: $text"
  fi
}

json_str(){ printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | awk '{printf "%s%s",(NR>1?"\\n":"\""),$0} END{print "\""}'; }

# ---- gpu readings ----------------------------------------------------------
# Resolve the index from the UUID on every poll. Index order is not guaranteed
# stable across driver reloads; the UUID is.
gpu_read(){
  local line
  line=$(nvidia-smi --query-gpu=uuid,index,temperature.gpu,temperature.memory \
          --format=csv,noheader,nounits 2>/dev/null | grep -F "$GPU_UUID") || return 1
  [[ -n $line ]] || return 1
  IFS=',' read -r _u idx core mem <<<"$line"
  idx=${idx// /}; core=${core// /}; mem=${mem// /}
  [[ $core =~ ^[0-9]+$ ]] || return 1
  [[ $mem  =~ ^[0-9]+$ ]] || mem=0        # N/A on cards without an HBM sensor
  printf '%s %s %s' "$idx" "$core" "$mem"
}

# ---- stage decision --------------------------------------------------------
# Prints one of: NORMAL NOTIFY CAP STOP FLOOR
stage_for(){
  local core=$1 mem=$2
  if (( core >= CORE_FLOOR  || mem >= MEM_FLOOR  )); then echo FLOOR;  return; fi
  if (( core >= CORE_STOP   || mem >= MEM_STOP   )); then echo STOP;   return; fi
  if (( core >= CORE_CAP    || mem >= MEM_CAP    )); then echo CAP;    return; fi
  if (( core >= CORE_NOTIFY || mem >= MEM_NOTIFY )); then echo NOTIFY; return; fi
  echo NORMAL
}
stage_rank(){ case $1 in NORMAL) echo 0;; NOTIFY) echo 1;; CAP) echo 2;; STOP) echo 3;; FLOOR) echo 4;; *) echo 0;; esac; }

# ---- actions ---------------------------------------------------------------
set_power_limit(){
  local idx=$1 watts=$2
  if (( DRY_RUN )); then log "DRY-RUN would set GPU $idx power limit to ${watts}W"; return 0; fi
  if nvidia-smi -i "$idx" -pl "$watts" >/dev/null 2>&1; then
    log "power limit GPU $idx set to ${watts}W"
  else
    log "ERROR failed to set power limit GPU $idx to ${watts}W"
    return 1
  fi
}

# Returns non-zero if any bundle could not be set.
#
# sdf1 does not depend on Rancher: a managed cluster keeps running whether the
# management cluster is up or not. Only Fleet state changes and the Rancher admin
# UI need khyron. So a dead Rancher must never delay the sdf1-side scale-down,
# which is the action that actually cools the card — hence the hard timeout. The
# pause is best-effort; the scale is not.
pause_bundles(){
  local paused=$1 b rc=0
  for b in $TARGET_BUNDLES; do
    if (( DRY_RUN )); then log "DRY-RUN would set bundle $b paused=$paused"; continue; fi
    if $KUBECTL --context "$RANCHER_CTX" --request-timeout="$KUBE_TIMEOUT" \
         -n "$FLEET_NS" patch bundle "$b" \
         --type=merge -p "{\"spec\":{\"paused\":$paused}}" >/dev/null 2>&1; then
      log "bundle $b paused=$paused"
    else
      log "WARN could not set paused=$paused on bundle $b (rancher unreachable?)"
      rc=1
    fi
  done
  return $rc
}

ksdf1(){ $KUBECTL --context "$SDF1_CTX" --request-timeout="$KUBE_TIMEOUT" -n "$TARGET_NS" "$@"; }

# Pause first, then scale down — Fleet must never find a state it wants to fight.
# The pause is allowed to fail: sdf1 runs independently of Rancher, so a dead
# management cluster is not a reason to leave the card cooking.
stop_workloads(){
  local d reps
  pause_bundles true || pause_pending=1
  for d in $TARGET_DEPLOYS; do
    reps=$(ksdf1 get deploy "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    [[ $reps =~ ^[0-9]+$ ]] || { log "WARN deploy $d not found, skipping"; continue; }
    if (( reps == 0 )); then log "deploy $d already at 0"; continue; fi
    if (( DRY_RUN )); then log "DRY-RUN would annotate $d prior-replicas=$reps and scale to 0"; continue; fi
    ksdf1 annotate deploy "$d" "$ANNOT=$reps" --overwrite >/dev/null 2>&1
    if ksdf1 scale deploy "$d" --replicas=0 >/dev/null 2>&1; then
      log "scaled $d 0 (was $reps)"
    else
      log "ERROR failed to scale $d to 0"
    fi
  done
}

# Scale up, then unpause — the mirror of the ordering above.
restore_workloads(){
  local d reps
  for d in $TARGET_DEPLOYS; do
    reps=$(ksdf1 get deploy "$d" \
             -o jsonpath="{.metadata.annotations.lab\.ash4d\.com/prior-replicas}" 2>/dev/null)
    [[ $reps =~ ^[0-9]+$ ]] || { log "deploy $d has no prior-replicas annotation, leaving as found"; continue; }
    if (( DRY_RUN )); then log "DRY-RUN would scale $d to $reps and drop the annotation"; continue; fi
    if ksdf1 scale deploy "$d" --replicas="$reps" >/dev/null 2>&1; then
      log "restored $d to $reps"
      ksdf1 annotate deploy "$d" "${ANNOT}-" >/dev/null 2>&1
    else
      log "ERROR failed to restore $d to $reps"
    fi
  done
  # If this fails the bundles stay paused until Rancher is reachable. That is the
  # safe direction: paused means Fleet leaves the restored replicas alone.
  if pause_bundles false; then
    pause_pending=0
  else
    log "WARN bundles left paused — unpause by hand or via sdf1-toggle once rancher is back"
    pause_pending=1
  fi
}

# ---- state -----------------------------------------------------------------
# Persisted under /var/lib rather than /run on purpose: if the node reboots
# while tripped, paused bundles survive on khyron and the deployments stay at 0.
# A guard that forgot it had tripped would leave them off silently forever.
cur_stage=NORMAL
cool_count=0
pause_pending=0        # tripped, but Fleet bundles could not be paused

load_state(){
  [[ -r $STATE ]] || return 0
  # shellcheck disable=SC1090
  . "$STATE"
  cur_stage=${cur_stage:-NORMAL}
  cool_count=${cool_count:-0}
  pause_pending=${pause_pending:-0}
}
save_state(){
  (( DRY_RUN )) && return 0        # simulate must never write real state
  mkdir -p "$STATE_DIR"
  printf 'cur_stage=%s\ncool_count=%s\npause_pending=%s\nupdated=%s\n' \
    "$cur_stage" "$cool_count" "$pause_pending" "$(date -Is)" > "$STATE.tmp" \
    && mv "$STATE.tmp" "$STATE"
}

# ---- the loop --------------------------------------------------------------
# The action for one rung, with no messaging. Kept separate from escalate_to so
# that a jump of several rungs in one poll still performs every rung's action.
do_stage(){
  local s=$1 idx=$2
  case $s in
    NOTIFY) : ;;                                   # alert only, by design
    CAP)    set_power_limit "$idx" "$PL_CAP" ;;
    STOP)   stop_workloads ;;
    FLOOR)  set_power_limit "$idx" "$PL_FLOOR" ;;
  esac
}

# Walk every rung from the held stage up to the target. A V100 with no airflow
# can cross 25C between two 15s polls under a sudden load, so a single poll
# landing straight on FLOOR must still pause bundles and scale workloads down on
# the way past STOP — skipping it would floor the power limit and leave the
# workloads running.
escalate_to(){
  local new=$1 idx=$2 core=$3 mem=$4
  local from=$cur_stage r target s
  target=$(stage_rank "$new")
  for r in 1 2 3 4; do
    (( r <= $(stage_rank "$from") )) && continue
    (( r > target )) && break
    case $r in 1) s=NOTIFY;; 2) s=CAP;; 3) s=STOP;; 4) s=FLOOR;; esac
    log "action for rung $s"
    do_stage "$s" "$idx"
  done

  # One consolidated alert describing the state actually reached.
  case $new in
    NOTIFY)
      slack ":warning: sdf1 V100 ${core}C core / ${mem}C mem — over the NOTIFY threshold (core ${CORE_NOTIFY} / mem ${MEM_NOTIFY}). No action taken. Check the external fan on outlet 6." ;;
    CAP)
      slack ":thermometer: sdf1 V100 ${core}C core / ${mem}C mem — power limit cut to ${PL_CAP}W. Workloads still running. Check the fan." ;;
    STOP)
      slack ":fire: sdf1 V100 ${core}C core / ${mem}C mem — stopped ollama, comfyui, unsloth-studio and paused their Fleet bundles. Power limit ${PL_CAP}W. The fan is probably off." ;;
    FLOOR)
      slack ":rotating_light: sdf1 V100 ${core}C core / ${mem}C mem — over the FLOOR threshold (core ${CORE_FLOOR} / mem ${MEM_FLOOR}), was ${from}. Workloads stopped and power limit floored at ${PL_FLOOR}W. Nothing further is automated — the card throttles itself at 88C and shuts down at 91C. GO LOOK AT THE FAN." ;;
  esac
  cur_stage=$new
  save_state
}

recover(){
  local idx=$1 core=$2 mem=$3 from=$cur_stage
  log "recovery from $from at ${core}C/${mem}C"
  if [[ $from == STOP || $from == FLOOR ]]; then restore_workloads; fi
  if [[ $from == CAP || $from == STOP || $from == FLOOR ]]; then
    set_power_limit "$idx" "$PL_DEFAULT"
  fi
  cur_stage=NORMAL
  cool_count=0
  save_state
  # States the measured temperature rather than asserting the threshold was met:
  # `clear` calls this too, and can be run at any temperature.
  slack ":white_check_mark: sdf1 V100 recovered from ${from} at ${core}C core / ${mem}C mem. Workloads and the ${PL_DEFAULT}W power limit restored."
}

run_daemon(){
  local reading idx core mem want fails=0
  load_state
  log "gpu-guard started — uuid=$GPU_UUID poll=${POLL_SECS}s recover<${RECOVER_TEMP}C stage=$cur_stage dry_run=$DRY_RUN"
  [[ -r $SLACK_WEBHOOK_FILE ]] || log "NOTE $SLACK_WEBHOOK_FILE absent — alerts go to the journal only"
  while :; do
    if ! reading=$(gpu_read); then
      (( fails++ ))
      log "WARN cannot read GPU (attempt $fails)"
      # No data is not a reason to act. Acting blind is worse than waiting.
      (( fails == 20 )) && slack ":grey_question: sdf1 gpu-guard has not been able to read the V100 for $(( fails * POLL_SECS ))s. Driver or card problem — the thermal guard is blind."
      sleep "$POLL_SECS"; continue
    fi
    (( fails )) && { log "GPU readable again"; fails=0; }
    read -r idx core mem <<<"$reading"

    # Fleet could not be paused when we tripped — khyron down, or Rancher itself
    # unhealthy. Nothing is reverting our scale-down while Rancher is away, but
    # the moment it returns Fleet would restore the workloads onto a card that
    # may still be hot. Keep retrying the pause for as long as we hold a stage
    # that scaled anything down.
    if (( pause_pending )) && [[ $cur_stage == STOP || $cur_stage == FLOOR ]]; then
      if pause_bundles true; then
        log "Fleet bundles paused on retry (rancher reachable again)"
        pause_pending=0; save_state
      fi
    fi

    want=$(stage_for "$core" "$mem")
    if (( $(stage_rank "$want") > $(stage_rank "$cur_stage") )); then
      log "escalating $cur_stage -> $want at ${core}C/${mem}C"
      cool_count=0
      escalate_to "$want" "$idx" "$core" "$mem"
    elif [[ $cur_stage != NORMAL ]]; then
      if (( core < RECOVER_TEMP && mem < RECOVER_TEMP )); then
        (( cool_count++ ))
        log "cool $cool_count/$RECOVER_POLLS at ${core}C/${mem}C (stage $cur_stage)"
        (( cool_count >= RECOVER_POLLS )) && recover "$idx" "$core" "$mem"
        save_state
      elif (( cool_count )); then
        cool_count=0; save_state
      fi
    fi
    sleep "$POLL_SECS"
  done
}

# ---- CLI -------------------------------------------------------------------
cmd_status(){
  local reading idx core mem
  load_state
  if reading=$(gpu_read); then
    read -r idx core mem <<<"$reading"
    printf 'V100        index %s  core %sC  memory %sC\n' "$idx" "$core" "$mem"
    printf 'would be    %s\n' "$(stage_for "$core" "$mem")"
    printf 'power limit %s\n' "$(nvidia-smi -i "$idx" --query-gpu=power.limit --format=csv,noheader 2>/dev/null)"
  else
    printf 'V100        UNREADABLE (uuid %s)\n' "$GPU_UUID"
  fi
  printf 'held stage  %s\n' "$cur_stage"
  printf 'cool count  %s/%s\n' "$cool_count" "$RECOVER_POLLS"
  (( pause_pending )) && printf 'fleet       PAUSE PENDING — rancher was unreachable, retrying each poll\n'
  printf 'thresholds  notify %s  cap %s  stop %s  floor %s  recover <%s\n' \
    "$CORE_NOTIFY" "$CORE_CAP" "$CORE_STOP" "$CORE_FLOOR" "$RECOVER_TEMP"
  [[ -r $SLACK_WEBHOOK_FILE ]] && printf 'alerting    slack\n' || printf 'alerting    journal only (no %s)\n' "$SLACK_WEBHOOK_FILE"
}

# Simulate a temperature and print the ladder decision without touching anything.
# This exists so a warning branch can be exercised without invoking the command
# that mutates state — the mistake that cut rack power to the fan on 2026-08-02.
cmd_simulate(){
  local core=${1:?usage: simulate <core-temp> [mem-temp]} mem=${2:-$1}
  load_state
  local want; want=$(stage_for "$core" "$mem")
  printf 'at %sC core / %sC mem, held stage %s -> ladder says %s\n' "$core" "$mem" "$cur_stage" "$want"
  if (( $(stage_rank "$want") > $(stage_rank "$cur_stage") )); then
    printf 'would escalate. Actions:\n'
    DRY_RUN=1 escalate_to "$want" 1 "$core" "$mem"
  elif [[ $cur_stage != NORMAL ]] && (( core < RECOVER_TEMP && mem < RECOVER_TEMP )); then
    printf 'would count toward recovery (%s more polls). Actions on recovery:\n' "$(( RECOVER_POLLS - cool_count ))"
    DRY_RUN=1 recover 1 "$core" "$mem"
  else
    printf 'would hold at %s, no action\n' "$cur_stage"
  fi
}

cmd_clear(){
  load_state
  [[ $cur_stage == NORMAL ]] && { echo "already NORMAL, nothing held"; return 0; }
  local reading idx core mem
  if reading=$(gpu_read); then
    read -r idx core mem <<<"$reading"
  else
    idx=1; core=0; mem=0
    echo "WARN GPU unreadable; restoring anyway on your instruction"
  fi
  echo "clearing held stage $cur_stage at ${core}C/${mem}C"
  recover "$idx" "$core" "$mem"
}

case ${1:-daemon} in
  daemon)          shift || true; [[ ${1:-} == --dry-run ]] && DRY_RUN=1; run_daemon ;;
  status)          cmd_status ;;
  simulate)        shift; cmd_simulate "$@" ;;
  clear)           cmd_clear ;;
  test-alert)      slack ":bell: sdf1 gpu-guard test alert — delivery works." ; echo "sent (or logged if unconfigured)" ;;
  *) cat >&2 <<EOF
usage: gpu-guard.sh [daemon [--dry-run] | status | simulate <core> [mem] | clear | test-alert]

  daemon      poll and act (what systemd runs)
  status      current temps, held stage, thresholds, alert path
  simulate    print what a given temperature would do, touching nothing
  clear       restore workloads and power limit now, clearing a held stage
  test-alert  prove the Slack path end to end
EOF
     exit 2 ;;
esac
