# Customer DNS and HTTPS acceptance (disposable VPS)

This runbook is for a new Ubuntu 24.04 test VPS only. It uses no production
Cloudflare credential on the VPS and must not be run against an existing
customer installation without separate approval.

## Preconditions

The central Auth API response must include `activation_url`, the central
service must have `DNS_PROVISIONING_ENABLED=true`, and the central runtime
must have its restricted `CLOUDFLARE_DNS_API_TOKEN` and pinned
`CLOUDFLARE_ZONE_ID`. The token is never copied to the VPS.

## Install

Run the normal installer with the issued short-lived installer token. Choose a
unique nickname when prompted. The installer then:

1. registers the installation using the existing signed activation contract;
2. reserves `<nickname>.matched.laysports.co.uk` and waits for central DNS
   readiness after the VPS answers the central public-IP challenge;
3. renders Nginx for the customer app on port 80;
4. obtains the certificate locally with Certbot HTTP-01; and
5. serves the central HTTPS proof challenge and reports certificate metadata;
6. replaces the HTTP server with an HTTP-to-HTTPS redirect and HTTPS proxy.

Set `LAYMATCHED_ACME_MODE=mock` only for local configuration tests. Real
acceptance requires ports 80 and 443 reachable on the new VPS and the hostname
resolving to that VPS IPv4 address.

The updater installs the hostname, HTTPS and recognition helpers as one
validated bundle. Existing installations that predate those sidecar files use
the updater's embedded fallback bundle; it does not overwrite the stored
hostname, certificates, credentials or application data. Certbot's deploy hook
reloads Nginx and refreshes central HTTPS metadata after renewal.

## Checks

```text
hostname=<nickname>.matched.laysports.co.uk
curl -I "http://$hostname/"                 # 301 to HTTPS after issuance
curl -fsS "https://$hostname/health"         # application health
systemctl status nginx --no-pager
systemctl status laymatched-recognition-heartbeat.timer --no-pager
docker compose -f /opt/laymatched/docker-compose.yml ps
```

Confirm that `/` presents the private customer login, not the marketing site;
the customer login and MFA enrolment are exercised only after the released
customer image containing those features has been independently verified. The
central activation status must show DNS `ready`, HTTPS `verified`, and no
provider error before the run is accepted.

To verify the concurrency contract during a disposable test, repeat a network
or reservation-renewal request with its old `ETag`/`If-Match` value and confirm
that central returns `409`, then fetch activation status and retry with the new
ETag. The network response must include `status`, `last_error` and
`retry_after`.

## Failure and cleanup

If nickname reservation reports `dns_failed`, inspect central activation status
and retry; do not create a manual Cloudflare record. If HTTP-01 or Nginx setup
fails, retain `/var/lib/laymatched/activation`, `/etc/letsencrypt`, and the
installer logs for diagnosis. Do not delete Docker volumes or reset customer
credentials. A disposable VPS can be terminated only after the evidence has
been captured and the central hostname reservation has been released by the
approved operator procedure.
