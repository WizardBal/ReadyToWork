-- Movable frames. Every frame ReadyToWork puts on screen registers here through Helper.MakeMovable: its saved
-- place and size (ReadyToWorkDB.positions[key] = { point, relativePoint, x, y, scale }), Alt-drag or plain
-- drag, a reset, and the list unlock mode (UI\Unlock.lua) outlines. Protected frames are placed only out of
-- combat.

local _, Helper = ...
local Frames = {}
Helper.Frames = Frames

local registered, order = {}, {}
local deferred = {}

local MIN_SCALE, MAX_SCALE = 0.5, 2
local OWN_HINTS = { destroy = true, barProfiles = true }

local function InCombat()
  return type(InCombatLockdown) == "function" and InCombatLockdown()
end

local function Protected(target)
  if type(target.IsProtected) ~= "function" then return false end
  local ok, protected = pcall(target.IsProtected, target)
  return ok and protected == true
end

-- The feature that owns a frame's saved place, so moving it is an undoable edit of that feature.
local function Owner(key)
  for _, name in ipairs(Helper.featureOrder) do
    local spec = Helper.features[name]
    if spec.position == key then return name, spec end
  end
end

local function Place(key)
  local entry = registered[key]
  if not entry then return end
  local target = entry.frame
  if InCombat() and Protected(target) then deferred[key] = true; return end
  local saved = Helper.db and Helper.db.positions[key]
  local default = entry.default
  target:ClearAllPoints()
  if type(saved) == "table" and saved[1] then
    target:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
  else
    target:SetPoint(default[1], UIParent, default[2], default[3], default[4])
  end
  local scale = type(saved) == "table" and tonumber(saved[5]) or 1
  if target.SetScale then target:SetScale(math.max(MIN_SCALE, math.min(MAX_SCALE, scale))) end
end

Helper.positionSetters = setmetatable({}, { __index = function(_, key) return registered[key] and function() Place(key) end end })

function Helper.RestorePlacement(key)
  Place(key)
end

Helper.On("PLAYER_REGEN_ENABLED", function()
  for key in pairs(deferred) do
    deferred[key] = nil
    Place(key)
  end
end)

-- Saves a frame's place (and size), as an undoable edit when a feature owns it.
function Frames.Save(key, point, relativePoint, x, y, scale)
  local function save()
    local old = Helper.db.positions[key]
    scale = scale or (type(old) == "table" and old[5]) or nil
    Helper.db.positions[key] = { point, relativePoint, x, y, scale ~= 1 and scale or nil }
  end
  local owner, spec = Owner(key)
  if owner and Helper.Store then
    Helper.Store.Edit(owner, "Move " .. (spec.title or key), save)
  else
    save()
  end
end

-- Puts a frame back in its first place and size.
function Frames.Reset(key)
  local function reset() Helper.db.positions[key] = nil end
  local owner, spec = Owner(key)
  if owner and Helper.Store then
    Helper.Store.Edit(owner, "Reset " .. (spec.title or key) .. " position", reset)
  else
    reset()
  end
  Place(key)
end

-- Sets a frame's size, 0.5 to 2 times its normal size.
function Frames.SetScale(key, scale)
  local entry = registered[key]
  if not entry then return end
  scale = math.floor(math.max(MIN_SCALE, math.min(MAX_SCALE, scale)) * 20 + 0.5) / 20
  local saved = Helper.db.positions[key]
  local point, relativePoint, x, y
  if type(saved) == "table" and saved[1] then
    point, relativePoint, x, y = saved[1], saved[2], saved[3], saved[4]
  else
    point, relativePoint, x, y = entry.default[1], entry.default[2], entry.default[3], entry.default[4]
  end
  Frames.Save(key, point, relativePoint, x, y, scale)
  Place(key)
end

function Frames.Scale(key)
  local saved = Helper.db and Helper.db.positions[key]
  return type(saved) == "table" and tonumber(saved[5]) or 1
end

-- The frames unlock mode can move: [key] = entry ({ frame, title, default, needsAlt }).
function Frames.Movable()
  local list = {}
  for _, key in ipairs(order) do
    local entry = registered[key]
    if entry.title then list[key] = entry end
  end
  return list
end

function Frames.Order()
  return order
end

function Frames.Get(key)
  return registered[key]
end

-- Whether a frame can be moved or resized now (secure ones wait for the end of combat).
function Frames.CanChange(key)
  local entry = registered[key]
  return entry ~= nil and not (InCombat() and Protected(entry.frame))
end

-- Makes a frame draggable and remembers where it was left. With `needsAlt` it only moves while Alt is held,
-- for frames that also take clicks. `...` is its first place: point, relativePoint, x, y.
-- Frames with a title in a feature's `frames` (or `options.title`) show in unlock mode.
function Helper.MakeMovable(target, key, needsAlt, ...)
  local title
  for _, name in ipairs(Helper.featureOrder) do
    local frames = Helper.features[name].frames
    if frames and frames[key] then title = frames[key] end
  end
  if not registered[key] then order[#order + 1] = key end
  registered[key] = { frame = target, title = title, default = { ... }, needsAlt = needsAlt, key = key }
  target:SetMovable(true)
  target:SetClampedToScreen(true)
  target:EnableMouse(true)
  target:RegisterForDrag("LeftButton")
  target:SetScript("OnDragStart", function(self)
    if not needsAlt or IsAltKeyDown() then
      self.moving = true
      self:StartMoving()
    end
  end)
  target:SetScript("OnDragStop", function(self)
    if self.moving then
      self.moving = nil
      self:StopMovingOrSizing()
      local point, _, relativePoint, x, y = self:GetPoint(1)
      Frames.Save(key, point, relativePoint, x, y)
    end
  end)
  target.ResetPosition = function() Frames.Reset(key) end
  -- (the destroy button and the swap button say how to move them in their own first-use tips)
  if title and not OWN_HINTS[key] and target.HookScript then
    target:HookScript("OnShow", function()
      Frames.Hint(key, ("%s: %s to move it. /rtw unlock moves, resizes or resets any ReadyToWork frame.")
        :format(title, needsAlt and "Alt-drag" or "drag"))
    end)
  end
  Place(key)
end

-- Puts every registered frame back where it started.
function Helper.ResetPositions()
  for _, key in ipairs(order) do
    if registered[key].title then Frames.Reset(key) end
  end
  if Helper.BarUI and Helper.BarUI.ResetButton then Helper.BarUI.ResetButton() end
end

-- A one-line chat hint the first time a frame appears, saying how to move it.
function Frames.Hint(key, text)
  local general = Helper.db and Helper.db.general
  if not general or type(general.hints) ~= "table" or general.hints[key] then return end
  general.hints[key] = true
  Helper.Print(text)
end
