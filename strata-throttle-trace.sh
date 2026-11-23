#!/usr/bin/env bash
# Per-second throttle trace in balanced / performance / balanced, Strata active engine, IQ3_S, 64k, DFlash2, SSD conversation cache off.
# The performance arm uses a temporary power-profiles hold that ends with the arm. No root needed.
set -uo pipefail
cd /home/sum/Downloads/AI-Runtime
STRATA=~/.local/bin/strata; COOL=65; STAMP=$(date +%Y%m%d-%H%M); hold=""
MODEL_DIR=/home/sum/.cache/lm-studio/models/ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-GGUF
ARMS="balanced performance balanced"
BT=$(mktemp -d); mkdir -p $BT/btop
printf 'update_ms = 1000\nshown_boxes = "cpu"\nshow_cpu_watts = True\nshow_gpu_info = "Off"\n' > $BT/btop/btop.conf
cpu_t() { sensors 2>/dev/null | awk '/Package id 0/{gsub(/[+°C]/,"",$4); print int($4)}'; }
say() { echo "[$(date +%H:%M:%S)] $*"; }
release() { if [[ -n $hold ]]; then pkill -P $hold -x sleep 2>/dev/null; wait $hold 2>/dev/null; hold=""; fi; }
cleanup() { release; tmux -L strata-probe kill-server 2>/dev/null; $STRATA launch --stop </dev/null >/dev/null 2>&1; rm -rf "$BT"; say "cleaned up; profile $(cat /sys/firmware/acpi/platform_profile)"; }
trap cleanup EXIT
trap 'exit 143' TERM INT
tmux -L strata-probe kill-server 2>/dev/null
tmux -L strata-probe new-session -d -x 170 -y 34 "env XDG_CONFIG_HOME=$BT btop"
sleep 2
say "# trace $STAMP  arms: $ARMS  engine: $($STRATA --version | awk '{print $4}' | tr -d ';')"
i=0
for a in $ARMS; do
    i=$((i+1)); $STRATA launch --stop </dev/null >/dev/null 2>&1
    for k in $(seq 1 60); do [[ $(cpu_t) -lt $COOL ]] && break; sleep 5; done
    if [[ $a == performance ]]; then
        /usr/bin/python3 /usr/bin/powerprofilesctl launch -p performance -r strata-throttle-trace -i strata-throttle-trace sleep 1200 & hold=$!
        sleep 2
    fi
    say "=== arm $i: $a, profile $(cat /sys/firmware/acpi/platform_profile), CPU $(cpu_t)C"
    $STRATA launch --model-path $MODEL_DIR --model iq3_s --context 64k --vision off --access local --port 8099 --no-api-key --yes --no-tui --restart \
      --drafting dflash2 --set STRATA_ROUTE_TAIL_SKIP=0 --set STRATA_ROUTE_PRIOR=1.5 --set conversation-spill-mib=0 </dev/null >/dev/null 2>&1
    ok=0; for k in $(seq 1 90); do curl -s -m3 localhost:8099/v1/models | grep -q '"loaded"' && { ok=1; break; }; sleep 2; done
    (( ok )) || { say "arm $i: server not ready"; exit 1; }
    pid=$(pgrep -x strata-host | head -1); [[ -n $pid ]] || pid=$(pgrep -x strata | head -1)
    [[ -n $pid ]] || { say "arm $i: engine process not found"; exit 1; }
    python3 -I strata-throttle-trace.py $a $pid strata-throttle-trace-$STAMP-$i-$a.jsonl || { say "arm $i: trace failed"; exit 1; }
    release
done
say "# trace done: strata-throttle-trace-$STAMP-*.jsonl"
