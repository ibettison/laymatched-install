# Local activation state and installation identity

Slice 2 adds a root-only command service at `tools/local_activation.py`. It
initializes and advances `/var/lib/laymatched/activation`, creates an Ed25519
installation key, prints browser-safe status, and can sign the later canonical
central requests without exporting the private key.

The directory is mode `0700`, journals and the private key are `0600`, and the
public key is `0644`. Journal replacement is atomic and fsynced; the preceding
complete revision supports crash recovery. Initialization and same-stage
updates are idempotent, and persisted progress resumes after reboot.

The schema contains only installation ID, stage, revision, timestamp and a
provider-neutral error. Credential, token, password, private-key, MFA and
recovery material is rejected from serialization. No central, DNS, ACME, MFA,
first-run UI, deployment or infrastructure behaviour is included.

## Authority and consumer boundary

The installer is the only writer, state-machine/recovery owner and Ed25519 key
service. `contracts/local-activation/state-v1.schema.json` and its fixture are
authoritative. The customer application contains only a read-only decoder and
browser-safe projection. Its pinned fixture must remain byte-identical; the
cross-repository compatibility test proves that the application reader accepts
the installer contract without gaining write or signing capability.

Customer Compose mounts only the journal file read-only. The activation
directory and Ed25519 private/public key files are not visible inside the
customer API container.
