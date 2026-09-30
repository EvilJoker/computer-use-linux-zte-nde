#!/usr/bin/env bash
# Install computer-use-linux-static-claude-nde onto a DSH web host.
#
# Pulls the latest release asset from EvilJoker/computer-use-linux-zte-nde,
# verifies its sha256, drops it into the npm package's bin/ directory without
# touching the original (v0.7.1 gnu) binary, then patches DSH cordis.patch.yml
# to spawn it via the npm wrapper + COMPUTER_USE_LINUX_BIN.
#
# Idempotent: re-running on the same latest tag is a no-op.
#
# Usage:
#   scripts/install-claude-nde.sh
#   scripts/install-claude-nde.sh --dry-run
#   scripts/install-claude-nde.sh --dsh-dir=/home/<user>/dsh_test/computer-use-poc

set -euo pipefail

REPO="EvilJoker/computer-use-linux-zte-nde"
DRY_RUN=0
DSH_DIR="${HOME}/dsh_test/computer-use-poc"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)        DRY_RUN=1; shift ;;
        --dsh-dir=*)      DSH_DIR="${1#*=}"; shift ;;
        --dsh-dir)        DSH_DIR="$2"; shift 2 ;;
        --repo=*)         REPO="${1#*=}"; shift ;;
        -h|--help)
            sed -n '2,16p' "$0"
            exit 0
            ;;
        *) echo "install-claude-nde: unknown arg: $1" >&2; exit 2 ;;
    esac
done

