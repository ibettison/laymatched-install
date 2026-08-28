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
