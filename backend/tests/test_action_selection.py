"""Offline selector contract regressions. No provider calls."""

import unittest

from fastapi import HTTPException
from pydantic import ValidationError

from app.actions import Candidate, SelectionRequest, resolve_answer


class ActionSelectionTests(unittest.TestCase):
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
