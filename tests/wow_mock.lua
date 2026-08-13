local Mock = {
    now = 1800000000,
    player = "TestOwner",
    realm = "TestRealm",
    inbox = {},
    frames = {},
    hooks = {},
    getInboxTextCalls = 0,
    markReadOnGetInboxText = true,
    deleteInboxCalls = 0,
}

function Mock.reset()
    Mock.now = 1800000000
    Mock.player = "TestOwner"
    Mock.realm = "TestRealm"
    Mock.inbox = {}
    Mock.popup = nil
    Mock.ambiguateQualifies = false
    Mock.getInboxTextCalls = 0
    Mock.markReadOnGetInboxText = true
    Mock.deleteInboxCalls = 0
    Mock.deletedInboxMail = nil
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
    local itemCount = mail.itemCount
    if itemCount == nil and mail.items then itemCount = #mail.items end
    if itemCount == nil then itemCount = mail.hasItem or 0 end
    return nil, nil, mail.sender, mail.subject, mail.money or 0,
        mail.CODAmount or 0, mail.daysLeft, itemCount,
        mail.wasRead or false, false, false, mail.canReply ~= false, mail.isGM or false
end

function GetInboxText(index)
    local mail = Mock.inbox[index]
    Mock.getInboxTextCalls = Mock.getInboxTextCalls + 1
    if mail and Mock.markReadOnGetInboxText then mail.wasRead = true end
    return mail and mail.body or nil
end

local function NewUIObject(parent)
    local object = {
        events = {}, scripts = {}, children = {}, text = "", shown = true,
        width = 0, height = 0, checked = false, enabled = true, value = 0,
    }
    if parent and parent.children then table.insert(parent.children, object) end

    function object:RegisterEvent(event) self.events[event] = true end
    function object:SetScript(name, callback) self.scripts[name] = callback end
    function object:GetScript(name) return self.scripts[name] end
    function object:SetSize(width, height) self.width, self.height = width, height end
    function object:SetWidth(width) self.width = width end
    function object:SetHeight(height) self.height = height end
    function object:GetWidth() return self.width end
    function object:GetHeight() return self.height end
    function object:SetBackdrop(backdrop) self.backdrop = backdrop end
    function object:SetBackdropColor(...) self.backdropColor = {...} end
    function object:SetBackdropBorderColor(...) self.backdropBorderColor = {...} end
    function object:SetTextColor(...) self.textColor = {...} end
    function object:SetText(text) self.text = tostring(text or "") end
    function object:GetText() return self.text end
    function object:SetFormattedText(format, ...) self.text = string.format(format, ...) end
    function object:GetNumLetters() return #self.text end
    function object:SetChecked(checked) self.checked = checked and true or false end
    function object:GetChecked() return self.checked end
    function object:SetValue(value)
        self.value = value
        if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, value) end
    end
    function object:GetValue() return self.value end
    function object:Enable() self.enabled = true end
    function object:Disable() self.enabled = false end
    function object:IsEnabled() return self.enabled end
    function object:GetChildren() return unpack(self.children) end
    function object:SetParent(newParent) self.parent = newParent end
    function object:IsShown() return self.shown end
    function object:Show()
        local changed = not self.shown
        self.shown = true
        if changed and self.scripts.OnShow then self.scripts.OnShow(self) end
    end
    function object:Hide()
        self.shown = false
        if self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    function object:GetStringHeight()
        local width = math.max(1, self.width)
        local lines = math.max(1, math.ceil(#self.text / math.max(1, math.floor(width / 7))))
        return lines * 14
    end
    function object:CreateFontString() return NewUIObject(self) end
    function object:CreateTexture() return NewUIObject(self) end

    setmetatable(object, {
        __index = function(_, key)
            if key == "parchmentBase" or key == "parchmentArt" then return nil end
            return function() end
        end,
    })
    return object
end

UIParent = NewUIObject()
UIParent:SetSize(1920, 1080)
GameFontHighlight = {}
UISpecialFrames = {}

function CreateFrame(_, name, parent)
    local frame = NewUIObject(parent)
    if name then _G[name] = frame end
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
function StaticPopup_Show(name, textArg1, textArg2, data)
    Mock.popup = {name = name, textArg1 = textArg1, textArg2 = textArg2, data = data}
end

SlashCmdList = {}
DEFAULT_CHAT_FRAME = {AddMessage = function() end}
UIErrorsFrame = {AddMessage = function() end}

function GetInboxItem(index, slot)
    local item = Mock.inbox[index] and Mock.inbox[index].items and Mock.inbox[index].items[slot]
    if not item then return nil end
    return item.name, item.itemID, item.texture, item.count or 1
end

function GetInboxItemLink(index, slot)
    local item = Mock.inbox[index] and Mock.inbox[index].items and Mock.inbox[index].items[slot]
    return item and (item.link or item.name) or nil
end

function InboxItemCanDelete(index)
    local mail = Mock.inbox[index]
    return mail ~= nil and mail.canDelete ~= false
end

function DeleteInboxItem(index)
    Mock.deleteInboxCalls = Mock.deleteInboxCalls + 1
    Mock.deletedInboxMail = table.remove(Mock.inbox, index)
end

return Mock
