import datetime as dt

from pydantic import BaseModel, ConfigDict, Field

# The mobile app enforces these ranges in ProfileScreen._validateAge and
# the gender dropdown. Server-side validation mirrors them because the
# backend is the source of truth — client validation is UX, not security.
_GENDER_VALUES = ("Male", "Female", "Non-binary", "Prefer not to say")


class UserOut(BaseModel):
    """Read-side representation of a User. Never includes secrets."""

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
    """
    Body for PATCH /me — all fields optional. Only fields that are
    provided (non-None) are applied.

    Constraints match the mobile-side validation in ProfileScreen:
      age   13–120
      gender one of Male / Female / Non-binary / Prefer not to say
      bmi   10.0–80.0 (loose physical bounds; BMI is optional)
    """

    display_name: str | None = Field(
        default=None,
        min_length=2,
        max_length=80,
    )
    photo_url: str | None = Field(
        default=None,
        max_length=2048,
    )
    age: int | None = Field(
        default=None,
        ge=13,
        le=120,
    )
    gender: str | None = Field(
        default=None,
        pattern="^(Male|Female|Non-binary|Prefer not to say)$",
    )
    bmi: float | None = Field(
        default=None,
        ge=10.0,
        le=80.0,
    )