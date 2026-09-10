"""Normalize platform-provided PostgreSQL URLs for psycopg."""

from __future__ import annotations


def normalize_postgres_url(value: str) -> str:
    value = value.strip()
    if value.startswith("postgres://"):
        value = "postgresql+psycopg://" + value.removeprefix("postgres://")
    elif value.startswith("postgresql://"):
        value = "postgresql+psycopg://" + value.removeprefix("postgresql://")
    if not value.startswith("postgresql+psycopg://"):
        raise ValueError("Menso requires a postgresql+psycopg database URL")
    return value
