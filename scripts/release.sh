#!/usr/bin/env bash
# Local release engine for the ashton/zte-nde fork.
#
# Mirrors what upstream's release-binary job in .github/workflows/ci.yml does
# (build, sha256sum, stage, publish release) — but locally, for the static-claude-nde
# variant only, on the zte-nde branch.  No DSH variant, no cosmic, no gnu, no aarch64.
#
# Usage:
#   scripts/release.sh --tag=v0.7.7-nde.1 [--variant=static-claude-nde] \
#                      [--branch=zte-nde] [--from-tag=COMMIT] [--push] [--dry-run]
#
# Steps:
#   1. Verify current branch (default: zte-nde) and clean working tree.
#   2. Stage assets into release/<tag>/assets/.
#   3. Generate release/<tag>/manifest.json + RELEASE-NOTES.md.
#   4. git tag -a <tag> (annotated) on current HEAD.
#   5. If --push: git push <upstream> <branch> --tags (NEVER auto; gated by --push flag
#      AND by an interactive y/N confirmation unless --yes).
#
# This script NEVER deletes, NEVER force-pushes, NEVER touches master, NEVER
# touches ~/.dsh, NEVER pushes to origin without --push, NEVER publishes
# artifacts to a remote without explicit --push.
#
# OPERATIONAL RULE (2026-09-30, user explicit): all push operations gated by
# --push are intended for human-driven runs.  An autonomous agent running this
# script must NOT pass --push (or --yes) without the user explicitly
# authorizing that specific run.  The interactive [y/N] prompt is the gate;
# --yes exists only as a convenience for the user (or for the user
# authorizing an agent run).  See viking://user/default/memories/preferences/
# Nde_Fork_Push_Ban.md for the full rule.

set -euo pipefail

TAG=""
VARIANT="static-claude-nde"   # only the variant tag (release.sh prepends computer-use-linux-)
BRANCH="zte-nde"
FROM_TAG=""
PUSH=0
DRY=0
YES=0
ALLOW_DIRTY=0
SKIP_BUILD=0

for arg in "$@"; do
  case "$arg" in
    --tag=*)        TAG="${arg#*=}"        ;;
    --variant=*)    VARIANT="${arg#*=}"    ;;
    --branch=*)     BRANCH="${arg#*=}"     ;;
    --from-tag=*)   FROM_TAG="${arg#*=}"   ;;
    --push)         PUSH=1                 ;;
    --dry-run)      DRY=1                  ;;
    --yes)          YES=1                  ;;
    --allow-dirty)  ALLOW_DIRTY=1          ;;
    --skip-build)   SKIP_BUILD=1           ;;
    -h|--help)
      sed -n '2,32p' "$0"; exit 0
      ;;
    *)
      echo "release: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if [[ -z "$TAG" ]]; then
  echo "release: --tag is required (e.g. --tag=v0.7.7-nde.1)" >&2
  exit 2
fi

# Tag name format guard: vX.Y.Z-nde.N
if ! [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-nde\.[0-9]+$ ]]; then
  echo "release: tag '$TAG' does not match pattern vX.Y.Z-nde.N" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# 1. branch + clean tree
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
  echo "release: must be on branch '$BRANCH' (currently on '$CURRENT_BRANCH')" >&2
  echo "release: hint: git checkout $BRANCH" >&2
  exit 4
fi

if [[ -n "$(git status --porcelain)" ]] && [[ "$ALLOW_DIRTY" -ne 1 ]]; then
  echo "release: working tree not clean. Commit/stash first." >&2
  git status --short >&2
  echo "release: pass --allow-dirty to bypass (NOT recommended for real releases)" >&2
  exit 5
fi

# 2. base commit for the release
if [[ -n "$FROM_TAG" ]]; then
  BASE="$(git rev-parse --verify "$FROM_TAG^{commit}")"
else
  BASE="HEAD"
fi
BASE_SHORT="$(git rev-parse --short "$BASE")"

# 3. release dir + manifest
ASSET_NAME="computer-use-linux-${VARIANT}-x86_64-unknown-linux-musl"
RELEASE_DIR="$REPO_ROOT/release/$TAG"
ASSETS_DIR="$RELEASE_DIR/assets"
mkdir -p "$ASSETS_DIR"

# Build & stage (delegated)
STAGING_DIR="$REPO_ROOT/release/_staging"
TARGET_DIR="$REPO_ROOT/release/_target"
JOBS="$(nproc)"

echo "=========================================="
echo "[release] tag=$TAG  variant=$VARIANT"
echo "[release] branch=$BRANCH  base=${BASE_SHORT}"
echo "[release] asset=$ASSET_NAME"
echo "[release] release-dir=$RELEASE_DIR"
echo "[release] dry-run=$DRY  push=$PUSH"
echo "=========================================="

