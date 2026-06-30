from __future__ import annotations

from typing import Final

DIGEST_PREFIX: Final = "sha256:"
BYTES_PREFIX: Final = ";bytes:"
SHA256_HEX_LEN: Final = 64


def is_digest_summary(value: str) -> bool:
    digest_start = len(DIGEST_PREFIX)
    digest_end = digest_start + SHA256_HEX_LEN
    if len(value) <= digest_end + len(BYTES_PREFIX):
        return False
    if not value.startswith(DIGEST_PREFIX):
        return False
    if value[digest_end : digest_end + len(BYTES_PREFIX)] != BYTES_PREFIX:
        return False
    digest = value[digest_start:digest_end]
    byte_count = value[digest_end + len(BYTES_PREFIX) :]
    return all(char in "0123456789abcdef" for char in digest) and byte_count.isdecimal()
