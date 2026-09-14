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

    def test_set_model_preserves_revision_effort_and_retry_identity(self):
        code, _ = self.run_cli(['set-model', 'fmf_sample', '--model', 'synthetic/reasoner', '--thinking', 'high', '--expected-settings-revision', '2', '--request-id', 'model-one'])
        self.assertEqual(code, 0)
        self.assertEqual(self.requests[0].full_url, 'https://host.example.test/api/v1/first-mate/features/fmf_sample/model-settings')
        self.assertEqual(json.loads(self.requests[0].data), {'model': 'synthetic/reasoner', 'thinking': 'high', 'expected_settings_revision': 2, 'request_id': 'model-one'})

    def test_pause_has_revision_and_no_automatic_retries(self):
        code,_=self.run_cli(['pause','fmf_sample','--expected-revision','3','--request-id','pause-one'])
        self.assertEqual(code,0);self.assertEqual(len(self.requests),1)
        self.assertEqual(json.loads(self.requests[0].data)['expected_revision'],3)

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
