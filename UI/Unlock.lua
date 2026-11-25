-- Unlock mode (/rtw unlock, General > Unlock frames, a feature page's Move button, or its key binding):
-- every ReadyToWork frame on screen gets a labelled outline, shown even while the frame itself is hidden.
-- Drag an outline to move its frame, turn the mouse wheel over it to resize it, right-click it to put it
-- back. Done, Escape, or /rtw unlock again ends it. Alt-drag keeps working on the frames themselves at any
-- time.

local _, Helper = ...
local W, Frames = Helper.Widgets, Helper.Frames
local Unlock = {}
Helper.Unlock = Unlock

local bar, active, only
local overlays = {}

-- Where a frame is, in its own scale: its saved place or its first place.
local function Anchor(entry)
  local saved = Helper.db.positions[entry.key]
  if type(saved) == "table" and saved[1] then return saved[1], saved[2], saved[3], saved[4] end
  local d = entry.default
  return d[1], d[2], d[3], d[4]
end

local function Place(overlay)
  local entry = overlay.entry
  local target = entry.frame
  local point, relativePoint, x, y = Anchor(entry)
  local width = math.max(60, target:GetWidth() or 60)
  local height = math.max(24, target:GetHeight() or 24)
  overlay:SetScale(Frames.Scale(entry.key))
  overlay:ClearAllPoints()
  overlay:SetPoint(point, UIParent, relativePoint, x, y)
  overlay:SetSize(width, height)
  overlay.size:SetText(("%d%%"):format(math.floor(Frames.Scale(entry.key) * 100 + 0.5)))
end

local function Build(entry)
  local overlay = CreateFrame("Frame", nil, UIParent)
  overlay.entry = entry
  overlay:SetFrameStrata("FULLSCREEN_DIALOG")
  overlay:SetMovable(true)
  overlay:SetClampedToScreen(true)
  overlay:EnableMouse(true)
  overlay:EnableMouseWheel(true)
  overlay:RegisterForDrag("LeftButton")
  overlay.bg, overlay.border = W.Surface(overlay, "md", { .08, .36, .26, .32 }, { .22, .88, .62, .90 })
  overlay.label = W.Font(overlay, "small")
  overlay.label:SetPoint("CENTER", 0, 6)
  overlay.label:SetJustifyH("CENTER")
  overlay.label:SetTextColor(unpack(W.colors.text))
  overlay.label:SetText(entry.title)
  overlay.size = W.Font(overlay, "micro")
  overlay.size:SetPoint("TOP", overlay.label, "BOTTOM", 0, -2)
  overlay.size:SetTextColor(unpack(W.colors.on))
  overlay:SetScript("OnDragStart", function(self)
    if not Frames.CanChange(entry.key) then
      Helper.Print(entry.title .. " can be moved after combat.")
      return
    end
    self:StartMoving()
  end)
  overlay:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relativePoint, x, y = self:GetPoint(1)
    Frames.Save(entry.key, point, relativePoint, x, y)
    Helper.RestorePlacement(entry.key)
    Place(self)
  end)
  overlay:SetScript("OnMouseWheel", function(self, delta)
    if not Frames.CanChange(entry.key) then return end
    Frames.SetScale(entry.key, Frames.Scale(entry.key) + delta * 0.05)
    Place(self)
  end)
  overlay:SetScript("OnMouseUp", function(self, mouse)
    if mouse == "RightButton" and Frames.CanChange(entry.key) then
      Frames.Reset(entry.key)
      Place(self)
    end
  end)
  overlay:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(entry.title, 1, 1, 1)
    GameTooltip:AddLine("Drag: move", 1, 1, 1)
    GameTooltip:AddLine("Mouse wheel: bigger or smaller", 1, 1, 1)
    GameTooltip:AddLine("Right-click: back to its first place and size", 1, 1, 1)
    GameTooltip:Show()
  end)
  overlay:SetScript("OnLeave", function(self) if GameTooltip:IsOwned(self) then GameTooltip:Hide() end end)
  overlays[entry.key] = overlay
  return overlay
end

local function BuildBar()
  bar = CreateFrame("Frame", "ReadyToWorkUnlockBar", UIParent)
  bar:SetFrameStrata("FULLSCREEN_DIALOG")
  bar:SetSize(580, 42)
  bar:SetPoint("TOP", UIParent, "TOP", 0, -90)
  W.Shadow(bar, 14, .50)
  W.Surface(bar, "lg", W.colors.window, W.colors.accentBorder, "BACKGROUND", -2)
  bar.text = W.Font(bar, "small")
  bar.text:SetPoint("LEFT", 16, 0)
  bar.text:SetPoint("RIGHT", -168, 0)
  local done = W.Button(bar, "Done", "primary")
  done:SetSize(68, 26); done:SetPoint("RIGHT", -10, 0)
  done:SetScript("OnClick", function() Unlock.Stop() end)
  local reset = W.Button(bar, "Reset all", "danger")
  reset:SetSize(74, 26); reset:SetPoint("RIGHT", done, "LEFT", -6, 0)
  reset:SetScript("OnClick", function(self)
    if not (self.confirmUntil and GetTime() <= self.confirmUntil) then
      self.confirmUntil = GetTime() + 4
      self.label:SetText("Sure?")
      return
    end
    self.confirmUntil = nil
    self.label:SetText("Reset all")
    for key in pairs(overlays) do
      if overlays[key]:IsShown() and Frames.CanChange(key) then Frames.Reset(key); Place(overlays[key]) end
    end
  end)
  -- Escape ends unlock mode.
  bar:SetScript("OnHide", function() if active then Unlock.Stop() end end)
  if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "ReadyToWorkUnlockBar") end
  bar:Hide()
end

-- Starts unlock mode, for every frame or (with `key`) just that one.
function Unlock.Start(key)
  if not bar then BuildBar() end
  only = key
  active = true
  local count = 0
  for name, entry in pairs(Frames.Movable()) do
    local overlay = overlays[name] or Build(entry)
    overlay.entry = entry
    if not key or key == name then
      Place(overlay)
      overlay:Show()
      count = count + 1
    else
      overlay:Hide()
    end
  end
  if count == 0 then
    active = false
    Helper.Print(key and "That frame hasn't been made yet: switch its helper on first." or "No ReadyToWork frames to move yet.")
    return false
  end
  bar.text:SetText(key and ("Moving the %s: drag it, mouse wheel to resize, right-click to reset."):format(Frames.Movable()[key].title:lower())
    or "Drag an outline to move its frame · mouse wheel resizes · right-click resets")
  bar:Show()
  return true
end

function Unlock.Stop()
  active = false
  for _, overlay in pairs(overlays) do overlay:Hide() end
  if bar and bar:IsShown() then bar:Hide() end
end

function Unlock.Active()
  return active == true, only
end

Helper.commands.unlock = function()
  if active then Unlock.Stop() else Unlock.Start() end
end
Helper.help[#Helper.help + 1] = "/rtw unlock - move, resize or reset ReadyToWork's frames"
