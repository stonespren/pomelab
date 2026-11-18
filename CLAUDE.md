# Project notes

This repository is **public**, and servers are set up by pulling it from GitHub. Keep that in mind for every change:

- Never commit secrets, real domains, bucket names, server IPs or other details that identify a specific deployment. Real values belong in `.env`, which is not tracked. Use placeholders everywhere else.
- Git history is public too, so a secret that gets committed must be revoked. Removing it in a later commit is not enough.
- `setup.sh` and everything in `scripts/` (the `configure-*.sh` files and `media/*.sh` it sources, `backup-to-s3.sh` and `prepare-existing-server.sh`) run as root, so review any outside contribution carefully before merging.
- Changes should work on any new server, not just one existing deployment.
