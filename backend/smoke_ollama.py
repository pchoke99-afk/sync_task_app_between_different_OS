"""Exercise the real local model against synthetic tasks, never PocketBase."""
import os
import tempfile
import time
from pathlib import Path

from service import Assistant, Store


class SyntheticTasks:
    user = 'aaaaaaaaaaaaaaa'
    task_id = 'bbbbbbbbbbbbbbb'

    def __init__(self):
        self.task = {'id': self.task_id, 'user': self.user,
                     'title': 'Study PEE2', 'description': 'Review notes',
                     'priority': 'normal', 'is_completed': False, 'updated': 'test-v1'}

    def list_tasks(self):
        return [dict(self.task)]

    def owned(self, task_id):
        if task_id != self.task_id:
            raise AssertionError('Model selected an unknown synthetic task.')
        return dict(self.task)

    def execute(self, operation):
        raise AssertionError('The smoke test must never execute task changes.')


def main():
    if os.environ.get('AI_PROVIDER') != 'ollama':
        raise SystemExit('This test only permits the local Ollama provider.')
    tasks = SyntheticTasks()
    with tempfile.TemporaryDirectory(prefix='sahur-smoke-') as directory:
        store = Store(str(Path(directory) / 'test.sqlite3'))
        try:
            assistant = Assistant(store)
            cases = [
                ('create_task', 'Propose a new task titled Study PEE2 practice problems, with high priority and description Solve five practice questions.'),
                ('update_task', 'Propose changing the existing Study PEE2 task priority from normal to high. Keep its title unchanged.'),
            ]
            for expected, message in cases:
                start = time.monotonic()
                result = assistant.chat(tasks, {'message': message})
                proposal = result['proposal']
                if not proposal or not any(op['name'] == expected for op in proposal['operations']):
                    raise AssertionError(f'{expected}: no expected proposal. Answer: {result["answer"]}')
                if proposal['status'] != 'pending':
                    raise AssertionError('Proposal must still require confirmation.')
                print(f'PASS {expected}: validated pending proposal ({time.monotonic() - start:.1f}s)', flush=True)
            print('PASS: no PocketBase connection or production task changes.', flush=True)
        finally:
            store.db.close()


if __name__ == '__main__':
    main()
