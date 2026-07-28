# Deploy Codex Web to Google Cloud Run

This guide deploys Codex Web as a private, single-user Cloud Run service. The
deployment uses:

- Google Cloud Build and Artifact Registry for the container image
- Secret Manager for Codex authentication and SSH configuration
- a Cloud Storage bucket mounted at `/data`
- Identity-Aware Proxy (IAP) for browser access
- one always-allocated Cloud Run instance

The production container includes the Codex CLI at `/usr/local/bin/codex`.

## Prerequisites

Install the Google Cloud CLI. Docker Desktop is also needed when the helper
copies authentication from the local Codex Web container. Confirm the tools
you use are available:

```bash
gcloud version
docker version
```

Docker Buildx is only required when using `CODEX_WEB_BUILD_MODE=local`.

Authenticate `gcloud` before running the deployment:

```bash
gcloud auth login
gcloud auth list
```

The selected Google Cloud project must have billing enabled. Your active
account needs permission to enable APIs and manage Cloud Run, Artifact
Registry, IAM service accounts, Secret Manager, Cloud Storage, and IAP.

List the projects available to your account:

```bash
gcloud projects list
```

## Prepare local Codex authentication

Sign in through the local Codex Web container before deploying. The deployment
helper copies the working authentication from either:

1. a local container named `codex-web`; or
2. a Docker volume named `codex-web-data`.

For example:

```bash
docker run --rm \
  --name codex-web \
  --publish 127.0.0.1:8080:8080 \
  --publish 127.0.0.1:1455:1455 \
  --volume codex-web-data:/data \
  --volume "$HOME/.config/codex-web/ssh:/run/secrets/codex-ssh:ro" \
  codex-web:local
```

Open <http://127.0.0.1:8080> and complete the OpenAI login before proceeding.

If the authentication file is stored elsewhere, provide it explicitly:

```bash
CODEX_AUTH_FILE=/absolute/path/to/auth.json \
./scripts/deploy-cloud-run.sh
```

Do not commit `auth.json`, SSH private keys, or generated secret bundles.

## Prepare the SSH configuration

The default SSH source directory is:

```text
~/.config/codex-web/ssh
```

It must contain:

```text
config
known_hosts
one or more private key files
```

Example:

```sshconfig
Host contabocodexcli
  HostName 80.190.72.35
  User root
  Port 22
  IdentityFile ~/.ssh/remote_key
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile ~/.ssh/known_hosts
```

`IdentityFile` refers to the location inside the container. If the source key
is `~/.config/codex-web/ssh/remote_key`, use `~/.ssh/remote_key` in the SSH
configuration.

Verify the connection before deploying:

```bash
ssh -F "$HOME/.config/codex-web/ssh/config" \
  contabocodexcli \
  'codex app-server daemon version'
```

