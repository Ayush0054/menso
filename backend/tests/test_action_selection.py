"""Offline selector contract regressions. No provider calls."""

import unittest

from fastapi import HTTPException
from pydantic import ValidationError

from app.actions import Candidate, SelectionRequest, provider_failure, resolve_answer


class ActionSelectionTests(unittest.TestCase):
    def test_provider_credentials_are_not_reported_as_product_jwt_failure(self) -> None:
        for status_code in [401, 403]:
            with self.assertLogs("app.actions", level="WARNING") as logs:
                error = provider_failure(status_code)
            self.assertEqual(error.status_code, 502)
            self.assertEqual(error.detail, {"code": "typesafe_authentication_failed"})
            self.assertEqual(error.headers, {"Cache-Control": "no-store"})
            self.assertIn(f"upstream_status={status_code}", logs.output[0])

    def test_other_provider_errors_do_not_blame_credentials(self) -> None:
        for status_code in [422, 429, 500, 529]:
            with self.assertLogs("app.actions", level="WARNING"):
                error = provider_failure(status_code)
            self.assertEqual(error.detail, {"code": "typesafe_unavailable"})

    def setUp(self) -> None:
        self.candidates = [Candidate(id="action_0", kind="open_application", description="Open Example")]

    def answer(self, choice="action_0", confidence=0.95, probability=0.95):
        return {"answers": {"action": {"type": "choice", "choice": choice,
                "confidence": confidence, "probabilities": {choice: probability}}}}

    def test_known_choice_is_only_an_id(self) -> None:
        result = resolve_answer(self.answer(), self.candidates)
        self.assertEqual(result.model_dump(), {"status": "selected", "candidate_id": "action_0"})

    def test_uncertainty_abstains(self) -> None:
        for payload in [self.answer(confidence=0.5), self.answer(probability=0.5)]:
            result = resolve_answer(payload, self.candidates)
            self.assertEqual(result.status, "unclear")
            self.assertIsNone(result.candidate_id)

    def test_unsupported_remains_non_executable(self) -> None:
        result = resolve_answer(self.answer(choice="unsupported"), self.candidates)
        self.assertEqual(result.status, "unsupported")
        self.assertIsNone(result.candidate_id)

    def test_invented_choice_or_approval_cannot_pass(self) -> None:
        for choice in ["action_1", "requires_external_action", "run-123"]:
            with self.assertRaises(HTTPException):
                resolve_answer(self.answer(choice=choice), self.candidates)

    def test_malformed_or_nonfinite_confidence_fails_closed(self) -> None:
        for payload in [{}, [], self.answer(confidence=float("nan")), self.answer(probability=float("inf"))]:
            with self.assertRaises(HTTPException):
                resolve_answer(payload, self.candidates)

    def test_body_cannot_override_identity(self) -> None:
        with self.assertRaises(ValidationError):
            SelectionRequest.model_validate({"utterance": "Open Example", "candidates": [], "user_id": "other"})

    def test_duplicate_candidate_ids_are_rejected(self) -> None:
        with self.assertRaises(ValidationError):
            SelectionRequest(utterance="Open Example", candidates=self.candidates * 2)

    def test_completion_requires_task_loop_with_verified_progress(self) -> None:
        payload = self.answer(choice="complete")
        with self.assertRaises(HTTPException):
            resolve_answer(payload, self.candidates)
        self.assertEqual(resolve_answer(payload, self.candidates, allow_complete=True).status, "complete")

    def test_task_progress_is_bounded(self) -> None:
        with self.assertRaises(ValidationError):
            SelectionRequest(utterance="Open Example", candidates=self.candidates, completed_steps=self.candidates * 9)
