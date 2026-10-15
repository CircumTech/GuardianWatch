"""
Records what an admin did.

See `models/admin_audit_log.py` for why this table exists and why it is
append-only. This module is the only write path.

TRANSACTION SEMANTICS

  Two modes, chosen by the caller:

    `commit=True` (default)
      Adds the entry to the session and commits it. Use this when the
      audit is a standalone event — the router has no other uncommitted
      changes.

    `commit=False`
      Adds the entry to the session WITHOUT committing. The caller is
      responsible for committing. Use this from any handler that is
      already mid-transaction, so the audit record and the mutation it
      describes commit atomically: either both persist, or neither does.

  The correct default for admin routers is `commit=False`. If the audit
  insert fails — say, a schema mismatch after a code change — you want
  the mutation to roll back with it, not to have happened silently with
  no record of who did it.

  Reading the audit log to reconcile "what happened" is only meaningful
  if the log is guaranteed complete for every mutation the API accepts.
"""
from __future__ import annotations

import logging
import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from app.models.admin_audit_log import AdminAuditLog
from app.models.admin_user import AdminUser

logger = logging.getLogger("guardianwrist.admin_audit")


async def record(
    db: AsyncSession,
    admin: AdminUser,
    action: str,
    resource_type: str,
    resource_id: str,
    detail: dict | None = None,
    *,
    commit: bool = True,
) -> AdminAuditLog:
    """
    Writes an audit log entry.

    Returns the entry so the caller can reference its id or timestamp if
    needed (e.g. to include it in the response). The return value is
    available even when `commit=False` — the entry exists in the session
    and is queryable, it just isn't durable until the caller commits.

    `detail` is copied defensively before being stored. A caller that
    mutates the dict after calling `record()` should not accidentally
    change what was written.
    """
    entry = AdminAuditLog(
        # Explicit id rather than relying on the model's `default=` —
        # the caller may read `entry.id` before the row is flushed.
        # Matches the model's `uuid4().hex` shape (32 chars, no dashes)
        # so both code paths produce the same format.
        id=uuid.uuid4().hex,
        admin_id=admin.id,
        admin_email=admin.email,
        action=action,
        resource_type=resource_type,
        resource_id=resource_id,
        detail=dict(detail) if detail else {},
    )
    db.add(entry)

    if commit:
        await db.commit()
        await db.refresh(entry)
        logger.info(
            "Audit: %s %s=%s by %s",
            action,
            resource_type,
            resource_id,
            admin.email,
        )

    return entry