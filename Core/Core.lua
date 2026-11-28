-- ReadyToWork core: saved settings, events, the slash command and shared helpers.
--
--   Core\Core.lua      this file
--   Core\Features.lua  the feature registry and every feature's declaration
--   Core\Migrate.lua   saved-data schema version and its ordered migrations
--   Core\Store.lua     settings edits and the one undo history
--   Core\Frames.lua    movable frames: positions, sizes, unlock mode's list
--
-- The windows, the quick menu and the minimap button are in the UI folder: UI\Window.lua, UI\Menu.lua,
-- UI\Launcher.lua, UI\Unlock.lua, UI\Intro.lua and UI\Entry.lua.
--
-- Each helper lives in its own file and starts through Helper.Feature. A helper that fails to start does not
-- stop the others.

local ADDON, Helper = ...
do
  local getMeta = C_AddOns and C_AddOns.GetAddOnMetadata
  local ok, version = false, nil
  if type(getMeta) == "function" then ok, version = pcall(getMeta, ADDON, "Version") end
  Helper.version = ok and type(version) == "string" and version ~= "" and version or "1.58.0"
end

local POOR = Enum and Enum.ItemQuality and Enum.ItemQuality.Poor or 0
Helper.POOR = POOR

-- The two bag actions, wherever this client keeps them. A feature that needs
-- one that is missing stays switched off instead of raising errors.
local container = C_Container or {}
Helper.UseItem = container.UseContainerItem or UseContainerItem
Helper.PickupItem = container.PickupContainerItem or PickupContainerItem

function Helper.Print(message)
  if Helper.EditorOutput then Helper.EditorOutput(tostring(message)); return end
  print("|cff79cfffReadyToWork:|r " .. tostring(message))
end

