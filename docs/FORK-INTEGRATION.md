# Fork build, validation and image replacement

This repository builds **BenCodez/videoduplicatefinder**, keeping the existing
jlesage browser/VNC desktop. Container port 5800 serves the same interface and
optional port 5900 serves VNC. The base image, authentication, TLS, clipboard,
file manager, Openbox window behavior, dark-mode switch and bundled FFmpeg are
retained. No VDF.Web service is introduced.

## Source and build pins

`Dockerfile` pins a full application commit in
`VIDEO_DUPLICATE_FINDER_COMMIT_SHA`. The implementation pin is
`4f38cd9e0d2951362bec33296e5a2bfd7b956dcb`, including scheduled scans,
NFO favourite protection, selection profiles, persistent review decisions and
safe cleanup. The commit is published on the application fork's
`feature/safe-media-automation` branch. A branch name is deliberately rejected
as the application source pin.
Changing a version label alone does not change the application's code.

The SDK is pinned to `10.0.401` using Microsoft's
`mcr.microsoft.com/dotnet/sdk:10.0.401-alpine3.24` image. The build verifies the
actual SDK version and disables SDK roll-forward. Cross-compilation helpers use
`tonistiigi/xx:1.9.0`; the GUI runtime remains
`jlesage/baseimage-gui:alpine-3.24-v4.14.0`. FFmpeg 8.1.3 aligns with the
application's FFmpeg.AutoGen 8.1 bindings. Its source SHA256 is pinned and
verified before extraction; changing FFmpeg versions requires changing that
checksum too. Source and SDK pins make rebuilding the same application possible; mutable distro packages
and container tag contents mean this is not a promise of bit-identical layers.

