-- Opens clams and other containers in the bags (the game's "Right Click to Open" items: a bag slot's
-- hasLoot), one at a time, and takes what's inside when the game's own auto loot is off.
--
-- It waits while opening could do something else with the item: in combat, while casting, with an
-- item on the cursor, while dead, and while any vendor, bank, mailbox, auction house, trade or other
-- interaction window or a loot window is open (using a bag item there sells it, banks it or mails it).
-- Locked lockboxes, items on the never-open list and items that don't open are left alone; an item
-- that fails to open is skipped until the next login. If the game refuses an automatic open, "Open
-- now" (menu, or /rtw open now) opens one per click.

local ADDON, Helper = ...

local Open = {}
Helper.Opener = Open

local START_DELAY = 0.30    -- seconds after the bags settle before looking
local LOOT_RESUME_DELAY = 0.06 -- fast open right after a corpse/world loot window closes
local NEXT_DELAY = 0.10     -- ... between one container and the next
local SETTLE_DELAY = 0.08   -- ... after a container's loot closes before settling
local REVEAL_TIMEOUT = 0.40 -- failsafe to reveal LootFrame if items remain unlootable
local SUPPRESS_GUARD = 0.50 -- restore LootFrame quickly if UseContainerItem opens no loot window
local TIMEOUT = 2.5         -- a container that hasn't opened by then is skipped this session

-- Clams by item ID (classic and later); the English "Clam" in the name covers others
local CLAMS = {
  [5523] = true, [5524] = true, [7973] = true, [15874] = true,     -- Small Barnacled, Thick-shelled, Big-mouth, Soft-shelled
  [24476] = true, [36781] = true, [44700] = true, [45909] = true, [52340] = true,
}
local WHICH = { clams = "Clams only", common = "White and gray containers", all = "Any container" }

local settings
local busy = {}           -- what's pausing it: interaction types, "trade", "loot"
local pending             -- the container just opened: { key, bag, slot, itemID, link, at, count }
local failed = {}         -- key -> true: tried this session, didn't open
local batch = {}          -- link -> count opened since the last chat line
local scheduleToken, scheduledAt = 0, nil
local blocked, blockedSaid = false, false
local pausedForSpace, drainingAll = false, false
local suppressing, savedAlpha, lootHooked = false, nil, false
local bagBar, hookedBagFrames = nil, {}
local UpdateBagBar

local function Plain(value)
  if issecretvalue and issecretvalue(value) then return nil end
  return value
end

local function Read(func, ...)
  if type(func) ~= "function" then return nil end
  local ok, value = pcall(func, ...)
  if ok then return Plain(value) end
end

local function IsClam(info)
  if CLAMS[info.itemID] then return true end
  local name = Plain(info.itemName)
  return type(name) == "string" and name:find("Clam", 1, true) ~= nil
end

-- A lockbox still locked: its tooltip says so (LOCKED). A picked one opens like any other.
local function StillLocked(bag, slot)
  local data = C_TooltipInfo and Read(C_TooltipInfo.GetBagItem, bag, slot)
  local lines = type(data) == "table" and Plain(data.lines)
  local locked = _G.LOCKED or "Locked"
  if type(lines) ~= "table" then return false end
  for _, line in ipairs(lines) do
    if type(line) == "table" and Plain(line.leftText) == locked then return true end
  end
  return false
end

local function KeyOf(bag, slot, itemID)
  return Helper.BagItemGUID(bag, slot) or (itemID .. ":" .. bag .. ":" .. slot)
end

-- A lockbox found locked isn't read again for LOCKED_RECHECK seconds (reading means building its tooltip, and
-- the bags are looked through at every bag update: a locked box was read again each time).
local LOCKED_RECHECK = 30
local lockedUntil = {}   -- key -> time
local function Locked(bag, slot, itemID)
  local key = KeyOf(bag, slot, itemID)
  local now = GetTime()
  if (lockedUntil[key] or 0) > now then
    return true
  end
  if StillLocked(bag, slot) then
    lockedUntil[key] = now + LOCKED_RECHECK
    return true
  end
  lockedUntil[key] = nil
  return false
