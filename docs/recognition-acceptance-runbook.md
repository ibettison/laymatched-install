# Central recognition disposable acceptance runbook

This runbook is for a disposable customer VPS only. It does not use a
production customer, betting data, or production credentials.

The installer main revision for this run is
`a7498984ab65e83f16bf4ed37f843662e036dc3c`. The central application revision
under test is `22ab064d6513ee1bf6c092941bd44052fddfae37`.

## 1. Prepare and install

Take a restorable VPS snapshot before starting. Supply the disposable
installer token and customer password through the approved secret channel.
Do not paste either into a shell transcript, issue, or log.

```bash
git clone https://github.com/ibettison/laymatched-install.git
cd laymatched-install
git checkout a7498984ab65e83f16bf4ed37f843662e036dc3c
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

Expected: service result `success` and Central records a fresh authenticated
heartbeat containing only installation ID, application version and service
status. The service wrapper reports `healthy` only when both customer API and
web container health checks are healthy; otherwise it reports `degraded` or
`unknown`.

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
desired; one invocation must exit with the documented lock-conflict status
and the two runs must not overlap.

## 4. Outage, durable retry and recovery

Use an unused loopback port to simulate Central being unavailable:

```bash
APP_VERSION=$(sudo awk -F= '$1=="APP_VERSION"{print substr($0,index($0,"=")+1)}' /opt/laymatched/.env)
sudo python3 /opt/laymatched/recognition_client.py heartbeat \\
  --state-dir /var/lib/laymatched/activation \\
  --central-url http://127.0.0.1:9 \\
  --app-version "$APP_VERSION" --service-status degraded
sudo stat -c '%a %n' /var/lib/laymatched/activation/heartbeat-outbox.json
```

Expected: exit `75`, a mode-600 outbox remains, and no secret is printed.
Restore the real Central URL by starting the scheduled service:

```bash
sudo systemctl start laymatched-recognition-heartbeat.service
sudo test ! -e /var/lib/laymatched/activation/heartbeat-outbox.json
```

Expected: queued delivery succeeds before any newly-created heartbeat, the
same idempotency key is reused, and the outbox is removed only after success.

## 5. Unknown and stale reporting

The central implementation uses `ACTIVATION_STALE_AFTER_SECONDS`, defaulting
to 900 seconds in `backend/app/config.py` at application revision
`22ab064d6513ee1bf6c092941bd44052fddfae37`.

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
timer for longer than 900 seconds, then query status again; contact must be
`stale`, never healthy. An installation with no received heartbeat is
`unknown`.

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
