-- Bar profiles: named action bar layouts ("Raid healing", "Group healing"), as many as you like, for each
-- character. A profile holds what was in every action slot (1-180: all bars, stance and stealth pages, the
-- extra bars) and remembers which spec it was saved in. Loading one puts it on the spec you are in.
-- The swap button and its fan are in BarSwap.lua; the menu row in Minimap.lua.
--
-- Keeping specs apart:
--   * Only the active spec's bars can be read or changed (the game swaps the bars with the spec), so a save
--     reads, and a load changes, the active spec only. Profiles from the other spec are listed apart, and
--     chat names both specs when one is loaded.
--   * Menu entries, fan tiles and the name box carry the spec they were made for: used after a spec switch,
--     they are refused, never applied to the other spec.
--   * Nothing is saved or loaded while the bars are still arriving: for 3 quiet seconds (at most 15) after
--     logging in or switching spec, while casting (a spec switch is a cast), or on a vehicle bar; loading
--     also waits for the end of combat and an empty cursor.
--   * A load re-checks the active spec, combat and the cursor before every slot and stops if any changed.
-- Updating ("adjust things for this current profile, update it, and move on"):
--   * Only the profile loaded on the spec you are in, whichever spec it was saved in; you can't pick another
--     one (1.19.0's "update" could overwrite any profile from either spec: "I don't see the point in that").
--     1.21.0 also refused a profile saved in the other spec, so the option never appeared for it ("Did you
--     hardcode this shit to only do one fucking spec?").
--   * Offered only once you have changed the bars since that profile was loaded, saved or updated on this
--     spec. Each spec keeps the bars as they were then (`base`). Comparing with the profile itself instead
--     counted every button a load couldn't place (a talent spell of the other spec, an item no longer carried)
--     as a change, right after loading.
--   * Writes only the slots you changed: the rest of the profile stays as saved. Where the profile has a button
--     that wasn't on these bars when the record was made (this spec couldn't place it: the other spec's
--     talents, an item not carried, a mount; or it was changed from the other spec since), you can't see what
--     you would replace: emptying that slot (dragging off what a load left there) is never written, and putting
--     a button there makes the update ask first, naming both. (The first review lost TestHeal's Water Shield
--     when the stray Chain Heal a load left in its slot was dragged off; the third lost a button moved into such
--     a slot when it was left out instead.) Emptied slots alone are offered as "why can't it take your
--     changes?", never silently missing.
--   * Records from builds before 1.21.1 have no `base`, and updating a profile also loaded on the other spec
--     gives that spec a copy of the profile instead: a guess, counting only slots that can't be leftovers. A
--     guess becomes a real record the first time it is read. An undo back to a profile with no record counts
--     from the bars it puts back.
--   * The game reports slot changes at once, inside PlaceAction: during a load or undo they are ReadyToWork's
--     own, and the undo keeps a copy of the record, not the record itself (the third review: load, then undo,
--     made up a change).
--   * A crash right after a load leaves the record of the profile loaded before (SavedVariables are written
--     only at /reload or logout). When the bars hold none of the loaded profile's own buttons where it and
--     another profile differ, and some of the other's, an update asks first.
--   * Not while something is on the cursor (a button being dragged reads as an empty slot).
--   * The profile keeps the spec it was saved in. No earlier copy is kept. Renaming, and deleting (asked
--     first), are the only other changes.
-- Undoing:
--   * Every load first keeps the bars as they were, per spec: "Undo the last load" (again: redo).
--   * A load only changes slots it could also put back: mounts, pets, items you no longer carry, spells this
--     spec doesn't know and anything else ReadyToWork can't place are left where they are.
-- Spells are put back by spell ID, or the highest rank you know of the same spell; macros by name (the game
-- names a macro button's spell, not the macro); items only while you have them.
local _, Helper = ...

local SETTLE_SECONDS, SETTLE_LIMIT = 3, 15
local PROBLEMS_SHOWN = 6
local NAME_LIMIT = 32
local T                                   -- Helper.BarTools (MaxSpells.lua)
local settings                            -- Helper.db.barProfiles
local unsettledSince, unsettledUntil      -- bars loading after login or a spec switch
local settleToken = 0
local lastAutoWarning = {}
local SyncAutoUpdate

local Bars = {}
Helper.BarLayouts = Bars
Bars.NAME_LIMIT = NAME_LIMIT

local function Say(text)
  Helper.Print(text)
end

local function SpecName(spec)
  return "Spec " .. tostring(spec)
end
Bars.SpecName = SpecName

local function When(at)
  return type(at) == "number" and date("%d %b %H:%M", at) or "?"
end

-- Tells the swap button (BarSwap.lua) that profiles or the active one changed.
local function Changed()
  if Bars.onChange then
    Bars.onChange()
  end
end

-- The active spec group (1 or 2), or nil when the game won't say. A client without spec groups has one.
function Bars.ActiveSpec()
  local info = C_SpecializationInfo
  if not info or type(info.GetActiveSpecGroup) ~= "function" then
    return 1
  end
  local ok, group = pcall(info.GetActiveSpecGroup)
  if ok and T.Number(group) and group >= 1 and group % 1 == 0 then
    return group
  end
end

local function Unsettling()
  return unsettledSince ~= nil and GetTime() < unsettledUntil
end

local function ClearAutoWarning(spec, key)
  if spec and key then
    lastAutoWarning[spec .. ":" .. key] = nil
  else
    for k in pairs(lastAutoWarning) do lastAutoWarning[k] = nil end
  end
end

local function Unsettle()
  local now = GetTime()
  -- (a wait that ran out unchecked starts afresh: keeping its old start skipped the wait after a later switch)
  if not Unsettling() then
    unsettledSince = now
  end
  unsettledUntil = math.min(now + SETTLE_SECONDS, unsettledSince + SETTLE_LIMIT)
  settleToken = settleToken + 1
  local token = settleToken
  if C_Timer and type(C_Timer.After) == "function" then
    C_Timer.After(SETTLE_SECONDS + 0.2, function()
      if token == settleToken and SyncAutoUpdate then SyncAutoUpdate(true) end
    end)
  end
end

local function Settled()
  if unsettledSince and GetTime() >= unsettledUntil then
    unsettledSince = nil
  end
  if unsettledSince then
    return false
  end
  local info = C_SpecializationInfo
  if info and type(info.IsInitialized) == "function" then
    local ok, ready = pcall(info.IsInitialized)
    if ok and not T.Secret(ready) and ready == false then
      return false
    end
  end
  return true
end

local function Casting()
  for _, read in ipairs({ UnitCastingInfo, UnitChannelInfo }) do
    if type(read) == "function" then
      local ok, name = pcall(read, "player")
      if ok and (T.Secret(name) or name ~= nil) then
        return true
      end
    end
  end
  return false
end

local function CursorKind()
  local ok, kind, a = pcall(GetCursorInfo)
  if not ok or T.Secret(kind) or T.Secret(a) then
    return "unknown"
  end
  return kind, a
end

-- Why the bars can't be read now (nil when they can).
local function ReadBlocker()
  if not Settled() then
    return "your bars are still loading after logging in or switching spec; try again in a few seconds"
  end
  if Casting() then
    return "wait until your cast finishes"
  end
  if T.TemporaryBar() then
    return "leave the vehicle or special bar first"
  end
end

-- Why the bars can't be changed now (nil when they can).
local function ChangeBlocker()
  if T.Locked() then
    return "bars can only be changed out of combat"
  end
  local why = ReadBlocker()
  if why then
    return why
  end
  if CursorKind() ~= nil then
    return "put down what is on your cursor first"
  end
end

-- Reading slots -------------------------------------------------------------------------------------------

local function MacroName(slot)
  local getText = C_ActionBar and C_ActionBar.GetActionText
  if type(getText) ~= "function" then
    return nil
  end
  local ok, text = pcall(getText, slot)
  if ok and T.Text(text) then
    return text
  end
end

local function macroAt(index)
  if not T.Number(index) or index<=0 then return end
  local ok,name,_,body=pcall(GetMacroInfo,index)
  if ok and T.Text(name) and type(body)=="string" and not T.Secret(body) then
    return {kind="macro",name=name,body=body,scope=index>(MAX_ACCOUNT_MACROS or 120) and "character" or "account"}
  end
end
-- Every macro, read once per frame (a profile comparison asks about each macro slot; reading 150 macros for
-- each one made thousands of calls per update).
local macroCache, macroCacheAt = nil, nil
local function Macros()
  local now = type(GetTime) == "function" and GetTime() or nil
  if macroCache and now and macroCacheAt == now then
    return macroCache
  end
  macroCache, macroCacheAt = {}, now
  for index = 1, (MAX_ACCOUNT_MACROS or 120) + (MAX_CHARACTER_MACROS or 30) do
    local m = macroAt(index)
    if m then
      m.index = index
      macroCache[#macroCache + 1] = m
    end
  end
  return macroCache
end

-- The macro a saved button means: by name (and account or character scope, when saved). The text only tells
-- apart macros that share a name, so editing a macro's text keeps it in every profile. nil when no macro has
-- the name, or several do and none has the saved text.
local function resolveMacro(want)
  local named, exact = 0, nil
  local only
  for _, m in ipairs(Macros()) do
    if m.name == want.name and (not want.scope or want.scope == m.scope) then
      named = named + 1
      only = m.index
      if want.body and want.body == m.body and not exact then
        exact = m.index
      end
    end
  end
  if exact then
    return exact
  end
  return named == 1 and only or nil
end
local function ItemName(id)
  if C_Item and type(C_Item.IsItemDataCachedByID) == "function" and type(C_Item.GetItemNameByID) == "function" then
    local ok, cached = pcall(C_Item.IsItemDataCachedByID, id)
    if ok and cached == true then
      local nameOK, name = pcall(C_Item.GetItemNameByID, id)
      if nameOK and T.Text(name) then
        return name
      end
    end
  end
end

-- What a slot holds: nil when empty, or { kind = "spell" | "macro" | "item" | "other" | "unknown", ... }.
function Bars.ReadSlot(slot)
  local ok, kind, id, subType = pcall(GetActionInfo, slot)
  if not ok or T.Secret(kind) or T.Secret(id) or T.Secret(subType) then
    return { kind = "unknown" }
  end
  if kind == nil then
    local has = C_ActionBar and C_ActionBar.HasAction or HasAction
    if type(has) == "function" then
      local hasOK, occupied = pcall(has, slot)
      if not hasOK or T.Secret(occupied) or occupied == true then
        return { kind = "unknown" }
      end
    end
    return nil
  end
  if kind == "spell" and subType ~= "pet" and T.Number(id) and id > 0 then
    local spell = T.Spell(id)
    return { kind = "spell", id = id, name = spell and spell.name, rank = spell and spell.rank }
  elseif kind == "macro" then
    local name = MacroName(slot)
    local record=macroAt(id)
    if record and (not name or record.name==name) then return record end
    if name then return macroAt(resolveMacro({name=name})) or {kind="unknown"} end
    return {kind="unknown"}
  elseif kind == "item" and T.Number(id) and id > 0 then
    return { kind = "item", id = id, name = ItemName(id) }
  end
  local label = subType == "pet" and "pet ability" or tostring(kind)
  -- (a companion pet's ID is its GUID, a string)
  return { kind = "other", type = label, id = (T.Number(id) or T.Text(id)) and id or nil }
end

-- A layout of `slots`, saved now in `spec`.
local function NewLayout(spec, slots)
  local counts = { spell = 0, macro = 0, item = 0, other = 0, unknown = 0 }
  for _, entry in pairs(slots) do
    counts[entry.kind] = (counts[entry.kind] or 0) + 1
  end
  local _, class = UnitClass("player")
  return { at = time(), spec = spec, class = class, slots = slots, counts = counts }
end

-- Every slot of the active spec's bars.
local function Snapshot(spec)
  local slots = {}
  for slot = 1, T.SLOT_LIMIT do
    slots[slot] = Bars.ReadSlot(slot)
  end
  return NewLayout(spec, slots)
end

local function Label(entry)
  if not entry then
    return "an empty slot"
  elseif entry.kind == "spell" then
    return (entry.name or ("spell " .. entry.id)) .. (entry.rank and (" (Rank " .. entry.rank .. ")") or "")
  elseif entry.kind == "macro" then
    return "macro " .. entry.name
  elseif entry.kind == "item" then
    return entry.name or ("item " .. entry.id)
  elseif entry.kind == "other" then
    return "a " .. entry.type .. " button"
  end
  return "a button the game didn't show"
end

-- Whether `have` already is what `want` asks for.
local function Matches(want, have)
  if want == nil or have == nil then
    return want == have
  end
  if want.kind ~= have.kind then
    return false
  end
  if want.kind == "spell" then
    if have.id == want.id then
      return true
    end
    -- A higher rank of the same spell, as rank upgrades leave it, while they are on.
    return T.UpgradesOn() and want.name ~= nil and have.name == want.name and (have.rank or 0) >= (want.rank or 0)
  elseif want.kind == "macro" then
    if have.name ~= want.name or (want.scope and have.scope and have.scope ~= want.scope) then
      return false
    end
    -- (an edited macro is still the same button; with two macros of that name only the saved text tells)
    return (want.body ~= nil and have.body == want.body) or resolveMacro({ name = want.name, scope = want.scope }) ~= nil
  elseif want.kind == "item" then
    return have.id == want.id
  elseif want.kind == "other" then
    -- (profiles saved before 1.30 kept no ID for companion pets: any of the same kind matches those)
    return have.type == want.type and (want.id == nil or have.id == want.id)
  end
  return false
end

local function Placeable(entry)
  return entry == nil or entry.kind == "spell" or entry.kind == "macro" or entry.kind == "item"
end

local function Unreadable(entry)
  return entry ~= nil and entry.kind == "unknown"
end

-- Whether a load could put `want` on a bar now (as PickUp checks, without picking anything up).
local function CanLoad(want)
  if want.kind == "spell" then
    return T.Known(want.id) or (want.name ~= nil and T.HighestKnown(want.name) ~= nil)
  elseif want.kind == "macro" then
    return resolveMacro(want) ~= nil
  elseif want.kind == "item" then
    local countOK, count = pcall(C_Item.GetItemCount, want.id)
    local wornOK, worn = pcall(C_Item.IsEquippedItem, want.id)
    return (countOK and T.Number(count) and count > 0) or (wornOK and worn == true)
  end
  return false
end

-- Whether a slot holding `entry` could be set back to it (empty, or a spell, macro or item you have now). A load
-- never covers or clears a button that couldn't be put back: an undo would lose it (a used-up potion, a spell
-- this spec doesn't know).
local function Restorable(entry)
  return entry == nil or (Placeable(entry) and CanLoad(entry))
end

-- Changing slots ------------------------------------------------------------------------------------------

-- Puts `want` on the (empty) cursor. Returns what is now on it, or nil and why not.
-- The spell ID a load puts on the bars for `want`: with rank upgrades on, the highest rank you know of it (a
-- profile saved before you trained a rank put the old rank back, and nothing upgraded it until the next login);
-- otherwise the saved rank, or the highest you know when that one is gone. nil when you know none.
local function LoadSpellID(want)
  if T.UpgradesOn() and want.name then
    local best = T.HighestKnown(want.name)
    if best then
      return best.id
    end
  end
  if T.Known(want.id) then
    return want.id
  end
  local best = want.name and T.HighestKnown(want.name)
  return best and best.id or nil
end

local function PickUp(want)
  if want.kind == "spell" then
    local id = LoadSpellID(want)
    if not id then
      return nil, "not learned"
    end
    local pickup = C_Spell and C_Spell.PickupSpell or PickupSpell
    local kind, cursorID
    if type(pickup) == "function" and pcall(pickup, id) then
      kind, cursorID = T.Cursor()
    end
    if kind ~= "spell" or cursorID ~= id then
      return nil, "the game didn't pick it up"
    end
    return { kind = "spell", id = id }
  elseif want.kind == "macro" then
    local index = resolveMacro(want)
    if not index then
      return nil, "macro missing, changed, or ambiguous"
    end
    if not pcall(PickupMacro, index) or CursorKind() ~= "macro" then
      return nil, "the game didn't pick it up"
    end
    return macroAt(index)
  elseif want.kind == "item" then
    local countOK, count = pcall(C_Item.GetItemCount, want.id)
    local wornOK, worn = pcall(C_Item.IsEquippedItem, want.id)
    if not (countOK and T.Number(count) and count > 0) and not (wornOK and worn == true) then
      return nil, "not in your bags"
    end
    local kind, cursorID
    if pcall(C_Item.PickupItem, want.id) then
      kind, cursorID = CursorKind()
    end
    if kind ~= "item" or cursorID ~= want.id then
      return nil, "the game didn't pick it up"
    end
    return { kind = "item", id = want.id }
  end
  return nil, "ReadyToWork can't place these"
end

local function DropCursor()
  if CursorKind() ~= nil then
    pcall(ClearCursor)
  end
end

-- `want` into `slot`; whatever was there is dropped (it was kept for undo first). Returns whether it worked,
-- why not, and whether the slot was touched at all (nothing is, when `want` couldn't be picked up).
local function Put(slot, want)
  if T.IsTotemSlot(slot) then
    -- The totem bar takes only spells, through SetMultiCastSpell (see TotemSlots in MaxSpells.lua): PlaceAction
    -- there showed the button until the next zone, then the game put the old one back.
    if want.kind ~= "spell" then
      return false, "the totem bar takes only totems", false
    end
    local id = LoadSpellID(want)
    if not id then
      return false, "not learned", false
    end
    if type(SetMultiCastSpell) ~= "function" or not pcall(SetMultiCastSpell, slot, id) then
      return false, "the totem bar didn't take it", false
    end
    local now = Bars.ReadSlot(slot)
    if now and now.kind == "spell" and now.id == id then
      return true, nil, true
    end
    return false, "the totem bar didn't confirm it", true
  end
  local held, why = PickUp(want)
  if not held then
    DropCursor()
    return false, why, false
  end
  pcall(PlaceAction, slot)
  DropCursor()
  local now = Bars.ReadSlot(slot)
  if now and now.kind == held.kind and
      ((held.kind == "macro" and Matches(held, now)) or (held.kind ~= "macro" and now.id == held.id)) then
    return true, nil, true
  end
  return false, "the game didn't accept it", true
end

local function Clear(slot)
  pcall(PickupAction, slot)
  DropCursor()
  return Bars.ReadSlot(slot) == nil
end

-- Saved data ----------------------------------------------------------------------------------------------

local function CharacterKey()
  local ok, guid = pcall(UnitGUID, "player")
  if ok and T.Text(guid) then
    return guid
  end
  local name, realm = UnitName("player"), GetRealmName()
  if T.Text(name) then
    return name .. "-" .. (T.Text(realm) and realm or "?")
  end
end

-- This character's data: { name, profiles = { [key] = { name, layout } }, active = { [spec] = key },
-- specs = { [spec] = { undo, undoActive, undoBase, base } } }. nil when there is none yet (and `create` is false).
-- base = { key, slots }: the bars as they were when profile `key` was last loaded, saved or updated on that spec.
Bars.CharacterKey=CharacterKey
local function Character(create)
  local key = CharacterKey()
  if not key then
    return nil
  end
  local store = Helper.db.bars
  local character = store[key]
  if type(character) ~= "table" then
    if not create then
      return nil
    end
    character = {}
    store[key] = character
  end
  character.name = UnitName("player") or character.name
  character.profiles = character.profiles or {}
  character.active = character.active or {}
  character.specs = character.specs or {}
  return character
end

local function SpecState(character, spec)
  character.specs[spec] = character.specs[spec] or {}
  return character.specs[spec]
end

local applying = false   -- a load or undo is changing the slots (see Apply)

-- "Undo the last load", per character and spec, for this session only: { layout = the bars before the load,
-- active = the profile loaded before, base = its record, edited = { [slot] = true } }. `edited` holds the slots
-- you changed since the load; an undo leaves those as you made them. (Before 1.30 the undo was saved and never
-- expired: an undo days later wiped every bar edit made since.)
local undos = {}
local function UndoFor(spec, create)
  local key = CharacterKey()
  if not key or not spec then
    return nil
  end
  local byChar = undos[key]
  if not byChar then
    if not create then
      return nil
    end
    byChar = {}
    undos[key] = byChar
  end
  return byChar[spec]
end
local function SetUndo(spec, undo)
  local key = CharacterKey()
  if not key or not spec then
    return
  end
  undos[key] = undos[key] or {}
  undos[key][spec] = undo
end
local function EachUndo(fn)
  local byChar = undos[CharacterKey() or ""]
  for _, undo in pairs(byChar or {}) do
    fn(undo)
  end
end

local function CopySlots(slots)
  local copy = {}
  for slot, entry in pairs(slots) do
    copy[slot] = entry
  end
  return copy
end

local function CopyRecord(base)
  if type(base) ~= "table" or type(base.slots) ~= "table" then
    return nil
  end
  return { key = base.key, slots = CopySlots(base.slots), guess = base.guess }
end

local function SetBase(character, spec, base)
  SpecState(character, spec).base = base
end

-- Marks profile `key` as loaded on the active spec `spec`, as the bars are now (nil: nothing loaded there).
-- The record (`base`) keeps the bars as they were then: the changes an update writes are counted from it, and
-- a slot where the profile's button differs from it held a button the profile doesn't have (this spec couldn't
-- place the profile's), so an update never writes over the profile's button there.
local function MarkLoaded(character, spec, key)
  ClearAutoWarning(spec, key)
  character.active[spec] = key
  SetBase(character, spec, key and character.profiles[key] and { key = key, slots = Snapshot(spec).slots } or nil)
end

-- A name as it is kept: no colour codes, no spaces at the ends, at most NAME_LIMIT letters.
local function CleanName(name)
  if type(name) ~= "string" then
    return nil, "a profile needs a name"
  end
  name = name:gsub("|", "")
  name = name:gsub("%s+", " ")
  name = name:match("^%s*(.-)%s*$")
  if name == "" then
    return nil, "a profile needs a name"
  end
  if #name > NAME_LIMIT then
    return nil, ("a name can be at most %d letters"):format(NAME_LIMIT)
  end
  return name
end

local function Key(name)
  return name:lower()
end

local function Find(character, rawName)
  local name = CleanName(rawName)
  return name and character and character.profiles[Key(name)] or nil
end

local function Describe(layout)
  local c = layout.counts or {}
  return ("%d spells, %d macros, %d items"):format(c.spell or 0, c.macro or 0, c.item or 0)
end

-- BalHelper 1.18 kept one save (and the one before it) per spec: they become profiles named after the spec.
-- 1.19.0's "update" kept the version it replaced: that becomes a profile of its own, "Name (earlier)".
-- A name no profile has: `stem` cut so `suffix` fits, then numbered ("Heal (earlier)", "Heal (earlier) 2").
-- (cutting the whole name instead made a 32-letter name's copy the name itself, and dropped the copy)
local function FreeName(character, stem, suffix)
  for number = 1, 99 do
    local tail = suffix .. (number > 1 and (" " .. number) or "")
    local name = CleanName(stem:sub(1, NAME_LIMIT - #tail) .. tail)
    if name and not character.profiles[Key(name)] then
      return name
    end
  end
end

local function Migrate()
  for _, character in pairs(Helper.db.bars) do
    if type(character) == "table" and type(character.profiles) == "table" then
      local earlier = {}
      for _, profile in pairs(character.profiles) do
        if type(profile) == "table" and type(profile.previous) == "table" then
          earlier[#earlier + 1] = profile
        end
      end
      for _, profile in ipairs(earlier) do
        local name = FreeName(character, profile.name, " (earlier)")
        if name then
          character.profiles[Key(name)] = { name = name, layout = profile.previous }
        end
        profile.previous = nil
      end
    end
    if type(character) == "table" and type(character.specs) == "table" then
      character.profiles = character.profiles or {}
      for spec, record in pairs(character.specs) do
        if type(record) == "table" then
          -- (saved undos are removed by Core\Migrate.lua; these conversions need the spec names, so they run here)
          for _, field in ipairs({ "saved", "previous" }) do
            local layout = record[field]
            if type(layout) == "table" then
              local name = SpecName(spec) .. (field == "previous" and " (earlier)" or "")
              if not character.profiles[Key(name)] then
                character.profiles[Key(name)] = { name = name, layout = layout }
              end
              record[field] = nil
            end
          end
        end
      end
    end
  end
end

-- The active spec, if it is still the one a menu entry, fan tile or name box was made for.
local function SpecFor(forSpec, nothing)
  local spec = Bars.ActiveSpec()
  if not spec then
    Say("Can't tell which spec is active; " .. nothing .. ".")
    return nil
  end
  if forSpec and forSpec ~= spec then
    Say(("%s isn't active any more (you are in %s); %s."):format(SpecName(forSpec), SpecName(spec), nothing))
    return nil
  end
  return spec
end

-- Loading -------------------------------------------------------------------------------------------------

-- Puts `layout` onto the active spec, which must be `spec`. Returns true when it ran to the end, and whether
-- it touched any slot (a load stopped partway leaves a mix of two layouts).
local function Apply(character, layout, spec, title)
  local why = ChangeBlocker()
  if why then
    Say(("%s: nothing changed, %s."):format(title, why))
    return false
  end
  local _, class = UnitClass("player")
  if layout.class and class and layout.class ~= class then
    Say(title .. ": that layout is from another class; nothing changed.")
    return false
  end
  local current = Snapshot(spec)
  local steps, problems, right = {}, {}, 0
  for slot = 1, T.SLOT_LIMIT do
    local want, have = layout.slots[slot], current.slots[slot]
    if want and want.kind == "unknown" then
      -- not readable when saved: left as it is
    elseif want == nil and T.IsTotemSlot(slot) then
      -- (an empty totem bar slot in the profile: the totem bar is never emptied, see Put)
    elseif Matches(want, have) and not (want and want.kind == "spell" and LoadSpellID(want) and
        have.id ~= LoadSpellID(want)) then
      -- (the right spell on a lower rank than a load gives, with rank upgrades on, is put on the higher rank)
      if want then right = right + 1 end
    elseif not Placeable(want) then
      problems[#problems + 1] = ("%s (slot %d): ReadyToWork can't place these"):format(Label(want), slot)
    elseif not Restorable(have) then
      -- (named as the profile's button that wasn't loaded, and what is in its way)
      problems[#problems + 1] = ("%s (slot %d): %s is there and couldn't be put back"):format(
        want and Label(want) or "an empty slot", slot, Label(have))
    else
      steps[#steps + 1] = { slot = slot, want = want }
    end
  end

  local placed, cleared, stopped, touched = 0, 0, nil, false
  local state = SpecState(character, spec)
  -- (a copy: the record in use must not be the undo's too)
  local undoActive, undoBase = character.active[spec], CopyRecord(state.base)
  -- The game reports each slot change at once, inside PlaceAction and PickupAction: while the load runs, those
  -- are ReadyToWork's own changes, not "your button is back" (SlotChanged), and the record still belongs to the
  -- profile loaded before.
  applying = true
  T.BeginOurs()
  local ok, err = pcall(function()
  for _, step in ipairs(steps) do
    if T.Locked() then stopped = "combat started" break end
    if Bars.ActiveSpec() ~= spec then stopped = "your spec changed" break end
    if CursorKind() ~= nil then stopped = "something was left on your cursor" break end
    if step.want == nil then
      touched = true
      if Clear(step.slot) then
        cleared = cleared + 1
      else
        problems[#problems + 1] = ("slot %d: couldn't clear it"):format(step.slot)
      end
    else
      local done, reason, changed = Put(step.slot, step.want)
      touched = touched or changed
      if done then
        placed = placed + 1
      else
        problems[#problems + 1] = ("%s (slot %d): %s"):format(Label(step.want), step.slot, reason)
      end
    end
  end
  end)
  applying = false
  T.EndOurs()
  if not ok then
    error(err, 0)
  end
  -- "Undo the last load": the bars, the profile loaded, and its record, from before this load. Only when a slot
  -- was touched: a load that changed nothing must not replace the way back to the one before.
  if touched then
    SetUndo(spec, { layout = current, active = undoActive, base = undoBase, edited = {} })
  end

  local summary = ("%s: %d placed, %d cleared, %d already right."):format(title, placed, cleared, right)
  if stopped then
    summary = summary .. " Stopped early: " .. stopped .. "."
  end
  if touched then
    summary = summary .. " Undo: /rtw bars undo."
  end
  Say(summary)
  if #problems > 0 then
    local shown = {}
    for index = 1, math.min(#problems, PROBLEMS_SHOWN) do
      shown[index] = problems[index]
    end
    Say("Not loaded: " .. table.concat(shown, "; ") ..
      (#problems > PROBLEMS_SHOWN and ("; and " .. (#problems - PROBLEMS_SHOWN) .. " more") or "") .. ".")
  end
  return stopped == nil, touched
end

-- After Apply on `spec`: done, it is loaded as the bars are now; stopped partway, the bars are a mix of two
-- layouts and no profile is marked loaded (so an update can't write the mix into either).
local function AfterApply(character, spec, done, touched, key)
  if done then
    MarkLoaded(character, spec, key)
  elseif touched then
    character.active[spec] = nil
    SetBase(character, spec, nil)
  end
end

-- Profile operations (also used by the menu, the fan and the name box) ------------------------------------
-- Each returns true when it did what it says, or false and a reason for the name box.

local function Missing(rawName)
  local text = ('there is no profile named "%s"'):format(tostring(CleanName(rawName) or rawName or ""))
  Say(text:sub(1, 1):upper() .. text:sub(2) .. ".")
  return false, text
end

function Bars.SaveNew(rawName, forSpec)
  local name, bad = CleanName(rawName)
  if not name then
    Say("Not saved: " .. bad .. ".")
    return false, bad
  end
  local spec = SpecFor(forSpec, "nothing saved")
  if not spec then
    return false, "your spec changed"
  end
  local why = ReadBlocker()
  if why then
    Say("Not saved: " .. why .. ".")
    return false, why
  end
  local character = Character(true)
  if not character then
    Say("Can't tell which character this is; nothing saved.")
    return false, "can't tell which character this is"
  end
  if character.profiles[Key(name)] then
    local text = ('a profile named "%s" already exists'):format(character.profiles[Key(name)].name)
    Say("Not saved: " .. text .. ". Pick another name; delete the old one when you no longer want it.")
    return false, text
  end
  local layout = Snapshot(spec)
  character.profiles[Key(name)] = { name = name, layout = layout }
  MarkLoaded(character, spec, Key(name))
  Say(('Saved your %s bars as "%s": %s.'):format(SpecName(spec), name, Describe(layout)))
  Changed()
  return true
end

function Bars.Load(rawName, forSpec)
  local character = Character(false)
  local profile = Find(character, rawName)
  if not profile then
    return Missing(rawName)
  end
  local spec = SpecFor(forSpec, "nothing changed")
  if not spec then
    return false, "your spec changed"
  end
  local layout = profile.layout
  if type(layout) ~= "table" or type(layout.slots) ~= "table" or not T.Number(layout.spec) then
    Say(('"%s" is damaged; nothing changed.'):format(profile.name))
    return false
  end
  local from = layout.spec ~= spec and (" (saved in %s)"):format(SpecName(layout.spec)) or ""
  local done, touched = Apply(character, layout, spec, ('Loaded "%s"%s onto %s'):format(profile.name, from, SpecName(spec)))
  AfterApply(character, spec, done, touched, Key(profile.name))
  Changed()
  return done
end

local function SameRecord(base, key)
  return type(base) == "table" and base.key == key and type(base.slots) == "table"
end

-- The same button either way round (with rank upgrades on, a higher rank of it counts).
local function Same(a, b)
  return Matches(a, b) or Matches(b, a)
end

-- After a crash right after a load (SavedVariables are written only at /reload or logout) the record still
-- names the profile loaded before, and the bars are the other one's. Telling: in the slots where the two
-- profiles differ and both buttons could be on these bars, more of the other profile's buttons are on the bars
-- than of the loaded one's. Empty slots count for neither: a load leaves the slot as it was where it couldn't
-- place a button (a Hearthstone in the bank), and taking buttons off is ordinary editing. Profiles that differ
-- only in buttons this spec can't place (TestHeal and TestHeal (earlier) on Spec 1) are told apart nowhere
-- here, so they never are; and an ordinary change leaves most of the loaded profile's own buttons in place.
local function LooksLike(layout, other, bars)
  local mine, theirs = 0, 0
  for slot = 1, T.SLOT_LIMIT do
    local a, b, have = layout.slots[slot], other.slots[slot], bars[slot]
    if have ~= nil and not Unreadable(have) and not Same(a, b) and Restorable(a) and Restorable(b) then
      if Matches(a, have) then
        mine = mine + 1
      elseif Matches(b, have) then
        theirs = theirs + 1
      end
    end
  end
  return theirs > mine
end

-- What the changes on `spec` are counted from: its record for this profile, or else (no record: written by a
-- build before 1.21.1, or the other spec updated it) a guess. A guess counts a slot only when what is there now
-- could be put back and the button it is counted from could be placed: anything else may be left over from
-- before the load. The first time a guess is read it becomes a real record (see Changes).
local function Record(character, spec, key, layout)
  local state = character.specs[spec]
  if state and SameRecord(state.base, key) then
    return state.base
  end
  return { key = key, slots = layout.slots, guess = true }
end

-- A slot showing the profile's own button where the record has something else (you put it back, or a used-up
-- item came back): from now on it is that button the slot is counted from.
local function Refreshes(record, layout, slot, now)
  local want = layout.slots[slot]
  return record.slots ~= layout.slots and want ~= nil and Matches(want, now) and not Matches(want, record.slots[slot])
end
local function Refresh(record, layout, slot, now)
  if Refreshes(record, layout, slot, now) then
    record.slots[slot] = now
  end
end

local function SlotDiffers(want, was, now)
  return not (Unreadable(now) or Unreadable(was) or Matches(want, now) or Matches(was, now))
end

-- The profile loaded on `spec` and the slots you changed since its record (a slot that differs from the record
-- and from the profile; one either side couldn't read isn't), in three kinds, each with how many:
--   changed  { [slot] = what is there now, or false for empty }: an update writes these.
--   replace  { [slot] = { want, now } }: you put a button where the profile has one that wasn't on these bars
--            (this spec couldn't place it, or it was changed from the other spec). You can't see what it would
--            replace, so an update asks first, naming both.
--   held     { [slot] = the profile's button }: you emptied such a slot (dragged off what a load left there).
--            Never written: you can't take off a button you never saw.
-- nil when nothing is loaded or the bars can't be read now.
-- Only reads, unless `commit` (an update, or your own edit): hovering the swap button or opening the menu used
-- to rewrite the record, which changed what a later update wrote.
local function Changes(character, spec, commit)
  -- (only the active spec's bars can be read: asked about the other spec, there is no answer)
  if not character or not spec or spec ~= Bars.ActiveSpec() or ReadBlocker() then
    return nil
  end
  local key = character.active[spec]
  local profile = key and character.profiles[key]
  local layout = profile and profile.layout
  if type(layout) ~= "table" or type(layout.slots) ~= "table" then
    return nil
  end
  local record = Record(character, spec, key, layout)
  local bars = {}
  local changed, count, replace, replaceCount, held, heldCount = {}, 0, {}, 0, {}, 0
  for slot = 1, T.SLOT_LIMIT do
    local now, want = Bars.ReadSlot(slot), layout.slots[slot]
    bars[slot] = now
    local was = record.slots[slot]
    if Refreshes(record, layout, slot, now) then
      was = now
      if commit then
        record.slots[slot] = now
      end
    end
    local differs = SlotDiffers(want, was, now)
    if differs and record.guess then
      differs = Restorable(now) and (was == nil or CanLoad(was))
    end
    if differs then
      local missingSameSpecMacro = layout.spec == spec and want ~= nil and want.kind == "macro" and resolveMacro(want) == nil
      if want ~= nil and want.kind ~= "unknown" and not Matches(want, was) and not missingSameSpecMacro then
        if now ~= nil then
          replace[slot] = { want = want, now = now }
          replaceCount = replaceCount + 1
        else
          held[slot] = want
          heldCount = heldCount + 1
        end
      else
        changed[slot] = now or false
        count = count + 1
      end
    end
  end
  if record.guess and commit then
    -- From now on a real record: a slot counted as changed stays counted from what it was counted from, every
    -- other slot is taken as it is (so a mount or a used-up item you move later counts too).
    local slots = {}
    for slot = 1, T.SLOT_LIMIT do
      if changed[slot] ~= nil or replace[slot] or held[slot] then
        slots[slot] = record.slots[slot]
      else
        slots[slot] = bars[slot]
      end
    end
    SetBase(character, spec, { key = key, slots = slots })
  end
  return profile, changed, count, replace, replaceCount, held, heldCount
end

-- "Name (slot 6)" lists, slot order, at most PROBLEMS_SHOWN.
local function SlotList(entries, text)
  local list = {}
  for slot, entry in pairs(entries) do
    list[#list + 1] = { slot = slot, text = text(slot, entry) }
  end
  table.sort(list, function(a, b) return a.slot < b.slot end)
  local shown = {}
  for index = 1, math.min(#list, PROBLEMS_SHOWN) do
    shown[index] = list[index].text
  end
  return table.concat(shown, ", ") .. (#list > PROBLEMS_SHOWN and (" and " .. (#list - PROBLEMS_SHOWN) .. " more") or "")
end

-- Puts the slots you changed into the profile loaded on this spec (see "Updating" at the top). `forName` is
-- the profile a menu entry, fan tile or command named: refused if another one is loaded now. `anyway`: the user
-- said yes to the question (your changes replace buttons you can't see here, or the bars look like another
-- profile).
function Bars.UpdateActive(forSpec, forName, anyway, automatic, quiet)
  local spec = SpecFor(forSpec, "nothing updated")
  if not spec then
    return false, "your spec changed"
  end
  local character = Character(false)
  local key = character and character.active[spec]
  local profile = key and character.profiles[key]
  local text
  if not profile then
    text = ("no profile is loaded on %s"):format(SpecName(spec))
    Say("Not updated: " .. text .. ". Save your bars as a new profile instead.")
    return false, text
  end
  if forName ~= nil and Key(CleanName(forName) or "") ~= key then
    text = ('only "%s", the profile loaded on %s, can be updated'):format(profile.name, SpecName(spec))
    Say("Not updated: " .. text .. ". Load the other one first.")
    return false, text
  end
  local layout = profile.layout
  if type(layout) ~= "table" or type(layout.slots) ~= "table" then
    text = ('"%s" is damaged'):format(profile.name)
    Say("Not updated: " .. text .. ". Save these bars as a new profile instead.")
    return false, text
  end
  local why = ReadBlocker() or (CursorKind() ~= nil and "put down what is on your cursor first") or nil
  if why then
    Say("Not updated: " .. why .. ".")
    return false, why
  end
  local _, changed, count, replace, replaceCount, held, heldCount = Changes(character, spec, true)
  local note
  if heldCount and heldCount > 0 then
    note = ('Kept as saved in "%s": %s. %s on your %s bars, so emptying %s here doesn\'t take %s off; update it where %s.'):format(
      profile.name, SlotList(held, function(slot, want) return ("%s (slot %d)"):format(Label(want), slot) end),
      heldCount == 1 and "It isn't" or "They aren't", SpecName(spec), heldCount == 1 and "its slot" or "their slots",
      heldCount == 1 and "it" or "them", heldCount == 1 and "it is" or "they are")
  end
  local total = (count or 0) + (replaceCount or 0)
  if total == 0 then
    text = note and ('your only changes empty slots where "%s" has buttons that aren\'t on these bars'):format(profile.name)
      or ('you haven\'t changed your bars since "%s" was loaded'):format(profile.name)
    Say("Nothing to update: " .. text .. ".")
    if note then
      Say(note)
    end
    return false, text
  end
  if not anyway then
    local warnings = {}
    local bars, others = Snapshot(spec).slots, {}
    for otherKey, other in pairs(character.profiles) do
      if otherKey ~= key and type(other.layout) == "table" and type(other.layout.slots) == "table" then
        others[#others + 1] = otherKey
      end
    end
    table.sort(others)
    for _, otherKey in ipairs(others) do
      local other = character.profiles[otherKey]
      if LooksLike(layout, other.layout, bars) then
        warnings[#warnings + 1] = ('Your %s bars look like "%s", not "%s" (did the game close right after you loaded "%s"?).'):format(
          SpecName(spec), other.name, profile.name, other.name)
        break
      end
    end
    if replaceCount > 0 then
      warnings[#warnings + 1] = ('This replaces %s "%s" has that %s on your %s bars: %s.'):format(
        replaceCount == 1 and "a button" or "buttons", profile.name, replaceCount == 1 and "isn't" or "aren't",
        SpecName(spec), SlotList(replace, function(slot, entry)
          return ("%s (slot %d) with %s"):format(Label(entry.want), slot, Label(entry.now))
        end))
    end
    if #warnings > 0 then
      if automatic then
        -- (never silently: before 1.30 auto-update just stopped here; quiet syncs on login/reload avoid chat spam)
        if not quiet then
          local warnKey = spec .. ":" .. key
          local joined = table.concat(warnings, " ")
          if lastAutoWarning[warnKey] ~= joined then
            lastAutoWarning[warnKey] = joined
            Say(('Auto-update left "%s" as it was: %s Use Update in the bar profile menu to review it.'):format(
              profile.name, joined))
          end
        end
        return false, "manual review required"
      end
      local question = ('%s Update "%s" with your %d change%s anyway?'):format(table.concat(warnings, " "),
        profile.name, total, total == 1 and "" or "s")
      if Helper.BarUI then
        Helper.BarUI.AskUpdate(spec, profile.name, question)
      else
        Say("Not updated: " .. question)
      end
      return false, "asked first"
    end
  end
  -- Another spec with this profile loaded and no record of its own counts from the profile: before it changes,
  -- give that spec a copy of it, or this update would look like changes there (and reverse it).
  for otherSpec, otherKey in pairs(character.active) do
    if otherSpec ~= spec and otherKey == key and not SameRecord(SpecState(character, otherSpec).base, key) then
      SpecState(character, otherSpec).base = { key = key, slots = CopySlots(layout.slots), guess = true }
    end
  end
  local slots = CopySlots(layout.slots)
  for slot, now in pairs(changed) do
    slots[slot] = now or nil
  end
  for slot, entry in pairs(replace) do
    slots[slot] = entry.now
  end
  -- (no copy of the old layout: 1.19.0's kept one, and Migrate turns any it finds into an "(earlier)" profile.
  -- The profile stays the spec's it was saved in: updated from the other spec, it still holds its own talents.)
  profile.layout = NewLayout(T.Number(layout.spec) and layout.spec or spec, slots)
  MarkLoaded(character, spec, key)
  Say(('Updated "%s" with your changes to %d slot%s. It now has %s.'):format(profile.name, total,
    total == 1 and "" or "s", Describe(profile.layout)))
  if note then
    Say(note)
  end
  Changed()
  return true
end

-- On every bar change but ReadyToWork's own (a load or undo running): a slot now showing the loaded profile's own
-- button is counted from it from now on.
-- Auto-update listens only to changes you make. You make them with something on the cursor (dragging a button
-- off, out of the spellbook or onto a slot) or with the totem flyout (SetMultiCastSpell). The game refreshes every
-- slot itself when you log in, /reload, zone or land from a flight, with neither: those are now ignored without a
-- single slot being read (the user, 2026-11-21: "make it behave like a normal one instead of making all these
-- checks"). A drop can be reported just after the cursor empties, so changes count for EDIT_GRACE seconds more.
local EDIT_GRACE = 1
local holding, editUntil = false, nil
local function NoteCursor()
  -- (ReadyToWork's own pickups, by a load or by Spell ranks, are never yours: see BarTools.Ours)
  if applying or T.Ours() then
    holding = false
    return
  end
  if CursorKind() ~= nil then
    holding = true
  elseif holding then
    holding, editUntil = false, GetTime() + EDIT_GRACE
  end
end
local function YourEdit()
  if applying or T.Ours() then
    return false
  end
  return holding or CursorKind() ~= nil or (editUntil ~= nil and GetTime() <= editUntil)
end

local autoTimer, pendingUpdate
local function scheduleAutoUpdate()
  if autoTimer then autoTimer:Cancel() end
  autoTimer = C_Timer.NewTimer(1.5, function()
    autoTimer = nil
    local job = pendingUpdate
    if not job then return end
    if not Helper.db.barProfiles.enabled or not job.state.autoUpdate or Bars.ActiveSpec() ~= job.spec
        or job.character.active[job.spec] ~= job.key then
      pendingUpdate = nil
      return
    end
    -- A drag or cast can finish after the debounce timer: a drag resumes on the cursor event, a cast on its stop
    -- event. The bars settling after login or a spec switch sends no event, so that wait checks again.
    if CursorKind() then return end
    if ReadBlocker() then
      if not Settled() then scheduleAutoUpdate() end
      return
    end
    pendingUpdate = nil
    local profile = job.character.profiles[job.key]
    local layout = profile and profile.layout
    if type(layout) ~= "table" or type(layout.slots) ~= "table" then return end
    if not SameRecord(job.state.base, job.key) then
      Changes(job.character, job.spec, true)
    end
    local base = job.state.base
    if not SameRecord(base, job.key) then return end
    for slot in pairs(job.slots) do
      if SlotDiffers(layout.slots[slot], base.slots[slot], Bars.ReadSlot(slot)) then
        if Bars.ActiveChanged(job.spec) then Bars.UpdateActive(job.spec, job.name, false, true) end
        return
      end
    end
  end)
end

SyncAutoUpdate = function(quiet)
  if not settings or not settings.enabled or applying or T.Ours() then return end
  local spec = Bars.ActiveSpec()
  local character = spec and Character(false)
  local key = character and character.active[spec]
  local state = key and character.specs[spec]
  if not (state and state.autoUpdate) then return end
  if CursorKind() ~= nil or ReadBlocker() then return end
  local profile, _, count, _, replaceCount = Changes(character, spec, false)
  if profile and (count + replaceCount) > 0 then
    Bars.UpdateActive(spec, profile.name, false, true, quiet)
  end
end

function Bars.NoteAutoPlace(slot)
  if not settings or not settings.enabled or not T or not T.Number(slot) or slot < 1 or slot > T.SLOT_LIMIT then return end
  local spec = Bars.ActiveSpec()
  local character = spec and Character(false)
  local key = character and character.active[spec]
  local profile = key and character.profiles[key]
  local state = profile and character.specs[spec]
  if not (state and state.autoUpdate and type(profile.layout) == "table" and type(profile.layout.slots) == "table") then return end
  if not pendingUpdate or pendingUpdate.state ~= state or pendingUpdate.key ~= key then
    pendingUpdate = { character = character, state = state, key = key, spec = spec, name = profile.name, slots = {} }
  end
  pendingUpdate.slots[slot] = true
  scheduleAutoUpdate()
end

local function SlotChanged(slot)
  if applying or not YourEdit() then
    return
  end
  local spec = Bars.ActiveSpec()
  local character = spec and T.Number(slot) and slot >= 1 and slot <= T.SLOT_LIMIT and Character(false)
  -- (an undo of the last load leaves the slots you changed since as you made them)
  local undo = character and UndoFor(spec)
  if undo then
    undo.edited[slot] = true
  end
  local key = character and character.active[spec]
  local profile = key and character.profiles[key]
  local state = character and character.specs[spec]
  if not (profile and type(profile.layout) == "table" and type(profile.layout.slots) == "table") then
    return
  end
  if not ReadBlocker() then
    -- A record still guessed (see Record) becomes a real one at your first edit, so the edit can be counted.
    if not (state and SameRecord(state.base, key)) then
      Changes(character, spec, true)
      state = character.specs[spec]
    end
    if state and SameRecord(state.base, key) then
      local now = Bars.ReadSlot(slot)
      Refresh(state.base, profile.layout, slot, now)
      -- Travel can refresh slots without changing the buttons saved in them.
      if state.autoUpdate and Helper.db.barProfiles.enabled and
          SlotDiffers(profile.layout.slots[slot], state.base.slots[slot], now) then
        if not pendingUpdate or pendingUpdate.state ~= state or pendingUpdate.key ~= key then
          pendingUpdate = {character=character, state=state, key=key, spec=spec, name=profile.name, slots={}}
        end
        pendingUpdate.slots[slot] = true
        scheduleAutoUpdate()
      end
    end
  elseif state and state.autoUpdate and Helper.db.barProfiles.enabled then
    if not pendingUpdate or pendingUpdate.state ~= state or pendingUpdate.key ~= key then
      pendingUpdate = {character=character, state=state, key=key, spec=spec, name=profile.name, slots={}}
    end
    pendingUpdate.slots[slot] = true
    scheduleAutoUpdate()
  end
end

function Bars.Undo(forSpec)
  local spec = SpecFor(forSpec, "nothing changed")
  if not spec then
    return false
  end
  local character = Character(false)
  local saved = character and UndoFor(spec)
  if not saved or type(saved.layout) ~= "table" then
    Say(("%s has no load to undo this session."):format(SpecName(spec)))
    return false
  end
  if saved.layout.spec ~= spec then
    Say(("That undo is marked as %s's, not %s's; nothing changed."):format(SpecName(saved.layout.spec), SpecName(spec)))
    return false
  end
  -- Slots you changed since the load stay as you made them (an undo puts back only what the load changed).
  local undo, keptCount = { spec = saved.layout.spec, class = saved.layout.class, slots = {} }, 0
  for slot = 1, T.SLOT_LIMIT do
    if saved.edited[slot] then
      undo.slots[slot] = { kind = "unknown" }
      keptCount = keptCount + 1
    else
      undo.slots[slot] = saved.layout.slots[slot]
    end
  end
  local returnTo, returnBase = saved.active, saved.base
  local done, touched = Apply(character, undo, spec, ("Undid the last load on %s"):format(SpecName(spec)))
  if keptCount > 0 then
    Say(("Kept %d slot%s you changed since that load."):format(keptCount, keptCount == 1 and "" or "s"))
  end
  if done then
    -- The profile loaded before, with its record from then: changes made to it before that load still count.
    -- A slot the undo couldn't set back is as the undo left it: not a change of yours, and (differing from the
    -- record) the profile's own button there is never written over.
    character.active[spec] = returnTo
    local profile = returnTo and character.profiles[returnTo]
    local base
    if profile and type(profile.layout) == "table" and type(profile.layout.slots) == "table" then
      -- (no record kept for it, from a build before 1.21.1: the bars as they were before that load, exactly what
      -- the undo puts back. Guessing from the profile instead counted an update made on the other spec since as
      -- changes here, and offered to reverse it.)
      local from = SameRecord(returnBase, returnTo) and returnBase or { slots = undo.slots }
      base = { key = returnTo, slots = {}, guess = from.guess }
      for slot, entry in pairs(from.slots) do
        base.slots[slot] = entry
      end
      local now = Snapshot(spec).slots
      for slot = 1, T.SLOT_LIMIT do
        if not Matches(undo.slots[slot], now[slot]) then
          base.slots[slot] = now[slot]
        end
      end
    end
    SetBase(character, spec, base)
  else
    AfterApply(character, spec, done, touched)
  end
  Changed()
  return done
end

function Bars.Rename(oldName, newName)
  local character = Character(false)
  local profile = Find(character, oldName)
  if not profile then
    return Missing(oldName)
  end
  local name, bad = CleanName(newName)
  if not name then
    Say("Not renamed: " .. bad .. ".")
    return false, bad
  end
  local oldKey, newKey = Key(profile.name), Key(name)
  if newKey ~= oldKey and character.profiles[newKey] then
    local text = ('a profile named "%s" already exists'):format(character.profiles[newKey].name)
    Say("Not renamed: " .. text .. ".")
    return false, text
  end
  local oldDisplay = profile.name
  character.profiles[oldKey] = nil
  profile.name = name
  character.profiles[newKey] = profile
  for spec, key in pairs(character.active) do
    if key == oldKey then character.active[spec] = newKey end
  end
  for _, state in pairs(character.specs) do
    if type(state.base) == "table" and state.base.key == oldKey then state.base.key = newKey end
  end
  EachUndo(function(undo)
    if undo.active == oldKey then undo.active = newKey end
    if type(undo.base) == "table" and undo.base.key == oldKey then undo.base.key = newKey end
  end)
  Say(('Renamed "%s" to "%s".'):format(oldDisplay, name))
  Changed()
  return true
end

function Bars.Delete(rawName)
  local character = Character(false)
  local profile = Find(character, rawName)
  if not profile then
    return Missing(rawName)
  end
  local key = Key(profile.name)
  character.profiles[key] = nil
  for spec, active in pairs(character.active) do
    if active == key then character.active[spec] = nil end
  end
  for _, state in pairs(character.specs) do
    if type(state.base) == "table" and state.base.key == key then state.base = nil end
  end
  EachUndo(function(undo)
    if undo.active == key then undo.active = nil end
    if type(undo.base) == "table" and undo.base.key == key then undo.base = nil end
  end)
  Say(('Deleted the profile "%s". Your bars are as they were.'):format(profile.name))
  Changed()
  return true
end

-- Reading for the menu and the fan ------------------------------------------------------------------------

-- This character's profiles: those saved in `spec`, then the others; each sorted by name.
-- Entries: { key, name, spec, at, active }.
function Bars.Profiles(spec)
  local character = Character(false)
  local own, other = {}, {}
  for key, profile in pairs(character and character.profiles or {}) do
    local layout = type(profile.layout) == "table" and profile.layout or {}
    local entry = { key = key, name = profile.name, spec = layout.spec, at = layout.at,
      active = character.active[spec] == key }
    if entry.spec == spec then
      own[#own + 1] = entry
    else
      other[#other + 1] = entry
    end
  end
  local function ByName(a, b) return a.key < b.key end
  table.sort(own, ByName)
  table.sort(other, ByName)
  return own, other
end

-- The profile loaded or saved last on `spec` (its display name), or nil.
function Bars.AutoUpdate(value)
  local spec=Bars.ActiveSpec()
  local char=spec and Character(value~=nil)
  if not char then return false end
  if value==nil then return char.specs[spec] and char.specs[spec].autoUpdate==true or false end
  local state=SpecState(char,spec)
  state.autoUpdate=value==true
  ClearAutoWarning(spec, char.active[spec])
  if state.autoUpdate then
    if Settled() and not ReadBlocker() and CursorKind() == nil then
      SyncAutoUpdate(false)
    elseif C_Timer and type(C_Timer.After) == "function" then
      settleToken = settleToken + 1
      local token = settleToken
      C_Timer.After(SETTLE_SECONDS + 0.2, function()
        if token == settleToken then SyncAutoUpdate(true) end
      end)
    end
  end
  Changed()
  return state.autoUpdate==true
end

-- Read-only reason why auto-update has paused with unsaved changes on `spec`, or nil.
function Bars.AutoUpdateHoldReason(spec)
  if not settings or not settings.enabled or not spec then return nil end
  local character = Character(false)
  local key = character and character.active[spec]
  local state = key and character.specs[spec]
  if not (state and state.autoUpdate) then return nil end
  local profile, _, count, _, replaceCount = Changes(character, spec, false)
  if not profile or (count + replaceCount) == 0 then return nil end
  if CursorKind() ~= nil then
    return "Auto-update is waiting for your cursor to clear."
  end
  local layout = profile.layout
  local bars, others = Snapshot(spec).slots, {}
  for otherKey, other in pairs(character.profiles) do
    if otherKey ~= key and type(other.layout) == "table" and type(other.layout.slots) == "table" then
      others[#others + 1] = otherKey
    end
  end
  table.sort(others)
  for _, otherKey in ipairs(others) do
    local other = character.profiles[otherKey]
    if LooksLike(layout, other.layout, bars) then
      return ('Auto-update paused: your %s bars look like "%s". Click Update to confirm.'):format(SpecName(spec), other.name)
    end
  end
  if replaceCount > 0 then
    return ('Auto-update paused: %d change%s would replace buttons saved from another spec. Click Update to review.'):format(
      replaceCount, replaceCount == 1 and "" or "s")
  end
end
function Bars.ActiveName(spec)
  local character = Character(false)
  local key = character and spec and character.active[spec]
  local profile = key and character.profiles[key]
  return profile and profile.name or nil
end

-- The name of the profile loaded on `spec` when you have changed the bars since it was loaded, saved or
-- updated there (whichever spec it was saved in), and how many slots; nil otherwise. The menu, the fan and the
-- swap button's tooltip offer an update only then.
-- Also how many changes are in slots it keeps as saved: offered as "why can't it be updated?" when those are
-- the only ones (never silently missing).
-- (`count` includes changes that replace a button you can't see here: the update asks about those first)
function Bars.Updatable(spec)
  local profile, _, count, _, replaceCount, _, heldCount = Changes(Character(false), spec)
  if profile and count + replaceCount + heldCount > 0 then
    return profile.name, count + replaceCount, heldCount
  end
end

function Bars.ActiveChanged(spec)
  local _, count = Bars.Updatable(spec)
  return (count or 0) > 0
end

-- The display name of a profile, or nil when there is none by that name.
function Bars.Exists(rawName)
  local profile = Find(Character(false), rawName)
  return profile and profile.name or nil
end

function Bars.HasUndo(spec)
  return UndoFor(spec) ~= nil
end

function Bars.List()
  local spec = Bars.ActiveSpec()
  local own, other = Bars.Profiles(spec)
  Say(("Bar profiles (you are in %s):"):format(spec and SpecName(spec) or "an unknown spec"))
  if #own + #other == 0 then
    print("  none yet. Save one with /rtw bars save Name, or the ReadyToWork menu.")
    return
  end
  for _, entry in ipairs(own) do
    print(("  %s%s, saved %s"):format(entry.name, entry.active and " (loaded)" or "", When(entry.at)))
  end
  for _, entry in ipairs(other) do
    print(("  %s%s, saved %s in %s"):format(entry.name, entry.active and " (loaded)" or "", When(entry.at),
      SpecName(entry.spec)))
  end
end

-- /rtw bars ---------------------------------------------------------------------------------------------------

local function Command(rest, typed)
  typed = typed or rest or ""
  local word, argument = typed:match("^%s*(%S*)%s*(.-)%s*$")
  word = word:lower()
  local UI = Helper.BarUI
  if word == "on" or word == "off" then
    Helper.Toggle(settings, word, "Bar profiles")
    Changed()
  elseif not settings.enabled and word ~= "list" and word ~= "" then
    Say("Bar profiles are off: /rtw bars on, or the ReadyToWork menu.")
  elseif word == "save" then
    if argument == "" and UI then
      UI.AskSaveNew()
    else
      Bars.SaveNew(argument)
    end
  elseif word == "update" then
    Bars.UpdateActive(nil, argument ~= "" and argument or nil)
  elseif word == "revert" then
    Say("There is no revert: an update keeps no earlier copy. To keep a version, save it as a new profile before you update.")
  elseif word == "load" then
    Bars.Load(argument)
  elseif word == "restore" then
    -- (1.18's command) the profile loaded last on this spec, again
    local spec = Bars.ActiveSpec()
    local name = Bars.ActiveName(spec)
    if name then
      Bars.Load(name)
    else
      Say("No profile is loaded on this spec yet: /rtw bars load Name.")
    end
  elseif word == "rename" then
    local old, new = argument:match("^(.-)%s*=%s*(.-)$")
    if old and new and new ~= "" then
      Bars.Rename(old, new)
    elseif argument ~= "" and UI then
      UI.AskRename(argument)
    else
      Say("/rtw bars rename Old name = New name")
    end
  elseif word == "delete" then
    if UI then
      UI.AskDelete(argument)
    end
  elseif word == "undo" then
    Bars.Undo()
  elseif word == "button" then
    local what = argument:lower()
    if what == "reset" then
      if UI then UI.ResetButton() end
    else
      settings.button = what == "on" or (what ~= "off" and not settings.button)
      Say("The bar profile swap button is " .. (settings.button and "shown (Alt-drag to move it)." or "hidden."))
      Changed()
    end
  else
    Bars.List()
    print("  /rtw bars save Name | load Name | update | rename Old = New | delete Name | undo")
    print("  /rtw bars button on|off|reset | on|off")
  end
end

Helper.Feature(function()
  T = Helper.BarTools
  settings = Helper.db.barProfiles
  if not T then
    return
  end
  Migrate()
  Unsettle()
  Helper.On("PLAYER_LEAVING_WORLD", Unsettle)
  Helper.On("PLAYER_ENTERING_WORLD", Unsettle)
  Helper.On("ACTIVE_TALENT_GROUP_CHANGED", function()
    Unsettle()
    Changed()
  end)
  Helper.On("ACTIONBAR_SLOT_CHANGED", function(slot)
    -- while the bars are arriving, each change pushes the quiet time back (up to the limit)
    if Unsettling() then
      Unsettle()
    end
    SlotChanged(slot)
  end)
  Helper.On("CURSOR_CHANGED", function()
    NoteCursor()
    if pendingUpdate and not CursorKind() then scheduleAutoUpdate() end
  end)
  -- (the totem flyout's choice, see YourEdit; ReadyToWork's own loads and rank upgrades aren't yours). The game
  -- may report the slot change inside SetMultiCastSpell, before this hook runs, so the slot is counted here too.
  if type(hooksecurefunc) == "function" and type(SetMultiCastSpell) == "function" then
    hooksecurefunc("SetMultiCastSpell", function(slot)
      if not applying and not T.Ours() then
        editUntil = GetTime() + EDIT_GRACE
        SlotChanged(slot)
      end
    end)
  end
  for _, event in ipairs({"UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_CHANNEL_STOP"}) do
    -- (your casts only: other units' cast events can carry a hidden unit)
    Helper.OnUnit(event, { "player" }, function() if pendingUpdate then scheduleAutoUpdate() end end)
  end
  Helper.commands.bars = Command
  Helper.help[#Helper.help + 1] = "/rtw bars [save|load|update|rename|delete|undo|list] Name - named action bar profiles"
end)