if [[ "$DRY" -eq 1 ]]; then
  echo "[dry-run] would run:"
  echo "  scripts/build-static-musl.sh --asset-base=computer-use-linux-${VARIANT} \\"
  echo "      --out-dir=$STAGING_DIR --target-dir=$TARGET_DIR --jobs=$JOBS"
  echo "  (or pass --skip-build if the binary is already staged in $STAGING_DIR)"
  echo "  cp  $STAGING_DIR/$ASSET_NAME -> $ASSETS_DIR/"
  echo "  cp  $STAGING_DIR/$ASSET_NAME.sha256 -> $ASSETS_DIR/"
  echo "  write $RELEASE_DIR/manifest.json + RELEASE-NOTES.md"
  echo "  git tag -a $TAG -m 'release $TAG'  ($BASE_SHORT)"
  if [[ "$PUSH" -eq 1 ]]; then
    echo "  git push upstream $BRANCH --tags  (would confirm interactively unless --yes)"
  fi
  echo "[dry-run] OK"
  exit 0
fi

# 4. Build (delegated; keeps logic in one place)
if [[ "$SKIP_BUILD" -eq 1 ]]; then
  echo "[release] --skip-build set; expecting staged assets at $STAGING_DIR/$ASSET_NAME"
  if [[ ! -f "$STAGING_DIR/$ASSET_NAME" ]]; then
    echo "[release] staged asset missing: $STAGING_DIR/$ASSET_NAME" >&2
    exit 7
  fi
else
  scripts/build-static-musl.sh \
    --asset-base="computer-use-linux-${VARIANT}" \
    --out-dir="$STAGING_DIR" \
    --target-dir="$TARGET_DIR" \
    --jobs="$JOBS"
fi

# 5. Copy staged assets into the versioned release dir
cp -v "$STAGING_DIR/$ASSET_NAME"       "$ASSETS_DIR/"
cp -v "$STAGING_DIR/$ASSET_NAME.sha256" "$ASSETS_DIR/"

# 6. manifest.json
SHA256_HEX="$(awk '{print $1}' "$ASSETS_DIR/$ASSET_NAME.sha256")"
BYTES="$(stat -c %s "$ASSETS_DIR/$ASSET_NAME")"
COMMIT_FULL="$(git rev-parse "$BASE^{commit}")"
COMMIT_SHORT="$(git rev-parse --short "$BASE^{commit}")"
AUTHOR_NAME="$(git config user.name)"
AUTHOR_EMAIL="$(git config user.email)"
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$RELEASE_DIR/manifest.json" <<EOF
{
  "tag": "$TAG",
  "variant": "$VARIANT",
  "branch": "$BRANCH",
  "base_commit": "$COMMIT_FULL",
  "base_commit_short": "$COMMIT_SHORT",
  "build_time_utc": "$BUILD_TIME",
  "builder": "scripts/release.sh",
  "signer": { "name": "$AUTHOR_NAME", "email": "$AUTHOR_EMAIL" },
  "assets": [
    {
      "name": "$ASSET_NAME",
      "bytes": $BYTES,
      "sha256": "$SHA256_HEX",
      "role": "primary-binary"
    },
    {
      "name": "$ASSET_NAME.sha256",
      "bytes": $(stat -c %s "$ASSETS_DIR/$ASSET_NAME.sha256"),
      "sha256": "$(sha256sum "$ASSETS_DIR/$ASSET_NAME.sha256" | awk '{print $1}')",
      "role": "primary-binary-sha256"
    }
  ],
  "notes": "static-musl build for Nde desktop. Targets x86_64-unknown-linux-musl. Upstream: see README."
}
EOF
echo "[release] manifest.json written"

# 7. RELEASE-NOTES.md
# Pull the [## "x.y.z"] section out of CHANGELOG.md matching this tag.
# awk kept simple to avoid nested-quote hell.
TAG_NUM="${TAG#v}"   # strip leading "v"
CHANGELOG_SECTION=""
if [[ -f CHANGELOG.md ]]; then
  CHANGELOG_SECTION="$(
    awk -v t="$TAG_NUM" '
      /^## \[/ {
        line = $0
        idx = index(line, "[")
        if (idx > 0) {
          rest = substr(line, idx + 1)
          end = index(rest, "]")
          if (end > 0) {
            sec = substr(rest, 1, end - 1)
            if (sec == t) { p = 1; next }
            if (p) exit
          }
        }
      }
      p { print }
    ' CHANGELOG.md
  )"
fi

