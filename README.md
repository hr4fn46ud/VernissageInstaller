# Vernissage Installer

`vernissagectl` is the command-line installer and administration tool for
[Vernissage](https://joinvernissage.org). It installs a complete instance with
Docker and provides the commands needed for routine operation, diagnostics,
updates, and PostgreSQL recovery.

> [!WARNING]
> `vernissagectl` is currently experimental and undergoing active testing. Its
> commands are already complete enough for initial installation and day-to-day
> management of a Vernissage instance, but behavior and configuration formats
> may still change. Keep current off-server backups of all important data.

## Supported platforms

- Ubuntu 24.04 x86_64
- Ubuntu 24.04 ARM64
- macOS 26 ARM64

## Install vernissagectl

```bash
curl -fsSL https://joinvernissage.org/install.sh | sudo sh
```

To install a specific release:

```bash
curl -fsSL https://joinvernissage.org/install.sh | sudo sh -s -- --version X.Y.Z
```

The bootstrap script detects the platform, downloads the matching archive and
`SHA256SUMS` from GitHub Releases, verifies the checksum, and installs the
executable as `/usr/local/bin/vernissagectl`. Linux releases are statically
linked and do not require Swift on the target server.

Verify the installation:

```bash
vernissagectl --version
vernissagectl --help
```

## Command overview

| Command | Purpose |
|---|---|
| `vernissagectl install` | Installs and configures a new Vernissage instance. |
| `vernissagectl cleanup --instance-id <id> [--include-volumes]` | Removes Docker resources left by an incomplete installation. |
| `vernissagectl services` | Shows which services are local, external, and managed by the installer. |
| `vernissagectl status` | Shows the runtime state of installer-managed containers. |
| `vernissagectl doctor [--full]` | Diagnoses configuration, dependencies, routing, and service health. |
| `vernissagectl outdated` | Checks whether newer image digests exist for configured tags. |
| `vernissagectl start <service\|all>` | Starts one managed service or the complete instance. |
| `vernissagectl stop <service\|all>` | Stops one managed service or the complete instance. |
| `vernissagectl restart <service\|all>` | Restarts one managed service or the complete instance. |
| `vernissagectl logs <service> [--follow]` | Displays native Docker logs for a managed service. |
| `vernissagectl update <component\|all>` | Replaces one or all managed components with their currently published images or rebuilt source. |
| `vernissagectl backup [destination]` | Creates a backup of installer-managed PostgreSQL. |
| `vernissagectl restore <backup>` | Restores a compatible PostgreSQL backup. |
| `vernissagectl version` | Prints the installed `vernissagectl` version. |

Use `vernissagectl <command> --help` to display all options accepted by a
specific command.

## Selecting an installation

Commands that manage a successfully installed instance load an existing
`vernissage.yml`. Select it with the shared `--config` option (`-f`):

```bash
vernissagectl --config /srv/vernissage/vernissage.yml status
```

Without an explicit option, configuration is resolved in this order:

1. `--config` or `-f`;
2. the `VERNISSAGE_CONFIG` environment variable;
3. `./vernissage.yml`;
4. `./vernissage/vernissage.yml`.

The loader never searches parent directories and never falls back when an
explicit path is invalid. This prevents a command from accidentally managing a
different instance on a host with multiple installations. The referenced
`vernissage.secrets.yml` is always resolved relative to `vernissage.yml`.
`install`, `cleanup`, and `version` do not load an installation configuration.

## `install`

Start the interactive installer:

```bash
vernissagectl install
```

The installer performs these steps:

1. verifies the Docker CLI, daemon, and Docker Compose plugin;
2. generates an eight-letter instance identifier used to namespace containers,
   volumes, the network, and the locally built Proxy image;
3. collects the permanent instance domain and performs informational DNS and
   local port 80/443 checks;
4. configures an existing PostgreSQL database or creates a local `postgres:18`
   container, then verifies connection and migration permissions in a temporary
   schema;
5. configures an existing Redis service or creates a local persistent Redis
   container, then verifies `PING`, `SET`, `GET`, and `DEL`;
6. configures AWS S3, another S3-compatible service, or local MinIO, then checks
   the bucket and performs a temporary upload, download, comparison, and delete;
   AWS and compatible services can optionally use a custom public image or CDN
   base URL; local MinIO receives an anonymous `GetObject`-only bucket policy
   that is verified with an unsigned download;
7. starts API and Jobs from `mczachurski/vernissage-server:latest`, waits for
   their health endpoints, and verifies the migrated database tables;
8. creates and verifies the permanent administrator through the Vernissage API,
   assigns its role, and blocks the temporary `admin` account;
9. starts Web and Push, configures their internal endpoints, and verifies both;
10. builds the Nginx Proxy, exposes local MinIO read-only at
    `/static-resource/`, stores the public image base URL in Vernissage, then
    restarts API and Jobs and waits for both health endpoints;
11. optionally starts Caddy for development or production HTTPS;
12. writes the installation files immediately after Caddy starts, or after the
    manual public-access configuration is ready;
13. verifies public Web and API routing.

PostgreSQL, Redis, MinIO, API, Jobs, Web, Push, and Proxy remain on a private
Docker network unless external access is explicitly required. The generated
Proxy preserves Vernissage-specific API, ActivityPub, feed, and browser routing.

> [!WARNING]
> The domain is the permanent federated identity of the instance. Changing it
> later can break existing ActivityPub relationships.

### Infrastructure choices

- An existing managed PostgreSQL service with automatic backups, monitoring,
  and tested upgrades is recommended. A local Docker volume survives container
  replacement but is not protection against disk or server failure.
- Both local and external Redis are suitable. Redis does not hold primary
  account or media data, but losing it can discard pending jobs.
- AWS S3 is the most thoroughly tested storage option. Other S3-compatible
  services and local MinIO require their own monitoring, capacity planning,
  updates, and off-server backup strategy.

Local MinIO is built from the pinned
`RELEASE.2025-10-15T17-29-55Z` source release because maintained official
community images are no longer published. Its Docker port is not published on
the host. Public objects are served through Vernissage Proxy as
`https://<domain>/static-resource/<object-key>`, while write operations remain
available only through the private Docker network. The installer grants
anonymous `s3:GetObject` access to bucket objects but does not grant anonymous
bucket listing, upload, modification, or deletion.

For AWS S3 and other S3-compatible services, the optional public image URL is
useful when a CDN or a separate public object-storage hostname serves media.
Leave it empty to keep Vernissage's default URL derived from the configured S3
address and bucket.

### HTTPS choices

- `development` starts Caddy with its internal certificate authority and
  exports `vernissage/caddy/root.crt`. Every client must trust this certificate.
- `production` starts Caddy with automatic Let's Encrypt issuance and renewal.
  The domain must resolve publicly to the server and ports 80 and 443 must be
  reachable from the Internet.
- `manual` leaves certificates and public routing to an external proxy, load
  balancer, or CDN. Proxy is published on the selected host port, defaulting to
  `8080`.

Only one built-in Caddy container can bind ports 80 and 443 on a single server
IP. Multiple instances on the same host should use manually managed HTTPS, a
shared external reverse proxy, separate Proxy ports, or separate server IPs.

### Installation files

After the services and optional Caddy container have been created, the selected
installation directory contains:

- `vernissage/vernissage.yml` — non-secret identity, service, container,
  volume, network, image, path, and public-access configuration;
- `vernissage/vernissage.secrets.yml` — runtime secrets needed to manage and
  recreate services;
- generated Proxy files and, when applicable, Caddy configuration and the
  development root certificate.

Both configuration files are written atomically with mode `0600`. The secrets
file is referenced by relative name and ignored by Git. Keep the files together
for future management commands and store an encrypted copy of the secrets file
in a secure location. Neither file is a backup of PostgreSQL, S3/MinIO, or
Docker volumes. The administrator password and access token are not persisted.
The files remain available if the final HTTPS readiness check times out, so
Caddy can continue obtaining its certificate and the instance can be inspected
with `vernissagectl doctor` without repeating the installation.

### Non-interactive installation

Use `--non-interactive` for CI and provisioning scripts. All applicable
non-secret values must be provided as options; the installer validates the
entire plan before contacting Docker and never falls back to a prompt.

Passwords are not accepted as command-line options or environment variables.
Their only automation input is a mode-`0600` secrets file:

```text
VERNISSAGE_ADMIN_PASSWORD='replace-with-a-strong-password'
VERNISSAGE_POSTGRES_PASSWORD='replace-with-a-strong-password'
VERNISSAGE_REDIS_PASSWORD='replace-with-a-strong-password'
VERNISSAGE_S3_SECRET_ACCESS_KEY='replace-with-the-s3-secret-key'
VERNISSAGE_MINIO_ROOT_PASSWORD='replace-with-a-strong-password'
```

```bash
chmod 600 /run/secrets/vernissage-install.env
```

Unknown or duplicate keys, malformed assignments, insecure permissions, and
empty required values stop the installation. Known secrets that do not apply to
the selected infrastructure mode may remain in a reusable template. A relative
`--secrets-file` path is resolved from the directory in which the command was
started.

Example using existing PostgreSQL and Redis, AWS S3, and production HTTPS:

```bash
vernissagectl install \
  --non-interactive \
  --secrets-file /run/secrets/vernissage-install.env \
  --install-directory /srv/vernissage-one \
  --domain social.example.com \
  --admin-name "Jan Kowalski" \
  --admin-email jan@example.com \
  --admin-username jankowalski \
  --database-mode existing \
  --postgres-host postgres.example.com \
  --postgres-database vernissage \
  --postgres-username vernissage \
  --postgres-tls require \
  --redis-mode existing \
  --redis-host redis.example.com \
  --redis-tls require \
  --storage-mode aws \
  --s3-region eu-central-1 \
  --s3-bucket vernissage-media \
  --s3-access-key-id AKIAEXAMPLE \
  --images-url https://cdn.example.com/vernissage/ \
  --web-csp-image-source https://cdn.example.com \
  --https-mode production
```

Conditional options:

- `--database-mode existing` requires `--postgres-host`,
  `--postgres-database`, and `--postgres-username`; port defaults to `5432` and
  TLS to `require`. Local mode requires only `--postgres-username` and creates
  the `vernissage` database.
- `--redis-mode existing` requires `--redis-host`; username defaults to
  `default`, port to `6379`, and TLS to `require`. Local mode needs no additional
  non-secret values.
- `--storage-mode aws` requires region, bucket, and access key ID. `s3` requires
  address, bucket, and access key ID and optionally accepts
  `--s3-http-version automatic|http1`. Both modes optionally accept
  `--images-url` for a public CDN or media base URL. `minio` requires
  `--minio-root-username`, creates the `vernissage` bucket, and automatically
  uses `https://<domain>/static-resource/`; it does not accept `--images-url`.
- When `--images-url` uses a different origin than the Vernissage domain, pass
  that origin without a path to `--web-csp-image-source` as well.
- `--https-mode` accepts `development`, `production`, or `manual`; manual mode
  optionally accepts `--proxy-port`, defaulting to `8080`.
- `--admin-name`, `--web-csp-image-source`, and `--instance-id` are optional.
  When omitted, the identifier is generated automatically.

Run `vernissagectl install --help` for the complete option list.

If installation stops after creating Docker resources, its error message keeps
the failed container available for diagnostics and prints the relevant
`docker logs` command. It then shows the exact `cleanup` command for the
generated instance identifier and recommends running the original installation
command again after cleanup.

## `cleanup`

```bash
vernissagectl cleanup --instance-id abcdefgh
vernissagectl cleanup --instance-id abcdefgh --include-volumes
```

Removes Docker resources left by an incomplete installation without requiring
a generated `vernissage.yml`. Use the eight-letter identifier printed at the
beginning of `install`. The command inspects only the deterministic container,
volume, network, and Proxy image names belonging to that identifier.

By default, cleanup removes existing Vernissage containers, the private network,
and the locally built, instance-specific Proxy image. It preserves PostgreSQL,
Redis, MinIO, and Caddy volumes and reports their names.

`--include-volumes` also permanently removes those volumes. This is the
recommended way to discard a failed first installation before starting again:

```bash
vernissagectl cleanup --instance-id abcdefgh --include-volumes
vernissagectl install
```

Prefix both commands with `sudo` when the current user cannot access the Docker
daemon directly. Registry-backed images shared with other installations and
files in the selected installation directory are never removed.

## `services`

```bash
vernissagectl services
```

Lists PostgreSQL, Redis, storage, API, Jobs, Web, Push, Proxy, and HTTPS and
classifies each as local or external and installer-managed or unmanaged. The
command reads configuration only; it does not contact Docker. Use `status` for
runtime state.

## `status`

```bash
vernissagectl status
```

Inspects every installer-managed container and displays its name, state,
shortened immutable digest, published ports, and uptime. Configured containers
that do not exist are reported as `missing`. External PostgreSQL, Redis, and S3
services are excluded because the installer does not manage their runtime.

## `doctor`

```bash
vernissagectl doctor
vernissagectl doctor --full
```

Standard mode checks configuration and secrets, generated Proxy and Caddy
files, Docker and its private network, managed containers, PostgreSQL
`SELECT 1`, Redis `PING`, S3 bucket access, API and Jobs health, Web, Push,
Proxy routing, DNS, and managed HTTPS. It does not restart or repair services.

Full mode additionally creates and removes temporary resources to verify
PostgreSQL migration permissions, Redis read/write/delete, and S3
upload/download/delete. It also verifies administrator WebFinger and NodeInfo.
Cleanup is always attempted.

Results use `OK`, `WARN`, `FAIL`, and `SKIP`. Warnings return exit code `0`; any
failure returns exit code `1`, allowing the command to be used by monitoring.

## `outdated`

```bash
vernissagectl outdated
```

Compares the immutable digest used by each managed container with the digest
currently published for the same tag and platform. It reads registry manifests
without pulling layers or restarting containers. API and Jobs share one image
lookup. PostgreSQL remains within its configured major tag, such as
`postgres:18`. Locally built Proxy and MinIO images are reported as local builds.

## `start`

```bash
vernissagectl start api
vernissagectl start all
```

Starts one installer-managed container or the complete instance. With `all`,
infrastructure starts before application services. All selected containers are
verified before any state change begins.

## `stop`

```bash
vernissagectl stop jobs
vernissagectl stop all
```

Stops one installer-managed container or the complete instance. With `all`,
services stop in reverse dependency order. External services are never changed.

## `restart`

```bash
vernissagectl restart web
vernissagectl restart all
```

Restarts one installer-managed container or the complete instance. With `all`,
the dependency-aware order is preserved.

The service selectors accepted by `start`, `stop`, `restart`, and `logs` are:

```text
postgresql (or postgres), redis, minio, api, jobs, web, push,
proxy, https (or caddy)
```

Selecting a dependency configured as external returns an error without changing
Docker state.

## `logs`

```bash
vernissagectl logs api
vernissagectl logs jobs --follow
```

Displays the selected container's native Docker logs. `--follow` streams new
entries without buffering; press Control-C to stop following. This exits only
`vernissagectl` and its Docker log client—it does not stop the service.

## `update`

```bash
vernissagectl update server
vernissagectl update web
vernissagectl update push
vernissagectl update proxy
vernissagectl update caddy
vernissagectl update redis
vernissagectl update postgres
vernissagectl update minio
vernissagectl update all
```

`server` updates API and Jobs together. Registry-backed images are pulled;
Proxy and MinIO are rebuilt locally. Container names, networks, aliases, ports,
environment, restart policy, volumes, and previous running state are preserved.
If the prepared digest is already in use, replacement is skipped.

During replacement the old container is retained under a temporary name. A
startup failure removes the new container and restores the previous one. After
success, the temporary container is removed; old image layers remain available
until Docker cleanup is performed separately.

> [!CAUTION]
> `update` does not create a backup. PostgreSQL stays on its configured major
> tag, but migrations and application changes may still affect data. Create and
> verify appropriate backups before updating production services.

External dependencies and manually managed HTTPS cannot be updated by this
command.

### Updating all managed components

```bash
vernissagectl --config /srv/vernissage/vernissage.yml update all
```

`all` selects only installer-managed components, in this order: PostgreSQL,
Redis, MinIO, Server (API and Jobs together), Web, Push, Proxy, and Caddy.
External PostgreSQL, Redis, S3 storage, and manually managed HTTPS are skipped
and reported. Explicitly selecting an unmanaged component still returns an
error.

All update plans are validated and all selected containers are inspected before
the first image pull, build, or container replacement. Components are then
processed sequentially using the same update behavior as individual commands,
including digest comparison, volume preservation, and preservation of stopped
containers. Configured image tags are retained; `all` does not select newer
major versions or update the `vernissagectl` executable. MinIO is rebuilt from
the installer's pinned source version, rather than selecting the latest source.

The first error stops the batch with a nonzero exit code. The error identifies
the failed component, completed components, and components not yet attempted.
Earlier successful updates remain installed. The existing container rollback
applies only to replacement failures within the current component; there is no
batch-wide rollback or reversal of database migrations.

This is a convenience batch, not an atomic upgrade or a zero-downtime rollout.
As with individual updates, a successful Docker start does not establish service
readiness. Infrastructure replacement can briefly interrupt running application
services. Create and verify appropriate backups before the batch, and check
service health afterwards:

```bash
vernissagectl --config /srv/vernissage/vernissage.yml doctor
```

## `backup`

```bash
vernissagectl backup
vernissagectl backup /secure/off-server/vernissage.backup
```

Creates a versioned PostgreSQL custom-format dump for the local PostgreSQL
container created by the installer. External or managed PostgreSQL services
must use their provider's backup or snapshot system.

Without a destination, the command generates a unique file name under the
`backups` directory next to `vernissage.yml`. Existing files are never
overwritten, and backups are written with mode `0600`.

A backup can contain personal data, password hashes, and access tokens. Move it
to secure off-server storage. It does not include S3/MinIO objects,
configuration files, secrets files, or complete Docker volumes.

## `restore`

```bash
vernissagectl restore /secure/off-server/vernissage.backup
```

Restores PostgreSQL for the local database managed by the installer. Before any
database change, the command verifies the backup format, instance identifier,
domain, database name, PostgreSQL major version, and embedded dump. The operator
must type `RESTORE` to continue.

Restore does not create a pre-restore backup. It first restores into a temporary
database while the current application remains available. API and Jobs are
stopped only for the final database switch, then their health is verified. If
the switch or health check fails, the original database and previous service
state are restored automatically. S3 and MinIO objects are never modified.

## `version`

```bash
vernissagectl version
vernissagectl --version
```

Prints the installed `vernissagectl` version. Both forms are equivalent for
version checks in scripts.

## Build locally

Swift 6.2 or newer is required for development. Static Linux releases use the
matching Swift toolchain and official Static Linux SDK.

The project uses Foundation, Swift Argument Parser, Yams, and Swift Testing.

```bash
swift build
swift test
swift run vernissagectl --help
swift run vernissagectl install --help
```
