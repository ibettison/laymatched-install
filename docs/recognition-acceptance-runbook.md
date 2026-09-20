# Central recognition disposable acceptance runbook

This runbook is for a disposable customer VPS only. It does not use a
production customer, betting data, or production credentials.

The installer must be checked out from the current head of PR #29, which
contains the scheduling implementation. The central application revision
under test is `22ab064d6513ee1bf6c092941bd44052fddfae37`.

## 1. Prepare and install

Take a restorable VPS snapshot before starting. Supply the disposable
installer token and customer password through the approved secret channel.
Do not paste either into a shell transcript, issue, or log.

```bash
git clone https://github.com/ibettison/laymatched-install.git
cd laymatched-install
git fetch origin pull/29/head
git checkout --detach FETCH_HEAD
git rev-parse HEAD  # record this as the PR #29 implementation under test
ACTIVATION_SERVICE_URL=https://<central-recognition-base> sudo -E ./install.sh
```

Expected: the normal customer stack is healthy, the activation session exists,
and the installer token is not persisted or sent to Central.

Verify session presence without printing its values:

```bash
sudo python3 - <<'PY'
import json
from pathlib import Path
value = json.loads(Path('/var/lib/laymatched/activation/session.json').read_text())
assert value['activation_id'] and value['access_token'] and value['expires_at']
print('activation session present')
PY
```

Verify the scheduler without exposing configuration:

```bash
systemctl is-enabled laymatched-recognition-heartbeat.timer
systemctl is-active laymatched-recognition-heartbeat.timer
systemctl show laymatched-recognition-heartbeat.timer \\
  --property=NextElapseUSecRealtime,LastTriggerUSec
```

## 2. First automatic heartbeat

The timer starts shortly after boot and then runs every five minutes. For an
immediate disposable check, trigger the service once:

```bash
sudo systemctl start laymatched-recognition-heartbeat.service
sudo systemctl show laymatched-recognition-heartbeat.service \\
  --property=ExecMainStatus,ExecMainCode,Result
sudo journalctl -u laymatched-recognition-heartbeat.service -n 20 --no-pager
```

Expected: `ExecMainStatus=0`, `Result=success`, and Central records a fresh
authenticated heartbeat containing only installation ID, application version
and service status. The service wrapper reports `healthy` only when both
customer API and web container health checks are healthy; otherwise it reports
`degraded` or `unknown`.

## 3. Renewal and non-overlap

On the disposable VPS only, move the local session expiry close to now without
printing the access token:

```bash
sudo python3 - <<'PY'
import json, time
from pathlib import Path
p = Path('/var/lib/laymatched/activation/session.json')
value = json.loads(p.read_text())
value['expires_at'] = int(time.time()) + 1
p.write_text(json.dumps(value, separators=(',', ':')))
PY
sudo systemctl start laymatched-recognition-heartbeat.service
```

Expected: the client resumes the signed activation session, saves a new
expiry, and delivers the heartbeat. Start the service twice concurrently if
desired; one invocation must report lock-conflict exit `76` and the two runs
must not overlap. Lock contention is not treated as a successful delivery.

For a deterministic lock check on the disposable VPS:

```bash
sudo flock -n /run/laymatched-recognition-heartbeat.lock -c 'sleep 15' &
LOCK_HOLDER=$!
sleep 1
sudo systemctl start laymatched-recognition-heartbeat.service || true
wait "$LOCK_HOLDER"
sudo systemctl show laymatched-recognition-heartbeat.service \\
  --property=ExecMainStatus,ExecMainCode,Result
```

Expected: `ExecMainStatus=76`, `Result=exit-code`, with no heartbeat delivery.

## 4. Outage, durable retry and recovery

Use a secure disposable-only backup of the scheduler URL and temporarily point
the scheduler at an unused loopback port to simulate Central being unavailable:

```bash
sudo cp /etc/laymatched/recognition.env /root/recognition.env.acceptance-backup
sudo chmod 600 /root/recognition.env.acceptance-backup
printf 'ACTIVATION_SERVICE_URL=http://127.0.0.1:9\n' | \\
  sudo tee /etc/laymatched/recognition.env >/dev/null
sudo systemctl start laymatched-recognition-heartbeat.service || true
sudo systemctl show laymatched-recognition-heartbeat.service \\
  --property=ExecMainStatus,ExecMainCode,Result
sudo stat -c '%a %n' /var/lib/laymatched/activation/heartbeat-outbox.json
```

Expected: `ExecMainStatus=75`, `Result=exit-code`, a mode-600 outbox remains,
and no secret is printed. Exit `75` means delivery was deferred; it is not a
successful systemd run. Restore the real Central URL and run recovery:

```bash
sudo mv /root/recognition.env.acceptance-backup /etc/laymatched/recognition.env
sudo chmod 600 /etc/laymatched/recognition.env
sudo systemctl start laymatched-recognition-heartbeat.service
sudo test ! -e /var/lib/laymatched/activation/heartbeat-outbox.json
sudo systemctl show laymatched-recognition-heartbeat.service \\
  --property=ExecMainStatus,ExecMainCode,Result
```

Expected: queued delivery succeeds before any newly-created heartbeat, the
same idempotency key is reused, the outbox is removed only after success, and
`ExecMainStatus=0`, `Result=success`.

## 5. Unknown and stale reporting

The central implementation reads `ACTIVATION_STALE_AFTER_SECONDS` and defaults
to 900 seconds in `backend/app/config.py` at application revision
`22ab064d6513ee1bf6c092941bd44052fddfae37`. Verify the effective deployed
value rather than assuming the default:

```bash
sudo docker inspect <central-api-container> \\
  --format '{{range .Config.Env}}{{println .}}{{end}}' | \\
  awk -F= '$1=="ACTIVATION_STALE_AFTER_SECONDS"{print $2}'
```

If the command prints nothing, the application default is 900 seconds. Record
the effective value and wait that duration plus a safety margin.

Send an explicit unknown status and inspect the owner recognition status using
the approved owner access path:

```bash
APP_VERSION=$(sudo awk -F= '$1=="APP_VERSION"{print substr($0,index($0,"=")+1)}' /opt/laymatched/.env)
sudo python3 /opt/laymatched/recognition_client.py heartbeat \\
  --state-dir /var/lib/laymatched/activation \\
  --central-url https://<central-recognition-base> \\
  --app-version "$APP_VERSION" --service-status unknown
# Query the owner installation-recognition status for this installation ID.
```

Expected: service status can be `unknown` while contact is fresh. Stop the
timer for longer than the recorded effective threshold, then query status
again; contact must be `stale`, never healthy. An installation with no
received heartbeat is `unknown`.

## 6. Failure handling and cleanup

On any failure, preserve `/opt/laymatched/.env`, Compose files, activation
state and service logs. Do not regenerate keys, reset MFA, or automatically
rollback a migrated database.

After acceptance, and only on the disposable VPS:

```bash
sudo docker compose -f /opt/laymatched/docker-compose.yml down -v
```

Destroy the disposable VPS/snapshot through the approved process. Do not run
the cleanup command against a customer or production installation.
