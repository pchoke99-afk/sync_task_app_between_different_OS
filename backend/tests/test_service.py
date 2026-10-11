import copy
import json
import tempfile
import unittest
from unittest.mock import patch
from service import Assistant, Error, Store, PocketBase, fields, fingerprint, Provider, request_json

U = 'aaaaaaaaaaaaaaa'
T = 'bbbbbbbbbbbbbbb'

class FakePB:
    user = U
    def __init__(self):
        self.tasks = {T: {'id': T, 'user': U, 'title': 'Circuits homework', 'priority': 'normal', 'updated': 'v1'}}
        self.executed = []
    def list_tasks(self): return list(self.tasks.values())
    def owned(self, task_id):
        record = self.tasks.get(task_id)
        if not record: raise Error(404, 'Unavailable')
        if record['user'] != self.user: raise Error(403, 'Ownership failed')
        return record
    def execute(self, operation):
        self.executed.append(operation)
        if operation['name'] == 'create_task':
            record = {'id': operation['record_id'], 'user': self.user, **operation['arguments']['fields']}
            self.tasks[record['id']] = record
            return record
        record = self.owned(operation['arguments']['task_id'])
        if operation['name'] == 'delete_task': del self.tasks[record['id']]
        return record

class FakeProvider:
    def __init__(self, replies): self.replies = iter(replies)
    def reply(self, messages): return next(self.replies)

def call(name, args):
    return {'content': None, 'tool_calls': [{'id': 'call1', 'type': 'function', 'function': {'name': name, 'arguments': json.dumps(args)}}]}

