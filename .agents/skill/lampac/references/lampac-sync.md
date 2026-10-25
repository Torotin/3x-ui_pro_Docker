# Lampac Sync

## Source of Truth

Local master:

```text
docker-proxy/lampac/
```

Server target:

```text
/opt/docker-proxy/lampac/
```

The local repo is authoritative. Do not hand-edit the server copy and then expect local sync to preserve it.

## Sync Script

Use the repo-root script:

```bash
./sync-lampac.sh
```

Useful modes:

```bash
./sync-lampac.sh --dry-run
./sync-lampac.sh --interval 10
CLEAR_SCREEN=0 ./sync-lampac.sh --interval 10
./sync-lampac.sh --no-delete
```

The default source is `/mnt/x/3x-ui_pro_Docker/docker-proxy/lampac/`; the trailing slash is intentional. It syncs the directory contents into the remote target instead of nesting an extra `lampac` directory.

The default rsync includes:

```bash
rsync --archive --compress --human-readable --itemize-changes \
  --out-format="%i %n%L" --delete "$SOURCE_DIR" "$REMOTE_TARGET"
```

`--delete` is intentional because local is master. Use `--no-delete` only for a deliberate one-off preservation case, and explain that remote-only files may remain stale.

## Runtime Inputs

The script accepts CLI flags and environment overrides for:

- `SOURCE_DIR`
- `REMOTE_TARGET`
- `SSH_KEY`
- `SSH_PORT`
- `CLEAR_SCREEN`

Do not bake personal SSH values into skill guidance. Use the current operator-provided access details when they differ from script defaults.

## Interpreting Output

The script uses rsync itemized output:

- `>f.st...... config/init.conf`: file transferred or metadata updated
- `*deleting old-file.js`: remote file removed because local master no longer has it
- `Изменений нет.`: no changed items

Before syncing broad directories outside `docker-proxy/lampac/`, stop and confirm the intended source and delete behavior.
