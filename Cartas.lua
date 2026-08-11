local ADDON_NAME = ...
-- v1.9.0: data-safe history, partial character search and local test hooks.
CartasDB = CartasDB or {}

local MAIL_SUBJECT_MAX_LETTERS = 64
local MAIL_BODY_MAX_LETTERS = 500
local MAIL_REPLY_PREFIX = "RE: "
local NORMAL_MAIL_EXPIRY_DAYS = 31
local COD_MAIL_EXPIRY_DAYS = 3

-- Migrate data from the previous addon name without losing existing letters.
if CorrespondenciaDB and not CartasDB.migratedFromCorrespondencia then
    CartasDB.mails = CartasDB.mails or CorrespondenciaDB.mails or {}
    CartasDB.incoming = CartasDB.incoming or CorrespondenciaDB.incoming or {}
    CartasDB.migratedFromCorrespondencia = true
end

local pendingMail = nil
local activeCompose = nil
local activeMailRefresh = nil

local function EnsureDB()
    CartasDB = CartasDB or {}
    CartasDB.mails = CartasDB.mails or {}
    CartasDB.incoming = CartasDB.incoming or {}
    -- archive is the permanent historical store.  It is NEVER rebuilt from
    -- the current Blizzard inbox and NEVER pruned when a mail disappears.
    CartasDB.archive = CartasDB.archive or {}
    CartasDB.nextSequence = CartasDB.nextSequence or 0
    CartasDB.seen = CartasDB.seen or {}
    CartasDB.deletedArchive = CartasDB.deletedArchive or {}
end

local function CleanName(name)
    if not name then return "" end
    return Ambiguate(name, "none") or name
end

local function CurrentRealm()
    if type(GetNormalizedRealmName) == "function" then
        return GetNormalizedRealmName() or ""
    end
    if type(GetRealmName) == "function" then
        return (GetRealmName() or ""):gsub("%s+", "")
    end
    return ""
end

-- Use WoW's synchronized server clock for message timestamps.  time() is tied
-- to the player's local machine clock and can be offset from the mailbox/server.
local function NowTimestamp()
    if GetServerTime then
        return GetServerTime()
    end
    return time()
end

local function NormalizeMailSubject(subject)
    return strtrim(subject or "")
end

local function EstimateMailTimestamp(daysLeft, CODAmount, referenceTime)
    -- Retail can report newly received normal mail with daysLeft in the 30.x
    -- range. Treating 30 as the full horizon reconstructs a timestamp in the
    -- future and separates incoming replies from outgoing messages by a day.
    local expiryDays = (CODAmount and CODAmount > 0) and COD_MAIL_EXPIRY_DAYS or NORMAL_MAIL_EXPIRY_DAYS
    local now = referenceTime or NowTimestamp()
    local timestamp = now
    if type(daysLeft) == "number" then
        local remainingDays = math.max(0, math.min(daysLeft, expiryDays))
        timestamp = now - ((expiryDays - remainingDays) * 86400)
    end
    return math.floor(timestamp + 0.5)
end

local function RepairImpossibleFutureTimestamps()
    EnsureDB()
    local repaired = 0

    for _, mail in ipairs(CartasDB.archive) do
        local timestamp = tonumber(mail.timestamp)
        local firstSeenAt = tonumber(mail._firstSeenAt)

        -- A received letter cannot have been sent after Cartas first observed
        -- it. Versions through rc7 used a 30-day horizon, so affected records
        -- are exactly one day ahead of the corrected 31-day estimate.
        if timestamp and firstSeenAt and timestamp > firstSeenAt + 300 then
            local corrected = math.min(timestamp - 86400, firstSeenAt)
            mail._timestampBeforeExpiryFix = mail._timestampBeforeExpiryFix or timestamp
            mail._dateBeforeExpiryFix = mail._dateBeforeExpiryFix or mail.date
            mail._timestampRepair = mail._timestampRepair or "normal-expiry-31"
            mail.timestamp = corrected
            mail.date = date("%Y-%m-%d %H:%M:%S", corrected)
            repaired = repaired + 1
        end
    end

    return repaired
end

-- Blizzard does not expose a persistent mail ID through GetInboxHeaderInfo().
-- We therefore use the reconstructed creation time (from daysLeft) together with
-- sender/subject as the stable fingerprint. This also fixes two different mails
-- that have the same sender and subject but were sent at different times.
local function IncomingKey(sender, subject, timestamp, body, suffix)
    local base = (sender or "") .. "\031" .. NormalizeMailSubject(subject)
    if body and body ~= "" then
        base = base .. "\031B:" .. body
    else
        base = base .. "\031T:" .. tostring(timestamp or 0)
    end
    if suffix then base = base .. "\031N:" .. tostring(suffix) end
    return base
end

local function CopyMail(mail)
    local copy = {}
    for k, v in pairs(mail or {}) do copy[k] = v end
    return copy
end

local function MigrateCorrespondencia()
    if type(CorrespondenciaDB) ~= "table" or CartasDB.migratedFromCorrespondenciaV2 then return 0 end
    EnsureDB()

    local imported = 0
    local function AppendStore(target, source)
        if type(source) ~= "table" or target == source then return end
        for _, mail in ipairs(source) do
            table.insert(target, CopyMail(mail))
            imported = imported + 1
        end
    end

    AppendStore(CartasDB.mails, CorrespondenciaDB.mails)
    AppendStore(CartasDB.incoming, CorrespondenciaDB.incoming)
    AppendStore(CartasDB.archive, CorrespondenciaDB.archive)

    for key, value in pairs(CorrespondenciaDB.seen or {}) do
        if CartasDB.seen[key] == nil then CartasDB.seen[key] = value end
    end
    for key, value in pairs(CorrespondenciaDB.deletedArchive or {}) do
        if CartasDB.deletedArchive[key] == nil then CartasDB.deletedArchive[key] = value end
    end
    CartasDB.nextSequence = math.max(
        tonumber(CartasDB.nextSequence) or 0,
        tonumber(CorrespondenciaDB.nextSequence) or 0
    )

    -- Preserve top-level metadata from the old addon without replacing any
    -- value already owned by Cartas.
    for key, value in pairs(CorrespondenciaDB) do
        if CartasDB[key] == nil then CartasDB[key] = value end
    end

    CartasDB.migratedFromCorrespondenciaV2 = true
    return imported
end

MigrateCorrespondencia()

local function NextSequence()
    EnsureDB()
    local highest = tonumber(CartasDB.nextSequence) or 0
    for _, store in ipairs({CartasDB.mails, CartasDB.incoming, CartasDB.archive}) do
        for _, mail in ipairs(store) do
            highest = math.max(highest, tonumber(mail.sequence) or 0)
        end
    end
    CartasDB.nextSequence = highest + 1
    return CartasDB.nextSequence
end

local function FindArchiveByIdentity(owner, sender, subject, timestamp, body)
    EnsureDB()
    local cleanSender = CleanName(sender)
    local normalizedSubject = NormalizeMailSubject(subject)
    local best, bestDelta

    for _, mail in ipairs(CartasDB.archive) do
        if (mail.owner or mail.recipient or "") == (owner or "")
            and CleanName(mail.sender) == cleanSender
            and NormalizeMailSubject(mail.subject) == normalizedSubject then
            local mt = tonumber(mail.timestamp)
            if mt and timestamp then
                local delta = math.abs(mt - timestamp)
                local sameBody = body and body ~= "" and mail.body and mail.body ~= "" and mail.body == body
                if delta <= 180 and (not body or body == "" or sameBody)
                    and (not bestDelta or delta < bestDelta) then
                    best, bestDelta = mail, delta
                end
            end
        end
    end
    return best
end

local function EnsureArchive()
    EnsureDB()

    -- One-time migration from the old incoming cache.  From now on, archive
    -- is authoritative.  Nothing in the live Blizzard inbox can delete from it.
    local archivedKeys = {}
    for _, old in ipairs(CartasDB.archive) do
        if old.key then archivedKeys[old.key] = true end
    end

    for _, mail in ipairs(CartasDB.incoming) do
        local owner = mail.owner or mail.recipient or UnitName("player") or ""
        local importKey = mail.key or IncomingKey(mail.sender, mail.subject, mail.timestamp, mail.body, mail.sequence)
        -- Persist the derived key in the legacy cache. Without this, a legacy
        -- record without a key would be imported again on every refresh.
        mail.key = importKey
        local found = archivedKeys[importKey]
        local deleted = CartasDB.deletedArchive[importKey]
        if not found and not deleted then
            local copy = CopyMail(mail)
            copy.owner = owner
            copy.key = importKey
            table.insert(CartasDB.archive, copy)
            archivedKeys[importKey] = true
        end
    end
end

local function AuditArchiveDuplicates()
    EnsureDB()
    if #CartasDB.archive < 2 then return 0 end

    local candidates = 0
    local seen = {}

    -- This is intentionally an audit only. Blizzard exposes no persistent mail
    -- ID, so even two byte-identical letters sent seconds apart may be valid.
    -- Automatic deduplication is therefore destructive and must never run.
    for i = #CartasDB.archive, 1, -1 do
        local mail = CartasDB.archive[i]
        local owner = mail.owner or mail.recipient or ""
        local sender = CleanName(mail.sender)
        local subject = NormalizeMailSubject(mail.subject)
        local body = strtrim(mail.body or "")
        if body ~= "" then
            local key = owner .. "\031" .. sender .. "\031" .. subject .. "\031" .. body
            local previous = seen[key]
            if previous then
                local t1 = tonumber(mail.timestamp) or 0
                local t2 = tonumber(previous.timestamp) or 0
                if math.abs(t1 - t2) <= 10 then
                    candidates = candidates + 1
                end
            else
                seen[key] = mail
            end
        end
    end

    return candidates
