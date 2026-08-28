#!/usr/bin/env bash
set -euo pipefail

# Check if gpg is available (required)
if ! command -v gpg >/dev/null 2>&1; then
    echo "ERROR: 'gpg' is required for bad_key_test, but was not found on PATH." >&2
    exit 1
fi

# Locate root rules_distroless workspace directory by resolving realpath of rules_distroless file
if [ -n "${RULES_DISTROLESS_PATH:-}" ]; then
    REAL_PATH="$(realpath "${RULES_DISTROLESS_PATH}")"
    REPO_ROOT="$(cd "$(dirname "${REAL_PATH}")/.." && pwd -P)"
elif [ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]; then
    REPO_ROOT="$(cd "${BUILD_WORKSPACE_DIRECTORY}/../.." && pwd)"
else
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Generate an untrusted / bad key that does NOT match Debian signing keys
mkdir -m 700 -p "$TMP_DIR/gnupg"
cat << 'KEYGEN' > "$TMP_DIR/keygen.txt"
Key-Type: RSA
Key-Length: 2048
Name-Real: Untrusted Bad Key
Name-Email: untrusted-bad-key@example.com
Expire-Date: 0
%no-protection
%commit
KEYGEN

gpg --homedir "$TMP_DIR/gnupg" --no-tty --batch --generate-key "$TMP_DIR/keygen.txt" >/dev/null 2>&1
gpg --homedir "$TMP_DIR/gnupg" --armor --export -o "$TMP_DIR/bad_key.asc" untrusted-bad-key@example.com

# Create an ephemeral test workspace with the bad key
cat << BAZEL_MODULE > "$TMP_DIR/MODULE.bazel"
bazel_dep(name = "bazel_skylib", version = "1.5.0")
bazel_dep(name = "rules_distroless", version = "0.0.0")

local_path_override(
    module_name = "rules_distroless",
    path = "${REPO_ROOT}",
)

apt = use_extension("@rules_distroless//apt:extensions.bzl", "apt")
apt.sources_list(
    architectures = ["amd64"],
    components = ["main"],
    gpg_keys = ["//:bad_key.asc"],
    suites = ["bullseye"],
    types = ["deb"],
    uris = ["https://snapshot.debian.org/archive/debian/20240901T024950Z"],
)
apt.install(
    dependency_set = "bullseye",
    packages = ["tzdata"],
    suites = ["bullseye"],
)
use_repo(apt, "bullseye")
BAZEL_MODULE

cat << 'BUILD_FILE' > "$TMP_DIR/BUILD.bazel"
exports_files(["bad_key.asc"])
BUILD_FILE

echo "Running bazel build with bad GPG key against $REPO_ROOT..."
set +e
OUTPUT="$(cd "$TMP_DIR" && bazel --output_base="$TMP_DIR/out" build @bullseye//tzdata/amd64:data 2>&1)"
EXIT_CODE=$?
set -e

if [ $EXIT_CODE -eq 0 ]; then
    echo "ERROR: Expected bazel build with invalid GPG key to FAIL, but it SUCCEEDED."
    exit 1
fi

if ! echo "$OUTPUT" | grep -q "GPG verification failed"; then
    echo "ERROR: Expected 'GPG verification failed' in error output, but got:"
    echo "$OUTPUT"
    exit 1
fi

echo "Negative test PASSED: Invalid GPG key correctly failed signature verification."
