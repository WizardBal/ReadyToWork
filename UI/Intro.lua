-- ReadyToWork's introduction, changelog, and new-module notice:
--   * Fresh install: opens the full Introduction once so new users can see and toggle every helper.
--   * New module (`newModule = true` in CHANGELOG): opens a compact What's New dialog once unless skipped.
--   * All other updates: stay quiet unless "Show update notifications in chat" / General > Announce updates in chat
--     is enabled, while Settings > What's new (/rtw updates) always keeps recent release notes handy.

local _, Helper = ...
local W = Helper.Widgets

local SHOW_DELAY = 3          -- seconds after login, once the login chat has settled
local WIDTH, LINE_HEIGHT = 790, 28
local NOTICE_WIDTH = 470

local CHANGELOG = {
  {
    version = "1.59.0",
    newModule = true,
    notes = {
      "New module — Fast loot: collects all unlocked loot slots at once without the loot-window delay or flash (automatically showing the window for BoP prompts, locked slots, or full bags).",
      "New module — Mailbox: collects all gold even when your bags are full, collects attachments while respecting a free-bag-slot reserve, adds an Alts & Recent recipient menu to Send Mail, and never deletes letters or touches CoD/GM mail.",
      "Per-character settings for Sell & repair, Quick destroy, Auto-open, Spell ranks, and Talk & quests (existing characters keep their lists automatically; brand-new alts start clean).",
      "Copy settings or item lists between characters anytime from General > Character settings, a page's ... menu, or /rtw copy.",
      "Quick destroy now respects your free bag slots threshold even when manually included items are in your bags.",
      "Intro now only opens automatically for brand-new installs; recent release notes live under Settings > What's new (/rtw updates).",
    },
  },
  {
    version = "1.58.0",
    newModule = false,
    notes = {
      "Sell items (#) at vendors now sells all eligible grays and opted-in white items in one click.",
      "Quest markers now display a high-contrast remaining kill/loot count badge on nameplates, hover markers, and previews.",
      "Flight timer adds Mount Hyjal (Summit of Eternity, Tainted Foothills) and Riverglades (Farholde Keep, Rog'mar) estimates and clarifies untimed route tooltips.",
    },
  },
  {
    version = "1.57.3",
    newModule = false,
    notes = {
      "Fixed the Intro window's 'Don't show automatically on future updates' checkbox so it visually checks and saves reliably, and added a top-right close button.",
    },
  },
  {
    version = "1.57.2",
    newModule = false,
    notes = {
      "Bar profiles and Quick destroy swap buttons now dismiss their tooltip when the fan opens and anchor tooltips away from screen edges and fan tiles.",
    },
  },
  {
    version = "1.57.1",
    newModule = false,
    notes = {
      "Custom Orc Peon icon, indented parent/child switches, Bar profiles chat toggle (off by default), and a dedicated ReadyToWork keybindings category.",
    },
  },
  {
    version = "1.57.0",
    newModule = false,
    notes = {
      "Version-aware release tracking (keeping existing settings intact), quieter bar auto-update on login, and CurseForge release packaging.",
    },
  },
}

local frame, noticeFrame, listBox, listTop, listHeight

local function FindRelease(version)
  if type(version) ~= "string" then return nil end
  for _, entry in ipairs(CHANGELOG) do
    if entry.version == version then return entry end
  end
end

local function IsNewModuleUpdate(version)
  local entry = FindRelease(version)
  return entry ~= nil and entry.newModule == true
end

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

local function HasUnread()
  local intro = Helper.db and Helper.db.intro
  return type(intro) == "table" and IsNewer(Helper.version, intro.seenVersion)
end

local function MarkSeen()
  local intro = Helper.db and Helper.db.intro
  if type(intro) == "table" then
    intro.seenVersion = Helper.version
    intro.show = false
  end
end

local function ShouldAutoShow()
  local intro = Helper.db and Helper.db.intro
  if type(intro) ~= "table" then return false end
  if intro.show then return "intro", nil end
  if intro.skipUpdates then return false end
  if IsNewer(Helper.version, intro.seenVersion) and IsNewModuleUpdate(Helper.version) then
    return "update", intro.seenVersion
  end
  return false
end

