# Home Server: Nextcloud and Media Stack

Nextcloud All-in-One and a media stack on Debian, with remote access via Cloudflare Tunnel and automatic offsite backups of Nextcloud to S3.

`setup.sh` is idempotent. It does as much as it can, then writes whatever still needs a person to `NEXT_STEPS.md`. That file is rebuilt on every run, so it only lists what is outstanding.

## Architecture

```
Internet
   │  (HTTPS — TLS terminated by Cloudflare)
   ▼
Cloudflare Edge
   │
cloudflared container (host network, outbound-only)
   │  http://localhost:11000
   ▼
nextcloud-aio-apache  ←── managed by AIO mastercontainer
   │
   ├── nextcloud-aio-nextcloud  (PHP app)
   ├── nextcloud-aio-database   (PostgreSQL)
   ├── nextcloud-aio-redis      (cache)
   ├── nextcloud-aio-cron       (background jobs)
   └── nextcloud-aio-notify-push

Host cron
   └── backup-to-s3.sh → S3 (syncs AIO's Borg backup directory)
```

**`compose.yaml`:** `nextcloud-aio-mastercontainer` and `cloudflared`.  
Everything else on the Nextcloud side (DB, Redis, web server, cron, etc.) is started and managed automatically by the AIO mastercontainer.

**`compose.media.yaml`:** the media stack, as a separate Compose project.

| Service | Purpose | Default port |
|---|---|---|
| Jellyfin | Movies and TV playback | `8091` |
| Audiobookshelf | Audiobooks and ebooks | `13378` |
| Seerr | Movie and TV requests | `5055` |
| ReadMeABook | Audiobook requests | `3030` |
| Sonarr | TV automation | `8098` |
| Radarr | Movie automation | `8088` |
| Prowlarr | Indexer management | `8109` |
| FlareSolverr | Cloudflare challenge proxy for Prowlarr | Docker network only |
| Gluetun | VPN that carries all qBittorrent traffic | None of its own |
| qBittorrent | Downloads | `8133` |
| Decluttarr | Removes failed and stalled downloads | None |

Ports are bound to `MEDIA_BIND_IP` (`127.0.0.1` by default). `cloudflared` uses host networking, so it reaches them at `localhost:<port>`.

### What setup.sh configures for you

| App | Automatic | Left for you |
|---|---|---|
| All apps | Shared login, API keys, directories, ports | |
| Public hostnames | Tunnel routes, DNS and Cloudflare Access, once `MEDIA_DOMAIN` and an API token are set | Providing those values |
| Gluetun | VPN container, public IP check on every run | Choosing a VPN provider and adding its credentials |
| qBittorrent | Login, download paths | |
| Sonarr, Radarr | Login, root folder, qBittorrent client | |
| Prowlarr | Login, Sonarr and Radarr sync, FlareSolverr proxy | Choosing indexers |
| Jellyfin | Admin account, Movies and Shows libraries | |
| Audiobookshelf | Admin account, Audiobooks and Ebooks libraries | |
| Seerr | Jellyfin login and libraries, Sonarr and Radarr | Adjusting the default quality profile if you want to |
| ReadMeABook | Container and shared paths | The setup wizard, which needs your indexer choices |
| Decluttarr | API keys and qBittorrent login, in test mode | Turning off test mode after reviewing its logs |

Each app is configured once and then left alone, so changes you make in its UI are kept. To reconfigure one, delete its marker in `MEDIA_CONFIG_DIR/.setup-state/` and re-run `setup.sh`. If a step fails, setup carries on and adds the manual instructions to `NEXT_STEPS.md`.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Fresh Debian 12 (Bookworm) | Other Debian-based distros should work |
| Root / sudo access | `setup.sh` must run as root |
| A domain managed by Cloudflare | Free plan is fine |
| An S3 bucket | AWS S3, Cloudflare R2, Backblaze B2, etc. |
| Disk space for media | Set `MEDIA_DATA_DIR` to your largest disk. It must be one filesystem so imports can use hardlinks. |

---

## Pre-setup: Cloudflare Tunnel

You must create the tunnel and get a token **before** running `setup.sh`.

