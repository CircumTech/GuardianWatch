"""
Generates the human-typeable unique ID printed on each physical device
(e.g. on a sticker under the strap) — what the "look up your device" page
on the company site and the on-device pairing flow both key off.

Format: GW-XXXX-XXXX.

Alphabet: 31 characters — digits 2-9 plus A-Z minus the visually
ambiguous I, L, O. Someone transcribing a small label should not have to
guess between 0 and O, 1 and I and L.

ENTROPY

  31^8 ≈ 8.5 × 10¹¹ combinations.

  Birthday-paradox collision risk at common provisioning scales:
    •  100 000 devices →  ~0.6 % probability that at least one
                          collision has occurred in the set.
    •  500 000 devices →  ~14 %.
    •  1 000 000 devices → ~44 %.

  `generate_unique_device_id` below verifies uniqueness against the DB
  and is the correct call for any provisioning run that will exceed
  ~100 000 units. The plain `generate_device_id` is used only as the
  SQLAlchemy column default — a fallback that assumes the caller has
  already validated uniqueness.
"""
import secrets
from collections.abc import Awaitable, Callable

_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"  # no 0/O, 1/I/L — 31 chars
_CHUNK_LEN = 4
_CHUNKS = 2


def _chunk() -> str:
    return "".join(secrets.choice(_ALPHABET) for _ in range(_CHUNK_LEN))


def generate_device_id() -> str:
    """
    Returns a fresh device ID like `GW-XXXX-XXXX`.

    Does NOT verify uniqueness against the database. Use
    `generate_unique_device_id` when provisioning in bulk — a collision
    before ~1 million devices is unlikely but not impossible (see the
    module docstring for the exact numbers).
    """
    return f"GW-{'-'.join(_chunk() for _ in range(_CHUNKS))}"


async def generate_unique_device_id(
    exists_check: Callable[[str], Awaitable[bool]],
    max_attempts: int = 5,
) -> str:
    """
    Returns a device ID that does not already exist in the database.

    `exists_check` is an async callable that returns `True` if the
    candidate ID is already taken. Callers pass a closure over a DB
    session:

        async def id_taken(candidate: str) -> bool:
            result = await db.execute(
                select(Device.id).where(Device.id == candidate)
            )
            return result.scalar_one_or_none() is not None

        device_id = await generate_unique_device_id(id_taken)

    Five attempts against a 8.5 × 10¹¹-possibility space has a vanishingly
    small failure rate until the table holds hundreds of millions of
    rows, at which point the DB primary-key constraint is the actual
    backstop — an insert that races past this check still cannot create
    a duplicate row.
    """
    for _ in range(max_attempts):
        candidate = generate_device_id()
        if not await exists_check(candidate):
            return candidate

    raise RuntimeError(
        "Could not generate a unique device ID after "
        f"{max_attempts} attempts. The ID space may be exhausted or the "
        "existence check is failing."
    )