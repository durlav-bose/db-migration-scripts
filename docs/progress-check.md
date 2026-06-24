# Backup Progress Check

While a backup script is running, use these watchers to monitor progress. Run the
backup in **one** terminal and the matching watcher in a **second** terminal.

## How progress works (read this first)

A backup's progress = its output file growing. But *which* file grows live differs
by database and OS:

| Backup | Output file | Grows live? | What to watch |
|--------|-------------|-------------|---------------|
| PostgreSQL — Windows | `backups\*.dump` | ✅ yes | the final `.dump` |
| PostgreSQL — Ubuntu | `backups/*.dump` | ✅ yes | the final `.dump` |
| MySQL — Ubuntu | `backups/*.sql.gz` | ✅ yes (streamed through gzip) | the final `.sql.gz` |
| MySQL — Windows | `backups\*.sql.gz` | ❌ **no** | the **temp** `.tmp` file (see below) |

> **MySQL on Windows:** `mysqldump` writes a temporary uncompressed `.sql` file in
> your `%TEMP%` folder, then compresses it to `.sql.gz` only at the very end. So the
> final `.sql.gz` does not appear until the dump is finished — watch the temp file
> to see live progress. (The uncompressed temp file is also several times larger
> than the final `.gz` will be.)

The file name comes from `PG_BACKUP_NAME` / `MYSQL_BACKUP_NAME` in `.env`. Update
the paths below if you change those names.

---

## PostgreSQL

### Windows (PowerShell)

```powershell
# Terminal 1
cd D:\db-migration-scripts
.\postgresql-scripts\postgres-backup.ps1

# Terminal 2 — watcher (Ctrl+C to stop)
$f = 'D:\db-migration-scripts\backups\tracking-app-backup.dump'
while ($true) {
  if (Test-Path $f) {
    $sz = (Get-Item $f).Length / 1MB
    Write-Host ("{0}  {1,8:N2} MB" -f (Get-Date -Format 'HH:mm:ss'), $sz)
  } else {
    Write-Host ("{0}  waiting for file to appear..." -f (Get-Date -Format 'HH:mm:ss'))
  }
  Start-Sleep -Seconds 2
}
```

### Ubuntu (bash)

```bash
# Terminal 1
cd ~/db-migration-scripts
./postgresql-scripts/postgres-backup.sh

# Terminal 2 — watcher (Ctrl+C to stop)
F=~/db-migration-scripts/backups/tracking-app-backup.dump
while true; do
  if [ -f "$F" ]; then
    printf '%s  %8.2f MB\n' "$(date +%H:%M:%S)" "$(echo "scale=2; $(stat -c%s "$F")/1048576" | bc)"
  else
    printf '%s  waiting for file to appear...\n' "$(date +%H:%M:%S)"
  fi
  sleep 2
done
```

> Simpler alternative on Ubuntu — `watch -n 2 ls -lh backups/tracking-app-backup.dump`.

---

## MySQL

### Windows (PowerShell)

The final `.sql.gz` only appears at the end, so watch the newest growing temp file
in `%TEMP%` during the dump:

```powershell
# Terminal 1
cd D:\db-migration-scripts
.\mysql-scripts\mysql-backup.ps1

# Terminal 2 — watcher (Ctrl+C to stop)
$final = 'D:\db-migration-scripts\backups\mountainy_claim_portal_test_backup.sql.gz'
while ($true) {
  if (Test-Path $final) {
    $sz = (Get-Item $final).Length / 1MB
    Write-Host ("{0}  {1,8:N2} MB  COMPRESSED — done/compressing" -f (Get-Date -Format 'HH:mm:ss'), $sz)
  } else {
    # dump still running -> show the newest temp .tmp file (the uncompressed dump)
    $t = Get-ChildItem $env:TEMP -Filter *.tmp -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($t) {
      Write-Host ("{0}  {1,8:N2} MB  (temp dump in progress)" -f (Get-Date -Format 'HH:mm:ss'), ($t.Length/1MB))
    } else {
      Write-Host ("{0}  waiting for dump to start..." -f (Get-Date -Format 'HH:mm:ss'))
    }
  }
  Start-Sleep -Seconds 2
}
```

> Caveat: the watcher picks the **newest** `.tmp` in `%TEMP%`. If another app
> happens to create a `.tmp` at the same time, the number can jump around. The
> reliable signal is the final `.sql.gz` appearing — that means the dump finished
> and compression is done.

### Ubuntu (bash)

`mysqldump` is piped straight through `gzip`, so the final `.sql.gz` grows live:

```bash
# Terminal 1
cd ~/db-migration-scripts
./mysql-scripts/mysql-backup.sh

# Terminal 2 — watcher (Ctrl+C to stop)
F=~/db-migration-scripts/backups/mountainy_claim_portal_test_backup.sql.gz
while true; do
  if [ -f "$F" ]; then
    printf '%s  %8.2f MB\n' "$(date +%H:%M:%S)" "$(echo "scale=2; $(stat -c%s "$F")/1048576" | bc)"
  else
    printf '%s  waiting for file to appear...\n' "$(date +%H:%M:%S)"
  fi
  sleep 2
done
```

> Simpler alternative — `watch -n 2 ls -lh backups/mountainy_claim_portal_test_backup.sql.gz`.

---

## Verify a finished backup

Once the size stops growing, confirm the backup is valid.

### PostgreSQL (`.dump`)

Lists every schema/table/sequence captured (proves the dump isn't corrupt):

```powershell
# Windows
pg_restore --list "D:\db-migration-scripts\backups\tracking-app-backup.dump"
```
```bash
# Ubuntu
pg_restore --list ~/db-migration-scripts/backups/tracking-app-backup.dump
```

### MySQL (`.sql.gz`)

Test the gzip integrity, and peek at the first lines of SQL:

```powershell
# Windows (PowerShell)
# Integrity test:
& 'C:\Program Files\7-Zip\7z.exe' t "D:\db-migration-scripts\backups\mountainy_claim_portal_test_backup.sql.gz"
```
```bash
# Ubuntu
# Integrity test (no output + exit 0 == good):
gzip -t backups/mountainy_claim_portal_test_backup.sql.gz && echo OK
# Peek inside:
zcat backups/mountainy_claim_portal_test_backup.sql.gz | head -n 40
```

If the integrity test passes, the backup is good. If it errors, the dump is
incomplete or corrupt — re-run the backup.
