# Home Server: Nextcloud and Media Stack

Nextcloud All-in-One and a media stack on Debian, published through a Cloudflare Tunnel, with daily offsite backups of Nextcloud to S3-compatible storage.

You fill in a few values in `.env` and run `sudo ./setup.sh`. It installs everything, creates the Cloudflare tunnel, DNS records and Access apps, starts the containers, configures the media apps through their APIs and schedules backups. Anything that needs a person is written to `NEXT_STEPS.md`.

`setup.sh` is safe to re-run at any time. Each run brings the server and Cloudflare back in line with `.env`, pulls newer images, and rebuilds `NEXT_STEPS.md` so it only lists what is still outstanding.

## What you get

```
Internet ──HTTPS──▶ Cloudflare edge (TLS, Access)
                        │
              cloudflared (host network, outbound-only: no open ports)
                        │
        ┌───────────────┴──────────────────────────────┐
        ▼                                              ▼
localhost:11000                                localhost:<app port>
Nextcloud AIO                                  media apps
(AIO's mastercontainer runs Apache,            (one Compose project
 PHP, PostgreSQL, Redis, cron, backups)         with Nextcloud)

systemd timer (04:00) ── backup-to-s3.sh ──▶ S3 (copy of AIO's Borg backups)
```

| App | Address | Purpose |
|---|---|---|
| Nextcloud | `cloud.DOMAIN` | Files, calendar, contacts |
| Jellyfin | `jellyfin.DOMAIN` | Movies and TV |
| Seerr | `seerr.DOMAIN` | Movie and TV requests |
| Audiobookshelf | `audiobookshelf.DOMAIN` | Audiobooks and ebooks |
| ReadMeABook | `readmeabook.DOMAIN` | Audiobook requests |
| Sonarr | `sonarr.DOMAIN` (behind Access) | TV automation |
| Radarr | `radarr.DOMAIN` (behind Access) | Movie automation |
| Prowlarr | `prowlarr.DOMAIN` (behind Access) | Indexers |
| qBittorrent | `qbittorrent.DOMAIN` (behind Access) | Downloads, only through the VPN |
| AIO interface | `https://localhost:8080` over SSH only | Nextcloud admin, updates, backups |

FlareSolverr (Cloudflare challenge proxy for Prowlarr), Gluetun (the VPN) and Decluttarr (removes failed and stalled downloads) run without addresses of their own.

### What setup.sh does for you

| | Automatic | Left for you |
|---|---|---|
| Cloudflare | Tunnel, routes, DNS records, an Access app per admin app | |
| Nextcloud | Container, data and backup directories, daily offsite copy | Entering the domain and turning on backups in the AIO interface |
| Gluetun | VPN container, a public IP check on every run | Choosing a VPN provider |
| qBittorrent | Login, download paths | |
| Sonarr, Radarr | Login, root folder, qBittorrent client | |
| Prowlarr | Login, Sonarr and Radarr sync, FlareSolverr proxy | Choosing indexers |
| Jellyfin | Admin account, Movies and Shows libraries | |
| Audiobookshelf | Admin account, Audiobooks and Ebooks libraries | |
| Seerr | Jellyfin login and libraries, Sonarr and Radarr | Adjusting the default quality profile if you want to |
| ReadMeABook | Container and shared paths | Its setup wizard, which needs your indexer choices |
| Decluttarr | API keys and qBittorrent login, in test mode | Turning off test mode after reviewing its logs |
| Debian | Docker, automatic security updates | |

Each media app is configured once and then left alone, so changes you make in its UI are kept. To reconfigure one, delete its marker in `MEDIA_CONFIG_DIR/.setup-state/` and re-run `setup.sh`. If a step fails, setup carries on and adds the manual instructions to `NEXT_STEPS.md`.

---

## Before you start

You need:

| | Notes |
|---|---|
| A Debian 12 server with root access | Other Debian-based distros should work |
| A domain on Cloudflare | The free plan is fine |
| A Cloudflare Zero Trust organization | Free for up to 50 users. Open [one.cloudflare.com](https://one.cloudflare.com/) once and pick a team name. Access apps can't be created until this exists. |
| An S3-compatible bucket | AWS S3, Cloudflare R2, Backblaze B2 and so on |
| Disk space for media | `MEDIA_DATA_DIR` must be one filesystem, so imports can use hardlinks |
| A VPN subscription (optional) | Needed before qBittorrent will run. See [VPN](#vpn). |

### Cloudflare API token

In the Cloudflare dashboard go to **My Profile → API Tokens → Create Token → Custom token**, and give it:

| Scope | Permission |
|---|---|
| Account | Cloudflare Tunnel: Edit |
| Account | Access: Apps and Policies: Edit |
| Zone | Zone: Read |
| Zone | DNS: Edit |

Limit it to your account and your domain's zone. It stays in `.env` because every run of `setup.sh` checks the tunnel, DNS and Access against it.

### S3 bucket

The access key needs to read, write, delete and list objects in the bucket. Turn on versioning (or object lock) if your provider has it, so a bad sync can be undone.

**AWS S3:** create the bucket, then an IAM user with this policy, and use its access key. Leave `S3_ENDPOINT_URL` blank.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"],
    "Resource": ["arn:aws:s3:::BUCKET", "arn:aws:s3:::BUCKET/*"]
  }]
}
```

**Cloudflare R2:** create an R2 API token with Object Read & Write on the bucket. `S3_REGION=auto`, `S3_ENDPOINT_URL=https://<account-id>.r2.cloudflarestorage.com`.

