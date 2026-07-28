#!/usr/bin/env bash
set -euo pipefail
umask 077

data_dir="${CODEX_WEB_DATA_DIR:-/data}"
codex_home="${CODEX_HOME:-$data_dir/codex}"
cli_state_dir="${CODEX_WEB_CLI_STATE_DIR:-$codex_home/cli}"
gh_config_dir="${GH_CONFIG_DIR:-$cli_state_dir/gh}"
gcloud_config_dir="${CLOUDSDK_CONFIG:-$cli_state_dir/gcloud}"
git_config_global="${GIT_CONFIG_GLOBAL:-$cli_state_dir/gitconfig}"
ssh_source_dir="${CODEX_SSH_SOURCE_DIR:-/run/secrets/codex-ssh}"
ssh_target_dir="${HOME}/.ssh"

install -d -m 700 \
  "$data_dir" \
  "$data_dir/cache" \
  "$codex_home" \
  "$data_dir/crash-dumps" \
  "$data_dir/logs" \
  "$data_dir/session" \
  "$cli_state_dir" \
  "$gh_config_dir" \
  "$gcloud_config_dir" \
  "$(dirname "$git_config_global")" \
  "$ssh_target_dir"

export CODEX_HOME="$codex_home"
export GH_CONFIG_DIR="$gh_config_dir"
export CLOUDSDK_CONFIG="$gcloud_config_dir"
export GIT_CONFIG_GLOBAL="$git_config_global"

if [[ -n "${CODEX_WEB_STATE_BACKUP_FILE:-}" ]]; then
  node /usr/local/lib/codex-web/state-sync.mjs restore
fi

if [[ -d "$ssh_source_dir" ]]; then
  shopt -s nullglob
  ssh_source_files=("$ssh_source_dir"/*)
  shopt -u nullglob

  for source_file in "${ssh_source_files[@]}"; do
    if [[ -f "$source_file" ]]; then
      install -m 600 "$source_file" "$ssh_target_dir/$(basename "$source_file")"
    fi
  done
fi

if [[ "${CODEX_WEB_PREPARE_ONLY:-0}" == "1" ]]; then
  exit 0
fi

if [[ -n "${CODEX_WEB_STATE_BACKUP_FILE:-}" ]]; then
  node /usr/local/lib/codex-web/state-sync.mjs watch &
fi

if [[ "${CODEX_WEB_OAUTH_CALLBACK_BRIDGE:-1}" == "1" ]]; then
  node /usr/local/lib/codex-web/oauth-callback-bridge.mjs &
fi

exec node /app/src/server/main.js \
  --host "${CODEX_WEB_HOST:-0.0.0.0}" \
  --port "${PORT:-8080}" \
  "$@"
