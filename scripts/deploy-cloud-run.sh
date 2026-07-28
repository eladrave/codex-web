#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

retry_command() {
  local max_attempts="$1"
  local delay_seconds="$2"
  local attempt=1
  shift 2

  while ! "$@"; do
    if ((attempt >= max_attempts)); then
      return 1
    fi

    printf 'Command failed; retrying in %s seconds (%s/%s)...\n' \
      "$delay_seconds" "$attempt" "$max_attempts" >&2
    sleep "$delay_seconds"
    attempt=$((attempt + 1))
    if ((delay_seconds < 16)); then
      delay_seconds=$((delay_seconds * 2))
    fi
  done
}

for command_name in gcloud git tar; do
  require_command "$command_name"
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
cd "$repo_dir"

active_account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -n 1)"
[[ -n "$active_account" ]] || die "gcloud has no active account; authenticate before running this script"

default_project="$(gcloud config get-value project 2>/dev/null || true)"
project_id="${GCP_PROJECT_ID:-}"

if [[ -z "$project_id" ]]; then
  if [[ -n "$default_project" && "$default_project" != "(unset)" ]]; then
    read -r -p "GCP project ID [$default_project]: " project_id
    project_id="${project_id:-$default_project}"
  else
    read -r -p "GCP project ID: " project_id
  fi
fi

[[ -n "$project_id" ]] || die "a GCP project ID is required"
gcloud projects describe "$project_id" >/dev/null

region="${GCP_REGION:-us-central1}"
service="${CODEX_WEB_SERVICE:-codex-web}"
repository="${CODEX_WEB_REPOSITORY:-codex-web}"
bucket="${CODEX_WEB_BUCKET:-${project_id}-codex-web-data}"
run_service_account_name="${CODEX_WEB_SERVICE_ACCOUNT:-codex-web-run}"
run_service_account="${run_service_account_name}@${project_id}.iam.gserviceaccount.com"
concurrency="${CODEX_WEB_CONCURRENCY:-80}"
interactive_gcloud_account="${CODEX_WEB_GCLOUD_ACCOUNT:-}"
ssh_source_dir="${CODEX_SSH_SOURCE_DIR:-${HOME}/.config/codex-web/ssh}"
local_container="${CODEX_WEB_LOCAL_CONTAINER:-codex-web}"
local_volume="${CODEX_WEB_LOCAL_VOLUME:-codex-web-data}"
local_image="${CODEX_WEB_LOCAL_IMAGE:-codex-web:local}"
build_mode="${CODEX_WEB_BUILD_MODE:-cloud-build}"
revision_tag="${CODEX_WEB_IMAGE_TAG:-$(git rev-parse --short=12 HEAD)}"
image="${region}-docker.pkg.dev/${project_id}/${repository}/${service}:${revision_tag}"

[[ -f "$ssh_source_dir/config" ]] || die "missing SSH config: $ssh_source_dir/config"
[[ -f "$ssh_source_dir/known_hosts" ]] || die "missing SSH known_hosts: $ssh_source_dir/known_hosts"
[[ "$concurrency" =~ ^[1-9][0-9]*$ ]] ||
  die "CODEX_WEB_CONCURRENCY must be a positive integer"
[[ "$interactive_gcloud_account" != *,* ]] ||
  die "CODEX_WEB_GCLOUD_ACCOUNT cannot contain a comma"

tmp_dir="$(mktemp -d)"
temporary_container=""

