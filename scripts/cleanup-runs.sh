#!/usr/bin/env bash
#
# cleanup-runs.sh -- reclaim disk and Docker resources consumed by
# FuzzingBrain × OSS-CRS runs.
#
# A single run can produce tens of gigabytes (workspace copies, per-attempt
# harness binaries, FuzzingBrain's prompt-level logs), plus one builder image,
# several containers, and three bridge networks per invocation. Left
# unattended this saturates the disk, and leaked networks exhaust Docker's
# default address pools (~30 bridges), after which every run fails with
# "all predefined address pools have been fully subnetted".
#
# The script only touches objects it can positively identify as belonging to 
# this integration:
#   * containers named crs_compose_*
#   * networks named crs_compose_* (only when no container is attached)
#   * images tagged oss-crs-builder:fuzzingbrain-build-*
#   * dangling (untagged, unreferenced) images
#   * run/build directories under the given OSS-CRS work directory
#
# Running crs_compose_* containers are left alone by default, since they may
# belong to a campaign in progress. `oss-crs build-target` leaves its sidecars
# running after it finishes, though, and those pin networks. Pass
# --include-running between campaigns to remove them too.
#
# Dry-run by default. Nothing is deleted until you pass --yes.
#
# Usage:
#   scripts/cleanup-runs.sh                          # show what would be removed
#   scripts/cleanup-runs.sh --yes                    # apply
#   scripts/cleanup-runs.sh --yes --include-running  # also remove leftover sidecars
#   scripts/cleanup-runs.sh --yes --keep 3           # keep the 3 newest runs
#   scripts/cleanup-runs.sh --yes --all-runs         # remove every run dir
#   scripts/cleanup-runs.sh --workdir /path/.oss-crs-workdir --yes

set -uo pipefail

# --- defaults ---------------------------------------------------------------
WORKDIR="${OSS_CRS_WORKDIR:-$HOME/fuzzingbrain-osscrs/oss-crs/.oss-crs-workdir}"
FB_IMAGE="${FB_IMAGE:-ghcr.io/o2lab/fuzzingbrain:latest}"
KEEP=1               # how many newest run/build dirs to retain
APPLY=0              # 0 = dry run
ALL_RUNS=0
INCLUDE_RUNNING=0

log()  { echo "[cleanup] $*"; }
warn() { echo "[cleanup] WARN: $*" >&2; }
run()  { if [ "$APPLY" -eq 1 ]; then eval "$@"; else echo "    would run: $*"; fi; }

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y)          APPLY=1; shift ;;
        --keep)            KEEP="${2:-1}"; shift 2 ;;
        --all-runs)        ALL_RUNS=1; shift ;;
        --include-running) INCLUDE_RUNNING=1; shift ;;
        --workdir)         WORKDIR="${2:-}"; shift 2 ;;
        -h|--help)         sed -n '2,45p' "$0"; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
done

[ "$APPLY" -eq 1 ] || log "DRY RUN -- pass --yes to apply"
log "workdir = $WORKDIR   keep = $KEEP newest"

BEFORE=$(df -h / | awk 'NR==2{print $4}')
log "disk available before: $BEFORE"
echo

# ---------------------------------------------------------------------------
# 1. crs_compose_* containers
#
# Removed first: containers pin both their images and their networks, so
# nothing downstream can be reclaimed while they exist.
# ---------------------------------------------------------------------------
log "== crs_compose_* containers =="
if [ "$INCLUDE_RUNNING" -eq 1 ]; then
    STATUS_FILTER=""                     # every state, running included
    log "including RUNNING containers (--include-running)"
else
    STATUS_FILTER="--filter status=exited --filter status=created --filter status=dead"
fi
# shellcheck disable=SC2086
mapfile -t CONTAINERS < <(docker ps -a $STATUS_FILTER --format '{{.Names}}' 2>/dev/null \
                            | grep '^crs_compose_' || true)
if [ "${#CONTAINERS[@]}" -eq 0 ]; then
    log "none found"
else
    for c in "${CONTAINERS[@]}"; do echo "    $c"; done
    log "${#CONTAINERS[@]} container(s)"
    run "docker rm -f ${CONTAINERS[*]} >/dev/null"
fi

# Report running ones we are deliberately leaving
if [ "$INCLUDE_RUNNING" -eq 0 ]; then
    mapfile -t RUNNING < <(docker ps --format '{{.Names}}' 2>/dev/null | grep '^crs_compose_' || true)
    if [ "${#RUNNING[@]}" -gt 0 ]; then
        log "left ${#RUNNING[@]} RUNNING container(s) alone (pass --include-running if no campaign is active):"
        for c in "${RUNNING[@]}"; do echo "    $c"; done
    fi
fi
echo