class Tests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict('os.environ', {'TASK_SCHEDULING_ENABLED':'true'})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.tmp = tempfile.TemporaryDirectory()
        self.store = Store(self.tmp.name + '/db')
        self.pb = FakePB()
        self.a = Assistant(self.store)
        self.cid = self.store.conversation(U)
    def tearDown(self): self.store.db.close(); self.tmp.cleanup()
    def assertError(self, function, status=400):
        with self.assertRaises(Error) as caught: function()
        self.assertEqual(caught.exception.status, status)
    def test_unknown_tool_and_owner_fields(self):
        self.assertError(lambda: self.a.validate(self.pb, 'sql', {'query': 'DELETE'}, []))
        self.assertError(lambda: fields({'title': 'x', 'user': 'other'}, True))
    def test_invalid_priority_duration_dates_and_ids(self):
        for bad in ({'priority':'urgent'}, {'estimated_minutes':True}, {'estimated_minutes':-1}, {'estimated_minutes':10081}, {'due_at':'2026-10-12'}, {'title':''}):
            self.assertError(lambda: fields(bad))
        self.assertError(lambda: self.a.validate(self.pb, 'delete_task', {'task_id':'../users'}, []))
    def test_nullable_fields_and_clear_deadline(self):
        self.assertEqual(fields({'title':None, 'due_at':''}), {'due_at':''})
        self.assertEqual(fields({'title':'Exam'}, True)['priority'], 'normal')
    def test_cross_user_task_denied(self):
        self.pb.tasks[T]['user'] = 'ccccccccccccccc'
        self.assertError(lambda: self.a.validate(self.pb, 'delete_task', {'task_id':T}, []), 403)
    def test_preview_does_not_write(self):
        self.a.provider = FakeProvider([call('delete_task', {'task_id':T}), {'content':'Please review.'}])
        result = self.a.chat(self.pb, {'message':'Delete circuits homework'})
        self.assertEqual(self.pb.executed, [])
        self.assertEqual(result['proposal']['operations'][0]['preview_title'], 'Circuits homework')
    def proposal(self, name='delete_task', args=None):
        op, _ = self.a.validate(self.pb, name, args or {'task_id':T}, [])
        return self.store.proposal(U, self.cid, [op])['id']
    def test_confirm_applies_once_and_persists_result(self):
        pid = self.proposal()
        result = self.store.decide(self.pb, pid, True)
        self.assertEqual(result['status'], 'applied')
        self.assertEqual(self.store.decide(self.pb, pid, True), result)
        self.assertEqual(len(self.pb.executed), 1)
    def test_cancel_never_executes_even_after_reconfirm(self):
        pid = self.proposal()
        self.store.decide(self.pb, pid, False)
        self.assertEqual(self.store.decide(self.pb, pid, True)['status'], 'cancelled')
        self.assertEqual(self.pb.executed, [])
    def test_cross_user_conversation_and_confirmation_denied(self):
        pid = self.proposal()
        self.pb.user = 'ccccccccccccccc'
        self.assertError(lambda: self.store.history(self.pb.user, self.cid), 404)
        self.assertError(lambda: self.store.decide(self.pb, pid, True), 404)
    def test_stale_preview_prevents_all_changes(self):
        pid = self.proposal()
        self.pb.tasks[T]['priority'] = 'high'
        self.assertError(lambda: self.store.decide(self.pb, pid, True), 409)
        self.assertEqual(self.pb.executed, [])
    def test_expired_preview(self):
        pid = self.proposal()
        with self.store.db: self.store.db.execute('UPDATE proposals SET expires=0 WHERE id=?', (pid,))
        self.assertError(lambda: self.store.decide(self.pb, pid, True), 409)
    def test_crashed_confirmation_never_replays(self):
        pid = self.proposal()
        with self.store.db: self.store.db.execute("UPDATE proposals SET status='executing' WHERE id=?", (pid,))
        self.assertError(lambda: self.store.decide(self.pb, pid, True), 409)
    def test_partial_failure_explicit(self):
        pid = self.proposal()
        with patch.object(self.pb, 'execute', side_effect=Error(503, 'Offline')):
            self.assertEqual(self.store.decide(self.pb, pid, True)['status'], 'partial_or_failed')
        self.assertEqual(self.store.decide(self.pb, pid, True)['status'], 'partial_or_failed')
    def test_duplicate_target_rejected_before_proposal(self):
        self.a.provider = FakeProvider([call('complete_task', {'task_id':T}), call('delete_task', {'task_id':T})])
        self.assertError(lambda: self.a.chat(self.pb, {'message':'Complete and delete'}))
        self.assertEqual(self.pb.executed, [])
    def test_rate_limit_persistent(self):
        self.store.limit('x', 1)
        self.assertError(lambda: self.store.limit('x', 1), 429)
    def test_history_is_shared_through_persistent_database(self):
        self.store.message(U, self.cid, 'user', 'hello')
        other = Store(self.tmp.name + '/db')
        self.assertEqual(other.history(U, self.cid)['messages'][0]['content'], 'hello')
        other.db.close()
    def test_history_pagination_preserves_all_messages(self):
        for index in range(55):
            self.store.message(U, self.cid, 'user', str(index))
        recent = self.store.history(U, self.cid)
        self.assertTrue(recent['has_more'])
        earlier = self.store.history(U, self.cid, recent['messages'][0]['id'])
        self.assertFalse(earlier['has_more'])
        self.assertEqual([m['content'] for m in earlier['messages'] + recent['messages']], [str(i) for i in range(55)])
    def test_provider_outage_no_operations(self):
        with patch.object(self.a.provider, 'reply', side_effect=Error(503, 'Offline')):
            self.assertError(lambda: self.a.chat(self.pb, {'message':'Create exam task'}), 503)
        self.assertEqual(self.pb.executed, [])
    def test_organizing_puts_deadlines_first_and_completed_last(self):
        tasks = [{'id':'1','title':'No deadline','priority':'high'}, {'id':'2','title':'Tomorrow','priority':'normal','due_at':'2026-10-12'}, {'id':'3','title':'Done','priority':'high','is_completed':True,'due_at':'2020-01-01'}]
        _, result = self.a.validate(self.pb, 'organize_tasks', {}, tasks)
        self.assertEqual([r['id'] for r in result], ['2','1','3'])
    def test_pocketbase_adapter_verifies_token_and_ownership(self):
        with patch('service.request_json', side_effect=[{'record':{'id':U,'collectionName':'users'},'token':'fresh'}, {'id':T,'user':'ccccccccccccccc'}]) as mock:
            pb = PocketBase('old')
            self.assertIn('/auth-refresh', mock.call_args_list[0].args[0])
            self.assertError(lambda: pb.owned(T), 403)
    def test_pocketbase_adapter_denies_superuser(self):
        with patch('service.request_json', return_value={'record':{'id':U,'collectionName':'_superusers'},'token':'x'}):
            self.assertError(lambda: PocketBase('x'), 401)
    def test_openai_request_has_strict_tools_and_bounds(self):
        env={'AI_MODEL':'test-model','OPENAI_API_KEY':'test-only','AI_PROVIDER':'openai'}
        with patch.dict('os.environ', env), patch('service.request_json', return_value={'choices':[{'finish_reason':'stop','message':{'content':'Hi'}}]}) as mock:
            Provider().reply([{'role':'user','content':'Hi'}])
            body = mock.call_args.args[2]
            self.assertFalse(body['store'])
            self.assertTrue(all(t['function']['strict'] for t in body['tools']))
            self.assertFalse(body['parallel_tool_calls'])
    def test_ollama_adapter_uses_same_tools_without_key(self):
        with patch.dict('os.environ', {'AI_MODEL':'local','AI_PROVIDER':'ollama','AI_BASE_URL':'http://localhost:11434/v1'}), patch('service.request_json', return_value={'choices':[{'finish_reason':'stop','message':{'content':'Hi'}}]}) as mock:
            Provider().reply([])
            self.assertIsNone(mock.call_args.args[3])
            self.assertIn('max_tokens', mock.call_args.args[2])
    def test_incomplete_provider_response_denied(self):
        with patch.dict('os.environ', {'AI_MODEL':'test','OPENAI_API_KEY':'test'}), patch('service.request_json', return_value={'choices':[{'finish_reason':'length','message':{'content':'oops'}}]}):
            self.assertError(lambda: Provider().reply([]), 502)

if __name__ == '__main__': unittest.main()
