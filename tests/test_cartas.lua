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

test("normal inbox timestamps with 30.x days remaining never land in the future", function()
    resetDB()
    local timestamp = API.EstimateMailTimestamp(30.5, 0, Mock.now)
    assertEqual(timestamp, Mock.now - 43200)
    assertTrue(timestamp <= Mock.now)
end)

test("incoming and outgoing thread messages interleave by reconstructed timestamp", function()
    resetDB()
    Mock.inbox = {
        {
            sender = "Arianna-TestRealm",
            subject = "Plan compartido",
            body = "",
            daysLeft = 30.5,
            wasRead = false,
            canReply = true,
        },
    }
    API.ScanInbox()
    local incomingTimestamp = CartasDB.archive[1].timestamp
    CartasDB.mails = {
        {
            sequence = 2,
            owner = Mock.player,
            sender = Mock.player,
            recipient = "Arianna-TestRealm",
            subject = "Plan compartido",
            body = "Antes",
            timestamp = incomingTimestamp - 60,
        },
        {
            sequence = 3,
            owner = Mock.player,
            sender = Mock.player,
            recipient = "Arianna-TestRealm",
            subject = "RE: Plan compartido",
            body = "Después",
            timestamp = incomingTimestamp + 60,
        },
    }

    local participants = API.BuildParticipantGroups(API.GetAllCorrespondence())
    local chain = API.BuildThreadChain(participants[1].threads[1].messages)

    assertEqual(#chain, 3)
    assertEqual(chain[1].direction, "out")
    assertEqual(chain[2].direction, "in")
    assertEqual(chain[3].direction, "out")
end)

test("future archived timestamps are repaired without losing original metadata", function()
    local broken = incoming(1, Mock.now + 43200, "Conservar")
    broken.date = os.date("%Y-%m-%d %H:%M:%S", broken.timestamp)
    broken._firstSeenAt = Mock.now
    broken.customMetadata = "intacto"
    local originalTimestamp = broken.timestamp
    local originalDate = broken.date
    resetDB({
        mails = {}, incoming = {}, archive = {broken},
        seen = {}, deletedArchive = {}, nextSequence = 1,
    })

    assertEqual(API.RepairImpossibleFutureTimestamps(), 1)
    assertEqual(#CartasDB.archive, 1)
    assertEqual(CartasDB.archive[1].timestamp, Mock.now - 43200)
    assertEqual(CartasDB.archive[1]._timestampBeforeExpiryFix, originalTimestamp)
    assertEqual(CartasDB.archive[1]._dateBeforeExpiryFix, originalDate)
    assertEqual(CartasDB.archive[1].customMetadata, "intacto")
    assertEqual(API.RepairImpossibleFutureTimestamps(), 0)
end)

test("legacy 30-day inbox timestamps are matched after rows shift", function()
    resetDB()
    local currentDaysLeft = 20
    local previousSeenAt = Mock.now - 3600
    local previousDaysLeft = currentDaysLeft + (3600 / 86400)
    local correctedTimestamp = API.EstimateMailTimestamp(currentDaysLeft, 0, Mock.now)
    local legacyTimestamp = math.floor(
        previousSeenAt - ((30 - previousDaysLeft) * 86400) + 0.5
    )
    assertEqual(legacyTimestamp, correctedTimestamp + 86400)

    local legacy = incoming(1, legacyTimestamp, "Texto conservado")
    legacy.subject = "Tema desplazado"
    legacy.daysLeft = previousDaysLeft
    legacy._firstSeenAt = previousSeenAt
    legacy._lastSeenAt = previousSeenAt
    legacy._lastInboxIndex = 1
    CartasDB.archive = {legacy}
    CartasDB.nextSequence = 1

    Mock.inbox = {
        {sender = "Brina", subject = "Carta nueva", body = "", daysLeft = 30.5, wasRead = false},
        {sender = legacy.sender, subject = legacy.subject, body = legacy.body, daysLeft = currentDaysLeft, wasRead = true},
    }
    API.ScanInbox()

    assertEqual(#CartasDB.archive, 2)
    assertEqual(legacy.timestamp, correctedTimestamp)
    assertEqual(legacy._timestampBeforeExpiryFix, legacyTimestamp)
    assertEqual(legacy._timestampRepair, "normal-expiry-31-live-match")
    assertEqual(legacy._lastInboxIndex, 2)
    assertEqual(legacy.body, "Texto conservado")
    assertEqual(Mock.getInboxTextCalls, 1)
end)

test("unread one-day candidates are never merged from headers alone", function()
    resetDB()
    local currentDaysLeft = 20
    local previousSeenAt = Mock.now - 3600
    local previousDaysLeft = currentDaysLeft + (3600 / 86400)
    local correctedTimestamp = API.EstimateMailTimestamp(currentDaysLeft, 0, Mock.now)
    local legacyTimestamp = correctedTimestamp + 86400
    local legacy = incoming(1, legacyTimestamp, "Cuerpo todavía privado")
    legacy.subject = "Cabecera ambigua"
    legacy.daysLeft = previousDaysLeft
    legacy._firstSeenAt = previousSeenAt
    legacy._lastSeenAt = previousSeenAt
    legacy._lastInboxIndex = 1
    CartasDB.archive = {legacy}
    CartasDB.nextSequence = 1

    Mock.inbox = {
        {sender = "Brina", subject = "Carta nueva", body = "", daysLeft = 30.5, wasRead = false},
        {sender = legacy.sender, subject = legacy.subject, body = legacy.body, daysLeft = currentDaysLeft, wasRead = false},
    }
    API.ScanInbox()

    assertEqual(#CartasDB.archive, 3)
    assertEqual(legacy.timestamp, legacyTimestamp)
    assertEqual(legacy._timestampBeforeExpiryFix, nil)
    assertEqual(Mock.getInboxTextCalls, 0)
end)

test("proven expiry duplicates are filtered without deleting either record", function()
    resetDB()
    local correctedDaysLeft = 20
    local correctedTimestamp = API.EstimateMailTimestamp(correctedDaysLeft, 0, Mock.now)
    local legacySeenAt = Mock.now - 3600
    local legacyDaysLeft = correctedDaysLeft + (3600 / 86400)

    local legacy = incoming(1, correctedTimestamp + 86400, "Mismo texto técnico")
    legacy.subject = "Duplicado de migración"
    legacy.daysLeft = legacyDaysLeft
    legacy._firstSeenAt = legacySeenAt
    legacy._lastSeenAt = legacySeenAt

    local corrected = incoming(2, correctedTimestamp, legacy.body)
    corrected.subject = legacy.subject
    corrected.daysLeft = correctedDaysLeft
    corrected._firstSeenAt = Mock.now
    corrected._lastSeenAt = Mock.now

    local legitimateFirst = incoming(3, correctedTimestamp, "Texto repetido legítimo")
    legitimateFirst.subject = "Dos cartas reales"
    legitimateFirst.daysLeft = correctedDaysLeft
    legitimateFirst._firstSeenAt = Mock.now
    legitimateFirst._lastSeenAt = Mock.now

    local legitimateSecond = incoming(4, correctedTimestamp + 86400, legitimateFirst.body)
    legitimateSecond.subject = legitimateFirst.subject
    legitimateSecond.daysLeft = correctedDaysLeft + 1
    legitimateSecond._firstSeenAt = Mock.now
    legitimateSecond._lastSeenAt = Mock.now

    CartasDB.archive = {legacy, corrected, legitimateFirst, legitimateSecond}
    CartasDB.nextSequence = 4
    local legacyTimestamp = legacy.timestamp
    local aliases = API.BuildTechnicalDuplicateAliases(CartasDB.archive)
    local correspondence = API.GetAllCorrespondence()

    assertEqual(aliases[legacy], corrected)
    assertEqual(aliases[legitimateFirst], nil)
    assertEqual(aliases[legitimateSecond], nil)
    assertEqual(#correspondence, 3)
    assertEqual(#CartasDB.archive, 4)
    assertEqual(legacy.timestamp, legacyTimestamp)
    assertTrue(not legacy.hidden)
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
    assertEqual(participants[2].threads[2].newCount, 1)
    assertEqual(#participants[2].threads[2].messages, 2)

    local filtered = API.BuildParticipantGroups(participants[2].threads[2].messages, "bri")
    assertEqual(#filtered, 1)
    assertEqual(filtered[1].name, "Brina")
end)

test("legacy organization metadata is preserved but ignored", function()
    local legacyOrganization = {old = {title = "No aplicar", folder = "No aplicar", pinned = true}}
    resetDB({
        mails = {}, incoming = {}, archive = {}, seen = {}, deletedArchive = {},
        nextSequence = 0, threadOrganization = legacyOrganization,
    })
    local participants = API.BuildParticipantGroups({
        {person = "Brina", subject = "Tema original", timestamp = 10, sequence = 1},
    })

    assertEqual(CartasDB.threadOrganization, legacyOrganization)
    assertEqual(participants[1].threads[1].subject, "Tema original")
    assertEqual(participants[1].threads[1].displaySubject, nil)
    assertEqual(participants[1].threads[1].folder, nil)
    assertEqual(participants[1].threads[1].pinned, nil)
end)

test("visual settings are isolated and clamp opacity and window size", function()
    resetDB({
        mails = {{sequence = 1, subject = "Intacto", body = "Conservar"}},
        incoming = {}, archive = {}, seen = {}, deletedArchive = {}, nextSequence = 1,
    })

    assertEqual(CartasDB.ui.theme, API.UI_THEME_PARCHMENT)
    assertEqual(CartasDB.ui.opacity, 1)
    assertEqual(CartasDB.ui.width, API.HISTORY_WIDTH_DEFAULT)
    assertEqual(CartasDB.ui.height, API.HISTORY_HEIGHT_DEFAULT)
    API.SetVisualSettings(API.UI_THEME_CLASSIC, 0.1, 100, 5000)
    assertEqual(CartasDB.ui.theme, API.UI_THEME_CLASSIC)
    assertEqual(CartasDB.ui.opacity, API.UI_OPACITY_MIN)
    assertEqual(CartasDB.ui.width, API.HISTORY_WIDTH_MIN)
    assertEqual(CartasDB.ui.height, API.HISTORY_HEIGHT_MAX)
    API.SetVisualSettings(API.UI_THEME_PARCHMENT, 5)
    assertEqual(CartasDB.ui.theme, API.UI_THEME_PARCHMENT)
    assertEqual(CartasDB.ui.opacity, API.UI_OPACITY_MAX)
    assertEqual(#CartasDB.mails, 1)
    assertEqual(CartasDB.mails[1].subject, "Intacto")
    assertEqual(CartasDB.mails[1].body, "Conservar")
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
        {sender = "Arianna-TestRealm", subject = "Igual", body = "Mismo texto", daysLeft = 29, wasRead = true},
        {sender = "Arianna-TestRealm", subject = "Igual", body = "Mismo texto", daysLeft = 29 - (10 / 86400), wasRead = true},
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
        {sender = "Arianna-TestRealm", subject = "Abierta", body = "Ya cargada", daysLeft = 27, wasRead = true},
    }
    API.ScanInbox()
    assertEqual(CartasDB.archive[1].body, "Ya cargada")
end)

test("background scan never opens or marks unread inbox mail", function()
    resetDB()
    Mock.inbox = {
        {sender = "Arianna-TestRealm", subject = "Pendiente", body = "Texto privado", daysLeft = 26, wasRead = false},
    }

    Mock.trigger("MAIL_INBOX_UPDATE")

    assertEqual(Mock.getInboxTextCalls, 0)
    assertTrue(not Mock.inbox[1].wasRead)
    assertTrue(not CartasDB.archive[1].wasRead)
    assertEqual(CartasDB.archive[1].body, "")
end)

test("rendering the live inbox only reads headers", function()
    resetDB()
    Mock.inbox = {
        {sender = "Arianna-TestRealm", subject = "Sin abrir", body = "No solicitar", daysLeft = 25, wasRead = false},
    }

    local live = API.GetLiveInbox()

    assertEqual(#live, 1)
    assertEqual(Mock.getInboxTextCalls, 0)
    assertTrue(API.IsLiveInboxMailNew(live[1]))
    assertTrue(not Mock.inbox[1].wasRead)
end)

test("live inbox deletion is blocked for every protected content type", function()
    local cases = {
        {
            label = "objeto",
            mail = {items = {{name = "Cristal ficticio", itemID = 1, count = 1}}},
        },
        {label = "dinero", mail = {money = 12345}},
        {label = "contra reembolso", mail = {CODAmount = 67890}},
    }

    for _, case in ipairs(cases) do
        resetDB()
        case.mail.sender = "Brina-TestRealm"
        case.mail.subject = "Contenido protegido"
        case.mail.body = "No borrar"
        case.mail.daysLeft = 20
        case.mail.wasRead = false
        case.mail.canDelete = true
        Mock.inbox = {case.mail}

        local requested, reason = API.RequestDeleteLiveInboxMail(1)

        assertTrue(not requested, case.label)
        assertEqual(reason, "protected", case.label)
        assertEqual(Mock.popup.name, "CARTAS_LIVE_MAIL_WARNING", case.label)
        assertTrue(Mock.popup.textArg1:find(case.label, 1, true) ~= nil, case.label)
        assertEqual(Mock.deleteInboxCalls, 0, case.label)
        assertEqual(Mock.getInboxTextCalls, 0, case.label)
        assertEqual(#Mock.inbox, 1, case.label)
    end
end)

test("return-only player mail is never silently returned by delete", function()
    resetDB()
    Mock.inbox = {{
        sender = "Brina-TestRealm", subject = "Solo devolver", body = "Texto",
        daysLeft = 20, wasRead = true, canDelete = false,
    }}

    local requested, reason = API.RequestDeleteLiveInboxMail(1)

    assertTrue(not requested)
    assertEqual(reason, "return-only")
    assertEqual(Mock.popup.name, "CARTAS_LIVE_MAIL_WARNING")
    assertEqual(Mock.deleteInboxCalls, 0)
    assertEqual(#Mock.inbox, 1)
end)

test("live inbox deletion archives the body before removing the Blizzard row", function()
    resetDB()
    Mock.inbox = {{
        sender = "Brina-TestRealm", subject = "Borrado seguro", body = "Cuerpo preservado",
        daysLeft = 20, wasRead = false, canDelete = true,
    }}
    API.ScanInbox()
    assertEqual(CartasDB.archive[1].body, "")
    assertEqual(Mock.getInboxTextCalls, 0)

    local requested = API.RequestDeleteLiveInboxMail(1)
    assertTrue(requested)
    assertEqual(Mock.popup.name, "CARTAS_DELETE_LIVE_MAIL")
    StaticPopupDialogs.CARTAS_DELETE_LIVE_MAIL.OnAccept(nil, Mock.popup.data)

    assertEqual(Mock.getInboxTextCalls, 1)
    assertEqual(Mock.deleteInboxCalls, 1)
    assertEqual(#Mock.inbox, 0)
    assertEqual(#CartasDB.archive, 1)
    assertEqual(CartasDB.archive[1].body, "Cuerpo preservado")
    assertTrue(CartasDB.archive[1].wasRead)
    assertTrue(not CartasDB.archive[1].hidden)
end)

test("live inbox deletion aborts when the selected row changes", function()
    resetDB()
    Mock.inbox = {{
        sender = "Brina-TestRealm", subject = "Fila original", body = "Texto",
        daysLeft = 20, wasRead = true, canDelete = true,
    }}
    assertTrue(API.RequestDeleteLiveInboxMail(1))
    local confirmation = Mock.popup
    Mock.inbox[1] = {
        sender = "Celene-TestRealm", subject = "Fila distinta", body = "Otro texto",
        daysLeft = 29, wasRead = true, canDelete = true,
    }

    StaticPopupDialogs.CARTAS_DELETE_LIVE_MAIL.OnAccept(nil, confirmation.data)

    assertEqual(Mock.deleteInboxCalls, 0)
    assertEqual(Mock.getInboxTextCalls, 0)
    assertEqual(#Mock.inbox, 1)
    assertEqual(Mock.popup.name, "CARTAS_LIVE_MAIL_WARNING")
end)

test("live Blizzard unread state wins over stale archived read state", function()
    resetDB()
    local staleArchive = {wasRead = true}
    local live = {wasRead = false}

    assertTrue(staleArchive.wasRead)
    assertTrue(API.IsLiveInboxMailNew(live))
    assertTrue(not API.IsLiveInboxMailNew({wasRead = true}))
end)

test("explicit capture is the action that reads and stores an unread body", function()
    resetDB()
    Mock.inbox = {
        {sender = "Arianna-TestRealm", subject = "Lectura explícita", body = "Contenido", daysLeft = 24, wasRead = false},
    }
    API.ScanInbox()
    assertEqual(Mock.getInboxTextCalls, 0)

    local captured
    API.CaptureInboxMail(1, function(mail) captured = mail end)

    assertEqual(Mock.getInboxTextCalls, 1)
    assertTrue(Mock.inbox[1].wasRead)
    assertTrue(captured.wasRead)
    assertEqual(captured.body, "Contenido")
    assertTrue(not API.IsMailNew(Mock.player, captured))
end)

test("archived read metadata prevents false new conversation badges", function()
    local unread = incoming(1, Mock.now, "Pendiente")
    unread.wasRead = false
    local read = incoming(2, Mock.now + 1, "Revisada")
    read.wasRead = true
    resetDB({
        mails = {}, incoming = {}, archive = {unread, read},
        seen = {}, deletedArchive = {}, nextSequence = 2,
    })

    local correspondence = API.GetAllCorrespondence()

    assertTrue(not correspondence[1].isNew)
    assertTrue(correspondence[2].isNew)
end)

test("expanded state defaults are deterministic and remain overridable", function()
    local state = {}
    assertTrue(API.ResolveExpandedState(state, "inbox", true))
    assertTrue(not API.ResolveExpandedState(state, "thread", false))
    state.inbox = false
    state.thread = true
    assertTrue(not API.ResolveExpandedState(state, "inbox", true))
    assertTrue(API.ResolveExpandedState(state, "thread", false))
end)

test("already visible history frames refresh on their first initialization", function()
    local refreshCount = 0
    local visible = {scripts = {}}
    function visible:SetScript(name, callback) self.scripts[name] = callback end
    function visible:IsShown() return true end
    function visible:Show() error("visible frame must refresh directly") end

    API.ShowFrameWithInitialRefresh(visible, function() refreshCount = refreshCount + 1 end)

    assertEqual(refreshCount, 1)
    assertTrue(type(visible.scripts.OnShow) == "function")
end)

test("hidden history frames refresh exactly once through OnShow", function()
    local refreshCount = 0
    local hidden = {scripts = {}}
    function hidden:SetScript(name, callback) self.scripts[name] = callback end
    function hidden:IsShown() return false end
    function hidden:Show() self.scripts.OnShow(self) end

    API.ShowFrameWithInitialRefresh(hidden, function() refreshCount = refreshCount + 1 end)

    assertEqual(refreshCount, 1)
end)

test("visual modes and window sizes build without reading unread mail", function()
    resetDB({
        mails = {{
            sequence = 1, owner = Mock.player, recipient = "Arianna-TestRealm",
            subject = "Crónica", body = "Texto enviado", timestamp = Mock.now - 20,
        }},
        incoming = {}, archive = {}, seen = {}, deletedArchive = {}, nextSequence = 1,
    })
    Mock.inbox = {{
        sender = "Arianna-TestRealm", subject = "RE: Crónica",
        body = "Texto pendiente", daysLeft = 30.5, wasRead = false, canReply = true,
    }}
    API.ScanInbox()
    local callsBefore = Mock.getInboxTextCalls
    local archiveCount = #CartasDB.archive
    local sentBody = CartasDB.mails[1].body

    API.SetVisualSettings(API.UI_THEME_PARCHMENT, 1, 1180, 820)
    API.OpenHistoryFrame()
    API.OpenVisualSettings()
    assertTrue(CartasFrame ~= nil)
    assertTrue(CartasVisualSettingsFrame ~= nil)
    assertEqual(CartasFrame:GetWidth(), 1180)
    assertEqual(CartasFrame:GetHeight(), 820)
    assertTrue(not CartasFrame.compactLayout)
    assertTrue(CartasFrame.themeSearchPanel ~= nil)
    assertEqual(CartasFrame.themeSearchPanel.backdropColor[1], 0.96)
    assertEqual(CartasFrame.themeSearchPanel.backdropColor[4], 1)

    CartasVisualSettingsFrame.classicButton.scripts.OnClick()
    CartasVisualSettingsFrame.opacitySlider:SetValue(70)
    CartasVisualSettingsFrame.widthSlider:SetValue(800)
    CartasVisualSettingsFrame.heightSlider:SetValue(860)
    assertEqual(CartasDB.ui.theme, API.UI_THEME_CLASSIC)
    assertEqual(CartasDB.ui.opacity, 0.7)
    assertEqual(CartasDB.ui.width, 800)
    assertEqual(CartasDB.ui.height, 860)
    assertEqual(CartasFrame:GetWidth(), 800)
    assertEqual(CartasFrame:GetHeight(), 860)
    assertTrue(CartasFrame.compactLayout)
    assertEqual(CartasFrame.themeSearchPanel.backdropColor[4], 1)

    CartasVisualSettingsFrame.parchmentButton.scripts.OnClick()
    assertEqual(CartasDB.ui.theme, API.UI_THEME_PARCHMENT)
    API.OpenCompose("Arianna-TestRealm", "RE: Crónica", "Borrador local")
    assertEqual(CartasComposeFrame.body:GetText(), "Borrador local")

    assertEqual(Mock.getInboxTextCalls, callsBefore)
    assertEqual(#CartasDB.archive, archiveCount)
    assertEqual(CartasDB.mails[1].body, sentBody)
    assertTrue(not Mock.inbox[1].wasRead)
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
