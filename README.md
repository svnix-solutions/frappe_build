# frappe_build

Container image + Docker Compose stacks for self-hosted Frappe / ERPNext, designed to be deployed via [Komodo](https://komo.do/).

The repo is split into independent Compose stacks so each can run on its own host (or all on one box):

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the Frappe bench image with all apps from `apps.json` baked in. Published to a container registry. |
| `compose.db.yaml` | MariaDB stack. Standalone — can live on its own server. |
| `compose.jfs.yaml` | JuiceFS stack. Provides the host mount that backs Frappe's `sites/` (chunks in object storage, metadata in a dedicated Redis). Must be up before the app stack. |
| `compose.yaml` | Application stack: backend, websocket, workers, scheduler, redis, frontend (nginx). Pulls the image built from the Dockerfile. Bind-mounts `sites/` from the JuiceFS host mount. |

Ingress (TLS + domain routing) is delegated to an external [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy) stack via container labels.

---

## Repo layout

```
.
├── Dockerfile              # Frappe bench image with apps baked in
├── apps.json               # List of apps + branches to include in the build
├── compose.db.yaml         # MariaDB stack
├── compose.jfs.yaml        # JuiceFS stack (object-store-backed sites/ volume)
├── compose.yaml            # App stack (backend, workers, frontend, redis)
├── .env.example            # All env vars consumed by both stacks
└── config/
    ├── mariadb/            # mariadb.cnf mounted into the DB container
    └── nginx/              # nginx template + entrypoint used by the frontend service
```

---

## Apps included

Listed in [`apps.json`](apps.json). Currently:

- **Core ERP**: erpnext, hrms, payments, ecommerce_integrations
- **Tools**: builder, lms, insights, print_designer, frappe_pdf
- **Integrations**: twilio_integration, frappe_whatsapp, email_delivery_service, frappe-cloud-storage
- **UX**: chat, desk-navbar-extended
- **Tenant-specific**: fuelbuddy_dubai

To add or remove apps, edit `apps.json` and rebuild the image. The build pulls these as a base64-encoded `APPS_JSON_BASE64` build arg (see below).

---

## Building the image

The image is built by [Komodo's Build resource](https://komo.do/docs/build), pushed to a registry (Docker Hub or GHCR), then pulled by `compose.yaml`.

### Build args

| Arg | Recommended | Notes |
|---|---|---|
| `PYTHON_VERSION` | `3.11.6` | Frappe v15 supports 3.10–3.12. **Do not use 3.13+.** |
| `DEBIAN_BASE` | `bookworm` | |
| `NODE_VERSION` | `22.17.0` | Required by `frappe/lms@main`. Node 20 fails the build. |
| `WKHTMLTOPDF_VERSION` | `0.12.6.1-3` | |
| `WKHTMLTOPDF_DISTRO` | `bookworm` | |
| `FRAPPE_BRANCH` | `version-15` | |
| `FRAPPE_PATH` | `https://github.com/frappe/frappe` | |
| `APPS_JSON_BASE64` | *(see below)* | base64 of `apps.json` |

### Generating `APPS_JSON_BASE64`

```bash
base64 -i apps.json | tr -d '\n'
```

Paste the single-line output as the build arg value. Without it, the image only contains a vanilla Frappe install (no ERPNext, HRMS, etc.).

If any URL in `apps.json` points to a **private repo**, embed a GitHub Personal Access Token in the URL and pass `APPS_JSON_BASE64` as a **Secret Arg** in Komodo so the token doesn't leak into build logs.

---

## Deploying with Komodo

### 0. One-time prep on the Periphery host

```bash
# Network shared with the caddy stack — must exist before bringing up the app
docker network create caddy
```

### 1. Build Stack

In Komodo: **Builds → + New**, set source = this repo, Dockerfile path = `Dockerfile`, target = `backend`, and the build args above. Push to your registry.

### 2. Database Stack

**Stacks → + New** → `frappe-db`:

- **Source**: this repo, `File Paths=compose.db.yaml`, `Run Directory=.`
- **Environment**:
  ```env
  DB_ROOT_PASSWORD=[[FRAPPE_DB_ROOT_PASSWORD]]   # Komodo secret variable
  INNODB_BUFFER_POOL_SIZE=4G                     # ~60–70% of host RAM
  DB_PUBLISH_BIND=0.0.0.0                        # firewall 3306 from public!
  DB_PUBLISH_PORT=3306
  ```

Deploy. After it starts, allow connections from app containers:

```bash
docker exec -it frappe-db-db-1 mariadb -uroot -p
```
```sql
CREATE USER 'root'@'%' IDENTIFIED BY '<DB_ROOT_PASSWORD>';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
```

### 3. JuiceFS Stack

The app stack bind-mounts `sites/` from a JuiceFS host mount produced by this stack — bring it up **before** `frappe-app`, or the app containers will start against an empty directory and fail loudly.

**Stacks → + New** → `frappe-jfs`:

- **Source**: this repo, `File Paths=compose.jfs.yaml`, `Run Directory=.`
- **Host requirements**: Linux with FUSE available. `privileged: true` + `/dev/fuse` + AppArmor exemption are required for the mount sidecar — won't run on Docker Desktop.
- **Environment**:
  ```env
  JFS_HOST_MOUNT=/mnt/jfs            # also read by frappe-app — keep them in sync
  JFS_NAME=frappe-sites
  JFS_META_PASSWORD=[[FRAPPE_JFS_META_PASSWORD]]
  JFS_CACHE_SIZE=10240               # MB of local read cache

  JFS_STORAGE=s3
  JFS_BUCKET=https://s3.us-east-1.amazonaws.com/your-bucket
  JFS_ACCESS_KEY=[[FRAPPE_JFS_ACCESS_KEY]]
  JFS_SECRET_KEY=[[FRAPPE_JFS_SECRET_KEY]]
  ```

Deploy. On startup:

1. `jfs-meta` (Redis with AOF persistence) starts.
2. `jfs-format` runs `juicefs format` once against the metadata DB + bucket, exits 0. Idempotent — safe on every deploy.
3. `jfs` mounts the FUSE filesystem at `${JFS_HOST_MOUNT}/${JFS_NAME}` and stays running.

> In Komodo, add `jfs-format` to the `frappe-jfs` Stack resource's **`ignore_services`** list. It's a one-shot init container that exits 0 by design; without ignoring it, Komodo marks the whole stack Unhealthy because "containers are in a mix of states."

> **Critical**: the `jfs-meta` Redis is the filesystem index. If you lose its volume, the JuiceFS volume is unrecoverable even though every chunk is still in the bucket. Back up the `jfs-meta-data` volume on its own schedule, separate from the object bucket. Don't reuse the app's `redis-cache` or `redis-queue` for this.

### 4. App Stack

**Stacks → + New** → `frappe-app`:

- **Source**: this repo, `File Paths=compose.yaml`, `Run Directory=.`
- **Image Registry**: same registry where the build was pushed (so Komodo can `docker login` and pull)
- **Environment**:
  ```env
  FRAPPE_IMAGE=docker.io/<your-namespace>/frappe-app:latest
  FRAPPE_SITE_NAME_HEADER=erp.example.com
  PUBLIC_DOMAINS=erp.example.com
  CADDY_NETWORK=caddy

  DB_HOST=host.docker.internal     # same-host DB
  # DB_HOST=10.0.0.5               # multi-host: private IP of DB box
  DB_PORT=3306

  # Must match the JFS stack — these resolve the bind-mount source path.
  JFS_HOST_MOUNT=/mnt/jfs
  JFS_NAME=frappe-sites
  ```

Deploy. On startup:

1. `redis-cache`, `redis-queue` start.
2. `backend`, `websocket`, `scheduler`, queues, `frontend` start.
3. caddy-docker-proxy picks up the `frontend` container's labels and starts routing `PUBLIC_DOMAINS` to it with HTTPS.

> Redis/DB hostnames in `sites/common_site_config.json` are set manually after the first `bench new-site` (see §6). The auto-`configurator` service is shipped commented-out in `compose.yaml` — uncomment it (and the matching `depends_on` block) if you'd rather have it rewrite the config on every deploy.

### 5. Caddy Stack (one per host, shared by all app stacks)

Minimal `compose.caddy.yaml`:

```yaml
name: caddy

services:
  caddy:
    image: lucaslorentz/caddy-docker-proxy:ci-alpine
    restart: unless-stopped
    environment:
      CADDY_INGRESS_NETWORKS: caddy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - caddy-data:/data
      - caddy-config:/config
    networks:
      - caddy

volumes:
  caddy-data:
  caddy-config:

networks:
  caddy:
    name: caddy
    external: true
```

Deploy as a separate Komodo Stack. It needs no env vars.

### 6. Create the ERPNext site (one-time)

The Compose stack starts cleanly but the site doesn't exist yet, and `common_site_config.json` is empty until you write it. Do both manually:

```bash
docker exec -it frappe-backend-1 bash
```

First, point bench at the DB and Redis. These mirror what the (disabled) `configurator` service in `compose.yaml` would otherwise write on every deploy:

```bash
bench set-config  -g  db_host         "$DB_HOST"
bench set-config  -gp db_port         "$DB_PORT"
bench set-config  -g  redis_cache     "redis://redis-cache:6379"
bench set-config  -g  redis_queue     "redis://redis-queue:6379"
bench set-config  -g  redis_socketio  "redis://redis-queue:6379"
bench set-config  -gp socketio_port   9000
```

Then create the site:

```bash
bench new-site erp.example.com \
  --mariadb-user-host-login-scope='%' \
  --db-root-username=root \
  --admin-password='<strong-password>' \
  --db-root-password='<DB_ROOT_PASSWORD>' \
  --install-app erpnext \
  --install-app hrms \
  --install-app payments \
  --install-app builder \
  --install-app lms \
  --install-app insights \
  --install-app print_designer \
  --install-app chat \
  --install-app email_delivery_service \
  --install-app desk_navbar_extended \
  --install-app frappe_whatsapp \
  --install-app ecommerce_integrations \
  --install-app frappe_cloud_storage \
  --install-app frappe_pdf \
  --install-app twilio_integration \
  --install-app fuelbuddy_dubai \
  --set-default
```

- The site name **must match** `FRAPPE_SITE_NAME_HEADER`.
- Takes 5–15 min (migrates schema + builds JS assets for each app).
- DNS for `erp.example.com` must point at the Caddy host before HTTPS works.

---

## Environment variable reference

All variables live in `.env` (or in Komodo's Stack environment block — see [`.env.example`](.env.example) for the full list with comments).

### App stack (`compose.yaml`)

| Variable | Required | Default | Purpose |
|---|:-:|---|---|
| `FRAPPE_IMAGE` | ✅ | `frappe-app:latest` | Image to deploy |
| `FRAPPE_SITE_NAME_HEADER` | ✅ | `erp.example.com` | Site key Frappe routes on |
| `PUBLIC_DOMAINS` | ✅ | — | Domains Caddy serves (space-separated) |
| `CADDY_NETWORK` | | `caddy` | External docker network name |
| `DB_HOST` | ✅ | `host.docker.internal` | DB hostname/IP |
| `DB_PORT` | | `3306` | DB port |
| `JFS_HOST_MOUNT` | | `/mnt/jfs` | Host path where the JFS stack exposes the mount |
| `JFS_NAME` | | `frappe-sites` | JuiceFS volume name (sub-dir under `JFS_HOST_MOUNT`) |

### DB stack (`compose.db.yaml`)

| Variable | Required | Default | Purpose |
|---|:-:|---|---|
| `DB_ROOT_PASSWORD` | ✅ | — | MariaDB root password |
| `INNODB_BUFFER_POOL_SIZE` | | `1G` | InnoDB cache size |
| `DB_PUBLISH_BIND` | | `0.0.0.0` | Interface MariaDB binds on |
| `DB_PUBLISH_PORT` | | `3306` | Host port |

### JuiceFS stack (`compose.jfs.yaml`)

| Variable | Required | Default | Purpose |
|---|:-:|---|---|
| `JFS_HOST_MOUNT` | | `/mnt/jfs` | Host path the FUSE mount propagates to |
| `JFS_NAME` | | `frappe-sites` | JuiceFS volume name |
| `JFS_META_PASSWORD` | ✅ | — | Password for the metadata Redis |
| `JFS_CACHE_SIZE` | | `10240` | Local read cache in MB |
| `JFS_STORAGE` | | `s3` | JuiceFS storage backend type |
| `JFS_BUCKET` | ✅ | — | Full bucket endpoint URL |
| `JFS_ACCESS_KEY` | ✅ | — | Object store access key |
| `JFS_SECRET_KEY` | ✅ | — | Object store secret key |

---

## Migrating an existing `sites` named volume to JuiceFS

If you were previously running with the old named-volume layout, the bind-mount swap won't carry your data over. One-time copy with the app stack stopped:

```bash
docker compose -f compose.yaml down

# Bring JFS up first so /mnt/jfs/frappe-sites exists
docker compose -f compose.jfs.yaml up -d

# Copy the old volume into the JuiceFS mount. Volume name is `<project>_sites`
# — check `docker volume ls` for the exact name.
docker run --rm \
  -v frappe_sites:/from \
  -v /mnt/jfs/frappe-sites:/to \
  alpine cp -a /from/. /to/

docker compose -f compose.yaml up -d
```

Once you've verified everything works, drop the old volume: `docker volume rm frappe_sites`.

---

## Single-host vs multi-host

### Single host (all stacks on one server)
- `DB_HOST=host.docker.internal` (the app container reaches the DB via the host gateway)
- `DB_PUBLISH_BIND=0.0.0.0` is fine **provided the host firewall blocks 3306 from the public internet**

### Multi-host (DB on dedicated server)
- `DB_HOST=10.0.0.5` (private IP — Tailscale, VPC, WireGuard)
- `DB_PUBLISH_BIND=10.0.0.5` (bind only to the private interface, not public)
- Run the DB stack on the DB box and the app stack on the app box. Both can be managed from a single Komodo control plane.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Build fails: `frappe_lms ... node ">=22"` | Node 20 in build arg | Bump `NODE_VERSION` to 22+ |
| Build fails: `Repository not found` mid `bench init` | Private repo in `apps.json` without auth | Embed PAT in the URL, pass `APPS_JSON_BASE64` as Komodo Secret Arg |
| Build OOM-killed during `yarn install` | Builder host < 6 GB RAM | Use a bigger builder or trim apps |
| `websocket` exits with `ECONNREFUSED 127.0.0.1:6379` | `common_site_config.json` missing the Redis URLs | Run the `bench set-config` commands from §6, or enable the commented-out `configurator` service in `compose.yaml` |
| `Access denied for user 'root'@'<ip>'` during `bench new-site` | Only `root@localhost` exists in MariaDB | Run the `CREATE USER 'root'@'%'` block from §2 |
| Hitting Caddy → `no such site` | DNS not pointing at host, or `PUBLIC_DOMAINS` mismatch | Check DNS A record and verify the label was applied: `docker inspect frappe-frontend-1 | jq '.[0].Config.Labels'` |
| Frontend logs Caddy's IP instead of real visitor IP | `UPSTREAM_REAL_IP_ADDRESS` too narrow | Already set to `172.16.0.0/12` in compose; ensure your docker network falls in that range |
| App containers exit immediately, logs show `sites/common_site_config.json` missing | App stack started before JFS mount was ready (empty bind-mount dir) | Bring `frappe-jfs` up first; verify `mountpoint -q /mnt/jfs/frappe-sites` on the host before starting app |
| All app containers show `Input/output error` reading `sites/` mid-run | `jfs` sidecar restarted, FUSE mount dropped | Restart the app stack so the bind-mount picks up the new FUSE handle. Investigate why `jfs` flapped (OOM, image pull, meta DB unreachable) |
| `juicefs format` fails with `access denied` or `NoSuchBucket` | Bucket doesn't exist or keys are wrong | Create the bucket first; verify `JFS_BUCKET` includes the full endpoint URL (not just bucket name) |

### Useful commands

```bash
# Stack overview
docker compose -f compose.yaml ps -a

# Tail all app logs
docker compose -f compose.yaml logs -f --tail=200

# Open a bench shell
docker exec -it frappe-backend-1 bash

# Rebuild JS assets after installing a new app
docker exec -it frappe-backend-1 bench build

# Migrate after a code update / image bump
docker exec -it frappe-backend-1 bench --site all migrate
```
