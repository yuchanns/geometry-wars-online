-- Data-only binary encoding shared with Skynet. No executable Lua crosses the socket.
local M = {}
local function encode(v, chunks, depth)
    assert(depth < 12, "Packet nesting too deep")
    local t = type(v)
    if t == "nil" then chunks[#chunks+1] = "\0"
    elseif t == "boolean" then chunks[#chunks+1] = v and "\2" or "\1"
    elseif t == "number" then chunks[#chunks+1] = "\3" .. string.pack("<d", v)
    elseif t == "string" then chunks[#chunks+1] = "\4" .. string.pack("<I2", #v) .. v
    elseif t == "table" then
        local count = 0
        for k, x in pairs(v) do if type(x) ~= "function" and (type(k)=="string" or type(k)=="number") then count=count+1 end end
        chunks[#chunks+1] = "\5" .. string.pack("<I2", count)
        for k, x in pairs(v) do
            if type(x) ~= "function" and (type(k)=="string" or type(k)=="number") then encode(k,chunks,depth+1);encode(x,chunks,depth+1) end
        end
    else error("Unsupported packet value: "..t) end
end
function M.encode(v)
    local chunks = {};encode(v,chunks,0);local result=table.concat(chunks)
    assert(#result<=1048575,"Packet too large");return result
end
local function decode(data, offset, depth, budget)
    assert(depth<12 and budget[1]<50000,"Packet complexity limit")
    budget[1]=budget[1]+1
    local tag=data:byte(offset);offset=offset+1
    if tag==0 then return nil,offset
    elseif tag==1 then return false,offset
    elseif tag==2 then return true,offset
    elseif tag==3 then local v;v,offset=string.unpack("<d",data,offset);assert(v==v and math.abs(v)<math.huge,"Invalid number");return v,offset
    elseif tag==4 then
        local size;size,offset=string.unpack("<I2",data,offset);assert(offset+size-1<=#data,"Truncated string")
        return data:sub(offset,offset+size-1),offset+size
    elseif tag==5 then
        local size;size,offset=string.unpack("<I2",data,offset);local result={}
        for _=1,size do
            local k,v;k,offset=decode(data,offset,depth+1,budget);v,offset=decode(data,offset,depth+1,budget)
            assert(type(k)=="string" or type(k)=="number","Invalid key");result[k]=v
        end
        return result,offset
    end
    error("Invalid packet tag")
end
function M.decode(data)
    assert(#data<=1048575,"Packet too large")
    local result,offset=decode(data,1,0,{0});assert(offset==#data+1,"Trailing packet data");return result
end
return M
