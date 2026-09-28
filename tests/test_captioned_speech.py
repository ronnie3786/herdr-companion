import base64
import io
import json
import unittest
import wave

from herdr_harness.captioned_speech import CaptionedSpeechService, compile_cues, normalize_wave, normalize_words
from herdr_harness.response_audio import ResponseAudioError, ResponseAudioService


def recording(seconds=3):
    output = io.BytesIO()
    with wave.open(output, 'wb') as target:
        target.setnchannels(1)
        target.setsampwidth(2)
        target.setframerate(24000)
        target.writeframes(b'\0\0' * (24000 * seconds))
    return output.getvalue()


def cue(phrase='the ownership check', **extras):
    return {'id': 'ownership', 'shape': 'underline',
            'targets': [{'path': 'Sources/Cache.swift', 'side': 'after', 'startLine': 3, 'endLine': 4}],
            'onPhrase': phrase, **extras}


class Response:
    status = 200
    def __init__(self, value): self.value = json.dumps(value).encode()
    def __enter__(self): return self
    def __exit__(self, *_): return False
    def read(self, maximum): return self.value[:maximum]


class CaptionedSpeechTests(unittest.TestCase):
    def test_streaming_wave_placeholder_is_measured_from_real_samples(self):
        audio = bytearray(recording())
        audio[4:8] = (2**32 - 1).to_bytes(4, 'little')
        audio[40:44] = (2**32 - 1).to_bytes(4, 'little')
        normalized, duration = normalize_wave(bytes(audio))
        self.assertEqual(duration, 3)
        with wave.open(io.BytesIO(normalized)) as source:
            self.assertEqual(source.getnframes(), 72000)

    def test_phrase_at_arbitrary_point_and_expiry_compile_from_exact_words(self):
        script = 'First, inspect the ownership check. Now return the result.'
        words = [{'word': word, 'start': index * .4, 'end': index * .4 + .3}
                 for index, word in enumerate(script.split())]
        compiled, rejected = compile_cues([cue(untilPhrase='return the result')], words, script, 5)
        self.assertFalse(rejected)
        self.assertAlmostEqual(compiled[0]['onset'], 0.8)
        self.assertAlmostEqual(compiled[0]['until'], 2.4)

    def test_repeated_phrase_requires_occurrence(self):
        words = [{'word': 'Check', 'start': .1, 'end': .5}, {'word': 'check', 'start': 1, 'end': 1.4}]
        compiled, rejected = compile_cues([cue('check')], words, 'Check check', 3)
        self.assertEqual((compiled, rejected), ([], ['ownership']))
        compiled, rejected = compile_cues([cue('check', occurrence=2)], words, 'Check check', 3)
        self.assertEqual(compiled[0]['onset'], 1)

    def test_normalization_does_not_match_a_phrase_absent_from_the_input_script(self):
        words = [{'word': 'three', 'start': .2, 'end': .7}]
        self.assertEqual(compile_cues([cue('three')], words, '3', 2), ([], ['ownership']))

    def test_expiry_and_duration_outside_audio_omit_only_drawing(self):
        words = [{'word': 'check', 'start': 2.9, 'end': 3}]
        self.assertEqual(compile_cues([cue('check')], words, 'check', 3), ([], ['ownership']))

    def test_invalid_targets_and_boolean_durations_reject_request(self):
        for change in [{'drawSeconds': True}, {'targets': [{'path': '../secret', 'side': 'after', 'startLine': 1, 'endLine': 2}]},
                       {'shape': 'arrow'}, {'occurrence': True}]:
            with self.subTest(change=change), self.assertRaises(ResponseAudioError):
                compile_cues([cue(**change)], [], '', 3)

    def test_word_bounds_order_and_boolean_times_are_rejected(self):
        for raw in [[{'word': 'code', 'start_time': True, 'end_time': 1}],
                    [{'word': 'code', 'start_time': 0, 'end_time': 10}],
                    [{'word': 'code', 'start_time': 1, 'end_time': 2}, {'word': 'next', 'start_time': .5, 'end_time': 2}]]:
            with self.subTest(raw=raw), self.assertRaises(ResponseAudioError): normalize_words(raw, 3)

    def test_punctuation_pauses_and_codec_tolerance_do_not_invent_words(self):
        words = normalize_words([{'word': 'Code', 'start_time': -.02, 'end_time': 3.04},
                                 {'word': '.', 'start_time': 3.04, 'end_time': 4}], 3)
        self.assertEqual(words, [{'word': 'Code', 'start': 0, 'end': 3}])

    def make_service(self, caption=True):
        requests = []
        def open_request(request, **_):
            if request.full_url.endswith('/openapi.json'):
                return Response({'paths': {'/dev/captioned_speech': {'post': {}}} if caption else {}})
            if request.full_url.endswith('/voices'):
                return Response({'voices': [{'id': 'af_jessica'}, {'id': 'am_echo'}, {'id': 'bm_daniel'}]})
            body = json.loads(request.data)
            requests.append(body)
            return Response({'audio': base64.b64encode(recording()).decode(), 'audio_format': 'wav',
                             'timestamps': [{'word': 'Check', 'start_time': .2 if body['voice'] == 'af_jessica' else .8, 'end_time': 1}]})
        service = CaptionedSpeechService(ResponseAudioService({'HERDR_RESPONSE_AUDIO_TTS_URL': 'https://speech.example.invalid',
                                                              'HERDR_RESPONSE_AUDIO_VOICE': 'af_jessica'}, opener=open_request))
        return service, requests

    def test_voice_script_and_settings_have_separate_recordings_and_cues(self):
        service, requests = self.make_service()
        first = service.synthesize(text='Check', voice='af_jessica', cues=[cue('check')])
        second = service.synthesize(text='Check', voice='am_echo', cues=[cue('check')])
        self.assertEqual(first['cues'][0]['onset'], .2)
        self.assertEqual(second['cues'][0]['onset'], .8)
        self.assertNotEqual(first['voice'], second['voice'])
        self.assertEqual(first['script'], 'Check')
        self.assertEqual(first['duration'], 3)
        self.assertEqual(requests[0]['input'], 'Check')
        self.assertFalse(requests[0]['stream'])
        service.synthesize(text='Check', voice='af_jessica', cues=[])
        self.assertEqual(len(requests), 2)
        service.synthesize(text='Check!', voice='af_jessica', cues=[])
        service.audio.speed = 1.2
        service.synthesize(text='Check', voice='af_jessica', cues=[])
        self.assertEqual(len(requests), 4)

    def test_unsupported_service_preserves_text_and_has_no_timestamps(self):
        service, requests = self.make_service(caption=False)
        result = service.synthesize(text='Read the explanation', cues=[])
        self.assertFalse(result['available'])
        self.assertEqual(result['script'], 'Read the explanation')
        self.assertFalse(result['cues'])
        self.assertNotIn('duration', result)
        self.assertFalse(requests)

    def test_unknown_voice_is_rejected_before_synthesis(self):
        service, requests = self.make_service()
        with self.assertRaises(ResponseAudioError): service.synthesize(text='Check', voice='invented')
        self.assertFalse(requests)

    def test_capability_does_not_expose_private_endpoint(self):
        service, _ = self.make_service()
        self.assertNotIn('example.invalid', json.dumps(service.capabilities()))


if __name__ == '__main__': unittest.main()
