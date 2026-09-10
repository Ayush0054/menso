"""Process-wide Postgres and pgvector factories."""

from __future__ import annotations

from functools import lru_cache

from agno.db.postgres import PostgresDb
from agno.knowledge.knowledge import Knowledge
from agno.vectordb.pgvector import PgVector

from app.settings import get_settings


@lru_cache(maxsize=1)
def get_db() -> PostgresDb:
    settings = get_settings()
    return PostgresDb(db_url=settings.database_url, id="menso-postgres")


@lru_cache(maxsize=16)
def create_knowledge(table_name: str, max_results: int = 8) -> Knowledge:
    """Create a namespaced knowledge facade over a shared pgvector database."""

    settings = get_settings()
    return Knowledge(
        name=table_name,
        vector_db=PgVector(
            db_url=settings.database_url,
            table_name=table_name,
        ),
        max_results=max_results,
    )