end

local function NewArchiveMail(owner, sender, subject, timestamp, wasRead, money, hasItem, canReply, isGM, daysLeft, slot, observedAt)
    EnsureDB()
    local sequence = NextSequence()
    local cleanSender = CleanName(sender)
    local observed = observedAt or NowTimestamp()
    local mail = {
        sequence = sequence,
        key = IncomingKey(cleanSender, subject, timestamp, "", sequence),
        recipient = owner, owner = owner, sender = cleanSender,
        ownerRealm = CurrentRealm(),
        subject = subject or "", body = "", timestamp = timestamp,
        date = date("%Y-%m-%d %H:%M:%S", timestamp), daysLeft = daysLeft,
        direction = "in", isNew = not wasRead, wasRead = wasRead and true or false,
        money = money or 0, hasItem = hasItem or 0,
        canReply = canReply and true or false, isGM = isGM and true or false,
        _lastInboxIndex = slot,
        _firstSeenAt = observed,
        _lastSeenAt = observed,
        _lastInboxRank = slot,
    }
    table.insert(CartasDB.archive, mail)
    return mail
end

-- Find an existing historical record for a currently visible inbox row.
-- Matching is deliberately one-to-one so two mails with the same sender and
-- subject are still stored as two separate historical messages.
local function FindLiveArchiveMatch(owner, sender, subject, timestamp, used, slot, daysLeft)
    local cleanSender = CleanName(sender)
    local normalizedSubject = NormalizeMailSubject(subject)
    local best, bestDelta, bestIndexDelta

    -- IMPORTANT: the Blizzard inbox index is NOT a stable message identity.
    -- When a new letter arrives, every older letter can move one or more slots.
    -- Older versions gave the slot an overwhelming weight, which could make a
    -- new reply inherit the timestamp/body of the letter that used to occupy
    -- that slot. That is the source of the apparently impossible chronology.
    --
    -- Use the reconstructed mail timestamp as the primary identity instead.
    -- daysLeft is fractional, so the timestamp is precise enough to distinguish
    -- letters sent seconds/minutes apart. The slot is only a tie-breaker.
    for _, mail in ipairs(CartasDB.archive) do
        if not used[mail] and (mail.owner or mail.recipient or "") == owner
            and CleanName(mail.sender) == cleanSender
            and NormalizeMailSubject(mail.subject) == normalizedSubject then
            local mt = tonumber(mail.timestamp)
            if mt and timestamp then
                local delta = math.abs(mt - timestamp)
                local indexDelta = math.abs((mail._lastInboxIndex or slot or 0) - (slot or 0))
                if not bestDelta or delta < bestDelta or (delta == bestDelta and indexDelta < bestIndexDelta) then
                    best, bestDelta, bestIndexDelta = mail, delta, indexDelta
                end
            elseif not best then
                best = mail
                bestIndexDelta = math.abs((mail._lastInboxIndex or slot or 0) - (slot or 0))
            end
        end
    end

    -- Never reuse a distant record merely because sender+subject match. A
    -- different letter with the same subject must become a new archive record.
    if bestDelta and bestDelta <= 300 then
        return best
    end

    -- If the timestamp is no longer trustworthy for this inbox row, prefer the
    -- same archive record that occupied this slot on the previous scan. This is
    -- only a fallback; timestamp matching above remains the primary identity.
    local slotMatch
    for _, mail in ipairs(CartasDB.archive) do
        if not used[mail]
            and (mail.owner or mail.recipient or "") == (UnitName("player") or "")
            and CleanName(mail.sender) == cleanSender
            and NormalizeMailSubject(mail.subject) == normalizedSubject
            and mail._lastInboxIndex == slot then
            slotMatch = mail
            break
        end
    end
    if slotMatch then
        return slotMatch
    end

    return nil
end

local function SaveIncomingMail(index, used, scanNow)
    EnsureDB()
    local packageIcon, stationeryIcon, sender, subject, money, CODAmount, daysLeft,
          hasItem, wasRead, wasReturned, textCreated, canReply, isGM = GetInboxHeaderInfo(index)
    if not sender or sender == "" then return end

    local owner = UnitName("player") or ""
    -- Use one timestamp for the whole scan.  The old code called time() once per
    -- inbox row, which fabricated one-second differences between mails that had
    -- actually been observed in the same scan.
    local timestamp = EstimateMailTimestamp(daysLeft, CODAmount, scanNow)
    local existing = FindLiveArchiveMatch(owner, sender, subject, timestamp, used or {}, index, daysLeft)

    if not existing then
        existing = NewArchiveMail(owner, sender, subject, timestamp, wasRead, money, hasItem, canReply, isGM, daysLeft, index, scanNow)
    else
        used[existing] = true
        existing.daysLeft = daysLeft
        existing.wasRead = wasRead and true or false
        existing.isNew = not wasRead
        existing.money = money or existing.money or 0
        existing.hasItem = hasItem or existing.hasItem or 0
        if type(canReply) == "boolean" then existing.canReply = canReply end
        if type(isGM) == "boolean" then existing.isGM = isGM end
        existing._lastInboxIndex = index
        existing._lastInboxRank = index
        existing._lastSeenAt = scanNow or time()
    end

    -- Never request an unread body during a background scan. In WoW,
    -- GetInboxText() may transition the live message to read. Once Blizzard
    -- already reports it as read, preserving the loaded body is safe.
    if wasRead and type(GetInboxText) == "function" then
        local loadedBody = GetInboxText(index)
        if loadedBody and loadedBody ~= "" then
            existing.body = loadedBody
        end
    end

    if used then used[existing] = true end

    -- Keep the legacy incoming cache only as a migration aid.  It is never the
    -- source of truth and deleting a Blizzard mail cannot delete archive data.
    local cacheFound
    for _, mail in ipairs(CartasDB.incoming) do
        if mail.key == existing.key then cacheFound = mail break end
    end
    if not cacheFound then
        table.insert(CartasDB.incoming, CopyMail(existing))
    else
        for k, v in pairs(existing) do cacheFound[k] = v end
    end
    return existing
end

local function ScanInbox()
    EnsureDB()
    EnsureArchive()
    RepairImpossibleFutureTimestamps()
    AuditArchiveDuplicates()
    if not GetInboxNumItems or not GetInboxHeaderInfo then return end
    local count = GetInboxNumItems() or 0
    local used = {}
    local scanNow = NowTimestamp()
    for i = 1, count do
        SaveIncomingMail(i, used, scanNow)
    end
    -- IMPORTANT: there is intentionally NO cleanup pass here.
    -- Blizzard removing/expiring a mail only removes it from the live inbox.
    -- CartasDB.archive remains untouched forever.
end

local function SavePendingMail()
    if not pendingMail then return end
    EnsureDB()

    local sequence = NextSequence()
    local timestamp = NowTimestamp()
    table.insert(CartasDB.mails, {
        sequence = sequence,
        recipient = pendingMail.recipient or "",
        owner = UnitName("player") or "",
        ownerRealm = CurrentRealm(),
        subject = pendingMail.subject or "",
        body = pendingMail.body or "",
        timestamp = timestamp,
        date = date("%Y-%m-%d %H:%M:%S", timestamp),
        sender = UnitName("player") or "",
    })

    pendingMail = nil
end

-- SendMail(recipient, subject, body) exposes the complete body to the addon.
-- We only save it after MAIL_SEND_SUCCESS so failed sends are not archived.
hooksecurefunc("SendMail", function(recipient, subject, body)
    pendingMail = {
        recipient = CleanName(recipient),
        subject = subject or "",
        body = body or "",
    }
end)

local frame = CreateFrame("Frame")
frame:RegisterEvent("MAIL_SEND_SUCCESS")
frame:RegisterEvent("MAIL_INBOX_UPDATE")
frame:SetScript("OnEvent", function(self, event)
    if event == "MAIL_SEND_SUCCESS" then
        SavePendingMail()
    elseif event == "MAIL_INBOX_UPDATE" then
        -- MAIL_INBOX_UPDATE fires when the inbox is loaded or a message is opened/read.
        ScanInbox()
        if activeMailRefresh then activeMailRefresh() end
    end
end)

local function PrintLine(text)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[Cartas]|r " .. text)
end

local function FormatDate(ts)
    if not ts then return "Fecha desconocida" end
    return date("%d/%m/%Y %H:%M", ts)
end

local function ShowMail(mail, index)
    print(" ")
    print("|cff66ccff--- Cartas #" .. index .. " ---|r")
    print("|cffffffff" .. (mail.date or FormatDate(mail.timestamp)) .. " |r→ |cffFFD100" ..
        (mail.recipient or "?") .. "|r")
    if mail.subject and mail.subject ~= "" then
        print("|cffaaaaaaAsunto:|r " .. mail.subject)
    end
    print("|cffdddddd" .. (mail.body ~= "" and mail.body or "(abre la carta para ver el contenido)") .. "|r")
    print("|cff66ccff--------------------------------|r")
