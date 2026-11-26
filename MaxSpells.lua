-- Max-rank spells: keeps your action bars on the highest spell ranks you know, and can put newly learned
-- spells in empty bar slots. Rank upgrades and placement share the same combat and cursor safety.
--
-- 2026-11-16: this was the separate addon BalMaxSpells 0.2.0 (before that, Max Rank Bars 0.1.4). It is
-- now part of ReadyToWork: settings in ReadyToWorkDB.maxSpells, options in ReadyToWork's menu (its own minimap
-- button and window are gone), and /bms, /balmaxspells, /mrb and /maxrankbars still work, as does /rtw spells.
local _, Helper = ...
local OLD_ADDON = "BalMaxSpells"
local SLOT_LIMIT = 180 -- Player pages 1-15, including stance and extra bars.
local LEARN_TIMEOUT = 60
local LEARN_LIMIT = 64
-- Switching spec makes the game teach the new spec's talents and spec spells again, while its bars are still
-- being swapped in. Spells "learned" until the bars have been quiet this long (at most SPEC_LIMIT) came back
-- with the switch: they are never placed again. (2026-11-17: Resto's Water Shield was placed a second time
-- after switching back from Enhancement; any spec-only spell of any class could be.)
local SPEC_QUIET, SPEC_LIMIT = 3, 15
local placementBars = { "MainActionBar", "MultiBarBottomLeft", "MultiBarBottomRight",
    "MultiBarRight", "MultiBarLeft", "MultiBar5", "MultiBar6", "MultiBar7" }
local db, ready
local driver = CreateFrame("Frame")
local rankWanted = false
local function syncCastEvent()
    if db.enabled and db.castCheck then driver:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    else driver:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED") end
end

local pending, scheduled, running, bookDirty = false, false, false, true
local bookRevision = 0
local ownedCursorID, reportRequested
local families, spells, requested, rankDataWaiting = {}, {}, {}, {}
local learnQueue, learnedByID = {}, {}
local failedUpgrades = {}                        -- ["slot:spellID"]: an upgrade the game wouldn't take this session
-- Learning a spell (a new rank from a trainer, say) asks for a rank pass, and so does the spellbook change that
-- follows it within this many seconds (the book can show the new rank only after the learn event). 1.28.9 ran
-- rank passes only at login, /reload and Scan now, so a trained rank stayed off the bars until you scanned.
local LEARN_RANK_WINDOW = 10
local rankLearnUntil
local stats, warned = {}, {}
local specGroup                                  -- the spec group last seen
local switchSince, switchUntil                   -- a spec switch under way (see SPEC_QUIET)
local retryAfterSwitch                           -- a scan waits for the switch to settle
-- This character's spells (by ID and by name, so every rank counts) it has had: in its spellbook, in either
-- spec, or on its action bars; ReadyToWorkDB.maxSpells.seen[character]. A learned spell among them is not new
-- and is never placed (see QueueLearned): switching spec makes the game teach a spec's own talents and spells
-- again, at times no window can catch (1.21.3's spec-switch window still let some through, 2026-11-17), and a
-- spell you took off on purpose must stay off.
local seen
local Request, Process

local function Secret(value)
    return issecretvalue and issecretvalue(value) or false
end

local function Number(value)
    return not Secret(value) and type(value) == "number" and value == value and
        value > -math.huge and value < math.huge
end

local function Text(value)
    return not Secret(value) and type(value) == "string" and value ~= ""
end

local function True(value)
    return not Secret(value) and (value == true or value == 1)
end

local function Say(message)
    Helper.Print(message)
end

local function Literal(value)
    return Text(value) and value:gsub("|", "||") or "unknown"
end

local function Warn(key, message)
    if not warned[key] then warned[key] = true; Say(message) end
end

local function Locked()
    if type(InCombatLockdown) ~= "function" then return true end
    local ok, value = pcall(InCombatLockdown)
    return not ok or Secret(value) or (value ~= false and value ~= nil)
end

local function PlayerBank()
    return Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
end

local function Rank(subtext)
    if not Text(subtext) then return nil end
    -- "Rank 3", "Rang 3", etc. Exactly one number, with no locale-specific
    -- English word or spell-ID ordering assumption.
    local digits = subtext:match("^%D*(%d+)%D*$")
    local rank = digits and tonumber(digits)
    if Number(rank) and rank > 0 then return rank end
end

local function RequestData(id)
    if Number(id) and not requested[id] and C_Spell and type(C_Spell.RequestLoadSpellData) == "function" then
        requested[id] = true
        if rankWanted then rankDataWaiting[id] = true end
        pcall(C_Spell.RequestLoadSpellData, id)
    end
end

local function Spell(id, fallback)
    if not Number(id) or id <= 0 then return nil end
    local ok, info = pcall(C_Spell.GetSpellInfo, id)
    local name = ok and not Secret(info) and type(info) == "table" and info.name or nil
    local rankOK, subtext = pcall(C_Spell.GetSpellSubtext, id)
    if not rankOK or Secret(subtext) then subtext = nil end
    if fallback then
        if not Text(name) then name = fallback.name end
        if not Text(subtext) and not Secret(fallback.subName) and type(fallback.subName) == "string" then
            subtext = fallback.subName
        end
    end
    if not Text(name) then RequestData(id) end
    local cached = true
    if type(C_Spell.IsSpellDataCached) == "function" then
        local cachedOK, value = pcall(C_Spell.IsSpellDataCached, id)
        cached = cachedOK and True(value)
        if cachedOK and not Secret(value) and value == false then RequestData(id) end
    end
    local rank = Rank(subtext)
    if Text(name) then
        return { id = id, name = name, rank = rank,
            placementReady = rank ~= nil or (cached and type(subtext) == "string") }
    end
end

local function Known(id)
    local fn = C_SpellBook and C_SpellBook.IsSpellKnown
    if type(fn) == "function" then
        local ok, known = pcall(fn, id, PlayerBank())
        return ok and True(known)
    end
    if type(IsPlayerSpell) == "function" then
        local ok, known = pcall(IsPlayerSpell, id)
        return ok and True(known)
    end
    return false
end

local function BuildBook()
    local revision = bookRevision
    local countOK, lineCount = pcall(C_SpellBook.GetNumSpellBookSkillLines)
    if not countOK or not Number(lineCount) or lineCount < 1 or lineCount > 1000 then return false end
    local nextFamilies, nextSpells = {}, {}
    local spellKind = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell or 1
    local ranked, ambiguous = 0, 0
    for line = 1, lineCount do
        local lineOK, info = pcall(C_SpellBook.GetSpellBookSkillLineInfo, line)
        if not lineOK or Secret(info) or type(info) ~= "table" then return false end
        if lineOK and not Secret(info) and type(info) == "table" and
            not Secret(info.offSpecID) and not True(info.isGuild) and not info.offSpecID then
            local offset, count = info.itemIndexOffset, info.numSpellBookItems
            if not Number(offset) or not Number(count) or offset < 0 or count < 0 or offset + count > 10000 then
                return false
            end
            if Number(offset) and Number(count) and offset >= 0 and count >= 0 and offset + count <= 10000 then
                -- Hidden UI categories/ranks are still real book entries.
                for index = offset + 1, offset + count do
                    local itemOK, item = pcall(C_SpellBook.GetSpellBookItemInfo, index, PlayerBank())
                    if not itemOK or Secret(item) or type(item) ~= "table" then return false end
                    if itemOK and not Secret(item) and type(item) == "table" and
                        not Secret(item.itemType) and item.itemType == spellKind and
                        not Secret(item.isPassive) and not item.isPassive and
                        not Secret(item.isOffSpec) and not item.isOffSpec then
                        local id = item.spellID
                        if not Number(id) or id <= 0 then id = item.actionID end
                        if Number(id) and id > 0 and Known(id) then
                            local entry = Spell(id, item)
                            if entry then nextSpells[id] = entry end
                            if entry and entry.rank then
                                local family = nextFamilies[entry.name]
                                if not family then
                                    family = { highest = entry, ranks = {} }
                                    nextFamilies[entry.name] = family
                                    ranked = ranked + 1
                                end
                                local sameRank = family.ranks[entry.rank]
                                if sameRank and sameRank ~= id and not family.ambiguous then
                                    family.ambiguous = true
                                    ambiguous = ambiguous + 1
                                end
                                family.ranks[entry.rank] = id
                                if entry.rank > family.highest.rank then family.highest = entry end
                            end
                        end
                    end
                end
            end
        end
    end
    families, spells = nextFamilies, nextSpells
    stats.families, stats.ambiguous = ranked, ambiguous
    if seen then
        for id, entry in pairs(nextSpells) do seen[id], seen[entry.name] = true, true end
    end
    bookDirty = bookRevision ~= revision
    return true
end

local function Action(slot)
    local ok, kind, id = pcall(GetActionInfo, slot)
    if ok and not Secret(kind) and not Secret(id) then return kind, id, true end
end

-- The shaman totem bar's slots (12 of them, 133-144 on Forever: the user's saved bars, 2026-11-21). The game sets
-- them only through SetMultiCastSpell, as Blizzard's own totem flyout does (MultiCastActionBarFrame.lua @bebcb6b).
-- PlaceAction there changed the button on screen but not what the server keeps, so every login, zone or landing
-- put the old rank back, and the next scan picked up and put down the new one again: the clicks heard on every
-- reload (1.28.9 and earlier). nil when this character has no totem bar.
local function TotemSlots()
    local fn = C_ActionBar and C_ActionBar.GetMultiCastBarIndex
    if type(fn) ~= "function" then return nil end
    local ok, index = pcall(fn)
    if ok and Number(index) and index >= 1 and index <= SLOT_LIMIT / 12 and index % 1 == 0 then
        return (index - 1) * 12 + 1, index * 12
    end