1. Log in to [Cloudflare Zero Trust](https://one.cloudflare.com/) → **Networks** → **Tunnels**.
2. Click **Create a tunnel** → choose **Cloudflared** → **Next**.
3. Name it (e.g. `home-nextcloud`) → **Save tunnel**.
4. On the connector page, **copy the token** (a long base64 string).  
   Do not run the install command shown — `setup.sh` handles the container.
5. Click **Next** → **Published applications** → **Add a public hostname**:

   | Field | Value |
   |---|---|
   | Subdomain | `cloud` (or anything you want) |
   | Domain | `yourdomain.com` |
   | Type | `HTTP` |
   | URL | `localhost:11000` |

6. **Save**.
7. **Critical — disable Rocket Loader** for your domain:  
   Cloudflare Dashboard → your domain → **Speed** → **Optimization** → **Content Optimization** → **Rocket Loader → OFF**.  
   Without this, Nextcloud's login page will not render correctly.

---

## Pre-setup: S3 Bucket

AIO uses **BorgBackup** for local backups. This setup syncs those Borg archives to S3 for offsite storage.

### AWS S3

1. Create a bucket (e.g. `my-nextcloud-backups`) in your preferred region.
2. Enable **Versioning** on the bucket.
3. Create an IAM policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"],
    "Resource": [
      "arn:aws:s3:::my-nextcloud-backups",
      "arn:aws:s3:::my-nextcloud-backups/*"
    ]
  }]
}
```

4. Create an IAM user, attach the policy, generate an access key, add to `.env`.

### Cloudflare R2 (free egress, recommended alternative)

```
S3_ENDPOINT_URL=https://<ACCOUNT_ID>.r2.cloudflarestorage.com
S3_REGION=auto
```

### Backblaze B2

```
S3_ENDPOINT_URL=https://s3.<region>.backblazeb2.com
```

---

## Installation

### Step 1 — Copy files to your server

```bash
scp -r ./nextcloud-homeserver user@server:/opt/nextcloud-setup
ssh user@server
cd /opt/nextcloud-setup
```

### Step 2 — (Optional) Pre-fill .env

```bash
cp .env.example .env
nano .env
```

### Step 3 — Run setup

```bash
sudo ./setup.sh
```

The script will:
1. Prompt for any required `.env` values not already set, and generate the media stack's login and API keys.
2. Install Docker CE, Docker Compose plugin, and AWS CLI v2.
3. Create the Nextcloud and media directories on the host.
4. Pull and start `compose.yaml` and `compose.media.yaml`.
5. Register a daily cron job to sync Borg archives to S3.
6. Configure the media apps through their APIs.
7. Print the remaining steps and save them to `NEXT_STEPS.md`.

**Work through `NEXT_STEPS.md`, then re-run `sudo ./setup.sh` to see what is left.** The Nextcloud steps are described in more detail below.

### Step 4 — Complete setup in the AIO interface

The AIO admin interface only listens on the server's localhost. From your own computer, open an SSH tunnel:

```bash
ssh -L 8080:127.0.0.1:8080 user@server
```

Then browse to:

```
https://localhost:8080
```

> Accept the self-signed certificate warning. Never use the domain — HSTS will make the domain inaccessible on port 8080 later.

1. Enter your domain (e.g. `cloud.yourdomain.com`) and click **Submit**.
2. AIO skips domain validation, then starts all containers.
3. Once the status shows green, click **Open your Nextcloud** to complete initial setup.

### Step 5 — Configure Borg backup in AIO

Back in the AIO interface (port 8080):

1. Scroll to the **Backup** section.
2. Set **Backup directory** to the path you configured: `/opt/nextcloud/borg-backup`
3. Set a strong **backup password** — save this somewhere safe, you cannot restore without it.
4. Enable **Daily backup** and choose a backup time (e.g. `03:00`).
5. Click **Create backup** to run the first backup and verify it works.

### Step 6 — Test S3 sync

After the first Borg backup completes:

```bash
sudo ./backup-to-s3.sh
```

---

## Media Stack

### Paths

Every app sees the media tree at the same `/data` path, so there are no remote path mappings to maintain:

```
MEDIA_DATA_DIR/
├── torrents/{incomplete,complete}/
└── media/{movies,tv,audiobooks,books}/
```

### Remote access

Set `MEDIA_DOMAIN` and `CLOUDFLARE_API_TOKEN` in `.env` (the required permissions are listed in `.env.example`) and re-run `setup.sh`. It publishes each app as `<app>.MEDIA_DOMAIN` on your existing tunnel, using the `cf` CLI in a temporary container.

- **Jellyfin, Seerr, Audiobookshelf and ReadMeABook** are published using their own logins.
- **Sonarr, Radarr, Prowlarr and qBittorrent** can control your downloads, so they are only published when `MEDIA_ACCESS_EMAIL` is set. Each gets a Cloudflare Access application that only allows that email, created before the hostname exists.

This is built to leave Nextcloud alone. The step only adds rules for these exact hostnames, never edits an existing route or DNS record, leaves the tunnel alone if it can't read its current routes, and restores the previous config if the routes don't read back as expected. A hostname that already has a different DNS record is skipped and listed in `NEXT_STEPS.md`. Each hostname is published once, so one you remove later stays removed. To publish it again, delete its `hostname-*` marker in `MEDIA_CONFIG_DIR/.setup-state/`. Without an API token, `NEXT_STEPS.md` lists the routes to add by hand.

Check [Cloudflare's terms](https://www.cloudflare.com/service-specific-terms-application-services/) before streaming video through the tunnel, because video proxied through its network has restrictions.

### VPN

All qBittorrent traffic goes through the `gluetun` container, whose firewall blocks anything outside the VPN tunnel, including when the VPN drops. Set `VPN_SERVICE_PROVIDER` and its credentials in `.env`, following the [guide for your provider](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers), then re-run `setup.sh`.

- **No VPN configured:** qBittorrent and Decluttarr don't start. The other apps run normally.
- **On every run:** `setup.sh` compares qBittorrent's public IP with the server's and stops qBittorrent if they match.
- **Port forwarding:** without a forwarded port, downloads still work but you connect to fewer peers and seed less. Router port forwarding has no effect, because peers connect through the VPN. Use `VPN_PORT_FORWARDING=on` with a supported provider.

Only qBittorrent uses the VPN. Everything else, including Nextcloud and the Cloudflare tunnel, stays on your normal connection.

### Reaching the admin UIs

`NEXT_STEPS.md` contains an `ssh -L` command that forwards every app port to your computer. To reach the apps directly from your LAN instead, set `MEDIA_BIND_IP` to the server's LAN address and re-run `setup.sh`. Docker's published ports bypass `ufw`, so this exposes them to everything that can reach that address.

### Updating

Re-running `sudo ./setup.sh` pulls the latest images and recreates any containers that changed.

### Backups

`backup-to-s3.sh` only covers Nextcloud. Media files and app configuration under `MEDIA_CONFIG_DIR` are **not** backed up offsite.

---

## Updating Nextcloud

Updates are managed entirely through the AIO interface at `https://localhost:8080` (via the SSH tunnel from Step 4).

