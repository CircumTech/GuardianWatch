"""widen_users_photo_url

Revision ID: 9b1701f05aae
Revises: 33f723d01676
Create Date: 2026-10-08 00:07:03.019968

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '9b1701f05aae'
down_revision: Union[str, None] = '33f723d01676'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    pass


def downgrade() -> None:
    pass