Each remote machine needs the official standalone Codex installation, its own
Codex authentication, and key-based SSH access:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
codex login
codex app-server daemon version
```

## Deploy

From the repository root:

```bash
cd /path/to/codex-web
./scripts/deploy-cloud-run.sh
```

The script uses the active `gcloud` account and asks for a project:

```text
GCP project ID [current-project]:
```

Enter the project ID from `gcloud projects list`, or press Enter to use the
displayed project.

The first deployment can take several minutes. The helper:

1. enables the required Google Cloud APIs;
2. creates or reuses an Artifact Registry Docker repository;
3. creates or reuses a private Cloud Storage bucket;
4. creates a dedicated Cloud Run service account;
5. uploads Codex authentication and the SSH bundle to Secret Manager;
6. uses Google Cloud Build to build and push a native `linux/amd64` image;
7. mounts the Cloud Storage bucket at `/data`;
8. keeps Codex's socket and SQLite runtime state on the instance-local
   filesystem;
9. snapshots durable Codex and Electron state safely into the bucket;
10. deploys an IAP-protected Cloud Run service; and
11. grants the active Google account access through IAP.

At completion, it prints the Cloud Run URL and bucket name.

## Deployment defaults

The default configuration is:

| Setting                      | Default                       |
| ---------------------------- | ----------------------------- |
| Region                       | `us-central1`                 |
| Service                      | `codex-web`                   |
| Artifact Registry repository | `codex-web`                   |
| Data bucket                  | `<project-id>-codex-web-data` |
| Runtime service account      | `codex-web-run`               |
| Minimum instances            | `1`                           |
| Maximum instances            | `1`                           |
| Concurrency                  | `80`                          |
| Memory                       | `2Gi`                         |
| CPU                          | `1`                           |
| Request timeout              | `3600` seconds                |

The instance uses instance-based CPU allocation so Codex and SSH subprocesses
can continue running while the browser is idle. A minimum of one instance means
the service incurs Cloud Run charges while it is not actively being used.
The service remains limited to one instance, while concurrency is high enough
for the long-lived Codex WebSocket and browser asset requests to share it.

The GCS bucket is mounted at `/data` for persistent user files. Codex runtime
state uses `/tmp/codex-home` and Electron state uses `/tmp/codex-web` because
both contain Unix sockets and SQLite databases, which are not compatible with
Cloud Storage FUSE. The helper restores OpenAI authentication and SSH
configuration from Secret Manager on every instance start.

Codex Web safely snapshots both state directories into immutable archives under
`/data/codex-web-state.tar.snapshots/` every 15 seconds and attempts a final
snapshot on shutdown. It retains the four newest snapshots and restores the
newest valid one. SQLite databases are copied with SQLite's online backup API;
ordinary settings files are copied normally. Caches, sockets, temporary files,
lock files, and `auth.json` are excluded. The archive is restored before a
replacement instance starts the app.

This preserves saved SSH connections and auto-connect choices, custom
instructions, memory configuration and data, app preferences, and other
durable Codex settings. A crash can lose changes made since the most recent
15-second snapshot, but it cannot expose a live SQLite database to Cloud
Storage FUSE.

## Override deployment settings

Set environment variables before invoking the helper:

```bash
GCP_REGION=europe-west1 \
CODEX_WEB_BUCKET=my-private-codex-data \
CODEX_WEB_SERVICE=my-codex-web \
./scripts/deploy-cloud-run.sh
```

Supported overrides include:

| Variable                    | Purpose                                     |
| --------------------------- | ------------------------------------------- |
| `GCP_PROJECT_ID`            | Skip the project prompt                     |
| `GCP_REGION`                | Cloud Run and Artifact Registry region      |
| `CODEX_WEB_SERVICE`         | Cloud Run service name                      |
| `CODEX_WEB_REPOSITORY`      | Artifact Registry repository                |
| `CODEX_WEB_BUCKET`          | Existing or new Cloud Storage bucket        |
| `CODEX_WEB_SERVICE_ACCOUNT` | Runtime service-account name                |
| `CODEX_WEB_CONCURRENCY`     | Requests accepted by the single instance    |
| `CODEX_SSH_SOURCE_DIR`      | Local SSH configuration directory           |
| `CODEX_AUTH_FILE`           | Explicit local Codex `auth.json`            |
| `CODEX_WEB_IMAGE_TAG`       | Container image tag                         |
| `CODEX_WEB_BUILD_MODE`      | `cloud-build` (default), `local`, or `skip` |

Cloud Build uses the checked-in `cloudbuild.yaml` configuration with an
`E2_HIGHCPU_8` builder and a 30-minute timeout. This avoids slow x86 emulation
when deploying from an Apple Silicon Mac. To use local Docker Buildx instead:

```bash
CODEX_WEB_BUILD_MODE=local \
./scripts/deploy-cloud-run.sh
```

Use `CODEX_WEB_BUILD_MODE=skip` only when the tagged image already exists in
Artifact Registry and only Cloud Run configuration or secrets have changed.

## First-time IAP configuration

The service is not publicly accessible. The script enables IAP and grants the
active Google account the IAP-secured Web App User role.

Some personal projects require initial IAP OAuth configuration in Google Cloud
Console:

1. Open **Cloud Run**.
2. Select the `codex-web` service.
3. Open **Security**.
4. Select **Require authentication**.
5. If **Identity-Aware Proxy (IAP)** is already selected but the service URL
   reports `Empty Google Account OAuth client ID(s)/secret(s)`, clear the IAP
   checkbox and click **Save**.
6. Select **Identity-Aware Proxy (IAP)** and click **Save** again.
7. Wait for the `IAP configured` confirmation.
8. Rerun `./scripts/deploy-cloud-run.sh`.

Do not enable unauthenticated public access. Codex Web can control remote
machines through SSH and should remain private.

## Add another remote machine

Create or copy a private key into the SSH source directory:

```bash
cp /path/to/server_two_key \
  "$HOME/.config/codex-web/ssh/server_two_key"