end

local function GetLiveInbox()
    local result = {}
    if not GetInboxNumItems or not GetInboxHeaderInfo then return result end

    local count = GetInboxNumItems() or 0
    for index = 1, count do
        local packageIcon, stationeryIcon, sender, subject, money, CODAmount, daysLeft,
              hasItem, wasRead, wasReturned, textCreated, canReply, isGM = GetInboxHeaderInfo(index)

        if sender and sender ~= "" then
            -- Header-only: do not request the body just to render the inbox list.
            local body = ""
            table.insert(result, {
                inboxIndex = index,
                sender = CleanName(sender),
                subject = subject or "",
                body = body,
                money = money or 0,
                CODAmount = CODAmount or 0,
                hasItem = hasItem and true or false,
                wasRead = wasRead and true or false,
                canReply = canReply and true or false,
                isGM = isGM and true or false,
                daysLeft = daysLeft,
            })
        end
    end

    return result
end

local function IsLiveInboxMailNew(live)
    return live ~= nil and not live.wasRead
end

local function GetSeenKey(owner, mail)
    return (owner or "") .. "\031" .. (mail.key or
        ((mail.sender or "") .. "\031" .. (mail.subject or "") .. "\031" .. (mail.body or "")))
end

local function IsMailNew(owner, mail)
    if mail.direction ~= "in" then return false end
    if mail.wasRead then return false end
    EnsureDB()
    return not CartasDB.seen[GetSeenKey(owner, mail)]
end

local function MarkMailSeen(owner, mail)
    if not mail or mail.direction ~= "in" then return end
    EnsureDB()
    CartasDB.seen[GetSeenKey(owner, mail)] = true
end

local function IsConversationMail(mail)
    if not mail then return false end
    if mail.direction == "out" then return true end

    -- Blizzard marks Auction House and other system mail as non-replyable,
    -- while Customer Support mail carries the GM flag. Keep these records in
    -- the archive and live inbox, but never present them as conversations.
    return mail.canReply ~= false and not mail.isGM
end

local function GetAllCorrespondence()
    EnsureDB()
    local all = {}
    local owner = UnitName("player") or ""

    -- Outgoing mail: sender is the character who wrote it.
    for _, mail in ipairs(CartasDB.mails) do
        local mailOwner = CleanName(mail.owner or mail.sender or "")
        if not mail.hidden and mailOwner == CleanName(owner) then
            local copy = {}
            for k, v in pairs(mail) do copy[k] = v end
            copy.direction = "out"
            copy.person = mail.recipient or ""
            table.insert(all, copy)
        end
    end

    -- Incoming mail comes from the persistent archive, NOT the live Blizzard inbox.
    -- Once archived, it remains visible even after Blizzard deletes/expirs the mail.
    EnsureArchive()
    RepairImpossibleFutureTimestamps()
    AuditArchiveDuplicates()
    for _, mail in ipairs(CartasDB.archive) do
        local mailOwner = CleanName(mail.owner or mail.recipient or "")
        if not mail.hidden and mailOwner == CleanName(owner) and IsConversationMail(mail) then
            local copy = {}
            for k, v in pairs(mail) do copy[k] = v end
            copy.direction = "in"
            copy.person = mail.sender or ""
            copy.isNew = IsMailNew(owner, copy)
            table.insert(all, copy)
        end
    end

    table.sort(all, function(a, b)
        local ta = tonumber(a.timestamp) or 0
        local tb = tonumber(b.timestamp) or 0
        if ta == tb then
            return (a.sequence or 0) > (b.sequence or 0)
        end
        return ta > tb
    end)

    return all
end

local function NormalizeSearchName(name)
    name = strtrim(name or "")
    if name == "" then return "" end
    -- Never pass user-entered partial text to Ambiguate(). In mail context WoW
    -- can qualify it with the current realm, turning a partial name into a
    -- value that cannot match a longer character name on another realm.
    return name:lower():gsub("%s+", "")
end

local function SplitSearchName(name)
    local normalized = NormalizeSearchName(name)
    local character, realm = normalized:match("^([^%-]+)%-(.+)$")
    return normalized, character or normalized, realm
end

local function MailMatchesPerson(mail, targetLower)
    if not targetLower or targetLower == "" then return true end

    -- `mail.person` is the counterpart of the correspondence row: for an
    -- outgoing letter it is the recipient, and for an incoming letter it is
    -- the sender. Do NOT search sender/recipient/owner independently here.
    -- Older saved records can contain those fields with the mailbox owner or
    -- stale metadata, which caused a search for "flor" to pull unrelated
    -- messages from the mailbox owner into the results.
    local candidate, candidateCharacter, candidateRealm = SplitSearchName(mail.person)
    local target, targetCharacter, targetRealm = SplitSearchName(targetLower)
    if candidate == "" or target == "" then return false end

    -- A query without realm searches only the character component. This makes
    -- prefixes and partial names work across realms. The search is literal,
    -- not a Lua pattern, so punctuation cannot cause malformed-pattern errors.
    if not targetRealm then
        return candidateCharacter:find(targetCharacter, 1, true) ~= nil
    end

    return candidateCharacter:find(targetCharacter, 1, true) ~= nil
        and candidateRealm ~= nil
        and candidateRealm:find(targetRealm, 1, true) ~= nil
end

local function HasReplyPrefixChain(subject)
    local value = strtrim(subject or "")
    if value:match("^[Rr][Ee]%s*:") then return true end
    local remainder = value:match("^[Rr][Ee]%s+(.+)$")
    return remainder ~= nil and HasReplyPrefixChain(remainder)
end

local function AnalyzeThreadSubject(subject)
    local value = strtrim(subject or "")
    local replyDepth = 0
    local hasThreadPrefix = false
    local changed = true

    while changed do
        changed = false

        -- Standard replies are "RE:", but some clients/addons produce chains
        -- such as "RE RE:". Consume the missing-colon tokens only when they
        -- lead to another RE token with a colon, so a real subject beginning
        -- with words like "Re encuentro" is not altered.
        local afterReply = value:match("^%s*[Rr][Ee]%s*:%s*(.*)$")
        if afterReply then
            value = strtrim(afterReply)
            replyDepth = replyDepth + 1
            hasThreadPrefix = true
            changed = true
        else
            local afterRepeatedReply = value:match("^%s*[Rr][Ee]%s+(.+)$")
            if afterRepeatedReply and HasReplyPrefixChain(afterRepeatedReply) then
                value = strtrim(afterRepeatedReply)
                replyDepth = replyDepth + 1
                hasThreadPrefix = true
                changed = true
            else
                local afterForward = value:match("^%s*[Ff][Ww]%s*:%s*(.*)$")
                if afterForward then
                    value = strtrim(afterForward)
                    hasThreadPrefix = true
                    changed = true
                end
            end
        end
    end

    return value ~= "" and value or "(Sin asunto)", replyDepth, hasThreadPrefix
end

local function NormalizeThreadSubject(subject)
    local base = AnalyzeThreadSubject(subject)
    return base
end

local function BuildThreadKey(subject, person)
    return NormalizeThreadSubject(subject):lower() .. "\031" .. NormalizeSearchName(person)
end

local function CountUTF8Characters(value)
    local text = tostring(value or "")
    local _, continuationBytes = text:gsub("[\128-\191]", "")
    return #text - continuationBytes
end

local function TruncateUTF8Characters(value, maxLetters)
    local text = tostring(value or "")
    local limit = math.max(0, tonumber(maxLetters) or 0)
    if CountUTF8Characters(text) <= limit then return text end

    local character = 0
    for byteIndex = 1, #text do
        local byte = text:byte(byteIndex)
        if byte < 128 or byte >= 192 then
            character = character + 1
            if character > limit then
                return text:sub(1, byteIndex - 1)
            end
        end
    end
    return text
end

local function BuildReplySubject(subject)
    local base = NormalizeThreadSubject(subject)
    local prefixed = MAIL_REPLY_PREFIX .. base
    if CountUTF8Characters(prefixed) <= MAIL_SUBJECT_MAX_LETTERS then
        return prefixed
    end

    -- At 61-64 characters, retaining the exact base keeps the message in the
    -- same conversation. WoW's field cannot fit both that base and "RE: ".
    return TruncateUTF8Characters(base, MAIL_SUBJECT_MAX_LETTERS)
end

local function ValidateOutgoingMailText(subject, body)
    if CountUTF8Characters(subject) > MAIL_SUBJECT_MAX_LETTERS then
        return false, "Cartas: el asunto supera 64 caracteres."
    end
    if CountUTF8Characters(body) > MAIL_BODY_MAX_LETTERS then
        return false, "Cartas: la carta supera 500 caracteres."
    end
    return true
end

local function ReplyLevel(subject)
    local _, depth = AnalyzeThreadSubject(subject)
    return depth
end

local function IsReplySubject(subject)
    local _, _, hasThreadPrefix = AnalyzeThreadSubject(subject)
    return hasThreadPrefix
end

