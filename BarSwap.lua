-- Bar profiles on screen (the profiles themselves are in BarLayouts.lua):
--   * ReadyToWork's own small box for naming a profile (save, rename) and confirming a delete. It is not one of
--     Blizzard's shared popups, which can be blocked for the game's own use after an addon shows one.
--   * The swap button, shown only if you switch it on: click it and your profiles fan out, the ones saved in
--     the spec you are in first, then your other spec's; click one to load it, or the last tile to save your
--     bars as a new profile. Once you change the bars after loading a profile, a tile above that one puts
--     your changes into it (the profile loaded on this spec only, whichever spec it was saved in). Alt-drag moves it; right-click opens the bar profile settings. Like the destroy button's
--     fan, it folds away once the mouse has left it for 2 seconds. Each fan remembers the spec it was opened
--     in: after a spec switch it closes, and a tile can't load onto the other spec.
local _, Helper = ...

local TILE_WIDTH, TILE_HEIGHT, TILE_GAP = 204, 28, 5
local OPEN_TIME, STAGGER = 0.16, 0.025   -- how the fan spreads out (as the destroy button's)
local AWAY_SECONDS = 2                   -- the fan folds when the mouse has left it this long
local MAX_TILES = 16                     -- the rest are in the menu
local ICON = "Interface\\Icons\\INV_Misc_Book_09"
local CHECK = "|TInterface\\Buttons\\UI-CheckBox-Check:14:14|t"

local UI = {}
Helper.BarUI = UI
local Bars, settings
local box
local button, fan, tiles = nil, nil, {}
local fanOpen, openedAt, awaySince, fanSettled, fanSpec, shownTiles = false, 0, nil, true, nil, 0

local function Capital(text)
  return text:sub(1, 1):upper() .. text:sub(2)
end

-- The name box ------------------------------------------------------------------------------------------------

local function Accept()
  if not box.accept then
    box:Hide()
    return
  end
  local input=box.Input:IsShown() and box.Input:GetText() or nil
  local ok,problem
  if Helper.ApplyEditorAction then
    ok,problem=Helper.ApplyEditorAction("barProfiles",box.OK:GetText().." profile",function() return box.accept(input) end,true)
  else ok,problem=box.accept(input) end
  if ok then
    box:Hide()
    if Helper.RefreshSettings then Helper.RefreshSettings("Bar profiles") end
  else
    box.Error:SetText(problem and (Capital(problem) .. ".") or "")
  end
end

local function BuildBox()
  local W = Helper.Widgets
  if W then
    box = CreateFrame("Frame", "ReadyToWorkBarProfileBox", UIParent)
    box:SetSize(376, 144)
    box:SetFrameStrata("DIALOG")
    box:SetToplevel(true)
    Helper.MakeMovable(box, "barProfileBox", false, "TOP", "TOP", 0, -170)
    W.Shadow(box, 16, .52)
    box.bg, box.border = W.Surface(box, "lg", W.colors.window, W.colors.borderStrong)
    W.TopSheen(box, .03)
    box.Title = W.Font(box, "heading")
    box.Title:SetPoint("TOP", 0, -16)
    box.Title:SetWidth(340)
    box.Title:SetJustifyH("CENTER")
    box.Input = W.Input(box, nil, "Profile name...")
    if box.Input.searchIcon then box.Input.searchIcon:Hide() end
    box.Input:SetTextInsets(10, 24, 0, 0)
    if box.Input.hint then box.Input.hint:SetPoint("LEFT", 10, 0) end
    box.Input:SetSize(284, 28)
    box.Input:SetPoint("TOP", box.Title, "BOTTOM", 0, -12)
    box.Input:SetMaxLetters(Bars.NAME_LIMIT)
    box.Input:SetScript("OnEnterPressed", Accept)
    box.Input:SetScript("OnEscapePressed", function() box:Hide() end)
    box.Input:HookScript("OnTextChanged", function() box.Error:SetText("") end)
    box.Input.onClear = function() box.Error:SetText("") end
    box.Error = W.Font(box, "small")
    box.Error:SetTextColor(unpack(W.colors.danger))
    box.Error:SetPoint("BOTTOM", 0, 46)
    box.Error:SetWidth(340)
    box.Error:SetJustifyH("CENTER")
    box.OK = W.Button(box, "OK", "primary")
    box.OK:SetSize(124, 26)
    box.OK:SetPoint("BOTTOMRIGHT", box, "BOTTOM", -6, 14)
    box.OK.SetText = function(self, t) self.label:SetText(t) end
    box.OK.GetText = function(self) return self.label:GetText() end
    box.OK:SetScript("OnClick", Accept)
    box.Cancel = W.Button(box, CANCEL or "Cancel")
    box.Cancel:SetSize(124, 26)
    box.Cancel:SetPoint("BOTTOMLEFT", box, "BOTTOM", 6, 14)
    box.Cancel:SetScript("OnClick", function() box:Hide() end)
  else
    box = CreateFrame("Frame", "ReadyToWorkBarProfileBox", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    box:SetSize(360, 132)
    box:SetFrameStrata("DIALOG")
    box:SetToplevel(true)
    Helper.MakeMovable(box, "barProfileBox", false, "TOP", "TOP", 0, -170)
    if box.SetBackdrop then
      box:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
      box:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
    end
    box.Title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    box.Title:SetPoint("TOP", 0, -14)
    box.Title:SetWidth(330)
    box.Input = CreateFrame("EditBox", nil, box, "InputBoxTemplate")
    box.Input:SetSize(260, 20)
    box.Input:SetPoint("TOP", box.Title, "BOTTOM", 0, -10)
    box.Input:SetAutoFocus(false)
    box.Input:SetMaxLetters(Bars.NAME_LIMIT)
    box.Input:SetScript("OnEnterPressed", Accept)
    box.Input:SetScript("OnEscapePressed", function() box:Hide() end)
    box.Input:SetScript("OnTextChanged", function() box.Error:SetText("") end)
    box.Error = box:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
    box.Error:SetPoint("BOTTOM", 0, 40)
    box.Error:SetWidth(330)
    box.OK = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    box.OK:SetSize(120, 22)
    box.OK:SetPoint("BOTTOMRIGHT", box, "BOTTOM", -6, 12)
    box.OK:SetScript("OnClick", Accept)
    box.Cancel = CreateFrame("Button", nil, box, "UIPanelButtonTemplate")
    box.Cancel:SetSize(120, 22)
    box.Cancel:SetPoint("BOTTOMLEFT", box, "BOTTOM", 6, 12)
    box.Cancel:SetText(CANCEL or "Cancel")
    box.Cancel:SetScript("OnClick", function() box:Hide() end)
  end
  box:SetScript("OnHide", function() box.accept = nil box.Input:ClearFocus() end)
  box:Hide()
  if type(UISpecialFrames) == "table" then
    table.insert(UISpecialFrames, "ReadyToWorkBarProfileBox")   -- Escape closes it
  end
end

-- `default` text shows the name field (nil: a yes/no question). `accept(name)` returns true, or false and why.
local function Ask(title, okText, default, accept)
  if not box then
    BuildBox()
  end
  local W = Helper.Widgets
  box.Title:SetText(title)
  -- (a long question, as an update's, makes the box taller rather than running under its buttons)
  local height = box.Title.GetStringHeight and box.Title:GetStringHeight()
  if W and box.OK.bg then
    box:SetHeight(math.max(144, (type(height) == "number" and height or 0) + (default and 128 or 96)))
    W.Style(box.OK, okText == "Delete" and "danger" or "primary")
  else
    box:SetHeight(math.max(132, (type(height) == "number" and height or 0) + (default and 118 or 88)))
  end
  box.OK:SetText(okText)
  box.Error:SetText("")
  box.accept = accept
  box:Show()
  box:Raise()
  if default then
    box.Input:Show()
    box.Input:SetText(default)
    box.Input:SetFocus()
    box.Input:HighlightText()
  else
    box.Input:Hide()
  end
end

function UI.IsAsking()
  return box ~= nil and box:IsShown()
end

-- Save the bars of the spec you are in now (the box remembers it) as a new profile.
function UI.AskSaveNew()
  local spec = Bars.ActiveSpec()
  if not spec then
    Helper.Print("Can't tell which spec is active; nothing saved.")
    return
  end
  local own, other = Bars.Profiles(spec)
  local number = #own + #other + 1
  while Bars.Exists("Profile " .. number) do
    number = number + 1
  end
  Ask(("Save your %s action bars as a new profile, named:"):format(Bars.SpecName(spec)), "Save", "Profile " .. number,
    function(name) return Bars.SaveNew(name, spec) end)
end

-- An update that would replace buttons you can't see here, or whose bars look like another profile (a crash
-- right after a load): a big, clear question naming what it would do, never a silent refusal. Its spec and
-- profile are fixed when asked.
function UI.AskUpdate(spec, name, question)
  Ask(question, "Update", nil, function() return Bars.UpdateActive(spec, name, true) end)
end

function UI.AskRename(name)
  local current = Bars.Exists(name)
  if not current then
    Helper.Print(('There is no profile named "%s".'):format(tostring(name)))
    return
  end
  Ask(('Rename the profile "%s" to:'):format(current), "Rename", current,
    function(new) return Bars.Rename(current, new) end)
end

function UI.AskDelete(name)
  local current = Bars.Exists(name)
  if not current then
    Helper.Print(name == "" and "/rtw bars delete Name" or ('There is no profile named "%s".'):format(tostring(name)))
    return
  end
  Ask(('Delete the profile "%s"? Your bars stay as they are; only the saved profile goes.'):format(current), "Delete",
    nil, function() return Bars.Delete(current) end)
end

-- The swap button and its fan ---------------------------------------------------------------------------------

-- Tiles stack up from a button in the lower half of the screen, down from one in the upper half.
local function Direction()
  local _, y = button:GetCenter()
  local height = UIParent:GetHeight()
  if y and height and y > height / 2 then
    return -1
  end
  return 1
end

local function ShowTileTooltip(tile)
  local entry = tile.entry
  if not entry then
    return
  end
  GameTooltip:SetOwner(tile, "ANCHOR_RIGHT")
  if entry.more then
    GameTooltip:SetText("More profiles")
    GameTooltip:AddLine(("Click: show page %d of %d."):format(entry.page % entry.pages + 1, entry.pages), 1, 1, 1, true)
  elseif entry.save then
    GameTooltip:SetText("New profile")
    GameTooltip:AddLine(("Click: name and save your %s bars as they are now."):format(Bars.SpecName(fanSpec)), 1, 1, 1, true)
  elseif entry.update then
    GameTooltip:SetText(('Update "%s"'):format(entry.name))
    GameTooltip:AddLine(("Click: put the %d slot%s you changed since loading it into the profile."):format(entry.count or 0,
      entry.count == 1 and "" or "s"), 1, 1, 1, true)
    GameTooltip:AddLine("The rest of the profile stays as saved. Only the profile loaded on this spec can be updated.",
      0.6, 0.6, 0.6, true)
  else
    GameTooltip:SetText(entry.name)
    GameTooltip:AddLine(("Saved %s in %s."):format(entry.at and date("%d %b %H:%M", entry.at) or "?",
      Bars.SpecName(entry.spec)), 1, 1, 1)
    GameTooltip:AddLine(("Click: load it onto %s."):format(Bars.SpecName(fanSpec)), 0.4, 1, 0.4, true)
    if entry.spec ~= fanSpec then
      GameTooltip:AddLine("It was saved in your other spec.", 1, 0.82, 0, true)
    end
  end
  GameTooltip:Show()
end

local fanPage                         -- the fan's page when there are more profiles than tiles
local FillFan, PlaceTiles

local function TileFor(index)
  local tile = tiles[index]
  if tile then
    return tile
  end
  local W = Helper.Widgets
  tile = CreateFrame("Button", nil, fan)
  tile:SetSize(TILE_WIDTH, TILE_HEIGHT)
  tile:SetFrameStrata("DIALOG")
  if W then
    W.Shadow(tile, 8, .36)
    tile.bg, tile.border = W.Surface(tile, "md", W.colors.window, W.colors.borderStrong)
    W.Highlight(tile, "md")
    tile.Edge = tile:CreateTexture(nil, "ARTWORK")
    tile.Edge:SetPoint("TOPLEFT", 4, -5)
    tile.Edge:SetPoint("BOTTOMLEFT", 4, 5)
    tile.Edge:SetWidth(3)
    tile.Text = W.Font(tile, "body")
    tile.Text:SetPoint("LEFT", 12, 0)
    tile.Text:SetPoint("RIGHT", -8, 0)
    tile.Text:SetJustifyH("LEFT")
    tile.Text:SetWordWrap(false)
  else
    local background = tile:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0.05, 0.06, 0.1, 0.92)
    tile.Edge = tile:CreateTexture(nil, "BORDER")
    tile.Edge:SetPoint("TOPLEFT")
    tile.Edge:SetPoint("BOTTOMLEFT")
    tile.Edge:SetWidth(3)
    tile.Text = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    tile.Text:SetPoint("LEFT", 9, 0)
    tile.Text:SetPoint("RIGHT", -6, 0)
    tile.Text:SetJustifyH("LEFT")
    tile.Text:SetWordWrap(false)
    local highlight = tile:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(0.3, 0.55, 1, 0.25)
  end
  tile:RegisterForClicks("LeftButtonUp")
  tile:SetScript("OnClick", function(self)
    local entry, spec = self.entry, fanSpec
    if not entry then
      return
    end
    if entry.more then
      -- (the next page, without closing the fan)
      fanPage = entry.page % entry.pages + 1
      FillFan()
      PlaceTiles(math.huge)
      fanSettled = true
      return
    end
    UI.CloseFan()
    if entry.save then
      UI.AskSaveNew()
    elseif entry.update then
      Bars.UpdateActive(spec, entry.name)
    else
      Bars.Load(entry.key, spec)
    end
  end)
  tile:SetScript("OnEnter", ShowTileTooltip)
  tile:SetScript("OnLeave", function() GameTooltip:Hide() end)
  tiles[index] = tile
  return tile
end

FillFan = function()
  fanSpec = Bars.ActiveSpec()
  local own, other = Bars.Profiles(fanSpec)
  local entries = {}
  for _, entry in ipairs(own) do entries[#entries + 1] = entry end
  for _, entry in ipairs(other) do entries[#entries + 1] = entry end
  local updatable, count = nil, nil
  if fanSpec then
    updatable, count = Bars.Updatable(fanSpec)
  end
  if count == 0 then
    updatable = nil   -- (only changes it keeps as saved: the tooltip and the menu say why)
  end
  -- More profiles than tiles: pages, with a "More" tile (before 1.30 the extra profiles were silently left out,
  -- the loaded one among them). The fan opens on the page holding the loaded profile.
  local actions = updatable and 2 or 1
  local room = MAX_TILES - actions
  if #entries > room then
    local perPage = room - 1
    local pages = math.ceil(#entries / perPage)
    if not fanPage then
      fanPage = 1
      for index, entry in ipairs(entries) do
        if entry.active then fanPage = math.ceil(index / perPage) end
      end
    end
    fanPage = math.max(1, math.min(fanPage, pages))
    local first = (fanPage - 1) * perPage + 1
    local shown = {}
    for index = first, math.min(#entries, first + perPage - 1) do
      shown[#shown + 1] = entries[index]
    end
    entries = shown
    entries[#entries + 1] = { more = true, page = fanPage, pages = pages }
  end
  if updatable then
    entries[#entries + 1] = { update = true, name = updatable, count = count }
  end
  entries[#entries + 1] = { save = true }
  for index, entry in ipairs(entries) do
    local tile = TileFor(index)
    tile.entry = entry
    if entry.more then
      tile.Text:SetText(("|cffc0c0c0More profiles (page %d of %d)|r"):format(entry.page, entry.pages))
      tile.Edge:SetColorTexture(0.7, 0.7, 0.7, 0.9)
    elseif entry.save then
      tile.Text:SetText("|cff80c0ff+ Save as new profile|r")
      tile.Edge:SetColorTexture(0.3, 0.55, 1, 0.9)
    elseif entry.update then
      tile.Text:SetText(('|cffffd200Update "%s" with your changes|r'):format(entry.name))
      tile.Edge:SetColorTexture(1, 0.82, 0, 0.9)
    else
      local text = (entry.active and (CHECK .. " ") or "") .. entry.name
      if entry.spec ~= fanSpec then
        text = text .. "  |cff999999(" .. Bars.SpecName(entry.spec) .. ")|r"
      end
      tile.Text:SetText(text)
      if entry.spec == fanSpec then
        tile.Edge:SetColorTexture(0.25, 0.8, 0.35, 0.9)
      else
        tile.Edge:SetColorTexture(0.55, 0.55, 0.55, 0.9)
      end
    end
    tile:Show()
  end
  for index = #entries + 1, #tiles do
    tiles[index].entry = nil
    tiles[index]:Hide()
  end
  shownTiles = #entries
  fanSettled = false
end

-- Puts each tile where it belongs `elapsed` seconds into opening.
PlaceTiles = function(elapsed)
  local direction = Direction()
  local moving = false
  for index = 1, shownTiles do
    local tile = tiles[index]
    local progress = math.max(0, math.min(1, (elapsed - (index - 1) * STAGGER) / OPEN_TIME))
    if progress < 1 then
      moving = true
    end
    local eased = 1 - (1 - progress) ^ 3
    local offset = (button:GetHeight() / 2 + 6 + TILE_HEIGHT / 2 + (index - 1) * (TILE_HEIGHT + TILE_GAP)) * eased
    tile:ClearAllPoints()
    local dir=settings.direction
    if dir=="left" or dir=="right" then
      local dx=(button:GetWidth()/2+6+TILE_WIDTH/2+(index-1)*(TILE_WIDTH+TILE_GAP))*eased
      tile:SetPoint("CENTER",button,"CENTER",dir=="left" and -dx or dx,0)
    else
      tile:SetPoint("CENTER",button,"CENTER",0,(dir=="up" and 1 or dir=="down" and -1 or direction)*offset)
    end
    tile:SetAlpha(eased)
  end
  return moving
end

function UI.CloseFan()
  if not fanOpen then
    return
  end
  fanOpen = false
  fan:Hide()
  for _, tile in ipairs(tiles) do
    tile.entry = nil
    tile:Hide()
  end
end

function UI.OpenFan()
  if fanOpen or not button or not button:IsShown() then
    return
  end
  fanOpen = true
  openedAt, awaySince = GetTime(), nil
  fanPage = nil
  FillFan()
  PlaceTiles(0)
  fan:Show()
end

function UI.IsFanOpen()
  return fanOpen
end

-- Spreads the tiles out, then watches for the mouse to leave.
local function FanUpdate()
  local now = GetTime()
  if not fanSettled then
    fanSettled = not PlaceTiles(now - openedAt)
  end
  local over = button:IsMouseOver()
  for index = 1, shownTiles do
    over = over or tiles[index]:IsMouseOver()
  end
  if over then
    awaySince = nil
  else
    awaySince = awaySince or now
    if now - awaySince > AWAY_SECONDS then
      UI.CloseFan()
    end
  end
end

local function ShowButtonTooltip(self)
  local spec = Bars.ActiveSpec()
  local name = spec and Bars.ActiveName(spec)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:SetText("Bar profiles")
  if name then
    GameTooltip:AddLine(("On %s: %s"):format(Bars.SpecName(spec), name), 1, 1, 1, true)
    local _, count, held = Bars.Updatable(spec)
    if count and count > 0 then
      GameTooltip:AddLine(("You have changed %d slot%s since: the fan can update it."):format(count,
        count == 1 and "" or "s"), 1, 0.82, 0, true)
    end
    if held and held > 0 then
      GameTooltip:AddLine(("%d change%s in slots where %s keeps buttons that weren't on these bars: those stay as saved (/rtw bars update says which)."):format(
        held, held == 1 and " is" or "s are", name), 1, 0.5, 0.25, true)
    end
  elseif spec then
    GameTooltip:AddLine(("No profile loaded on %s yet."):format(Bars.SpecName(spec)), 1, 1, 1, true)
  end
  GameTooltip:AddLine("Click: choose a profile to load.", 1, 1, 1)
  GameTooltip:AddLine("Right-click: bar profile settings.", 0.6, 0.6, 0.6)
  GameTooltip:AddLine("Alt-drag: move this button.", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

local function BuildButton()
  local W = Helper.Widgets
  button = CreateFrame("Button", "ReadyToWorkBarProfilesButton", UIParent)
  button:SetFrameStrata("MEDIUM")
  button:Hide()
  if W then
    button:SetSize(40, 40)
    W.Shadow(button, 10, .42)
    button.bg, button.border = W.Surface(button, "md", W.colors.window, { .32, .62, .96, .58 })
    button.Icon = W.Icon(button, ICON, 30)
    button.Icon:SetPoint("CENTER")
    button.Name = W.Font(button, "small")
    button.Name:SetTextColor(unpack(W.colors.text))
    button.Name:SetPoint("TOP", button, "BOTTOM", 0, -5)
    button.Name:SetWidth(150)
    button.Name:SetJustifyH("CENTER")
    button.Name:SetWordWrap(false)
    W.Highlight(button, "md")
  else
    button:SetSize(36, 36)
    local border = button:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", -2, 2)
    border:SetPoint("BOTTOMRIGHT", 2, -2)
    border:SetColorTexture(0.2, 0.45, 0.9, 0.9)
    button.Icon = button:CreateTexture(nil, "ARTWORK")
    button.Icon:SetAllPoints()
    button.Icon:SetTexture(ICON)
    button.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    button.Name = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    button.Name:SetPoint("TOP", button, "BOTTOM", 0, -4)
    button.Name:SetWidth(140)
    button.Name:SetWordWrap(false)
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.18)
  end
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:SetScript("OnClick", function(_, mouse)
    if IsAltKeyDown() then
      return -- Alt is for dragging
    end
    if mouse == "RightButton" then
      UI.CloseFan()
      Helper.OpenFeatureSettings("Bar profiles")
    elseif fanOpen then
      UI.CloseFan()
    else
      UI.OpenFan()
    end
  end)
  button:SetScript("OnEnter", ShowButtonTooltip)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  Helper.MakeMovable(button, "barProfiles", true, "BOTTOMLEFT", "BOTTOMLEFT", 250, 130)

  fan = CreateFrame("Frame", nil, UIParent)
  fan:Hide()
  fan:SetScript("OnUpdate", FanUpdate)
end

-- Shows or hides the button and names the profile loaded on this spec. A fan opened in another spec closes.
function UI.Refresh()
  if not button then
    return
  end
  local show = settings.enabled and settings.button
  button:SetShown(show)
  if not show then
    UI.CloseFan()
    return
  end
  local spec = Bars.ActiveSpec()
  button.Name:SetText(spec and Bars.ActiveName(spec) or "Bar profiles")
  if fanOpen and spec ~= fanSpec then
    UI.CloseFan()
  elseif fanOpen then
    FillFan()
    PlaceTiles(GetTime() - openedAt)
  end
  if not settings.buttonHint then
    -- Said once, the first time the button appears.
    settings.buttonHint = true
    if settings.reportChat then
      Helper.Print("Click the blue book button to switch bar profiles. Right-click it for bar profile settings, Alt-drag to move it.")
    end
  end
end

function UI.ResetButton()
  if button then
    button.ResetPosition()
    Helper.Print("The bar profile swap button is back in its first place.")
  end
end

Helper.Feature(function()
  Bars, settings = Helper.BarLayouts, Helper.db.barProfiles
  if not Helper.BarTools or not Bars then
    return
  end
  BuildButton()
  Bars.onChange = function()
    UI.Refresh()
    if Helper.RefreshSettings then Helper.RefreshSettings("Bar profiles") end
  end
  Helper.On("PLAYER_ENTERING_WORLD", function(initialLogin, reloadingUI)
    if initialLogin or reloadingUI then UI.Refresh() end
  end)
  UI.Refresh()
end)