end

-- Whether a bag slot holds a container this should open
local function Wanted(bag, slot, info)
  if not info or Plain(info.hasLoot) ~= true or info.isLocked or not info.itemID then return false end
  if settings.skip[info.itemID] then return false end
  if settings.which == "clams" then
    if not IsClam(info) then return false end
  elseif settings.which ~= "all" then
    if (info.quality or 99) > (Enum and Enum.ItemQuality and Enum.ItemQuality.Common or 1) then return false end
  end
  return not Locked(bag, slot, info.itemID)
end

-- Every container in the bags this would open, whatever's pausing it: { bag, slot, itemID, link, key }
function Open.List()
  local list = {}
  for _, bag in ipairs(Helper.Bags()) do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if Wanted(bag, slot, info) then
        local key = KeyOf(bag, slot, info.itemID)
        if not failed[key] then
          list[#list + 1] = { bag = bag, slot = slot, itemID = info.itemID, link = info.hyperlink,
            key = key, count = info.stackCount or 1 }
        end
      end
    end
  end
  return list
end

-- Every container in the bags, wanted or not (for the never-open menu): itemID -> link
function Open.Openable()
  local found = {}
  for _, bag in ipairs(Helper.Bags()) do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and Plain(info.hasLoot) == true and info.itemID then found[info.itemID] = info.hyperlink end
    end
  end
  return found
end

