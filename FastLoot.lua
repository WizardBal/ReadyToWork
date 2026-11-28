-- Grabs all unlocked loot slots at once on LOOT_READY / LOOT_OPENED so auto-looting finishes in one
-- frame without the ~0.4s loot window animation delay or flash.
--
-- Never calls LootFrame:Hide() or CloseLoot() while requests are in flight (LootFrameMixin:OnHide()
-- closes the loot session on the server and would cancel items). Instead, sets LootFrame:SetAlpha(0)
-- until LOOT_CLOSED or whenever any item stays behind (BoP prompts, locked slots, full bags).

local _, Helper = ...

local FastLoot = {}
Helper.FastLoot = FastLoot

local REVEAL_DELAY = 0.30

local settings
local sessionActive, blocked, sessionToken = false, false, 0
local attempted = {}
local suppressing, savedAlpha, lootHooked = false, nil, false

local function Plain(value)
  if issecretvalue and issecretvalue(value) then return nil end
  return value
end

local function Read(func, ...)
  if type(func) ~= "function" then return nil end
  local ok, value = pcall(func, ...)
  if ok then return Plain(value) end
end

local function IsEditMode(frame)
  if frame and frame.isInEditMode == true then return true end
  if EditModeManagerFrame and type(EditModeManagerFrame.IsEditModeActive) == "function" then
    return Read(EditModeManagerFrame.IsEditModeActive, EditModeManagerFrame) == true
  end
  return false
end

local function EnsureLootHook()
  if lootHooked or not (LootFrame and type(LootFrame.HookScript) == "function") then
    return
  end
  lootHooked = true
  LootFrame:HookScript("OnShow", function(self)
    if suppressing and not blocked and not IsEditMode(self) then
      self:SetAlpha(0)
      if type(self.EnableMouse) == "function" then
        pcall(self.EnableMouse, self, false)
      end
    end
  end)
end

local function SuppressLootWindow()
  if not settings or settings.hideWindow == false or blocked then return end
  if IsEditMode(LootFrame) then return end
  EnsureLootHook()
  suppressing = true
  if LootFrame and not (LootFrame.IsForbidden and LootFrame:IsForbidden()) then
    if savedAlpha == nil and type(LootFrame.GetAlpha) == "function" then
      local cur = LootFrame:GetAlpha()
      savedAlpha = (type(cur) == "number" and cur > 0) and cur or 1
    end
    LootFrame:SetAlpha(0)
    if type(LootFrame.EnableMouse) == "function" then
      pcall(LootFrame.EnableMouse, LootFrame, false)
    end
  end
end

local function RestoreLootWindow()
  if not suppressing then return end
  suppressing = false
  if LootFrame and not (LootFrame.IsForbidden and LootFrame:IsForbidden()) then
    LootFrame:SetAlpha((savedAlpha and savedAlpha > 0) and savedAlpha or 1)
    if type(LootFrame.EnableMouse) == "function" then
      pcall(LootFrame.EnableMouse, LootFrame, true)
    end
  end
  savedAlpha = nil
end

function FastLoot.GameAutoLootOn()
  if C_CVar and type(C_CVar.GetCVarBool) == "function" then
    return Read(C_CVar.GetCVarBool, "autoLootDefault") == true
  end
  if type(GetCVar) == "function" then
    return Read(GetCVar, "autoLootDefault") == "1"
  end
  return false
end

function FastLoot.ShouldAutoLoot(eventAutoLoot)
  local modified = type(IsModifiedClick) == "function" and Read(IsModifiedClick, "AUTOLOOTTOGGLE") == true
  if settings and settings.always then
    return not modified
  end
  if type(eventAutoLoot) == "boolean" then
    return eventAutoLoot
  end
  return FastLoot.GameAutoLootOn() ~= modified
end

local function HasSlotContent(slot)
  if type(LootSlotHasItem) == "function" and Read(LootSlotHasItem, slot) == false then
    return false, false
  end
  if type(GetLootSlotInfo) ~= "function" then
    return false, false
  end
  local ok, texture, item, _, currencyID, _, locked, _, _, _, isCoin = pcall(GetLootSlotInfo, slot)
  if not ok then return false, false end
  texture, item, currencyID, locked, isCoin =
    Plain(texture), Plain(item), Plain(currencyID), Plain(locked), Plain(isCoin)
  local has = texture ~= nil or item ~= nil or currencyID ~= nil or isCoin == true
  return has, locked == true
