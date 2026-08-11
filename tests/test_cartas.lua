local Mock = dofile("tests/wow_mock.lua")
assert(loadfile("Cartas.lua"))("Cartas")

local API = assert(CartasTestAPI, "CartasTestAPI was not exported")
local passed, failed = 0, 0

local function assertEqual(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function assertTrue(value, message)
    if not value then error(message or "expected a truthy value", 2) end
end

local function test(name, callback)
    local ok, err = pcall(callback)
    if ok then
        passed = passed + 1
        io.write("PASS  " .. name .. "\n")
    else
        failed = failed + 1
        io.write("FAIL  " .. name .. "\n      " .. tostring(err) .. "\n")
    end
end

local function resetDB(value)
    CartasDB = value or {}
    Mock.reset()
    API.EnsureDB()
end

local function incoming(sequence, timestamp, body)
    return {
        sequence = sequence,
        key = "incoming-" .. sequence,
        owner = Mock.player,
        recipient = Mock.player,
        sender = "Arianna-TestRealm",
        subject = "Saludos",
        body = body or "Texto",
        timestamp = timestamp,
        direction = "in",
    }
end

test("partial character search ignores realm qualification", function()
    resetDB()
    Mock.ambiguateQualifies = true
    local query = API.NormalizeSearchName("Arian")
    assertEqual(query, "arian")
    assertTrue(API.MailMatchesPerson({person = "Arianna-TestRealm"}, query))
    assertTrue(API.MailMatchesPerson({person = "Arianna-TestRealm"}, "arian-test"))
    assertTrue(not API.MailMatchesPerson({person = "Arianna-TestRealm"}, "arian-other"))
    assertTrue(not API.MailMatchesPerson({person = "Arianna-TestRealm"}, "["))
end)

test("subject variants share one thread base", function()
    resetDB()
    local cases = {
        {"Tema principal", "Tema principal", 0},
        {"RE: Tema principal", "Tema principal", 1},
        {"RE: RE: Tema principal", "Tema principal", 2},
        {"RE RE: Tema principal", "Tema principal", 2},
        {"RE RE RE: Tema principal", "Tema principal", 3},
        {"Re: Segundo tema", "Segundo tema", 1},
        {"FW: RE: Tema archivado", "Tema archivado", 1},
        {"RE: RE: RE: RE: Tema archivado", "Tema archivado", 4},
        {"Tema extenso", "Tema extenso", 0},
        {"RE: Tema extenso", "Tema extenso", 1},
        {"RE encuentro", "RE encuentro", 0},
    }
    for _, item in ipairs(cases) do
        local base, depth = API.AnalyzeThreadSubject(item[1])
        assertEqual(base, item[2], item[1] .. " base")
        assertEqual(depth, item[3], item[1] .. " depth")
    end
end)

test("thread order remains chronological when reply prefixes reset", function()
    resetDB()
    local chain = API.BuildThreadChain({
        {subject = "RE: Tema principal", timestamp = 40, sequence = 4},
        {subject = "RE RE: Tema principal", timestamp = 30, sequence = 3},
        {subject = "Tema principal", timestamp = 10, sequence = 1},
        {subject = "RE: RE: RE: Tema principal", timestamp = 20, sequence = 2},
    })
    assertEqual(chain[1].subject, "Tema principal")
    assertEqual(chain[2].subject, "RE: RE: RE: Tema principal")
    assertEqual(chain[3].subject, "RE RE: Tema principal")
    assertEqual(chain[4].subject, "RE: Tema principal")
end)

test("reset reply subject keeps the same participant thread", function()
    resetDB()
    local historical = API.BuildThreadKey("RE: RE: RE: Tema archivado", "Brina")
    local resetReply = API.BuildThreadKey("RE: Tema archivado", "Brina")
    local otherPerson = API.BuildThreadKey("RE: Tema archivado", "Otra")
    assertEqual(resetReply, historical)
    assertTrue(otherPerson ~= historical)
end)

test("conversation history groups threads under each participant", function()
    resetDB()
    local participants = API.BuildParticipantGroups({
        {person = "Brina", subject = "Tema archivado", timestamp = 10, sequence = 1, isNew = true},
        {person = "Brina", subject = "RE: RE: Tema archivado", timestamp = 20, sequence = 2},
        {person = "Brina", subject = "Tema principal", timestamp = 30, sequence = 3},
        {person = "Arianna-TestRealm", subject = "Tema archivado", timestamp = 40, sequence = 4},
    })

    assertEqual(#participants, 2)
    assertEqual(participants[1].name, "Arianna-TestRealm")
    assertEqual(participants[2].name, "Brina")
    assertEqual(participants[2].messageCount, 3)
    assertEqual(participants[2].newCount, 1)
    assertEqual(#participants[2].threads, 2)
    assertEqual(participants[2].threads[1].subject, "Tema principal")
    assertEqual(participants[2].threads[2].subject, "Tema archivado")
    assertEqual(#participants[2].threads[2].messages, 2)

    local filtered = API.BuildParticipantGroups(participants[2].threads[2].messages, "bri")
    assertEqual(#filtered, 1)
    assertEqual(filtered[1].name, "Brina")
end)

test("compose enforces the live WoW subject and body limits", function()
    resetDB()
    assertEqual(API.MAIL_SUBJECT_MAX_LETTERS, 64)
    assertEqual(API.MAIL_BODY_MAX_LETTERS, 500)
    assertEqual(API.CountUTF8Characters("a\195\161z"), 3)

    local valid = API.ValidateOutgoingMailText(string.rep("s", 64), string.rep("b", 500))
    assertTrue(valid)
    valid = API.ValidateOutgoingMailText(string.rep("s", 65), "body")
    assertTrue(not valid)
    valid = API.ValidateOutgoingMailText("subject", string.rep("b", 501))
    assertTrue(not valid)
end)

test("reply subjects stop accumulating prefixes and remain within 64 characters", function()
    resetDB()
    assertEqual(API.BuildReplySubject("Tema archivado"), "RE: Tema archivado")
    assertEqual(API.BuildReplySubject("RE: RE: RE: Tema archivado"), "RE: Tema archivado")

    local sixty = string.rep("a", 60)
    assertEqual(API.BuildReplySubject(sixty), "RE: " .. sixty)

    local sixtyFour = string.rep("b", 64)
    assertEqual(API.BuildReplySubject(sixtyFour), sixtyFour)

    local accented = string.rep("\195\161", 70)
    local truncated = API.BuildReplySubject(accented)
    assertEqual(API.CountUTF8Characters(truncated), 64)
    assertEqual(truncated, string.rep("\195\161", 64))
end)

test("sent history is not pruned after 500 records", function()
    resetDB({mails = {}, incoming = {}, archive = {}, seen = {}, deletedArchive = {}, nextSequence = 500})
    for i = 1, 500 do
        CartasDB.mails[i] = {sequence = i, owner = Mock.player, recipient = "P" .. i, body = "B" .. i}
    end
    Mock.callHook("SendMail", "Arianna-TestRealm", "Asunto", "Cuerpo")
    Mock.trigger("MAIL_SEND_SUCCESS")
    assertEqual(#CartasDB.mails, 501)
    assertEqual(CartasDB.mails[1].sequence, 1)
    assertEqual(CartasDB.mails[501].ownerRealm, Mock.realm)
end)

test("automatic duplicate audit never removes records", function()
    local first = incoming(1, Mock.now - 5, "Mismo cuerpo")
    local second = incoming(2, Mock.now, "Mismo cuerpo")
    resetDB({mails = {}, incoming = {}, archive = {first, second}, seen = {}, deletedArchive = {}, nextSequence = 2})
    assertEqual(API.AuditArchiveDuplicates(), 1)
    assertEqual(#CartasDB.archive, 2)
end)

test("legacy incoming migration is idempotent", function()
    local legacy = incoming(7, Mock.now, "Legado")
    legacy.key = nil
    resetDB({mails = {}, incoming = {legacy}, archive = {}, seen = {}, deletedArchive = {}, nextSequence = 7})
    API.EnsureArchive()
    API.EnsureArchive()
    assertEqual(#CartasDB.archive, 1)
    assertTrue(CartasDB.incoming[1].key ~= nil)
end)

test("identical incoming letters remain separate", function()
    resetDB()
    Mock.inbox = {
        {sender = "Arianna-TestRealm", subject = "Igual", body = "Mismo texto", daysLeft = 29},
        {sender = "Arianna-TestRealm", subject = "Igual", body = "Mismo texto", daysLeft = 29 - (10 / 86400)},
    }
    Mock.trigger("MAIL_INBOX_UPDATE")
    assertEqual(#CartasDB.archive, 2)
    assertEqual(CartasDB.archive[1].body, "Mismo texto")
    assertEqual(CartasDB.archive[2].body, "Mismo texto")
    API.ScanInbox()
    assertEqual(#CartasDB.archive, 2)
end)

test("Correspondencia migration preserves every store and is idempotent", function()
    resetDB({mails = {}, incoming = {}, archive = {}, seen = {}, deletedArchive = {}, nextSequence = 0})
    CorrespondenciaDB = {
        mails = {{sequence = 1, body = "Enviada legado"}},
        incoming = {{sequence = 2, body = "Recibida legado"}},
        archive = {{sequence = 3, body = "Archivo legado"}},
        seen = {oldSeen = true},
        deletedArchive = {oldDeleted = true},
        nextSequence = 3,
        customMetadata = "preservar",
    }
    assertEqual(API.MigrateCorrespondencia(), 3)
    assertEqual(API.MigrateCorrespondencia(), 0)
    assertEqual(#CartasDB.mails, 1)
    assertEqual(#CartasDB.incoming, 1)
    assertEqual(#CartasDB.archive, 1)
    assertTrue(CartasDB.seen.oldSeen)
    assertTrue(CartasDB.deletedArchive.oldDeleted)
    assertEqual(CartasDB.nextSequence, 3)
    assertEqual(CartasDB.customMetadata, "preservar")
    CorrespondenciaDB = nil
end)

test("new sequence advances past stale legacy counters", function()
    resetDB({
        mails = {{sequence = 900, owner = Mock.player, recipient = "Antiguo"}},
        incoming = {}, archive = {}, seen = {}, deletedArchive = {}, nextSequence = 2,
    })
    Mock.callHook("SendMail", "Arianna", "Secuencia", "Nueva")
    Mock.trigger("MAIL_SEND_SUCCESS")
    assertEqual(CartasDB.mails[2].sequence, 901)
    assertEqual(CartasDB.nextSequence, 901)
end)

test("capture callback completes and stores a body", function()
    resetDB()
    Mock.inbox = {
        {sender = "Arianna-TestRealm", subject = "Lectura", body = "", daysLeft = 28},
    }
    API.ScanInbox()
    Mock.inbox[1].body = "Cuerpo cargado"
    local captured
    API.CaptureInboxMail(1, function(mail) captured = mail end)
    assertTrue(captured ~= nil)
    assertEqual(captured.body, "Cuerpo cargado")
end)

test("same-second inbox rows keep their own bodies", function()
    resetDB()
    Mock.inbox = {
        {sender = "Arianna-TestRealm", subject = "Coinciden", body = "", daysLeft = 28},
        {sender = "Arianna-TestRealm", subject = "Coinciden", body = "", daysLeft = 28},
    }
    API.ScanInbox()
    Mock.inbox[1].body = "Primer cuerpo"
    Mock.inbox[2].body = "Segundo cuerpo"
    API.CaptureInboxMail(1)
    API.CaptureInboxMail(2)
    assertEqual(CartasDB.archive[1].body, "Primer cuerpo")
    assertEqual(CartasDB.archive[2].body, "Segundo cuerpo")
end)

test("loaded Blizzard bodies are archived during inbox scan", function()
    resetDB()
    Mock.inbox = {
        {sender = "Arianna-TestRealm", subject = "Abierta", body = "Ya cargada", daysLeft = 27},
    }
    API.ScanInbox()
    assertEqual(CartasDB.archive[1].body, "Ya cargada")
end)

test("system and Customer Support mail never become conversations", function()
    local auction = incoming(1, Mock.now, "Venta completada")
    auction.sender = "Auction House"
    auction.canReply = false

    local support = incoming(2, Mock.now + 1, "Respuesta de soporte")
    support.sender = "Customer Support"
    support.canReply = true
    support.isGM = true

    local player = incoming(3, Mock.now + 2, "Carta de jugador")
    player.canReply = true
    player.isGM = false

    local legacyPlayer = incoming(4, Mock.now + 3, "Carta antigua")
    legacyPlayer.canReply = nil
    legacyPlayer.isGM = nil

    resetDB({
        mails = {}, incoming = {}, archive = {auction, support, player, legacyPlayer},
        seen = {}, deletedArchive = {}, nextSequence = 4,
    })

    local conversations = API.GetAllCorrespondence()
    assertEqual(#CartasDB.archive, 4)
    assertEqual(#conversations, 2)
    assertEqual(conversations[1].sender, legacyPlayer.sender)
    assertEqual(conversations[2].sender, player.sender)
    assertTrue(not API.IsConversationMail(auction))
    assertTrue(not API.IsConversationMail(support))
end)

test("Blizzard system metadata corrects a stale archived record", function()
    local stale = incoming(1, Mock.now, "Sistema")
    stale.sender = "Auction House"
    stale.canReply = true
    stale._lastInboxIndex = 1
    resetDB({
        mails = {}, incoming = {}, archive = {stale},
        seen = {}, deletedArchive = {}, nextSequence = 1,
    })
    Mock.inbox = {
        {sender = "Auction House", subject = stale.subject, body = stale.body, daysLeft = 30, canReply = false},
    }
    API.ScanInbox()
    assertEqual(CartasDB.archive[1].canReply, false)
    assertEqual(#API.GetAllCorrespondence(), 0)
    assertEqual(#CartasDB.archive, 1)
end)

test("delete all is reversible and does not shrink storage", function()
    local archived = incoming(1, Mock.now, "Recibida")
    resetDB({
        mails = {{sequence = 2, owner = Mock.player, recipient = "Arianna", body = "Enviada", timestamp = Mock.now}},
        incoming = {archived},
        archive = {archived},
        seen = {},
        deletedArchive = {},
        nextSequence = 2,
    })
    assertEqual(#API.GetAllCorrespondence(), 2)
    API.DeleteAllHistory()
    assertEqual(#CartasDB.archive, 1)
    assertEqual(#CartasDB.mails, 1)
    assertEqual(API.GetHiddenHistoryCount(), 2)
    assertEqual(#API.GetAllCorrespondence(), 0)
    API.RestoreAllHistory()
    assertEqual(API.GetHiddenHistoryCount(), 0)
    assertEqual(#API.GetAllCorrespondence(), 2)
end)

test("slash limpiar asks before hiding anything", function()
    resetDB({
        mails = {{sequence = 1, owner = Mock.player, recipient = "Arianna", body = "Enviada"}},
        incoming = {}, archive = {}, seen = {}, deletedArchive = {}, nextSequence = 1,
    })
    SlashCmdList.CARTAS("limpiar")
    assertEqual(#CartasDB.mails, 1)
    assertTrue(not CartasDB.mails[1].hidden)
    assertEqual(Mock.popup.name, "CARTAS_DELETE_ALL")
    StaticPopupDialogs.CARTAS_DELETE_ALL.OnAccept()
    assertEqual(#CartasDB.mails, 1)
    assertTrue(CartasDB.mails[1].hidden)
end)

test("keyed delete does not hide a record with only the same sequence", function()
    local first = incoming(4, Mock.now, "Uno")
    local second = incoming(4, Mock.now + 60, "Dos")
    first.key = "key-one"
    second.key = "key-two"
    resetDB({mails = {}, incoming = {}, archive = {first, second}, seen = {}, deletedArchive = {}, nextSequence = 4})
    assertTrue(API.DeleteHistoryMail({direction = "in", sequence = 4, key = "key-one"}))
    assertTrue(CartasDB.archive[1].hidden)
    assertTrue(not CartasDB.archive[2].hidden)
    assertEqual(#CartasDB.archive, 2)
end)

io.write(string.format("\n%d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
