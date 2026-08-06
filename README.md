# Copilot Migration

Back up and restore GitHub Copilot CLI sessions between Macs.

The scripts preserve session directories and local session indexes without
assuming a particular workspace layout. Optional flags also migrate Copilot
instructions, configuration, skills, skill state, and mailbox data.

## Requirements

- macOS
- Bash 3.2 or newer
- `tar`, `shasum`, and `diff` from macOS
- GitHub Copilot CLI installed on the destination Mac

Authentication is not copied. Sign in to GitHub and Copilot normally on the
destination Mac.

## Create a backup

Close every Copilot CLI session first. The backup command refuses to run while
live session lock files are present.

```bash
git clone https://github.com/dfrysinger/copilot-migration.git
cd copilot-migration

./scripts/backup.sh --output ~/Desktop/copilot-backup
```

The default backup contains:

- `~/.copilot/session-state/`
- `session-store.db` and its sidecars, when present
- `data.db` and its sidecars, when present

Include additional state when needed:

```bash
./scripts/backup.sh \
  --output ~/Desktop/copilot-backup \
  --include-config \
  --include-skills \
  --include-mailbox
```

Use `--copilot-home PATH` if Copilot state is not under `~/.copilot`.

## Transfer and verify

Copy the whole bundle directory to the destination Mac using an encrypted
transport or external drive.

```bash
./scripts/verify.sh ~/Desktop/copilot-backup
```

The bundle contains private conversation history and may contain repository
content, prompts, tool output, or configuration. Do not publish it or place it
in an untrusted cloud location.

## Restore

Close Copilot CLI sessions on the destination Mac, then run:

```bash
./scripts/restore.sh --bundle ~/Desktop/copilot-backup
```

Sessions absent from the destination are added. Identical sessions are skipped.
If the same session ID has different contents, restore stops before changing
anything.

Choose an explicit collision policy when needed:

```bash
# Keep the destination copy.
./scripts/restore.sh \
  --bundle ~/Desktop/copilot-backup \
  --session-conflict keep

# Replace it and preserve the old destination copy in a timestamped backup.
./scripts/restore.sh \
  --bundle ~/Desktop/copilot-backup \
  --session-conflict replace
```

Existing session index databases are kept by default so a destination with new
sessions is not overwritten. On a fresh Mac, the databases are restored
automatically. To replace existing databases:

```bash
./scripts/restore.sh \
  --bundle ~/Desktop/copilot-backup \
  --replace-databases
```

Restore optional bundle sections explicitly:

```bash
./scripts/restore.sh \
  --bundle ~/Desktop/copilot-backup \
  --restore-config \
  --restore-skills \
  --restore-mailbox
```

Any replaced destination data is moved under
`~/.copilot/migration-backup-TIMESTAMP/`.

## What is intentionally excluded

- GitHub and Copilot authentication
- macOS Keychain entries
- installed plugin caches
- logs, crash reports, updater data, and other rebuildable caches
- source repositories and worktrees
- arbitrary files outside the selected Copilot state directory

Commit and push repository work before retiring the source Mac. Re-clone source
repositories on the destination rather than copying build trees.

## Test

```bash
make test
```

The test suite uses temporary fake Copilot homes. It covers backup and restore,
live-session refusal, checksum corruption, collision preflight, and replacement
with destination backup.

