import io
import json
import unittest
import urllib.error
from unittest.mock import Mock, patch

from herdr_harness import voice
from tests.test_herdr_voice import _wav


class _Response:
    def __init__(self, payload=None, *, body=None, headers=None):
        self.body = io.BytesIO(json.dumps(payload).encode() if body is None else body)
        self.headers = headers or {}
    def read(self, maximum):
        return self.body.read(maximum)
    def __enter__(self):
        return self
    def __exit__(self, *_):
        return False


class TranscriptionTests(unittest.TestCase):
    def setUp(self):
        self.env = {"HERDR_HARNESS_TRANSCRIPTION_URL": "https://speech.example.test/v1/audio/transcriptions", "HERDR_HARNESS_TRANSCRIPTION_MODEL": "example-model", "HERDR_HARNESS_TRANSCRIPTION_TOKEN": "provider-test-token"}
        self.wav = _wav()

    def transcribe(self, environ=None, **kwargs):
        return voice.transcribe(filename="voice.wav", mime_type="audio/wav", data=self.wav, environ=self.env if environ is None else environ, **kwargs)

    def test_unconfigured_provider_never_opens_network(self):
        with patch("urllib.request.build_opener") as opened, self.assertRaises(voice.VoiceError) as failure:
            self.transcribe({})
        opened.assert_not_called()
        self.assertEqual(failure.exception.code, "transcription_not_configured")

    def test_openai_provider_receives_multipart_file_model_and_only_its_own_token(self):
        opener = Mock()
        opener.open.return_value = _Response({"text": "  Do the work. ", "language": "en"})
        with patch("urllib.request.build_opener", return_value=opener):
            result = self.transcribe()
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, self.env["HERDR_HARNESS_TRANSCRIPTION_URL"])
        self.assertEqual(request.get_header("Authorization"), "Bearer provider-test-token")
        self.assertIn(b'name="file"; filename="voice.wav"', request.data)
        self.assertIn(b'name="model"', request.data)
        self.assertIn(b"example-model", request.data)
        self.assertIn(self.wav, request.data)
        self.assertEqual(result, {"ok": True, "text": "Do the work.", "backend": "openai", "language": "en"})
        self.assertEqual(opener.open.call_args.kwargs["timeout"], 90)

    def test_parakeet_provider_receives_audio_field_without_a_model_requirement(self):
        opener = Mock()
        opener.open.return_value = _Response({"text": "Local speech"})
        with patch("urllib.request.build_opener", return_value=opener):
            result = self.transcribe({"HERDR_HARNESS_TRANSCRIPTION_URL": "http://127.0.0.1:19000/transcribe", "HERDR_HARNESS_TRANSCRIPTION_BACKEND": "parakeet"})
        request = opener.open.call_args.args[0]
        self.assertIn(b'name="audio"', request.data)
        self.assertNotIn(b'name="model"', request.data)
        self.assertIsNone(request.get_header("Authorization"))
        self.assertEqual(result["backend"], "parakeet")

    def test_redirects_are_rejected_and_provider_error_details_are_private(self):
        handler = None
        def build(*handlers):
            nonlocal handler
            handler = handlers[0]
            opener = Mock()
            opener.open.side_effect = urllib.error.HTTPError("https://private.example.test", 307, "private-token", {"Location": "https://other.example.test"}, io.BytesIO(b"private-token"))
            return opener
        with patch("urllib.request.build_opener", side_effect=build), self.assertRaises(voice.VoiceError) as failure:
            self.transcribe()
        self.assertIsNone(handler.redirect_request(None, None, 307, "Redirect", {}, "https://other.example.test"))
        self.assertEqual(failure.exception.code, "transcription_provider_error")
        self.assertNotIn("private", str(failure.exception))

    def test_endpoint_credentials_queries_injection_and_unknown_backend_are_rejected(self):
        overrides = [
            {"HERDR_HARNESS_TRANSCRIPTION_URL": value} for value in ("file:///tmp/file", "https://user:pass@host.test", "https://host.test?token=x", "https://host.test#token", "https://host.test:99999")
        ]
        overrides += [{"HERDR_HARNESS_TRANSCRIPTION_TOKEN": "abc\nX: evil"}, {"HERDR_HARNESS_TRANSCRIPTION_BACKEND": "unknown"}, {"HERDR_HARNESS_TRANSCRIPTION_MODEL": ""}]
        for override in overrides:
            with self.subTest(override=override), patch("urllib.request.build_opener") as opened, self.assertRaises(voice.VoiceError):
                self.transcribe({**self.env, **override})
            opened.assert_not_called()

    def test_response_size_is_bounded_with_or_without_content_length(self):
        for response in (_Response({}, headers={"Content-Length": str(voice.MAX_TRANSCRIPTION_RESPONSE_BYTES + 1)}), _Response(body=b"x" * (voice.MAX_TRANSCRIPTION_RESPONSE_BYTES + 1))):
            opener = Mock()
            opener.open.return_value = response
            with patch("urllib.request.build_opener", return_value=opener), self.assertRaises(voice.VoiceError) as failure:
                self.transcribe()
            self.assertEqual(failure.exception.code, "transcription_response_too_large")

    def test_timeouts_are_typed_without_exposing_private_endpoint_details(self):
        for error in (TimeoutError("private detail"), urllib.error.URLError(TimeoutError("private detail"))):
            opener = Mock()
            opener.open.side_effect = error
            with patch("urllib.request.build_opener", return_value=opener), self.assertRaises(voice.VoiceError) as failure:
                self.transcribe()
            self.assertEqual(failure.exception.code, "transcription_timeout")
            self.assertEqual(failure.exception.status, 504)
            self.assertNotIn("private", str(failure.exception))

    def test_malformed_json_and_transcripts_are_rejected(self):
        for response in (_Response(body=b"not json"), _Response([]), _Response({"text": ""}), _Response({"text": "x" * (voice.MAX_TRANSCRIPT_CHARACTERS + 1)}), _Response({"text": "hello", "language": 42})):
            opener = Mock()
            opener.open.return_value = response
            with patch("urllib.request.build_opener", return_value=opener), self.assertRaises(voice.VoiceError) as failure:
                self.transcribe()
            self.assertEqual(failure.exception.code, "transcription_invalid_response")

    def test_invalid_recording_filename_mime_and_audio_are_rejected_before_network(self):
        for override in ({"filename": "voice.wav\r\nX:injected.wav"}, {"mime_type": "audio/mpeg"}, {"data": b"not audio"}):
            with self.subTest(override=override), patch("urllib.request.build_opener") as opened, self.assertRaises(voice.VoiceError):
                voice.transcribe(**{"filename": "voice.wav", "mime_type": "audio/wav", "data": self.wav, "environ": self.env, **override})
            opened.assert_not_called()


if __name__ == "__main__":
    unittest.main()
