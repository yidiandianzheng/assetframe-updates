import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest

CLIENT = Path(__file__).resolve().parent.parent / 'CLI/assetframe'

class ClientTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='assetframe-cli-client-')
        self.root = Path(self.tmp.name)
        self.endpoint = self.root / 'endpoint.json'
        self.token = 'private-client-test-token'
    def tearDown(self): self.tmp.cleanup()
    def endpoint_file(self, port=1, **changes):
        info = dict(protocolVersion=1, host='127.0.0.1', port=port, token=self.token, pid=os.getpid())
        info.update(changes)
        self.endpoint.write_text(json.dumps(info));self.endpoint.chmod(0o600)
    def call(self, *args):
        return subprocess.run([str(CLIENT), *args, '--endpoint', str(self.endpoint), '--json'], capture_output=True, text=True, timeout=12)
    def serve(self, callback):
        listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen();listener.settimeout(10)
        self.endpoint_file(listener.getsockname()[1])
        errors=[]
        def run():
            try:
                with listener, listener.accept()[0] as peer:
                    data=b''
                    while not data.endswith(b'\n'):data += peer.recv(65536)
                    request=json.loads(data);self.assertEqual(request['token'],self.token)
                    response=callback(request)
                    peer.sendall(json.dumps(response).encode()+b'\n')
            except Exception as e:errors.append(e)
        thread=threading.Thread(target=run);thread.start()
        return thread,errors
    def test_success_pagination(self):
        def respond(r):
            self.assertEqual(r['command'],'materials.list')
            self.assertEqual(r['arguments'],dict(query='木兰',kind='视频',limit='20',offset='5',includeDeleted='false'))
            return dict(protocolVersion=1,id=r['id'],ok=True,result={'total':30,'items':[]})
        t,errors=self.serve(respond);result=self.call('list','--query','木兰','--kind','视频','--limit','20','--offset','5');t.join();self.assertFalse(errors)
        self.assertEqual(result.returncode,0);self.assertTrue(json.loads(result.stdout)['ok']);self.assertNotIn(self.token,result.stdout+result.stderr)
    def test_app_rejection(self):
        t,errors=self.serve(lambda r: dict(protocolVersion=1,id=r['id'],ok=False,error={'code':'unsaved_edits','message':'先保存'}))
        result=self.call('preview','id');t.join();self.assertFalse(errors);self.assertEqual(result.returncode,3)
    def test_mismatched_response(self):
        t,errors=self.serve(lambda r: dict(protocolVersion=1,id='wrong',ok=True,result={}))
        result=self.call('status');t.join();self.assertFalse(errors);self.assertEqual(result.returncode,4)
    def test_unsafe_discovery(self):
        self.endpoint_file(host='192.0.2.1');self.assertEqual(self.call('status').returncode,4)
        self.endpoint_file();self.endpoint.chmod(0o644);self.assertEqual(self.call('status').returncode,4)
        self.endpoint.chmod(0o600);target=self.root/'private.json';self.endpoint.rename(target);self.endpoint.symlink_to(target)
        self.assertEqual(self.call('status').returncode,4)
    def test_missing_discovery(self): self.assertEqual(self.call('status').returncode,4)
    def test_private_report_no_overwrite(self):
        output=self.root/'report.json'
        def response(r):return dict(protocolVersion=1,id=r['id'],ok=True,result={'appVersion':'TEST'})
        t,errors=self.serve(response);result=self.call('diagnostics','--output',str(output));t.join();self.assertFalse(errors)
        self.assertEqual(result.returncode,0);self.assertEqual(output.stat().st_mode&0o777,0o600);before=output.read_bytes()
        t,errors=self.serve(response);result=self.call('diagnostics','--output',str(output));t.join();self.assertFalse(errors)
        self.assertEqual(result.returncode,4);self.assertEqual(output.read_bytes(),before)
    def test_measure_rejects_non_qa_and_validates_whole_scenario(self):
        scenario=self.root/'scenario.json'; scenario.write_text(json.dumps({'steps':[{'command':'status'}]}))
        self.endpoint_file()
        result=self.call('measure','--scenario',str(scenario),'--output',str(self.root/'out.json'))
        self.assertEqual(result.returncode,4);self.assertFalse((self.root/'out.json').exists())
        scenario.write_text(json.dumps({'steps':[{'command':'status'},{'command':'delete','id':'asset'}]}))
        result=self.call('measure','--scenario',str(scenario),'--output',str(self.root/'out.json'))
        self.assertEqual(result.returncode,4);self.assertIn('不支持的操作',result.stderr)
    def test_measure_records_settled_qa_and_private_report(self):
        with tempfile.TemporaryDirectory(prefix='assetframe-qa.measure-test-',dir='/tmp') as raw:
            qa=Path(raw);(qa/'CLI').mkdir();(qa/'test.assetframelibrary').mkdir()
            scenario=qa/'scenario.json';scenario.write_text(json.dumps({'steps':[{'command':'search','query':'木兰'}]}))
            listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen();listener.settimeout(10)
            endpoint=qa/'CLI/endpoint.json';endpoint.write_text(json.dumps(dict(protocolVersion=1,host='127.0.0.1',port=listener.getsockname()[1],token=self.token)));endpoint.chmod(0o600)
            errors=[];commands=[]
            def serve():
                searched=False;pending=True
                try:
                    for _ in range(5):
                        with listener.accept()[0] as peer:
                            data=b''
                            while b'\n' not in data:data+=peer.recv(65536)
                            r=json.loads(data);self.assertEqual(r['token'],self.token);commands.append(r['command'])
                            if r['command']=='browse.search':searched=True;payload={'accepted':True}
                            else:
                                payload={'pid':os.getpid(),'libraryID':'qa','appVersion':'test','libraryPath':str(qa/'test.assetframelibrary'),'browse':{'search':'木兰' if searched else ''},'workspace':{'queryPending':searched and pending,'visibleCount':2},'previewPipeline':{'activeDecodes':0}}
                                if searched:pending=False
                            peer.sendall(json.dumps(dict(protocolVersion=1,id=r['id'],ok=True,result=payload)).encode()+b'\n')
                except Exception as e:errors.append(e)
                finally:listener.close()
            thread=threading.Thread(target=serve);thread.start()
            output=qa/'out.json'
            result=subprocess.run([str(CLIENT),'measure','--scenario',str(scenario),'--output',str(output),'--repeat','1','--endpoint',str(endpoint),'--json'],capture_output=True,text=True,timeout=12)
            thread.join();self.assertFalse(errors);self.assertEqual(result.returncode,0,result.stderr)
            report=json.loads(output.read_text());self.assertTrue(report['passed']);self.assertEqual(len(report['samples']),1);self.assertEqual(commands.count('status'),4)
            self.assertEqual(output.stat().st_mode&0o777,0o600);self.assertNotIn(self.token,output.read_text()+result.stdout+result.stderr)
    def test_timeout_argument(self):self.assertEqual(self.call('status','--timeout','nan').returncode,4)

if __name__=='__main__':unittest.main()