GTK/Pango and HarfBuzzSharp use Alpine's single native `harfbuzz` library.
The published managed HarfBuzzSharp 8.3.1.3 wrapper keeps its public C ABI;
`libHarfBuzzSharp.so` points to `/usr/lib/libharfbuzz.so.0`. The build rejects a
different managed wrapper version or any missing import from its complete
319-symbol inventory. This prevents musl from interposing internal calls between
the bundled HarfBuzz 8 and system HarfBuzz 13, which have different private object
layouts. HarfBuzz documents its [stable public API/ABI](https://harfbuzz.github.io/install-harfbuzz.html).
The 12 public wrapper struct layouts were also checked against Alpine 13.2.1
headers on the supported LP64 targets. `/opt/vdf/NativeFontRuntime.txt` records
the selected native package/version; the build checker, import inventory and
HarfBuzz's COPYING notice are included with the image.

```sh
# The application commit must be available in the fork before the image build.
APP_COMMIT=4f38cd9e0d2951362bec33296e5a2bfd7b956dcb
docker buildx build --platform linux/amd64,linux/arm64 \
  --build-arg VIDEO_DUPLICATE_FINDER_COMMIT_SHA="$APP_COMMIT" \
  --build-arg DOCKER_IMAGE_VERSION=local-test \
  --output type=oci,dest=vdf-local-test.tar .

# For a runnable local image, build one platform with --load:
docker buildx build --platform linux/amd64 --load \
  --build-arg VIDEO_DUPLICATE_FINDER_COMMIT_SHA="$APP_COMMIT" \
  --tag vdf:local-test .
PLATFORM=linux/amd64 tests/smoke-image.sh vdf:local-test
```

| Target | Status |
| --- | --- |
| `linux/amd64` | Required build and runtime smoke in CI |
| `linux/arm64` | Required cross-build and runtime smoke under QEMU in CI |
| `linux/arm/v6`, `linux/arm/v7` | Not published by this fork; the newer GUI/native dependency stack is not validated for 32-bit ARM |
| Other targets | Unsupported; the source builder rejects them |

The previous container advertised 32-bit ARM too. It is excluded explicitly
rather than shipping an untested image. Re-enable it only after the matching
.NET RID, Avalonia/Skia/ONNX native libraries and complete image smoke all pass.

## Patches and persistence

All eight upstream container patches remain in use, with current contexts.
A ninth, narrow build-provenance patch preserves the pinned full application
commit in the existing assembly metadata and GUI About display even though a
source archive has no `.git` directory.
`src/vdf/apply-patches.sh` rejects fuzzy/reversed patch application. The FFmpeg
patch now disables the shared GUI downloader, covering both the manual command
and scan startup while retaining missing-native-library and executable checks.
The ONNX patch uses Alpine's musl runtime and ignores old glibc runtime copies
under the configuration directory. It retains the model download and SHA check.
The original About dialog owner, file-picker locations, container theme controls
and unavailable desktop drag/drop/release controls remain patched.

The current application separates `SettingsFolder`, `StateFolder` and
`CurrentFolder`, and ignores desktop portable mode in container mode. The updated
container patch routes all three and their defaults to **`/config`**, retaining
the existing flat layout. `startapp.sh` explicitly opens
`/config/Settings.json`; XDG folders and application temporary caches also stay
under the mounted `/config` directory.

| Data | Default persistent location |
| --- | --- |
| Application settings, schedule settings and selection profiles | `/config/Settings.json` |
| Scan database and its journal/backup sidecars | `/config/ScannedFiles.db` and adjacent files |
| Review decisions, selection plan and quarantine history | `/config/ReviewedFiles.json`, `/config/SelectionPlan.json`, `/config/QuarantineHistory.json` |
| Group blacklist and results backup | `/config` |
| AI models and embedding databases | `/config/ai` and `/config` |
| Log | `/config/log.txt` |
| XDG data/cache and temporary thumbnail cache | Subdirectories of `/config` |

Explicit `CustomDatabaseFolder`, quarantine destinations and exported files
remain configurable. Choose a persistent bind mount for those paths; a container
path outside a mounted volume is ephemeral. Quarantine operations need a writable
media/quarantine mount; the test deployment mounts media read-only by default.

Startup changes only the legacy/new theme fields according to `DARK_MODE`.
Unknown settings survive the atomic JSON rewrite. Empty, malformed, multiple-document or non-object JSON
fails startup with its bytes intact instead of silently clearing configuration.
Missing settings in an existing configuration also fail startup; a successful
initialization marker and existing state/protection files prevent fresh defaults
from replacing saved cleanup protections. Restore the settings file to resume.
No new migration of the existing database is performed by container scripts;
application-level schema migration and backup behavior remain owned by VDF.

The fork's legacy-removal journal saves schema version 2, including durable
proof for refreshing deliberate protections after an authorized rollback.
Quarantine history saves version 3, adding the exact restore-staging identity
so an interrupted rename cannot accept an unrelated byte-identical destination.
Safe version 1 legacy history and safe version 1/2 quarantine history migrate
on save. Older binaries reject newer history instead of interpreting it
permissively. Reviews, policy, plans and the scan database retain their schemas.
Preserve the **entire pre-upgrade configuration/state snapshot**, including both
journals and their sidecars, when making the test copy.

The scheduler belongs to the continuously running GUI process. Closing a browser
or disconnecting VNC does not stop that process. The container must remain
running; keep its `TZ` value consistent with the intended calendar schedule.

## CI and publication

PRs and ordinary branch pushes validate shell/startup behavior, source patches
and persistent paths, then build and smoke both architectures without logging
into a registry or pushing images. No Docker Hub or Pushover secrets are used.

Publication to `ghcr.io/bencodez/video-duplicate-finder` happens only after both
architecture smoke tests succeed, on:

- An intentional `vX.Y.Z` or prerelease version-tag push in the BenCodez repository.
- A manual workflow run with `publish=true` and an explicit version/test tag.

The publication job alone grants `packages: write` and uses `GITHUB_TOKEN`.
Ensure the GHCR package grants this repository Actions write access. It publishes
the exact saved images tested in CI, with the chosen tag and
`sha-<container-commit-12>-<application-commit-12>` plus architecture suffix tags.
Version-tag pushes never update `latest`. Updating `latest` requires a manual
run with `publish=true`, `promote_latest=true` and a stable `vX.Y.Z` tag.

## Test using a copied configuration

These commands are deployment instructions only. No running container or user
volume has been changed by implementing this repository.

1. Record the original immutable image digest and existing Compose configuration.
2. Stop/quiesce the original GUI before copying `/config`, or use a consistent
   filesystem snapshot. Never copy a live database while it is being written.
3. Copy the entire configuration directory, preserving owners and permissions.
   Keep the original directory untouched for rollback. Restart the original
   container against its original directory if testing concurrently.
4. Set the environment below to your own paths and a tested fork tag/digest.
   Copy any existing authentication, TLS and network settings into the private
   test configuration. Do not put credentials or actual private paths in commits.

```sh
export VDF_IMAGE='ghcr.io/bencodez/video-duplicate-finder:TESTED_TAG'
export VDF_CONFIG_COPY='/example/vdf-config-copy'
export ORIGINAL_CONFIG_DIRECTORY='/example/original-vdf-config'
export VDF_MEDIA_DIR='/example/synthetic-test-media'
export VDF_TZ='Etc/UTC'
export VDF_USER_ID=1000
export VDF_GROUP_ID=1000
# Only after the original GUI has stopped or a consistent snapshot is available:
test ! -e "$VDF_CONFIG_COPY"
cp -a -- "$ORIGINAL_CONFIG_DIRECTORY" "$VDF_CONFIG_COPY"
docker compose -p vdf-test -f deploy/compose.test.yml config
docker compose -p vdf-test -f deploy/compose.test.yml up -d
```

The test exposes host port 5801 to container port 5800 so an original installation
using host port 5800 can keep running. VNC is optional; uncomment 5901:5900 if
needed. Start with synthetic media; then check a copied configuration with media
read-only. Review settings/database load, scan results, schedule status and
selection protections before permitting cleanup. Close every browser/VNC client
and confirm the configured scheduled scan completes in the GUI log and state.

## Image swap and rollback

`deploy/compose.image-swap.yml` is a small override for an existing service named
`video-duplicate-finder`. It changes only the image and `/config` source; original
5800/5900 port mappings, `/storage` mounts, network and environment settings merge
from the existing Compose file. Rename the override's service if yours differs.

After validation, and only when you intend to replace the running image:

```sh
# VDF_IMAGE and VDF_CONFIG_COPY must still reference the tested image/config copy.
docker compose -f compose.original.yml -f deploy/compose.image-swap.yml config
docker compose -f compose.original.yml -f deploy/compose.image-swap.yml \
  up -d --no-deps --force-recreate video-duplicate-finder
```

Before rollback, stop/quiesce the newer GUI and preserve a complete copy of its
current configuration/state and any quarantine destinations. Complete pending
cleanup recovery with the newer image before switching versions. Keep that
current-state copy even when restoring the pre-upgrade snapshot: it contains
post-upgrade review decisions, protection changes and cleanup/recovery history
that the older snapshot cannot contain.

Validate the recorded original image **with the untouched pre-upgrade config
and read-only media** before permitting any older-image cleanup. The image and
state swap is then:

```sh
export VDF_IMAGE="$ORIGINAL_IMAGE_DIGEST"
export VDF_CONFIG_COPY="$ORIGINAL_CONFIG_DIRECTORY"
docker compose -f compose.original.yml -f deploy/compose.image-swap.yml \
  up -d --no-deps --force-recreate video-duplicate-finder
```

Do not point the old image at the test directory after the new application has
written its state. Restore the full pre-upgrade configuration/state snapshot
with the older image; replacing only `Settings.json` or the scan database leaves
upgraded version-2 cleanup journals that the older binary must reject.
The pre-upgrade snapshot cannot undo post-upgrade media mutations or decisions.
Preserve and reconcile any new protections and cleanup results before allowing
the older image and old state to authorize cleanup. Restore any intentionally
quarantined test media through the newer application's verified recovery path
before relying on an older application's database. Do not discard the copied
current state or quarantine history when making that assessment.

## Validation gates

Every application-pin or container change requires all nine patches to apply
with zero fuzz to an isolated copy of the exact pinned source. The persistence
probe must compile that patched source with SDK 10.0.401 and verify `/config`
defaults, explicit database overrides and the full source-revision metadata.
The repository's Python regressions, shell syntax, whitespace and actionlint
checks also form part of acceptance. The application stack requires its full
serial solution build and six test suites, Windows CI, and a fresh independent
review of the exact final changes. Scalar Linux media-test results do not
substitute for optimized native container validation.

Both `linux/amd64` and `linux/arm64` must pass the original normal image smoke
on the same reviewed container source and exact application pin. It uses an
optimized FFmpeg FFV1 fixture, a cold GUI launch, scheduled scan without a
browser, NFO-protected selection, HTTP 5800, VNC 5900, dark/light interface checks
and a persistent restart with the same settings, database, reviews and schedule
claims. Media is synthetic and mounted read-only. Failure-only diagnostic
replays preserve the original failure status and cannot satisfy these gates.
The build also verifies source/SDK pins, ELF architecture, native dependencies,
FFmpeg stack reservations, font imports, licenses and corresponding source.

Earlier trials exposed three distinct native/startup defects: FFV1 worker
stack exhaustion under musl, incompatible bundled/system HarfBuzz libraries
loaded into one process, and incorrect ARM64 directory-durability ABI flags.
The build requests and checks a 2 MiB `PT_GNU_STACK` reservation for FFmpeg tools
and libraries, retains optimized CPU code, and uses the single guarded system
HarfBuzz library described above. The application pin must include the corrected
ARM64 directory flags and report original startup failures before opening an
owned error dialog. These fixes require the complete normal smoke on both
architectures; a successful native probe alone is insufficient.

Current execution results, exact commit IDs, test counts and CI links are
recorded in the [container draft PR](https://github.com/BenCodez/docker-video-duplicate-finder/pull/1)
and [application integration draft PR](https://github.com/BenCodez/videoduplicatefinder/pull/6).
Passing build/smoke gates does not create a published image tag or authorize
production replacement. Clipboard/file-manager behavior, configured
authentication/TLS and optional AI-model inference still need validation for
the intended installation using a copied configuration.

## Attribution and corresponding source

The container integration preserves Jocelyn Le Sage's MIT license and existing
attribution. Video Duplicate Finder preserves 0x90d's AGPL-3.0-or-later source
headers/license. FFmpeg is built with GPL/version-3 flags. The image includes
the exact patched application source at `/opt/vdf/CorrespondingSource.tar.gz`,
its license at `/opt/vdf/licenses/VDF/LICENSE`, the container's license/build
scripts under `/usr/share/licenses/container` and `/usr/share/vdf/container-build`,
and the FFmpeg source/license under `/usr/share/licenses/ffmpeg`.
Alpine's HarfBuzz runtime is installed as a distro package; its upstream
13.2.1 COPYING notice is retained under `/usr/share/licenses/harfbuzz`, with the
actual installed package version recorded in `NativeFontRuntime.txt`.