**Backblaze B2:** create an application key for the bucket. `S3_REGION` is the region in the bucket's endpoint, `S3_ENDPOINT_URL=https://s3.<region>.backblazeb2.com`.

---

## Installation

```bash
sudo git clone https://github.com/<you>/<this-repo>.git /opt/pomelab
cd /opt/pomelab
sudo cp .env.example .env
sudo nano .env          # fill in the "Required" section, and the VPN if you have one
sudo ./setup.sh
```

Then work through `NEXT_STEPS.md` and re-run `sudo ./setup.sh` to see what is left. The Nextcloud part is:

1. **Enter the domain.** The AIO interface only listens on the server. From your computer, run `ssh -L 8080:127.0.0.1:8080 you@server`, browse to `https://localhost:8080` and accept the certificate warning. Never open it through the domain: HSTS would lock you out of port 8080 later. Enter `cloud.DOMAIN`. AIO skips its domain check (the tunnel blocks it) and starts Nextcloud.
2. **Turn on backups.** In the same interface, set the backup directory to `BORG_BACKUP_DIR` (`/opt/nextcloud/borg-backup` by default), save the backup password in a password manager, schedule daily backups for 03:00 and create the first one.
3. **Test the offsite copy:** `sudo systemctl start nextcloud-offsite-backup`, then `journalctl -u nextcloud-offsite-backup` should end with `Sync complete`.

---

## Cloudflare

