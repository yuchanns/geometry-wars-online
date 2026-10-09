import test from 'node:test';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {writeFile,readFile,mkdir} from 'node:fs/promises';
import net from 'node:net';
import {WebSocket} from 'ws';
const root=new URL('../',import.meta.url);
function encode(v){
 if(v===null)return Buffer.from([0]);
 if(typeof v==='boolean')return Buffer.from([v?2:1]);
 if(typeof v==='number'){const b=Buffer.alloc(9);b[0]=3;b.writeDoubleLE(v,1);return b;}
 if(typeof v==='string'){const b=Buffer.from(v);const h=Buffer.alloc(3);h[0]=4;h.writeUInt16LE(b.length,1);return Buffer.concat([h,b]);}
 const entries=Object.entries(v);const h=Buffer.alloc(3);h[0]=5;h.writeUInt16LE(entries.length,1);return Buffer.concat([h,...entries.flatMap(([k,x])=>[encode(k),encode(x)])]);
}
function decode(b){let o=0;function get(){const t=b[o++];if(t===0)return null;if(t<3)return t===2;if(t===3){const n=b.readDoubleLE(o);o+=8;return n;}if(t===4){const n=b.readUInt16LE(o);o+=2;const s=b.toString('utf8',o,o+n);o+=n;return s;}if(t===5){const n=b.readUInt16LE(o);o+=2;const v={};for(let i=0;i<n;i++){const k=get();v[k]=get();}return v;}throw Error('Bad packet');}return get();}
async function peer(port){
 const ws=new WebSocket(`ws://127.0.0.1:${port}/ws`);const messages=[];let observer;
 ws.on('message',b=>{const m={kind:b[0],body:decode(b.subarray(1))};messages.push(m);observer?.();});
 await new Promise((res,rej)=>{ws.once('open',res);ws.once('error',rej);});
 return {ws,messages,send:(k,b={})=>ws.send(Buffer.concat([Buffer.from([k]),encode(b)])),
  wait(kind,predicate=()=>true){return new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error(`Missing packet ${kind}`)),3000);const check=()=>{const i=messages.findIndex(m=>m.kind===kind&&predicate(m.body));if(i>=0){const [m]=messages.splice(i,1);clearTimeout(timer);observer=undefined;resolve(m.body);}};observer=check;check();});}};
}
test('Skynet rooms require two players, isolate games, and recover after a player leaves',async t=>{
 const probe=net.createServer();await new Promise(r=>probe.listen(0,'127.0.0.1',r));const port=probe.address().port;await new Promise(r=>probe.close(r));
 await mkdir(new URL('build/test/',root),{recursive:true});const config=new URL('build/test/rooms.config',root);await writeFile(config,(await readFile(new URL('server/config',root),'utf8'))+`\nws_port = ${port}\n`);
 const proc=spawn('bin/native/skynet',[config.pathname],{cwd:root.pathname,stdio:['ignore','pipe','pipe']});t.after(()=>proc.kill('SIGTERM'));
 await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Skynet did not start')),5000);for(const stream of [proc.stdout,proc.stderr])stream.on('data',b=>{if(b.toString().includes('rooms ready')){clearTimeout(timer);resolve();}});proc.once('exit',c=>reject(Error(`Skynet exited: ${c}`)));});
 const host=await peer(port),guest=await peer(port),other=await peer(port);for(const p of [host,guest,other])t.after(()=>p.ws.terminate());
 host.send(17);const room=await host.wait(33,b=>b.count===1);assert.equal(room.host,true);
 host.send(20);assert.equal(await host.wait(35),'Two players required');
 const listing=await guest.wait(32,b=>Object.values(b).some(r=>r.id===room.id));assert.equal(Object.values(listing).find(r=>r.id===room.id).count,1);
 guest.send(18,room.id);assert.equal((await guest.wait(33,b=>b.count===2)).host,false);await host.wait(33,b=>b.count===2);
 guest.send(20);assert.equal(await guest.wait(35),'Two players required');
 other.send(18,room.id);assert.equal(await other.wait(35),'Room unavailable');
 host.send(20);assert.equal((await host.wait(34)).host,true);assert.equal((await guest.wait(34)).host,false);
 guest.send(2,{right:true});assert.equal((await host.wait(2)).right,true);
 host.send(3,{score:123});assert.equal((await guest.wait(3)).score,123);
 guest.send(3,{score:999});other.send(3,{score:888});
 await new Promise(r=>setTimeout(r,80));assert.equal(host.messages.some(m=>m.kind===3),false);assert.equal(other.messages.some(m=>m.kind===2||m.kind===3),false);
 guest.send(21);await host.wait(33,b=>!b.started&&b.count===2);host.send(20);await guest.wait(34);
 guest.ws.close();const waiting=await host.wait(33,b=>b.count===1&&!b.started);assert.equal(waiting.host,true);
 host.send(19);await host.wait(33,b=>b.count===0);host.send(16);await host.wait(32,b=>Object.values(b).every(r=>r.id!==room.id));
});
