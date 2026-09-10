"""Environment-backed settings with production fail-closed defaults."""

from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path
from urllib.parse import quote_plus

from pydantic import BaseModel, ConfigDict, field_validator, model_validator

from db.url import normalize_postgres_url

_ASYMMETRIC_JWT_ALGORITHMS = frozenset({"RS256", "RS384", "RS512", "ES256", "ES384", "ES512", "EdDSA"})


class Settings(BaseModel):
    model_config = ConfigDict(extra="ignore", str_strip_whitespace=True)

    runtime_env: str = "prd"
    os_id: str = "menso-os"
    database_url: str
    jwt_verification_key: str | None = None
    jwt_jwks_file: str | None = None
    jwt_algorithm: str = "RS256"
    admin_user_ids: frozenset[str] = frozenset()
    openai_api_key: str | None = None
    openai_realtime_model: str = "gpt-realtime-2.1"
    openai_realtime_voice: str = "marin"
    openai_realtime_reasoning_effort: str = "low"
    safety_identifier_salt: str | None = None
    agentos_url: str = "http://127.0.0.1:8000"
    public_url: str | None = None
    improvement_schedule_cron: str = "0 4 * * 1"
    eval_schedule_enabled: bool = False
    eval_schedule_cron: str = "0 5 * * 1"

    @field_validator("database_url", mode="before")
    @classmethod
    def normalize_database_url(cls, value: str) -> str:
        return normalize_postgres_url(value)

    @field_validator("jwt_algorithm")
    @classmethod
    def require_asymmetric_jwt_algorithm(cls, value: str) -> str:
        if value not in _ASYMMETRIC_JWT_ALGORITHMS:
            raise ValueError("JWT_ALGORITHM must be an asymmetric signing algorithm")
        return value

    @model_validator(mode="after")
    def enforce_production_secrets(self) -> Settings:
        if self.runtime_env != "dev" and not (self.jwt_verification_key or self.jwt_jwks_file):
            raise ValueError("Production requires JWT_VERIFICATION_KEY or JWT_JWKS_FILE")
        return self

    @property
    def auth_enabled(self) -> bool:
        return self.runtime_env != "dev"


def _split_csv(value: str | None) -> frozenset[str]:
    return frozenset(item.strip() for item in (value or "").split(",") if item.strip())


def _env_bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _database_url(runtime_env: str) -> str:
    if value := os.getenv("DATABASE_URL"):
        return value
    driver = os.getenv("DB_DRIVER", "postgresql+psycopg")
    user = quote_plus(os.getenv("DB_USER", "menso"))
    raw_password = os.getenv("DB_PASS")
    if runtime_env != "dev" and not raw_password:
        raise ValueError("Production requires DATABASE_URL or an explicit DB_PASS")
    password = quote_plus(raw_password or "menso")
    host = os.getenv("DB_HOST", "localhost")
    port = os.getenv("DB_PORT", "5432")
    database = quote_plus(os.getenv("DB_DATABASE", "menso"))
    return f"{driver}://{user}:{password}@{host}:{port}/{database}"


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    runtime_env = os.getenv("RUNTIME_ENV", "prd")
    return Settings(
        runtime_env=runtime_env,
        os_id=os.getenv("OS_ID", "menso-os"),
        database_url=_database_url(runtime_env),
        jwt_verification_key=os.getenv("JWT_VERIFICATION_KEY"),
        jwt_jwks_file=os.getenv("JWT_JWKS_FILE"),
        jwt_algorithm=os.getenv("JWT_ALGORITHM", "RS256"),
        admin_user_ids=_split_csv(os.getenv("MENSO_ADMIN_USER_IDS")),
        openai_api_key=os.getenv("OPENAI_API_KEY"),
        openai_realtime_model=os.getenv("OPENAI_REALTIME_MODEL", "gpt-realtime-2.1"),
        openai_realtime_voice=os.getenv("OPENAI_REALTIME_VOICE", "marin"),
        openai_realtime_reasoning_effort=os.getenv("OPENAI_REALTIME_REASONING_EFFORT", "low"),
        safety_identifier_salt=os.getenv("MENSO_SAFETY_IDENTIFIER_SALT"),
        agentos_url=os.getenv("AGENTOS_URL", "http://127.0.0.1:8000"),
        public_url=os.getenv("AGENTOS_PUBLIC_URL"),
        improvement_schedule_cron=os.getenv("IMPROVEMENT_SCHEDULE_CRON", "0 4 * * 1"),
        eval_schedule_enabled=_env_bool("EVAL_SCHEDULE_ENABLED", False),
        eval_schedule_cron=os.getenv("EVAL_SCHEDULE_CRON", "0 5 * * 1"),
    )


def resolve_jwks_file(settings: Settings) -> str | None:
    if not settings.jwt_jwks_file:
        return None
    path = Path(settings.jwt_jwks_file).expanduser().resolve()
    if not path.is_file():
        raise ValueError(f"JWT_JWKS_FILE does not exist: {path}")
    return str(path)
