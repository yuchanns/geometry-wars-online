local ltask = require "ltask"
local M = {}
function M.new(ctx)
    local net = { host=false, started=false, room=nil, rooms={}, selected=1, page=1, error="", connected=false, events={} }
    local network = ltask.uniqueservice "geometry_wars/network"
    local inbox
    local pending_send = false
    local sent, received = 0, 0
    -- Acknowledge only after the frame consumes this batch, bounding the inbox.
    ltask.dispatch {
        _network_update = function(state, reason, messages)
            inbox = {state=state, reason=reason, messages=messages}
        end,
        _network_sent = function() pending_send = false end,
    }
    local function send(kind, body, frame)
        if not net.connected then return false end
        ltask.send(network, "send", kind, body, frame)
        return true
    end
    function net.record(kind,body)
        if net.host and net.started then net.events[#net.events+1]={kind,body,net.effect_source} end
    end
    function net.connect()
        net.connected=false;net.room=nil;net.started=false;pending_send=false
        ltask.send(network, "connect", ltask.self(), ctx.endpoint)
        print("Connecting: "..ctx.endpoint)
    end
    function net.poll(time)
        local batch = inbox
        if batch then
            inbox = nil
            local state, reason = batch.state, batch.reason
            if not net.connected and state=="open" then net.error="" end
            net.connected=state=="open"
            if state=="closed" then
                net.started=false;net.room=nil;net.error=reason or "";pending_send=false
                net.events={}
            else
                for _, message in ipairs(batch.messages) do
                    local ok,err=pcall(function()
                        local kind,body=message[1],message[2]
                        if kind==32 then
                            net.rooms=body;net.selected=math.min(math.max(1,#body),net.selected)
                            net.page=math.min(net.page,math.max(1,math.ceil(#body/7)))
                        elseif kind==33 then
                            if body.count==0 then net.room=nil;net.started=false else net.room=body;net.host=body.host;net.started=body.started end
                        elseif kind==34 then net.host=body.host;net.started=true;net.error="";ctx.reset_partner();print("Room started / "..(net.host and "host" or "guest"))
                        elseif kind==35 then net.error=body
                        elseif kind==36 then
                            net.room=nil;net.started=false;pending_send=false;net.events={}
                        elseif kind==2 and net.host then received=time;ctx.remote_input(body)
                        elseif kind==3 and not net.host then received=time;ctx.apply(body)
                        end
                    end)
                    if not ok then
                        net.error=tostring(err);print(err)
                        ltask.send(network, "close", net.error)
                        break
                    end
                end
            end
            ltask.send(network, "received")
        end
        if net.started and net.host and time-received>.5 then ctx.remote_input({}) end
    end
    function net.publish(time)
        if not net.started or pending_send or time-sent<1/15 then return end
        if net.host then
            local snapshot=ctx.snapshot();snapshot.events=net.events
            if send(3,snapshot,true) then net.events={};pending_send=true;sent=time end
        elseif send(2,ctx.local_input(),true) then pending_send=true;sent=time end
    end
    function net.create() send(17,{}) end
    function net.join() local r=net.rooms[net.selected];if r then send(18,r.id) end end
    function net.start() send(20,{}) end
    function net.leave() send(19,{}) end
    function net.finish() send(21,{}) end
    function net.refresh() send(16,{}) end
    function net.draw()
        ctx.text(0,95,"GEOMETRY WARS",24,0xff00ffff,"C",800)
        local function button(x,y,w,label,action,enabled)
            if ctx.button(x,y,w,30,label,enabled and 0xff00ffff or 0xff404040) and enabled then action() end
        end
        if not net.connected then ctx.text(0,230,"CONNECTING...",12,0xff79c8ff,"C",800);return end
        if net.room then
            ctx.text(0,178,string.format("ROOM %03d",net.room.id),16,0xffffffff,"C",800)
            ctx.text(0,222,net.room.count==1 and "WAITING FOR SECOND PLAYER" or "TWO PLAYERS READY",10,0xff79c8ff,"C",800)
            button(240,295,320,net.host and "START GAME" or "WAITING FOR HOST",net.start,net.host and net.room.count==2)
            button(300,346,200,"LEAVE ROOM",net.leave,true)
        else
            ctx.text(60,160,"ROOM",8,0xffc8c8c8,"LT",120,8)
            ctx.text(230,160,"PLAYERS",8,0xffc8c8c8,"LT",100,8)
            ctx.text(360,160,"STATUS",8,0xffc8c8c8,"LT",120,8)
            button(600,148,140,"CREATE ROOM",net.create,true)
            if #net.rooms==0 then ctx.text(60,205,"NO ROOMS",8,0xffffffff,"LT",400,12) end
            local first=(net.page-1)*7+1
            for i=first,math.min(first+6,#net.rooms) do
                local r=net.rooms[i]
                local y=200+(i-first)*40
                local enabled=r.count<2 and not r.started
                ctx.text(60,y,string.format("#%03d",r.id),8,0xffffffff,"LT",120,12)
                ctx.text(230,y,string.format("%d/2",r.count),8,0xffffffff,"LT",100,12)
                ctx.text(360,y,r.started and "PLAYING" or (enabled and "WAITING" or "FULL"),8,0xffffffff,"LT",120,12)
                button(600,y-8,140,"JOIN",function()net.selected=i;net.join()end,enabled)
            end
            if #net.rooms>7 then
                local pages=math.ceil(#net.rooms/7)
                ctx.text(60,505,string.format("PAGE %d/%d",net.page,pages),8,0xffffffff,"LT",120,12)
                button(600,490,65,"PREV",function()net.page=net.page-1 end,net.page>1)
                button(675,490,65,"NEXT",function()net.page=net.page+1 end,net.page<pages)
            end
        end
        ctx.text(0,540,net.error,8,0xffff554a,"C",800)
    end
    net.reset_partner = ctx.reset_partner
    net.connect()
    return net
end
return M