-- 12345 -> "1g 23s 45c", with coin icons where the game can draw them.
function Helper.Money(copper)
  copper = math.max(0, math.floor((copper or 0) + 0.5))
  if type(GetMoneyString) == "function" then
    local ok, text = pcall(GetMoneyString, copper, true)
    if ok and type(text) == "string" and text ~= "" then
      return text
    end
  end
  local gold, silver = math.floor(copper / 10000), math.floor(copper / 100) % 100
  local parts = {}
  if gold > 0 then parts[#parts + 1] = gold .. "g" end
  if silver > 0 then parts[#parts + 1] = silver .. "s" end
  if copper % 100 > 0 or #parts == 0 then parts[#parts + 1] = (copper % 100) .. "c" end
  return table.concat(parts, " ")
end

-- "5s", "50c", "1g 20s" or a plain number of copper -> copper, or nil.
function Helper.ParseMoney(text)
  text = tostring(text or ""):lower():gsub("%s+", "")
  if text:match("^%d+$") then
    return tonumber(text)
  end
  if text == "" or text:gsub("%d+[gsc]", "") ~= "" then
    return nil
  end
  local worth = { g = 10000, s = 100, c = 1 }
  local total = 0
  for amount, unit in text:gmatch("(%d+)([gsc])") do
    total = total + tonumber(amount) * worth[unit]
  end
  return total
end

-- 151 -> "2:31"
function Helper.Clock(seconds)
  seconds = math.max(0, math.floor((seconds or 0) + 0.5))
  return ("%d:%02d"):format(math.floor(seconds / 60), seconds % 60)
end

-- The bags that hold ordinary items: the backpack and the equipped bags.
function Helper.Bags()
  local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
  local bags = {}
  for bag = 0, last do
    bags[#bags + 1] = bag
  end
  return bags
end

-- Free slots in the ordinary bags: not the reagent bag (it only takes reagents, so its room doesn't help with
-- loot or junk) and not quivers or other special bags.
function Helper.FreeSlots()
  local reagentBag = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag or 5
  local free = 0
  for _, bag in ipairs(Helper.Bags()) do
    if bag ~= reagentBag then
      local count, family = C_Container.GetContainerNumFreeSlots(bag)
      if (family or 0) == 0 then
        free = free + (count or 0)
      end
    end
  end
  return free
end

-- Where a "party" line goes, as the game's own chat box picks it: your group, or instance chat when you are
-- only in a dungeon-finder group (party chat fails there). nil when not in a group.
function Helper.GroupChannel()
  local function InGroup(category)
    if type(IsInGroup) ~= "function" then return false end
    local ok, yes = pcall(IsInGroup, category)
    return ok and yes == true
  end
  if InGroup(LE_PARTY_CATEGORY_HOME) then
    return "PARTY"
  end
  if LE_PARTY_CATEGORY_INSTANCE and InGroup(LE_PARTY_CATEGORY_INSTANCE) then
    return "INSTANCE_CHAT"
  end
end

-- Sends `text` to your group (see GroupChannel). Returns whether it was sent.
function Helper.SendGroup(text)
  local channel = Helper.GroupChannel()
  if not channel then return false end
  if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
    local ok, locked = pcall(C_ChatInfo.InChatMessagingLockdown)
    if ok and locked == true then return false end
  end
  local send = C_ChatInfo and C_ChatInfo.SendChatMessage
  return type(send) == "function" and pcall(send, text, channel) == true
end

function Helper.ItemLinkKey(link)
  if issecretvalue and issecretvalue(link) then return nil end
  if type(link) == "string" then return link:match("|H(item:[^|]+)|h") or link end
end

function Helper.CursorBagItem()
  local kind, itemID, link = GetCursorInfo()
  if kind ~= "item" or type(itemID) ~= "number" or itemID <= 0
      or not (C_Cursor and C_Cursor.GetCursorItem) then
    return
  end
  local source = C_Cursor.GetCursorItem()
  if source and source:IsBagAndSlot() then
    local bag, slot = source:GetBagAndSlot()
    for _, equippedBag in ipairs(Helper.Bags()) do
      if bag == equippedBag and slot and slot > 0 then
        return itemID, Helper.ItemLinkKey(link) and link, bag, slot
      end
    end
  end
end

function Helper.BagItemGUID(bag, slot)
  if not (ItemLocation and ItemLocation.CreateFromBagAndSlot and C_Item and C_Item.GetItemGUID) then return end
  local location = ItemLocation:CreateFromBagAndSlot(bag, slot)
  local ok, guid = pcall(C_Item.GetItemGUID, location)
  if ok and not (issecretvalue and issecretvalue(guid)) and type(guid) == "string" then return guid end
end

function Helper.CountBagItem(itemID, guid)
  local count, sameStack = 0, 0
  for _, bag in ipairs(Helper.Bags()) do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID == itemID then
        count = count + info.stackCount
        if guid and Helper.BagItemGUID(bag, slot) == guid then sameStack = info.stackCount end
      end
    end
  end
  return count, sameStack
end

-- What a vendor pays for one of an item. nil while the game has not loaded
-- the item yet; asking makes it load.
function Helper.SellPrice(link)
  local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
  if not getInfo or not link then
    return nil
  end
  local ok, name, _, _, _, _, _, _, _, _, _, price = pcall(getInfo, link)
  if not ok or name == nil then
    return nil
  end
  return tonumber(price) or 0
end

-- Events ------------------------------------------------------------------

local frame = CreateFrame("Frame")
local handlers = {}

-- Calls `callback(...)` whenever `event` fires. An event this client does
-- not have is ignored rather than raising an error.
function Helper.On(event, callback)
  if not handlers[event] then
    if not pcall(frame.RegisterEvent, frame, event) then
      return false
    end
    handlers[event] = {}
  end
  table.insert(handlers[event], callback)
  return true
end

-- Calls `callback(unit, ...)` whenever `event` fires for one of `units` only (RegisterUnitEvent), so events for
-- every other unit in the group never run it. Spellcast events can carry a hidden unit for other units.
-- Falls back to Helper.On when the client won't filter that event.
function Helper.OnUnit(event, units, callback)
  local unitFrame = CreateFrame("Frame")
  local ok, registered = pcall(unitFrame.RegisterUnitEvent, unitFrame, event, unpack(units))
  if not ok or registered == false then
    return Helper.On(event, callback)
  end
  unitFrame:SetScript("OnEvent", function(_, _, ...) Helper.Safely(callback, ...) end)
  return true
end

-- The units nameplate features care about: nameplates and the units you point at (for Helper.OnUnit).
Helper.WORLD_UNITS = { "target", "mouseover", "focus", "softenemy" }
for index = 1, 40 do
  Helper.WORLD_UNITS[#Helper.WORLD_UNITS + 1] = "nameplate" .. index
end

-- Shows an error like any other, without stopping the other features. It runs as xpcall's handler, while the
-- failing code is still on the stack, so the error report (and BalErrors) shows that code and its locals; a
-- handler called after pcall returned would only ever show this file.
local function ReportError(problem)
  local handler = type(geterrorhandler) == "function" and geterrorhandler()
  if handler then
    handler(problem)
  end
  return problem
end

local function Call(callback, ...)
  xpcall(callback, ReportError, ...)
end
Helper.Safely = Call

-- Features and settings ---------------------------------------------------

local starters = {}
Helper.commands = {}   -- word after /rtw -> function(rest)
Helper.help = {}       -- lines shown by /rtw

-- Registers a feature. `start` runs once at login, when saved settings exist.
function Helper.Feature(start)
  starters[#starters + 1] = start
end

local function FillDefaults(saved, defaults)
  for key, value in pairs(defaults) do
    if type(value) == "table" then
      if type(saved[key]) ~= "table" then
        saved[key] = {}
      end
      FillDefaults(saved[key], value)
    elseif saved[key] == nil then
      saved[key] = value
    end
  end
end

-- "on" / "off" / nothing (toggle) -> the new setting, announced.
function Helper.Toggle(settings, word, label)
  if word == "on" then
    settings.enabled = true
  elseif word == "off" then
    settings.enabled = false
  else
    settings.enabled = not settings.enabled
  end
  Helper.Print(label .. (settings.enabled and " on." or " off."))
  return settings.enabled
end

-- Movable frames (Helper.MakeMovable) are in Core\Frames.lua.

frame:SetScript("OnEvent", function(_, event, ...)
  for _, callback in ipairs(handlers[event] or {}) do
    Call(callback, ...)
  end
end)

local function ReadableText(value)
  return not (issecretvalue and issecretvalue(value)) and type(value) == "string" and value ~= ""
end

local function DeepCopy(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, item in pairs(value) do
    copy[key] = DeepCopy(item)
  end
  return copy
end

local function ValuesEqual(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for key, value in pairs(a) do
    if not ValuesEqual(value, b[key]) then return false end
  end
  for key in pairs(b) do
    if a[key] == nil then return false end
  end
  return true
end

local function IsRealmText(text, realm, normRealm)
  if not ReadableText(text) then return false end
  local low = text:lower()
  if ReadableText(realm) and (low == realm:lower() or low == realm:gsub("%s+", ""):lower()) then
    return true
  end
  return ReadableText(normRealm) and low == normRealm:lower()
end

local function CombineNameAndSurname(first, second, realm, normRealm)
  if not ReadableText(first) then return nil end
  if ReadableText(second) and not IsRealmText(second, realm, normRealm)
      and not first:find(" ", 1, true) and not first:find("-", 1, true) then
    return first .. " " .. second
  end
  return first
end

local function ReadPlayerRealmInfo()
  local realm, normRealm, regional = nil, nil, false
  if type(GetRealmName) == "function" then
    local ok, r = pcall(GetRealmName)
    if ok and ReadableText(r) then realm = r end
  end
  if type(GetNormalizedRealmName) == "function" then
    local ok, r = pcall(GetNormalizedRealmName)
    if ok and ReadableText(r) then normRealm = r end
  end
  local regFn = _G.RegionalUniqueNamesEnabled
  if type(regFn) == "function" then
    local ok, flag = pcall(regFn)
    if ok and flag == true then regional = true end
  end
  return realm, normRealm, regional
end

-- Returns the player's full name ("First Last" on Forever realms with surnames, or "Name" otherwise).
function Helper.PlayerFullName()
  local realm, normRealm, regional = ReadPlayerRealmInfo()
  local first, second
  if type(UnitFullName) == "function" then
    local ok, a, b = pcall(UnitFullName, "player")
    if ok and ReadableText(a) then
      first, second = a, b
    end
  end
  if type(UnitName) == "function" and (not ReadableText(first) or not ReadableText(second)) then
    local ok, a, b = pcall(UnitName, "player")
    if ok then
      if not ReadableText(first) and ReadableText(a) then first = a end
      if not ReadableText(second) and ReadableText(b) then second = b end
    end
  end
  local combined = CombineNameAndSurname(first, second, realm, normRealm)
  if ReadableText(combined) and combined:find(" ", 1, true) then
    return combined
  end
  if regional and type(GetUnitName) == "function" then
    local ok, uName = pcall(GetUnitName, "player", true)
    if ok and ReadableText(uName) then
      local clean = uName:gsub("%s*%([^%)]+%)$", "")
      local head, tail = clean:match("^([^-]+)%-(.+)$")
      if head and tail and not IsRealmText(tail, realm, normRealm) then
        return head .. " " .. tail
      end
      if clean:find(" ", 1, true) then
        return clean
      end
    end
  end
  return combined or (ReadableText(first) and first) or nil
end

local function ResolveCharKey()
  if type(UnitGUID) == "function" then
    local ok, guid = pcall(UnitGUID, "player")
    if ok and ReadableText(guid) then return guid end
  end
  local name = Helper.PlayerFullName()
  if ReadableText(name) then
    local realm = ReadPlayerRealmInfo()
    return name .. "-" .. (realm or "?")
  end
end

local function FormatCharLabel(info)
  local name = ReadableText(info and info.name) and info.name or "Unknown"
  local level = type(info and info.level) == "number" and info.level > 0 and info.level or nil
  local className = ReadableText(info and info.className) and info.className or nil
  if level and className then
    return ("%s (%d %s)"):format(name, level, className)
  elseif level then
    return ("%s (%d)"):format(name, level)
  elseif className then
    return ("%s (%s)"):format(name, className)
  end
  return name
end

-- Binds per-character features (`perChar = true`) under `saved.chars[charKey]` while leaving
-- account-wide settings on `saved`. Returns the active db table (`view`, or `saved` when unit
-- identity is unavailable in minimal test fixtures).
function Helper.BindCharacter(saved)
  Helper.saved = saved
  if type(saved) ~= "table" then
    Helper.db, Helper.charKey = nil, nil
    return nil
  end
  local charKey = ResolveCharKey()
  if not charKey then
    Helper.db, Helper.charKey = saved, nil
    return saved
  end
  if type(saved.chars) ~= "table" then saved.chars = {} end
  local char = saved.chars[charKey]
  local lvl = nil
  if type(UnitLevel) == "function" then
    local okLvl, rawLvl = pcall(UnitLevel, "player")
    if okLvl and type(rawLvl) == "number" and not (issecretvalue and issecretvalue(rawLvl)) and rawLvl > 0 then
      lvl = rawLvl
    end
  end

  if type(char) ~= "table" then
    char = {}
    saved.chars[charKey] = char
    local knownInBars = type(saved.bars) == "table" and type(saved.bars[charKey]) == "table"
    -- Existing characters (seen in bars, level > 1, or test runs without UnitLevel) keep their
    -- pre-1.59 lists so upgrading never breaks their setup; brand-new level-1 alts start clean.
    local isExisting = knownInBars or (lvl == nil) or (lvl > 1)
    for _, key in ipairs(Helper.featureOrder) do
      local spec = Helper.features[key]
      if spec and spec.perChar then
        char[key] = {}
        local legacy = isExisting and type(saved[key]) == "table" and saved[key] or nil
        if legacy then
          for _, field in ipairs(spec.prefs or {}) do
            if legacy[field] ~= nil then
              char[key][field] = DeepCopy(legacy[field])
            end
          end
          if key == "maxSpells" and type(legacy.seen) == "table" and type(legacy.seen[charKey]) == "table" then
            char[key].seen = { [charKey] = DeepCopy(legacy.seen[charKey]) }
          end
          if key == "vendor" then
            local hasStats = (tonumber(legacy.lifetime) or 0) > 0
              or (tonumber(legacy.repairSpent) or 0) > 0
              or (tonumber(legacy.repairGuildSpent) or 0) > 0
              or (type(legacy.log) == "table" and #legacy.log > 0)
            if hasStats then
              char[key].lifetime = legacy.lifetime or 0
              char[key].repairSpent = legacy.repairSpent or 0
              char[key].repairGuildSpent = legacy.repairGuildSpent or 0
              if type(legacy.today) == "table" then char[key].today = DeepCopy(legacy.today) end
              if type(legacy.log) == "table" then char[key].log = DeepCopy(legacy.log) end
              legacy.lifetime, legacy.repairSpent, legacy.repairGuildSpent = 0, 0, 0
              legacy.today, legacy.log = nil, {}
            end
          end
        end
        if spec.defaults then FillDefaults(char[key], spec.defaults) end
      end
    end
  else
    for _, key in ipairs(Helper.featureOrder) do
      local spec = Helper.features[key]
      if spec and spec.perChar then
        if type(char[key]) ~= "table" then char[key] = {} end
        if spec.defaults then FillDefaults(char[key], spec.defaults) end
      end
    end
  end

  local pName = Helper.PlayerFullName()
  if ReadableText(pName) then char.name = pName end
  if type(UnitClass) == "function" then
    local okClass, cName, cFile = pcall(UnitClass, "player")
    if okClass then
      if ReadableText(cName) then char.className = cName end
      if ReadableText(cFile) then char.class = cFile end
    end
  end
  if lvl then char.level = lvl end
  local realm, normRealm = ReadPlayerRealmInfo()
  if realm then char.realm = realm end
  if type(UnitFactionGroup) == "function" then
    local okFac, faction = pcall(UnitFactionGroup, "player")
    if okFac and ReadableText(faction) then char.faction = faction end
  end
  if type(time) == "function" then char.seen = time() end
  for otherKey, info in pairs(saved.chars) do
    if otherKey ~= charKey and type(info) == "table" and ReadableText(info.name) and not info.name:find(" ", 1, true) then
      local fn, sn
      if type(UnitNameFromGUID) == "function" then
        local okU, a, b = pcall(UnitNameFromGUID, otherKey)
        if okU and ReadableText(a) then fn, sn = a, b end
      end
      if (not ReadableText(fn) or not ReadableText(sn)) and type(GetPlayerInfoByGUID) == "function" then
        local okP, _, _, _, _, _, a, b = pcall(GetPlayerInfoByGUID, otherKey)
        if okP and ReadableText(a) then
          if not ReadableText(fn) then fn = a end
          if not ReadableText(sn) then sn = b end
        end
      end
      local full = CombineNameAndSurname(fn, sn, info.realm or realm, normRealm)
      if ReadableText(full) and full:find(" ", 1, true) then
        info.name = full
      end
    end
  end

  local view = {}
  for _, key in ipairs(Helper.featureOrder) do
    local spec = Helper.features[key]
    if spec and spec.perChar then
      view[key] = char[key]
    end
  end
  setmetatable(view, {
    __index = saved,
    __newindex = function(_, key, value)
      local spec = Helper.features[key]
      if spec and spec.perChar then
        char[key] = value
        view[key] = value
      else
        saved[key] = value
      end
    end,
  })
  Helper.db, Helper.charKey = view, charKey
  return view
end

Helper.Characters = {}

function Helper.Characters.IsPerChar(key)
  local spec = Helper.features[key]
  return spec ~= nil and spec.perChar == true
end

function Helper.Characters.Current()
  local saved = Helper.saved
  local key = Helper.charKey
  return key, saved and type(saved.chars) == "table" and key and saved.chars[key] or nil
end

function Helper.Characters.List()
  local saved, current = Helper.saved, Helper.charKey
  local list = {}
  if not (saved and type(saved.chars) == "table") then return list end
  for key, info in pairs(saved.chars) do
    if key ~= current and type(info) == "table" then
      list[#list + 1] = {
        key = key,
        name = info.name,
        realm = info.realm,
        faction = info.faction,
        class = info.class,
        className = info.className,
        level = info.level,
        label = FormatCharLabel(info),
      }
    end
  end
  table.sort(list, function(a, b)
    local al, bl = (a.name or a.key):lower(), (b.name or b.key):lower()
    if al ~= bl then return al < bl end
    return tostring(a.key) < tostring(b.key)
  end)
  return list
end

function Helper.Characters.CopyFeature(sourceKey, featureKey)
  local spec = Helper.features[featureKey]
  local saved = Helper.saved
  if not (spec and spec.perChar and saved and type(saved.chars) == "table") then return false end
  if not sourceKey or sourceKey == Helper.charKey then return false end
  local srcChar = saved.chars[sourceKey]
  local src = type(srcChar) == "table" and srcChar[featureKey]
  local dst = Helper.db and Helper.db[featureKey]
  if type(src) ~= "table" or type(dst) ~= "table" then return false end

  local label = FormatCharLabel(srcChar)
  local captured = spec.capture and spec.capture(dst)
  local changed, count = {}, 0
  local function applyCopy()
    for _, field in ipairs(spec.prefs or {}) do
      local nextVal = src[field]
      if not ValuesEqual(dst[field], nextVal) then
        dst[field] = DeepCopy(nextVal)
        changed[field] = true
        count = count + 1
      end
    end
    if spec.defaults then FillDefaults(dst, spec.defaults) end
  end
  if Helper.Store and Helper.Store.Edit then
    Helper.Store.Edit(featureKey, "Copy from " .. (srcChar.name or label), applyCopy)
    if count > 0 and Helper.Store.Apply then
      Helper.Store.Apply(featureKey, changed, captured)
    end
  else
    applyCopy()
  end
  return true, count, label
end

function Helper.Characters.CopyAll(sourceKey)
  local saved = Helper.saved
  local srcChar = saved and type(saved.chars) == "table" and saved.chars[sourceKey]
  if type(srcChar) ~= "table" or sourceKey == Helper.charKey then return false end
  local copied = 0
  for _, key in ipairs(Helper.featureOrder) do
    local spec = Helper.features[key]
    if spec and spec.perChar then
      local ok, count = Helper.Characters.CopyFeature(sourceKey, key)
      if ok and count > 0 then copied = copied + 1 end
    end
  end
  return true, copied, FormatCharLabel(srcChar)
end

-- Prepares the saved table: migrations first (they read the old shapes), then any missing defaults.
-- Returns the table to use, or nil when it was written by a newer ReadyToWork (see Core\Migrate.lua).
function Helper.PrepareSaved(saved)
  local fresh = type(saved) ~= "table"
  saved = fresh and {} or saved
  if not Helper.Migrate(saved, fresh) then
    return nil, saved
  end
  FillDefaults(saved, Helper.Defaults())
  -- The introduction (Intro.lua) opens by itself on a fresh install and once after each update (keeping all
  -- saved settings), unless "Don't show automatically on future updates" is ticked.
  if type(saved.intro) ~= "table" then
    saved.intro = { show = fresh, skipUpdates = false }
  end
  return saved, saved
end

Helper.On("ADDON_LOADED", function(name)
  if name == ADDON then
    local db, saved = Helper.PrepareSaved(ReadyToWorkDB)
    ReadyToWorkDB = saved
    Helper.saved = db
    Helper.db = db
  end
end)

Helper.On("PLAYER_LOGIN", function()
  if not Helper.saved then
    if Helper.savedTooNew then
      Helper.Print(("Your saved settings come from a newer ReadyToWork (saved-data version %d; this one reads up to %d), so ReadyToWork stays off and leaves them untouched. Install the newer version again."):format(Helper.savedTooNew, Helper.SCHEMA))
    end
    return
  end
  -- ReadyToWork was BalHelper until 1.24.0: both at once would sell, open, place and mark everything twice.
  local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded
  local ok, oldLoaded = pcall(isLoaded or function() end, "BalHelper")
  if ok and oldLoaded then
    Helper.Print("The old BalHelper addon is still loaded, so ReadyToWork stays off. Remove the BalHelper folder from AddOns and /reload.")
    Helper.saved, Helper.db, Helper.charKey = nil, nil, nil
    return
  end
  Helper.BindCharacter(Helper.saved)
  for _, start in ipairs(starters) do
    Call(start)
  end
  -- (Set in the saved file written when BalHelper and Minimap Fan became ReadyToWork, 1.24.0: said once.)
  if Helper.db.renamedFrom then
    Helper.db.renamedFrom = nil
    Helper.Print("BalHelper is now called ReadyToWork, and Minimap Fan is part of it. Your settings came across. /rtw lists the commands and /rtw menu opens the settings; /bh and /minifan still work.")
  end
end)

Helper.On("PLAYER_LEVEL_UP", function(level)
  local _, char = Helper.Characters.Current()
  if not char then return end
  local n = not (issecretvalue and issecretvalue(level)) and tonumber(level) or nil
  if not n and type(UnitLevel) == "function" then
    local ok, cur = pcall(UnitLevel, "player")
    if ok and not (issecretvalue and issecretvalue(cur)) then n = tonumber(cur) end
  end
  if n and n > 0 then char.level = n end
end)

local function FindCharacter(query)
  local list = Helper.Characters.List()
  local needle = (query or ""):lower():match("^%s*(.-)%s*$")
  if needle == "" then return nil, list end
  for _, entry in ipairs(list) do
    if (entry.name and entry.name:lower() == needle) or entry.key:lower() == needle then
      return entry, list
    end
  end
  for _, entry in ipairs(list) do
    if (entry.name and entry.name:lower():sub(1, #needle) == needle) or entry.label:lower():find(needle, 1, true) then
      return entry, list
    end
  end
  return nil, list
end

Helper.commands.copy = function(_, typed)
  local trimmed = (typed or ""):match("^%s*(.-)%s*$")
  local entry, others = FindCharacter(trimmed)
  local featureArg = ""
  if not entry then
    local head, tail = trimmed:match("^(.-)%s+(%S+)$")
    if head and tail then
      local cand, list = FindCharacter(head)
      others = list
      local spec = Helper.FeatureByName and Helper.FeatureByName(tail)
      if cand and (spec or (cand.name and cand.name:find(" ", 1, true))) then
        entry, featureArg = cand, tail
      end
    end
  end
  if not entry and featureArg == "" then
    local first, rest = trimmed:match("^(%S+)%s*(.-)$")
    if first and first ~= "" then
      entry, others = FindCharacter(first)
      featureArg = rest or ""
    end
  end
  if not entry then
    if #others == 0 then
      Helper.Print("Log in on another character first so ReadyToWork has a character to copy from.")
    else
      local names = {}
      for _, info in ipairs(others) do names[#names + 1] = info.label end
      Helper.Print("Usage: /rtw copy <character> [helper]  ·  Characters: " .. table.concat(names, ", "))
    end
    return
  end
  if featureArg ~= "" then
    local spec = Helper.FeatureByName and Helper.FeatureByName(featureArg)
    if not (spec and spec.perChar) then
      Helper.Print("Per-character helpers you can copy: vendor, destroy, open, spells, talk.")
      return
    end
    local ok, changed, label = Helper.Characters.CopyFeature(entry.key, spec.key)
    if ok then
      Helper.Print(changed > 0
        and ("Copied %s settings from %s. /rtw undo takes it back."):format(spec.title or spec.key, label)
        or ("%s settings already match %s."):format(spec.title or spec.key, label))
    end
    return
  end
  local ok, copied, label = Helper.Characters.CopyAll(entry.key)
  if ok then
    Helper.Print(copied > 0
      and ("Copied %d per-character helper%s from %s. /rtw undo takes it back."):format(copied, copied == 1 and "" or "s", label)
      or ("Your per-character settings already match %s."):format(label))
  end
end
Helper.help[#Helper.help + 1] = "/rtw copy [character] [helper] - copy per-character settings from another character"

-- /readytowork and /rtw (and /balhelper, /bh from its old name) -------------------

SLASH_READYTOWORK1, SLASH_READYTOWORK2, SLASH_READYTOWORK3, SLASH_READYTOWORK4 = "/readytowork", "/rtw", "/balhelper", "/bh"
SlashCmdList.READYTOWORK = function(message)
  if not Helper.db then
    return
  end
  local word, rest = (message or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
  local command = Helper.commands[word]
  if command then
    -- also the words as typed, for commands that take a name (bar profiles)
    local typed = (message or ""):match("^%s*%S*%s*(.-)%s*$")
    -- A feature's command is a settings edit like any other, so Undo covers it.
    local feature = Helper.FeatureForCommand(word)
    if feature and Helper.Store then
      local label = ("/rtw %s%s"):format(word, rest ~= "" and (" " .. rest) or "")
      Call(Helper.Store.Edit, feature, label, function() command(rest, typed) end)
    else
      Call(command, rest, typed)
    end
    return
  end
  Helper.Print("version " .. Helper.version)
  for _, line in ipairs(Helper.help) do
    print("  " .. line)
  end
end
