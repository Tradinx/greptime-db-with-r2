# greptimedb-with-r2

GreptimeDB v1.1.3 standalone, backed by Cloudflare R2 object storage, with a
large local read/write cache in front of it.

R2 holds the data (cheap, unlimited, zero egress fees). The local disk holds a
cache so queries do not pay an HTTPS round trip per read.

## Layout

| File | Purpose |
| --- | --- |
| `docker-compose.yml` | Service definition. No secrets. |
| `config.toml` | GreptimeDB config, mounted read-only. No secrets. |
| `.env.example` | Template for credentials. Copy to `.env`. |

## Quick start

```sh
cp .env.example .env
chmod 600 .env
$EDITOR .env          # fill in R2 keys + admin password

docker compose up -d
docker compose logs -f greptimedb
```

Verify:

```sh
curl -fsS http://localhost:4000/health
mysql -h 127.0.0.1 -P 4002 -u admin -p    # password from .env
```

Dashboard: <http://localhost:4000/dashboard>

## Endpoints

| Port | Protocol |
| --- | --- |
| 4000 | HTTP API + dashboard |
| 4001 | gRPC |
| 4002 | MySQL wire protocol |
| 4003 | PostgreSQL wire protocol |

## How secrets work

`config.toml` is committed and contains no credentials. GreptimeDB merges
environment variables over the config file at startup, using the pattern
`GREPTIMEDB_STANDALONE__<SECTION>__<KEY>`:

```
GREPTIMEDB_STANDALONE__STORAGE__ACCESS_KEY_ID
GREPTIMEDB_STANDALONE__STORAGE__SECRET_ACCESS_KEY
```

Compose maps `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` from `.env` onto those.
All three required vars use `${VAR:?...}`, so a missing value fails `up` with a
clear message instead of booting a broken container.

## Sizing

Tuned for **16 vCPU / 32 GB RAM / 320 GB local disk**.

Disk (`/data`, the `greptime-data` named volume):

| Item | Size |
| --- | --- |
| read cache | 150 GiB |
| write cache | 20 GiB |
| WAL + metadata + index | ~20 GiB |
| **total** | **~190 GiB of 320 GB** |

> The named volume lives under `/var/lib/docker/volumes`, i.e. the 320 GB local
> disk. If you instead bind-mount the 40 GB block volume to `/data`, drop
> `cache_capacity` to ~20GiB or it will fill the disk.

Memory: ~12.75 GiB steady state across page/content/vector caches and write
buffers, container capped at 26 GB via `mem_limit`. Tune `page_cache_size`
first if the workload is read-heavy.

## R2 is not a backup — read this before touching the volume

The `greptime-data` volume is **not** just cache, even though ~99% of its bytes
are:

| Path | Contents | If lost |
| --- | --- | --- |
| `home/wal/*.raftlog` | **WAL + table catalog / region metadata** (~70 MB) | 🔴 R2 data becomes unreadable |
| `home/index/` | index staging | regenerates |
| `write_cache/` | cached SSTs (GBs) | regenerates from R2 |
| `read_cache/` | read cache (GBs) | regenerates from R2 |

R2 stores SST files keyed by table and region ID. The mapping from a table
*name* to those IDs exists only in the local raft-engine WAL. Start GreptimeDB
against a full R2 bucket with an empty volume and you get **zero tables** — the
data is intact and unaddressable.

This is not theoretical. On 2026-07-22 a redeploy under a new Dokploy project
slug created a fresh empty volume; the database came up with no tables while
every byte remained in R2. Recovery was copying `home/` back from the old
volume.

Two defences, both already in this repo:

1. The volume name is **pinned** (`name: greptime-data`), so a project rename
   cannot silently swap in an empty volume.
2. `scripts/backup-metadata.sh` archives `home/` (~70 MB). Run it on a cron:

   ```sh
   0 */6 * * * /path/to/scripts/backup-metadata.sh /root/greptime-backups
   ```

Restoring metadata into a volume:

```sh
docker compose stop greptimedb
docker run --rm -v greptime-data:/data -v /root/greptime-backups:/b:ro \
  alpine sh -c 'rm -rf /data/home && tar xzf /b/greptime-home-YYYYMMDD-HHMMSS.tar.gz -C /data'
docker compose start greptimedb
```

## Notable gotchas

- **Prefer `--grpc-bind-addr`.** It is the only gRPC flag `standalone start
  --help` lists in v1.1.3. `--rpc-bind-addr` still works as an undocumented
  alias, so existing configs using it are not broken — but an alias that is
  already absent from `--help` is a reasonable candidate for removal, so use
  the documented name.
- **Config is a mounted file, not a heredoc.** Generating the TOML inside a
  shell heredoc in `command:` stacks three escaping layers (compose
  interpolation → `sh` → TOML); one stray backslash yields
  `invalid escape character in string`. A mounted file has zero escaping layers.
- **`timeout = "120s"` / `connect_timeout = "10s"`** in `[storage.http_client]`.
  60s/5s was killing healthy-but-slow R2 downloads and surfacing as
  `reqwest::Error`.
- **Image is pinned.** Config keys and CLI flags change between releases; never
  use `:latest` here.

## Operations

```sh
docker compose ps                       # health status
docker compose restart greptimedb
docker compose down                     # stop, keep data
docker compose down -v                  # stop and DESTROY the local volume
```

`down -v` deletes the local cache and the WAL, not the data in R2. Any writes
not yet flushed to R2 are lost.

Upgrading: bump the image tag, read that release's changelog for renamed config
keys, then `docker compose up -d`.
