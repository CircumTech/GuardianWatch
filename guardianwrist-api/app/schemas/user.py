import datetime as dt

from pydantic import BaseModel, ConfigDict


class UserOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    email: str | None = None
    display_name: str | None = None
    photo_url: str | None = None
    age: int | None = None
    gender: str | None = None
    bmi: float | None = None
    premium: bool
    created_at: dt.datetime


class UserProfileUpdate(BaseModel):
    """Body for PATCH /me — all fields optional, only provided ones change."""
    display_name: str | None = None
    photo_url: str | None = None
    age: int | None = None
    gender: str | None = None
    bmi: float | None = None
