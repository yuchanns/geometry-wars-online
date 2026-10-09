local ltask = require "ltask"
local websocket = require "ext.websocket"
local codec = require "net_codec"

global ipairs, pcall, string, table, tostring

local MAX_QUEUE <const> = 64
local RECONNECT_DELAY <const> = 200 -- ltask time is in centiseconds.
local S = {}
local owner, endpoint, socket
local incoming, outgoing = {}, {}
local awaiting_receive = false
local reported_state, reported_reason
local retry_at = 0
local failure
local quitting = false

local function disconnect(reason)
    if socket then socket:close() end
    incoming, outgoing = {}, {}
    failure = reason
    retry_at = ltask.now() + RECONNECT_DELAY
end

local function connect(url)
    if socket then socket:close() end
    socket = websocket.connect(url or endpoint, string.char(2, 3))
    incoming, outgoing = {}, {}
    failure = nil
    retry_at = ltask.now() + RECONNECT_DELAY
end

-- Retain the latest gameplay packet while preserving room command order.
local function enqueue(data)
    local kind = data:byte(1)
    if kind == 2 or kind == 3 then
        for i, pending in ipairs(incoming) do
            if pending:byte(1) == kind then
                table.remove(incoming, i)
                break
            end
        end
    end
    if #incoming >= MAX_QUEUE then
        disconnect("Receive queue overflow")
        return false
    end
    incoming[#incoming + 1] = data
    return true
end

local function deliver(state, reason)
    if awaiting_receive then return end
    if #incoming == 0 and state == reported_state and reason == reported_reason then return end
    local messages = {}
    local redirect
    for _, data in ipairs(incoming) do
        local ok, body = pcall(codec.decode, data:sub(2))
        if not ok then
            disconnect(tostring(body))
            state, reason, messages = "closed", failure, {}
            break
        end
        if data:byte(1) == 36 then
            if body.room == 0 then
                redirect = endpoint
            else
                redirect = endpoint:gsub("%?.*$", "") .. "?room=" .. string.format("%.0f", body.room) .. "&ticket=" .. body.ticket
            end
        end
        messages[#messages + 1] = {data:byte(1), body}
    end
    incoming = {}
    reported_state, reported_reason = state, reason
    awaiting_receive = true
    ltask.send(owner, "_network_update", state, reason, messages)
    if redirect then connect(redirect) end
end

local function tick()
    -- poll also drives the native curl handshake and partial sends.
    for _, data in ipairs(socket:poll()) do
        if not enqueue(data) then break end
    end
    local state, reason = socket:status()
    reason = failure or reason
    if state == "open" then
        while #outgoing > 0 do
            local packet = outgoing[1]
            if not socket:send(packet.data) then break end
            table.remove(outgoing, 1)
            if packet.frame then ltask.send(owner, "_network_sent") end
        end
    elseif state == "closed" then
        outgoing = {}
    end
    deliver(state, reason)
    -- Deliver queued room redirects before reconnecting to the lobby.
    if state == "closed" and #incoming == 0 and not awaiting_receive and ltask.now() >= retry_at then connect() end
end

function S.connect(address, url)
    owner, endpoint = address, url
    connect()
end

function S.received()
    awaiting_receive = false
end

function S.send(kind, body, frame)
    if not socket or socket:status() ~= "open" then
        if frame then ltask.send(owner, "_network_sent") end
        return
    end
    local ok, data = pcall(codec.encode, body)
    if not ok then
        disconnect(tostring(data))
        return
    end
    if #outgoing >= MAX_QUEUE then
        disconnect("Send queue overflow")
        return
    end
    outgoing[#outgoing + 1] = {data = string.char(kind) .. data, frame = frame}
end

function S.close(reason)
    disconnect(reason)
end

function S.quit()
    quitting = true
    if socket then socket:close() end
    incoming, outgoing = {}, {}
end

ltask.fork(function()
    while not quitting do
        if socket then
            local ok, err = pcall(tick)
            if not ok then disconnect(tostring(err)) end
        end
        ltask.sleep(1)
    end
end)

return S
