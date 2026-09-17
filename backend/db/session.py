"""Shared Postgres task state."""

from functools import lru_cache

from agno.db.postgres import PostgresDb

from app.settings import get_settings


@lru_cache(maxsize=1)
def get_db() -> PostgresDb:
    return PostgresDb(db_url=get_settings().database_url, id="menso-postgres")
