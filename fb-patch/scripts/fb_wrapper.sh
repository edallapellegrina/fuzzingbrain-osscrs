#!/bin/bash
# ==============================================================================
# OSS-CRS -> FuzzingBrain wrapper
#
# This wrapper consumes the target through the OSS-CRS runtime interface
# (the OSS_CRS_* environment variables and mounts) rather than expecting a
# pre-staged /app/workspace. It assembles the workspace layout FuzzingBrain
# expects from those mounts, runs FuzzingBrain, then copies any POVs back
# into $OSS_CRS_SUBMIT_DIR.
#
# Framework inputs (provided by OSS-CRS at run time):
#   $OSS_CRS_TARGET          project name, e.g. "cjson"
#   $OSS_CRS_TARGET_HARNESS  harness binary name, e.g. "fuzz_target"
#   $OSS_CRS_TARGET_SOURCE   target source tree (a git repo)
#   $OSS_CRS_FUZZ_PROJ       OSS-Fuzz project dir (Dockerfile, build.sh, project.yaml)
#   $OSS_CRS_BUILD_OUT_DIR   built harness output (contains build/<harness>)
#   $OSS_CRS_FETCH_DIR       task inputs: diffs/, seeds/, povs/, bug-candidates/
#   $OSS_CRS_SUBMIT_DIR      where discovered POVs must be written
#   $OSS_CRS_SHARED_DIR      scratch space shared across phases
# ==============================================================================

set -uo pipefail

log() { echo "[wrapper] $*"; }

# ------------------------------------------------------------------------------
# 0. Resolve inputs from the framework environment
# ------------------------------------------------------------------------------
TARGET="${OSS_CRS_TARGET:?OSS_CRS_TARGET not set}"
HARNESS="${OSS_CRS_TARGET_HARNESS:-fuzz_target}"
SAN="${SANITIZER:-address}"
SRC_DIR="${OSS_CRS_TARGET_SOURCE:?OSS_CRS_TARGET_SOURCE not set}"
FUZZ_PROJ="${OSS_CRS_FUZZ_PROJ:?OSS_CRS_FUZZ_PROJ not set}"
BUILD_OUT="${OSS_CRS_BUILD_OUT_DIR:?OSS_CRS_BUILD_OUT_DIR not set}"
FETCH_DIR="${OSS_CRS_FETCH_DIR:-}"
SUBMIT_DIR="${OSS_CRS_SUBMIT_DIR:-/tmp/submit}"

# Build the workspace at a path that is identical inside the container and on
# the host, so inner OSS-Fuzz containers (spawned by FuzzingBrain via the Docker
# socket) resolve bind mounts correctly
HOST_SHARED="${OSS_CRS_SHARED_DIR_HOST:-}"
if [ -n "${HOST_SHARED}" ] && [ "${HOST_SHARED}" != "${OSS_CRS_SHARED_DIR}" ]; then
    # Recreate the host directory path inside the container, pointing at the
    # same bind-mounted content, so $WS is valid on both sides
    mkdir -p "$(dirname "${HOST_SHARED}")"
    ln -sfn "${OSS_CRS_SHARED_DIR}" "${HOST_SHARED}"
    WS_ROOT="${HOST_SHARED}"
else
    WS_ROOT="${OSS_CRS_SHARED_DIR:-/app/workspace}"
fi
WS="${WS_ROOT}/${TARGET}"

log "target=${TARGET} harness=${HARNESS} sanitizer=${SAN}"
log "assembling workspace at ${WS}"

# ------------------------------------------------------------------------------
# 1. Fresh workspace skeleton
# ------------------------------------------------------------------------------
rm -rf "${WS}"
mkdir -p "${WS}/repo" \
         "${WS}/fuzz-tooling/projects/${TARGET}" \
         "${WS}/fuzz-tooling/build/out/${TARGET}-${SAN}" \
         "${WS}/diff"
cp -a "${WS}/repo" "${WS}/repo-${SAN}"

# ------------------------------------------------------------------------------
# 2. repo/  <-  the target source (a git repo)
# ------------------------------------------------------------------------------
log "populating repo/ from ${SRC_DIR}"
cp -a "${SRC_DIR}/." "${WS}/repo/"

# ------------------------------------------------------------------------------
# 3. fuzz-tooling/  <-  OSS-Fuzz infra (helper.py etc.)
# ------------------------------------------------------------------------------
if [ -f /app/oss-fuzz/infra/helper.py ]; then
    log "using bundled OSS-Fuzz infra"
    cp -a /app/oss-fuzz/infra "${WS}/fuzz-tooling/infra"
else
    log "cloning shallow OSS-Fuzz for infra/"
    git clone --depth 1 https://github.com/google/oss-fuzz.git /tmp/oss-fuzz-infra 2>/dev/null \
        && cp -a /tmp/oss-fuzz-infra/infra "${WS}/fuzz-tooling/infra" \
        || { log "ERROR: could not obtain OSS-Fuzz infra/"; }
fi

