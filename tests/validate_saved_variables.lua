local savePath = assert(arg[1], "usage: lua tests/validate_saved_variables.lua <Cartas.lua SavedVariables>")
local Mock = dofile("tests/wow_mock.lua")
dofile(savePath)

local stores = {"mails", "incoming", "archive"}
local before = {}

local function copyRecord(record)
    local result = {}
    for key, value in pairs(record) do
        if type(value) ~= "table" then result[key] = value end
    end
    return result
end

for _, name in ipairs(stores) do
    before[name] = {count = #(CartasDB[name] or {}), records = {}}
    for index, record in ipairs(CartasDB[name] or {}) do
        before[name].records[index] = copyRecord(record)
    end
end

CartasTestMode = true
assert(loadfile("Cartas.lua"))("Cartas")
local API = assert(CartasTestAPI)
API.EnsureDB()
API.EnsureArchive()
local duplicateCandidates = API.AuditArchiveDuplicates()
local technicalAliases = API.BuildTechnicalDuplicateAliases(CartasDB.archive)
local technicalDuplicateCount = 0
for _ in pairs(technicalAliases) do technicalDuplicateCount = technicalDuplicateCount + 1 end

local ownerSet, owners = {}, {}
local function addOwner(owner)
    if owner and owner ~= "" and not ownerSet[owner] then
        ownerSet[owner] = true
        table.insert(owners, owner)
    end
end
for _, mail in ipairs(CartasDB.mails) do addOwner(mail.owner or mail.sender) end
for _, mail in ipairs(CartasDB.archive) do addOwner(mail.owner or mail.recipient) end
table.sort(owners)

local groupedParticipants, groupedThreads = 0, 0
for _, owner in ipairs(owners) do
    Mock.player = owner
    local correspondence = API.GetAllCorrespondence()
    local participants = API.BuildParticipantGroups(correspondence)
    local groupedMessages = 0
    groupedParticipants = groupedParticipants + #participants
    for _, participant in ipairs(participants) do
        groupedThreads = groupedThreads + #participant.threads
        for _, thread in ipairs(participant.threads) do
            groupedMessages = groupedMessages + #thread.messages
        end
    end
    assert(groupedMessages == #correspondence, owner .. " grouping lost correspondence rows")
end

local excludedSystem = 0
for _, mail in ipairs(CartasDB.archive) do
    if not API.IsConversationMail(mail) then excludedSystem = excludedSystem + 1 end
end

for _, name in ipairs(stores) do
    local current = CartasDB[name] or {}
    assert(#current >= before[name].count, name .. " lost records")
    for index, old in ipairs(before[name].records) do
        local record = assert(current[index], name .. " record " .. index .. " disappeared")
        for key, value in pairs(old) do
            local preservedByTimestampRepair =
                (key == "timestamp" and record._timestampBeforeExpiryFix == value) or
                (key == "date" and record._dateBeforeExpiryFix == value)
            assert(record[key] == value or preservedByTimestampRepair,
                name .. " record " .. index .. " changed field " .. tostring(key))
        end
    end
end

io.write(string.format(
    "SavedVariables OK: mails=%d incoming=%d archive=%d mailboxes=%d participant_groups=%d threads=%d system_excluded=%d possible_duplicates=%d technical_aliases=%d\n",
    #CartasDB.mails, #CartasDB.incoming, #CartasDB.archive, #owners,
    groupedParticipants, groupedThreads, excludedSystem, duplicateCandidates, technicalDuplicateCount
))
