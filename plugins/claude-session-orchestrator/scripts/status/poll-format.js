let d='';
process.stdin.on('data',c=>d+=c);
process.stdin.on('end',()=>{
  const wt = JSON.parse(d).filter(w => w.name !== '.orchestrator' && w.name !== 'orchestrator');
  console.log('Worktree             | Branch                     | Deps  | Files | Status');
  console.log('---------------------|----------------------------|-------|-------|--------');
  const stuck = [];
  wt.forEach(w => {
    const s = !w.gitHealthy ? 'ZOMBIE'
      : w.uncommittedFiles > 2 ? 'BUILDING'
      : w.hasFrontendNodeModules ? 'READY'
      : 'NO DEPS';
    const deps = w.hasFrontendNodeModules ? 'YES' : '--';
    const branch = (w.branch || '--').slice(0, 26);
    console.log(`${w.name.padEnd(20)} | ${branch.padEnd(26)} | ${deps.padEnd(5)} | ${String(w.uncommittedFiles).padEnd(5)} | ${s}`);
    // Flag stuck agents: has deps but no code changes and no commits beyond base
    if (w.gitHealthy && w.hasFrontendNodeModules && w.uncommittedFiles <= 1 && s === 'READY') {
      stuck.push(w.name);
    }
  });
  if (stuck.length > 0) {
    console.log('');
    console.log('STUCK AGENTS (have deps, no code written):');
    stuck.forEach(n => console.log(`  -> ${n}`));
    console.log('ACTION: Send nudge via /send <name> <message>');
  }
});
