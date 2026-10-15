"""
Shared `Limiter` instance. Lives in its own module (rather than inside
`main.py`) so routers can import it to decorate individual endpoints —
decorating a route function *after* `app.include_router()` has already
registered it has no effect, since the router captures a reference to the
endpoint at inclusion time.
"""
from fastapi import Request
from slowapi import Limiter

from app.config import get_settings

settings = get_settings()


def _client_ip(request: Request) -> str:
    """
    Returns the originating client IP for rate-limiting purposes.

    On Render (and most PaaS) the platform terminates TLS at its edge and
    forwards the original client via the left-most entry of
    ``X-Forwarded-For``. ``request.client.host`` inside the container is
    the reverse proxy, so using it directly would bucket every user
    behind the same IP and one busy client would starve everyone else.

    We trust ``X-Forwarded-For`` here because the app is only reachable
    through Render's proxy — never expose uvicorn directly without
    changing this.

    Falls back to the peer address if the header is absent (direct
    connection, e.g. local dev or integration tests).
    """
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        # XFF is a comma-separated list: client, proxy1, proxy2, ...
        # The first entry is the original client.
        first = forwarded.split(",", 1)[0].strip()
        if first:
            return first

    return request.client.host if request.client else "unknown"


limiter = Limiter(
    key_func=_client_ip,
    default_limits=[settings.RATE_LIMIT_DEFAULT],
)