1. Click **Check for updates** in the AIO interface.
2. AIO will create a backup, apply the update, and restart all containers.
3. No manual intervention needed.

---

## Backup & Restore

### Backup flow

```
AIO (daily, configured time)
  └── BorgBackup → /opt/nextcloud/borg-backup/  (local, encrypted, deduplicated)

Host cron (daily at 04:00)
  └── backup-to-s3.sh → s3://BUCKET/PREFIX/  (offsite S3 sync)
```

### Monitor S3 sync logs

```bash
tail -f /var/log/nextcloud-s3-sync.log
```

### Run a manual S3 sync

```bash
sudo ./backup-to-s3.sh
```

### Restore on a new server

1. Install Docker on the new server and copy this repo.
2. Run `sudo ./setup.sh` — it starts the AIO mastercontainer.
3. Open the AIO interface at `https://localhost:8080` (via the SSH tunnel from Step 4).
4. At the initial screen, click **"Restore former AIO instance from backup"**.
5. Enter your **Borg backup password** and the **backup directory path**.
6. AIO will restore everything: database, files, config, apps.

Alternatively, if you need to restore from S3 first:

```bash
# Pull the Borg backup down from S3
aws s3 sync s3://BUCKET/PREFIX/ /opt/nextcloud/borg-backup/

# Then proceed with AIO restore as above
```

---

## Useful Commands

