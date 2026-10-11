// REVIEW IN STAGING FIRST. PocketBase >=0.23 JS migration API.
// Additive only. Deliberately no down migration: removing fields would destroy metadata.
migrate((app) => {
  const tasks = app.findCollectionByNameOrId('tasks');
  const users = app.findCollectionByNameOrId('users');
  const required = ['title', 'description', 'priority', 'is_completed', 'completed_at', 'user'];
  for (const name of required) {
    if (!tasks.fields.getByName(name)) throw new Error('Unexpected tasks schema: missing ' + name);
  }
  const owner = tasks.fields.getByName('user');
  if (owner.type() !== 'relation' || owner.collectionId !== users.id || owner.maxSelect !== 1) {
    throw new Error('Expected single user relation; review schema: ' + JSON.stringify(owner) + ' expected users: ' + users.id);
  }
  const additions = [
    new DateField({name: 'due_at'}),
    new NumberField({name: 'estimated_minutes', min: 0, max: 10080, onlyInt: true}),
    new TextField({name: 'category', max: 80}),
    new DateField({name: 'scheduled_at'}),
  ];
  for (const field of additions) {
    const existing = tasks.fields.getByName(field.name);
    if (!existing) tasks.fields.add(field);
    else if (existing.type() !== field.type()) throw new Error('Conflicting existing field: ' + field.name);
  }
  // These are required for direct mobile CRUD as well as backend calls.
  // Review existing custom sharing/role rules before approving these owner-only rules.
  const rule = '@request.auth.id != "" && user = @request.auth.id';
  tasks.listRule = rule;
  tasks.viewRule = rule;
  tasks.createRule = '@request.auth.id != "" && @request.body.user = @request.auth.id';
  tasks.updateRule = rule + ' && @request.body.user:changed = false';
  tasks.deleteRule = rule;
  app.save(tasks);
});