end

local function IsTotemSlot(slot)
    local first, last = TotemSlots()
    return first ~= nil and slot >= first and slot <= last
end

local function SlotMatches(slot, old)
    local kind, id, readable = Action(slot)
    if old then return kind == "spell" and id == old.id end
    if not readable or kind ~= nil or id ~= nil then return false end
    local hasAction = C_ActionBar and C_ActionBar.HasAction or HasAction
    if type(hasAction) ~= "function" then return true end
    local ok, occupied = pcall(hasAction, slot)
    return ok and not Secret(occupied) and occupied == false
end

local function TemporaryBar()
    if not C_ActionBar then return false end
    for _, name in ipairs({ "HasVehicleActionBar", "HasOverrideActionBar", "HasTempShapeshiftActionBar", "IsPossessBarVisible" }) do
        local fn = C_ActionBar[name]
        if type(fn) == "function" then
            local ok, active = pcall(fn)
            if not ok or Secret(active) or active then return true end
        end
    end
    return false
end

local function VisibleSlot(bar, index)
    if Secret(bar) or not bar or type(bar.IsShown) ~= "function" then return end
    local ok, shown = pcall(bar.IsShown, bar)
    if not ok or not True(shown) then return end
    local count, buttons = bar.numButtonsShowable, bar.actionButtons
    if not Number(count) or index > count or Secret(buttons) or type(buttons) ~= "table" then return end
    local button = buttons[index]
    if Secret(button) or not button or type(button.GetAttribute) ~= "function" then return end
    local attributeOK, hidden = pcall(button.GetAttribute, button, "statehidden")
    if not attributeOK or Secret(hidden) or hidden then return end
    local slot = button.action
    if Number(slot) and slot >= 1 and slot <= SLOT_LIMIT and slot % 1 == 0 then return slot end
end

local function FirstEmptySlot()
    for _, barName in ipairs(placementBars) do
        local bar = _G[barName]
        -- Empty buttons can be visually hidden by the grid setting. Use the
        -- bar's configured button count and each button's real paged slot.
        for index = 1, 12 do
            local slot = VisibleSlot(bar, index)
            if slot and SlotMatches(slot) then return slot, bar, index end
        end
    end
end

