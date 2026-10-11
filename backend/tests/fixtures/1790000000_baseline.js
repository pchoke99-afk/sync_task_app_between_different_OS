migrate((app) => {
  const users = app.findCollectionByNameOrId('users');
  users.passwordAuth.enabled = true;
  app.save(users);
  const tasks = new Collection({name:'tasks',type:'base', fields:[
    {name:'created',type:'autodate',onCreate:true},
    {name:'updated',type:'autodate',onCreate:true,onUpdate:true},
    {name:'title',type:'text',required:true,max:200},
    {name:'description',type:'text',max:4000},
    {name:'priority',type:'select',values:['high','normal','low'],maxSelect:1},
    {name:'is_completed',type:'bool'}, {name:'completed_at',type:'date'},
    {name:'user',type:'relation',collectionId:users.id,maxSelect:1,required:true},
  ]});
  app.save(tasks);
  for (const [id,email] of [['aaaaaaaaaaaaaaa','alice@example.invalid'],['ccccccccccccccc','bob@example.invalid']]) {
    const record = new Record(users);
    record.set('id',id); record.set('email',email);
    record.set('password','integration-only-password-123'); record.set('passwordConfirm','integration-only-password-123');
    app.save(record);
  }
  const task = new Record(tasks);
  task.set('id','bbbbbbbbbbbbbbb');task.set('user','aaaaaaaaaaaaaaa');task.set('title','Preserved legacy task');task.set('priority','normal');
  app.save(task);
});