-- (not the reagent bag: what a container holds mostly can't go there)
local function FreeSlots()
  return Helper.FreeSlots()
end

-- A window noted as open that the game says is closed (its closing event missed): forgotten
local function ForgetClosedWindows()
  local manager = C_PlayerInteractionManager
  for kind in pairs(busy) do
    if type(kind) == "number" and manager and manager.IsInteractingWithNpcOfType
        and Read(manager.IsInteractingWithNpcOfType, kind) == false then
      busy[kind] = nil
    end
  end
  if busy.loot and (Read(GetNumLootItems) or 0) == 0 and not (LootFrame and LootFrame:IsShown()) then busy.loot = nil end
  if busy.trade and not (TradeFrame and TradeFrame:IsShown()) then busy.trade = nil end
end

-- nil when it may open now, else why not
local function Paused(ignoreKeepFree)
  if InCombatLockdown() or Read(UnitAffectingCombat, "player") == true then return "you're in combat" end
  ForgetClosedWindows()
  if next(busy) then return "a window is open" end
  if Read(UnitIsDeadOrGhost, "player") == true then return "you're dead" end
  if GetCursorInfo and GetCursorInfo() ~= nil then return "there's an item on your cursor" end
  if Read(UnitCastingInfo, "player") ~= nil or Read(UnitChannelInfo, "player") ~= nil then return "you're casting" end
  if not ignoreKeepFree and FreeSlots() < (settings.keepFree or 0) then return "your bags are full" end
end

local function BagHost()
  local combined = _G.ContainerFrameCombinedBags
  if combined and combined.IsShown and combined:IsShown() then return combined end
  local limit = _G.NUM_CONTAINER_FRAMES or 13
  for i = 1, limit do
    local frame = _G["ContainerFrame" .. i]
    if frame and frame.IsShown and frame:IsShown() then return frame end
  end
end

local function HookBagFrames()
  local frames = {}
  if _G.ContainerFrameCombinedBags then frames[#frames + 1] = _G.ContainerFrameCombinedBags end
  local limit = _G.NUM_CONTAINER_FRAMES or 6
  for i = 1, limit do
    local frame = _G["ContainerFrame" .. i]
    if frame then frames[#frames + 1] = frame end
  end
  for _, frame in ipairs(frames) do
    if not hookedBagFrames[frame] and frame.HookScript then
      hookedBagFrames[frame] = true
      pcall(frame.HookScript, frame, "OnShow", function() UpdateBagBar() end)
      pcall(frame.HookScript, frame, "OnHide", function() UpdateBagBar() end)
    end
  end
end

local function BuildBagBar()
  if bagBar then return bagBar end
  local bar = CreateFrame("Frame", "ReadyToWorkOpenBagBar", _G.UIParent)
  bar:SetHeight(34)
  bar:SetFrameStrata("HIGH")
  bar:SetClampedToScreen(true)

  local W = Helper.Widgets
  if W and W.Surface and W.Font and W.Button then
    W.Shadow(bar, 10, .45)
    bar.bg, bar.border = W.Surface(bar, "md", W.colors.window, W.colors.accentBorder)
    bar.icon = W.Icon(bar, "Interface\\Icons\\INV_Box_01", 18)
    bar.icon:SetPoint("LEFT", 10, 0)
    bar.text = W.Font(bar, "small")
    bar.text:SetPoint("LEFT", 34, 0)
    bar.text:SetPoint("RIGHT", -94, 0)
    if bar.text.SetWordWrap then bar.text:SetWordWrap(false) end
    bar.text:SetTextColor(unpack(W.colors.text))
    bar.button = W.Button(bar, "Open all", "primary")
  else
    bar.icon = bar:CreateTexture(nil, "ARTWORK")
    bar.icon:SetTexture("Interface\\Icons\\INV_Box_01")
    bar.icon:SetSize(18, 18)
    bar.icon:SetPoint("LEFT", 10, 0)
    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.text:SetPoint("LEFT", 34, 0)
    bar.text:SetPoint("RIGHT", -94, 0)
    bar.button = CreateFrame("Button", nil, bar)
    bar.button.label = bar.button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.button.label:SetPoint("CENTER")
    bar.button.label:SetText("Open all")
  end

  bar.button:SetSize(78, 24)
  bar.button:SetPoint("RIGHT", -6, 0)
  bar.button:SetScript("OnClick", function() Open.OpenAll() end)
  bar.button:SetScript("OnEnter", function(self)
    if not _G.GameTooltip then return end
    _G.GameTooltip:SetOwner(self, "ANCHOR_TOP")
    _G.GameTooltip:SetText("Open all containers", 1, 1, 1)
    if bar.blocker then
      _G.GameTooltip:AddLine("Can't open now: " .. bar.blocker .. ".", 1, .6, .4, true)
    else
      _G.GameTooltip:AddLine("Unpauses and opens all waiting containers in your bags.", nil, nil, nil, true)
    end
    _G.GameTooltip:Show()
  end)
  bar.button:SetScript("OnLeave", function(self)
    if _G.GameTooltip and _G.GameTooltip.IsOwned and _G.GameTooltip:IsOwned(self) then _G.GameTooltip:Hide() end
  end)

  bar:Hide()
  bagBar = bar
  return bar
end

UpdateBagBar = function()
  if not settings then return end
  HookBagFrames()
  if not settings.enabled or not pausedForSpace then
    if bagBar then bagBar:Hide() end
    return
  end
  local waiting = #Open.List()
  if waiting == 0 then
    pausedForSpace = false
    drainingAll = false
    if bagBar then bagBar:Hide() end
    return
  end
  local host = BagHost()
  if not host then
    if bagBar then bagBar:Hide() end
    return
  end
  local bar = BuildBagBar()
  local width = math.max(248, math.floor((host.GetWidth and host:GetWidth() or 280) + 0.5))
  bar:SetWidth(width)
  bar:ClearAllPoints()
  bar:SetPoint("BOTTOMRIGHT", host, "TOPRIGHT", 0, 4)
  if host.GetFrameLevel and bar.SetFrameLevel then
    bar:SetFrameLevel(math.max(10, (host:GetFrameLevel() or 0) + 5))
  end
  bar.text:SetText(("Containers paused · %d waiting"):format(waiting))
  local blocker = Paused(true)
  if not blocker and FreeSlots() == 0 then blocker = "free a bag slot first" end
  bar.blocker = blocker
  if bar.button.SetEnabled then bar.button:SetEnabled(blocker == nil) end
  if bar.button.SetAlpha then bar.button:SetAlpha(blocker and .45 or 1) end
  bar:Show()
end

local function SayBatch()
  if not next(batch) then return end
  if settings.chat then
    local parts = {}
    for link, count in pairs(batch) do
      parts[#parts + 1] = count > 1 and (link .. " x" .. count) or link
    end
    table.sort(parts)
    Helper.Print("Opened " .. table.concat(parts, ", ") .. ".")
  end
  batch = {}
end

local function EnsureLootHook()
  if lootHooked or not LootFrame or (LootFrame.IsForbidden and LootFrame:IsForbidden()) or not LootFrame.HookScript then
    return
  end
  lootHooked = true
  LootFrame:HookScript("OnShow", function(self)
    if suppressing then
      self:SetAlpha(0)
      pcall(self.EnableMouse, self, false)
    end
  end)
end

local function SuppressLootWindow()
  EnsureLootHook()
  suppressing = true
  if LootFrame and not (LootFrame.IsForbidden and LootFrame:IsForbidden()) then
    if savedAlpha == nil and LootFrame.GetAlpha then
      savedAlpha = LootFrame:GetAlpha() or 1
    end
    LootFrame:SetAlpha(0)
    pcall(LootFrame.EnableMouse, LootFrame, false)
  end
end

local function RestoreLootWindow()
  if not suppressing then return end
  suppressing = false
  if LootFrame and not (LootFrame.IsForbidden and LootFrame:IsForbidden()) then
    LootFrame:SetAlpha(savedAlpha or 1)
    pcall(LootFrame.EnableMouse, LootFrame, true)
  end
  savedAlpha = nil
end

local function RemainingLootSlots()
  local count = 0
  for slot = 1, Read(GetNumLootItems) or 0 do
    if LootSlotHasItem == nil or Read(LootSlotHasItem, slot) ~= false then
      count = count + 1
    end
  end
  return count
end

local function IsPendingContainerLoot()
  if not pending then return false end
  if pending.itemLoot then return true end
  if type(GetLootSourceInfo) == "function" then
    local src = Read(GetLootSourceInfo, 1)
    if type(src) == "string" then
      if src == pending.key or src:find("^Item%-") then return true end
      if src:find("^Creature%-") or src:find("^GameObject%-") then return false end
    end
  end
  return (GetTime() - (pending.at or 0)) <= 1.0
end

local function DrainLoot()
  for slot = (Read(GetNumLootItems) or 0), 1, -1 do
    if LootSlotHasItem == nil or Read(LootSlotHasItem, slot) ~= false then
      pcall(LootSlot, slot)
    end
  end
  if RemainingLootSlots() == 0 and type(CloseLoot) == "function" then
    pcall(CloseLoot)
  end
end

local Next

local function Schedule(delay)
  if not settings.enabled or blocked then return end
  if pausedForSpace and not drainingAll then return end
  local wait = delay or START_DELAY
  local due = GetTime() + wait
  if scheduledAt and scheduledAt <= due then return end
  scheduleToken = scheduleToken + 1
  scheduledAt = due
  local token = scheduleToken
  C_Timer.After(wait, function()
    if scheduleToken ~= token then return end
    scheduledAt = nil
    Next()
  end)
end

local function Settle(success)
  RestoreLootWindow()
  local done = pending
  pending = nil
  if not done then return end
  if success then
    batch[done.link or "a container"] = (batch[done.link or "a container"] or 0) + 1
    UpdateBagBar()
    Schedule(NEXT_DELAY)
    if Helper.RefreshSettings then Helper.RefreshSettings("Containers") end
    return
  end
  local spaceFull = done.spaceStall or FreeSlots() == 0 or (not drainingAll and FreeSlots() < (settings.keepFree or 0))
  if spaceFull then
    pausedForSpace = true
    drainingAll = false
    SayBatch()
    UpdateBagBar()
    if Helper.RefreshSettings then Helper.RefreshSettings("Containers") end
    return
  end
  failed[done.key] = true
  UpdateBagBar()
  Schedule(NEXT_DELAY)
end

-- Opens the next container. `byClick`: from the player's click (Open all / slash), allowed when the game
-- refused automatic opening, and saying why when it can't
local function OpenNext(byClick)
  if pending then return false end
  local why = Paused(drainingAll)
  if not why and drainingAll and FreeSlots() == 0 then
    why = "your bags are full"
  end
  if why then
    if byClick then Helper.Print("Can't open containers now: " .. why .. ".") end
    if why == "your bags are full" and #Open.List() > 0 then
      pausedForSpace = true
      drainingAll = false
    end
    if not next(busy) then SayBatch() end
    UpdateBagBar()
    if Helper.RefreshSettings then Helper.RefreshSettings("Containers") end
    return false
  end
  local item = Open.List()[1]
  if not item then
    drainingAll = false
    pausedForSpace = false
    if byClick then Helper.Print("Nothing to open.") end
    SayBatch()
    UpdateBagBar()
    if Helper.RefreshSettings then Helper.RefreshSettings("Containers") end
    return false
  end
  -- (looked at a moment ago: still the same item, still a container, in that slot)
  local info = C_Container.GetContainerItemInfo(item.bag, item.slot)
  if not Wanted(item.bag, item.slot, info) or info.itemID ~= item.itemID then
    Schedule(NEXT_DELAY)
    return false
  end
  local attempt = { key = item.key, bag = item.bag, slot = item.slot, itemID = item.itemID, link = item.link,
    at = GetTime(), count = info.stackCount or 1 }
  pending = attempt
  SuppressLootWindow()
  local ok = pcall(C_Container.UseContainerItem, item.bag, item.slot)
  if not ok then
    RestoreLootWindow()
    Settle(false)
    return false
  end
  C_Timer.After(SUPPRESS_GUARD, function()
    if pending == attempt and not busy.loot and suppressing then
      RestoreLootWindow()
    end
  end)
  C_Timer.After(TIMEOUT, function()
    -- (its loot window still up: LOOT_CLOSED settles it)
    if pending == attempt and not busy.loot then
      -- (gone from its slot without a loot window: some containers hand their contents straight over)
      local now = C_Container.GetContainerItemInfo(attempt.bag, attempt.slot)
      local opened = not now or now.itemID ~= attempt.itemID or (now.stackCount or 1) < attempt.count
      Settle(opened)
    end
  end)
  return true
end

function Next()
  if not settings.enabled or blocked then return end
  if pausedForSpace and not drainingAll then
    UpdateBagBar()
    return
  end
  OpenNext(drainingAll)
end

-- /rtw open now: one container, on the player's click
function Open.Now()
  if OpenNext(true) and blocked then
    Helper.Print("Opened one. Type /rtw open now again for the next.")
  end
end

function Open.IsPausedForSpace()
  return pausedForSpace == true
end

function Open.WaitingCount()
  return #Open.List()
end

function Open.BagBar()
  return bagBar
end

Open.UpdateBagBar = function() UpdateBagBar() end

function Open.OpenAll()
  if not settings or pending then return false end
  local blocker = Paused(true)
  if blocker then
    Helper.Print("Can't open containers now: " .. blocker .. ".")
    UpdateBagBar()
    return false
  end
  if FreeSlots() == 0 then
    Helper.Print("Free at least one bag slot first.")
    UpdateBagBar()
    return false
  end
  pausedForSpace = false
  blocked = false
  drainingAll = true
  UpdateBagBar()
  local started = OpenNext(true)
  if Helper.RefreshSettings then Helper.RefreshSettings("Containers") end
  return started
end

function Open.SetSkip(itemID, link, skip)
  if skip and type(link) ~= "string" then
    -- (a link typed in /rtw comes in lowercased: the game's own, by its ID)
    local getInfo = C_Item and C_Item.GetItemInfo
    local ok, _, known = false, nil, nil
    if getInfo then ok, _, known = pcall(getInfo, itemID) end
    link = ok and Plain(known) or nil
  end
  settings.skip[itemID] = skip and (link or true) or nil
  if not skip then
    for key in pairs(failed) do failed[key] = nil end   -- (and anything held back this session gets another try)
    Schedule()
  end
  UpdateBagBar()
end

Open.Refresh=Schedule
function Open.Which() return settings.which end
function Open.WhichLabels() return WHICH end

local function ItemFromText(text)
  local id = tonumber(text:match("item:(%d+)") or text:match("^(%d+)$"))
  return id, text:match("|H.-|h") and text or nil   -- (/rtw lowercases what's typed: then nil, and the ID decides)
end

Helper.Feature(function()
  settings = Helper.db.open
  if not WHICH[settings.which] then settings.which = "common" end
  if type(settings.keepFree) ~= "number" then settings.keepFree = 1 end
  if not (C_Container and C_Container.UseContainerItem and C_Container.GetContainerItemInfo) then return end

  Helper.On("BAG_UPDATE_DELAYED", function()
    if pending and not busy.loot then
      local now = C_Container.GetContainerItemInfo(pending.bag, pending.slot)
      if not now or now.itemID ~= pending.itemID or (now.stackCount or 1) < pending.count then Settle(true) end
    end
    if pausedForSpace then
      if #Open.List() == 0 then
        pausedForSpace = false
        drainingAll = false
      end
      UpdateBagBar()
      if Helper.RefreshSettings then Helper.RefreshSettings("Containers") end
    else
      Schedule()
    end
  end)
  Helper.On("LOOT_READY", function(autoLoot)
    busy.loot = true
    if pending and IsPendingContainerLoot() then
      pending.autoLoot = autoLoot == true
      DrainLoot()
    else
      RestoreLootWindow()
    end
  end)
  Helper.On("LOOT_OPENED", function(autoLoot, isFromItem)
    busy.loot = true
    if not isFromItem then
      RestoreLootWindow()
      return
    end
    if pending then
      pending.itemLoot = true
      pending.autoLoot = autoLoot == true
      DrainLoot()
      if RemainingLootSlots() > 0 then
        if FreeSlots() == 0 then pending.spaceStall = true end
        local attempt = pending
        C_Timer.After(REVEAL_TIMEOUT, function()
          if pending == attempt and busy.loot and RemainingLootSlots() > 0 then
            if FreeSlots() == 0 then attempt.spaceStall = true end
            RestoreLootWindow()
          end
        end)
      end
    end
  end)
  Helper.On("LOOT_SLOT_CLEARED", function()
    if pending and pending.itemLoot then
      if RemainingLootSlots() == 0 and type(CloseLoot) == "function" then
        pcall(CloseLoot)
      end
    end
  end)
  Helper.On("LOOT_BIND_CONFIRM", function()
    RestoreLootWindow()
  end)
  Helper.On("LOOT_CLOSED", function()
    RestoreLootWindow()
    busy.loot = nil
    if pending and pending.itemLoot then
      local attempt = pending
      C_Timer.After(SETTLE_DELAY, function()
        if pending ~= attempt then return end
        local info = C_Container.GetContainerItemInfo(attempt.bag, attempt.slot)
        Settle(not info or info.itemID ~= attempt.itemID or (info.stackCount or 1) < attempt.count)
      end)
    else
      Schedule(LOOT_RESUME_DELAY)
    end
  end)
  Helper.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(kind)
    busy[kind or "window"] = true
    UpdateBagBar()
  end)
  Helper.On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(kind)
    busy[kind or "window"] = nil
    UpdateBagBar()
    Schedule()
  end)
  Helper.On("TRADE_SHOW", function()
    busy.trade = true
    UpdateBagBar()
  end)
  Helper.On("TRADE_CLOSED", function()
    busy.trade = nil
    UpdateBagBar()
    Schedule()
  end)
  Helper.On("PLAYER_REGEN_DISABLED", function() UpdateBagBar() end)
  Helper.On("PLAYER_REGEN_ENABLED", function()
    UpdateBagBar()
    Schedule()
  end)
  Helper.On("PLAYER_UNGHOST", function()
    UpdateBagBar()
    Schedule()
  end)
  -- (your casts only: other units' cast events can carry a hidden unit)
  Helper.OnUnit("UNIT_SPELLCAST_STOP", { "player" }, function() Schedule() end)
  Helper.On("PLAYER_ENTERING_WORLD", function()
    RestoreLootWindow()
    for kind in pairs(busy) do busy[kind] = nil end   -- (a window can't stay open over a loading screen)
    blocked = false   -- (a place where the game wanted a click: somewhere new may not)
    UpdateBagBar()
    Schedule(2)
  end)
  -- the game refusing an automatic open: Open all / /rtw open now takes over
  local function Blocked(addon, action)
    if addon == ADDON and pending and type(action) == "string" and action:find("UseContainerItem", 1, true) then
      RestoreLootWindow()
      blocked = true
      pending = nil
      if not blockedSaid then
        blockedSaid = true
        Helper.Print("The game wants a click to open containers here. Type /rtw open now.")
      end
    end
  end
  Helper.On("ADDON_ACTION_BLOCKED", Blocked)
  Helper.On("ADDON_ACTION_FORBIDDEN", Blocked)

  HookBagFrames()
  if type(hooksecurefunc) == "function" then
    for _, fnName in ipairs({ "OpenAllBags", "ToggleAllBags", "ToggleBackpack", "OpenBackpack" }) do
      if type(_G[fnName]) == "function" then
        pcall(hooksecurefunc, fnName, function() UpdateBagBar() end)
      end
    end
  end

  Helper.commands.open = function(rest)
    local word, arg = rest:match("^(%S*)%s*(.-)$")
    if word == "now" then
      Open.Now()
    elseif word == "openall" or word == "resume" then
      Open.OpenAll()
    elseif WHICH[word] then
      settings.which = word
      Helper.Print("Containers to open: " .. WHICH[word] .. ".")
      Schedule()
    elseif word == "free" and tonumber(arg) then
      local keep = tonumber(arg)
      settings.keepFree = math.max(0, math.min(10, math.floor(keep)))
      Helper.Print(("Containers open while %d or more bag slots are free."):format(settings.keepFree))
      UpdateBagBar()
      Schedule()
    elseif word == "chat" and (arg == "on" or arg == "off") then
      settings.chat = arg == "on"
      Helper.Print("Chat lines for opened containers " .. (settings.chat and "on." or "off."))
    elseif (word == "skip" or word == "unskip") and arg ~= "" then
      local id, link = ItemFromText(arg)
      if not id then Helper.Print("Give an item link (shift-click it) or an item ID.") return end
      Open.SetSkip(id, link or settings.skip[id], word == "skip")
      Helper.Print((link or ("item " .. id)) .. (word == "skip" and " won't be opened." or " will be opened again."))
    elseif word == "list" then
      local any = false
      for id, link in pairs(settings.skip) do
        any = true
        print("  never open: " .. (type(link) == "string" and link or ("item " .. id)))
      end
      if not any then Helper.Print("The never-open list is empty.") end
    elseif word == "on" or word == "off" or word == "" then
      if Helper.Toggle(settings, word, "Opening containers") then
        blocked = false
        pausedForSpace = false
        drainingAll = false
        UpdateBagBar()
        Schedule()
      else
        pausedForSpace = false
        drainingAll = false
        RestoreLootWindow()
        SayBatch()
        UpdateBagBar()
      end
    else
      Helper.Print("/rtw open [on|off|now|clams|common|all|free <n>|chat on|off|skip <item>|unskip <item>|list]")
    end
  end
  Helper.help[#Helper.help + 1] = "/rtw open [on|off|now] - open clams and other containers in your bags"
  Helper.help[#Helper.help + 1] = "/rtw open clams | common | all, free <n>, chat on|off, skip|unskip <item>, list"
  Schedule(2)
end)