Helper.Intro = {
  IsNewer = IsNewer,
  ShouldAutoShow = ShouldAutoShow,
  IsNewModuleUpdate = IsNewModuleUpdate,
  IsMajorUpdate = IsNewModuleUpdate,
  HasUnread = HasUnread,
  MarkSeen = MarkSeen,
  FindRelease = FindRelease,
  Changelog = CHANGELOG,
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

  local release = updated and Helper.version and FindRelease(Helper.version)
  local note = release and release.notes and release.notes[1] or nil
  local bottomAnchor = listBox
  local whatsNewH = 0
  if note then
    frame.WhatsNew:SetHeight(0)
    frame.WhatsNew:SetText("What's new: " .. note)
    frame.WhatsNew:Show()
    local textH = math.max(18, math.ceil(tonumber(frame.WhatsNew.GetStringHeight and frame.WhatsNew:GetStringHeight()) or 18))
    frame.WhatsNew:SetHeight(textH)
    whatsNewH = textH + 8
    bottomAnchor = frame.WhatsNew
  else
    frame.WhatsNew:Hide()
  end

  frame.Footer:ClearAllPoints()
  frame.Footer:SetPoint("TOPLEFT", bottomAnchor, "BOTTOMLEFT", 0, -10)
  frame.Footer:SetHeight(0)
  local footerH = math.max(18, math.ceil(tonumber(frame.Footer.GetStringHeight and frame.Footer:GetStringHeight()) or 18))
  frame.Footer:SetHeight(footerH)
  local height = listTop + listHeight + whatsNewH + footerH + 62
  frame:SetSize(WIDTH, height)
  local sw = UIParent and UIParent.GetWidth and UIParent:GetWidth() or 0
  local sh = UIParent and UIParent.GetHeight and UIParent:GetHeight() or 0
  if sw > 0 and sh > 0 then
    frame:SetScale(math.max(.5, math.min(1, (sw - 24) / WIDTH, (sh - 24) / height)))
  end
end

local function SyncAll()
  if frame then
    for _, row in ipairs(frame.Lines) do
      SyncRow(row)
    end
    frame.DontShow:SetChecked(Helper.db and Helper.db.general and Helper.db.general.updateChat == true)
  end
  if noticeFrame and noticeFrame.DontShow then
    noticeFrame.DontShow:SetChecked(Helper.db and Helper.db.intro and Helper.db.intro.skipUpdates == true)
  end
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

local function MakeCloseX(parent, onHide)
  local closeX = W.Button(parent, "", "ghost")
  closeX:SetSize(28, 28); closeX:SetPoint("TOPRIGHT", -14, -16)
  closeX.glyph = W.Glyph(closeX, "icon_close.png", 12, W.colors.dim)
  closeX.glyph:SetPoint("CENTER")
  closeX:SetScript("OnEnter", function(self) W.SetColor(self.glyph, unpack(W.colors.text)) end)
  closeX:SetScript("OnLeave", function(self) W.SetColor(self.glyph, unpack(W.colors.dim)) end)
  closeX:SetScript("OnClick", onHide)
  return closeX
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

  local badge = W.IconBadge(frame, W.MEDIA .. "icon_rtw.png", 24, 36)
  badge:SetPoint("TOPLEFT", 18, -16)
  frame.Title = W.Font(frame, "title")
  frame.Title:SetPoint("TOPLEFT", badge, "TOPRIGHT", 12, -1)
  frame.Title:SetText("ReadyToWork")
  frame.Subtitle = W.Font(frame, "dim")
  frame.Subtitle:SetPoint("TOPLEFT", frame.Title, "BOTTOMLEFT", 0, -4)
  frame.Subtitle:SetWidth(WIDTH - 120)
  frame.Subtitle:SetText("Toggle any helper right here, or open Settings for details.")
  W.Rule(frame, "TOPLEFT", 18, -64, WIDTH - 36)
  frame.CloseX = MakeCloseX(frame, function() frame:Hide() end)

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
  if frame.Footer.SetWordWrap then frame.Footer:SetWordWrap(true) end
  frame.Footer:SetText("Left-click the minimap button for the fan, right-click for the quick menu, Shift-click (or /rtw settings) for settings. /rtw unlock moves frames.")

  frame.DontShow = W.Checkbox(frame)
  frame.DontShow:SetPoint("BOTTOMLEFT", 18, 16)
  frame.DontShow:SetHitRectInsets(0, -245, -4, -4)
  frame.DontShow:HookScript("OnClick", function(self)
    local enabled = self:GetChecked() == true
    local function apply()
      if Helper.db and Helper.db.general then
        Helper.db.general.updateChat = enabled
      end
    end
    if Helper.Store and Helper.Store.Edit and Helper.features and Helper.features.general then
      Helper.Store.Edit("general", "Announce updates in chat", apply)
    else
      apply()
    end
  end)
  frame.DontShowLabel = W.Font(frame, "small")
  frame.DontShowLabel:SetPoint("LEFT", frame.DontShow, "RIGHT", 8, 0)
  frame.DontShowLabel:SetText("Show update notifications in chat")

  frame.Close = W.Button(frame, "Got it")
  frame.Close:SetSize(82, 26); frame.Close:SetPoint("BOTTOMRIGHT", -18, 14)
  frame.Close:SetScript("OnClick", function() frame:Hide() end)
  frame.Settings = W.Button(frame, "Open settings", "primary")
  frame.Settings:SetSize(114, 26); frame.Settings:SetPoint("RIGHT", frame.Close, "LEFT", -6, 0)
  frame.Settings:SetScript("OnClick", function() frame:Hide(); Helper.OpenSettings("home") end)
  frame.Menu = W.Button(frame, "Quick menu")
  frame.Menu:SetSize(96, 26); frame.Menu:SetPoint("RIGHT", frame.Settings, "LEFT", -6, 0)
  frame.Menu:SetScript("OnClick", function() frame:Hide(); if Helper.ShowMenu then Helper.ShowMenu() end end)

  frame:SetScript("OnHide", MarkSeen)
  frame:Hide()
  if type(UISpecialFrames) == "table" then
    table.insert(UISpecialFrames, "ReadyToWorkIntro")   -- Escape closes it
  end
end

local function BuildUpdateNotice()
  noticeFrame = CreateFrame("Frame", "ReadyToWorkUpdateNotice", UIParent)
  noticeFrame:SetSize(NOTICE_WIDTH, 220)
  noticeFrame:SetFrameStrata("DIALOG")
  noticeFrame:SetToplevel(true)
  noticeFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
  W.Shadow(noticeFrame, 16, .52)
  W.Surface(noticeFrame, "lg", W.colors.window, W.colors.borderStrong, "BACKGROUND", -2)

  local badge = W.IconBadge(noticeFrame, W.MEDIA .. "icon_rtw.png", 22, 34)
  badge:SetPoint("TOPLEFT", 16, -14)
  noticeFrame.Title = W.Font(noticeFrame, "title")
  noticeFrame.Title:SetPoint("TOPLEFT", badge, "TOPRIGHT", 10, -1)
  noticeFrame.Subtitle = W.Font(noticeFrame, "dim")
  noticeFrame.Subtitle:SetPoint("TOPLEFT", noticeFrame.Title, "BOTTOMLEFT", 0, -3)
  noticeFrame.Subtitle:SetWidth(NOTICE_WIDTH - 110)
  noticeFrame.CloseX = MakeCloseX(noticeFrame, function() noticeFrame:Hide() end)
  W.Rule(noticeFrame, "TOPLEFT", 16, -58, NOTICE_WIDTH - 32)

  noticeFrame.Card = CreateFrame("Frame", nil, noticeFrame)
  noticeFrame.Card:SetPoint("TOPLEFT", 16, -68)
  noticeFrame.Card:SetWidth(NOTICE_WIDTH - 32)
  W.Surface(noticeFrame.Card, "md", W.colors.card, W.colors.border)
  noticeFrame.Lines = {}

  noticeFrame.DontShow = W.Checkbox(noticeFrame)
  noticeFrame.DontShow:SetPoint("BOTTOMLEFT", 16, 16)
  noticeFrame.DontShow:SetHitRectInsets(0, -210, -4, -4)
  noticeFrame.DontShow:HookScript("OnClick", function(self) Helper.db.intro.skipUpdates = self:GetChecked() == true end)
  noticeFrame.DontShowLabel = W.Font(noticeFrame, "small")
  noticeFrame.DontShowLabel:SetPoint("LEFT", noticeFrame.DontShow, "RIGHT", 8, 0)
  noticeFrame.DontShowLabel:SetText("Don't pop up for new modules")

  noticeFrame.Close = W.Button(noticeFrame, "Got it")
  noticeFrame.Close:SetSize(74, 26); noticeFrame.Close:SetPoint("BOTTOMRIGHT", -16, 14)
  noticeFrame.Close:SetScript("OnClick", function() noticeFrame:Hide() end)
  noticeFrame.ViewAll = W.Button(noticeFrame, "What's new", "primary")
  noticeFrame.ViewAll:SetSize(102, 26); noticeFrame.ViewAll:SetPoint("RIGHT", noticeFrame.Close, "LEFT", -6, 0)
  noticeFrame.ViewAll:SetScript("OnClick", function()
    noticeFrame:Hide()
    if Helper.OpenSettings then Helper.OpenSettings("updates") end
  end)

  noticeFrame:SetScript("OnHide", MarkSeen)
  noticeFrame:Hide()
  if type(UISpecialFrames) == "table" then
    table.insert(UISpecialFrames, "ReadyToWorkUpdateNotice")
  end
end

local function LayoutUpdateNotice(opts)
  local from = type(opts) == "table" and opts.from or nil
  noticeFrame.Title:SetText("ReadyToWork v" .. (Helper.version or ""))
  if type(from) == "string" and from ~= "" then
    noticeFrame.Subtitle:SetText(("New module added (updated from v%s) — your settings were kept."):format(from))
  else
    noticeFrame.Subtitle:SetText("New module added — check Settings > What's new anytime.")
  end

  local release = FindRelease(Helper.version) or CHANGELOG[1]
  local notes = release and release.notes or { "Bug fixes and improvements." }
  local cardW = NOTICE_WIDTH - 32
  local cy = 10
  for i, line in ipairs(notes) do
    local fs = noticeFrame.Lines[i]
    if not fs then
      fs = W.Font(noticeFrame.Card, "small")
      fs:SetTextColor(unpack(W.colors.text))
      if fs.SetWordWrap then fs:SetWordWrap(true) end
      fs:SetJustifyH("LEFT")
      noticeFrame.Lines[i] = fs
    end
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", noticeFrame.Card, "TOPLEFT", 12, -cy)
    fs:SetWidth(cardW - 24)
    fs:SetHeight(0)
    fs:SetText("•  " .. line)
    local lh = math.max(16, math.ceil(tonumber(fs.GetStringHeight and fs:GetStringHeight()) or 16))
    fs:SetHeight(lh)
    fs:Show()
    cy = cy + lh + 6
  end
  for i = #notes + 1, #noticeFrame.Lines do
    noticeFrame.Lines[i]:Hide()
  end
  local cardH = cy + 6
  noticeFrame.Card:SetSize(cardW, cardH)
  noticeFrame:SetSize(NOTICE_WIDTH, 68 + cardH + 54)
end

function Helper.ShowIntro(opts)
  if not frame then Build() end
  MarkSeen()
  Layout(opts)
  SyncAll()
  frame:Show()
end

function Helper.ShowUpdateNotice(opts)
  if not noticeFrame then BuildUpdateNotice() end
  MarkSeen()
  LayoutUpdateNotice(opts)
  SyncAll()
  noticeFrame:Show()
end

Helper.Feature(function()
  if Helper.Store and Helper.Store.OnChange then
    Helper.Store.OnChange(function()
      if (frame and frame:IsShown()) or (noticeFrame and noticeFrame:IsShown()) then SyncAll() end
    end)
  end
  local intro = Helper.db and Helper.db.intro
  if type(intro) == "table" and IsNewer(Helper.version, intro.announcedVersion) then
    local prevAnnounced = intro.announcedVersion or intro.seenVersion
    intro.announcedVersion = Helper.version
    if Helper.db.general and Helper.db.general.updateChat == true then
      if prevAnnounced and prevAnnounced ~= "" and prevAnnounced ~= Helper.version then
        Helper.Print(("Updated to v%s — open Settings > What's new (or /rtw updates) to see what changed."):format(Helper.version))
      else
        Helper.Print(("v%s loaded — type /rtw for settings."):format(Helper.version))
      end
    end
  end
  local mode, prevVersion = ShouldAutoShow()
  if mode then
    local pendingAfterCombat = false
    local function tryShow()
      local currentMode, fromVer = ShouldAutoShow()
      if not currentMode then return end
      if InCombatLockdown() then
        pendingAfterCombat = true
        return
      end
      if currentMode == "intro" then
        Helper.ShowIntro()
      else
        Helper.ShowUpdateNotice({ from = fromVer or prevVersion })
      end
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
  Helper.commands.updates = function(rest)
    if rest == "popup" then
      Helper.ShowUpdateNotice()
    elseif Helper.OpenSettings then
      Helper.OpenSettings("updates")
    else
      Helper.ShowUpdateNotice()
    end
  end
  Helper.commands.changelog = Helper.commands.updates
  Helper.help[#Helper.help + 1] = "/rtw intro - what ReadyToWork does, in a few lines"
  Helper.help[#Helper.help + 1] = "/rtw updates - view recent ReadyToWork release notes"
end)