`setup.sh` creates a tunnel named `TUNNEL_NAME` (the server's hostname by default) and on every run makes sure that:

- the tunnel's token is in `.env` for the `cloudflared` container;
- each app's route is in the tunnel's config, followed by a catch-all 404. Routes for other hostnames, such as ones you add in the dashboard, are kept;
- Sonarr, Radarr, Prowlarr and qBittorrent each have a Cloudflare Access app allowing only `ACCESS_EMAIL`, created before their hostname is published. An existing app is left as it is, so changes you make to it in the dashboard are kept;
- each hostname has a proxied CNAME to the tunnel. A hostname that already has a different DNS record is never overwritten: it is skipped and listed in `NEXT_STEPS.md`.

Nextcloud is not behind Access because its desktop and mobile clients can't sign in through it. Jellyfin, Seerr, Audiobookshelf and ReadMeABook use their own logins so their apps keep working too.

The `cf` CLI runs in a temporary `node` container, so the server doesn't need Node installed.

Check [Cloudflare's terms](https://www.cloudflare.com/service-specific-terms-application-services/) before streaming a lot of video through the tunnel. To keep Jellyfin traffic at home off Cloudflare, see [LAN access](#lan-access).

---

## Media stack

### Paths

Every app sees the media tree at the same `/data` path, so there are no remote path mappings to maintain:

```
MEDIA_DATA_DIR/
├── torrents/{incomplete,complete}/
└── media/{movies,tv,audiobooks,books}/
```

### VPN

All qBittorrent traffic goes through the `gluetun` container, whose firewall blocks anything outside the VPN, including when the VPN drops. Set `VPN_SERVICE_PROVIDER` and its credentials in `.env`, following the [guide for your provider](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers), then re-run `setup.sh`.

- **No VPN configured:** qBittorrent and Decluttarr don't start. Everything else runs normally.
- **On every run:** `setup.sh` compares qBittorrent's public IP with the server's and stops qBittorrent if they match.
- **Port forwarding:** without a forwarded port, downloads still work but you reach fewer peers and seed less. Router port forwarding has no effect, because peers connect through the VPN. Use `VPN_PORT_FORWARDING=on` with a provider that supports it.

Only qBittorrent uses the VPN. Nextcloud, the tunnel and the other apps use your normal connection.

### LAN access

The app ports listen on `127.0.0.1` by default. To reach them directly from home, for example so a TV streams from Jellyfin without going through Cloudflare, set `MEDIA_BIND_IP` to the server's LAN address and re-run `setup.sh`. Docker's published ports bypass `ufw`, so this exposes every app port to anything that can reach that address.

| App | Port |
|---|---|
| Jellyfin | 8096 |
| Seerr | 5055 |
| Audiobookshelf | 13378 |
| ReadMeABook | 3030 |
| Sonarr | 8989 |
| Radarr | 7878 |
| Prowlarr | 9696 |
| qBittorrent | 8090 |

---

## Updating

- **Media apps and cloudflared:** re-run `sudo ./setup.sh`. It pulls the latest images and recreates containers that changed.
- **Nextcloud:** in the AIO interface, click **Check for updates**. AIO backs up, updates and restarts its containers.
- **Debian:** security updates install automatically.

---

## Backup and restore

```
AIO, daily at the time you choose (03:00 suggested)
  └── BorgBackup → BORG_BACKUP_DIR  (local, encrypted, deduplicated)

systemd timer nextcloud-offsite-backup, daily at 04:00
  └── backup-to-s3.sh → s3://S3_BUCKET/S3_PREFIX/  (rclone mirror)
```

`backup-to-s3.sh` waits for a running AIO backup to finish, and refuses to mirror a directory that doesn't hold a Borg repository, so a wrong path can't wipe the offsite copy. Logs are in `journalctl -u nextcloud-offsite-backup`.

Only Nextcloud is backed up offsite. Media files and `MEDIA_CONFIG_DIR` are not.

### Restore on a new server

1. Clone this repo, copy your old `.env` (or fill in a new one with the same S3 values), and run `sudo ./setup.sh`.
2. `sudo ./backup-to-s3.sh restore` copies the archives from S3 into `BORG_BACKUP_DIR`.
3. Open the AIO interface over SSH, choose **Restore former AIO instance from backup**, and enter the backup directory and the Borg password.

---

## Useful commands

Run these from the repo directory.

```bash
sudo docker compose ps                     # this repo's containers
sudo docker ps                             # including AIO's own containers
sudo docker compose logs -f sonarr         # one app's logs
sudo docker logs nextcloud-aio-nextcloud   # an AIO container's logs
sudo docker exec --user www-data nextcloud-aio-nextcloud php occ <command>
sudo docker compose restart jellyfin
systemctl list-timers nextcloud-offsite-backup
```

AIO starts its own containers (`nextcloud-aio-*`), which `docker compose` doesn't list or stop. Stop those from the AIO interface.

---

## Files

```
/opt/pomelab/                ← this repo
├── compose.yaml             ← every container
├── setup.sh                 ← installs and reconciles everything
├── configure-cloudflare.sh  ← tunnel, routes, DNS and Access (used by setup.sh)
├── configure-media.sh       ← media app configuration (used by setup.sh)
├── backup-to-s3.sh          ← offsite copy and restore of Nextcloud's backups
├── .env                     ← your settings and secrets (chmod 600, not in git)
├── .env.example             ← template
└── NEXT_STEPS.md            ← what is left to do (generated, not in git)

/opt/nextcloud/{data,borg-backup}/   ← NEXTCLOUD_DATADIR, BORG_BACKUP_DIR
/opt/media/{config,data}/            ← MEDIA_CONFIG_DIR, MEDIA_DATA_DIR
```

---

## Security notes

- **No inbound ports.** The tunnel connects outward, so the firewall needs no rules for any app. Only SSH has to be reachable.
- **Admin apps are behind Cloudflare Access** as well as their own logins. FlareSolverr has no login, so it is never published outside the Docker network.
- **The AIO interface is SSH-only.** It is bound to `127.0.0.1` and has no route through the tunnel.
- **qBittorrent only runs through the VPN.** A VPN hides your IP but doesn't change what you're allowed to download.
- **`.env` holds every secret** (Cloudflare and S3 keys, the media admin password) and is `chmod 600`. Never commit it. The Cloudflare token can change your tunnel, DNS and Access apps, so keep it limited to this account and zone.
- **The Borg password is the only key to your backups.** Keep it in a password manager, not on the server alone.

---

## Troubleshooting

**Nextcloud's login page is blank or broken.** Turn off Rocket Loader: Cloudflare dashboard → your domain → Speed → Optimization → Content Optimization → Rocket Loader. It is off by default on new zones.

**Large uploads to Nextcloud fail.** Cloudflare limits a single request to 100 MB on the free plan. The Nextcloud desktop and web clients upload in chunks below that. Other clients may not.

**The AIO interface doesn't load.** Check your SSH tunnel (`ssh -L 8080:127.0.0.1:8080 you@server`) and that you are browsing to `https://localhost:8080`, not the domain.

**An app's address shows a Cloudflare error.** Check `sudo docker compose logs cloudflared` and that the tunnel is Healthy under Zero Trust → Networks → Tunnels. Then re-run `sudo ./setup.sh`, which repairs routes and DNS and lists anything it couldn't fix.

**A media app wasn't configured automatically.** Re-run `sudo ./setup.sh`. Completed steps are skipped and failed ones retried. The reason is in the output as a `WARN` line, and the manual alternative is in `NEXT_STEPS.md`.

**The offsite copy fails.** `journalctl -u nextcloud-offsite-backup` shows rclone's error. "Access Denied" usually means the key can't list the bucket.