chmod 600 \
  "$HOME/.config/codex-web/ssh/server_two_key"
```

Add the verified server host key:

```bash
ssh-keyscan -H 203.0.113.20 \
  >> "$HOME/.config/codex-web/ssh/known_hosts"
```

Verify the fingerprint through the server console or another trusted channel.

Add a concrete alias to `~/.config/codex-web/ssh/config`:

```sshconfig
Host server-two
  HostName 203.0.113.20
  User root
  Port 22
  IdentityFile ~/.ssh/server_two_key
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile ~/.ssh/known_hosts
```

Test it:

```bash
ssh -F "$HOME/.config/codex-web/ssh/config" \
  server-two \
  'codex app-server daemon version'
```

Rerun the deployment helper:

```bash
./scripts/deploy-cloud-run.sh
```

This uploads a new SSH secret version and deploys a new Cloud Run revision.
After deployment, open Codex Web and select **Settings > Connections > Add**.
Choose the new alias.

Use a concrete `Host` alias for every machine. Entries such as `Host *` are not
displayed in the Codex connection picker.

## GitHub automation

The fork includes two workflows:

- **Check OpenAI releases** runs every Monday at 13:17 UTC and can also be
  started manually from **Actions**. It checks the official Codex desktop
  appcast and the latest `@openai/codex` npm package. When a version changes, it
  updates the Dockerfile, runs `npm test`, completes a full production build in
  Google Cloud Build, and opens a PR assigned to the repository owner.
- **Deploy Cloud Run** runs after every push to `main`, including a merged
  updater PR. It builds an image tagged with the merge commit and changes only
  the image on the existing `codex-web` service.

### Notifications

A successful update check opens a GitHub PR assigned to the repository owner.
That appears in GitHub's notification inbox and is also sent by email when
assigned-item email notifications are enabled in the owner's GitHub settings.

If detection, tests, or the compatibility build fails, the workflow opens or
updates an assigned issue named **OpenAI Codex update needs attention**, with a
link to the failed run. GitHub's normal failed-workflow notification may also
be sent, according to the account's Actions notification preferences.

### Deploy an update

Review the generated PR, including its linked Cloud Build run, and merge it into
`main`. No local command is required. The merge starts **Deploy Cloud Run**,
which:

1. authenticates to Google Cloud with short-lived GitHub OIDC credentials;
2. builds the merged commit with `cloudbuild.yaml`;
3. pushes the commit-tagged image to Artifact Registry;
4. updates the existing Cloud Run service to that image; and
5. reports the ready revision and production URL in the workflow summary.

The deployment does not recreate the service. GCS state snapshots, SSH and
OpenAI secrets, IAP access, scaling, CPU allocation, and volume mounts survive
the image update.

The runtime image includes Node.js, npm, Codex CLI, `gcloud`, `gh`, Git, Git
LFS, Python 3 with pip and virtual environments, native build tools, `jq`,
`ripgrep`, `fd`, `rsync`, SQLite and archive/process/network diagnostics.
These binaries are part of the immutable image and therefore remain available
after Cloud Run replaces an instance.

Installing an OS package from the app terminal is not durable and normally is
not possible because the container runs as the non-root `codex` user. Add
another permanent utility to the Dockerfile and merge it into `main`; this
workflow rebuilds and deploys it. Do not put package-manager directories on the
GCS mount.

`gcloud` uses the Cloud Run runtime service account through Application Default
Credentials. The installed CLI does not expand that account's IAM roles.

The workflow can be rerun from **Actions > Deploy Cloud Run > Run workflow**.
Because manual runs use `main`, they redeploy the current committed production
version.

### GitHub-to-GCP authentication

The workflows expect these GitHub repository variables:

| Variable                         | Value for this deployment               |
| -------------------------------- | --------------------------------------- |
| `GCP_PROJECT_ID`                 | `aztm-amesh`                            |
| `GCP_REGION`                     | `us-central1`                           |
| `GCP_CLOUD_RUN_SERVICE`          | `codex-web`                             |
| `GCP_ARTIFACT_REPOSITORY`        | `codex-web`                             |
| `GCP_DEPLOY_SERVICE_ACCOUNT`     | GitHub deployment service-account email |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | Full Workload Identity provider name    |

No long-lived Google Cloud key is stored in GitHub. The provider accepts tokens
only from `eladrave/codex-web` workflows running from `refs/heads/main`.

### Roll back

Cloud Run retains previous revisions. To restore an earlier image, open the
failed deployment in Google Cloud Console and route traffic back to the last
known-good revision, or run:

```bash
gcloud run services update-traffic codex-web \
  --project aztm-amesh \
  --region us-central1 \
  --to-revisions PREVIOUS_REVISION=100
