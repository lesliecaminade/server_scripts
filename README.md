# Server Scripts

A collection of automation and maintenance scripts for the homelab server.

## Repository Layout

```
server_scripts/
├── backups/
│   ├── backup_to_backblaze.sh   # Off-site backup to Backblaze B2 via restic
│   ├── backup_to_laptop.sh      # Local-network backup to laptop via SFTP/restic
│   └── daily.sh                 # Wrapper that runs the backup scripts
├── .env.b2                      # Backblaze B2 credentials (gitignored)
└── README.md                    # This file
```

## Backups

Backups are managed with [restic](https://restic.net/).

### Scripts

- `backups/backup_to_backblaze.sh` — backs up selected directories to a Backblaze B2 bucket, then runs `forget --prune` and `check`.
- `backups/backup_to_laptop.sh` — backs up selected directories to a restic repository on a laptop over SFTP, then runs `forget --prune`.
- `backups/daily.sh` — convenience wrapper that can invoke the backup scripts.

### 24-Hour Guard

Both `backup_to_backblaze.sh` and `backups/backup_to_laptop.sh` now track their last successful run in `~/.local/log/backup_to_*.last`. If a script is invoked again within 24 hours of the previous successful run, it exits immediately and logs a skip message.

This prevents overlapping or redundant backups when the scripts are triggered multiple times per day (e.g., by cron, systemd timers, or manual runs).

### Logging

Every script prints timestamped progress to the terminal and appends the same lines to its log in `~/.local/log/` (`daily_backup.log`, `backup_to_backblaze.log`, `backup_to_laptop.log`). Each run reports the repository, the paths being backed up, any restic locks it finds, when each step starts and finishes with its duration, and the step and exit code if something fails. restic's own output is printed to the terminal at its default verbosity but is not written to the log files.

### Credentials

Backblaze B2 credentials are loaded from `backups/.env.b2`, which is gitignored. The file must define the environment variables that restic expects, for example:

```bash
export B2_ACCOUNT_ID=your_account_id
export B2_ACCOUNT_KEY=your_account_key
export RESTIC_PASSWORD=your_restic_password
```

### Retention Policy

Both scripts keep:

- last 10 snapshots
- daily snapshots for the last 10 days
- weekly snapshots for the last 10 weeks
- monthly snapshots for the last 10 months
- yearly snapshots for the last 10 years

## Usage

Run a backup manually:

```bash
./backups/backup_to_backblaze.sh
./backups/backup_to_laptop.sh
```

Or run the daily wrapper:

```bash
./backups/daily.sh
```

## License

This repository is for personal homelab use.