cleanup() {
  if [[ -n "$temporary_container" ]]; then
    docker rm -f "$temporary_container" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

auth_file="$tmp_dir/auth.json"
ssh_bundle="$tmp_dir/ssh.tar"

if [[ -n "${CODEX_AUTH_FILE:-}" ]]; then
  [[ -f "$CODEX_AUTH_FILE" ]] || die "CODEX_AUTH_FILE does not exist: $CODEX_AUTH_FILE"
  cp "$CODEX_AUTH_FILE" "$auth_file"
else
  require_command docker
  if docker container inspect "$local_container" >/dev/null 2>&1; then
    docker cp "${local_container}:/data/codex/auth.json" "$auth_file"
  elif docker volume inspect "$local_volume" >/dev/null 2>&1; then
    docker image inspect "$local_image" >/dev/null 2>&1 ||
      die "found volume $local_volume but not image $local_image"
    temporary_container="$(docker create --volume "${local_volume}:/data" "$local_image")"
    docker cp "${temporary_container}:/data/codex/auth.json" "$auth_file"
  else
    die "could not find Codex auth; start container $local_container or set CODEX_AUTH_FILE"
  fi
fi

[[ -s "$auth_file" ]] || die "the copied Codex auth file is empty"
COPYFILE_DISABLE=1 tar --no-xattrs -C "$ssh_source_dir" -cf "$ssh_bundle" .
tar -tf "$ssh_bundle" >/dev/null

if (( $(wc -c < "$ssh_bundle") > 65536 )); then
  die "the SSH bundle exceeds Secret Manager's 64 KiB payload limit"
fi

printf 'Deploying as %s\n' "$active_account"
printf 'Project: %s\nRegion: %s\nService: %s\nBucket: gs://%s\nImage: %s\nBuild: %s\nConcurrency: %s\n' \
  "$project_id" "$region" "$service" "$bucket" "$image" "$build_mode" "$concurrency"

gcloud services enable \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  iam.googleapis.com \
  iap.googleapis.com \
  run.googleapis.com \
  secretmanager.googleapis.com \
  storage.googleapis.com \
  --project="$project_id" \
  --quiet

if ! gcloud artifacts repositories describe "$repository" \
  --location="$region" \
  --project="$project_id" >/dev/null 2>&1; then
  gcloud artifacts repositories create "$repository" \
    --repository-format=docker \
    --location="$region" \
    --project="$project_id" \
    --quiet
fi

if ! gcloud storage buckets describe "gs://${bucket}" \
  --project="$project_id" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${bucket}" \
    --location="$region" \
    --project="$project_id" \
    --public-access-prevention \
    --uniform-bucket-level-access \
    --quiet
fi

if ! gcloud iam service-accounts describe "$run_service_account" \
  --project="$project_id" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$run_service_account_name" \
    --display-name="Codex Web Cloud Run" \
    --project="$project_id" \
    --quiet
fi

retry_command 8 2 \
  gcloud storage buckets add-iam-policy-binding "gs://${bucket}" \
    --member="serviceAccount:${run_service_account}" \
    --role=roles/storage.objectUser \
    --project="$project_id" \
    --quiet >/dev/null

upsert_secret() {
  local secret_name="$1"
  local source_file="$2"

  if gcloud secrets describe "$secret_name" \
    --project="$project_id" >/dev/null 2>&1; then
    gcloud secrets versions add "$secret_name" \
      --data-file="$source_file" \
      --project="$project_id" \
      --quiet >/dev/null
  else
    gcloud secrets create "$secret_name" \
      --data-file="$source_file" \
      --replication-policy=automatic \
      --project="$project_id" \
      --quiet >/dev/null
  fi

  retry_command 8 2 \
    gcloud secrets add-iam-policy-binding "$secret_name" \
      --member="serviceAccount:${run_service_account}" \
      --role=roles/secretmanager.secretAccessor \
      --project="$project_id" \
      --quiet >/dev/null
}

upsert_secret codex-web-auth "$auth_file"
upsert_secret codex-web-ssh-bundle "$ssh_bundle"

case "$build_mode" in
  cloud-build)
    gcloud builds submit "$repo_dir" \
      --config="$repo_dir/cloudbuild.yaml" \
      --substitutions="_IMAGE=${image}" \
      --region="$region" \
      --project="$project_id" \
      --quiet
    ;;
  local)
    require_command docker
    gcloud auth configure-docker "${region}-docker.pkg.dev" --quiet
    docker buildx build \
      --platform linux/amd64 \
      --tag "$image" \
      --push \
      "$repo_dir"
    ;;
  skip)
    gcloud artifacts docker images describe "$image" \
      --project="$project_id" >/dev/null 2>&1 ||
      die "cannot skip build because the image does not exist: $image"
    ;;
  *)
    die "unsupported CODEX_WEB_BUILD_MODE: $build_mode (use cloud-build, local, or skip)"
    ;;