say() { printf '[install-claude-nde] %s\n' "$*"; }
die() { printf '[install-claude-nde] ERROR: %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh CLI not found on PATH"
gh auth status >/dev/null 2>&1 || die "gh CLI is not authenticated; run 'gh auth login' first"

say "Repo:       $REPO"
say "DSH dir:    $DSH_DIR"
say "Dry run:    $DRY_RUN"

# Resolve the npm package's bin/ directory inside DSH_DIR.
NPM_PKG_DIR="$DSH_DIR/node_modules/@agent-sh/computer-use-linux"
NPM_BIN_DIR="$NPM_PKG_DIR/npm/bin"
TARGET="$NPM_BIN_DIR/computer-use-linux-linux-x64-musl"
SHA_FILE="$NPM_BIN_DIR/computer-use-linux-linux-x64-musl.sha256"
[[ -d "$NPM_BIN_DIR" ]] || die "npm package bin dir not found: $NPM_BIN_DIR"

# Resolve latest release tag.
LATEST_TAG="$(gh release view --repo "$REPO" --json tagName -q '.tagName' 2>/dev/null || true)"
[[ -n "$LATEST_TAG" ]] || die "could not resolve latest release tag from $REPO"
say "Latest tag: $LATEST_TAG"

# If the target is already at this exact tag, no-op.
if [[ -f "$TARGET.tag" ]]; then
    if [[ "$(cat "$TARGET.tag")" == "$LATEST_TAG" ]]; then
        say "Already installed at $LATEST_TAG — nothing to do"
        exit 0
    fi
fi

# Download to a temp dir so a failed/aborted install leaves no half files.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ASSET="computer-use-linux-static-claude-nde-x86_64-unknown-linux-musl"
SHA_ASSET="${ASSET}.sha256"

say "Downloading $ASSET + .sha256"
gh release download "$LATEST_TAG" --repo "$REPO" \
    --pattern "$ASSET" --pattern "$SHA_ASSET" \
    --dir "$WORK" >/dev/null

DOWNLOADED="$WORK/$ASSET"
DOWNLOADED_SHA="$WORK/$SHA_ASSET"
[[ -s "$DOWNLOADED"   ]] || die "downloaded binary missing or empty: $DOWNLOADED"
[[ -s "$DOWNLOADED_SHA" ]] || die "downloaded sha256 missing or empty: $DOWNLOADED_SHA"

# Verify sha256 (cross-check downloaded file against the .sha256 sidecar).
EXPECTED_SHA="$(awk '{print $1}' "$DOWNLOADED_SHA")"
ACTUAL_SHA="$(sha256sum "$DOWNLOADED" | awk '{print $1}')"
say "Expected: $EXPECTED_SHA"
say "Actual:   $ACTUAL_SHA"
if [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
    die "sha256 mismatch — refusing to install"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
    say "--dry-run: would install $ASSET ($ACTUAL_SHA) into $TARGET"
    say "--dry-run: would patch cordis.patch.yml"
    exit 0
fi

# Back up the existing target, if any.
if [[ -e "$TARGET" ]]; then
    BACKUP="$TARGET.bak.$(date +%Y%m%d-%H%M%S)"
    say "Backing up existing target to $BACKUP"
    mv -v "$TARGET" "$BACKUP"
fi
if [[ -e "$SHA_FILE" ]]; then
    SHA_BACKUP="$SHA_FILE.bak.$(date +%Y%m%d-%H%M%S)"
    say "Backing up existing sha256 to $SHA_BACKUP"
    mv -v "$SHA_FILE" "$SHA_BACKUP"
fi

# Drop the new binary + sha256 in.
say "Installing binary to $TARGET"
cp -v "$DOWNLOADED"   "$TARGET"
cp -v "$DOWNLOADED_SHA" "$SHA_FILE"
chmod +x "$TARGET"

# Record the tag so re-runs can short-circuit.
echo "$LATEST_TAG" > "$TARGET.tag"

# Patch DSH cordis.patch.yml so mcp-computer-use spawns the npm wrapper
# with COMPUTER_USE_LINUX_BIN pointing at our new musl binary.
CORDIS="$HOME/.dsh/profiles/web/cordis.patch.yml"
[[ -f "$CORDIS" ]] || die "cordis.patch.yml not found at $CORDIS"

CORDIS_BACKUP_DIR="$HOME/.dsh/backups/install-claude-nde-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$CORDIS_BACKUP_DIR"
say "Backing up cordis.patch.yml to $CORDIS_BACKUP_DIR/cordis.patch.yml"
cp -v "$CORDIS" "$CORDIS_BACKUP_DIR/cordis.patch.yml"

# Locate the mcp-computer-use row's env block and patch in the two envs.
# Idempotent: skip any env that already names the same value.
python3 - "$CORDIS" "$TARGET" <<'PYEOF'
import sys, re
path, target = sys.argv[1], sys.argv[2]
with open(path) as f:
    src = f.read()

# Match the mcp-computer-use block: from "id: mcp-computer-use" to the
# next top-level "    - id:" or end of the insert list.  We anchor on
# "id: mcp-computer-use" + "serverName: computer-use" so we don't hit
# any other row.
m = re.search(
    r'(    - id: mcp-computer-use\n'
    r'      name: .@deepseek-ai/dsh-mcp-client.\n'
    r'      config:\n'
    r'        serverName: computer-use\n'
    r'.*?)(\n        env:\n)(        COMPUTER_USE_LINUX_ENABLE_SHELL: .0.\n)(        \}\n|\n        reconnect:|\Z)',
    src, flags=re.S,
)
if not m:
    sys.exit("could not locate mcp-computer-use row in cordis.patch.yml")

block_body, env_head, env_line, after = m.group(1), m.group(2), m.group(3), m.group(4)

# Compose the new env block: keep existing COMPUTER_USE_LINUX_ENABLE_SHELL,
# add COMPUTER_USE_LINUX_BIN (only if missing) and NDE_AT_SPI_SCOPE_REQUIRED.
extra = []
if 'COMPUTER_USE_LINUX_BIN:' not in block_body:
    extra.append(f'          COMPUTER_USE_LINUX_BIN: {target}\n')
if 'NDE_AT_SPI_SCOPE_REQUIRED:' not in block_body:
    extra.append(f'          NDE_AT_SPI_SCOPE_REQUIRED: \'1\'\n')

if not extra:
    sys.exit(0)

new_block = block_body + env_head + env_line + ''.join(extra) + (
    '        reconnect:\n' if after.strip().startswith('reconnect') else
    '        }\n' if after.strip() == '}' else after
)
src = src[:m.start()] + new_block + src[m.end():]
with open(path, 'w') as f:
    f.write(src)
PYEOF

say "Patched cordis.patch.yml"
say "  + COMPUTER_USE_LINUX_BIN: $TARGET"
say "  + NDE_AT_SPI_SCOPE_REQUIRED: '1'"

# Trigger DSH mcp reconnect so the next call spawns the new binary.
# We pkill the npm wrapper chain — DSH's mcp-client reconnect settings
# (initialDelayMs=500, maxAttempts=10) will spawn it again with the new
# cordis config.
if pgrep -f 'computer-use-linux-linux-x64' >/dev/null 2>&1; then
    say "Restarting DSH mcp-computer-use (pkill + reconnect)"
    pkill -f 'computer-use-linux-linux-x64' || true
    sleep 3
    pkill -f 'npm/bin/computer-use-linux.js mcp' || true
    sleep 4
fi

# Verify the new binary is live.
LIVE_PID="$(pgrep -f 'computer-use-linux-linux-x64-musl' | head -1 || true)"
if [[ -n "$LIVE_PID" ]]; then
    say "Verified: new binary live (PID $LIVE_PID)"
else
    say "WARN: did not see the new binary live yet; check DSH logs"
fi

say "Done."
