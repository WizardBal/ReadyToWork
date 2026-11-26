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
  Helper.version = ok and type(version) == "string" and version ~= "" and version or "1.57.3"
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
    Helper.db = db
  end
end)

Helper.On("PLAYER_LOGIN", function()
  if not Helper.db then
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
    Helper.db = nil
    return
  end
  for _, start in ipairs(starters) do
    Call(start)
  end
  -- (Set in the saved file written when BalHelper and Minimap Fan became ReadyToWork, 1.24.0: said once.)
  if Helper.db.renamedFrom then
    Helper.db.renamedFrom = nil
    Helper.Print("BalHelper is now called ReadyToWork, and Minimap Fan is part of it. Your settings came across. /rtw lists the commands and /rtw menu opens the settings; /bh and /minifan still work.")
  end
end)

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
