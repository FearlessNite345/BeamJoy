local M = {
    _name = "BJIRX",
    _ctrls = {},
    logEndpointsBlacklist = {
        { BJI_EVENTS.PLAYER.EVENT, BJI_EVENTS.PLAYER.RX.SERVER_TICK }
    }
}
-- route events categories to controller files
for k, v in pairs(BJI_EVENTS) do
    if type(v) == "table" and type(v.RX) == "table" and tlength(v.RX) > 0 then
        M._ctrls[k] = require("ge/extensions/BJI/rx/" .. k .. "Controller")
    end
end
for _, ctrl in pairs(M._ctrls) do
    function ctrl.dispatchEvent(self, endpoint, data)
        local fn = self[endpoint]
        if fn and type(fn) == "function" then
            fn(data)
        else
            LogWarn(svar("Event received but not handled : {1}", { endpoint }), self.tag)
        end
    end
end

BJILoaded = {}
local function initListeners()
    if MPConfig then
        for _, v in pairs(BJI_EVENTS) do
            if type(v) == "table" and type(v.RX) == "table" and tlength(v.RX) > 0 then
                BJILoaded[v.EVENT] = true
            end
        end
    end
end

-- the JSON parser change number keys to strings, so update recursively
local function parsePayload(obj)
    if type(obj) == "table" then
        local cpy = {}
        for k, v in pairs(obj) do
            local finalKey = tonumber(k) or k
            cpy[finalKey] = parsePayload(v)
        end
        return cpy
    end
    return obj
end

local function dispatchEvent(eventName, endpoint, data)
    if not data or type(data) ~= "table" then
        LogError(svar("Invalid endpoint {1}.{2}", { eventName, endpoint }), M._name)
        return
    end
    for event, ctrl in pairs(M._ctrls) do
        if type(BJI_EVENTS[event]) == "table" and BJI_EVENTS[event].EVENT == eventName then
            -- LOG
            local inBlacklist = false
            for _, el in pairs(M.logEndpointsBlacklist) do
                if el[1] == eventName and el[2] == endpoint then
                    inBlacklist = true
                    break
                end
            end
            if not inBlacklist then
                LogDebug(svar("Event received : {1}.{2}", { eventName, endpoint }), M._name)
                if BJIContext.DEBUG and tlength(data) > 0 then
                    PrintObj(data, svar("{1}.{2}", { eventName, endpoint }))
                end
            end

            ctrl:dispatchEvent(endpoint, data)
            break
        end
    end
end

local retrievingEvents = {}
local function tryFinalizingEvent(id)
    local event = retrievingEvents[id]
    if event then
        if not event.controller or event.parts > #event.data then
            -- not ready yet
            return
        end

        local dataStr = table.concat(event.data)
        local data = #dataStr > 0 and jsonDecode(dataStr) or {}
        data = parsePayload(data)
        dispatchEvent(event.controller, event.endpoint, data)
    end

    retrievingEvents[id] = nil
    BJIAsync.removeTask(svar("BJIRxEventTimeout-{1}", { id }))
end

local function retrieveEvent(rawData)
    local data = jsonDecode(rawData)
    if not data or type(data) ~= "table" or
        not data.id or not data.parts or
        not data.controller or not data.endpoint then
        PrintObj(data, "Invalid event")
        return
    end

    local event = retrievingEvents[data.id]
    if event then
        event.parts = data.parts
        event.controller = data.controller
        event.endpoint = data.endpoint
        if not event.data then
            event.data = {}
        end
    else
        retrievingEvents[data.id] = {
            parts = data.parts,
            controller = data.controller,
            endpoint = data.endpoint,
            data = {},
        }
    end
    if data.parts == 0 then
        tryFinalizingEvent(data.id)
    end
    if retrievingEvents[data.id] then
        BJIAsync.delayTask(function()
            retrievingEvents[data.id] = nil
        end, 30000, svar("BJIRxEventTimeout-{1}", { data.id }))
    end
end

local function retrieveEventPart(rawData)
    local data = jsonDecode(rawData)
    if not data or type(data) ~= "table" or
        not data.id or not data.part or
        not data.data then
        PrintObj(data, "Invalid event part")
        return
    end

    local event = retrievingEvents[data.id]
    if event then
        if event.data then
            event.data[data.part] = data.data
        else
            event.data = { [data.part] = data.data }
        end
    else
        retrievingEvents[data.id] = {
            data = { [data.part] = data.data }
        }
    end
    tryFinalizingEvent(data.id)
    if retrievingEvents[data.id] then
        BJIAsync.delayTask(function()
            retrievingEvents[data.id] = nil
        end, 30000, svar("BJIRxEventTimeout-{1}", { data.id }))
    end
end

AddEventHandler(BJI_EVENTS.SERVER_EVENT, retrieveEvent)
AddEventHandler(BJI_EVENTS.SERVER_EVENT_PARTS, retrieveEventPart)

M.initListeners = initListeners
M.dispatchEvent = dispatchEvent

RegisterBJIManager(M)
return M