local function BuildThreadChain(messages)
    for _, mail in ipairs(messages) do
        mail.replyDepth = ReplyLevel(mail.subject)
    end

    table.sort(messages, function(a, b)
        local timestampA = tonumber(a.timestamp) or 0
        local timestampB = tonumber(b.timestamp) or 0
        if timestampA ~= timestampB then return timestampA < timestampB end

        local sequenceA = tonumber(a.sequence) or 0
        local sequenceB = tonumber(b.sequence) or 0
        if sequenceA ~= sequenceB then return sequenceA < sequenceB end

        local depthA = tonumber(a.replyDepth) or 0
        local depthB = tonumber(b.replyDepth) or 0
        if depthA ~= depthB then return depthA < depthB end

        return tostring(a.subject or "") < tostring(b.subject or "")
    end)
    return messages
end

local function BuildParticipantGroups(all, targetLower)
    local participants, participantMap = {}, {}

    for _, mail in ipairs(all or {}) do
        if MailMatchesPerson(mail, targetLower) then
            local participantName = mail.person or ""
            local participantKey = NormalizeSearchName(participantName)
            if participantKey == "" then
                participantKey = "\030unknown"
                participantName = "Desconocido"
            end

            local participant = participantMap[participantKey]
            if not participant then
                participant = {
                    key = participantKey,
                    name = participantName,
                    threads = {},
                    threadMap = {},
                    latest = 0,
                    messageCount = 0,
                    newCount = 0,
                }
                participantMap[participantKey] = participant
                table.insert(participants, participant)
            end

            local threadKey = BuildThreadKey(mail.subject, participantName)
            local thread = participant.threadMap[threadKey]
            if not thread then
                thread = {
                    key = threadKey,
                    subject = NormalizeThreadSubject(mail.subject),
                    messages = {},
                    latest = 0,
                    newCount = 0,
                }
                participant.threadMap[threadKey] = thread
                table.insert(participant.threads, thread)
            end

            local copy = {}
            for key, value in pairs(mail) do copy[key] = value end
            copy.isReply = IsReplySubject(mail.subject)
            table.insert(thread.messages, copy)

            local timestamp = tonumber(mail.timestamp) or 0
            thread.latest = math.max(thread.latest, timestamp)
            if mail.isNew then thread.newCount = thread.newCount + 1 end
            participant.latest = math.max(participant.latest, timestamp)
            participant.messageCount = participant.messageCount + 1
            if mail.isNew then participant.newCount = participant.newCount + 1 end
        end
    end

    for _, participant in ipairs(participants) do
        table.sort(participant.threads, function(a, b)
            if a.latest ~= b.latest then return a.latest > b.latest end
            return a.subject:lower() < b.subject:lower()
        end)
        participant.threadMap = nil
    end

    table.sort(participants, function(a, b)
        if a.latest ~= b.latest then return a.latest > b.latest end
        return a.name:lower() < b.name:lower()
    end)

    return participants
end

local function ShowHistory(target)
    local all = GetAllCorrespondence()
    local found = 0
    target = target and strtrim(target)
    local targetLower = target and NormalizeSearchName(target)

    if target then
        PrintLine("Historial con: " .. target)
    else
        PrintLine("Toda tu correspondencia:")
    end

    for _, mail in ipairs(all) do
        if MailMatchesPerson(mail, targetLower) then
            found = found + 1
            print(" ")
            local icon = mail.direction == "in" and "|cff66ff66📥 RECIBIDA|r" or "|cff66ccff📤 ENVIADA|r"
            print(icon .. " |cffFFD100" .. (mail.person or "?") .. "|r — " ..
                (mail.date or FormatDate(mail.timestamp)))
            if mail.subject and mail.subject ~= "" then
                print("|cffaaaaaaAsunto:|r " .. mail.subject)
            end
            print("|cffdddddd" .. (mail.body ~= "" and mail.body or "(abre la carta para ver el contenido)") .. "|r")
            print("|cff66ccff--------------------------------|r")
        end
    end

    if found == 0 then
        PrintLine(target and "No hay correspondencia guardada con ese personaje." or "No hay correspondencia guardada.")
    else
        PrintLine(found .. " mensaje(s) encontrado(s).")
    end
end

local function FindArchiveByBody(owner, sender, subject, body, timestamp)
    EnsureArchive()
    if not body or body == "" then return nil end
    owner = owner or UnitName("player") or ""
    local cleanSender = CleanName(sender)
    local normalizedSubject = NormalizeMailSubject(subject)

    -- Body is useful only together with the reconstructed timestamp. Identical
    -- content may legitimately be sent more than once.
    local best, bestDelta
    for _, mail in ipairs(CartasDB.archive) do
        if (mail.owner or mail.recipient or "") == owner
            and CleanName(mail.sender) == cleanSender
            and NormalizeMailSubject(mail.subject) == normalizedSubject
            and mail.body and mail.body ~= ""
            and mail.body == body then
            local mt = tonumber(mail.timestamp)
            if mt and timestamp then
                local delta = math.abs(mt - timestamp)
                if delta <= 300 and (not bestDelta or delta < bestDelta) then
                    best, bestDelta = mail, delta
                end
            end
        end
    end
    return best
end

local function FindIncomingRecord(owner, index, sender, subject, daysLeft, CODAmount)
    EnsureArchive()
    owner = owner or UnitName("player") or ""
    local timestamp = EstimateMailTimestamp(daysLeft, CODAmount)

    -- The inbox slot is deliberately NOT used as the primary identity. Slots
    -- shift whenever a new letter arrives, so matching by slot can attach a
    -- reply to the wrong historical letter. Match by the stable reconstructed
    -- timestamp instead.
    local candidates = {}
    local cleanSender = CleanName(sender)
    local normalizedSubject = NormalizeMailSubject(subject)
    for _, mail in ipairs(CartasDB.archive) do
        if (mail.owner or mail.recipient or "") == owner
            and CleanName(mail.sender) == cleanSender
            and NormalizeMailSubject(mail.subject) == normalizedSubject then
            local mt = tonumber(mail.timestamp)
            if mt and timestamp then
                local delta = math.abs(mt - timestamp)
                if delta <= 300 then
                    table.insert(candidates, {
                        mail = mail,
                        delta = delta,
                        indexDelta = math.abs((mail._lastInboxIndex or index or 0) - (index or 0)),
                        filled = (mail.body and mail.body ~= ""),
                    })
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        if a.delta == b.delta then
            if a.indexDelta ~= b.indexDelta then return a.indexDelta < b.indexDelta end
            if a.filled ~= b.filled then return a.filled end
            return (a.mail.sequence or 0) < (b.mail.sequence or 0)
        end
        return a.delta < b.delta
    end)
    return candidates[1] and candidates[1].mail or nil
end

local function CaptureInboxMail(index, onDone)
    if not GetInboxHeaderInfo or not GetInboxText then
        if onDone then onDone(nil) end
        return
    end

    -- Retail mail text is not guaranteed to be populated just because the
    -- header exists. With a large inbox, GetInboxText(index) can remain empty
    -- until Blizzard's mail UI has actually opened/requested that message.
    -- The old implementation only polled the empty value, so some users could
    -- get stuck forever at "(sin abrir)". We now explicitly ask Blizzard to
    -- open the exact inbox slot once, then wait for the body.
    local attempts = 0
    local requestedOpen = false
    local finished = false

    local function finish(mail)
        if finished then return end
        finished = true
        if onDone then onDone(mail) end
    end

    local function requestBlizzardOpen()
        if requestedOpen then return end
        requestedOpen = true

        -- Prefer Blizzard's mailbox-open routine if exposed by the current
        -- Retail client. Different builds expose different FrameXML helpers,
        -- so use whichever is available and never assume either one exists.
        local opener = nil
        if type(InboxFrame_OpenMail) == "function" then
            opener = InboxFrame_OpenMail
        elseif type(OpenMail) == "function" then
            opener = OpenMail
        end

        if opener then
            pcall(opener, index)
        end
    end

    local function captureWhenReady()
        if finished then return end
        attempts = attempts + 1

        local _, _, sender, subject, money, CODAmount, daysLeft, hasItem, wasRead,
              wasReturned, textCreated, canReply, isGM = GetInboxHeaderInfo(index)

        if not sender or sender == "" then
            finish(nil)
            return
        end

        local body = GetInboxText(index) or ""

        if body == "" then
            if attempts == 1 or attempts == 3 then
                requestBlizzardOpen()
            end

            -- Give Blizzard substantially more time than the old 1.5 seconds.
            -- A busy mailbox can take several update cycles to populate text.
            if attempts < 50 then
                C_Timer.After(0.12, captureWhenReady)
                return
            end
        end

        EnsureDB()
        EnsureArchive()

        local owner = UnitName("player") or ""
        local timestamp = EstimateMailTimestamp(daysLeft, CODAmount)

        -- Match the header record created for this exact inbox row before using
        -- content. Two legitimate messages may have identical sender, subject
        -- and body, so body alone is never a persistent identity.
        local mail = nil
        if not mail then
            mail = FindIncomingRecord(owner, index, sender, subject, daysLeft, CODAmount)
        end
        if not mail and body ~= "" then
            mail = FindArchiveByBody(owner, sender, subject, body, timestamp)
        end
        if not mail then
            mail = FindLiveArchiveMatch(owner, sender, subject, timestamp, {}, index, daysLeft)
        end
        if not mail then
            mail = FindArchiveByIdentity(owner, sender, subject, timestamp, body)
        end

        if not mail then
            local sequence = NextSequence()
            mail = {
                sequence = sequence,
                key = IncomingKey(CleanName(sender), subject, timestamp, body, sequence),
                recipient = owner,
                owner = owner,
                ownerRealm = CurrentRealm(),
                sender = CleanName(sender),
                subject = subject or "",
                body = body,
                timestamp = timestamp,
                date = date("%Y-%m-%d %H:%M:%S", timestamp),
                daysLeft = daysLeft,
                direction = "in",
                isNew = false,
                wasRead = true,
                _lastInboxIndex = index,
                _firstSeenAt = NowTimestamp(),
                _lastSeenAt = NowTimestamp(),
                _lastInboxRank = index,
            }
            table.insert(CartasDB.archive, mail)
        else
            if timestamp and (not mail.timestamp or math.abs((tonumber(mail.timestamp) or 0) - timestamp) <= 300) then
                mail.timestamp = timestamp
                mail.date = date("%Y-%m-%d %H:%M:%S", timestamp)
            end
            if body ~= "" then
                mail.body = body
            end
            mail.daysLeft = daysLeft
            mail.wasRead = true
            mail.isNew = false
            mail.money = money or mail.money or 0
            mail.hasItem = hasItem or mail.hasItem or 0
            if type(canReply) == "boolean" then mail.canReply = canReply end
            if type(isGM) == "boolean" then mail.isGM = isGM end
            mail._lastInboxIndex = index
            mail._lastInboxRank = index
            mail._lastSeenAt = NowTimestamp()
        end

        MarkMailSeen(owner, mail)
        mail.isNew = false
        mail.wasRead = true
        mail._lastInboxIndex = index

        finish(mail)
    end

    captureWhenReady()