```

## Deploy an update

Pull or build the desired repository revision, then rerun:

```bash
git pull
./scripts/deploy-cloud-run.sh
```

The image tag defaults to the current Git commit. The helper pushes the new
image, adds new Secret Manager versions, and creates a new Cloud Run revision.
User files in `/data` remain in the mounted bucket.

## Cloud Storage `/data` considerations

Cloud Storage FUSE persists objects across Cloud Run revisions, but it is not a
POSIX filesystem. It does not support file locking and is not recommended as a
database backend. Codex Web therefore keeps Codex and Electron runtime state on
the instance-local filesystem while exposing the bucket at `/data` for ordinary
user files.

Do not point `CODEX_HOME` or `CODEX_WEB_DATA_DIR` directly at the GCS mount.
Both trees contain files that require POSIX filesystem behavior. The deployment
helper instead sets `CODEX_WEB_STATE_BACKUP_FILE=/data/codex-web-state.tar`.
The container uses that path as the base name for immutable rolling snapshots,
so a new Cloud Run revision never reads an archive while the previous revision
is replacing it.

## Troubleshooting

### Codex authentication was not found

Start the locally authenticated `codex-web` container, or specify:

```bash
CODEX_AUTH_FILE=/absolute/path/to/auth.json \
./scripts/deploy-cloud-run.sh
```

### The SSH alias does not appear

Confirm that:

- the entry begins with a concrete `Host alias`;
- its private key is present in the SSH source directory;
- `IdentityFile` uses `~/.ssh/<key-file>`;
- the alias works with `ssh -F`; and
- the deployment helper was rerun after changing the files.

### Cloud Run cannot reach SSH port 22

Confirm that the remote firewall permits SSH from the internet. Cloud Run uses
dynamic outbound addresses by default. If the remote server requires an IP
allowlist, configure Direct VPC egress and Cloud NAT with a reserved static
outbound IP.

### The service URL returns an authorization error

Complete the first-time IAP configuration and verify that the active Google
account has the **IAP-secured Web App User** role for the Cloud Run service.

If the response is `Empty Google Account OAuth client ID(s)/secret(s)`, use the
off/save/on/save sequence under **First-time IAP configuration**. OAuth client
creation for a personal project cannot be completed by `gcloud` alone.

### The app stays on its startup logo

Check the latest revision for HTTP 429 responses:

```bash
gcloud logging read \
  'resource.type="cloud_run_revision" AND httpRequest.status=429' \
  --project=PROJECT_ID \
  --limit=20
```

Codex keeps a WebSocket open, so Cloud Run concurrency must be greater than
one. The helper defaults to `80` while retaining a maximum of one instance.

### The installed `gcloud run` command rejects mount options

The helper automatically uses `gcloud beta run` when the installed stable
command does not expose Cloud Storage FUSE mount options. Update Google Cloud
CLI components if neither command supports them:

```bash
gcloud components update
```
