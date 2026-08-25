#!/usr/bin/env node
/* The geometry can be tested without a browser now that it is its own file. */
const PE=require('../play-engine.js');
let fails=0; const ok=(c,m)=>{console.log((c?'PASS  ':'FAIL  ')+m); if(!c)fails++;};
const P=(...a)=>a.map(([x,y])=>({x,y}));

ok(PE.smoothD(P([0,0],[10,10]))==='M0,0 L10,10','two points stay a straight line');
ok(PE.smoothD(P([0,0],[10,0],[20,10])).includes(' C'),'three points curve');
ok(PE.smoothPts(P([0,0],[10,10])).length===2,'two points are not resampled');
ok(PE.smoothPts(P([0,0],[10,0],[20,10])).length===13,'a curve is sampled along its length');

const path=P([0,0],[10,0],[10,10]);
ok(PE.walk(path,0).x===0&&PE.walk(path,1).y===10,'walk runs end to end');
ok(Math.abs(PE.walk(path,0.5).x-10)<0.01,'and halfway is halfway along the path, not the points');
ok(PE.walk([{x:5,y:5}],0.5).x===5,'a man with nowhere to go stays put');

ok(PE.rectsOverlap({x:0,y:0,w:10,h:10},{x:5,y:5,w:10,h:10}),'overlapping rects overlap');
ok(!PE.rectsOverlap({x:0,y:0,w:10,h:10},{x:10,y:0,w:10,h:10}),'touching edges do not');

// the mirror: reflect a play across the line and flip it left to right
const m=PE.mirror({los:250,ours:P([100,300],[200,300])},
                  {los:100,ours:[{id:'a',x:100,y:200},{id:'b',x:300,y:200}],
                   routes:[{playerId:'a',points:P([100,300])}]});
ok(m.men.length===2,'every man comes across');
ok(m.men[0].x===320&&m.men[1].x===120,'their left is our right');
ok(m.men.every(x=>x.y<250),'and they line up on the far side of the ball');
ok(m.men[0].path.length===2&&m.men[1].path.length===1,'a man with a route brings it; one without does not');

// matchups: assignments win, then nearest, one man each
const men=[{label:'A',x:0,y:0},{label:'B',x:100,y:0},{label:'C',x:200,y:0}];
let mu=PE.matchups([{id:'1',x:10,y:0},{id:'2',x:110,y:0}],men);
ok(mu['1'].bi===0&&mu['2'].bi===1,'nearest man, best pair first');
ok(!mu['1'].assigned,'and it says it was a guess');
mu=PE.matchups([{id:'1',x:10,y:0,covers:'C'},{id:'2',x:110,y:0}],men);
ok(mu['1'].bi===2&&mu['1'].assigned,'an assignment overrides the guess');
ok(mu['2'].bi===1,'and the rest still sort themselves out');
mu=PE.matchups([{id:'1',x:10,y:0,covers:'ZZ'}],men);
ok(mu['1'].bi===0,'a label that no longer exists falls back to nearest');

// meets: somebody has to have run there
let c=PE.meets([{id:'1',ours:P([0,0],[100,0]),theirs:P([110,0],[10,0])}]);
ok(c.length===1&&c[0].t>0,'two men closing meet in the middle, not at the snap');
c=PE.meets([{id:'1',ours:P([0,0],[0,100]),theirs:P([14,0],[14,100])}]);
ok(c.length===1&&c[0].t>0.05,'a pair aligned across the ball meets a step in, not on it');
c=PE.meets([{id:'1',ours:P([0,0],[0,100]),theirs:P([400,0],[400,100])}]);
ok(c.length===0,'two men on opposite sides of the field never meet');
c=PE.meets([{id:'1',assigned:true,ours:P([0,0],[0,100]),theirs:P([400,0],[400,100])}]);
ok(c.length===1,'unless he has said they are a pair, and then it marks the closest they come');
c=PE.meets([{id:'1',ours:[{x:0,y:0}],theirs:[{x:5,y:0}]}]);
ok(c.length===0,'nobody moving is not a collision');

console.log(fails?('FAILURES: '+fails):'the engine holds up on its own');
process.exit(fails?1:0);
