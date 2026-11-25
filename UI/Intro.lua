-- ReadyToWork's introduction: a small window saying what each helper does, whether it is on, and where to
-- change it. Its lines come from the declarations (Core\Features.lua), so it is never wrong about what's on.
-- It opens a few seconds after login for someone new to ReadyToWork, and once after each version update
-- (preserving all saved settings), unless "Don't show automatically on future updates" is ticked. /rtw intro
-- and General > Introduction open it any time.

local _, Helper = ...
local W = Helper.Widgets

local SHOW_DELAY = 3          -- seconds after login, once the login chat has settled
local WIDTH, LINE_HEIGHT = 790, 28
local RELEASE_NOTES = {
  ["1.57.0"] = "What's new: Intro now appears once after each update (keeping your settings), bar auto-update stays quiet on login, and release packaging is ready.",
}
local frame, listBox, listTop, listHeight

local function ParseVersion(version)
  if type(version) ~= "string" then return nil end
  local major, minor, patch = version:match("^(%d+)%.(%d+)%.?(%d*)")
  if not major then return nil end
  return tonumber(major), tonumber(minor), tonumber(patch) or 0
end

local function IsNewer(current, seen)
  if type(current) ~= "string" or current == "" then return false end
  if type(seen) ~= "string" or seen == "" then return true end
  if current == seen then return false end
  local cmaj, cmin, cpat = ParseVersion(current)
  local smaj, smin, spat = ParseVersion(seen)
  if cmaj and smaj then
    if cmaj ~= smaj then return cmaj > smaj end
    if cmin ~= smin then return cmin > smin end
    return cpat > spat
  end
  return true
end

local function ShouldAutoShow()
  local intro = Helper.db and Helper.db.intro
  if type(intro) ~= "table" then return false end
  if intro.show then return true, nil end
  if intro.skipUpdates then return false end
  if IsNewer(Helper.version, intro.seenVersion) then
    return true, intro.seenVersion
  end
  return false
end

Helper.Intro = {
  IsNewer = IsNewer,
  ShouldAutoShow = ShouldAutoShow,
}

