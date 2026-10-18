"""Exercise the manual verification harness without reading real preferences."""
import contextlib
import datetime
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "verify", Path(__file__).resolve().parents[1] / "verify.py"
)
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class VerificationTests(unittest.TestCase):
    def check(self, function, preferences):
        with patch.object(verify, "prefs", return_value=preferences):
            with contextlib.redirect_stdout(io.StringIO()):
                return function()

    def restored_preferences(self):
        return {
            "dayHistory": json.dumps({verify.TODAY: [
                {"id": verify.T2, "title": "Second", "estimateMinutes": 60,
                 "completedBlocks": 1},
                {"id": verify.T1, "title": "First", "estimateMinutes": 25,
                 "completedAt": 1},
            ]}),
            "activeBlockID": f"{verify.T2}-work-2",
            "remaining": 1800,
            "isRunning": False,
        }

    def test_current_schema_restoration_passes_even_if_task_order_changes(self):
        self.assertTrue(self.check(verify.test_restore_and_complete,
                                   self.restored_preferences()))

    def test_wrong_block_fails_even_with_old_key_present(self):
        preferences = self.restored_preferences()
        preferences["activeTaskID"] = verify.T2
        for selected in (None, f"{verify.T2}-work-1", f"{verify.T1}-work-2"):
            with self.subTest(selected=selected):
                preferences["activeBlockID"] = selected
                self.assertFalse(self.check(verify.test_restore_and_complete, preferences))

    def test_rollover_requires_current_block_selection_to_be_cleared(self):
        yesterday = (datetime.date.today() - datetime.timedelta(days=1)).isoformat()
        preferences = {
            "dayHistory": json.dumps({yesterday: [{"title": "Yesterday"}]}),
            "isRunning": False,
        }
        self.assertTrue(self.check(verify.test_rollover, preferences))
        preferences["activeBlockID"] = f"{verify.T2}-work-2"
        self.assertFalse(self.check(verify.test_rollover, preferences))


if __name__ == "__main__":
    unittest.main()