end

local function GetInboxAttachments(index)
    local items = {}
    if not GetInboxItem or not GetInboxItemLink then return items end
    local max = ATTACHMENTS_MAX_RECEIVE or 16
    for slot = 1, max do
        local name, itemID, texture, count = GetInboxItem(index, slot)
        local link = GetInboxItemLink(index, slot)
        if name or link then
            table.insert(items, {
                slot = slot,
                name = name or "Objeto",
                itemID = itemID,
                texture = texture,
                count = count or 1,
                link = link,
            })
        end
    end
    return items
end

local function OpenCompose(recipient, subject, body)
    if activeCompose then
        activeCompose:Show()
        if recipient then activeCompose.to:SetText(recipient) end
        if subject then activeCompose.subject:SetText(subject) end
        if body then activeCompose.body:SetText(body) end
        return
    end

    local f = CreateFrame("Frame", "CartasComposeFrame", UIParent, "BackdropTemplate")
    activeCompose = f
    f:SetSize(620, 470)
    f:SetPoint("CENTER", 0, 10)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    f:SetBackdropColor(0.05, 0.05, 0.08, 0.98)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -15)
    title:SetText("Escribir carta")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    local function MakeEdit(label, y, maxLetters, rightInset)
        local l = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        l:SetPoint("TOPLEFT", 20, y + 2)
        l:SetText(label)
        local e = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        e:SetPoint("TOPLEFT", 90, y + 7)
        e:SetPoint("RIGHT", -(rightInset or 20), 0)
        e:SetHeight(28)
        e:SetAutoFocus(false)
        e:SetMaxLetters(maxLetters)
        return e
    end

    f.to = MakeEdit("Para:", -48, 255)
    f.subject = MakeEdit("Asunto:", -84, MAIL_SUBJECT_MAX_LETTERS, 80)

    local subjectCounter = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subjectCounter:SetPoint("LEFT", f.subject, "RIGHT", 8, 0)
    subjectCounter:SetWidth(52)
    subjectCounter:SetJustifyH("RIGHT")

    -- Área de contenido: marco propio para que el campo multilínea se vea
    -- realmente como un cuadro de escritura y no como una zona gris sin borde.
    local bodyBox = CreateFrame("Frame", nil, f, "BackdropTemplate")
    bodyBox:SetPoint("TOPLEFT", 20, -126)
    bodyBox:SetPoint("BOTTOMRIGHT", -20, 58)
    bodyBox:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    bodyBox:SetBackdropColor(0.025, 0.025, 0.035, 0.96)
    bodyBox:SetBackdropBorderColor(0.35, 0.35, 0.40, 1)

    local body = CreateFrame("EditBox", nil, bodyBox)
    f.body = body
    body:SetMultiLine(true)
    body:SetAutoFocus(false)
    body:SetMaxLetters(MAIL_BODY_MAX_LETTERS)
    body:SetPoint("TOPLEFT", 10, -10)
    body:SetPoint("BOTTOMRIGHT", -10, 26)
    body:SetFontObject(GameFontHighlight)
    body:SetTextInsets(2, 2, 2, 2)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")

    local bodyCounter = bodyBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bodyCounter:SetPoint("BOTTOMRIGHT", -10, 8)
    bodyCounter:SetJustifyH("RIGHT")

    local function BindCharacterCounter(editBox, counter, limit)
        local function RefreshCounter()
            local count = editBox.GetNumLetters and editBox:GetNumLetters()
                or CountUTF8Characters(editBox:GetText())
            counter:SetFormattedText("%d/%d", count, limit)
            if count >= limit then
                counter:SetTextColor(1, 0.25, 0.25)
            elseif count >= math.floor(limit * 0.9) then
                counter:SetTextColor(1, 0.82, 0)
            else
                counter:SetTextColor(0.65, 0.65, 0.65)
            end
        end
        editBox:SetScript("OnTextChanged", RefreshCounter)
        RefreshCounter()
    end

    BindCharacterCounter(f.subject, subjectCounter, MAIL_SUBJECT_MAX_LETTERS)
    BindCharacterCounter(f.body, bodyCounter, MAIL_BODY_MAX_LETTERS)

    local send = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    send:SetSize(120, 30)
    send:SetPoint("BOTTOMRIGHT", -20, 18)
    send:SetText("Enviar")
    send:SetScript("OnClick", function()
        local to = strtrim(f.to:GetText() or "")
        local subjectText = f.subject:GetText() or ""
        local bodyText = f.body:GetText() or ""
        if to == "" then
            UIErrorsFrame:AddMessage("Cartas: falta el destinatario.", 1, 0.2, 0.2, 1)
            return
        end
        if strtrim(subjectText) == "" then
            UIErrorsFrame:AddMessage("Cartas: falta el asunto.", 1, 0.2, 0.2, 1)
            return
        end
        local valid, validationError = ValidateOutgoingMailText(subjectText, bodyText)
        if not valid then
            UIErrorsFrame:AddMessage(validationError, 1, 0.2, 0.2, 1)
            return
        end
        SendMail(to, subjectText, bodyText)
        f:Hide()
    end)

    local cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    cancel:SetSize(120, 30)
    cancel:SetPoint("RIGHT", send, "LEFT", -8, 0)
    cancel:SetText("Cancelar")
    cancel:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnHide", function()
        -- Keep the frame for reuse; don't destroy it.
    end)

    f.to:SetText(recipient or "")
    f.subject:SetText(subject or "")
    f.body:SetText(body or "")
    f:Show()
end

EnsureDB()

local function DeleteArchivedMail(mail)
    if not mail or not CartasDB or not CartasDB.archive then return false end

    EnsureDB()
    local deletedKey = mail.key or ("SEQ:" .. tostring(mail.sequence or ""))
    CartasDB.deletedArchive[deletedKey] = true

    local removed = false
    local hiddenAt = NowTimestamp()
    for _, saved in ipairs(CartasDB.archive) do
        local matches = mail.key and saved.key == mail.key
            or (not mail.key and mail.sequence and saved.sequence == mail.sequence)
        if matches then
            saved.hidden = true
            saved.hiddenAt = hiddenAt
            removed = true
        end
    end

    for _, saved in ipairs(CartasDB.incoming) do
        local matches = mail.key and saved.key == mail.key
            or (not mail.key and mail.sequence and saved.sequence == mail.sequence)
        if matches then
            saved.hidden = true
            saved.hiddenAt = hiddenAt
        end
    end

    return removed
end

local function DeleteSentMail(mail)
    if not mail or not CartasDB or not CartasDB.mails then return false end
    local removed = false
    local hiddenAt = NowTimestamp()
    for _, saved in ipairs(CartasDB.mails) do
        local matches = mail.key and saved.key == mail.key
            or (not mail.key and mail.sequence and saved.sequence == mail.sequence)
        if matches then
            saved.hidden = true
            saved.hiddenAt = hiddenAt
            removed = true
        end
    end
    return removed
end

local function DeleteHistoryMail(mail)
    if not mail then return false end
    if mail.direction == "out" then
        return DeleteSentMail(mail)
    end
    return DeleteArchivedMail(mail)
end

local function DeleteAllHistory()
    EnsureDB()
    local hiddenAt = NowTimestamp()
    for _, mail in ipairs(CartasDB.archive) do
        local key = mail.key or ("SEQ:" .. tostring(mail.sequence or ""))
        CartasDB.deletedArchive[key] = true
        mail.hidden = true
        mail.hiddenAt = hiddenAt
    end
    for _, mail in ipairs(CartasDB.incoming) do
        mail.hidden = true
        mail.hiddenAt = hiddenAt
    end
    for _, mail in ipairs(CartasDB.mails) do
        mail.hidden = true
        mail.hiddenAt = hiddenAt
    end
    return true
