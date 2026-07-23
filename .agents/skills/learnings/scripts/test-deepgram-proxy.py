#!/usr/bin/env python3
"""Offline regression tests for Ethan's installed Deepgram adapter.

No request reaches Deepgram. A fake upstream response proves that canonical silence is
typed once, malformed payloads remain failures, and logs never contain credentials.
"""

import contextlib
import importlib.util
import io
import json
import os
import unittest
from pathlib import Path
from unittest import mock


DEFAULT_PROXY = (
    Path.home()
    / "Library/Application Support/VoiceInk/DeepgramTunedProxy/deepgram_voiceink_proxy.py"
)
PROXY_PATH = Path(os.environ.get("VOICEINK_DEEPGRAM_PROXY_PATH", DEFAULT_PROXY))
SPEC = importlib.util.spec_from_file_location("voiceink_deepgram_proxy", PROXY_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not load proxy module from {PROXY_PATH}")
proxy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proxy)


class FakeResponse:
    def __init__(self, payload):
        self.encoded = json.dumps(payload).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, traceback):
        return False

    def read(self):
        return self.encoded


class DeepgramProxyTests(unittest.TestCase):
    def config(self):
        return {
            "deepgram_api_key": "offline-test-secret",
            "deepgram_max_attempts": 3,
            "keyterms_file": "__offline_test_missing_keyterms__",
            "prefer_utterances": False,
        }

    def transcribe(self, payload):
        fake = mock.Mock(return_value=FakeResponse(payload))
        stderr = io.StringIO()
        with mock.patch.object(proxy.urllib.request, "urlopen", fake), contextlib.redirect_stderr(stderr):
            try:
                result = proxy.deepgram_transcribe(
                    b"offline wav bytes",
                    self.config(),
                    None,
                    "local",
                    "",
                )
                return result, None, fake.call_count, stderr.getvalue()
            except proxy.ProxyError as error:
                return None, error, fake.call_count, stderr.getvalue()

    def test_canonical_silence_is_typed_once_and_never_retried(self):
        result, error, calls, logs = self.transcribe({
            "results": {"channels": [{"alternatives": [{"transcript": ""}]}]}
        })
        self.assertIsNone(result)
        self.assertEqual(error.status, 422)
        self.assertEqual(error.code, proxy.NO_SPEECH_DETECTED_ERROR_CODE)
        self.assertEqual(calls, 1)
        self.assertRegex(logs, r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z category=no_speech_detected")
        self.assertNotIn("offline-test-secret", logs)

    def test_malformed_payload_remains_a_real_failure(self):
        result, error, calls, logs = self.transcribe({"results": {}})
        self.assertIsNone(result)
        self.assertEqual(error.status, 502)
        self.assertIsNone(error.code)
        self.assertEqual(calls, 1)
        self.assertIn("category=unexpected_response_shape", logs)
        self.assertNotIn("offline-test-secret", logs)

    def test_nonempty_transcript_still_succeeds(self):
        result, error, calls, logs = self.transcribe({
            "results": {
                "channels": [{"alternatives": [{"transcript": "hello"}]}]
            }
        })
        self.assertEqual(result, "hello")
        self.assertIsNone(error)
        self.assertEqual(calls, 1)
        self.assertNotIn("offline-test-secret", logs)


if __name__ == "__main__":
    unittest.main(verbosity=2)