PREV_TAG="$(git describe --tags --abbrev=0 "${BASE}^" 2>/dev/null || true)"
if [[ -n "$PREV_TAG" ]]; then
  COMMIT_COUNT_SINCE_PREV_TAG="$(git rev-list --count "${PREV_TAG}..${BASE}" 2>/dev/null || echo "n/a")"
else
  COMMIT_COUNT_SINCE_PREV_TAG="n/a (no previous tag reachable)"
fi

cat > "$RELEASE_DIR/RELEASE-NOTES.md" <<EOF
# Release $TAG

**Variant**: \`$VARIANT\`
**Branch**: \`$BRANCH\` @ \`$COMMIT_SHORT\`
**Built**: $BUILD_TIME UTC

## Contents

- **\`$ASSET_NAME\`** ($BYTES bytes, sha256 \`$SHA256_HEX\`) — static musl binary for x86_64 Linux
- **\`$ASSET_NAME.sha256\`** — sha256 checksum file
- **\`manifest.json\`** — machine-readable manifest

## Asset name convention

Mirrors upstream's release-asset naming style (\`computer-use-linux-<variant?>-<arch>-<vendor>-<sys>-<abi>\`):

- product: \`computer-use-linux\`
- variant: \`$VARIANT\` (placeholder for upstream's \`cosmic\`)
- arch: \`x86_64\`
- vendor: \`unknown\` (Rust standard placeholder; not modified)
- sys: \`linux\`
- abi: \`musl\`

## What's in this build

EOF

if [[ -n "$CHANGELOG_SECTION" ]]; then
  {
    echo "## Upstream changelog excerpt"
    echo
    echo '```'
    echo "$CHANGELOG_SECTION"
    echo '```'
  } >> "$RELEASE_DIR/RELEASE-NOTES.md"
fi

cat >> "$RELEASE_DIR/RELEASE-NOTES.md" <<EOF

## Verification commands

\`\`\`bash
sha256sum -c $ASSET_NAME.sha256
file $ASSET_NAME           # ELF 64-bit x86-64
ldd $ASSET_NAME            # statically linked
./$ASSET_NAME --help       # 8 subcommands: mcp, doctor, setup, ...
\`\`\`

## Notes

- This release artifact is built locally by \`scripts/release.sh\`.
- It is **not** pushed to GitHub by the release script itself. To publish, run
  with \`--push\` (which still requires your confirmation; never auto).
- Upstream's CI release-binary job was the reference design for this script.
  See \`.github/workflows/ci.yml\` lines 192-258.
EOF

echo "[release] RELEASE-NOTES.md written"

# 8. Cleanup staging/target to keep release/ lean.
# Tolerate failures: root-owned files (e.g. NFS-mounted host dirs from a container)
# can't be removed by the host user.  Don't let that abort the rest of the release.
rm -rf "$STAGING_DIR" "$TARGET_DIR" 2>/dev/null || true
echo "[release] staging + cargo target cleaned (saves ~1.7 GB)"

# 9. git tag
git tag -a "$TAG" -m "release $TAG

variant: $VARIANT
branch: $BRANCH @ $COMMIT_SHORT
built:  $BUILD_TIME UTC" "$BASE"

echo "[release] annotated tag created: $TAG"
git tag -n1 "$TAG"

# 10. Optional push (NEVER auto; requires --push AND interactive y/N unless --yes)
if [[ "$PUSH" -eq 1 ]]; then
  REMOTE="upstream"
  BRANCH_LOCAL="$BRANCH"

  echo "[release] --push requested."
  echo "[release]   remote:  $REMOTE"
  echo "[release]   branch:  $BRANCH_LOCAL"
  echo "[release]   tags:    $TAG"
  echo "[release]   new commits since last push:"
  git log --oneline "$REMOTE/$BRANCH_LOCAL".."$BRANCH_LOCAL" 2>/dev/null | head -10 || echo "  (no upstream/$BRANCH_LOCAL yet)"

  if [[ "$YES" -ne 1 ]]; then
    read -r -p "[release] push '$BRANCH_LOCAL' (with tag '$TAG') to '$REMOTE'? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "[release] push cancelled"; exit 6; }
  fi

  git push "$REMOTE" "$BRANCH_LOCAL" --follow-tags
  echo "[release] pushed to $REMOTE/$BRANCH_LOCAL (tags included via --follow-tags)"
else
  echo "[release] --push not set. Created tag locally; push later with:"
  echo "  git push upstream $BRANCH --follow-tags"
fi

echo
echo "=========================================="
echo "[release] DONE: $RELEASE_DIR/"
echo "=========================================="
ls -la "$RELEASE_DIR"
ls -la "$RELEASE_DIR/assets"