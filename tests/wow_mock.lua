local Mock = {
    now = 1800000000,
    player = "TestOwner",
    realm = "TestRealm",
    inbox = {},
    frames = {},
    hooks = {},
}

function Mock.reset()
    Mock.now = 1800000000
    Mock.player = "TestOwner"
    Mock.realm = "TestRealm"
    Mock.inbox = {}
    Mock.popup = nil
    Mock.ambiguateQualifies = false
end

function Mock.trigger(event)
    for _, frame in ipairs(Mock.frames) do
        if frame.events[event] and frame.scripts.OnEvent then
            frame.scripts.OnEvent(frame, event)
        end
    end
end

function Mock.callHook(name, ...)
    for _, callback in ipairs(Mock.hooks[name] or {}) do
        callback(...)
    end
end

CartasTestMode = true
CartasDB = {}
CorrespondenciaDB = nil

function strtrim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function Ambiguate(name, context)
    if Mock.ambiguateQualifies and context == "none" and name and not name:find("-", 1, true) then
        return name .. "-" .. Mock.realm
    end
    return name
end

function UnitName(unit)
    if unit == "player" then return Mock.player end
end

function GetNormalizedRealmName()
    return Mock.realm
end

function GetRealmName()
    return Mock.realm
end

function GetServerTime()
    return Mock.now
end

function time()
    return Mock.now
end

function date(format, timestamp)
    return os.date(format, timestamp)
end

function wipe(target)
    for key in pairs(target) do target[key] = nil end
    return target
end

function GetInboxNumItems()
    return #Mock.inbox, #Mock.inbox
end

function GetInboxHeaderInfo(index)
    local mail = Mock.inbox[index]
    if not mail then return nil end
    return nil, nil, mail.sender, mail.subject, mail.money or 0,
        mail.CODAmount or 0, mail.daysLeft, mail.hasItem or 0,
        mail.wasRead or false, false, false, mail.canReply ~= false, mail.isGM or false
end

function GetInboxText(index)
    local mail = Mock.inbox[index]
    return mail and mail.body or nil
end

function CreateFrame()
    local frame = {events = {}, scripts = {}}
    function frame:RegisterEvent(event) self.events[event] = true end
    function frame:SetScript(name, callback) self.scripts[name] = callback end
    table.insert(Mock.frames, frame)
    return frame
end

function hooksecurefunc(name, callback)
    Mock.hooks[name] = Mock.hooks[name] or {}
    table.insert(Mock.hooks[name], callback)
end

C_Timer = {
    After = function(_, callback) callback() end,
}

StaticPopupDialogs = {}
function StaticPopup_Show(name, _, _, data)
    Mock.popup = {name = name, data = data}
end

SlashCmdList = {}
DEFAULT_CHAT_FRAME = {AddMessage = function() end}

return Mock