# project files (Dockerfile, build.sh, project.yaml) for this target only
cp -a "${FUZZ_PROJ}/." "${WS}/fuzz-tooling/projects/${TARGET}/"

# ------------------------------------------------------------------------------
# 4. Pre-built harness  <-  BUILD_OUT/build/*  into the location FuzzingBrain
#    reads (fuzz-tooling/build/out/<target>-<san>/), and into each per-attempt 
#    dir it mounts as /out. This lets FuzzingBrain skip rebuilding, since
#    OSS-CRS already built the target.
# ------------------------------------------------------------------------------
FUZZ_OUT_DIR="${WS}/fuzz-tooling/build/out/${TARGET}-${SAN}"
PRISTINE="${WS_ROOT}/.pristine-build-${TARGET}"
if [ -d "${BUILD_OUT}/build" ]; then
    log "copying pre-built harness from ${BUILD_OUT}/build"
    rm -rf "${PRISTINE}" && mkdir -p "${PRISTINE}"
    cp -a "${BUILD_OUT}/build/." "${PRISTINE}/" # the one real copy

    # FuzzingBrain mounts per-attempt dirs (xp*/ap*) as /out and runs
    # /out/<harness> there. Populate them with HARD LINKS to the single copy:
    # JVM builds carry a Maven repo and jars (GBs), and real copies per attempt
    # dir exhaust the disk. FuzzingBrain only adds blobs to these dirs and never
    # rewrites build files, so sharing them is safe. Falls back to a real copy
    # if linking isn't possible.
    for d in "" xp0 xp1 xp2 xp3 xp4 ap0 ap1 ap2 ap3 ap4; do
        mkdir -p "${FUZZ_OUT_DIR}/${d}"
        cp -al "${PRISTINE}/." "${FUZZ_OUT_DIR}/${d}/" 2>/dev/null \
            || cp -a "${PRISTINE}/." "${FUZZ_OUT_DIR}/${d}/"
    done
    log "seeded xp*/ap* attempt dirs with harness binary (hard links)"
    # Restrict FuzzingBrain to the requested harness. 
    is_harness() {
        local f="$1" b
        b=$(basename "$f")
        [ -f "$f" ] && [ -x "$f" ] || return 1
        case "$b" in
            llvm-symbolizer|jazzer_*|*.so|*.so.*|*.jar|*.class|*.zip|*.options|*.dict) return 1 ;;
        esac
        # libFuzzer binaries carry this symbol; OSS-Fuzz JVM launcher scripts
        # carry it as a comment so that harness detection finds them.
        grep -aqs "LLVMFuzzerTestOneInput" "$f"
    }
    if is_harness "${FUZZ_OUT_DIR}/${HARNESS}"; then
        removed=0
        for d in "${FUZZ_OUT_DIR}" "${FUZZ_OUT_DIR}"/xp* "${FUZZ_OUT_DIR}"/ap*; do
            [ -d "$d" ] || continue
            for f in "$d"/*; do
                [ "$(basename "$f")" = "${HARNESS}" ] && continue
                if is_harness "$f"; then rm -f "$f"; removed=$((removed+1)); fi
            done
        done
        log "restricted to harness '${HARNESS}' (removed ${removed} other harness file(s))"
    else
        log "WARN: '${HARNESS}' not recognised as a harness in ${FUZZ_OUT_DIR}; leaving all harnesses in place"
    fi
else
    log "WARN: ${BUILD_OUT}/build not found; FuzzingBrain will build from source"
fi

# ------------------------------------------------------------------------------
# 5. diff/  <-  the delta
# ------------------------------------------------------------------------------
MODE="full"
if [ -n "${FETCH_DIR}" ] && compgen -G "${FETCH_DIR}/diffs/*" >/dev/null 2>&1; then
    log "using framework-provided diff from ${FETCH_DIR}/diffs/"
    cp -a "${FETCH_DIR}/diffs/." "${WS}/diff/"
    # normalise to ref.diff if a single file was provided under another name
    if [ ! -f "${WS}/diff/ref.diff" ]; then
        first_diff=$(find "${WS}/diff" -type f | head -1)
        [ -n "${first_diff}" ] && cp "${first_diff}" "${WS}/diff/ref.diff"
    fi
    MODE="delta"
elif [ -f "${FUZZ_PROJ}/ref.diff" ]; then
    log "using ref.diff shipped in the OSS-Fuzz project dir"
    cp "${FUZZ_PROJ}/ref.diff" "${WS}/diff/ref.diff"
    MODE="delta"
else
    log "no diff provided; treating as FULL-scan task"
    rm -rf "${WS}/diff"
fi

# ------------------------------------------------------------------------------
# 6. task_detail.json  <-  synthesised from the framework environment
# ------------------------------------------------------------------------------
DEADLINE_MS=$(( ( $(date +%s) + 4*3600 ) * 1000 ))
cat > "${WS}/task_detail.json" <<EOF
{
  "task_id": "$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo run-${OSS_CRS_RUN_ID:-0})",
  "type": "${MODE}",
  "harnesses_included": true,
  "deadline": ${DEADLINE_MS},
  "focus": "repo",
  "project_name": "${TARGET}",
  "source": null,
  "metadata": {},
  "state": ""
}
EOF
log "wrote task_detail.json (type=${MODE})"
cp "${WS}/task_detail.json" "${WS}/fuzz-tooling/build/out/${TARGET}-${SAN}/task_detail.json"

# ------------------------------------------------------------------------------
# 7. LLM routing: stage sitecustomize + write .env
# ------------------------------------------------------------------------------
mkdir -p /app/patchdir
if [ -f /usr/lib/python3.10/sitecustomize.py ] && [ ! -f /app/patchdir/sitecustomize.py ]; then
    cp /usr/lib/python3.10/sitecustomize.py /app/patchdir/sitecustomize.py
fi
export PYTHONPATH="/app/patchdir${PYTHONPATH:+:$PYTHONPATH}"

LLM_BASE="${FUZZBRAIN_LLM_ENDPOINT:-http://172.17.0.1:11435/v1}"
LLM_BASE_NO_V1="${LLM_BASE%/v1}"
mkdir -p /app/crs
cat > /app/crs/.env <<EOF
OPENAI_API_KEY=${OPENAI_API_KEY:-ollama}
OPENAI_BASE_URL=${LLM_BASE}
OPENAI_API_BASE=${LLM_BASE}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-ollama}
ANTHROPIC_BASE_URL=${LLM_BASE_NO_V1}
PYTHONPATH=/app/patchdir
STRATEGY_BASE_DIR=/app/strategy
STRATEGY_NEW_DIR=jeff
STRATEGY_POV_ADVANCED_DELTA_PATTERN=xs0_delta.py
STRATEGY_POV_ADVANCED_FULL_PATTERN=as0_full.py
STRATEGY_POV_SELECTED_BASIC="none"
STRATEGY_POV_SELECTED_ADVANCED=""
STRATEGY_ENABLE_PATCHING=true
OTEL_SDK_DISABLED=true
ADVANCED_FUZZER_TEST=1
FUZZER_SANITIZERS="${SAN}"
FUZZER_PREFERRED_SANITIZER="${SAN}"
FUZZER_DISCOVERY_MODE="auto"
EOF
export OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}" ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-ollama}"
export OPENAI_BASE_URL="${LLM_BASE}" OPENAI_API_BASE="${LLM_BASE}" ANTHROPIC_BASE_URL="${LLM_BASE_NO_V1}"
log "LLM endpoint: ${LLM_BASE}"

# ------------------------------------------------------------------------------
# 8. Run FuzzingBrain against the assembled workspace
# ------------------------------------------------------------------------------
log "launching FuzzingBrain: /app/FuzzingBrain.sh --in-place ${WS}"
FB_EXIT=0
setsid /app/FuzzingBrain.sh --in-place "${WS}" || FB_EXIT=$?
log "FuzzingBrain exited with status ${FB_EXIT}"

# ------------------------------------------------------------------------------
# 9. Propagate POVs via libCRS interface
# ------------------------------------------------------------------------------
# mkdir -p "${SUBMIT_DIR}"
FUZZ_OUT="${WS}/fuzz-tooling/build/out/${TARGET}-${SAN}"
count=0
if [ -d "${FUZZ_OUT}" ]; then
    while IFS= read -r pov; do
        if libCRS submit pov "${pov}"; then
            log "submitted POV: ${pov}"
            count=$((count+1))
        else
            log "WARN: libCRS submit failed for ${pov}"
        fi
    done < <(find "${FUZZ_OUT}" -path "*/successful_povs_advanced/*.bin" -type f 2>/dev/null | sort -u)
fi
log "submitted ${count} POV(s) via libCRS"

# ------------------------------------------------------------------------------
# 10. Propagate validated patches via libCRS. Only successful_patches/ holds
#     patches FuzzingBrain has rebuilt and re-tested against the POV; other
#     *.diff files in the workspace are inputs, OSS-Fuzz infra, or candidates.
# ------------------------------------------------------------------------------
patch_count=0
while IFS= read -r patchfile; do
    if libCRS submit patch "${patchfile}"; then
        log "submitted patch: ${patchfile}"
        patch_count=$((patch_count+1))
    else
        log "WARN: libCRS submit patch failed for ${patchfile}"
    fi
done < <(find "${WS}" -path "*/successful_patches/*.diff" -type f 2>/dev/null | sort -u)
log "submitted ${patch_count} patch(es) via libCRS"

# FuzzingBrain is SIGKILLed during post-success strategy cancellation in some
# configurations; if artefacts were submitted, the run succeeded.
if [ "${FB_EXIT}" -ne 0 ] && [ "${count}" -gt 0 ]; then
    log "artefacts submitted despite exit ${FB_EXIT}; reporting success"
    FB_EXIT=0
fi

exit "${FB_EXIT}"