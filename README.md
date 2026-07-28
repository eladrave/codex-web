# codex-web

a browser frontend for codex desktop, running on a machine you control.

https://github.com/user-attachments/assets/0a33cbd8-741c-412c-9e75-46dfe9324596

## motivation

the agents were never meant to stay trapped in a terminal window for long.
codex desktop brought the power of agents to your local computer, where your
files, credentials, and tools already live.

codex-web brings codex desktop to the browser while keeping the backend on a
machine you control (a linux box in the cloud, your home lab, or a desktop / mac
mini). agents keep running after your laptop closes. you can reconnect from any
device with a browser.

this project aims to be as thin a wrapper as possible to ensure upstream changes
to the codex desktop app can be integrated quickly.

## usage

`codex-web` serves the browser client and hosts the desktop-side bridge. by
default, it listens on `127.0.0.1:8214`.

it will use `codex` from `PATH` if available, or `CODEX_CLI_PATH` if you set
it.

run it with `npx`:

```bash
npx --yes github:0xcaff/codex-web
```

or with nix:

```bash
nix run github:0xcaff/codex-web
```

then open <http://127.0.0.1:8214> in a browser.

## docker

build the production image:

```bash
docker build -t codex-web:local .
```

run it with a persistent data volume:

```bash
docker run --rm \
  --name codex-web \
  --publish 127.0.0.1:8080:8080 \
  --volume codex-web-data:/data \
  codex-web:local
```

then open <http://127.0.0.1:8080>.

the image contains:

- the patched codex desktop browser client
- the `codex-web` node bridge
- the codex cli
- the Google Cloud and GitHub CLIs
- Git, Git LFS, Python 3, pip, virtual environments, and native build tools
- common coding and diagnostics tools such as `jq`, `ripgrep`, `fd`, `rsync`,
  `sqlite3`, archive tools, process tools, and network tools
- the OpenSSH client used by codex desktop's remote connection manager
- a non-root `codex` runtime user
- health endpoints at `/__backend/healthz` and `/__backend/readyz`

the build downloads and patches the pinned upstream codex desktop bundle. the
largest renderer bundle requires several gigabytes of memory while prettier
prepares it, so give the docker builder at least 6 GiB.

### multiple remote codex hosts

the bundled codex desktop connection manager supports multiple SSH hosts
natively. it creates a separate app-server connection for each selected host
and reaches it through:

```text
ssh <alias> codex app-server proxy
```

put concrete host aliases in an SSH config. pattern-only hosts such as `Host *`
are not displayed as connections.

```sshconfig
Host devbox
  HostName devbox.example.com
  User codex
  IdentityFile ~/.ssh/devbox
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile ~/.ssh/known_hosts

Host homelab
  HostName homelab.example.com
  User codex
  IdentityFile ~/.ssh/homelab
  IdentitiesOnly yes
  StrictHostKeyChecking yes
  UserKnownHostsFile ~/.ssh/known_hosts
```

place `config`, the identity files, and `known_hosts` in a directory and mount
it read-only at `/run/secrets/codex-ssh`:

```bash
docker run --rm \
  --name codex-web \
  --publish 127.0.0.1:8080:8080 \
  --publish 127.0.0.1:1455:1455 \
  --volume codex-web-data:/data \
  --volume "$PWD/codex-ssh-secrets:/run/secrets/codex-ssh:ro" \
  codex-web:local
```

the entrypoint copies those files into the runtime user's writable `~/.ssh`
directory and sets mode `0600`. this is also compatible with read-only secret
mounts where OpenSSH would otherwise reject a private key because of its mode.
the source mount and files must be readable by the container's non-root runtime
user (UID `10001`); the copied files are private even if a secret provider
exposes the source files as read-only mode `0444`.

each remote machine must:

- accept key-based SSH from the container
- have the standalone Codex install managed by the official installer
- have `codex` available on the remote login shell's `PATH`
- have its own codex authentication and configuration

