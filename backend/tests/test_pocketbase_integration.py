"""Runs ONLY against a throwaway localhost PocketBase created by this test."""
import json
import os
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch
from pathlib import Path
from service import Assistant, Error, PocketBase, Store, request_json

@unittest.skipUnless(os.environ.get('POCKETBASE_TEST_BINARY'), 'Set POCKETBASE_TEST_BINARY to official local test binary; production is never used.')
class Integration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='task-pb-integration-')
        root = Path(cls.temp.name)
        migrations = root/'migrations'; migrations.mkdir()
        here = Path(__file__).parent
        shutil.copy2(here/'fixtures/1790000000_baseline.js',migrations)
        shutil.copy2(here.parents[1]/'pb_migrations/1791676800_task_scheduling.js',migrations)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0)); port = sock.getsockname()[1]
        cls.base = f'http://127.0.0.1:{port}'
        cls.log = open(root/'server.log','w+')
        cls.process = subprocess.Popen([os.environ['POCKETBASE_TEST_BINARY'],'serve','--http',f'127.0.0.1:{port}','--dir',str(root/'data'),'--migrationsDir',str(migrations),'--automigrate=false'],stdout=cls.log,stderr=cls.log)
        try:
            for _ in range(100):
                if cls.process.poll() is not None:
                    cls.log.seek(0); raise RuntimeError(cls.log.read())
                try: request_json(cls.base+'/api/health'); break
                except Error: time.sleep(.1)
            else: raise RuntimeError('Local PocketBase did not start.')
            cls.env = patch.dict(os.environ,{'POCKETBASE_URL':cls.base,'TASK_SCHEDULING_ENABLED':'true'})
            cls.env.start()
            cls.tokens = {}
            for who in ('alice','bob'):
                result = request_json(cls.base+'/api/collections/users/auth-with-password','POST',{'identity':who+'@example.invalid','password':'integration-only-password-123'})
                cls.tokens[who] = result['token']
        except Exception:
            cls.process.terminate(); cls.process.wait(); cls.log.close(); cls.temp.cleanup(); raise
    @classmethod
    def tearDownClass(cls):
        cls.env.stop(); cls.process.terminate(); cls.process.wait(timeout=10); cls.log.close(); cls.temp.cleanup()
    def setUp(self):
        self.pb = PocketBase(self.tokens['alice'])
        self.bob = PocketBase(self.tokens['bob'])
        self.store = Store(self.temp.name+'/history-'+str(time.time_ns())+'.sqlite3')
        self.a = Assistant(self.store)
        self.cid = self.store.conversation(self.pb.user)
    def tearDown(self): self.store.db.close()
    def test_legacy_records_and_accounts_preserved(self):
        record=self.pb.owned('bbbbbbbbbbbbbbb')
        self.assertEqual(record['title'],'Preserved legacy task')
        self.assertEqual(record['due_at'],'')
        self.assertEqual(self.bob.user,'ccccccccccccccc')
    def test_real_crud_confirmation_and_optional_metadata(self):
        op,_=self.a.validate(self.pb,'create_task',{'fields':{'title':'Integration exam','due_at':'2026-10-16T14:00:00Z','estimated_minutes':90,'category':'Study'}},[])
        pid=self.store.proposal(self.pb.user,self.cid,[op])['id']
        result=self.store.decide(self.pb,pid,True)
        self.assertEqual(result['status'],'applied')
        task_id=result['results'][0]['id']
        self.assertEqual(self.pb.owned(task_id)['estimated_minutes'],90)
        for name,args in [('update_task',{'task_id':task_id,'fields':{'priority':'high'}}),('complete_task',{'task_id':task_id}),('delete_task',{'task_id':task_id})]:
            op,_=self.a.validate(self.pb,name,args,[])
            pid=self.store.proposal(self.pb.user,self.cid,[op])['id']
            self.assertEqual(self.store.decide(self.pb,pid,True)['status'],'applied')
        with self.assertRaises(Error):self.pb.owned(task_id)
    def test_direct_api_cross_user_denied_by_database_rules(self):
        self.assertEqual(self.bob.list_tasks(),[])
        for method,body in [('GET',None),('PATCH',{'title':'Stolen'}),('DELETE',None)]:
            with self.assertRaises(Error):self.bob.call(method,'/bbbbbbbbbbbbbbb',body)
        with self.assertRaises(Error):self.bob.call('POST',body={'title':'Forgery','user':self.pb.user})
        with self.assertRaises(Error):self.pb.call('PATCH','/bbbbbbbbbbbbbbb',{'user':self.bob.user})
    def test_bad_token_denied(self):
        with self.assertRaises(Error) as caught:PocketBase('invalid')
        self.assertEqual(caught.exception.status,401)

if __name__=='__main__':unittest.main()