end

local function RestoreAllHistory()
    EnsureDB()
    local restored = 0
    for _, store in ipairs({CartasDB.archive, CartasDB.mails}) do
        for _, mail in ipairs(store) do
            if mail.hidden then
                mail.hidden = nil
                mail.hiddenAt = nil
                restored = restored + 1
            end
        end
    end
    for _, mail in ipairs(CartasDB.incoming) do
        mail.hidden = nil
        mail.hiddenAt = nil
    end
    wipe(CartasDB.deletedArchive)
    return restored
end

local function GetHiddenHistoryCount()
    EnsureDB()
    local hidden = 0
    for _, mail in ipairs(CartasDB.archive) do
        if mail.hidden then hidden = hidden + 1 end
    end
    for _, mail in ipairs(CartasDB.mails) do
        if mail.hidden then hidden = hidden + 1 end
    end
    return hidden
end

StaticPopupDialogs["CARTAS_DELETE_ARCHIVED"] = {
    text = "¿Ocultar esta carta del historial de Cartas?\n\nNo se eliminará del buzón de Blizzard y podrá restaurarse.",
    button1 = "Eliminar",
    button2 = "Cancelar",
    OnAccept = function(self, data)
        if data and DeleteHistoryMail(data) then
            if activeMailRefresh then activeMailRefresh() end
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["CARTAS_DELETE_ALL"] = {
    text = "¿Ocultar TODO el historial de Cartas?\n\nNo borra los datos ni los correos de Blizzard; el historial podrá restaurarse.",
    button1 = "Eliminar todo",
    button2 = "Cancelar",
    OnAccept = function()
        if DeleteAllHistory() and activeMailRefresh then
            activeMailRefresh()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function ResolveExpandedState(state, key, defaultExpanded)
    if state[key] == nil then return defaultExpanded and true or false end
    return state[key] and true or false
end

local function ShowFrameWithInitialRefresh(frameToShow, refresh)
    frameToShow:SetScript("OnShow", refresh)
    if type(frameToShow.IsShown) == "function" and frameToShow:IsShown() then
        refresh()
    else
        frameToShow:Show()
    end
end

local function OpenHistoryFrame()
    EnsureDB()

    if CartasFrame then
        CartasFrame:Show()
        return
    end

    local f = CreateFrame("Frame", "CartasFrame", UIParent, "BackdropTemplate")
    f:SetSize(900, 650)
    f:SetPoint("CENTER")
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    f:SetBackdropColor(0.04, 0.04, 0.06, 0.98)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -14)
    title:SetText("Cartas")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)

    local search = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    search:SetSize(250, 28)
    search:SetPoint("TOPLEFT", 18, -48)
    search:SetAutoFocus(false)

    local button = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    button:SetSize(82, 28)
    button:SetPoint("LEFT", search, "RIGHT", 8, 0)
    button:SetText("Buscar")

    local newButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    newButton:SetSize(100, 28)
    newButton:SetPoint("LEFT", button, "RIGHT", 8, 0)
    newButton:SetText("Nueva carta")
    newButton:SetScript("OnClick", function()
        OpenCompose()
    end)

    local deleteAllButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    deleteAllButton:SetSize(112, 28)
    deleteAllButton:SetPoint("LEFT", newButton, "RIGHT", 8, 0)
    deleteAllButton:SetText("Eliminar todo")
    deleteAllButton:SetScript("OnClick", function()
        StaticPopup_Show("CARTAS_DELETE_ALL")
    end)

    local restoreButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    restoreButton:SetSize(100, 28)
    restoreButton:SetPoint("LEFT", deleteAllButton, "RIGHT", 8, 0)
    restoreButton:SetText("Restaurar")
    restoreButton:SetScript("OnClick", function()
        local restored = RestoreAllHistory()
        PrintLine(restored .. " carta(s) restaurada(s).")
        if activeMailRefresh then activeMailRefresh() end
    end)

    local mailboxButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    mailboxButton:SetSize(90, 28)
    mailboxButton:SetPoint("RIGHT", close, "LEFT", -8, 0)
    mailboxButton:SetText("Buzón")
    mailboxButton:SetScript("OnClick", function()
        f:Hide()
        if MailFrame then MailFrame:Show() end
    end)

    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPLEFT", 20, -78)
    hint:SetPoint("RIGHT", -20, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText("Busca un personaje · [NUEVA] = pendiente · Leer, recoger, responder y enviar desde Cartas")

    local list = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    list:SetPoint("TOPLEFT", 18, -100)
    list:SetPoint("BOTTOMRIGHT", -38, 18)

    local content = CreateFrame("Frame", nil, list)
    content:SetWidth(820)
    list:SetScrollChild(content)

    local expandedParticipants = {}
    local expandedThreads = {}
    local liveInboxExpanded = true

    local function Refresh()
        for _, child in ipairs({content:GetChildren()}) do
            child:Hide()
            child:SetParent(nil)
        end

        if GetHiddenHistoryCount() > 0 then
            restoreButton:Enable()
        else
            restoreButton:Disable()
        end

        local target = strtrim(search:GetText() or "")
        if target == "" then target = nil end
        local targetLower = target and NormalizeSearchName(target)
        local all = GetAllCorrespondence()
        local participants = BuildParticipantGroups(all, targetLower)

        local y = -4
        local maxRight = 820
        local liveInbox = GetLiveInbox()

        -- IMPORTANT: the live Blizzard inbox is rendered separately from the
        -- archived/history groups above. Apply the SAME person filter here,
        -- otherwise a search (e.g. "flor") filters Historial guardado but then
        -- appends every live mailbox message underneath it.
        local filteredLiveInbox = {}
        for _, live in ipairs(liveInbox) do
            local livePerson = {
                person = live.sender or "",
                direction = "in",
                sender = live.sender or "",
                recipient = UnitName("player") or "",
            }
            if MailMatchesPerson(livePerson, targetLower) then
                table.insert(filteredLiveInbox, live)
            end
        end
        liveInbox = filteredLiveInbox

        if #liveInbox > 0 then
            local ih = CreateFrame("Button", nil, content, "BackdropTemplate")
            ih:SetPoint("TOPLEFT", 0, y)
            ih:SetSize(820, 34)
            ih:RegisterForClicks("LeftButtonUp")
            ih:SetBackdrop({bgFile="Interface/Tooltips/UI-Tooltip-Background",edgeFile="Interface/Tooltips/UI-Tooltip-Border",tile=true,tileSize=8,edgeSize=8,insets={left=3,right=3,top=3,bottom=3}})
            ih:SetBackdropColor(0.16,0.12,0.08,0.95)
            ih:SetScript("OnEnter", function(self)
                self:SetBackdropColor(0.22,0.17,0.11,0.95)
            end)
            ih:SetScript("OnLeave", function(self)
                self:SetBackdropColor(0.16,0.12,0.08,0.95)
            end)
            ih:SetScript("OnClick", function()
                liveInboxExpanded = not liveInboxExpanded
                Refresh()
            end)
            local iht = ih:CreateFontString(nil,"OVERLAY","GameFontNormal")
            iht:SetPoint("LEFT",10,0)
            local inboxMarker = liveInboxExpanded and "[-]" or "[+]"
            iht:SetText(inboxMarker.."  |cffFFD100BUZÓN ACTUAL|r  —  |cffaaaaaa"..tostring(#liveInbox).." correo(s)|r")
            y = y - 40

            if liveInboxExpanded then
              for _, live in ipairs(liveInbox) do
                local owner = UnitName("player") or ""
                local stored = FindIncomingRecord(owner, live.inboxIndex, live.sender, live.subject, live.daysLeft, live.CODAmount)
                local isNew = IsLiveInboxMailNew(live)
                local card = CreateFrame("Frame", nil, content, "BackdropTemplate")
                card:SetPoint("TOPLEFT", 0, y)
                card:SetWidth(820)
                card:SetBackdrop({bgFile="Interface/Tooltips/UI-Tooltip-Background",edgeFile="Interface/Tooltips/UI-Tooltip-Border",tile=true,tileSize=8,edgeSize=8,insets={left=3,right=3,top=3,bottom=3}})
                card:SetBackdropColor(0.10,0.10,0.12,0.94)

                local header = card:CreateFontString(nil,"OVERLAY","GameFontNormal")
                header:SetPoint("TOPLEFT",10,-8)
                header:SetPoint("RIGHT",-210,0)
                header:SetJustifyH("LEFT")
                local readText = isNew and "|cff7CFF00[NUEVA]|r" or "|cffaaaaaa[LEÍDA]|r"
                local typeText = live.canReply and "|cff66ccffJUGADOR|r" or "|cffaaaaaaSISTEMA|r"
                header:SetText("|cff66ff66📥 DE:|r |cffFFD100"..live.sender.."|r  "..readText.."  "..typeText..(live.subject ~= "" and "  —  |cffaaaaaa["..live.subject.."]|r" or ""))

                local body = card:CreateFontString(nil,"OVERLAY","GameFontHighlight")
                body:SetPoint("TOPLEFT",10,-31)
                body:SetWidth(math.max(260, card:GetWidth() - 230))
                body:SetJustifyH("LEFT")
                body:SetJustifyV("TOP")
                body:SetWordWrap(true)
                body:SetNonSpaceWrap(true)
                body:SetText(stored and stored.body ~= "" and stored.body or "(sin abrir)")

                local readBtn = CreateFrame("Button",nil,card,"UIPanelButtonTemplate")
                readBtn:SetSize(76,26)
                readBtn:SetPoint("TOPRIGHT",-122,-8)
                readBtn:SetText(isNew and "Leer" or "Ver")
                readBtn:SetScript("OnClick",function()
                    CaptureInboxMail(live.inboxIndex,function(captured)
                        -- Do not perform a broad archive search here.  Refresh()
                        -- will resolve this same live inbox slot, and therefore
                        -- repaint the exact row whose body was just fetched.
                        Refresh()
                    end)
                end)

                local function CollectLiveMail(index)
                    -- Blizzard processes mailbox commands asynchronously. Calling
                    -- TakeInboxMoney/TakeInboxItem several times in the same frame
                    -- can make later requests silently fail. Process one command at
                    -- a time and wait for the mailbox command queue to clear.
                    local attempts = 0
                    local function step()
                        attempts = attempts + 1
                        if attempts > 40 then
                            Refresh()
                            return
                        end

                        if C_Mail and C_Mail.IsCommandPending and C_Mail.IsCommandPending() then
                            C_Timer.After(0.20, step)
                            return
                        end

                        local _, _, sender, subject, money = GetInboxHeaderInfo(index)
                        if not sender or sender == "" then
                            Refresh()
                            return
                        end

                        if money and money > 0 and TakeInboxMoney then
                            TakeInboxMoney(index)
                            C_Timer.After(0.35, step)
                            return
                        end

                        local items = GetInboxAttachments(index)
                        if #items > 0 and TakeInboxItem then
                            TakeInboxItem(index, items[1].slot)
                            C_Timer.After(0.35, step)
                            return
                        end

                        Refresh()
                    end
                    step()
                end

                local collectBtn = CreateFrame("Button",nil,card,"UIPanelButtonTemplate")
                collectBtn:SetSize(105,26)
                collectBtn:SetPoint("TOPRIGHT",-8,-8)
                collectBtn:SetText("Recoger")
                collectBtn:SetScript("OnClick",function()
                    CollectLiveMail(live.inboxIndex)
                end)

                local replyBtn
                if live.canReply then
                    replyBtn = CreateFrame("Button",nil,card,"UIPanelButtonTemplate")
                    replyBtn:SetSize(105,26)
                    replyBtn:SetPoint("TOPRIGHT",-8,-40)
                    replyBtn:SetText("Responder")
                    replyBtn:SetScript("OnClick",function()
                        -- Reply does not need to open/read the Blizzard message first.
                        -- Using CaptureInboxMail here made the button appear dead when
                        -- GetInboxText() was not immediately available. The sender and
                        -- subject are already available from GetInboxHeaderInfo().
                        OpenCompose(live.sender, BuildReplySubject(live.subject), "")
                    end)
                end

                local items = GetInboxAttachments(live.inboxIndex)
                local attachText = ""
                if live.money and live.money > 0 then attachText = "💰 Dinero adjunto" end
                if #items > 0 then
                    attachText = attachText ~= "" and attachText.."  ·  " or ""
                    attachText = attachText.."📦 "..#items.." objeto(s)"
                end
                local extra = card:CreateFontString(nil,"OVERLAY","GameFontNormalSmall")
                extra:SetPoint("BOTTOMLEFT",10,8)
                extra:SetText(attachText)

                -- Reserve enough vertical space for every wrapped line.  The
                -- text column has a fixed width, so long mails can never spill
                -- below the card or underneath the action buttons.
                local h = math.max(110, 66 + body:GetStringHeight() + 24)
                card:SetHeight(h)
                y = y - h - 7
              end
              y = y - 12
            end
        end

        if #participants > 0 then
            local conversationCount = 0
            for _, participant in ipairs(participants) do
                conversationCount = conversationCount + #participant.threads
            end

            local hh = CreateFrame("Frame", nil, content, "BackdropTemplate")
            hh:SetPoint("TOPLEFT", 0, y)
            hh:SetSize(820, 34)
            hh:SetBackdrop({bgFile="Interface/Tooltips/UI-Tooltip-Background",edgeFile="Interface/Tooltips/UI-Tooltip-Border",tile=true,tileSize=8,edgeSize=8,insets={left=3,right=3,top=3,bottom=3}})
            hh:SetBackdropColor(0.10,0.14,0.10,0.95)
            local hht = hh:CreateFontString(nil,"OVERLAY","GameFontNormal")
            hht:SetPoint("LEFT",10,0)
            local participantLabel = #participants == 1 and "interlocutor" or "interlocutores"
            local conversationCountLabel = conversationCount == 1 and "conversación" or "conversaciones"
            hht:SetText("|cff7CFF00HISTORIAL GUARDADO|r  —  |cffaaaaaa"..#participants.." "..participantLabel.." · "..conversationCount.." "..conversationCountLabel.."|r")
            y = y - 40
        end

        for _, participant in ipairs(participants) do
            local isExpanded = ResolveExpandedState(expandedParticipants, participant.key, target ~= nil)

            local participantHeader = CreateFrame("Button", nil, content, "BackdropTemplate")
            participantHeader:SetPoint("TOPLEFT", 0, y)
            participantHeader:SetSize(820, 36)
            participantHeader:RegisterForClicks("LeftButtonUp")
            participantHeader:SetBackdrop({bgFile="Interface/Tooltips/UI-Tooltip-Background",edgeFile="Interface/Tooltips/UI-Tooltip-Border",tile=true,tileSize=8,edgeSize=8,insets={left=3,right=3,top=3,bottom=3}})
            participantHeader:SetBackdropColor(0.10,0.11,0.15,0.98)
            participantHeader:SetScript("OnEnter", function(self)
                self:SetBackdropColor(0.15,0.16,0.21,0.98)
            end)
            participantHeader:SetScript("OnLeave", function(self)
                self:SetBackdropColor(0.10,0.11,0.15,0.98)
            end)
            participantHeader:SetScript("OnClick", function()
                expandedParticipants[participant.key] = not isExpanded
                Refresh()
            end)

            local participantText = participantHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            participantText:SetPoint("LEFT", 12, 0)
            participantText:SetPoint("RIGHT", -12, 0)
            participantText:SetJustifyH("LEFT")
            local marker = isExpanded and "[-]" or "[+]"
            local conversationLabel = #participant.threads == 1 and "conversación" or "conversaciones"
            local mailLabel = participant.messageCount == 1 and "carta" or "cartas"
            local newLabel = participant.newCount == 1 and "NUEVA" or "NUEVAS"
            local newText = participant.newCount > 0 and "  |cff7CFF00["..participant.newCount.." "..newLabel.."]|r" or ""
            local latestText = participant.latest > 0 and FormatDate(participant.latest) or "sin fecha"
            participantText:SetText(marker.."  |cffFFD100"..participant.name.."|r"..newText.."  |cffaaaaaa· "..#participant.threads.." "..conversationLabel.." · "..participant.messageCount.." "..mailLabel.." · "..latestText.."|r")
            y = y - 40

            if isExpanded then
                for _, thread in ipairs(participant.threads) do
                    local chain = BuildThreadChain(thread.messages)
                    local threadIndent = 20
                    local isThreadExpanded = ResolveExpandedState(expandedThreads, thread.key, target ~= nil)
                    local th = CreateFrame("Button",nil,content,"BackdropTemplate")
                    th:SetPoint("TOPLEFT",threadIndent,y)
                    th:SetSize(820 - threadIndent,34)
                    th:RegisterForClicks("LeftButtonUp")
                    th:SetBackdrop({bgFile="Interface/Tooltips/UI-Tooltip-Background",edgeFile="Interface/Tooltips/UI-Tooltip-Border",tile=true,tileSize=8,edgeSize=8,insets={left=3,right=3,top=3,bottom=3}})
                    th:SetBackdropColor(0.12,0.12,0.16,0.95)
                    th:SetScript("OnEnter", function(self)
                        self:SetBackdropColor(0.17,0.17,0.22,0.95)
                    end)
                    th:SetScript("OnLeave", function(self)
                        self:SetBackdropColor(0.12,0.12,0.16,0.95)
                    end)
                    th:SetScript("OnClick", function()
                        expandedThreads[thread.key] = not isThreadExpanded
                        Refresh()
                    end)
                    local txt = th:CreateFontString(nil,"OVERLAY","GameFontNormal")
                    txt:SetPoint("LEFT",10,0)
                    txt:SetPoint("RIGHT",-10,0)
                    txt:SetJustifyH("LEFT")
                    local threadMailLabel = #chain == 1 and "carta" or "cartas"
                    local threadMarker = isThreadExpanded and "[-]" or "[+]"
                    local threadNewLabel = thread.newCount == 1 and "NUEVA" or "NUEVAS"
                    local threadNewText = thread.newCount > 0 and "  |cff7CFF00["..thread.newCount.." "..threadNewLabel.."]|r" or ""
                    txt:SetText(threadMarker.."  |cffFFD100CONVERSACIÓN|r"..threadNewText.."  —  |cffaaaaaa"..thread.subject.." · "..#chain.." "..threadMailLabel.."|r")
                    y = y - 40

                    if isThreadExpanded then
                      for _, mail in ipairs(chain) do
                        -- Repeated RE prefixes do not encode a reliable reply tree.
                        -- Keep one visual reply level and use time for conversation order.
                        local depth = mail.isReply and 1 or 0
                        local indent = threadIndent + (depth * 34)
                        local cardWidth = math.max(560, 820 - indent)
                        local card = CreateFrame("Button",nil,content,"BackdropTemplate")
                        card:SetPoint("TOPLEFT",indent,y)
                        card:SetWidth(cardWidth)
                        card:RegisterForClicks("LeftButtonUp")
                        card:SetScript("OnClick",function()
                            if mail.direction == "in" and mail.isNew then
                                MarkMailSeen(UnitName("player") or "",mail)
                                mail.isNew=false
                                Refresh()
                            end
                        end)
                        card:SetBackdrop({bgFile="Interface/Tooltips/UI-Tooltip-Background",edgeFile="Interface/Tooltips/UI-Tooltip-Border",tile=true,tileSize=8,edgeSize=8,insets={left=3,right=3,top=3,bottom=3}})
                        card:SetBackdropColor(mail.direction=="in" and 0.08 or 0.08, mail.direction=="in" and 0.12 or 0.09, mail.direction=="in" and 0.08 or 0.15, 0.94)

                        if depth > 0 then
                            local arrow=card:CreateFontString(nil,"OVERLAY","GameFontNormalLarge")
                            arrow:SetPoint("TOPLEFT",-25,-7)
                            arrow:SetText("|cffaaaaaa↳|r")
                        end

                        local header=card:CreateFontString(nil,"OVERLAY","GameFontNormal")
                        header:SetPoint("TOPLEFT",10,-8)
                        header:SetPoint("RIGHT",-10,0)
                        header:SetJustifyH("LEFT")
                        local who=mail.person or mail.sender or mail.recipient or "?"
                        local directionText=mail.direction=="in" and "|cff66ff66📥 RECIBIDA DE:|r" or "|cff66ccff📤 ENVIADA A:|r"
                        local messageNewText=mail.isNew and "  |cff7CFF00[NUEVA]|r" or ""
                        header:SetText(directionText.." |cffFFD100"..who.."|r"..messageNewText.."  —  "..(mail.date or FormatDate(mail.timestamp))..((mail.subject and mail.subject~="") and "  |cffaaaaaa["..mail.subject.."]|r" or ""))

                        local body=card:CreateFontString(nil,"OVERLAY","GameFontHighlight")
                        body:SetPoint("TOPLEFT",10,-30)
                        body:SetWidth(math.max(240, card:GetWidth() - 20))
                        body:SetJustifyH("LEFT")
                        body:SetJustifyV("TOP")
                        body:SetWordWrap(true)
                        body:SetNonSpaceWrap(true)
                        body:SetText(mail.body~="" and mail.body or "(sin contenido guardado)")

                        local deleteBtn=CreateFrame("Button",nil,card,"UIPanelButtonTemplate")
                        deleteBtn:SetSize(76,24)
                        deleteBtn:SetPoint("BOTTOMRIGHT",-10,8)
                        deleteBtn:SetText("Eliminar")
                        deleteBtn:SetScript("OnClick",function()
                            StaticPopup_Show("CARTAS_DELETE_ARCHIVED",nil,nil,mail)
                        end)

                        local action=CreateFrame("Button",nil,card,"UIPanelButtonTemplate")
                        action:SetSize(90,24)
                        action:SetPoint("BOTTOMRIGHT",-94,8)
                        action:SetText("Responder")
                        action:SetScript("OnClick",function()
                            local recipient = mail.direction == "in" and mail.sender or mail.recipient
                            OpenCompose(recipient, BuildReplySubject(mail.subject), "")
                        end)

                        -- Keep the complete archived message inside its card.
                        local h=math.max(110,58+body:GetStringHeight()+30)
                        card:SetHeight(h)
                        y=y-h-7
                        maxRight=math.max(maxRight,indent+cardWidth)
                      end
                      y=y-12
                    end
                end
            end
        end

        content:SetWidth(820)
        content:SetHeight(math.max(1,-y))
    end

    activeMailRefresh = Refresh
    button:SetScript("OnClick",Refresh)
    search:SetScript("OnEnterPressed",function(self) self:ClearFocus(); Refresh() end)
    ShowFrameWithInitialRefresh(f, Refresh)
end



local function OpenCartasFromMailbox()
    if type(OpenHistoryFrame) == "function" then
        OpenHistoryFrame()
    end
end

local mailboxAutoOpen = CreateFrame("Frame")
mailboxAutoOpen:RegisterEvent("MAIL_SHOW")
mailboxAutoOpen:SetScript("OnEvent", function()
    C_Timer.After(0, OpenCartasFromMailbox)
end)

local function AddMailboxCartasButton()
    if CartasMailboxButton or not MailFrame then return end

    local b = CreateFrame("Button", "CartasMailboxButton", MailFrame, "UIPanelButtonTemplate")
    b:SetSize(30, 30)
    b:SetPoint("TOPRIGHT", MailFrame, "TOPRIGHT", -55, -38)
    b:SetText("C")
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Cartas")
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    b:SetScript("OnClick", function()
        OpenHistoryFrame()
    end)

    CartasMailboxButton = b
end

local mailboxHook = CreateFrame("Frame")
mailboxHook:RegisterEvent("MAIL_SHOW")
mailboxHook:SetScript("OnEvent", function()
    AddMailboxCartasButton()
end)

SLASH_CARTAS1 = "/cartas"
SLASH_CARTAS2 = "/correspondencia"

SlashCmdList.CARTAS = function(msg)
    msg = strtrim(msg or "")

    if msg == "" then
        OpenHistoryFrame()
    elseif msg == "limpiar" then
        StaticPopup_Show("CARTAS_DELETE_ALL")
    elseif msg == "restaurar" then
        local restored = RestoreAllHistory()
        PrintLine(restored .. " carta(s) restaurada(s).")
        if activeMailRefresh then activeMailRefresh() end
    elseif msg == "ayuda" then
        PrintLine("/cartas — abre tu historial")
        PrintLine("/correspondencia NOMBRE — muestra toda la correspondencia con ese personaje")
        PrintLine("/correspondencia limpiar — oculta el historial con confirmación")
        PrintLine("/correspondencia restaurar — recupera cartas ocultas")
    else
        ShowHistory(msg)
    end
end

if _G and _G.CartasTestMode then
    _G.CartasTestAPI = {
        EnsureDB = EnsureDB,
        EnsureArchive = EnsureArchive,
        MigrateCorrespondencia = MigrateCorrespondencia,
        AuditArchiveDuplicates = AuditArchiveDuplicates,
        SavePendingMail = SavePendingMail,
        ScanInbox = ScanInbox,
        CaptureInboxMail = CaptureInboxMail,
        GetLiveInbox = GetLiveInbox,
        IsLiveInboxMailNew = IsLiveInboxMailNew,
        IsMailNew = IsMailNew,
        GetAllCorrespondence = GetAllCorrespondence,
        IsConversationMail = IsConversationMail,
        AnalyzeThreadSubject = AnalyzeThreadSubject,
        NormalizeThreadSubject = NormalizeThreadSubject,
        BuildThreadKey = BuildThreadKey,
        BuildReplySubject = BuildReplySubject,
        BuildParticipantGroups = BuildParticipantGroups,
        CountUTF8Characters = CountUTF8Characters,
        TruncateUTF8Characters = TruncateUTF8Characters,
        ValidateOutgoingMailText = ValidateOutgoingMailText,
        MAIL_SUBJECT_MAX_LETTERS = MAIL_SUBJECT_MAX_LETTERS,
        MAIL_BODY_MAX_LETTERS = MAIL_BODY_MAX_LETTERS,
        ReplyLevel = ReplyLevel,
        BuildThreadChain = BuildThreadChain,
        NormalizeSearchName = NormalizeSearchName,
        MailMatchesPerson = MailMatchesPerson,
        FindIncomingRecord = FindIncomingRecord,
        EstimateMailTimestamp = EstimateMailTimestamp,
        RepairImpossibleFutureTimestamps = RepairImpossibleFutureTimestamps,
        DeleteHistoryMail = DeleteHistoryMail,
        DeleteAllHistory = DeleteAllHistory,
        RestoreAllHistory = RestoreAllHistory,
        GetHiddenHistoryCount = GetHiddenHistoryCount,
        ResolveExpandedState = ResolveExpandedState,
        ShowFrameWithInitialRefresh = ShowFrameWithInitialRefresh,
    }
end

local login = CreateFrame("Frame")
login:RegisterEvent("PLAYER_LOGIN")
login:SetScript("OnEvent", function()
    EnsureDB()
    EnsureArchive()
    RepairImpossibleFutureTimestamps()
    PrintLine("Cargado. Tus cartas enviadas se guardarán automáticamente.")
end)
