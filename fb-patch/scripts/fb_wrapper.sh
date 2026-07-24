#!/bin/bash

# ==============================================================================
# OSS-CRS -> FuzzingBrain wrapper
#
# This script prepares the execution environment expected by FuzzingBrain when
# running inside the OSS-CRS framework.
#
# Tasks:
#   - Validate the target workspace
#   - Configure the Python environment
#   - Configure LLM endpoints
#   - Launch FuzzingBrain
#   - Collect generated POVs and patches
#   - Submit results back through libCRS
# ==============================================================================

# Exit immediately if:
#   - a command fails (-e)
#   - an undefined variable is used (-u)
#   - any command in a pipeline fails (-o pipefail)
set -euo pipefail

# Read configuration from environment variables
# Target project/workspace
TARGET="${FUZZBRAIN_TARGET:-${OSS_CRS_TARGET:-example}}"
# Workspace directory for the selected target
WORKSPACE="/app/workspace/${TARGET}"
# Project name (used later when locating output files)
PROJECT="${TARGET}"
# Sanitizer used by the fuzzing build
SAN="${SANITIZER:-address}"
# Optional harness selection
HARNESS="${OSS_CRS_TARGET_HARNESS:-}"

# Validate the workspace
# Ensure the workspace exists
if [ ! -d "$WORKSPACE" ]; then
    echo "[wrapper] ERROR: /app/workspace/${TARGET} does not exist in container." >&2
    echo "[wrapper] Available targets:" >&2
    ls -1 /app/workspace/ 2>/dev/null | sed 's/^/  /' >&2 || true
    exit 1
fi
# Ensure this is a valid FuzzingBrain workspace
if [ ! -f "$WORKSPACE/task_detail.json" ]; then
    echo "[wrapper] ERROR: $WORKSPACE/task_detail.json missing — not a valid FuzzingBrain workspace" >&2
    exit 1
fi

echo "[wrapper] Using workspace: $WORKSPACE"
cat "$WORKSPACE/task_detail.json" | head -20

# Create directories for generated artifacts
mkdir -p /artifacts/povs /artifacts/corpus
# Register output dirs with libCRS [currently disabled]
#libCRS register-submit-dir pov /artifacts/povs || true
#libCRS register-submit-dir seed /artifacts/corpus || true

# Stage sitecustomize.py at /app/patchdir/.
# Python automatically imports sitecustomize.py during startup.
# This is used here to patch LiteLLM so that every Python process automatically uses the desired LLM endpoint.
mkdir -p /app/patchdir
if [ -f /usr/lib/python3.10/sitecustomize.py ] && \
   [ ! -f /app/patchdir/sitecustomize.py ]; then
    cp /usr/lib/python3.10/sitecustomize.py /app/patchdir/sitecustomize.py
fi
# Ensure Python loads the custom startup module first
export PYTHONPATH="/app/patchdir${PYTHONPATH:+:$PYTHONPATH}"

# Configure LLM access
mkdir -p /app/crs
# Default OpenAI-compatible endpoint
LLM_BASE="${FUZZBRAIN_LLM_ENDPOINT:-http://host.docker.internal:11435/v1}"
# Some APIs expect the base URL without "/v1"
LLM_BASE_NO_V1="${LLM_BASE%/v1}"
# Generate FuzzingBrain's .env configuration file
cat > /app/crs/.env <<EOF
OPENAI_API_KEY=${OPENAI_API_KEY:-ollama}
OPENAI_BASE_URL=${LLM_BASE}
OPENAI_API_BASE=${LLM_BASE}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-ollama}
ANTHROPIC_BASE_URL=${LLM_BASE_NO_V1}
GEMINI_API_KEY=${GEMINI_API_KEY:-}
XAI_API_KEY=${XAI_API_KEY:-}
PYTHONPATH=/app/patchdir

# Strategy configuration
STRATEGY_BASE_DIR=/app/strategy
STRATEGY_NEW_DIR=jeff
STRATEGY_POV_ADVANCED_DELTA_PATTERN=xs0_delta.py
STRATEGY_POV_ADVANCED_FULL_PATTERN=as0_full.py
STRATEGY_PATCH_DELTA_PATTERN=patch0_delta.py
STRATEGY_PATCH_FULL_PATTERN=patch0_full.py

# Strategy selection
STRATEGY_POV_SELECTED_BASIC="none"
STRATEGY_POV_SELECTED_ADVANCED=""
STRATEGY_PATCH_SELECTED="none"
STRATEGY_XPATCH_SELECTED="none"
STRATEGY_ENABLE_PATCHING=false

# Disable OpenTelemetry reporting
OTEL_SDK_DISABLED=true

# Fuzzer configuration
ADVANCED_FUZZER_TEST=1
DETECT_TIMEOUT_CRASH=0
DETECT_LEAK_AS_CRASH=0
FUZZER_SANITIZERS="address"
FUZZER_PREFERRED_SANITIZER="address"
FUZZER_DISCOVERY_MODE="auto"
EOF
echo "[wrapper] Wrote /app/crs/.env (LLM endpoint: ${LLM_BASE})"

# Export the same variables so the current shell and child processes also inherit them
export OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-ollama}"
export OPENAI_BASE_URL="${LLM_BASE}"
export OPENAI_API_BASE="${LLM_BASE}"
export ANTHROPIC_BASE_URL="${LLM_BASE_NO_V1}"

echo "[wrapper] LLM endpoint: ${LLM_BASE}"
echo "[wrapper] PYTHONPATH:   ${PYTHONPATH}"
echo "[wrapper] exec: /app/FuzzingBrain.sh --in-place $WORKSPACE"

FB_EXIT=0
# Run FuzzingBrain
/app/FuzzingBrain.sh --in-place "$WORKSPACE" || FB_EXIT=$?
echo "[wrapper] FuzzingBrain exited with status $FB_EXIT"

# # Submit discovered POVs
echo "[wrapper] Submitting POVs via libCRS"

# FuzzingBrain stores crash inputs under fuzz-tooling/build/out/<project>-<sanitizer>/.../xp*/x_*.bin
FUZZ_OUT="$WORKSPACE/fuzz-tooling/build/out/${PROJECT}-${SAN}"
if [ -d "$FUZZ_OUT" ]; then
    find "$FUZZ_OUT" -path "*/xp*/x_*.bin" -type f 2>/dev/null | while read -r povfile; do
        echo "[wrapper] Submitting POV: $povfile"
        libCRS submit pov "$povfile" || echo "[wrapper] Submit failed for $povfile"
    done
fi

# Submit generated patches
PATCH_DIR="$FUZZ_OUT/successful_patches"
if [ -d "$PATCH_DIR" ]; then
    find "$PATCH_DIR" \( -name "*.patch" -o -name "*.diff" \) -type f 2>/dev/null | while read -r patchfile; do
        echo "[wrapper] Submitting patch: $patchfile"
        libCRS submit patch "$patchfile" || echo "[wrapper] Submit failed for $patchfile"
    done
fi

# Return FuzzingBrain's exit code to the caller
exit $FB_EXIT