# ---------------------------------------------------------------------------
# 2. Leaked crs_compose_* networks
#
# Each run creates three bridge networks. OSS-CRS removes them on a normal
# finish, but aborted, killed, or interrupted runs leave them behind. Only
# networks with no attached container are removed: a network still in use
# belongs to something live, and Docker would refuse anyway.
#
# In a dry run, containers from step 1 have not actually been removed yet, so
# networks they pin are reported as "would become free" rather than skipped.
# ---------------------------------------------------------------------------
log "== crs_compose_* networks =="
FREE_NETS=()
PINNED_NETS=()
while IFS= read -r net; do
    [ -n "$net" ] || continue
    attached=$(docker network inspect -f '{{range $id, $c := .Containers}}{{$c.Name}} {{end}}' "$net" 2>/dev/null)
    if [ -z "$attached" ]; then
        FREE_NETS+=("$net")
    else
        # is every attached container one we are about to remove?
        all_doomed=1
        for c in $attached; do
            case " ${CONTAINERS[*]:-} " in *" $c "*) ;; *) all_doomed=0 ;; esac
        done
        if [ "$all_doomed" -eq 1 ] && [ "$APPLY" -eq 0 ]; then
            FREE_NETS+=("$net")      # dry run: freed by step 1 when applied
        else
            PINNED_NETS+=("$net ($attached)")
        fi
    fi
done < <(docker network ls --format '{{.Name}}' 2>/dev/null | grep '^crs_compose_' || true)

if [ "${#FREE_NETS[@]}" -eq 0 ]; then
    log "no unused networks"
else
    for n in "${FREE_NETS[@]}"; do echo "    $n"; done
    log "${#FREE_NETS[@]} unused network(s)"
    run "docker network rm ${FREE_NETS[*]} >/dev/null 2>&1 || true"
fi
if [ "${#PINNED_NETS[@]}" -gt 0 ]; then
    log "left ${#PINNED_NETS[@]} network(s) still in use:"
    for n in "${PINNED_NETS[@]}"; do echo "    $n"; done
fi
echo

# ---------------------------------------------------------------------------
# 3. Stale builder images (one is created per `oss-crs build-target`)
#    Keep the $KEEP newest; they are ~2.3 GB each.
# ---------------------------------------------------------------------------
log "== oss-crs-builder:fuzzingbrain-build-* images =="
mapfile -t BUILDERS < <(docker images --format '{{.CreatedAt}}\t{{.Repository}}:{{.Tag}}' 2>/dev/null \
                          | grep 'oss-crs-builder:fuzzingbrain-build-' \
                          | sort -r | tail -n +$((KEEP+1)) | cut -f2 || true)
if [ "${#BUILDERS[@]}" -eq 0 ]; then
    log "nothing to remove (keeping $KEEP newest)"
else
    for i in "${BUILDERS[@]}"; do echo "    $i"; done
    log "${#BUILDERS[@]} image(s)"
    run "docker rmi -f ${BUILDERS[*]} >/dev/null 2>&1 || true"
fi
echo

# ---------------------------------------------------------------------------
# 4. Dangling images untagged and unreferenced, so safe to prune.
# ---------------------------------------------------------------------------
log "== dangling images =="
DANGLING=$(docker images -f dangling=true -q 2>/dev/null | wc -l)
log "$DANGLING dangling image(s)"
if [ "$DANGLING" -gt 0 ]; then
    run "docker image prune -f >/dev/null"
fi
echo

# ---------------------------------------------------------------------------
# 5. Old run and build directories.
# ---------------------------------------------------------------------------
log "== run/build directories under the work directory =="
if [ ! -d "$WORKDIR" ]; then
    warn "workdir not found: $WORKDIR (skipping)"
else
    VICTIMS=()
    while IFS= read -r parent; do
        [ -d "$parent" ] || continue
        if [ "$ALL_RUNS" -eq 1 ]; then
            while IFS= read -r d; do VICTIMS+=("$d"); done \
                < <(find "$parent" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
        else
            # newest-first by mtime, drop the $KEEP newest
            while IFS= read -r d; do VICTIMS+=("${d%/}"); done \
                < <(ls -1dt "$parent"/*/ 2>/dev/null | tail -n +$((KEEP+1)))
        fi
    done < <(find "$WORKDIR" -type d \( -name runs -o -name builds \) 2>/dev/null)

    if [ "${#VICTIMS[@]}" -eq 0 ]; then
        log "nothing to remove (keeping $KEEP newest per runs/ and builds/)"
    else
        for d in "${VICTIMS[@]}"; do
            echo "    $(du -sh "$d" 2>/dev/null | cut -f1)  $d"
        done
        log "${#VICTIMS[@]} directory/ies"
        if [ "$APPLY" -eq 1 ]; then
            printf '%s\n' "${VICTIMS[@]}" > /tmp/.cleanup-victims
            docker run --rm \
                -v "$HOME":"$HOME" \
                -v /tmp/.cleanup-victims:/tmp/victims:ro \
                --entrypoint bash "$FB_IMAGE" \
                -c 'while IFS= read -r d; do rm -rf "$d"; done < /tmp/victims; echo "[container] removed"' \
                || warn "container removal failed"
            rm -f /tmp/.cleanup-victims
        else
            echo "    would remove via container (files are root-owned)"
        fi
    fi
fi
echo

# ---------------------------------------------------------------------------
# Summary. Build cache is reported but deliberately not touched.
# ---------------------------------------------------------------------------
AFTER=$(df -h / | awk 'NR==2{print $4}')
NETS_LEFT=$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -c '^crs_compose_' || true)
log "disk available after:  $AFTER  (was $BEFORE)"
log "crs_compose_* networks remaining: $NETS_LEFT"
CACHE=$(docker system df 2>/dev/null | awk '/Build Cache/{print $(NF)}')
log "build cache reclaimable: ${CACHE:-unknown} -- NOT pruned (shared with other users)"
[ "$APPLY" -eq 1 ] || log "DRY RUN -- nothing was deleted; re-run with --yes"