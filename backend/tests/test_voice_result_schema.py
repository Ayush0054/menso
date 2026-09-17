"""Offline regression coverage for model output versus native approval state."""

import unittest

from pydantic import ValidationError

from schemas.voice import DelegateToMensoResult, MensoTaskResult


class VoiceResultSchemaTests(unittest.TestCase):
    def test_model_cannot_return_pending_approval(self) -> None:
        with self.assertRaises(ValidationError):
            MensoTaskResult.model_validate(
                {"status": "requires_external_action", "spoken_summary": "Please approve Chrome."}
            )

    def test_model_cannot_invent_continuation_metadata(self) -> None:
        with self.assertRaises(ValidationError):
            MensoTaskResult.model_validate(
                {
                    "status": "completed",
                    "spoken_summary": "Hello.",
                    "run_id": "invented-run",
                    "continuation_kind": "agent",
                    "continuation_resource_id": "menso",
                }
            )

    def test_terminal_result_remains_compatible_with_voice_transport(self) -> None:
        terminal = MensoTaskResult(status="completed", spoken_summary="Hello.")
        transport = DelegateToMensoResult.model_validate(terminal.model_dump())
        self.assertEqual(transport.status, "completed")
        self.assertIsNone(transport.run_id)

    def test_transport_still_supports_native_pending_review(self) -> None:
        transport = DelegateToMensoResult(
            status="requires_external_action",
            spoken_summary="Review the action card in Menso.",
            run_id="native-run",
            continuation_kind="agent",
            continuation_resource_id="menso",
        )
        self.assertEqual(transport.run_id, "native-run")
