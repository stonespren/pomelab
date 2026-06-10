# Nextcloud AIO + Cloudflare Tunnel

Nextcloud All-in-One on Debian with remote access via Cloudflare Tunnel (no open inbound ports) and automatic offsite backups to S3.

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

**Two containers you manage:** `nextcloud-aio-mastercontainer` and `cloudflared`.  
Everything else (DB, Redis, web server, cron, etc.) is started and managed automatically by the AIO mastercontainer.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Fresh Debian 12 (Bookworm) | Other Debian-based distros should work |
| Root / sudo access | `setup.sh` must run as root |
| A domain managed by Cloudflare | Free plan is fine |
| An S3 bucket | AWS S3, Cloudflare R2, Backblaze B2, etc. |

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
1. Prompt for any `.env` values not already set.
2. Install Docker CE, Docker Compose plugin, and AWS CLI v2.
3. Create `NEXTCLOUD_DATADIR` and `BORG_BACKUP_DIR` on the host.
4. Pull and start both containers (`nextcloud-aio-mastercontainer` + `cloudflared`).
5. Register a daily cron job to sync Borg archives to S3.

### Step 4 — Complete setup in the AIO interface

Open a browser to the AIO admin interface using your server's **LAN IP address** (not the domain):

```
https://192.168.x.x:8080
```

> Accept the self-signed certificate warning. Always use the IP, never the domain — HSTS will make the domain inaccessible on port 8080 later.

1. Enter your domain (e.g. `cloud.yourdomain.com`) and click **Submit**.
2. AIO validates the domain via Cloudflare Tunnel, then starts all containers.
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

## Updating Nextcloud

Updates are managed entirely through the AIO interface at `https://SERVER_IP:8080`.

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
3. Open the AIO interface (`https://NEW_SERVER_IP:8080`).
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
```

---

## Directory Layout

```
/opt/nextcloud-setup/       ← this repo
├── compose.yaml            ← AIO + cloudflared service definitions
├── setup.sh                ← idempotent setup script
├── backup-to-s3.sh         ← S3 sync script
├── .env                    ← your secrets (chmod 600, not in git)
├── .env.example            ← template
└── README.md               ← this file

/opt/nextcloud/
├── data/                   ← Nextcloud user data (NEXTCLOUD_DATADIR)
└── borg-backup/            ← AIO's local Borg archives (BORG_BACKUP_DIR)
```

---

## Security Notes

- **No open inbound ports.** Cloudflare Tunnel uses an outbound-only connection. Your firewall needs no inbound rules for Nextcloud.
- **AIO admin interface (port 8080) is LAN-only.** It is not routed through Cloudflare Tunnel. Keep it restricted to your LAN.
- **`.env` is `chmod 600`.** Contains your tokens and keys. Never commit it.
- **Borg backup is encrypted.** Your backup password is the only thing protecting the archives — store it in a password manager.
- **Automatic security updates:**
  ```bash
  apt install unattended-upgrades
  dpkg-reconfigure --priority=low unattended-upgrades
  ```

---

## Troubleshooting

### AIO interface not loading at port 8080
Make sure you're using the server's **IP address**, not the domain. Example: `https://192.168.1.100:8080`

### Domain validation fails
This is expected with Cloudflare Tunnel — that's why `SKIP_DOMAIN_VALIDATION=true` is set. If the AIO interface still shows a validation error, double-check that:
- The Cloudflare Tunnel is in a **Healthy** state (Cloudflare dashboard)
- The ingress rule points to `localhost:11000` (HTTP, not HTTPS)
- Rocket Loader is **disabled** for the domain

### Nextcloud login page is blank or broken
Disable **Rocket Loader** in Cloudflare: Dashboard → your domain → Speed → Optimization → Content Optimization → Rocket Loader → OFF.

### cloudflared container keeps restarting
```bash
docker logs nextcloud-aio-cloudflared
# or if using compose:
docker compose logs cloudflared
```
Verify `CLOUDFLARE_TUNNEL_TOKEN` in `.env` matches the token in the Cloudflare dashboard.

### S3 sync fails with "Access Denied"
Check that your IAM policy includes `s3:ListBucket` on the bucket ARN (not just `/*`).

### AIO sub-containers not starting
Check the AIO interface at port 8080 for error messages. Also:
```bash
docker logs nextcloud-aio-mastercontainer
```
