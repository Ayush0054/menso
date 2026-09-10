"""CLI entrypoint: ``python -m evals --tag smoke``."""

import sys
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parents[1] / ".env")

from agno.eval import cli  # noqa: E402

from evals.cases import CASES, eval_db, run_contract_checks  # noqa: E402

run_contract_checks()
sys.exit(cli(CASES, db=eval_db))