esac

gcloud beta services identity create \
  --service=iap.googleapis.com \
  --project="$project_id" >/dev/null

run_command=(gcloud run)
if ! gcloud run deploy --help 2>/dev/null | grep -q 'mount-options'; then
  run_command=(gcloud beta run)
fi

startup_command='set -euo pipefail; install -d -m 700 /tmp/codex-ssh /tmp/codex-home /tmp/codex-web; cp /run/secrets/ssh-bundle/ssh.tar /tmp/codex-ssh.tar; tar -xf /tmp/codex-ssh.tar -C /tmp/codex-ssh; install -m 600 /run/secrets/codex-auth/auth.json /tmp/codex-home/auth.json; export CODEX_HOME=/tmp/codex-home; export CODEX_WEB_DATA_DIR=/tmp/codex-web; export CODEX_SSH_SOURCE_DIR=/tmp/codex-ssh; exec /usr/bin/tini -- /usr/local/bin/codex-web-entrypoint'
runtime_env_vars='CODEX_HOME=/tmp/codex-home,CODEX_WEB_DATA_DIR=/tmp/codex-web,CODEX_WEB_OAUTH_CALLBACK_BRIDGE=0,CODEX_WEB_STATE_BACKUP_FILE=/data/codex-web-state.tar'
if [[ -n "$interactive_gcloud_account" ]]; then
  runtime_env_vars+=",CLOUDSDK_CORE_ACCOUNT=${interactive_gcloud_account}"
fi

"${run_command[@]}" deploy "$service" \
  --project="$project_id" \
  --region="$region" \
  --image="$image" \
  --service-account="$run_service_account" \
  --execution-environment=gen2 \
  --port=8080 \
  --cpu=1 \
  --memory=2Gi \
  --min-instances=1 \
  --max-instances=1 \
  --concurrency="$concurrency" \
  --timeout=3600 \
  --no-cpu-throttling \
  --no-allow-unauthenticated \
  --iap \
  --set-env-vars="$runtime_env_vars" \
  --set-secrets="/run/secrets/ssh-bundle/ssh.tar=codex-web-ssh-bundle:latest,/run/secrets/codex-auth/auth.json=codex-web-auth:latest" \
  --add-volume="name=codex-data,type=cloud-storage,bucket=${bucket},mount-options=uid=10001;gid=10001;dir-mode=700;file-mode=600;implicit-dirs=true" \
  --add-volume-mount=volume=codex-data,mount-path=/data \
  --command=/bin/bash \
  --args=-lc,"$startup_command" \
  --quiet

project_number="$(gcloud projects describe "$project_id" --format='value(projectNumber)')"
iap_service_account="service-${project_number}@gcp-sa-iap.iam.gserviceaccount.com"

retry_command 8 2 \
  gcloud run services add-iam-policy-binding "$service" \
    --project="$project_id" \
    --region="$region" \
    --member="serviceAccount:${iap_service_account}" \
    --role=roles/run.invoker \
    --quiet >/dev/null

if [[ "$active_account" != *gserviceaccount.com ]]; then
  iap_command=(gcloud iap)
  if ! gcloud iap web add-iam-policy-binding --help 2>/dev/null |
    grep -q 'cloud-run'; then
    iap_command=(gcloud beta iap)
  fi

  if ! "${iap_command[@]}" web add-iam-policy-binding \
    --member="user:${active_account}" \
    --role=roles/iap.httpsResourceAccessor \
    --region="$region" \
    --resource-type=cloud-run \
    --service="$service" \
    --project="$project_id" \
    --quiet >/dev/null; then
    printf '%s\n' \
      "warning: deployment succeeded, but IAP user access needs to be completed in the Cloud Run Security tab" >&2
  fi
fi

service_url="$(gcloud run services describe "$service" \
  --project="$project_id" \
  --region="$region" \
  --format='value(status.url)')"

printf '\nDeployment complete: %s\n' "$service_url"
printf 'Persistent data bucket: gs://%s\n' "$bucket"
printf 'To add or change SSH hosts, update %s and rerun this script.\n' "$ssh_source_dir"