```bash
# View running containers (AIO manages sub-containers; they won't appear in compose ps)
docker ps

# View AIO mastercontainer logs
docker compose logs -f

# View a specific AIO sub-container's logs (example)
docker logs nextcloud-aio-nextcloud
docker logs nextcloud-aio-apache
docker logs nextcloud-aio-database

# Run occ commands
docker exec --user www-data nextcloud-aio-nextcloud php occ [command]

# Restart the stack
docker compose restart

# Stop the stack (does NOT stop AIO sub-containers — stop those from the AIO interface)
docker compose down

# The same commands for the media stack
docker compose -f compose.media.yaml ps
docker compose -f compose.media.yaml logs -f sonarr
docker logs gluetun
docker compose -f compose.media.yaml restart
```

---

## Directory Layout

```
/opt/nextcloud-setup/       ← this repo
├── compose.yaml            ← AIO + cloudflared service definitions
├── compose.media.yaml      ← media stack service definitions
├── setup.sh                ← idempotent setup script
├── configure-media.sh      ← media app configuration, used by setup.sh
├── backup-to-s3.sh         ← S3 sync script
├── .env                    ← your secrets (chmod 600, not in git)
├── .env.example            ← template
├── NEXT_STEPS.md           ← what is left to do (generated, not in git)
└── README.md               ← this file

/opt/nextcloud/
├── data/                   ← Nextcloud user data (NEXTCLOUD_DATADIR)
└── borg-backup/            ← AIO's local Borg archives (BORG_BACKUP_DIR)

/opt/media/
├── config/                 ← app configuration (MEDIA_CONFIG_DIR)
└── data/                   ← media and downloads (MEDIA_DATA_DIR)
```

---

## Security Notes

- **No open inbound ports.** Cloudflare Tunnel uses an outbound-only connection. Your firewall needs no inbound rules for Nextcloud or the media apps.
- **qBittorrent only runs through the VPN.** Peers and trackers see the VPN's IP. A VPN hides your IP but doesn't change what you're allowed to download.
- **`CLOUDFLARE_API_TOKEN` can change your tunnel, DNS and Access apps.** It is stored in `.env`. Once your hostnames are published you can revoke it and blank the value.
- **Media apps are localhost-only by default.** FlareSolverr has no authentication, so it is never published outside the Docker network.
- **AIO admin interface (port 8080) is localhost-only.** It is not routed through Cloudflare Tunnel. Reach it through an SSH tunnel.
- **`.env` is `chmod 600`.** Contains your tokens, keys and the media stack's admin password. Never commit it.
- **Borg backup is encrypted.** Your backup password is the only thing protecting the archives — store it in a password manager.
- **Automatic security updates:**
  ```bash
  apt install unattended-upgrades
  dpkg-reconfigure --priority=low unattended-upgrades
  ```

---

## Troubleshooting

### AIO interface not loading at port 8080
Make sure your SSH tunnel is open (`ssh -L 8080:127.0.0.1:8080 user@server`) and that you're browsing to `https://localhost:8080`, not the domain.

### Domain validation fails
This is expected with Cloudflare Tunnel — that's why `SKIP_DOMAIN_VALIDATION=true` is set. If the AIO interface still shows a validation error, double-check that:
- The Cloudflare Tunnel is in a **Healthy** state (Cloudflare dashboard)
- The ingress rule points to `localhost:11000` (HTTP, not HTTPS)
- Rocket Loader is **disabled** for the domain

### Nextcloud login page is blank or broken
Disable **Rocket Loader** in Cloudflare: Dashboard → your domain → Speed → Optimization → Content Optimization → Rocket Loader → OFF.

### cloudflared container keeps restarting
```bash
docker compose logs cloudflared
```
Verify `CLOUDFLARE_TUNNEL_TOKEN` in `.env` matches the token in the Cloudflare dashboard.

### S3 sync fails with "Access Denied"
Check that your IAM policy includes `s3:ListBucket` on the bucket ARN (not just `/*`).

### A media app was not configured automatically
Run `sudo ./setup.sh` again. Completed steps are skipped and failed ones retried. The reason is in the setup output as a `WARN` line, and the manual alternative is in `NEXT_STEPS.md`.

### AIO sub-containers not starting
Check the AIO interface at port 8080 for error messages. Also:
```bash
docker logs nextcloud-aio-mastercontainer
```