local function Helpers()
  local list = {}
  for _, key in ipairs(Helper.featureOrder) do
    local spec = Helper.features[key]
    if spec.section and spec.defaults and spec.defaults.enabled ~= nil then list[#list + 1] = spec end
  end
  return list
end

local function SyncRow(row)
  local key = row.spec.key
  local db = Helper.db[key]
  local on = db ~= nil and db.enabled == true and not (key == "minimapFan" and Helper.fanStandsDown)
  row.setSwitch(on)
  row.icon:SetAlpha(on and 1 or .52)
  row.name:SetAlpha(on and 1 or .52)
  row.text:SetAlpha(on and 1 or .52)
end

local function Layout(opts)
  if not frame then return end
  local updated = type(opts) == "table" and opts.updated == true
  local from = type(opts) == "table" and opts.from or nil
  frame.Title:SetText("ReadyToWork" .. (Helper.version and (" v" .. Helper.version) or ""))
  if updated then
    if type(from) == "string" and from ~= "" then
      frame.Subtitle:SetText(("Updated from v%s — your settings were kept. Toggle any helper below, or open Settings for details."):format(from))
    else
      frame.Subtitle:SetText("Updated — your settings were kept. Toggle any helper below, or open Settings for details.")
    end
  else
    frame.Subtitle:SetText("Toggle any helper right here, or open Settings for details.")
  end

  local note = updated and Helper.version and RELEASE_NOTES[Helper.version]
  local bottomAnchor = listBox
  local whatsNewH = 0
  if note then
    frame.WhatsNew:SetText(note)
    frame.WhatsNew:Show()
    whatsNewH = math.max(18, math.ceil(tonumber(frame.WhatsNew.GetStringHeight and frame.WhatsNew:GetStringHeight()) or 18)) + 8
    bottomAnchor = frame.WhatsNew
  else
    frame.WhatsNew:Hide()
  end

  frame.Footer:ClearAllPoints()
  frame.Footer:SetPoint("TOPLEFT", bottomAnchor, "BOTTOMLEFT", 0, -10)
  local footerH = math.max(18, math.ceil(tonumber(frame.Footer.GetStringHeight and frame.Footer:GetStringHeight()) or 18))
  local height = listTop + listHeight + whatsNewH + footerH + 62
  frame:SetSize(WIDTH, height)
  local sw = UIParent and UIParent.GetWidth and UIParent:GetWidth() or 0
  local sh = UIParent and UIParent.GetHeight and UIParent:GetHeight() or 0
  if sw > 0 and sh > 0 then
    frame:SetScale(math.max(.5, math.min(1, (sw - 24) / WIDTH, (sh - 24) / height)))
  end
end

local function SyncAll()
  if not frame then return end
  for _, row in ipairs(frame.Lines) do
    SyncRow(row)
  end
  frame.DontShow:SetChecked(Helper.db.intro.skipUpdates == true)
end

local function ToggleHelper(spec)
  if not spec then return end
  local key = spec.key
  local db = Helper.db[key]
  if not db then return end
  local command = spec.command and Helper.commands[spec.command]
  local function applyToggle()
    local oldOutput = Helper.EditorOutput
    Helper.EditorOutput = function() end
    local ok, err = pcall(function()
      if key == "minimapFan" and Helper.fanStandsDown then
        if command then command("on") end
        return
      end
      local nextOn = db.enabled ~= true
      if command then
        command(nextOn and "on" or "off")
      else
        db.enabled = nextOn
        if spec.apply then spec.apply({ enabled = true }, db, nil) end
      end
    end)
    Helper.EditorOutput = oldOutput
    if not ok then error(err, 0) end
  end
  local nextOn = db.enabled ~= true
  if Helper.Store and Helper.Store.Edit then
    Helper.Store.Edit(key, spec.title .. (nextOn and " on" or " off"), applyToggle)
  else
    applyToggle()
  end
  SyncAll()
end

local function Build()
  local helpers = Helpers()
  listTop = 76
  local rowW = WIDTH - 52
  local textW = rowW - 184
  frame = CreateFrame("Frame", "ReadyToWorkIntro", UIParent)
  frame:SetSize(WIDTH, 400)
  frame:SetFrameStrata("DIALOG")
  frame:SetToplevel(true)
  Helper.MakeMovable(frame, "intro", false, "CENTER", "CENTER", 0, 60)
  W.Shadow(frame, 18, .55)
  W.Surface(frame, "lg", W.colors.window, W.colors.borderStrong, "BACKGROUND", -2)

  local badge = W.IconBadge(frame, "Interface\\Icons\\INV_Misc_Bag_10", 24, 36)
  badge:SetPoint("TOPLEFT", 18, -16)
  frame.Title = W.Font(frame, "title")
  frame.Title:SetPoint("TOPLEFT", badge, "TOPRIGHT", 12, -1)
  frame.Title:SetText("ReadyToWork")
  frame.Subtitle = W.Font(frame, "dim")
  frame.Subtitle:SetPoint("TOPLEFT", frame.Title, "BOTTOMLEFT", 0, -4)
  frame.Subtitle:SetWidth(WIDTH - 90)
  frame.Subtitle:SetText("Toggle any helper right here, or open Settings for details.")
  W.Rule(frame, "TOPLEFT", 18, -64, WIDTH - 36)

  listBox = CreateFrame("Frame", nil, frame)
  listBox:SetPoint("TOPLEFT", 18, -listTop)
  listBox:SetSize(WIDTH - 36, 100)
  W.Surface(listBox, "md", W.colors.card, W.colors.border)

  frame.Lines = {}
  local yOffset = 6
  for index, spec in ipairs(helpers) do
    local row = CreateFrame("Button", nil, listBox)
    row:SetPoint("TOPLEFT", 8, -yOffset)
    W.Highlight(row, "md")
    row.setSwitch, row.rail, row.knob = W.Switch(row); row.rail:SetPoint("LEFT", 6, 0)
    row.icon = W.Icon(row, "Interface\\Icons\\" .. spec.icon, 16); row.icon:SetPoint("LEFT", 48, 0)
    row.name = W.Font(row, "small"); row.name:SetPoint("LEFT", 70, 0); row.name:SetWidth(98); row.name:SetText(spec.title)
    row.name:SetTextColor(unpack(W.colors.text))
    row.text = W.Font(row, "dim"); row.text:SetPoint("LEFT", 174, 0); row.text:SetWidth(textW); row.text:SetJustifyH("LEFT")
    if row.text.SetWordWrap then row.text:SetWordWrap(true) end
    row.text:SetText(spec.description)
    local h = math.max(LINE_HEIGHT, math.ceil((tonumber(row.text.GetStringHeight and row.text:GetStringHeight()) or 0) + 12))
    row:SetSize(rowW, h)
    row.spec = spec
    row:SetScript("OnClick", function(self) ToggleHelper(self.spec) end)
    W.Tooltip(row, spec.title, function()
      local db = Helper.db[spec.key]
      local isOn = db and db.enabled == true and not (spec.key == "minimapFan" and Helper.fanStandsDown)
      return (spec.description or "") .. "\n\nClick to turn " .. (isOn and "off." or "on.")
    end, "ANCHOR_RIGHT")
    frame.Lines[index] = row
    yOffset = yOffset + h
  end
  listHeight = yOffset + 6
  listBox:SetSize(WIDTH - 36, listHeight)

  frame.WhatsNew = W.Font(frame, "small")
  frame.WhatsNew:SetPoint("TOPLEFT", listBox, "BOTTOMLEFT", 0, -10)
  frame.WhatsNew:SetWidth(WIDTH - 36)
  if frame.WhatsNew.SetWordWrap then frame.WhatsNew:SetWordWrap(true) end
  frame.WhatsNew:SetTextColor(unpack(W.colors.on))
  frame.WhatsNew:Hide()

  frame.Footer = W.Font(frame, "dim")
  frame.Footer:SetPoint("TOPLEFT", listBox, "BOTTOMLEFT", 0, -10)
  frame.Footer:SetWidth(WIDTH - 36)
  frame.Footer:SetText("Left-click the minimap button for the fan, right-click for the quick menu, Shift-click (or /rtw settings) for settings. /rtw unlock moves frames.")

  frame.DontShow = W.Checkbox(frame)
  frame.DontShow:SetPoint("BOTTOMLEFT", 18, 16)
  frame.DontShow:SetHitRectInsets(0, -245, -4, -4)
  frame.DontShow:SetScript("OnClick", function(self) Helper.db.intro.skipUpdates = self:GetChecked() == true end)
  frame.DontShowLabel = W.Font(frame, "small")
  frame.DontShowLabel:SetPoint("LEFT", frame.DontShow, "RIGHT", 8, 0)
  frame.DontShowLabel:SetText("Don't show automatically on future updates")

  frame.Close = W.Button(frame, "Got it")
  frame.Close:SetSize(82, 26); frame.Close:SetPoint("BOTTOMRIGHT", -18, 14)
  frame.Close:SetScript("OnClick", function() frame:Hide() end)
  frame.Settings = W.Button(frame, "Open settings", "primary")
  frame.Settings:SetSize(114, 26); frame.Settings:SetPoint("RIGHT", frame.Close, "LEFT", -6, 0)
  frame.Settings:SetScript("OnClick", function() frame:Hide(); Helper.OpenSettings("home") end)
  frame.Menu = W.Button(frame, "Quick menu")
  frame.Menu:SetSize(96, 26); frame.Menu:SetPoint("RIGHT", frame.Settings, "LEFT", -6, 0)
  frame.Menu:SetScript("OnClick", function() frame:Hide(); if Helper.ShowMenu then Helper.ShowMenu() end end)

  frame:Hide()
  if type(UISpecialFrames) == "table" then
    table.insert(UISpecialFrames, "ReadyToWorkIntro")   -- Escape closes it
  end
end

function Helper.ShowIntro(opts)
  if not frame then Build() end
  if Helper.db and type(Helper.db.intro) == "table" then
    Helper.db.intro.seenVersion = Helper.version
    Helper.db.intro.show = false
  end
  Layout(opts)
  SyncAll()
  frame:Show()
end

Helper.Feature(function()
  if Helper.Store and Helper.Store.OnChange then
    Helper.Store.OnChange(function()
      if frame and frame:IsShown() then SyncAll() end
    end)
  end
  local showNow, prevVersion = ShouldAutoShow()
  if showNow then
    local wasFresh = Helper.db.intro.show == true
    local pendingAfterCombat = false
    local function tryShow()
      if not ShouldAutoShow() then return end
      if InCombatLockdown() then
        pendingAfterCombat = true
        return
      end
      Helper.ShowIntro({ updated = not wasFresh, from = prevVersion })
    end
    Helper.On("PLAYER_REGEN_ENABLED", function()
      if pendingAfterCombat then
        pendingAfterCombat = false
        tryShow()
      end
    end)
    C_Timer.After(SHOW_DELAY, tryShow)
  end
  Helper.commands.intro = function() Helper.ShowIntro() end
  Helper.help[#Helper.help + 1] = "/rtw intro - what ReadyToWork does, in a few lines"
end)