end

local function RemainingSlots()
  local count = 0
  for slot = 1, Read(GetNumLootItems) or 0 do
    if HasSlotContent(slot) then
      count = count + 1
    end
  end
  return count
end

local function Sweep(eventAutoLoot)
  if not settings or not settings.enabled then
    RestoreLootWindow()
    return
  end
  if Helper.Opener and Helper.Opener.IsOpening and Helper.Opener.IsOpening() then
    return
  end
  if not FastLoot.ShouldAutoLoot(eventAutoLoot) then
    RestoreLootWindow()
    return
  end
  local count = Read(GetNumLootItems) or 0
  if count <= 0 then return end
  if not sessionActive then
    sessionActive = true
    blocked = false
    for k in pairs(attempted) do attempted[k] = nil end
    sessionToken = sessionToken + 1
  end
  local token = sessionToken
  for slot = count, 1, -1 do
    local hasItem, isLocked = HasSlotContent(slot)
    if hasItem then
      if isLocked then
        blocked = true
      elseif not attempted[slot] then
        if not blocked and settings.hideWindow ~= false then
          SuppressLootWindow()
        end
        attempted[slot] = true
        pcall(LootSlot, slot)
      end
    end
  end
  if blocked then
    RestoreLootWindow()
  elseif settings.hideWindow ~= false then
    SuppressLootWindow()
    if C_Timer and type(C_Timer.After) == "function" then
      C_Timer.After(REVEAL_DELAY, function()
        if sessionActive and sessionToken == token and suppressing and RemainingSlots() > 0 then
          blocked = true
          RestoreLootWindow()
        end
      end)
    end
  end
end

function FastLoot.Apply()
  if not settings or not settings.enabled or settings.hideWindow == false then
    RestoreLootWindow()
  end
end

Helper.Feature(function()
  settings = Helper.db.fastLoot
  if not (GetNumLootItems and GetLootSlotInfo and LootSlot) then return end

  Helper.On("LOOT_READY", function(autoLoot)
    Sweep(autoLoot)
  end)

  Helper.On("LOOT_OPENED", function(autoLoot)
    Sweep(autoLoot)
  end)

  Helper.On("LOOT_BIND_CONFIRM", function()
    if sessionActive then
      blocked = true
      RestoreLootWindow()
    end
  end)

  Helper.On("UI_ERROR_MESSAGE", function(_, message)
    local text = Plain(message)
    if sessionActive and text and ERR_INV_FULL and text == ERR_INV_FULL then
      blocked = true
      RestoreLootWindow()
    end
  end)

  Helper.On("LOOT_CLOSED", function()
    sessionActive = false
    blocked = false
    for k in pairs(attempted) do attempted[k] = nil end
    sessionToken = sessionToken + 1
    RestoreLootWindow()
  end)

  local function command(rest)
    local first, second = (rest or ""):match("^(%S*)%s*(.-)$")
    if first == "hide" then
      if second == "on" then settings.hideWindow = true
      elseif second == "off" then settings.hideWindow = false
      else settings.hideWindow = not settings.hideWindow end
      FastLoot.Apply()
      Helper.Print("Fast loot window hiding " .. (settings.hideWindow ~= false and "on." or "off."))
      return
    end
    if first == "always" then
      if second == "on" then settings.always = true
      elseif second == "off" then settings.always = false
      else settings.always = not settings.always end
      Helper.Print("Fast loot when WoW Auto Loot is off: " .. (settings.always and "on." or "off."))
      return
    end
    Helper.Toggle(settings, first, "Fast loot")
    FastLoot.Apply()
  end

  Helper.commands.loot = command
  Helper.commands.fastloot = command
  Helper.commands.speedloot = command
  Helper.help[#Helper.help + 1] =
    "/rtw loot [on|off|hide|always] - grab all loot slots at once without waiting on the loot window"
end)
