"""
Shared `Limiter` instance. Lives in its own module (rather than inside
`main.py`) so routers can import it to decorate individual endpoints —
decorating a route function *after* `app.include_router()` has already
registered it has no effect, since the router captures a reference to the
endpoint at inclusion time.
"""
from slowapi import Limiter
from slowapi.util import get_remote_address

from app.config import get_settings

settings = get_settings()

limiter = Limiter(key_func=get_remote_address, default_limits=[settings.RATE_LIMIT_DEFAULT])
