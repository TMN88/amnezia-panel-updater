# Amnezia Web Panel Updater

One-command updater for an existing **Python/venv** installation of [PRVTPRO/Amnezia-Web-Panel](https://github.com/PRVTPRO/Amnezia-Web-Panel).

> This does not install the panel from scratch and does not manage the standalone Linux binary. Use only for a source checkout containing `app.py`, `.git`, and (normally) `venv/`.

## Update command

Run as root on the VPS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/TMN88/amnezia-panel-updater/main/update.sh)
```

Alternative:

```bash
wget -qO- https://raw.githubusercontent.com/TMN88/amnezia-panel-updater/main/update.sh | bash
```

If the checkout is not in `/root/Amnezia-Web-Panel`, specify its path:

```bash
PROJECT_DIR=/opt/Amnezia-Web-Panel bash <(curl -fsSL https://raw.githubusercontent.com/TMN88/amnezia-panel-updater/main/update.sh)
```

## What it does

- Looks for the existing checkout and verifies the Git origin.
- Fetches tags and selects the newest stable `vX.Y.Z` release tag.
- Backs up the project (excluding Git metadata and venv), `data.json`, commit reference, and runtime environment under `/root/Amnezia-Web-Panel-backups/`.
- Installs the release's Python dependencies and runs `pip check` plus `py_compile`.
- Restarts only the Python panel process in the project directory and checks `http://127.0.0.1:5000/login`.
- Attempts to return to the prior commit and relaunch the panel if validation fails.
- Does **not** stop/recreate Docker containers or intentionally modify `data.json`.

## Logs and backups

- Log: `/var/log/amnezia-panel-updater.log`
- Backups: `/root/Amnezia-Web-Panel-backups/panel-backup-<timestamp>/`

## Important limits

- Run on a supported Linux VPS with Bash, Git, Python 3, curl, tar, and the existing virtual environment.
- The script assumes the panel listens on local TCP port 5000 and exposes `/login`. If your installation uses a different port, review the script before use.
- It refuses to update if tracked Git files have local modifications.
- Keep your own off-server backup for critical production data. Test on one VPS before updating the rest.
