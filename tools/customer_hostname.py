#!/usr/bin/env python3
"""Local, non-secret validation for customer nickname/hostname values."""
from __future__ import annotations

import re
import sys
import unicodedata

DOMAIN = "matched.laysports.co.uk"
PROTECTED = {"auth", "registry", "www", "api", "admin", "mail", "support"}
PATTERN = re.compile(r"^[a-z0-9](?:[a-z0-9-]{1,30}[a-z0-9])$")


def normalize(value: str) -> str:
    nickname = unicodedata.normalize("NFKC", value).strip().casefold()
    if not PATTERN.fullmatch(nickname) or nickname in PROTECTED:
        raise ValueError("nickname must be 3-32 lowercase ASCII letters, digits or internal hyphens")
    return nickname


if __name__ == "__main__":
    try:
        print(f"{normalize(sys.argv[1])}.{DOMAIN}")
    except (IndexError, ValueError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
