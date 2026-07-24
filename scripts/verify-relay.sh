#!/usr/bin/env bash
#
# Confirm the integration's networking chain end-to-end:
#   direct loopback  : 127.0.0.1:11434  -> Ollama
#   via the relay    : 172.17.0.1:11435 -> Ollama
#
# Both queries should return the same non-empty list of local models.
# The second query is the one that matters: if it fails, containers
# will not be able to reach the model, and every LLM call in the
# pipeline will hang or time out.

set -uo pipefail

DIRECT_URL="${DIRECT_URL:-http://127.0.0.1:11434/api/tags}"
RELAY_URL="${RELAY_URL:-http://172.17.0.1:11435/api/tags}"

pass=true

echo "[verify] direct $DIRECT_URL"
if ! out=$(curl -sS --max-time 5 "$DIRECT_URL"); then
    echo "Fail: could not reach Ollama on loopback"
    echo "Check Ollama daemon status: systemctl --user status ollama"
    pass=false
elif ! echo "$out" | grep -q '"models"'; then
    echo "Fail: unexpected response from loopback:"
    echo "$out"
    pass=false
else
    echo "OK: Ollama reachable on loopback"
    echo "Models: $(echo "$out" | tr -d '\n' | head -c 200)..."
fi

echo
echo "[verify] relay $RELAY_URL"
if ! out=$(curl -sS --max-time 5 "$RELAY_URL"); then
    echo "Fail: could not reach the relay"
    echo "Check if the relay is running: pgrep -af ollama_relay.py"
    echo "If not, start it: nohup python3 ~/ollama_relay.py > ~/ollama_relay.log 2>&1 &"
    pass=false
elif ! echo "$out" | grep -q '"models"'; then
    echo "Fail: relay reachable but returned unexpected response:"
    echo "$out"
    pass=false
else
    echo "OK: relay forwards correctly to Ollama"
fi

echo
if $pass; then
    echo "[verify] All checks passed. The FuzzingBrain container will be able to reach the local model at 172.17.0.1:11435"
    exit 0
else
    echo "[verify] One or more checks failed. Fix these before running the pipeline"
    exit 1
fi
