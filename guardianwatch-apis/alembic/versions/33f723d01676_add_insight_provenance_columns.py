"""add_insight_provenance_columns

Revision ID: 33f723d01676
Revises: 08dc369c3c33
Create Date: 2026-10-07 22:04:04.271738

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '33f723d01676'
down_revision: Union[str, None] = '08dc369c3c33'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    pass


def downgrade() -> None:
    pass
