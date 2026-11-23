#!/usr/bin/env bash
# Steady-speed A/B against the XPS 15 SEN6 brake: Strata active engine, IQ3_S, 64k, DFlash2, SSD conversation cache off.
# Arms: balanced, power-saver (saver), 5 P-core workers (p5), both (saverp5). Each arm starts at SEN6 <= 58C and CPU < 65C.
# Profiles use temporary power-profiles holds that end with the arm. Traces: strata-steady-ab-<stamp>-<n>-<arm>.jsonl. No root needed.
set -uo pipefail
cd /home/sum/Downloads/AI-Runtime
STRATA=~/.local/bin/strata; STAMP=$(date +%Y%m%d-%H%M); hold=""
MODEL_DIR=/home/sum/.cache/lm-studio/models/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-GGUF
ARMS=$(printenv AB_ARMS || echo "saver p5 saverp5 balanced")
export TRACE_ROUNDS=4
BT=$(mktemp -d); mkdir -p $BT/btop
printf 'update_ms = 1000\nshown_boxes = "cpu"\nshow_cpu_watts = True\nshow_gpu_info = "Off"\n' > $BT/btop/btop.conf
cpu_t() { sensors 2>/dev/null | awk '/Package id 0/{gsub(/[+°C]/,"",$4); print int($4)}'; }
sen6() { for z in /sys/class/thermal/thermal_zone*; do [[ $(cat $z/type) == SEN6 ]] && echo $(( $(cat $z/temp)/1000 )); done; }
say() { echo "[$(date +%H:%M:%S)] $*"; }
release() { if [[ -n $hold ]]; then pkill -P $hold -x sleep 2>/dev/null; wait $hold 2>/dev/null; hold=""; fi; }
cleanup() { release; tmux -L strata-probe kill-server 2>/dev/null; $STRATA launch --stop </dev/null >/dev/null 2>&1; rm -rf "$BT"; say "cleaned up; profile $(cat /sys/firmware/acpi/platform_profile)"; }
trap cleanup EXIT
trap 'exit 143' TERM INT
tmux -L strata-probe kill-server 2>/dev/null
tmux -L strata-probe new-session -d -x 170 -y 34 "env XDG_CONFIG_HOME=$BT btop"
sleep 2
say "# steady A/B $STAMP  arms: $ARMS  rounds: $TRACE_ROUNDS  engine: $($STRATA --version | awk '{print $4}' | tr -d ';')"
i=0
for a in $ARMS; do
    i=$((i+1)); $STRATA launch --stop </dev/null >/dev/null 2>&1
    for k in $(seq 1 60); do [[ $(cpu_t) -lt 65 && $(sen6) -le 58 ]] && break; sleep 5; done
    sets=""; prof=balanced
    case $a in
      balanced) ;;
      saver) prof=power-saver;;
      p5) sets="--set pool-affinity=p-cores --set pool-workers=5";;
      saverp5) prof=power-saver; sets="--set pool-affinity=p-cores --set pool-workers=5";;
      *) say "unknown arm $a"; exit 1;;
    esac
    if [[ $prof != balanced ]]; then
        /usr/bin/python3 /usr/bin/powerprofilesctl launch -p $prof -r strata-steady-ab -i strata-steady-ab sleep 1500 & hold=$!
        sleep 2
    fi
    say "=== arm $i: $a, profile $(cat /sys/firmware/acpi/platform_profile), CPU $(cpu_t)C, SEN6 $(sen6)C"
    $STRATA launch --model-path $MODEL_DIR --model iq3_s --context 64k --vision off --access local --port 8099 --no-api-key --yes --no-tui --restart \
      --drafting dflash2 --set STRATA_ROUTE_TAIL_SKIP=0 --set STRATA_ROUTE_PRIOR=1.5 --set conversation-spill-mib=0 $sets </dev/null >/dev/null 2>&1
    ok=0; for k in $(seq 1 90); do curl -s -m3 localhost:8099/v1/models | grep -q '"loaded"' && { ok=1; break; }; sleep 2; done
    (( ok )) || { say "arm $i: server not ready"; exit 1; }
    pid=$(pgrep -x strata-host | head -1); [[ -n $pid ]] || pid=$(pgrep -x strata | head -1)
    [[ -n $pid ]] || { say "arm $i: engine process not found"; exit 1; }
    python3 -I strata-throttle-trace.py $a $pid strata-steady-ab-$STAMP-$i-$a.jsonl || { say "arm $i: trace failed"; exit 1; }
    release
done
say "# steady A/B done: strata-steady-ab-$STAMP-*.jsonl"
