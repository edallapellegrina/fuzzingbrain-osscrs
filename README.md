# FuzzingBrain × OSS-CRS

Run [FuzzingBrain](https://github.com/fuzzingbrain/afc-crs-all-you-need-is-a-fuzzing-brain)
— the fourth-place DARPA AIxCC cyber reasoning system — inside the
[OSS-CRS](https://github.com/ossf/oss-crs) orchestration framework, on an
unprivileged host, driven entirely by a locally-hosted LLM via
[Ollama](https://ollama.com) instead of a commercial API.

## How it works

OSS-CRS and FuzzingBrain each expect to own the run. OSS-CRS delivers targets to
a CRS through a fixed set of `OSS_CRS_*` mounts and expects the CRS to ask
sidecars to build and run things. FuzzingBrain is self-orchestrating: it
expects its own workspace layout and spawns OSS-Fuzz containers itself through
the Docker daemon.

The wrapper (`fb-patch/scripts/fb_wrapper.sh`) reconciles the two at runtime:

```
OSS-CRS                          wrapper                         FuzzingBrain
─────────────────────────        ─────────────────────────       ─────────────────
$OSS_CRS_TARGET_SOURCE      ──►  repo/  +  repo-address/        ──►  source to analyse
$OSS_CRS_FUZZ_PROJ          ──►  fuzz-tooling/projects/<t>/     ──►  OSS-Fuzz project
$OSS_CRS_BUILD_OUT_DIR      ──►  fuzz-tooling/build/out/…       ──►  prebuilt harness
$OSS_CRS_FETCH_DIR/diffs    ──►  diff/ref.diff                  ──►  delta-scan input 
$OSS_CRS_FUZZ_PROJ/ref.diff ──►  task_detail.json               ──►  task parameters
                                                                        │
POVs     ◄── libCRS submit pov   ◄── successful_povs_advanced/       ◄──┤
patches  ◄── libCRS submit patch ◄── successful_patches/             ◄──┘
```

The workspace is built at a path that is identical inside and outside the
container, because FuzzingBrain's nested `docker run` bind mounts are resolved
by the host daemon against the host filesystem.

Three mechanisms make local inference work without root or API keys:

- **`ollama_relay.py`** — Ollama binds to loopback, unreachable from containers.
  This user-space TCP relay re-exposes it on the Docker bridge gateway
  (`172.17.0.1:11435`).
- **`sitecustomize.py`** — a Python interpreter-startup hook that rewrites every
  LiteLLM completion call to the local model. FuzzingBrain's strategies keep
  their hardcoded commercial model names, the traffic is redirected beneath them.
- **`fb-patch/bin/compile_target`** — the build-phase entry point: compiles the
  target and hands the artefacts to OSS-CRS via libCRS.

### The OSS-CRS patch (required)

`osscrs-patch/docker.patch` adds two lines to OSS-CRS's run-phase compose
template:

1. **`/var/run/docker.sock`** mounted into the CRS service. OSS-CRS gives the
   socket only to its sidecars, but FuzzingBrain checks `docker info` at startup
   and spawns its own OSS-Fuzz containers. Without the socket it exits
   immediately with *"Docker is not running!"*.
2. **`OSS_CRS_SHARED_DIR_HOST`**, the host-side path of the shared directory.
   The wrapper uses it to satisfy the path-identity requirement above.

Both are CRS-agnostic: any self-orchestrating CRS needs them. See
[`osscrs-patch/README.md`](osscrs-patch/README.md) for details.

The patch is written against OSS-CRS commit
**`fd175fbad0804ea669eaf836179b2db72edbd5c9`** and does not apply to later
upstream revisions without rebasing. Setup below pins that commit.

---

## Prerequisites

| Requirement | Notes |
| --- | --- |
| Docker, usable without sudo | Operator in the `docker` group |
| [uv](https://docs.astral.sh/uv/) | Runs the OSS-CRS CLI |
| Ollama on `127.0.0.1:11434` | With a capable code model pulled |
| Python 3, Git, curl | Any recent versions |
| Free disk | Budget tens of GB per run — see *Operations* |

No root, no NVIDIA Container Toolkit, no commercial LLM API keys.

```bash
ollama pull qwen3-coder:30b
```

The model name is set in one place: `fb-patch/sitecustomize.py` (`_MODEL`).
Smaller models may not reason well enough to produce POVs.

---

## Setup

```bash
# 1. Clone this repo
git clone https://github.com/edallapellegrina/fuzzingbrain-osscrs.git
cd fuzzingbrain-osscrs

# 2. Clone OSS-CRS at the commit the patch targets, and apply the patch
git clone https://github.com/ossf/oss-crs.git oss-crs
git -C oss-crs checkout fd175fbad0804ea669eaf836179b2db72edbd5c9
git -C oss-crs apply ../osscrs-patch/docker.patch
git -C oss-crs diff --stat            # expect: 1 file changed, 2 insertions(+)

# 3. Clone OSS-Fuzz (used as a home for per-target project directories)
git clone --depth 1 https://github.com/google/oss-fuzz.git ~/oss-fuzz

# 4. Create the runtime compose file from the template
cp fb-patch/compose/compose.yaml.template fb-patch/compose/compose.yaml
sed -i "s|local_path: .*|local_path: $PWD/fb-patch|" fb-patch/compose/compose.yaml
# then set FUZZBRAIN_TARGET to the target you want to run

# 5. Start the LLM relay (once per host)
pgrep -f ollama_relay.py >/dev/null || nohup python3 fb-patch/ollama_relay.py > ~/ollama_relay.log 2>&1 &
bash scripts/verify-relay.sh
```

`local_path` must point at the directory that contains `oss-crs/crs.yaml`,
which is `fb-patch/` — not the repository root.

There is no workspace staging step: the wrapper assembles FuzzingBrain's
workspace at runtime from the framework's mounts.

---

## Running the samples

Each run is the same three OSS-CRS commands. Only the target name and the
project files differ.

### Delta scan — cjson

A real library with an injected CVE-shaped defect: the delta removes the
`valuestring == NULL` guard from `cJSON_SetValuestring`, reachable from the
`fuzz_target` harness.

```bash
mkdir -p ~/oss-fuzz/projects/cjson
cp targets/cjson/{project.yaml,Dockerfile,build.sh} ~/oss-fuzz/projects/cjson/
cp targets/cjson/diff/ref.diff                      ~/oss-fuzz/projects/cjson/

# set FUZZBRAIN_TARGET: "cjson" in fb-patch/compose/compose.yaml, then:
cd oss-crs
uv run oss-crs prepare --compose-file ../fb-patch/compose/compose.yaml
uv run oss-crs build-target --compose-file ../fb-patch/compose/compose.yaml --fuzz-proj-path ~/oss-fuzz/projects/cjson
uv run oss-crs run --compose-file ../fb-patch/compose/compose.yaml --fuzz-proj-path ~/oss-fuzz/projects/cjson --target-harness fuzz_target
```

Expected: `POV SUCCESS!` in round 1, then a `CRS Run Results` summary with
`POVs` ≥ 1 and, if patching completes, `Patches: 1`. A typical POV is a JSON
object with a string value, such as `{"test":"hello"}`.

### Full scan — vuln-test-repo

A synthetic C target with a heap read overflow, run without a diff so
FuzzingBrain must locate the defect unaided.

```bash
mkdir -p ~/oss-fuzz/projects/vuln-test-repo
cp -r targets/vuln-test-repo/{project.yaml,Dockerfile,build.sh,src} ~/oss-fuzz/projects/vuln-test-repo/
# do not copy a ref.diff -- its absence is what selects full-scan mode

# set FUZZBRAIN_TARGET: "vuln-test-repo", then run the same three commands
# with --fuzz-proj-path ~/oss-fuzz/projects/vuln-test-repo
```

Expected: a POV within the first round (the three-byte input `BUG`) and a
validated patch. Full scan takes noticeably longer than delta scan.

### Where results land

```
oss-crs/.oss-crs-workdir/crs_compose/<hash>/address/runs/<run-id>/crs/fuzzingbrain/<target>_<hash>/SUBMIT_DIR/<harness>/
  povs/       crashing inputs
  patches/    validated diffs against the target source
```

---

## Adding a new target

A target is defined by files in `targets/<name>/`:

| File | Purpose | Required |
| --- | --- | --- |
| `project.yaml` | OSS-Fuzz metadata: language, sanitizers, engine | always |
| `Dockerfile` | Obtains the source and pins the commit to build | always |
| `build.sh` | Compiles the harness to `$OUT/<harness>` | always |
| `diff/ref.diff` | `base..delta` unified diff | delta mode only |

How you produce them depends on where the target comes from.

### Case A — the project is already in OSS-Fuzz

If upstream OSS-Fuzz already integrates the project, the three build files already exist.
Copy them:

```bash
mkdir -p targets/<name>
cp ~/oss-fuzz/projects/<name>/{project.yaml,Dockerfile,build.sh} targets/<name>/
```

For a full scan you are done. For a delta scan you also need a
`diff/ref.diff` (see *Producing ref.diff*), and you must pin the `Dockerfile` to
your delta commit, because upstream OSS-Fuzz Dockerfiles clone the default
branch unpinned:

```dockerfile
# before (upstream): unpinned, builds whatever HEAD is today
RUN git clone --depth 1 https://github.com/<org>/<repo>.git $SRC/<name>

# after: pinned to the commit your diff describes
RUN git clone https://github.com/<you>/<repo>-fork.git $SRC/<name> && \
    cd $SRC/<name> && git checkout <DELTA_COMMIT>
```

Drop `--depth 1`: a shallow clone cannot check out an arbitrary commit.

### Case B — an arbitrary GitHub repository

Nothing exists yet, so you write all three files. The OSS-Fuzz
[new project guide](https://google.github.io/oss-fuzz/getting-started/new-project-guide/)
is the reference; the minimum for a C/C++ library is:

**`project.yaml`**

```yaml
homepage: "https://github.com/<org>/<repo>"
language: c # or c++, jvm
primary_contact: "you@example.com"
main_repo: "https://github.com/<org>/<repo>.git"
sanitizers:
  - address
fuzzing_engines:
  - libfuzzer
```

**`Dockerfile`**

```dockerfile
FROM gcr.io/oss-fuzz-base/base-builder
RUN apt-get update && apt-get install -y cmake # only if the build needs it
RUN git clone https://github.com/<org>/<repo>.git $SRC/<name> && cd $SRC/<name> && git checkout <DELTA_COMMIT>
WORKDIR $SRC/<name>
COPY build.sh $SRC/
```

**`build.sh`** — use the OSS-Fuzz-provided `$CC`, `$CXX`, `$CFLAGS`, and
`$LIB_FUZZING_ENGINE`, and write the binary to `$OUT/<harness>`:

```bash
#!/bin/bash -eu
cd $SRC/<name>
$CC $CFLAGS -I. -c <lib>.c -o <lib>.o
$CC $CFLAGS -I. tests/fuzz/<harness>.c <lib>.o $LIB_FUZZING_ENGINE -o $OUT/<harness>
```

If the repository has no `LLVMFuzzerTestOneInput` harness, write one:

```c
#include <stdint.h>
#include <stddef.h>
#include "<lib>.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    /* drive the API you want to exercise using `data` */
    return 0;
}
```

### Case C — a self-contained target

The source ships in this repository and the `Dockerfile` copies it from the build
context instead of cloning — see `targets/vuln-test-repo/`:

```dockerfile
RUN mkdir -p $SRC/vuln-test-repo
COPY src $SRC/vuln-test-repo/src
COPY build.sh $SRC/
```

Useful for controlled experiments where you want the defect under your control.

### Producing `ref.diff` (delta mode only)

You need two commits: a base (clean) and a delta (vulnerable), with the delta being what the `Dockerfile` builds.

**Injecting a defect**:

```bash
git clone https://github.com/<org>/<repo>.git && cd <repo>
git checkout -b vuln-test
BASE=$(git rev-parse HEAD)
# edit the source to introduce the defect; add a harness under tests/fuzz/ if needed
git commit -am "introduce test vulnerability"
DELTA=$(git rev-parse HEAD)
git push origin vuln-test # the Dockerfile clones this fork

mkdir -p /path/to/targets/<name>/diff
git diff $BASE $DELTA > /path/to/targets/<name>/diff/ref.diff
```

**Reconstructing a real CVE.** Revert the upstream commit that fixed it — the revert reintroduces the vulnerability, and its diff reads exactly like the defect being introduced:

```bash
git checkout -b cve-reintroduced <FIX_COMMIT>
BASE=$(git rev-parse HEAD)
git revert --no-edit <FIX_COMMIT>
DELTA=$(git rev-parse HEAD)
git diff $BASE $DELTA > /path/to/targets/<name>/diff/ref.diff
```

### Run it

```bash
mkdir -p ~/oss-fuzz/projects/<name>
cp targets/<name>/{project.yaml,Dockerfile,build.sh} ~/oss-fuzz/projects/<name>/
cp targets/<name>/diff/ref.diff ~/oss-fuzz/projects/<name>/ # delta mode only
cp -r targets/<name>/src ~/oss-fuzz/projects/<name>/ # Case C only

# verify the target builds on its own before involving FuzzingBrain
cd ~/oss-fuzz
python infra/helper.py build_fuzzers <name>
python infra/helper.py check_build <name>
```

A broken build otherwise surfaces as a confusing CRS failure. Then set
`FUZZBRAIN_TARGET: "<name>"` and run the three OSS-CRS commands with
`--fuzz-proj-path ~/oss-fuzz/projects/<name>` and `--target-harness <harness>`,
where `<harness>` is the basename of the binary `build.sh` writes to `$OUT/`.

**Mode selection is automatic.** The wrapper looks for a diff, first in
`$OSS_CRS_FETCH_DIR/diffs/`, then at `$OSS_CRS_FUZZ_PROJ/ref.diff`. If it finds
one, it runs delta mode (`xs0_delta.py`); otherwise full mode (`as0_full.py`).

**Language support.** `crs.yaml` declares `c`, `c++`, and `jvm`. JVM targets use
Jazzer's `fuzzerTestOneInput` rather than `LLVMFuzzerTestOneInput`.

---

## Operations

A single run can consume tens of gigabytes of disk (workspace copies,
per-attempt harness binaries, and FuzzingBrain's logs, which record every LLM
prompt and response), and leaves Docker objects behind: a builder image per
`build-target`, containers, and three bridge networks per run. Clean up between
campaigns:

```bash
bash scripts/cleanup-runs.sh # dry run: shows what would go
bash scripts/cleanup-runs.sh --yes --include-running # apply, between campaigns
```

The script only touches objects it can attribute to this integration
(`crs_compose_*` containers and networks, `oss-crs-builder:fuzzingbrain-build-*`
images, dangling images, old run directories). It never prunes the shared Docker
build cache, and never removes the runner image. `--include-running` also clears
the sidecars that `build-target` leaves running — omit it while a campaign is in
progress.

Resource limits for the CRS container are set in `fb-patch/compose/compose.yaml`.
The template ships `cpuset: "2-9"` and `memory: "32G"`. With patching enabled,
FuzzingBrain runs POV and patch strategies in parallel, and 8 GB is not enough.

---

## Repository layout

```
fb-patch/                       the CRS package (source.local_path)
  oss-crs/
    crs.yaml                    CRS manifest read by OSS-CRS
    docker-bake.hcl
    dockerfiles/{base,builder,runner}.Dockerfile
  bin/compile_target            build-phase entry point
  scripts/fb_wrapper.sh         run-phase entry point (baked into the runner image)
  sitecustomize.py              LiteLLM → local model interceptor
  ollama_relay.py               user-space TCP relay to Ollama
  fuzzingbrain.env.template
  compose/compose.yaml.template
osscrs-patch/
  docker.patch                  the required OSS-CRS patch
  README.md                     what it changes, why, and the base commit
targets/
  cjson/                        delta-scan sample
  vuln-test-repo/               full-scan sample
scripts/                        host-side operator tools
  verify-relay.sh
  cleanup-runs.sh
```

---

## FuzzingBrain version

Pinned by image digest in `runner.Dockerfile`, not by a floating tag:

```dockerfile
FROM ghcr.io/o2lab/fuzzingbrain@sha256:6da1d1d417c1c02d3e72a8f0dc69bcea535b74a7c7b5351fed667d8e11b71431
```

Corresponds to FuzzingBrain v0.1 (git `dcbc68a29e736b170fadb7f02f349aba79ec590e`), image built 2026-02-06.

---

## Known limitations

- **Patch validation is shallow.** FuzzingBrain accepts a patch when the target
  rebuilds and the POV no longer crashes. It does not run the target's functional
  tests. Because its patching prompt asks the model to return whole functions,
  accepted patches can change more than necessary: in one cjson run the model
  restored the missing NULL check but also removed an unrelated type/reference
  guard. Review patches before trusting them.
- **POV over-counting.** Parallel strategy phases produce several distinct inputs
  for one underlying defect, each submitted separately. Deduplicate on the
  sanitizer crash signature before treating counts as a metric.
- **Model-name labelling.** FuzzingBrain's logs and metadata record a commercial
  model name even though the local model does all the work. The
  `[sitecustomize] LiteLLM patched!` line is the reliable evidence of what ran.
- **Model dependence.** Time to discovery varies between runs, and smaller models may not succeed at all.
- **Pinned OSS-CRS.** The patch targets a specific upstream commit and needs
  rebasing for current `main`.

---

## License & attribution

See [`LICENSE.md`](LICENSE.md). This repository claims authorship only of the
integration layer, the target definitions, the OSS-CRS patch, and the
documentation. FuzzingBrain and OSS-CRS retain their own licences.

- FuzzingBrain — team "All You Need Is A Fuzzing Brain", O2 Lab.
- OSS-CRS — the OSS-CRS maintainers.