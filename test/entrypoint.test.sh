#!/usr/bin/env bash
set -euo pipefail

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/secrets"
printf '%s\n' \
  'Host alpha' \
  '  HostName alpha.example.test' \
  >"$test_root/secrets/config"
printf '%s\n' 'private-key-placeholder' >"$test_root/secrets/id_ed25519"

HOME="$test_root/home" \
CODEX_SSH_SOURCE_DIR="$test_root/secrets" \
CODEX_WEB_DATA_DIR="$test_root/data" \
CODEX_WEB_PREPARE_ONLY=1 \
  bash docker/entrypoint.sh

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

test "$(file_mode "$test_root/home/.ssh")" = "700"
test "$(file_mode "$test_root/home/.ssh/config")" = "600"
test "$(file_mode "$test_root/home/.ssh/id_ed25519")" = "600"
test -d "$test_root/data/codex"
test -d "$test_root/data/session"
test "$(file_mode "$test_root/data/codex/cli")" = "700"
test "$(file_mode "$test_root/data/codex/cli/gh")" = "700"
test "$(file_mode "$test_root/data/codex/cli/gcloud")" = "700"

GH_CONFIG_DIR="$test_root/custom/gh" \
CLOUDSDK_CONFIG="$test_root/custom/gcloud" \
GIT_CONFIG_GLOBAL="$test_root/custom/git/config" \
HOME="$test_root/custom-home" \
CODEX_SSH_SOURCE_DIR="$test_root/missing-secrets" \
CODEX_WEB_DATA_DIR="$test_root/custom-data" \
CODEX_WEB_PREPARE_ONLY=1 \
  bash docker/entrypoint.sh

test "$(file_mode "$test_root/custom/gh")" = "700"
test "$(file_mode "$test_root/custom/gcloud")" = "700"
test "$(file_mode "$test_root/custom/git")" = "700"
