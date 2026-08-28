# Local activation state contract

This directory is the authoritative persisted-state contract for Slice 2.
`tools/local_activation.py` is the sole writer, transition/recovery owner and
installation-key service. The customer application is a read-only consumer.

`state-v1.schema.json` defines the closed browser-safe record and the fixture is
an installer-valid canonical example. The application pins that fixture and a
cross-repository test rejects byte drift when both repositories are checked out
as siblings. Contract changes must begin here and require explicit compatibility
review before a consumer fixture or reader changes.
