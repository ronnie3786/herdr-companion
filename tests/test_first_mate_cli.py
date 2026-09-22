import io
import json
import unittest
from scripts import herdr_first_mate_cli as cli

class Reply:
    def __init__(self, request, value): self.request, self.value = request, value
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def geturl(self): return self.request.full_url
    def read(self, maximum): return json.dumps(self.value).encode()

class FirstMateCLITests(unittest.TestCase):
    def run_cli(self, argv, value=None, stdin=''):
        self.requests=[];self.launches=[]
        def opener(request, **kwargs):
            self.requests.append(request)
            return Reply(request, value or {'ok': True, 'feature': {'id': 'fmf_sample'}})
        out, err=io.StringIO(),io.StringIO()
        code=cli.main(argv,environ={'HERDR_HARNESS_API_TOKEN':'synthetic-token','HERDR_HARNESS_URL':'https://host.example.test'},stdin=io.StringIO(stdin),stdout=out,stderr=err,opener=opener,launch=lambda *a,**k:self.launches.append(a))
        return code,json.loads(out.getvalue() or err.getvalue())

    def test_send_preserves_stdin_and_request_identity(self):
        code,_=self.run_cli(['send','fmf_sample','--text-file','-','--request-id','stable-send'],'', 'Plan only.\nDo not implement.')
        self.assertEqual(code,0)
        body=json.loads(self.requests[0].data)
        self.assertEqual(body,{'text':'Plan only.\nDo not implement.','request_id':'stable-send'})
        self.assertEqual(self.requests[0].full_url,'https://host.example.test/api/v1/first-mate/features/fmf_sample/messages')

    def test_set_model_preserves_four_field_initial_request_when_safety_flags_omitted(self):
        code, _ = self.run_cli(['set-model', 'fmf_sample', '--model', 'synthetic/reasoner', '--thinking', 'high', '--expected-settings-revision', '2', '--request-id', 'model-one'])
        self.assertEqual(code, 0)
        self.assertEqual(self.requests[0].full_url, 'https://host.example.test/api/v1/first-mate/features/fmf_sample/model-settings')
        self.assertEqual(json.loads(self.requests[0].data), {'model': 'synthetic/reasoner', 'thinking': 'high', 'expected_settings_revision': 2, 'request_id': 'model-one'})

    def test_set_model_forwards_explicit_established_session_confirmation(self):
        code, _ = self.run_cli([
            'set-model', 'fmf_sample', '--model', 'synthetic/reasoner',
            '--thinking', 'high', '--expected-settings-revision', '2',
            '--expected-session-id', 'native-current',
            '--confirm-session-model-change', '--request-id', 'model-confirmed',
        ])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(self.requests[0].data), {
            'model': 'synthetic/reasoner',
            'thinking': 'high',
            'expected_settings_revision': 2,
            'expected_session_id': 'native-current',
            'confirm_session_model_change': True,
            'request_id': 'model-confirmed',
        })

    def test_pause_has_revision_and_no_automatic_retries(self):
        code,_=self.run_cli(['pause','fmf_sample','--expected-revision','3','--request-id','pause-one'])
        self.assertEqual(code,0);self.assertEqual(len(self.requests),1)
        self.assertEqual(json.loads(self.requests[0].data)['expected_revision'],3)

    def test_archive_uses_actions_route_and_optional_reason(self):
        code, _ = self.run_cli(['archive', 'fmf_sample', '--reason', 'test/synthetic', '--request-id', 'archive-one'])
        self.assertEqual(code, 0)
        self.assertTrue(self.requests[0].full_url.endswith('/features/fmf_sample/actions'))
        self.assertEqual(json.loads(self.requests[0].data), {
            'action': 'archive', 'reason': 'test/synthetic', 'request_id': 'archive-one',
        })
        self.run_cli(['unarchive', 'fmf_sample', '--request-id', 'unarchive-one'])
        self.assertEqual(json.loads(self.requests[0].data), {'action': 'unarchive', 'request_id': 'unarchive-one'})

    def test_list_archived_and_all_are_mutually_exclusive_api_views(self):
        self.run_cli(['list', '--archived'])
        self.assertTrue(self.requests[0].full_url.endswith('/features?view=archived'))
        self.run_cli(['list', '--all'])
        self.assertTrue(self.requests[0].full_url.endswith('/features?view=all'))
        code, result = self.run_cli(['list', '--archived', '--all'])
        self.assertEqual(code, 2)
        self.assertEqual(result['error']['code'], 'invalid_arguments')

    def test_open_only_navigates_after_feature_exists(self):
        code,data=self.run_cli(['open','fmf_sample','--graph'])
        self.assertEqual(code,0);self.assertIn('herdr://first-mate?',data['url'])
        self.assertIn('view=graph',data['url']);self.assertNotIn('synthetic-token',data['url'])
        self.assertEqual(self.requests[0].method,'GET');self.assertEqual(len(self.launches),1)

    def test_open_print_url_never_launches(self):
        code,_=self.run_cli(['open','fmf_sample','--print-url']);self.assertEqual(code,0);self.assertEqual(self.launches,[])

    def test_agents_returns_real_assignments(self):
        code,data=self.run_cli(['agents','fmf_sample'],{'ok':True,'assignments':[{'id':'a1'}]})
        self.assertEqual(data,{'ok':True,'assignments':[{'id':'a1'}]})

    def test_session_pagination(self):
        self.run_cli(['session','native-1','--before','40','--limit','20'])
        self.assertTrue(self.requests[0].full_url.endswith('/sessions/native-1?limit=20&before=40'))

    def test_rejects_remote_plain_http_and_missing_auth(self):
        code,_=self.run_cli(['--base-url','http://host.example.test','list']);self.assertEqual(code,2);self.assertEqual(self.requests,[])
        out=io.StringIO();self.assertEqual(cli.main(['list'],environ={},stderr=out),2)
        self.assertFalse(json.loads(out.getvalue())['ok'])

    def test_request_path_cannot_escape_feature(self):
        self.run_cli(['get','../notes?x=1'])
        self.assertIn('/features/..%2Fnotes%3Fx%3D1',self.requests[0].full_url)

if __name__=='__main__':unittest.main()
