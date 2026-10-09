import test from 'node:test';
import assert from 'node:assert/strict';
import {WebSocket} from 'ws';
const endpoint = process.env.GAME_SERVER || 'ws://127.0.0.1:8789/ws';
function encode(v){
 if(v===null)return Buffer.from([0]);
 if(typeof v==='boolean')return Buffer.from([v?2:1]);
 if(typeof v==='number'){const b=Buffer.alloc(9);b[0]=3;b.writeDoubleLE(v,1);return b;}
 if(typeof v==='string'){const b=Buffer.from(v);const h=Buffer.alloc(3);h[0]=4;h.writeUInt16LE(b.length,1);return Buffer.concat([h,b]);}
 const entries=Object.entries(v);const h=Buffer.alloc(3);h[0]=5;h.writeUInt16LE(entries.length,1);return Buffer.concat([h,...entries.flatMap(([k,x])=>[encode(k),encode(x)])]);
}
function decode(b){let o=0;function get(){const t=b[o++];if(t===0)return null;if(t<3)return t===2;if(t===3){const n=b.readDoubleLE(o);o+=8;return n;}if(t===4){const n=b.readUInt16LE(o);o+=2;const s=b.toString('utf8',o,o+n);o+=n;return s;}if(t===5){const n=b.readUInt16LE(o);o+=2;const v={};for(let i=0;i<n;i++){const k=get();v[k]=get();}return v;}throw Error('Bad packet');}return get();}
async function peer(){
 let ws, stopped=false;
 const sockets=new Set();
 const messages=[];let observer;
 function connect(url){
  ws=new WebSocket(url);sockets.add(ws);
  ws.on('error',()=>{});
  ws.on('message',b=>{
   if(stopped)return;
   const m={kind:b[0],body:decode(b.subarray(1))};
   if(m.kind===36){const url=new URL(endpoint);if(m.body.room){url.searchParams.set('room',m.body.room);url.searchParams.set('ticket',m.body.ticket);}connect(url);return;}
   messages.push(m);observer?.();
  });
 }
 connect(endpoint);
 await new Promise((res,rej)=>{ws.once('open',res);ws.once('error',rej);});
 return {get ws(){return ws;},close(){stopped=true;for(const socket of sockets)socket.terminate();},messages,send:(k,b={})=>ws.send(Buffer.concat([Buffer.from([k]),encode(b)])),
  wait(kind,predicate=()=>true){return new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error(`Missing packet ${kind} ${predicate}: queued ${JSON.stringify(messages)}`)),15000);const check=()=>{const i=messages.findIndex(m=>m.kind===kind&&predicate(m.body));if(i>=0){const [m]=messages.splice(i,1);clearTimeout(timer);observer=undefined;resolve(m.body);}};observer=check;check();});}};
}
test('Worker rooms require two players, isolate games, and recover after a player leaves',async t=>{
 const host=await peer(),guest=await peer(),other=await peer();for(const p of [host,guest,other])t.after(()=>p.close());
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
 host.send(19);await host.wait(33,b=>b.count===0);await host.wait(32,b=>Object.values(b).every(r=>r.id!==room.id));
});
