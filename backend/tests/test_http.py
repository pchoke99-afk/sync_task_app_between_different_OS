"""HTTP contract tests with an isolated mock PocketBase adapter and fake model."""
import json
import threading
import unittest
from unittest.mock import patch
import service
from test_service import FakePB, FakeProvider, call

class HTTPContract(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.store = service.Store(self.tmp.name+'/history.db')
        self.pb = FakePB()
        self.assistant = service.Assistant(self.store, FakeProvider([call('create_task',{'fields':{'title':'Exam'}}), {'content':'Please review the new exam task.'}]))
        self.patches = [patch.object(service,'store',self.store,create=True), patch.object(service,'assistant',self.assistant,create=True), patch.object(service,'PocketBase',return_value=self.pb)]
        for p in self.patches:p.start()
        self.server = service.LimitedServer(('127.0.0.1',0),service.Handler)
        self.thread = threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.base=f'http://127.0.0.1:{self.server.server_port}'
    def tearDown(self):
        self.server.shutdown();self.server.server_close();self.thread.join()
        for p in reversed(self.patches):p.stop()
        self.store.db.close();self.tmp.cleanup()
    def test_chat_history_and_confirmation_contract(self):
        result=service.request_json(self.base+'/chat','POST',{'message':'Create an exam task'},'Bearer test-user-token')
        self.assertEqual(self.pb.executed,[])
        history=service.request_json(self.base+'/conversations/'+result['conversation_id'],token='Bearer test-user-token')
        self.assertEqual(len(history['messages']),2)
        pid=result['proposal']['id']
        confirmed=service.request_json(self.base+'/proposals/'+pid+'/decision','POST',{'confirm':True},'Bearer test-user-token')
        self.assertEqual(confirmed['status'],'applied')
        self.assertEqual(len(self.pb.executed),1)
    def test_missing_auth_and_non_boolean_confirmation_denied(self):
        with self.assertRaises(service.Error) as caught:service.request_json(self.base+'/conversations')
        self.assertEqual(caught.exception.status,401)
        result=service.request_json(self.base+'/chat','POST',{'message':'Create exam'},'Bearer test')
        with self.assertRaises(service.Error):service.request_json(self.base+'/proposals/'+result['proposal']['id']+'/decision','POST',{'confirm':'yes'},'Bearer test')
        self.assertEqual(self.pb.executed,[])