local function AlreadyOnBar(entry)
    for slot = 1, SLOT_LIMIT do
        local kind, id = Action(slot)
        if kind == "spell" and Number(id) then
            if id == entry.id then return true end
            local other = spells[id] or Spell(id)
            if other and other.name == entry.name then return true end
        end
    end
    return false
end

-- (see `seen`) Spells in saved bar layouts: everything on either spec's bars when they were saved or loaded.
local function SeeSlots(slots)
    if not seen or type(slots) ~= "table" then return end
    for _, entry in pairs(slots) do
        if type(entry) == "table" and entry.kind == "spell" then
            if Text(entry.name) then seen[entry.name] = true end
            if Number(entry.id) then seen[entry.id] = true end
        end
    end
end

-- The game's own "push new spells to the action bar" (AutoPushSpellToActionBar: a per-character game setting,
-- on by default, that addons may change). After a spec switch it pushed the spec's talents back onto the bars
-- (ReadyToWork's learn log showed "the game itself put it in slot ...", 2026-11-17), so ReadyToWork keeps it off
-- unless you switch it back on (db.blockGamePush; the user: "baked into the bar helper ... and then just add a
-- customization option to turn it on/off"). Changed elsewhere (/console, the game's options), ReadyToWork follows
-- that choice rather than fighting it. ReadyToWork's own placement still adds spells new to this character.
local PUSH_CVAR = "AutoPushSpellToActionBar"
local settingPush, pushWaiting = false, false

local function GamePushOn()
    local get = C_CVar and C_CVar.GetCVar
    if type(get) ~= "function" then return nil end
    local ok, value = pcall(get, PUSH_CVAR)
    if ok and not Secret(value) and type(value) == "string" then return value ~= "0" end
end

local function ApplyGamePush(explicit)
    local wantOn = not db.blockGamePush
    local now = GamePushOn()
    if now == nil or now == wantOn then return end
    if Locked() then pushWaiting = true; return end   -- (after the fight)
    local set = C_CVar and C_CVar.SetCVar
    if type(set) ~= "function" then return end
    settingPush = true
    local ok, done = pcall(set, PUSH_CVAR, wantOn and "1" or "0")
    settingPush = false
    if ok and done ~= false and GamePushOn() == wantOn then
        if explicit or db.reportChanges then
            Say(wantOn and "The game puts newly learned spells on your bars again (its own setting)." or
                "ReadyToWork switched off the game's own pushing of spells onto your bars (it put a spec's spells back after " ..
                "every spec switch). ReadyToWork still places spells you've never had. To let the game do it again: /rtw spells gamepush on.")
        end
    else
        Warn("gamepush", "Couldn't change the game's own setting for putting spells on your bars (" .. PUSH_CVAR .. ").")
    end
end

-- The setting changed by anything but ReadyToWork: that is your choice now.
local function GamePushChanged(name, value)
    if settingPush or Secret(name) or Secret(value) or type(name) ~= "string" or name:lower() ~= PUSH_CVAR:lower() then
        return
    end
    db.blockGamePush = value == "0"
end

-- What happened to each learned spell, for /rtw spells status (the last LOG_LINES).
local LOG_LINES = 20
local function Log(text)
    if db.recordLog==false then return end
    if type(db.learnLog) ~= "table" then db.learnLog = {} end
    local stamp = type(date) == "function" and date("%m-%d %H:%M:%S") or "?"
    table.insert(db.learnLog, stamp .. " " .. text)
    while #db.learnLog > LOG_LINES do table.remove(db.learnLog, 1) end
end

local function Cursor()
    local ok, kind, a, bank, id = pcall(GetCursorInfo)
    if not ok or Secret(kind) then return "unknown" end
    if kind == nil then return nil end
    if kind ~= "spell" then return kind end
    if Number(id) and id > 0 then return kind, id end
    if Number(a) and not Secret(bank) then
        if bank == nil then return kind, a end
        local spellBank = bank == "spell" and PlayerBank() or bank
        if spellBank == PlayerBank() then
            local itemOK, item = pcall(C_SpellBook.GetSpellBookItemInfo, a, spellBank)
            if itemOK and not Secret(item) and type(item) == "table" then
                local spellID = item.spellID
                if not Number(spellID) then spellID = item.actionID end
                if Number(spellID) then return kind, spellID end
            end
        end
    end
    return kind
end

local function ReleaseOwnedCursor()
    if ownedCursorID and not Locked() then
        local kind, id = Cursor()
        if kind == "spell" and id == ownedCursorID then pcall(ClearCursor) end
        ownedCursorID = nil
    end
end

local function SetSpellNow(slot, old, highest, bar, index)
    if Locked() then return false, true, "waiting for combat to end" end
    if Cursor() ~= nil then return false, true, "waiting for an empty cursor" end
    if not SlotMatches(slot, old) then return false, true, "action changed during scan" end
    local pickup = C_Spell.PickupSpell or PickupSpell
    local pickupOK = pcall(pickup, highest.id)
    local cursorKind, cursorID = Cursor()
    if not pickupOK or cursorKind ~= "spell" or cursorID ~= highest.id then
        if cursorKind == "spell" and cursorID == highest.id then
            ownedCursorID = cursorID
            ReleaseOwnedCursor()
            cursorKind = Cursor()
        end
        -- An unfamiliar cursor payload might belong to the player/another
        -- addon. Preserve it, and never place an unverified spell.
        Warn("pickup:" .. slot .. ":" .. highest.id,
            "Could not verify picking up " .. Literal(highest.name) .. "; slot " .. slot .. " kept. /bms debug for status.")
        return false, cursorKind ~= nil, "spell pickup unavailable"
    end
    ownedCursorID = highest.id
    if Locked() then return false, true, "waiting for combat to end" end
    if (not old and (not db.autoPlace or TemporaryBar() or VisibleSlot(bar, index) ~= slot or AlreadyOnBar(highest)))
        or not SlotMatches(slot, old) then
        ReleaseOwnedCursor()
        return false, true, "action changed during pickup"
    end
    cursorKind, cursorID = Cursor()
    if cursorKind ~= "spell" or cursorID ~= highest.id then
        ownedCursorID = nil
        return false, true, "cursor changed during pickup"
    end
    if Locked() then return false, true, "waiting for combat to end" end
    pcall(PlaceAction, slot)
    local newKind, newID = Action(slot)
    cursorKind, cursorID = Cursor()
    if cursorKind == "spell" and (cursorID == highest.id or (old and cursorID == old.id)) then
        ownedCursorID = cursorID
    else
        ownedCursorID = nil
    end
    ReleaseOwnedCursor()
    local blocked = Locked() or Cursor() ~= nil
    if newKind == "spell" and newID == highest.id then
        if old then
            if db.reportChanges then
                Say(Literal(highest.name) .. ": Rank " .. old.rank .. " -> Rank " .. highest.rank .. " (slot " .. slot .. ").")
            end
            Log(Literal(highest.name) .. ": Rank " .. old.rank .. " -> Rank " .. highest.rank .. " in slot " .. slot)
        else
            if db.reportChanges then Say("Placed " .. Literal(highest.name) .. " in empty slot " .. slot .. ".") end
            Log(Literal(highest.name) .. " (" .. highest.id .. "): placed in slot " .. slot .. ", never on your bars before")
        end
        return true, blocked, blocked and "waiting for combat/cursor" or nil
    end
    Warn("place:" .. slot .. ":" .. highest.id,
        "Could not confirm " .. (old and "upgrading " or "placing ") .. Literal(highest.name) ..
        " in slot " .. slot .. ". /bms debug for status.")
    return false, blocked, "placement not confirmed"
end

-- A totem bar slot (see TotemSlots) to the highest rank, the way the game's own totem flyout does it: no cursor,
-- nothing picked up or put down.
local function SetTotemNow(slot, old, highest)
    if Locked() then return false, true, "waiting for combat to end" end
    if not SlotMatches(slot, old) then return false, true, "action changed during scan" end
    if type(SetMultiCastSpell) ~= "function" then return false, false, "totem bar API unavailable" end
    local ok = pcall(SetMultiCastSpell, slot, highest.id)
    local newKind, newID = Action(slot)
    if ok and newKind == "spell" and newID == highest.id then
        if db.reportChanges then
            Say(Literal(highest.name) .. ": Rank " .. old.rank .. " -> Rank " .. highest.rank .. " (totem bar).")
        end
        Log(Literal(highest.name) .. ": Rank " .. old.rank .. " -> Rank " .. highest.rank .. " on the totem bar (slot " .. slot .. ")")
        return true, false, nil
    end
    -- (it may still arrive with the bar's next update; either way it is not tried again this session)
    Log(Literal(highest.name) .. ": totem bar slot " .. slot .. " kept at Rank " .. old.rank ..
        (ok and ", the game didn't confirm Rank " or ", the game refused Rank ") .. highest.rank)
    return false, false, ok and "totem bar change not confirmed" or "totem bar refused the change"
end

-- Runs one of ReadyToWork's own bar changes with BarTools.ours raised (see Ours below), so bar profile
-- auto-update never takes it for your edit.
local function AsOurs(fn, ...)
    local tools = Helper.BarTools
    tools.BeginOurs()
    local results = { pcall(fn, ...) }
    tools.EndOurs()
    if not results[1] then error(results[2], 0) end
    return results[2], results[3], results[4]
end
local function SetSpell(...) return AsOurs(SetSpellNow, ...) end
local function SetTotem(...) return AsOurs(SetTotemNow, ...) end

local function RemoveLearned(index)
    local queued = table.remove(learnQueue, index)
    learnedByID[queued.id] = nil
end

-- A learned spell that was not placed. Most are not bar spells at all (a recipe, or
-- anything else that never reaches the spellbook), so this is kept for /bms debug
-- instead of printing a chat line with a bare spell number a minute later.
local function NotPlaced(id, why)
    local entry = spells[id] or Spell(id)
    stats.notPlaced = (stats.notPlaced or 0) + 1
    stats.lastNotPlaced = (entry and Literal(entry.name) or ("spell " .. id)) .. " (" .. why .. ")"
    Log((entry and Literal(entry.name) or "spell") .. " (" .. id .. "): not placed, " .. why)
end

local function Now()
    return type(GetTime) == "function" and GetTime() or 0
end

-- The active spec group (1 if the client has no spec groups; nil if it won't say, or isn't ready yet: a group
-- read too early at login would later look like a switch and drop a real new spell).
local function ActiveGroup()
    local info = C_SpecializationInfo
    if not info or type(info.GetActiveSpecGroup) ~= "function" then return 1 end
    if type(info.IsInitialized) == "function" then
        local readyOK, isReady = pcall(info.IsInitialized)
        if readyOK and not Secret(isReady) and isReady == false then return nil end
    end
    local ok, group = pcall(info.GetActiveSpecGroup)
    if ok and Number(group) then return group end
end

local function Switching()
    -- (no game clock: no window, rather than one that never closes)
    return type(GetTime) == "function" and switchSince ~= nil and switchUntil ~= nil and Now() < switchUntil
end

-- A spec switch, or its bars still arriving: start or extend the window (see SPEC_QUIET). Spells learned in
-- the second before it starts are the switch's too (the game can teach a spec's spells before it reports the
-- switch), and go; anything waiting longer was learned before the switch and stays.
local function SpecSwitch()
    local now = Now()
    local starting = not Switching()
    if starting then switchSince = now end
    switchUntil = math.min(now + SPEC_QUIET, switchSince + SPEC_LIMIT)
    specGroup = ActiveGroup() or specGroup
    if starting then
        for index = #learnQueue, 1, -1 do
            local queued = learnQueue[index]
            if (queued.at or 0) > now - 1 then
                RemoveLearned(index)
                NotPlaced(queued.id, "came back with a spec switch")
            end
        end
    end
end

-- The spec group can change before the game reports the switch: then the switch has begun.
local function CheckGroup()
    local group = ActiveGroup()
    if group ~= nil and specGroup ~= nil and group ~= specGroup then SpecSwitch() end
end

-- `fresh`: whether the spell was new to this character when the game reported it (see `seen`). Decided now:
-- the next spellbook scan records it, so by the time it is placed it is no longer new.
local function QueueLearned(id)
    if learnedByID[id] then return end
    if #learnQueue >= LEARN_LIMIT then
        NotPlaced(id, "too many learned at once")
        Warn("queue", "Too many spells learned at once; the rest were not placed. /bms debug for status.")
        return
    end
    local entry = spells[id] or Spell(id)
    local fresh = not (seen and (seen[id] or (entry and seen[entry.name])))
    local queued = { id = id, fresh = fresh, at = Now() }
    learnedByID[id] = queued
    learnQueue[#learnQueue + 1] = queued
    RequestData(id)
    C_Timer.After(LEARN_TIMEOUT, function()
        if learnedByID[id] ~= queued then return end
        for index, queuedEntry in ipairs(learnQueue) do
            if queuedEntry == queued then
                RemoveLearned(index)
                NotPlaced(id, "no spellbook entry after " .. LEARN_TIMEOUT .. " s")
                break
            end
        end
    end)
end

local function ProcessLearned()
    CheckGroup()   -- (a switch not yet reported drops what it taught before this runs)
    local index = 1
    while db.autoPlace and index <= #learnQueue do
        if Locked() or Cursor() ~= nil or TemporaryBar() then break end
        local queued = learnQueue[index]
        local entry = spells[queued.id]
        local passive
        if type(C_Spell.IsSpellPassive) == "function" then
            local ok, value = pcall(C_Spell.IsSpellPassive, queued.id)
            if ok and not Secret(value) then passive = value end
        end
        if not entry and passive == false and Known(queued.id) then
            -- Training multiple ranks in one burst can leave only the
            -- highest rank in the current book view. Recognize the rank-1
            -- learn, but place the verified active higher rank below.
            local base = Spell(queued.id)
            local family = base and families[base.name]
            if base and base.rank == 1 and family and not family.ambiguous then entry = base end
        end
        local defer = false
        if passive == true then
            -- Passive spells never go on a bar.
        elseif not entry or not entry.placementReady then
            -- The book and text can arrive after the learn event. Keep the
            -- intent until a book/data event or the expiry callback.
            defer = true
        elseif not queued.fresh then
            NotPlaced(queued.id, "you had it before (spellbook or bars, either spec)")
        elseif (not entry.rank or entry.rank == 1) and not AlreadyOnBar(entry) then
            local family = families[entry.name]
            if not family or not family.ambiguous then
                local best = family and family.highest or entry
                local slot, bar, button = FirstEmptySlot()
                if slot then
                    local changed, blocked, reason = SetSpell(slot, nil, best, bar, button)
                    if changed then
                        stats.placed = stats.placed + 1
                        if Helper.BarLayouts and Helper.BarLayouts.NoteAutoPlace then Helper.BarLayouts.NoteAutoPlace(slot) end
                    end
                    if reason then stats.status = reason end
                    if not changed and blocked then break end
                else
                    if db.reportChanges then
                        Say("No empty slot on the visible action bars for " .. Literal(entry.name) .. ".")
                    end
                    NotPlaced(queued.id, "no empty slot on the visible action bars")
                end
            end
        end
        if defer then index = index + 1 else RemoveLearned(index) end
    end
end

local function HasWork()
    -- (placement on: every scan also records the spellbook, see `seen`)
    return db.enabled or db.autoPlace or ownedCursorID ~= nil
end

local function APIsAvailable()
    return C_SpellBook and type(C_SpellBook.GetNumSpellBookSkillLines) == "function" and
        type(C_SpellBook.GetSpellBookSkillLineInfo) == "function" and
        type(C_SpellBook.GetSpellBookItemInfo) == "function" and
        (type(C_SpellBook.IsSpellKnown) == "function" or type(IsPlayerSpell) == "function") and
        C_Spell and type(C_Spell.GetSpellInfo) == "function" and type(C_Spell.GetSpellSubtext) == "function" and
        (type(C_Spell.PickupSpell) == "function" or type(PickupSpell) == "function") and
        type(GetActionInfo) == "function" and type(GetCursorInfo) == "function" and
        type(PlaceAction) == "function" and type(ClearCursor) == "function" and
        type(InCombatLockdown) == "function" and C_Timer and type(C_Timer.After) == "function"
end

Process = function()
    scheduled = false
    if not ready or not HasWork() then pending, reportRequested = false, false; return end
    if Locked() then stats.status = "waiting for combat to end"; return end
    if not APIsAvailable() then
        stats.status = "required API unavailable"
        Warn("apis", "Required spellbook/action APIs are unavailable. This build targets Forever 1.60.1.")
        return
    end
    running = true
    ReleaseOwnedCursor()
    if Cursor() ~= nil then
        running = false; stats.status = "waiting for an empty cursor"; return
    end
    if bookDirty and not BuildBook() then
        running = false; stats.status = "waiting for spellbook data"; return
    end
    pending = bookDirty
    -- While a spec switch settles its bars are still arriving: no slot is changed until they have (BarLayouts
    -- waits the same way), and one scan follows. (The spellbook above was still read: the new spec's spells
    -- are recorded as had, see `seen`.)
    if Switching() then
        running, pending = false, true
        stats.status = "waiting for the bars after a spec switch"
        if not retryAfterSwitch then
            retryAfterSwitch = true
            C_Timer.After(math.max(0.05, switchUntil - Now() + 0.05), function()
                retryAfterSwitch = false
                Request(false)
            end)
        end
        return
    end
    stats.changed, stats.spellButtons, stats.macros, stats.unresolved, stats.placed = 0, 0, 0, 0, 0
    stats.status = "up to date"
    for slot = 1, db.enabled and rankWanted and SLOT_LIMIT or 0 do
        if Locked() then pending = true; stats.status = "waiting for combat to end"; break end
        local kind, id = Action(slot)
        if kind == "macro" then
            stats.macros = stats.macros + 1
        elseif kind == "spell" and Number(id) and id > 0 then
            stats.spellButtons = stats.spellButtons + 1
            local old = spells[id] or Spell(id)
            local family = old and families[old.name]
            local attempt = old and family and (slot .. ":" .. family.highest.id)
            if old and old.rank and family and not family.ambiguous and old.rank < family.highest.rank and
                not failedUpgrades[attempt] then
                local changed, blocked, reason
                if IsTotemSlot(slot) then
                    changed, blocked, reason = SetTotem(slot, old, family.highest)
                else
                    changed, blocked, reason = SetSpell(slot, old, family.highest)
                end
                if changed then stats.changed = stats.changed + 1 end
                if reason then stats.status = reason end
                -- A slot that wouldn't take the rank is left alone for the rest of the session: retrying it on
                -- every later event picked it up and put it down again and again (see TotemSlots).
                if not changed and reason and not reason:find("^waiting") then failedUpgrades[attempt] = true end
                if blocked then pending = true; break end
            elseif not old or not old.rank then
                stats.unresolved = stats.unresolved + 1
            end
        end
    end
    if db.autoPlace and #learnQueue > 0 then ProcessLearned() end
    running = false
    if not pending then rankWanted = false end
    if reportRequested and not pending then
        Say("Scan complete: " .. stats.changed .. " spell button(s) upgraded; " .. stats.spellButtons ..
            " spell button(s) checked. Status: " .. stats.status .. ".")
        reportRequested = false
    end
    if pending and not Locked() and Cursor() == nil then Request(false) end
end

Request = function(rebuild, report, ranks)
    if ranks and db.enabled then rankWanted = true end
    if rebuild then bookDirty = true; bookRevision = bookRevision + 1 end
    if report then reportRequested = true end
    pending = true
    if not ready or not HasWork() or scheduled or running or Locked() then return end
    if not C_Timer or type(C_Timer.After) ~= "function" then
        Warn("timer", "The timer API is unavailable; automatic scans cannot run.")
        return
    end
    scheduled = true
    C_Timer.After(0.20, Process)
end

local function Debug()
    local version, build, _, interface = GetBuildInfo()
    Say("max-rank spells, ReadyToWork v" .. Helper.version .. "; client=" .. Literal(version) .. "; build=" .. Literal(build) ..
        "; interface=" .. (Number(interface) and interface or "unknown") .. ".")
    Say("enabled=" .. tostring(db.enabled) .. "; cast checks=" .. tostring(db.castCheck) ..
        "; new-spell placement=" .. tostring(db.autoPlace) .. "; learned queue=" .. #learnQueue ..
        "; pending=" .. tostring(pending) .. "; status=" .. (stats.status or "waiting") ..
        "; ranked families=" .. (stats.families or 0) .. "; ambiguous=" .. (stats.ambiguous or 0) ..
        "; spell buttons=" .. (stats.spellButtons or 0) .. "; macros=" .. (stats.macros or 0) ..
        "; unresolved/unranked=" .. (stats.unresolved or 0) .. "; slots=1-" .. SLOT_LIMIT .. ".")
    Say("learned spells not placed=" .. (stats.notPlaced or 0) ..
        (stats.lastNotPlaced and ("; last: " .. stats.lastNotPlaced) or "") .. ".")
    local log = type(db.learnLog) == "table" and db.learnLog or {}
    if #log > 0 then
        Say("Learned spells and rank changes, latest last:")
        for index = math.max(1, #log - 9), #log do Say(log[index]) end
    end
end

-- /rtw spells, and the names from before: /bms and /balmaxspells (BalMaxSpells), /mrb and /maxrankbars (Max
-- Rank Bars). "on"/"off" switch rank upgrades, as ReadyToWork's menu does for every feature.
local function Command(message)
    if not ready then
        Say(Helper.maxSpellsHeldBack or "max-rank spells haven't started yet.")
        return
    end
    local command, argument = (message or ""):match("^%s*(%S*)%s*(.-)%s*$")
    command, argument = command:lower(), argument:lower()
    if command == "on" or command == "off" or command == "toggle" then
        if command == "toggle" then db.enabled = not db.enabled else db.enabled = command == "on" end
        syncCastEvent()
        if db.enabled then Request(true,nil,true) else rankWanted, reportRequested = false, false end
        Say(db.enabled and "Rank upgrades enabled." or "Rank upgrades disabled.")
    elseif command == "scan" then
        if db.enabled then
            failedUpgrades = {}   -- (asked for: slots that wouldn't take a rank earlier get one more try)
            Request(true, true, true)
            if Locked() then Say("Scan queued until combat ends.")
            elseif Cursor() ~= nil then Say("Scan queued until the cursor is empty.") end
        else Say("Switch rank upgrades on first: /rtw spells on.") end
    elseif command == "casts" then
        if argument == "" or argument == "toggle" then db.castCheck = not db.castCheck
        elseif argument == "on" or argument == "off" then db.castCheck = argument == "on"
        else Say("Use /rtw spells casts on, /rtw spells casts off, or /rtw spells casts to toggle."); return end
        syncCastEvent()
        Say("Successful-cast safety checks = " .. (db.castCheck and "on" or "off") .. ".")
    elseif command == "place" then
        if argument == "" or argument == "toggle" then db.autoPlace = not db.autoPlace
        elseif argument == "on" or argument == "off" then db.autoPlace = argument == "on"
        else Say("Use /rtw spells place on or /rtw spells place off."); return end
        if not db.autoPlace then learnQueue, learnedByID = {}, {} end
        Say("Place newly learned spells on your bars = " .. (db.autoPlace and "on" or "off") .. ".")
    elseif command == "gamepush" then
        if argument == "on" or argument == "off" then db.blockGamePush = argument == "off"
        elseif argument == "" or argument == "toggle" then db.blockGamePush = not db.blockGamePush
        else Say("Use /rtw spells gamepush on (the game puts new spells on your bars) or off (ReadyToWork keeps it off)."); return end
        ApplyGamePush(true)
        if pushWaiting then Say("The game's setting changes when the fight ends.") end
    elseif command == "debug" or command == "status" then Debug()
    elseif command == "options" or command == "config" or command == "minimap" then
        -- (BalMaxSpells had its own window and minimap button; both are ReadyToWork's menu now)
        Say("Max-rank spells are in ReadyToWork's menu now: click the ReadyToWork minimap button, or /rtw menu.")
        if Helper.ShowMenu and command ~= "minimap" then Helper.ShowMenu() end
    else
        Say("/rtw spells scan | on | off | casts [on|off] | place [on|off] | gamepush [on|off] | status  (/bms and /mrb still work)")
        Say("Rank upgrades are on by default. Combat/cursor work waits. Macros keep their own cast commands. " ..
            "Turn on chat reports in Spell ranks settings to print upgrades.")
    end
end

SLASH_BALMAXSPELLS1 = "/bms"
SLASH_BALMAXSPELLS2 = "/balmaxspells"
SLASH_BALMAXSPELLS3 = "/mrb"
SLASH_BALMAXSPELLS4 = "/maxrankbars"
SlashCmdList.BALMAXSPELLS = Command
Helper.commands.spells = Command
Helper.commands.maxspells = Command
Helper.help[#Helper.help + 1] = "/rtw spells [scan|on|off|casts|place|status] - keep your bars on the highest spell ranks"

-- Shared with BarLayouts.lua, so saving and restoring bars reads spells, the cursor and combat exactly as
-- the rank upgrades do.
-- `ours`: how many of ReadyToWork's own bar changes are running (rank upgrades, placements, profile loads).
-- Slot and cursor events while it is above 0, or within OURS_GRACE seconds after, are ReadyToWork's, never
-- "your edit" for bar profile auto-update. (Guessing from the cursor alone counted Spell ranks' own pickups.)
local OURS_GRACE = 0.5
local ours, oursUntil = 0, nil
local function BeginOurs() ours = ours + 1 end
local function EndOurs()
    ours = math.max(0, ours - 1)
    if ours == 0 then oursUntil = Now() + OURS_GRACE end
end
local function Ours()
    return ours > 0 or (oursUntil ~= nil and Now() <= oursUntil)
end

Helper.BarTools = {
    BeginOurs = BeginOurs, EndOurs = EndOurs, Ours = Ours,
    SLOT_LIMIT = SLOT_LIMIT, Secret = Secret, Number = Number, Text = Text, IsTotemSlot = IsTotemSlot,
    Locked = Locked, Cursor = Cursor, TemporaryBar = TemporaryBar, Spell = Spell, Known = Known,
    -- The highest rank you know of a spell, by name (nil when unknown, or two spells share a rank).
    HighestKnown = function(name)
        if bookDirty and not BuildBook() then return nil end
        local family = families[name]
        if family and not family.ambiguous then return family.highest end
    end,
    -- Whether rank upgrades are on: then a higher rank of a saved spell counts as the same button.
    UpgradesOn = function() return ready == true and db ~= nil and db.enabled == true end,
}

local bookEvents = {
    PLAYER_ENTERING_WORLD = true, SPELLS_CHANGED = true,
    LEARNED_SPELL_IN_SKILL_LINE = true, PLAYER_LEVEL_UP = true,
    SPELL_DATA_LOAD_RESULT = true, SPELL_TEXT_UPDATE = true,
}
local barEvents = {
    "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_PAGE_CHANGED", "UPDATE_BONUS_ACTIONBAR",
    "UPDATE_SHAPESHIFT_FORM", "UPDATE_OVERRIDE_ACTIONBAR", "UPDATE_VEHICLE_ACTIONBAR",
    "UPDATE_POSSESS_BAR", "PLAYER_REGEN_ENABLED", "CURSOR_CHANGED",
}

-- Whether the old separate addon is still loaded (its folder put back, say): then it keeps the bars and this
-- stays off, so two copies never change the same slots.
local function OldAddonLoaded()
    local loaded = C_AddOns and C_AddOns.IsAddOnLoaded
    if type(loaded) ~= "function" then return false end
    local ok, yes = pcall(loaded, OLD_ADDON)
    return ok and True(yes)
end

Helper.Feature(function()
    if ready then return end
    if OldAddonLoaded() then
        Helper.maxSpellsHeldBack = "BalMaxSpells is now part of ReadyToWork, but the separate BalMaxSpells addon is " ..
            "still loaded, so it keeps your bars. Disable BalMaxSpells in the AddOns list and /reload."
        Say(Helper.maxSpellsHeldBack)
        return
    end
    db = Helper.db.maxSpells
    if Secret(db.enabled) or type(db.enabled) ~= "boolean" then db.enabled = true end
    -- Older versions prefilled true for every installation. Make casting opt-in once.
    if not db.castCheckOptInVersion then
        db.castCheck, db.castCheckOptInVersion = false, 1
    end
    if type(db.castCheck) ~= "boolean" then db.castCheck = false end
    if Secret(db.autoPlace) or type(db.autoPlace) ~= "boolean" then db.autoPlace = true end
    if Secret(db.blockGamePush) or type(db.blockGamePush) ~= "boolean" then db.blockGamePush = true end
    -- This character's spells it has had (see `seen`). From the start, everything in its saved bar profiles and
    -- their records counts too, for both specs; the spellbook and the bars are added at every scan.
    local guidOK, guid = pcall(UnitGUID, "player")
    if guidOK and Text(guid) then
        if type(db.seen) ~= "table" then db.seen = {} end
        if type(db.seen[guid]) ~= "table" then db.seen[guid] = {} end
        seen = db.seen[guid]
        local saved = type(Helper.db.bars) == "table" and Helper.db.bars[guid]
        if type(saved) == "table" then
            for _, profile in pairs(type(saved.profiles) == "table" and saved.profiles or {}) do
                if type(profile) == "table" and type(profile.layout) == "table" then SeeSlots(profile.layout.slots) end
            end
            for _, record in pairs(type(saved.specs) == "table" and saved.specs or {}) do
                if type(record) == "table" then
                    for _, field in ipairs({ "base", "undo", "undoBase" }) do
                        if type(record[field]) == "table" then SeeSlots(record[field].slots) end
                    end
                end
            end
        end
    end
    ready = true
    specGroup = ActiveGroup()
    for name in pairs(bookEvents) do driver:RegisterEvent(name) end
    for _, name in ipairs(barEvents) do driver:RegisterEvent(name) end
    for _, name in ipairs({ "ACTIVE_TALENT_GROUP_CHANGED", "ACTIVE_COMBAT_CONFIG_CHANGED", "PLAYER_TALENT_UPDATE",
        "SPELL_PUSHED_TO_ACTIONBAR", "CVAR_UPDATE" }) do
        pcall(driver.RegisterEvent, driver, name)
    end
    syncCastEvent()
    ApplyGamePush()
    Request(true,nil,true)
end)

driver:SetScript("OnEvent", function(self, event, arg1, arg2, guildPerk)
    if not ready then return end
    -- World entry only matters while the initial spellbook is becoming available.
    if event == "PLAYER_ENTERING_WORLD" and not True(arg1) and not True(arg2) then return end
    if specGroup == nil then specGroup = ActiveGroup() end   -- (spec groups may not be ready at login)
    if bookEvents[event] then
        if (event == "SPELL_DATA_LOAD_RESULT" or event == "SPELL_TEXT_UPDATE") and
            not (Number(arg1) and (requested[arg1] or learnedByID[arg1])) then
            -- Every spell anything in the game loads (tooltips, other addons) sends these.
            -- Only the ones this addon asked for can change a rank it is waiting on.
            return
        end
        if event == "LEARNED_SPELL_IN_SKILL_LINE" and db.autoPlace and
            Number(arg1) and arg1 > 0 and arg1 % 1 == 0 and
            not Secret(guildPerk) and not True(guildPerk) and (not IsLoggedIn or IsLoggedIn()) then
            if Switching() then
                NotPlaced(arg1, "came back with a spec switch")
            else
                QueueLearned(arg1)
            end
        elseif event == "SPELL_DATA_LOAD_RESULT" and Number(arg1) and learnedByID[arg1]
            and not Secret(arg2) and arg2 == false then
            for index, queued in ipairs(learnQueue) do
                if queued.id == arg1 then
                    RemoveLearned(index)
                    NotPlaced(arg1, "its spell data failed to load")
                    break
                end
            end
        end
        -- (a switch's spellbook still changing keeps it open, up to SPEC_LIMIT)
        if event == "SPELLS_CHANGED" and Switching() then SpecSwitch() end
        -- Each missing ID is requested once per login. Failed/empty data
        -- must not create a request/result/rebuild loop for unranked spells.
        bookDirty = true
        local rankData = Number(arg1) and rankDataWaiting[arg1]
            and (event == "SPELL_DATA_LOAD_RESULT" or event == "SPELL_TEXT_UPDATE")
        if rankData then rankDataWaiting[arg1] = nil end
        local readyRank = rankData and db.enabled and not Secret(arg2) and arg2 ~= false
        -- A spell learned (see LEARN_RANK_WINDOW): its new rank goes on the bars now, not at the next scan.
        if event == "LEARNED_SPELL_IN_SKILL_LINE" and db.enabled and Number(arg1) and
            not Secret(guildPerk) and not True(guildPerk) then
            rankLearnUntil = Now() + LEARN_RANK_WINDOW
            readyRank = true
        elseif event == "SPELLS_CHANGED" and db.enabled and rankLearnUntil and Now() <= rankLearnUntil then
            readyRank = true
        end
        if readyRank or pending or #learnQueue > 0 then Request(true,nil,readyRank) end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if db.enabled and not Secret(arg1) and arg1 == "player" and db.castCheck then Request(false,nil,true) end
    elseif event == "CURSOR_CHANGED" then
        if not running then
            ownedCursorID = nil -- A later cursor change belongs to the user.
            if pending or #learnQueue > 0 then Request(false) end
        end
    elseif event == "ACTIVE_TALENT_GROUP_CHANGED" or event == "ACTIVE_COMBAT_CONFIG_CHANGED" then
        -- (Blizzard's own talent frame ends a switch on ACTIVE_COMBAT_CONFIG_CHANGED)
        SpecSwitch()
        bookDirty = true
        -- The other spec's bars come with the switch: their ranks are checked once it settles (Process waits for
        -- that). Without the rank pass a rank trained in one spec stayed off the other spec's bars until login.
        if db.enabled or db.autoPlace or pending or #learnQueue > 0 then Request(true, nil, true) end
    elseif event == "PLAYER_TALENT_UPDATE" then
        if Switching() then SpecSwitch() end
        bookDirty = true
        if pending or #learnQueue > 0 then Request(true) end
    elseif event == "CVAR_UPDATE" then
        GamePushChanged(arg1, arg2)
    elseif event == "SPELL_PUSHED_TO_ACTIONBAR" then
        -- The game itself put a spell on the bars (its AutoPushSpellToActionBar setting, when you let it): noted,
        -- so /rtw spells status can tell its placements from ReadyToWork's.
        if Number(arg1) and Number(arg2) then
            local entry = spells[arg1] or Spell(arg1)
            Log((entry and Literal(entry.name) or "spell") .. " (" .. arg1 .. "): the game itself put it in slot " ..
                arg2 .. (Number(guildPerk) and (" (bar page " .. guildPerk .. ")") or ""))
        end
        if pending or #learnQueue > 0 then Request(false) end
    elseif event == "ACTIONBAR_SLOT_CHANGED" then
        -- (the new spec's bars arriving keep the switch open, up to SPEC_LIMIT)
        if Switching() then SpecSwitch() end
        if (pending or #learnQueue > 0) and not running then Request(false) end
    else
        if event == "PLAYER_REGEN_ENABLED" and pushWaiting then pushWaiting = false; ApplyGamePush() end
        if pending or #learnQueue > 0 then Request(event == "UPDATE_SHAPESHIFT_FORM") end
    end
end)
