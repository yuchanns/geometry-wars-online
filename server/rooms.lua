local skynet = require "skynet"
local socket = require "skynet.socket"
local websocket = require "http.websocket"
local codec = require "net_codec"
local clients, rooms, next_room = {}, {}, 1
local function send(id, kind, body)
    local ok = pcall(websocket.write, id, string.char(kind)..codec.encode(body), "binary")
    return ok
end
local function list()
    local result={}
    for id,room in pairs(rooms) do result[#result+1]={id=id,count=#room.players,started=room.started} end
    table.sort(result,function(a,b)return a.id<b.id end)
    for id in pairs(clients) do send(id,32,result) end
end
local function status(room)
    for i,id in ipairs(room.players) do send(id,33,{id=room.id,count=#room.players,host=i==1,started=room.started}) end
    list()
end
local function leave(id)
    local client=clients[id]
    if not client or not client.room then return end
    local room=rooms[client.room];client.room=nil
    for i,peer in ipairs(room.players) do if peer==id then table.remove(room.players,i);break end end
    room.started=false
    if #room.players==0 then rooms[room.id]=nil else status(room) end
    send(id,33,{count=0});list()
end
local handlers={}
function handlers.handshake(id, header, url)
    if url~="/ws" then websocket.close(id,1008,"Unknown endpoint");return end
    clients[id]={};send(id,32,{});list()
end
function handlers.message(id, data, format)
    local client=clients[id]
    if not client then return end
    if format~="binary" or #data>1048576 or #data<1 then websocket.close(id,1008,"Invalid packet");return end
    local kind=data:byte(1)
    local room=client.room and rooms[client.room]
    if kind==2 or kind==3 then
        if not room or not room.started or #room.players~=2 then return end
        local host=room.players[1]
        if kind==2 and id~=host then websocket.write(host,data,"binary")
        elseif kind==3 and id==host then websocket.write(room.players[2],data,"binary") end
        return
    end
    local ok, body=pcall(codec.decode,data:sub(2))
    if not ok then websocket.close(id,1008,"Invalid data");return end
    if kind==16 then list()
    elseif kind==17 then
        if client.room then send(id,35,"Leave your room first");return end
        room={id=next_room,players={id},started=false};next_room=next_room+1
        rooms[room.id]=room;client.room=room.id;status(room)
    elseif kind==18 then
        room=type(body)=="number" and rooms[body]
        if client.room or not room or #room.players~=1 or room.started then send(id,35,"Room unavailable");return end
        client.room=room.id;room.players[2]=id;status(room)
    elseif kind==19 then leave(id)
    elseif kind==20 then
        if not room or room.players[1]~=id or #room.players~=2 or room.started then send(id,35,"Two players required");return end
        room.started=true;status(room)
        for i,peer in ipairs(room.players) do send(peer,34,{host=i==1}) end
    elseif kind==21 then
        if room and room.started then room.started=false;status(room) end
    else websocket.close(id,1008,"Unknown command") end
end
function handlers.close(id) leave(id);clients[id]=nil;list() end
handlers.error=handlers.close
function handlers.warning(ws,size) if size>256 then websocket.close(ws.id,1013,"Client too slow") end end
skynet.start(function()
    local listener=socket.listen("0.0.0.0",tonumber(skynet.getenv("ws_port")))
    socket.start(listener,function(id,addr) skynet.fork(function() websocket.accept(id,handlers,"ws",addr) end) end)
    skynet.error("Geometry Wars rooms ready on :"..skynet.getenv("ws_port"))
end)