the remote daemon requires the installer-managed path, so an npm-global Codex
install alone is not sufficient. install Codex on each remote host with:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
codex app-server daemon version
```

in the web app, open **Settings > Connections**, select **Add**, and add any of
the discovered aliases. connected hosts and their remote projects then appear
in the same upstream UI used by codex desktop.

`/data` stores the browser host's connection settings and other Electron
application state. keep it on a persistent volume. codex chats, repositories,
credentials, skills, and tools remain on each selected remote machine.

### sign in from a local docker container

the desktop OAuth flow returns to `http://localhost:1455/auth/callback`. publish
host port `1455` to the same container so the built-in callback bridge can
forward that request to Codex's loopback-only login listener:

```bash
docker run --rm \
  --name codex-web \
  --publish 127.0.0.1:8080:8080 \
  --publish 127.0.0.1:1455:1455 \
  --volume codex-web-data:/data \
  codex-web:local
```

keep the callback port bound to host loopback. `/data/codex` stores the local
Codex authentication cache so login survives container recreation.

### deploy to Google Cloud Run

see [GoogleCloudRun.md](GoogleCloudRun.md) for the complete installation,
security, remote-host, update, and troubleshooting guide.

the deployment helper uses the currently authenticated `gcloud` account and
asks which GCP project to deploy into:

```bash
./scripts/deploy-cloud-run.sh
```

it creates or reuses Artifact Registry, Secret Manager secrets, a dedicated
runtime service account, and a private Cloud Storage bucket. Google Cloud Build
builds the production image natively on `linux/amd64`. the bucket is mounted at
`/data` using Cloud Storage FUSE with UID and GID `10001`, matching the non-root
container user. the Cloud Run service is protected by IAP and is limited to a
single always-allocated instance because the application keeps session and
connection state. that instance accepts multiple concurrent HTTP requests so
the app's long-lived WebSocket does not block its static assets.

Cloud Storage FUSE is not POSIX compliant and does not support file locking.
Codex uses Unix sockets and SQLite, so its runtime home and Electron state use
the Cloud Run instance's local `/tmp` filesystem instead of the bucket. `/data`
remains a persistent user-files mount. The container safely writes immutable
rolling snapshots of durable Codex and Electron state under
`/data/codex-web-state.tar.snapshots/` every 15 seconds and restores the newest
valid snapshot before a replacement instance starts. This includes connection
choices, custom instructions, memory state, app preferences, and interactive
GitHub CLI, gcloud CLI, and global Git configuration. Codex authentication and
SSH configuration are restored separately from Secret Manager.

the script seeds Codex authentication from the local `codex-web` container and
packages the files in `~/.config/codex-web/ssh` into Secret Manager. Cloud Run
only exposes the main HTTP port, so the local OAuth callback bridge is disabled
there. rerunning the helper publishes the current commit, uploads new secret
versions, and deploys a new revision while retaining `/data` in the bucket.

defaults can be overridden without editing the script:

```bash
GCP_REGION=europe-west1 \
CODEX_WEB_BUCKET=my-private-codex-data \
./scripts/deploy-cloud-run.sh
```

the helper uses `gcloud beta run` and `gcloud beta iap` only when the installed
stable commands do not yet expose the required Cloud Storage or Cloud Run IAP
options.

set `CODEX_WEB_BUILD_MODE=local` to use local Docker Buildx instead of the
default Google Cloud Build path. use `CODEX_WEB_BUILD_MODE=skip` only when the
tagged image already exists and only the Cloud Run configuration has changed.

### automated OpenAI updates and Cloud Run deployments

This fork checks OpenAI's desktop appcast and the published `@openai/codex`
package every Monday. When either pinned version changes, GitHub Actions runs
the unit tests and a full Google Cloud Build, then opens a release PR assigned
to the repository owner. Merging that PR into `main` builds a commit-tagged
production image and updates only the existing Cloud Run service image.

