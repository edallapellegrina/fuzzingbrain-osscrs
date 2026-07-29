# OSS-CRS patch

`docker.patch` adds two lines to OSS-CRS's run-phase compose template. It is
**required**: without it the FuzzingBrain CRS container exits immediately with
*"Docker is not running!"* and never starts.

- **File touched:** `oss_crs/src/templates/run-crs-compose.docker-compose.yaml.j2`
- **Written against upstream commit:** `fd175fbad0804ea669eaf836179b2db72edbd5c9`
  (https://github.com/ossf/oss-crs)

## Apply

```bash
git clone https://github.com/ossf/oss-crs.git
cd oss-crs
git apply /path/to/osscrs-patch/docker.patch
```

Verify before applying:

```bash
git apply --check /path/to/osscrs-patch/docker.patch && echo "applies cleanly"
```

If it fails, upstream has moved since the commit above. Either check out that
commit, or re-apply the two changes by hand.

## What it changes

### 1. Mount the Docker socket into the CRS service

```yaml
      - /var/run/docker.sock:/var/run/docker.sock
```

OSS-CRS mounts the Docker socket into its **sidecars** (`oss-crs-builder-sidecar`,
`oss-crs-runner-sidecar`) but not into CRS containers: the framework's model is
that a CRS asks the sidecars to build and run things on its behalf.

FuzzingBrain does not follow that model. It is *self-orchestrating*: it checks
for a working Docker daemon at startup (`check_docker`, called unconditionally
from `check_environment` in `/app/FuzzingBrain.sh`) and spawns OSS-Fuzz
containers itself to build the target and to execute candidate POVs against the
harness. Without socket access it aborts before doing any work.

### 2. Expose the host path of the shared directory

```yaml
      - OSS_CRS_SHARED_DIR_HOST={{ work_dir.get_shared_dir(crs.name, target, run_id, sanitizer) }}
```

When FuzzingBrain spawns a nested OSS-Fuzz container, its bind mounts are 
resolved by the **host** Docker daemon against the **host** filesystem — not
against the CRS container's filesystem. 

The CRS therefore needs to know the host-side path of the directory it is
writing into, so it can build its workspace at a path that is identical on both
sides. This line simply also it in as an environment variable.

`fb-patch/scripts/fb_wrapper.sh` consumes it: it symlinks the host path to the
container mount, then assembles FuzzingBrain's workspace there, so nested
`docker run -v <workspace>:<workspace>` invocations resolve correctly.