The production workflow deliberately leaves the service's GCS volume,
environment, IAP policy, Secret Manager mounts, scaling, and runtime service
account unchanged. See [GoogleCloudRun.md](GoogleCloudRun.md#github-automation)
for notification, authentication, deployment, and rollback details.

### adding permanent command-line utilities

The Cloud Run filesystem is replaced with each revision, and the application
runs as a non-root user. Installing an OS package interactively is therefore
neither durable nor the supported customization path. Add required packages to
the runtime stage in `Dockerfile`, test the image, and merge the change into
`main`; the deployment workflow then rebuilds and deploys the tool permanently.

The included `gcloud` CLI automatically sees the Cloud Run runtime service
account through Application Default Credentials. That identity has only the IAM
roles granted to `codex-web-run`; installing `gcloud` does not grant additional
Google Cloud permissions.

### local multi-host integration test

the repository includes a disposable test environment with one codex-web
container and two SSH-accessible codex hosts:

```bash
npm run test:docker:multihost
```

the test builds the image when needed, generates a temporary SSH key, verifies
that the production container can resolve and connect to both concrete aliases,
and starts a real codex app-server daemon on each host.

the test fixture disables strict host-key checking only inside its disposable
docker network. use pinned `known_hosts` entries for real machines.

### sign in

ensure the codex cli on the host machine is signed in before starting the
server.

```bash
codex login --device-auth
```

### proxying to app-server (advanced usage)

it’s often useful to run the app server separately, so a crash or restart of
codex-web doesn’t interrupt the codex process executing commands.

it's possible to hook codex-web up to an already-running app server using the
`codex_remote_proxy` script.

start a long-lived app server somewhere:

```bash
mkdir -p /tmp/codex-app-server
cd /tmp/codex-app-server
codex app-server --listen unix://codex-app-server.sock
```

then run `codex-web` with the proxy helper:

```bash
nix shell github:0xcaff/codex-web github:0xcaff/codex-web#codex_remote_proxy -c bash -lc '
  export CODEX_UNIX_SOCKET=/tmp/codex-app-server/codex-app-server.sock
  export CODEX_CLI_PATH="$(command -v codex_remote_proxy)"
  codex-web
'
```

`codex app-server proxy --sock ...` is a raw stdio protocol bridge for another
program to use; when run directly in a terminal it will wait for protocol input
rather than opening an interactive prompt.

## security

run `codex-web` only on trusted networks. treat anyone who can reach the
`codex-web` server as someone who can operate codex on the host machine as the
same user running the server.

if you need authn or authz, implement it outside of `codex-web`: proxy it through
wireguard, tailscale, or an ssh tunnel and put an authentication gateway or
reverse proxy in front.

someone with access to the web ui may be able to:

- run commands on the host, limited only by the permissions of the `codex-web`
  server process.
- read or modify files, environment variables, credentials, ssh keys, and other
  local resources that are accessible to that process.
- use the codex / chatgpt account already signed in on the host. this may
  consume usage quota or billing credits, and may expose account metadata shown
  by the app or cli, such as name or email address.

## features

- hostable on macOS, Linux (and anything codex cli + node will run on)
- reachable from the browser
- thin wrapper, so updates should land fast
- working today:
  - subagents
  - inline images
  - editor sidepanel
  - integrated terminal
  - transcription

## roadmap

some parts of the desktop experience are not wired up yet:

- browser panel support, likely rebuilt around iframes
- computer use on linux, which could become a very powerful feature
- git worker integration
- whatever else people find and file issues for

## issues welcome

if something is broken, missing, or rough around the edges, please file an
issue.

using `codex-web` in an interesting way? post about it on x and tag me
[@0xcaff](https://x.com/0xcaff).

using this at a company and need something more tailored? email me and we can
talk.

## alternatives

- [davej/pocodex](https://github.com/davej/pocodex) i used this until the wheels fell off. i needed subagents
  and an inline image viewer. this didn't have them and was having a hard time
  keeping up with upstream codex updates.
- the native codex remote feature (behind a feature flag) is great for
  connecting to remote codex hosts over ssh to manage long running tasks but
  this only works if you have codex desktop on your client device. this means it
  doesn't work on mobile.
- upcoming first party mobile app from openai. `codex-web` exists and works
  today. i can't wait for the mobile app but judging by the other openai mobile
  apps, i'm a little bit skeptical about the quality of the mobile experience.
  time will tell.
