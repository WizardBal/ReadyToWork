-- The settings window (/rtw settings, Shift-click or left-click the minimap button with the fan off).
--
-- Left: a search box, Home, and every page by group, each with its icon and an on/off dot. Home shows one
-- live status card per helper. A helper's page has a header (icon, name, one line about it, its switch and a
-- ... menu) and cards in a fixed order: Status, Behaviour, Appearance & position, Lists. Every entry comes
-- from the declarations in Core\Features.lua, so the window, the quick menu and the README use the same names
-- in the same order. Every change is an undoable settings edit (Core\Store.lua); the footer's Undo takes back
-- the newest change wherever it was made. Moving or resizing the window is not an edit.

local _, Helper = ...
local W, Options, Store = Helper.Widgets, Helper.Options, Helper.Store

local window, scroll, content, heading, subheading, enabled, sidebar, ghost, headerIcon, headerLine, scrollbar
local headerBadge, railDivider, footerBg, footerLine
local moreButton, showAllButton, searchBox, confirmBar
local current, focused, searchText = "home", false, ""
local minHeight = 540   -- raised to fit the rail when it holds more pages
local tabs, pools, used = {}, {}, {}
local WIDTH, GAP, RAIL = 620, 10, 214
local y, X, CW = 0, 0, 620          -- the layout cursor, and the current card's inner left edge and width
local drag, draw
local undoButton, revertButton, editStatus, resize, sliderEdit
local inWindowEdit, bagDrawPending = false, false
local questSampleIcons
local questionMark = "Interface\\Icons\\INV_Misc_Bag_10"
local CARD_TITLES = { status = "Status", behaviour = "Behavior", appearance = "Appearance & position", lists = "Lists" }
local CARD_ORDER = { "status", "behaviour", "appearance", "lists" }

local function Spec() return Helper.features[current] end
local rtwIcon = W.MEDIA .. "icon_rtw.png"
local function iconPath(name)
  if not name then return questionMark end
  return name:find("\\", 1, true) and name or ("Interface\\Icons\\" .. name)
end
local function columnSize(count) return math.floor((CW - (count - 1) * GAP) / count) end
local function isFeatureActive(key, db)
  return db ~= nil and db.enabled == true and not (key == "minimapFan" and Helper.fanStandsDown)
end

-- Runs `action` as an undoable edit of `owner` (this page's feature by default).
local function edit(label, action, owner, profiles)
  local key = owner or (Spec() and current) or "general"
  local oldOutput = Helper.EditorOutput
  Helper.EditorOutput = function() end
  inWindowEdit = true
  local ok, a, b = pcall(Store.Edit, key, label, action, { profiles = profiles })
  inWindowEdit = false
  Helper.EditorOutput = oldOutput
  if not ok then error(a, 0) end
  return a, b
end

local function footer()
  if not editStatus then return end
  local count, label, feature, since = Store.Count()
  undoButton:SetEnabled(count > 0); undoButton:SetAlpha(count > 0 and 1 or .42)
  W.Style(undoButton, count > 0 and "primary" or nil)
  revertButton:SetEnabled(since > 0); revertButton:SetAlpha(since > 0 and 1 or .42)
  local spec = feature and Helper.features[feature]
  editStatus:SetText(since > 0 and ("%d change%s this visit  ·  last: %s%s"):format(since, since == 1 and "" or "s", label or "?",
    spec and spec.title and (" (" .. spec.title .. ")") or "") or (count > 0 and ("Last change: " .. (label or "?")) or ""))
end

-- Pooled widgets ------------------------------------------------------------------------------------------

local function widget(kind, factory, x, offset, w, h)
  local index = (used[kind] or 0) + 1
  used[kind] = index
  local pool = pools[kind]
  if not pool then pool = {}; pools[kind] = pool end
  local part = pool[index]
  if not part then part = factory(kind); pool[index] = part end
  part:ClearAllPoints()
  part:SetPoint("TOPLEFT", content, "TOPLEFT", x, -offset)
  part:SetSize(w, h)
  part:Show()
  return part
end

local function tint(button, selected)
  if button.isRailTab then
    if selected then
      W.SetColor(button.bg, .120, .140, .175, 1)
      if button.border then W.SetColor(button.border, 1, 1, 1, .11) end
      if button.name then button.name:SetTextColor(unpack(W.colors.text)) end
    else
      W.SetColor(button.bg, 1, 1, 1, 0)
      if button.border then W.SetColor(button.border, 1, 1, 1, 0) end
      if button.name then button.name:SetTextColor(unpack(W.colors.label)) end
    end
  elseif button.choiceCard then
    if selected then
      W.SetColor(button.bg, unpack(W.colors.accentBg))
      if button.border then W.SetColor(button.border, unpack(W.colors.accentBorder)) end
    else
      W.SetColor(button.bg, unpack(W.colors.surface))
      if button.border then W.SetColor(button.border, unpack(W.colors.border)) end
    end
  else
    local fill = button.restFill or W.colors.surface
    local edge = button.restBorder or W.colors.border
    if selected then
      W.SetColor(button.bg, unpack(W.colors.accentBg))
      if button.border then W.SetColor(button.border, unpack(W.colors.accentBorder)) end
    else
      W.SetColor(button.bg, fill[1], fill[2], fill[3], fill[4] or 1)
      if button.border then W.SetColor(button.border, edge[1], edge[2], edge[3], edge[4] or 1) end
    end
  end
  if button.accent then button.accent:SetShown(selected == true) end
  button.selected = selected
end

local function button()
  local frame = CreateFrame("Button", nil, content)
  frame.bg, frame.border = W.Surface(frame, "md", W.colors.surface, W.colors.border)
  W.Highlight(frame, "md")
  frame.label = W.Font(frame, "small")
  frame.label:SetPoint("LEFT", 12, 0)
  frame.label:SetPoint("RIGHT", -10, 0)
  frame:SetScript("OnClick", function(self) if self.action then self.action() end end)
  frame:SetScript("OnEnter", function(self)
    if self.tooltip then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      self.tooltip(GameTooltip)
      GameTooltip:Show()
    end
  end)
  frame:SetScript("OnLeave", function(self) if GameTooltip:IsOwned(self) then GameTooltip:Hide() end end)
  return frame
end

local function subtitle(label)
  local part = widget("title", function()
    local row = CreateFrame("Frame", nil, content)
    row.label = W.Font(row, "small")
    row.label:SetTextColor(unpack(W.colors.label))
    row.label:SetPoint("LEFT")
    local c = W.colors.divider
    local line = W.Solid(row, "BACKGROUND", c[1], c[2], c[3], c[4] or .065)
    line:SetPoint("LEFT", row.label, "RIGHT", 12, 0); line:SetPoint("RIGHT"); line:SetHeight(1)
    return row
  end, X, y + 2, CW, 22)
  part.label:SetText(label)
  y = y + 28
end

local function note(label, style)
  local part = widget(style == "status" and "statusLine" or "note", function(kind)
    return W.Font(content, kind == "statusLine" and "body" or "dim")
  end, X, y, CW, 0)
  if part.SetWordWrap then part:SetWordWrap(true) end
  if part.SetNonSpaceWrap then part:SetNonSpaceWrap(false) end
  if part.SetJustifyV then part:SetJustifyV("TOP") end
  part:SetWidth(CW)
  part:SetHeight(0)
  part:SetText(label)
  local height = math.max(18, math.ceil((part:GetStringHeight() or 16) + 4))
  part:SetHeight(height)
  y = y + height + 6
end

-- A card: an elevated rounded panel with a header title and hairline separator.
local function CardStart(title)
  local bg = widget("card", function()
    local card = CreateFrame("Frame", nil, content)
    card:SetFrameLevel(content:GetFrameLevel())
    card:EnableMouse(false)
    card.bg, card.border = W.Surface(card, "md", W.colors.card, W.colors.border)
    W.TopSheen(card, .025)
    card.title = W.Font(card, "heading")
    card.title:SetPoint("TOPLEFT", 16, -13)
    local c = W.colors.divider
    card.divider = W.Solid(card, "BORDER", c[1], c[2], c[3], c[4] or .065)
    card.divider:SetPoint("TOPLEFT", 16, -36)
    card.divider:SetPoint("TOPRIGHT", -16, -36)
    card.divider:SetHeight(1)
    return card
  end, 0, y, WIDTH, 48)
  bg.title:SetText(title)
  local card = { bg = bg, top = y, actions = {}, headerActions = {} }
  y = y + 46
  X, CW = 16, WIDTH - 32
  return card
end

local function renderActionButtons(actions, rowY, height, rightEdge, compact)
  local right = rightEdge or (X + CW)
  for i = #actions, 1, -1 do
    local a = actions[i]
    local b = widget("action", function()
      local btn = W.Button(content, "")
      btn:SetScript("OnClick", function(self)
        if not self.run then return end
        if self.style == "danger" and not (self.confirmUntil and GetTime() <= self.confirmUntil) then
          self.confirmUntil = GetTime() + 4
          self.label:SetText("Click again: " .. self.text)
          return
        end
        self.confirmUntil = nil
        self.run()
      end)
      btn:SetScript("OnEnter", function(self)
        if not self.tip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(self.text, 1, 1, 1)
        GameTooltip:AddLine(self.tip, nil, nil, nil, true)
        if self.style == "danger" then GameTooltip:AddLine("Asks for a second click.", .8, .8, .8, true) end
        GameTooltip:Show()
      end)
      btn:SetScript("OnLeave", function(self) if GameTooltip:IsOwned(self) then GameTooltip:Hide() end end)
      return btn
    end, 0, rowY, 10, height or 26)
    b.text, b.tip, b.run, b.confirmUntil = a.label, a.tip, a.run, nil
    b.label:SetText(a.label)
    W.Style(b, a.danger and "danger" or (a.active and "primary" or nil))
    local minW = compact and 64 or 78
    local pad = compact and 20 or 28
    local width = math.max(minW, math.min(230, (b.label:GetStringWidth() or 80) + pad))
    right = right - width
    b:ClearAllPoints(); b:SetPoint("TOPLEFT", content, "TOPLEFT", right, -rowY); b:SetSize(width, height or 26)
    b:SetFrameLevel(content:GetFrameLevel() + 2)
    right = right - 8
    b:SetEnabled(a.enabled ~= false); b:SetAlpha(a.enabled == false and .42 or 1)
  end
end

-- A row of action buttons, right-aligned. A dangerous one asks for a second click.
local function actionRow(actions)
  renderActionButtons(actions, y, 26, X + CW, false)
  y = y + 32
end

local function CardFinish(card)
  if #card.headerActions > 0 then
    renderActionButtons(card.headerActions, card.top + 7, 22, WIDTH - 16, true)
  end
  if #card.actions > 0 then
    y = y + 4
    actionRow(card.actions)
  end
  y = y + 8
  card.bg:SetHeight(y - card.top)
  y = y + 12
  X, CW = 0, WIDTH
end

local function branchFactory()
  local f = CreateFrame("Frame", nil, content)
  f:EnableMouse(false)
  f.v = W.Solid(f, "ARTWORK", 1, 1, 1, .45)
  f.h = W.Solid(f, "ARTWORK", 1, 1, 1, .45)
  return f
end

local function optionFactory()
  local b = button()
  if b.SetMotionScriptsWhileDisabled then b:SetMotionScriptsWhileDisabled(true) end
  if b.label.SetWordWrap then b.label:SetWordWrap(false) end
  b.setSwitch, b.rail, b.knob, b.switchBorder = W.Switch(b)
  b.rail:SetPoint("RIGHT", -10, 0)
  b.state = W.Font(b, "micro")
  b.state:SetPoint("RIGHT", b.rail, "LEFT", -8, 0)
  b.radio = W.Glyph(b, "circle_ring.png", 15, W.colors.muted)
  b.radio:SetPoint("RIGHT", -10, 0)
  b.dot = W.Glyph(b, "circle.png", 7, W.colors.on)
  b.dot:SetPoint("CENTER", b.radio, "CENTER")
  return b
end

local function placeTile(row, tileX, tileY, tileW)
  local part = widget("option", optionFactory, tileX, tileY, tileW, 34)
  part.branch = nil
  local checked = row.check and row.check()
  local radio = row.kind == "radio"
  local toggle = row.check ~= nil and not radio
  local isDisabled = row.disabled == true
  local rightInset = toggle and -78 or (radio and (checked and -84 or -32) or -12)
  part.label:ClearAllPoints()
  part.label:SetPoint("LEFT", part, "LEFT", 12, 0)
  part.label:SetPoint("RIGHT", part, "RIGHT", rightInset, 0)
  part.label:SetText(row.label)
  part.rail:SetShown(toggle); part.knob:SetShown(toggle)
  if part.switchBorder then part.switchBorder:SetShown(toggle) end
  part.radio:SetShown(radio)
  part.dot:SetShown(radio and checked == true)
  part.state:SetShown(toggle or (radio and checked == true))
  if radio then
    W.SetColor(part.radio, unpack(checked and W.colors.on or W.colors.muted))
    part.state:ClearAllPoints()
    part.state:SetPoint("RIGHT", part.radio, "LEFT", -8, 0)
    part.state:SetText(checked and "Selected" or "")
    part.state:SetTextColor(unpack(checked and W.colors.on or W.colors.muted))
  elseif toggle then
    part.setSwitch(checked)
    part.state:ClearAllPoints()
    part.state:SetPoint("RIGHT", part.rail, "LEFT", -8, 0)
    part.state:SetText(checked and "On" or "Off")
    part.state:SetTextColor(unpack(checked and W.colors.on or W.colors.muted))
  else
    part.state:SetText("")
  end
  part.isAction = (not radio and not toggle)
  part.restFill = { .115, .124, .145, .72 }
  part.restBorder = { 1, 1, 1, .065 }
  if row.check then
    part.label:SetTextColor(unpack(isDisabled and W.colors.dim or W.colors.text))
  else
    part.label:SetTextColor(unpack(isDisabled and W.colors.dim or W.colors.link))
  end
  part:SetEnabled(not isDisabled)
  part:SetAlpha(isDisabled and .45 or 1)
  part.tooltip = row.tooltip or function(tip) tip:SetText(row.label) end
  part.action = not isDisabled and function() if row.action then row.action(); draw() end end or nil
  tint(part, radio and checked == true)
  return part
end

-- Tiles: toggles and radio choices in one, two, or more columns.
-- Consecutive `sub = true` rows stack vertically under their parent toggle with an L-shaped bend connector.
local SUB_INDENT, STEM_X, TILE_H, ROW_STEP = 22, 10, 34, 40

local function tiles(rows, columns)
  local groups = {}
  for _, row in ipairs(rows) do
    if row.sub == true and #groups > 0 then
      local g = groups[#groups]
      g.children[#g.children + 1] = row
    else
      groups[#groups + 1] = { row = row, children = {} }
    end
  end
  if not columns then columns = (#groups == 1) and 1 or 2 end
  local width = columnSize(columns)
  local bandY = y
  for bandStart = 1, #groups, columns do
    local bandHeight = ROW_STEP
    for col = 0, columns - 1 do
      local g = groups[bandStart + col]
      if g then
        local colX = X + col * (width + GAP)
        placeTile(g.row, colX, bandY, width)
        local usedH = ROW_STEP
        for ci, childRow in ipairs(g.children) do
          local childTop = bandY + ci * ROW_STEP
          local childPart = placeTile(childRow, colX + SUB_INDENT, childTop, width - SUB_INDENT)
          local stemTop = (ci == 1) and (bandY + TILE_H) or (bandY + (ci - 1) * ROW_STEP + 17)
          local stemH = (childTop + 17 + 1) - stemTop
          local branch = widget("subBranch", branchFactory, colX, stemTop, SUB_INDENT, stemH)
          branch.v:ClearAllPoints()
          branch.v:SetPoint("TOPLEFT", branch, "TOPLEFT", STEM_X, 0)
          branch.v:SetSize(2, stemH)
          branch.h:ClearAllPoints()
          branch.h:SetPoint("BOTTOMLEFT", branch, "BOTTOMLEFT", STEM_X, 0)
          branch.h:SetSize(SUB_INDENT - STEM_X, 2)
          local cr, cg, cb, ca
          if childRow.disabled == true then
            cr, cg, cb, ca = .56, .62, .70, .45
          else
            local checked = childRow.check and childRow.check()
            cr, cg, cb = W.colors.on[1], W.colors.on[2], W.colors.on[3]
            ca = checked and .60 or .42
          end
          W.SetColor(branch.v, cr, cg, cb, ca)
          W.SetColor(branch.h, cr, cg, cb, ca)
          childPart.branch = branch
          usedH = (ci + 1) * ROW_STEP
        end
        if usedH > bandHeight then bandHeight = usedH end
      end
    end
    bandY = bandY + bandHeight
  end
  y = bandY + (#groups > 0 and 4 or 0)
end

local function tipFor(label, text)
  if not text then return nil end
  return function(tip)
    tip:SetText(label, 1, 1, 1)
    tip:AddLine(text, nil, nil, nil, true)
  end
end

local function range(title, low, high, initial, change, owner, tip, isEnabled)
  local slider = widget("slider", function()
    local s = CreateFrame("Slider", nil, content)
    if s.SetMotionScriptsWhileDisabled then s:SetMotionScriptsWhileDisabled(true) end
    s:SetOrientation("HORIZONTAL")
    local rail = s:CreateTexture(nil, "BACKGROUND")
    rail:SetPoint("LEFT", 7, 0); rail:SetPoint("RIGHT", -7, 0); rail:SetHeight(6)
    W.Slice(rail, "pill_fill.png", 12, 6, 12, 6)
    W.SetColor(rail, .045, .049, .058, 1)

    local railBorder = s:CreateTexture(nil, "BORDER")
    railBorder:SetAllPoints(rail)
    W.Slice(railBorder, "pill_border.png", 12, 6, 12, 6)
    W.SetColor(railBorder, 1, 1, 1, .08)

    local thumb = s:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(W.MEDIA .. "circle.png")
    thumb:SetSize(14, 14)
    W.SetColor(thumb, .96, .98, .99, 1)
    s:SetThumbTexture(thumb)

    local fill = s:CreateTexture(nil, "ARTWORK")
    W.Slice(fill, "pill_fill.png", 12, 6, 12, 6)
    W.SetColor(fill, .16, .76, .52, 1)
    fill:SetPoint("TOPLEFT", rail, "TOPLEFT")
    fill:SetPoint("BOTTOMLEFT", rail, "BOTTOMLEFT")
    fill:SetPoint("RIGHT", thumb, "CENTER")
    s.fill = fill

    s.label = W.Font(s, "body")
    s.label:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 6)

    s.valuePill = CreateFrame("Frame", nil, s)
    s.valuePill:SetSize(44, 20)
    s.valuePill:SetPoint("BOTTOMRIGHT", s, "TOPRIGHT", 0, 4)
    s.valuePill.bg, s.valuePill.border = W.Surface(s.valuePill, "pill", W.colors.surface, W.colors.border)
    s.number = W.Font(s.valuePill, "small")
    s.number:SetPoint("CENTER")
    s.number:SetJustifyH("CENTER")
    s.number:SetTextColor(unpack(W.colors.text))

    s:SetValueStep(1); s:SetObeyStepOnDrag(true)
    s:HookScript("OnMouseDown", function(self, key)
      if key == "LeftButton" then sliderEdit = Store.Begin(self.owner, self.label:GetText()) end
    end)
    s:HookScript("OnMouseUp", function()
      if sliderEdit then Store.Finish(sliderEdit); sliderEdit = nil end
      draw()
    end)
    s:SetScript("OnEnter", function(self)
      if not self.tip then return end
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText(self.label:GetText(), 1, 1, 1)
      GameTooltip:AddLine(self.tip, nil, nil, nil, true)
      GameTooltip:Show()
    end)
    s:SetScript("OnLeave", function(self) if GameTooltip:IsOwned(self) then GameTooltip:Hide() end end)
    -- (the page is drawn again when the slider is let go: drawing it at every step rebuilt the whole page)
    s:SetScript("OnValueChanged", function(self, value)
      value = math.floor(value + .5)
      self.number:SetText(tostring(value))
      if not self.change or value == self.lastValue then return end
      self.lastValue = value
      if sliderEdit then
        local oldOutput = Helper.EditorOutput
        Helper.EditorOutput = function() end
        local ok, problem = pcall(self.change, value)
        Helper.EditorOutput = oldOutput
        if not ok then error(problem, 0) end
      else
        edit(self.label:GetText(), function() self.change(value) end, self.owner)
      end
    end)
    return s
  end, X, y + 26, CW, 22)
  slider.change = nil
  slider.owner = owner or current
  slider.tip = tip or Helper.Tip(title)
  slider:SetMinMaxValues(low, high)
  slider:SetValue(initial)
  slider.lastValue = math.floor((initial or low) + .5)
  slider.label:SetText(title); slider.number:SetText(tostring(slider.lastValue))
  local active = isEnabled ~= false
  slider:SetEnabled(active)
  slider:SetAlpha(active and 1 or .42)
  slider.change = change
  y = y + 58
end

-- The settings window's stand-in for a menu description, so a `build` option (made for the quick menu) can
-- show its entries here as tiles.
local Node = {}
Node.__index = Node
local function node(label, action, check, kind)
  return setmetatable({ label = label, action = action, check = check, kind = kind }, Node)
end
function Node:add(child) self[#self + 1] = child; return child end
function Node:CreateButton(label, action) return self:add(node(label, action)) end
function Node:CreateCheckbox(label, check, action) return self:add(node(label, action, check, "check")) end
function Node:CreateRadio(label, check, action) return self:add(node(label, action, check, "radio")) end
function Node:CreateTitle(label) return self:add(node(label, nil, nil, "title")) end
function Node:CreateDivider() end
function Node:SetTooltip(callback) self.tooltip = callback end
function Node:AddInitializer() end

local function inline(root, owner)
  local pending = {}
  local function flush()
    if #pending > 0 then tiles(pending); pending = {} end
  end
  for _, row in ipairs(root) do
    local action = row.action
    if action then
      row.action = function() edit(row.label, action, owner) end
    end
    if row.kind == "title" then flush(); subtitle(row.label)
    elseif #row > 0 then flush(); subtitle(row.label); inline(row, owner)
    elseif not action then flush(); note(row.label)
    else pending[#pending + 1] = row end
  end
  flush()
end

-- Custom editors ------------------------------------------------------------------------------------------

local editors = {}

local directionAxes = { left = { -1, 0 }, up = { 0, 1 }, down = { 0, -1 }, right = { 1, 0 } }
local directionLabels = { auto = "Auto", left = "Left", right = "Right", up = "Up", down = "Down" }
local function directionEditor(spec, option, ctx)
  subtitle(option.label)
  local width = columnSize(5)
  for i, key in ipairs({ "left", "up", "auto", "down", "right" }) do
    local part = widget("direction", function()
      local control = button()
      control.label:ClearAllPoints(); control.label:SetPoint("BOTTOM", 0, 7)
      control.label:SetJustifyH("CENTER")
      control.origin = W.Glyph(control, "circle.png", 8, { .96, .78, .44, 1 })
      control.steps = {}
      for n = 1, 4 do
        control.steps[n] = W.Glyph(control, "circle.png", 5, { .65, .86, .92, .9 })
      end
      control.choiceCard = true
      return control
    end, X + (i - 1) * (width + GAP), y, width, 60)
    local axis = directionAxes[key]
    local dx, dy = axis and axis[1] or 0, axis and axis[2] or 0
    part.origin:ClearAllPoints(); part.origin:SetPoint("CENTER", part, "CENTER", -dx * 8, 8 - dy * 8)
    for n, dot in ipairs(part.steps) do
      dot:ClearAllPoints()
      if axis then dot:SetPoint("CENTER", part.origin, "CENTER", dx * n * 6, dy * n * 6); dot:SetShown(n <= 3)
      else
        local ray = directionAxes[({ "left", "up", "down", "right" })[n]]
        dot:SetPoint("CENTER", part.origin, "CENTER", ray[1] * 7, ray[2] * 7); dot:Show()
      end
    end
    part.label:SetText(directionLabels[key]); tint(part, (Options.Get(spec, option, ctx) or "auto") == key)
    part.tooltip = tipFor(option.label, option.tip)
    part.action = function()
      edit(option.label, function() Options.Set(spec, option, key, ctx) end, Options.Owner(spec, option)); draw()
    end
  end
  y = y + 68
end

-- Minimap fan: layout cards, icons per page, and the button order canvas.
local sampleIcons = { "INV_Misc_Map_01", "INV_Misc_Spyglass_03", "INV_Sword_04", "INV_Misc_Book_09", "INV_Misc_Gem_Sapphire_02", "INV_Misc_Bag_10" }
local styles = { { "fan", "Fan" }, { "grid", "Grid" }, { "line", "Line" } }
local orderCanvas, drawnView, drawnPage, drawnRevision, refreshFaces
local launcherTexture = rtwIcon

local function stopDrag()
  if drag and drag.target then drag.target.dropBorder:Hide() end
  drag = nil
  if ghost then ghost:Hide() end
end

local function dragTarget()
  if not orderCanvas or not scroll:IsMouseOver() then return end
  for _, control in ipairs(orderCanvas.dots) do
    if control:IsShown() and control.entry and control:IsMouseOver() then return control end
  end
  for _, control in ipairs(orderCanvas.pages) do
    if control:IsShown() and control.targetKey and control:IsMouseOver() then return control end
  end
end

local function cardFactory()
  local card = button()
  card.label:ClearAllPoints(); card.label:SetPoint("BOTTOM", 0, 8)
  card.label:SetJustifyH("CENTER")
  card.choiceCard = true
  card.dots = {}
  card.origin = CreateFrame("Frame", nil, card)
  return card
end

local function orderIcon(canvas)
  local b = CreateFrame("Button", nil, canvas)
  b:SetHighlightTexture("Interface\\Buttons\\UI-ActionButton-Border", "ADD")
  W.DropBorder(b)
  b:RegisterForDrag("LeftButton")
  b:SetScript("OnEnter", function(self)
    if drag or not self.entry then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(self.entry.label)
    GameTooltip:AddLine("Slot " .. self.index, .8, .85, .88)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function(self) if GameTooltip:IsOwned(self) then GameTooltip:Hide() end end)
  b:SetScript("OnDragStart", function(self)
    if not self.entry then return end
    if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    drag = { key = self.entry.key, source = self }
    Helper.FanArt.Draw(ghost.icon, self.entry.art, self.entry.icon, self.entry.label)
    ghost.label:SetText(self.entry.label); ghost:Show()
  end)
  b:SetScript("OnDragStop", function()
    if not drag then return end
    local key, target = drag.key, dragTarget()
    stopDrag()
    local to = target and (target.targetKey or target.entry.key)
    if to and key ~= to then
      edit("Button order", function() Helper.PlaceFanButton(key, to) end, "minimapFan")
      if target and target.page then Helper.SetFanPage(target.page) end
    end
    draw()
  end)
  return b
end

local function canvasFactory()
  local canvas = cardFactory()
  canvas:EnableMouse(false)
  canvas.choiceCard = false
  canvas.restFill = { .068, .074, .088, 1 }
  canvas.restBorder = W.colors.border
  tint(canvas, false)
  canvas.pages = {}
  for i, label in ipairs({ "Previous", "Next" }) do
    local b = W.Button(canvas, label)
    b:SetSize(74, 24)
    if i == 1 then b:SetPoint("BOTTOMLEFT", 8, 5) else b:SetPoint("BOTTOMRIGHT", -8, 5) end
    W.DropBorder(b)
    b:SetScript("OnClick", function(self)
      if self.targetKey then Helper.SetFanPage(self.page); draw() end
    end)
    canvas.pages[i] = b
  end
  return canvas
end

-- Include the bag in the bounds even when the live layout had to slide its slots away from a screen edge.
-- Both axes use the same drawing scale.
local function diagram(view, style, count)
  local pts, ox, oy, l, r, b, t = Helper.FanLayout.LayoutInView(count, view, style)
  local hx, hy = view.x - ox, view.y - oy
  return { points = pts, x = hx, y = hy, left = math.min(l, hx - 16), right = math.max(r, hx + 16),
    bottom = math.min(b, hy - 16), top = math.max(t, hy + 16) }
end

local function plot(card, layout, entries, first)
  local count = layout and #layout.points or 0
  for i = count + 1, #card.dots do card.dots[i].entry = nil; card.dots[i]:Hide() end
  card.origin:SetShown(layout ~= nil)
  if not layout then return end
  local width, height = card:GetWidth(), card:GetHeight()
  local scale = math.min(1, (width - 20) / (layout.right - layout.left), (height - 38) / (layout.top - layout.bottom))
  local cx = (width - (layout.left + layout.right) * scale) / 2
  local cy = (height + 20 - (layout.bottom + layout.top) * scale) / 2
  local function placeIcon(frame, x, y2)
    frame:SetSize(32 * scale, 32 * scale)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", card, "BOTTOMLEFT", cx + x * scale, cy + y2 * scale)
  end
  placeIcon(card.origin, layout.x, layout.y)
  for i, pt in ipairs(layout.points) do
    local dotIcon = card.dots[i]
    if not dotIcon then
      dotIcon = card.pages and orderIcon(card) or CreateFrame("Frame", nil, card)
      card.dots[i] = dotIcon
    end
    dotIcon.index = first + i - 1
    dotIcon.entry = entries[dotIcon.index]
    if card.pages then dotIcon:EnableMouse(dotIcon.entry ~= nil) end
    placeIcon(dotIcon, pt[1], pt[2]); dotIcon:Show()
  end
end

editors.fanEditor = function(spec)
  local db = Helper.db.minimapFan
  local entries = Helper.FanButtons(true)
  local view, requested, revision, launcher = Helper.FanView()
  drawnView, drawnPage, drawnRevision = view, requested, revision
  local page, pages, first, count = Helper.FanLayout.PageRange(#entries, db.pageSize, requested)
  local examples = count == 0 and math.min(db.pageSize, #sampleIcons) or count
  local width = columnSize(3)
  local layouts, cards = {}, {}
  subtitle("Fan layout")
  for i, choice in ipairs(styles) do
    local style = choice[1]
    layouts[style] = view and diagram(view, style, examples)
    local card = widget("style", cardFactory, X + (i - 1) * (width + GAP), y, width, 90)
    card.label:SetText(choice[2]); tint(card, style == db.style)
    plot(card, layouts[style], entries, first)
    card.tooltip = tipFor(choice[2], "Open the fan in a " .. choice[2]:lower() .. ".")
    card.action = function() edit("Fan layout", function() db.style = style; Helper.RefreshFan() end, "minimapFan"); draw() end
    cards[i] = card
  end
  y = y + 102
  range("Icons per page", 1, 24, db.pageSize, function(value)
    db.pageSize = value; Helper.RefreshFan()
  end, "minimapFan", "How many buttons the fan shows at once. More buttons go on further pages.")
  subtitle("Button order")
  if view and count > 0 then
    note(pages > 1 and "Drag onto an icon to reorder, or onto Previous or Next to move between pages."
      or "Drag an icon onto another to move it to that slot.")
  end
  local layout = layouts[db.style] or layouts.fan
  local height = 140
  if layout then
    -- Long vertical layouts can scroll with the page. Keep their drag targets usable.
    local scale = math.min(1, (CW - 20) / (layout.right - layout.left))
    height = math.max(height, math.ceil((layout.top - layout.bottom) * scale) + 38)
  end
  local canvas = widget("preview", canvasFactory, X, y, CW, height)
  orderCanvas = canvas
  plot(canvas, layout, entries, first)
  local caption
  if Helper.fanStandsDown then caption = "The separate MinimapFan addon is using the fan"
  elseif not view then caption = "Waiting for the minimap button"
  elseif count == 0 then caption = "Sample icons · No buttons collected"
  elseif pages > 1 then caption = ("Page %d of %d  ·  Slots %d–%d of %d"):format(page, pages, first, first + count - 1, #entries)
  else caption = ("%d %s"):format(count, count == 1 and "button" or "buttons") end
  canvas.label:SetText(caption)
  for i, b in ipairs(canvas.pages) do
    local dest = i == 1 and entries[first - 1] or nil
    if i == 2 then dest = entries[first + count] end
    b.page = page + (i == 1 and -1 or 1)
    b.targetKey = dest and dest.key
    b:SetEnabled(dest ~= nil); b:SetAlpha(dest and 1 or .42); b:SetShown(view ~= nil and pages > 1)
  end
  cards[#cards + 1] = canvas
  local bagArt
  refreshFaces = function(force)
    if not view then return end
    local current2 = Helper.FanArt.Capture(launcher)
    if force or not Helper.FanArt.Same(bagArt, current2) then
      bagArt = current2
      for _, card in ipairs(cards) do Helper.FanArt.Draw(card.origin, bagArt, launcherTexture) end
    end
    for i = 1, examples do
      local entry = entries[first + i - 1]
      local art = entry and Helper.FanArt.Capture(entry.button)
      if force or (entry and not Helper.FanArt.Same(entry.art, art)) then
        if entry then entry.art = art end
        for _, card in ipairs(cards) do
          if entry then Helper.FanArt.Draw(card.dots[i], art, entry.icon, entry.label)
          else Helper.FanArt.Draw(card.dots[i], nil, "Interface\\Icons\\" .. sampleIcons[i]) end
        end
      end
    end
  end
  refreshFaces(true)
  y = y + height + 8
end

-- Every button the fan found: ticked ones go in the fan, unticked ones stay on the minimap.
editors.fanButtons = function(_, option)
  subtitle(option.label)
  local list = Helper.FanEntries and Helper.FanEntries() or {}
  if #list == 0 then note("No minimap buttons found yet.") return end
  local rows = {}
  for _, entry in ipairs(list) do
    local key, ignored = entry.key, entry.ignored
    rows[#rows + 1] = { label = entry.label, kind = "check", check = function() return not ignored end,
      tooltip = tipFor(entry.label, ignored and "On the minimap. Tick it to put it in the fan." or ("In the fan (" .. key .. "). Untick it to leave it on the minimap.")),
      action = function() edit(entry.label, function() Helper.SetFanIgnored(key, not ignored) end, "minimapFan") end }
  end
  tiles(rows)
end

local bagPickerOpen = false
editors.vendorItems = function(_, option)
  local db = Helper.db.vendor
  subtitle(option.label)
  local drop = widget("drop", function()
    local zone = button()
    zone.restFill = { .068, .074, .088, 1 }
    zone.restBorder = W.colors.accentBorder
    local badge = W.IconBadge(zone, "Interface\\Icons\\INV_Misc_Bag_10", 26, 38)
    badge:SetPoint("LEFT", 12, 0)
    zone.label:ClearAllPoints(); zone.label:SetPoint("LEFT", 60, 8)
    zone.label:SetTextColor(unpack(W.colors.text))
    zone.label:SetText("Drop an item here")
    local hint = W.Font(zone, "dim"); hint:SetPoint("LEFT", 60, -9)
    hint:SetText("Drag a saleable white item from your bags to remember it.")
    zone:SetScript("OnReceiveDrag", function() Helper.Vendor.DropBagItem() end)
    zone:SetScript("OnClick", function() if GetCursorInfo() == "item" then Helper.Vendor.DropBagItem() end end)
    return zone
  end, X, y, CW, 60)
  tint(drop, false)
  y = y + 68
  local items = {}
  for id, name in pairs(db.included) do
    local label = Helper.Vendor.Label and Helper.Vendor.Label(id) or (type(name) == "string" and name or ("Item #" .. id))
    items[#items + 1] = { id = id, name = label, sort = label:match("|h%[(.-)%]|h") or label }
  end
  table.sort(items, function(a, b) if a.sort ~= b.sort then return a.sort < b.sort end return a.id < b.id end)
  local listHeader = widget("vendorListHeader", function()
    local bar = CreateFrame("Frame", nil, content)
    bar.title = W.Font(bar, "body"); bar.title:SetPoint("LEFT")
    bar.pick = W.Button(bar, ""); bar.pick:SetSize(142, 26); bar.pick:SetPoint("RIGHT")
    bar.pick:SetScript("OnClick", function() bagPickerOpen = not bagPickerOpen; draw() end)
    return bar
  end, X, y, CW, 28)
  listHeader.title:SetText(("Remembered items (%d)"):format(#items))
  listHeader.pick.label:SetText(bagPickerOpen and "Hide bag choices" or "Choose from bags...")
  y = y + 34
  for _, item in ipairs(items) do
    local row = widget("vendorItem", function()
      local part = CreateFrame("Frame", nil, content)
      local c = W.colors.divider
      local line = W.Solid(part, "BACKGROUND", c[1], c[2], c[3], c[4] or .065)
      line:SetPoint("BOTTOMLEFT"); line:SetPoint("BOTTOMRIGHT"); line:SetHeight(1)
      part.icon = W.Icon(part, questionMark, 22); part.icon:SetPoint("LEFT", 4, 0)
      part.name = W.Font(part, "body"); part.name:SetPoint("LEFT", 36, 0); part.name:SetPoint("RIGHT", -84, 0)
      part.remove = W.Button(part, "Remove"); part.remove:SetSize(74, 26); part.remove:SetPoint("RIGHT")
      return part
    end, X, y, CW, 36)
    row.icon:SetTexture((C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(item.id)) or questionMark)
    row.name:SetText(item.name)
    row.remove:SetScript("OnClick", function() edit("Remove vendor item", function() Helper.Vendor.SetIncluded(item.id, nil) end, "vendor"); draw() end)
    y = y + 36
  end
  if #items == 0 then note("No white items chosen for automatic sale.") end
  if bagPickerOpen then
    local choices = {}
    for id, link in pairs(Helper.Vendor.WhiteItems()) do
      if not db.included[id] then
        choices[#choices + 1] = node(link, function() edit("Add vendor item", function() Helper.Vendor.SetIncluded(id, link) end, "vendor") end)
      end
    end
    table.sort(choices, function(a, b)
      return (a.label:match("|h%[(.-)%]|h") or a.label) < (b.label:match("|h%[(.-)%]|h") or b.label)
    end)
    if #choices == 0 then note("No other saleable white items in your bags.") else tiles(choices) end
  end
end

editors.protection = function(_, option)
  local db = Helper.db.destroy
  subtitle(option.label)
  local list = db.keep or {}
  local item = Helper.Destroy.CurrentItem and Helper.Destroy.CurrentItem()
  local zone = widget("protectDrop", function()
    local b = button()
    b.restFill = { .068, .074, .088, 1 }
    b.restBorder = W.colors.accentBorder
    b:SetScript("OnReceiveDrag", function()
      local id, link = Helper.CursorBagItem()
      if not id then return end
      ClearCursor()
      edit("Protect item", function() Helper.Destroy.Keep(id, link) end, "destroy")
      draw()
    end)
    b:SetScript("OnClick", function(self)
      if GetCursorInfo and GetCursorInfo() == "item" then self:GetScript("OnReceiveDrag")(self) end
    end)
    b.label:SetTextColor(unpack(W.colors.text))
    b.label:SetText("Drag a bag item here to protect it")
    return b
  end, X, y, CW, 36)
  tint(zone, false); y = y + 42
  if item and item.itemID then
    tiles({ node("Protect " .. (item.link or ("item #" .. item.itemID)), function()
      edit("Protect item", function() Helper.Destroy.Keep(item.itemID, item.link) end, "destroy")
    end) }, 1)
  end
  local entries = {}
  for id, value in pairs(list) do
    local name = type(value) == "string" and value or C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
    entries[#entries + 1] = { id = id, name = name or ("Item #" .. id) }
  end
  table.sort(entries, function(a, b) return a.name < b.name end)
  if #entries == 0 then note("No protected items.") end
  for _, entry in ipairs(entries) do
    local row = widget("keptItem", function()
      local f = CreateFrame("Frame", nil, content)
      local c = W.colors.divider
      local line = W.Solid(f, "BACKGROUND", c[1], c[2], c[3], c[4] or .065)
      line:SetPoint("BOTTOMLEFT"); line:SetPoint("BOTTOMRIGHT"); line:SetHeight(1)
      f.art = W.Icon(f, questionMark, 22); f.art:SetPoint("LEFT", 4, 0)
      f.name = W.Font(f, "body"); f.name:SetPoint("LEFT", f.art, "RIGHT", 10, 0); f.name:SetPoint("RIGHT", -150, 0)
      f.remove = W.Button(f, "Remove protection"); f.remove:SetSize(136, 26); f.remove:SetPoint("RIGHT")
      return f
    end, X, y, CW, 36)
    row.name:SetText(entry.name)
    row.art:SetTexture(C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(entry.id) or questionMark)
    row.remove:SetScript("OnClick", function()
      edit("Remove protection", function() db.keep[entry.id] = nil; Helper.Destroy.Refresh() end, "destroy")
      draw()
    end)
    y = y + 36
  end
  y = y + 4
  note("Protected items stay in your bags. Removing protection lets eligible items appear again.")
end

editors.profiles = function(_, option, ctx)
  local bars, ui = Helper.BarLayouts, Helper.BarUI
  local spec = ctx.spec
  subtitle(option.label)
  if not spec then note("Can't tell which spec is active."); return end
  local own, other = bars.Profiles(spec)
  if #own + #other == 0 then note("Save your current bars to create a profile."); return end
  for _, group in ipairs({ own, other }) do
    for _, entry in ipairs(group) do
      local part = widget("profile", function()
        local row = CreateFrame("Frame", nil, content)
        local c = W.colors.divider
        local line = W.Solid(row, "BACKGROUND", c[1], c[2], c[3], c[4] or .065)
        line:SetPoint("BOTTOMLEFT"); line:SetPoint("BOTTOMRIGHT"); line:SetHeight(1)
        row.check = W.Glyph(row, "icon_check.png", 15, W.colors.on)
        row.check:SetPoint("LEFT", 4, 0)
        row.label = W.Font(row, "body"); row.label:SetPoint("LEFT", 26, 0)
        row.label:SetPoint("RIGHT", row, "RIGHT", -190, 0); row.label:SetWordWrap(false)
        row.actions = {}
        for i, title in ipairs({ "Load", "Rename", "Delete" }) do
          local btn = W.Button(row, title, i == 3 and "danger" or nil)
          btn:SetSize(58, 26); btn:SetPoint("RIGHT", -2 - (3 - i) * 62, 0)
          row.actions[i] = btn
        end
        return row
      end, X, y, CW, 40)
      local name = entry.name
      part.check:SetShown(entry.active == true)
      if entry.spec ~= spec then name = name .. "  (" .. bars.SpecName(entry.spec) .. ")" end
      part.label:SetText(name)
      part.label:SetTextColor(unpack(entry.active and W.colors.text or W.colors.label))
      part.actions[1]:SetScript("OnClick", function() bars.Load(entry.key, spec); draw() end)
      part.actions[2]:SetScript("OnClick", function() ui.AskRename(entry.name) end)
      part.actions[3]:SetScript("OnClick", function() ui.AskDelete(entry.name) end)
      y = y + 40
    end
  end
end

local function markerExample()
  local panel = CreateFrame("Frame", nil, content)
  panel.bg, panel.border = W.Surface(panel, "md", { .068, .074, .088, 1 }, W.colors.border)
  panel.bar = panel:CreateTexture(nil, "ARTWORK")
  W.Slice(panel.bar, "pill_fill.png", 12, 6, 12, 6)
  W.SetColor(panel.bar, .58, .18, .20, 1)
  panel.bar:SetSize(128, 18); panel.bar:SetPoint("CENTER", 0, -12)
  panel.name = W.Font(panel, "small"); panel.name:SetPoint("CENTER", panel.bar)
  panel.name:SetTextColor(1, 1, 1, 1)
  panel.icon = panel:CreateTexture(nil, "ARTWORK")
  if Helper.QuestMarkers and Helper.QuestMarkers.attachBadge then
    Helper.QuestMarkers.attachBadge(panel, panel.icon)
  end
  return panel
end

editors.questSamples = function()
  local db = Helper.db.questKills
  questSampleIcons = {}
  local width = columnSize(2)
  for i, kind in ipairs({ "kill", "loot" }) do
    local panel = widget("markerSample", markerExample, X + (i - 1) * (width + GAP), y, width, 92)
    panel.name:SetText(kind == "kill" and "Kill objective" or "Loot source")
    local art = questionMark
    for _, candidate in ipairs(Helper.QuestMarkers and Helper.QuestMarkers.icons or {}) do
      if candidate.key == db[kind .. "Icon"] then art = candidate.texture; break end
    end
    panel.icon:SetTexture(art)
    panel.icon:ClearAllPoints()
    if db.placement == "above" then panel.icon:SetPoint("BOTTOM", panel.bar, "TOP", 0, 3)
    elseif db.placement == "right" then panel.icon:SetPoint("LEFT", panel.bar, "RIGHT", 5, 0)
    else panel.icon:SetPoint("RIGHT", panel.bar, "LEFT", -5, 0) end
    local size = db.size or 22
    panel.icon:SetSize(size, size)
    local sampleCount = i == 1 and 4 or 2
    if Helper.QuestMarkers and Helper.QuestMarkers.updateBadge then
      if not panel.countBg and Helper.QuestMarkers.attachBadge then
        Helper.QuestMarkers.attachBadge(panel, panel.icon)
      end
      Helper.QuestMarkers.updateBadge(panel, sampleCount, size, db.showCount ~= false)
    end
    questSampleIcons[i] = { icon = panel.icon, panel = panel, sampleCount = sampleCount }
  end
  y = y + 100
end

-- Options --------------------------------------------------------------------------------------------------

-- Draws the options of `spec` that belong on `cardName` (or all of `list`, for search results). Actions are
-- collected into the card's action row.
local function optionTip(label, option, isDisabled)
  local req = isDisabled and option.requires and ("Requires %s."):format(option.requires) or nil
  if not option.tip and not req then return nil end
  return function(tip)
    tip:SetText(label, 1, 1, 1)
    if option.tip then tip:AddLine(option.tip, nil, nil, nil, true) end
    if req then tip:AddLine(req, .75, .75, .75, true) end
  end
end

local function renderOptions(spec, list, ctx, card, cardName)
  local pending = {}
  local function flush()
    if #pending > 0 then tiles(pending); pending = {} end
  end
  for _, option in ipairs(list) do
    if (not cardName or Options.Card(option) == cardName) and Options.Shown(spec, option, ctx) then
      local owner = Options.Owner(spec, option)
      local label = Options.Label(spec, option, ctx)
      local kind = option.type
      if kind == "toggle" then
        local disabled = not Options.Enabled(spec, option, ctx)
        pending[#pending + 1] = { label = label, kind = "check", sub = option.sub == true, disabled = disabled,
          tooltip = optionTip(label, option, disabled),
          check = function() return Options.Get(spec, option, ctx) == true end,
          action = function() edit(label, function() Options.Set(spec, option, Options.Get(spec, option, ctx) ~= true, ctx) end, owner) end }
      else
        flush()
        if kind == "choice" and option.style == "direction" then
          directionEditor(spec, option, ctx)
        elseif kind == "choice" then
          subtitle(label)
          local disabled = not Options.Enabled(spec, option, ctx)
          local rows = {}
          for _, choice in ipairs(Options.Choices(spec, option, ctx)) do
            local value = choice[1]
            rows[#rows + 1] = { label = choice[2], kind = "radio", disabled = disabled, tooltip = optionTip(label, option, disabled),
              check = function() return Options.Get(spec, option, ctx) == value end,
              action = function() edit(label, function() Options.Set(spec, option, value, ctx) end, owner) end }
          end
          tiles(rows, #rows >= 3 and #rows ~= 4 and 3 or 2)
        elseif kind == "slider" then
          local value = tonumber(Options.Get(spec, option, ctx)) or option.min
          local isEnabled = Options.Enabled(spec, option, ctx)
          local tip = option.tip or Helper.Tip(label)
          if not isEnabled and option.requires then
            local req = ("Requires %s."):format(option.requires)
            tip = tip and (tip .. " " .. req) or req
          end
          range(label, option.min, option.max, value, function(n)
            Options.Set(spec, option, n, ctx)
            if spec.key == "questKills" and option.key == "size" and questSampleIcons then
              local showCount = Helper.db.questKills.showCount ~= false
              for _, sample in ipairs(questSampleIcons) do
                sample.icon:SetSize(n, n)
                if Helper.QuestMarkers and Helper.QuestMarkers.updateBadge and sample.panel then
                  Helper.QuestMarkers.updateBadge(sample.panel, sample.sampleCount, n, showCount)
                end
              end
            end
          end, owner, tip, isEnabled)
        elseif kind == "action" then
          local bucket = option.header and card.headerActions or card.actions
          bucket[#bucket + 1] = { label = label, tip = option.tip, danger = option.danger,
            enabled = Options.Enabled(spec, option, ctx),
            run = function() edit(label, function() Options.Run(spec, option, ctx) end, owner); draw() end }
        elseif kind == "build" then
          local root = node()
          root.settingsWindow = true
          option.build(root, Options.DB(spec, option), Options.Command(spec, option), ctx, Options.Kit())
          inline(root, owner)
        elseif kind == "custom" then
          if editors[option.render] then editors[option.render](spec, option, ctx) end
        elseif kind == "note" then
          note(option.text)
        end
      end
    end
  end
  flush()
end

local function hasCard(spec, ctx, cardName)
  for _, option in ipairs(spec.options) do
    if Options.Card(option) == cardName and Options.Shown(spec, option, ctx) then return true end
  end
  return cardName == "appearance" and spec.frames ~= nil
end

local CHIP_TONES = {
  accent = W.colors.on,
  warn = { .96, .76, .34, 1 },
  dim = W.colors.dim,
}

local function statChips(spec, db, ctx)
  local ok, raw = pcall(spec.statusChips, db, ctx)
  if not ok or type(raw) ~= "table" then return end
  local chips = raw.chips or raw
  local noteText = raw.note
  if #chips > 0 then
    local pills = {}
    local gap = 8
    local equalW = #chips <= 4 and math.floor((CW - (#chips - 1) * gap) / #chips) or nil
    local equalFits = equalW ~= nil
    for i, entry in ipairs(chips) do
      local pill = widget("statChip", function()
        local frame = CreateFrame("Frame", nil, content)
        frame:EnableMouse(false)
        frame.bg, frame.border = W.Surface(frame, "md", { .064, .070, .084, 1 }, W.colors.border)
        frame.k = W.Font(frame, "micro")
        frame.k:SetPoint("TOPLEFT", 12, -7)
        frame.k:SetPoint("RIGHT", -10, 0)
        if frame.k.SetWordWrap then frame.k:SetWordWrap(false) end
        frame.k:SetTextColor(unpack(W.colors.dim))
        frame.v = W.Font(frame, "body")
        frame.v:SetPoint("TOPLEFT", 12, -21)
        frame.v:SetPoint("RIGHT", -10, 0)
        if frame.v.SetWordWrap then frame.v:SetWordWrap(false) end
        return frame
      end, X, y, 120, 44)
      local kText = tostring(entry.label or "")
      local vText = tostring(entry.value or "")
      pill.k:SetText(kText)
      pill.v:SetText(vText)
      pill.v:SetTextColor(unpack(CHIP_TONES[entry.tone] or W.colors.text))
      local kW = pill.k.GetStringWidth and pill.k:GetStringWidth() or (#kText * 6)
      local vW = pill.v.GetStringWidth and pill.v:GetStringWidth() or (#vText * 7)
      local need = math.max(112, math.ceil(math.max(kW or 0, vW or 0)) + 26)
      if equalW and need > equalW then equalFits = false end
      pills[i] = { frame = pill, width = math.min(CW, need) }
    end
    if equalFits and equalW then
      for i, item in ipairs(pills) do
        item.frame:ClearAllPoints()
        item.frame:SetPoint("TOPLEFT", content, "TOPLEFT", X + (i - 1) * (equalW + gap), -y)
        item.frame:SetSize(equalW, 44)
      end
      y = y + 50
    else
      local colX, rowY = 0, y
      for _, item in ipairs(pills) do
        local w = item.width
        if colX > 0 and colX + w > CW then
          colX = 0
          rowY = rowY + 50
        end
        item.frame:ClearAllPoints()
        item.frame:SetPoint("TOPLEFT", content, "TOPLEFT", X + colX, -rowY)
        item.frame:SetSize(w, 44)
        colX = colX + w + gap
      end
      y = rowY + 50
    end
  end
  if type(noteText) == "string" and noteText ~= "" then
    note(noteText)
  end
end

-- Pages ---------------------------------------------------------------------------------------------------

local function setHeader(iconName, title, description)
  headerIcon:SetTexture(iconPath(iconName))
  heading:SetText(title)
  subheading:SetText(description or "")
end

local function drawFeature(spec)
  local db = Helper.db[spec.key]
  local ctx = Options.Context(spec, true)
  setHeader(spec.icon, spec.title, spec.description)
  local command = spec.command and Helper.commands[spec.command]
  local switchable = db and db.enabled ~= nil and command ~= nil and spec.defaults and spec.defaults.enabled ~= nil
  enabled:SetShown(switchable)
  if switchable then
    local on = isFeatureActive(spec.key, db)
    enabled.label:SetText(on and "Enabled" or "Disabled")
    enabled.setSwitch(on)
    if on then
      W.SetColor(enabled.bg, unpack(W.colors.accentBg))
      W.SetColor(enabled.border, unpack(W.colors.accentBorder))
      enabled.label:SetTextColor(unpack(W.colors.on))
    else
      W.SetColor(enabled.bg, unpack(W.colors.surface))
      W.SetColor(enabled.border, unpack(W.colors.border))
      enabled.label:SetTextColor(unpack(W.colors.dim))
    end
  end
  moreButton:SetShown(spec.prefs[1] ~= nil)
  if not command and spec.defaults and spec.defaults.enabled ~= nil then
    note("This helper is unavailable on this client.")
    return
  end
  if spec.singleCard then
    local card = CardStart(spec.cardTitle or spec.title)
    if spec.statusChips then statChips(spec, db, ctx) end
    renderOptions(spec, spec.options, ctx, card)
    CardFinish(card)
    return
  end
  for _, cardName in ipairs(CARD_ORDER) do
    if cardName == "status" then
      local card = CardStart(CARD_TITLES.status)
      if spec.statusChips then
        statChips(spec, db, ctx)
      elseif spec.status then
        local ok, lines = pcall(spec.status, db, ctx)
        if ok and type(lines) == "table" then for _, line in ipairs(lines) do note(line, "status") end end
      end
      renderOptions(spec, spec.options, ctx, card, "status")
      CardFinish(card)
    elseif hasCard(spec, ctx, cardName) then
      local card = CardStart(CARD_TITLES[cardName])
      renderOptions(spec, spec.options, ctx, card, cardName)
      if cardName == "appearance" and spec.frames then
        for key, title in pairs(spec.frames) do
          card.actions[#card.actions + 1] = { label = "Move " .. title:lower(),
            tip = "Outlines the " .. title:lower() .. " so you can drag it, resize it with the mouse wheel, or right-click to reset it.",
            run = function() if Helper.Unlock then Helper.Unlock.Start(key) end end }
        end
      end
      CardFinish(card)
    end
  end
end

local function drawHome()
  local on, total = 0, 0
  for _, key in ipairs(Helper.featureOrder) do
    local spec = Helper.features[key]
    if spec.section and spec.defaults and spec.defaults.enabled ~= nil then
      total = total + 1
      if Helper.db[key].enabled and not (key == "minimapFan" and Helper.fanStandsDown) then on = on + 1 end
    end
  end
  setHeader(rtwIcon, "ReadyToWork", ("Version %s  ·  %d of %d helpers active"):format(Helper.version, on, total))
  enabled:Hide(); moreButton:Hide()
  local columns = WIDTH >= 640 and 3 or 2
  local width = math.floor((WIDTH - (columns - 1) * GAP) / columns)
  local index = 0
  for _, key in ipairs(Helper.featureOrder) do
    local spec = Helper.features[key]
    if spec.section then
      local col = index % columns
      local top = y + math.floor(index / columns) * 108
      local cardFrame = widget("homeCard", function()
        local b = CreateFrame("Button", nil, content)
        b.bg, b.border = W.Surface(b, "md", W.colors.card, W.colors.border)
        W.Highlight(b, "md")
        b.iconBox, b.icon = W.IconBadge(b, questionMark, 24, 34)
        b.iconBox:SetPoint("TOPLEFT", 12, -12)
        b.title = W.Font(b, "heading")
        b.title:SetPoint("LEFT", b.iconBox, "RIGHT", 10, 0)
        b.title:SetPoint("RIGHT", b, "RIGHT", -52, 0)
        if b.title.SetWordWrap then b.title:SetWordWrap(false) end

        local toggle = CreateFrame("Button", nil, b)
        toggle:SetSize(40, 24)
        toggle:SetPoint("TOPRIGHT", -8, -17)
        toggle:SetFrameLevel(b:GetFrameLevel() + 2)
        toggle.setSwitch, toggle.rail, toggle.knob = W.Switch(toggle)
        toggle.rail:SetPoint("CENTER")
        W.Highlight(toggle, "pill")
        toggle:SetScript("OnClick", function(self)
          local k = self.key
          local s = k and Helper.features[k]
          local db = s and Helper.db[s.key]
          if not (s and db and s.defaults and s.defaults.enabled ~= nil) then return end
          local command = s.command and Helper.commands[s.command]
          if k == "minimapFan" and Helper.fanStandsDown then
            if command then
              edit(s.title, function() command("on") end, s.key)
              draw()
            end
            return
          end
          local nextOn = db.enabled ~= true
          edit(s.title .. (nextOn and " on" or " off"), function()
            if command then
              command(nextOn and "on" or "off")
            else
              db.enabled = nextOn
              if s.apply then s.apply({ enabled = true }, db, nil) end
            end
          end, s.key)
          draw()
        end)
        W.Tooltip(toggle, function()
          local s = toggle.key and Helper.features[toggle.key]
          return s and s.title or ""
        end, function()
          local s = toggle.key and Helper.features[toggle.key]
          local db = s and Helper.db[s.key]
          local isOn = db and db.enabled == true and not (toggle.key == "minimapFan" and Helper.fanStandsDown)
          return ("Click to turn %s %s."):format(s and s.title or "this helper", isOn and "off" or "on")
        end, "ANCHOR_TOP")
        b.toggle = toggle
        b.setSwitch = toggle.setSwitch

        b.lines = {}
        for n = 1, 2 do
          local line = W.Font(b, n == 1 and "small" or "dim")
          line:SetPoint("TOPLEFT", 12, -54 - (n - 1) * 18); line:SetPoint("RIGHT", -12, 0)
          if line.SetWordWrap then line:SetWordWrap(false) end
          b.lines[n] = line
        end
        b:SetScript("OnClick", function(self) Helper.OpenSettings(self.key) end)
        return b
      end, col * (width + GAP), top, width, 98)
      cardFrame.key = key
      cardFrame.toggle.key = key
      cardFrame.icon:SetTexture(iconPath(spec.icon))
      cardFrame.title:SetText(spec.title)
      local db = Helper.db[key]
      local switchable = spec.defaults and spec.defaults.enabled ~= nil
      local isOn = switchable and db.enabled == true and not (key == "minimapFan" and Helper.fanStandsDown)
      cardFrame.title:ClearAllPoints()
      cardFrame.title:SetPoint("LEFT", cardFrame.iconBox, "RIGHT", 10, 0)
      cardFrame.title:SetPoint("RIGHT", cardFrame, "RIGHT", switchable and -52 or -12, 0)
      cardFrame.toggle:SetShown(switchable)
      if switchable then cardFrame.toggle.setSwitch(isOn) end
      cardFrame.iconBox:SetAlpha((not switchable or isOn) and 1 or .52)
      cardFrame.title:SetTextColor(unpack((not switchable or isOn) and W.colors.heading or W.colors.dim))
      local lines = {}
      if spec.status then
        local ok, result = pcall(spec.status, db, Options.Context(spec, true))
        if ok and type(result) == "table" then lines = result end
      end
      if switchable and not isOn then lines = { "Off", lines[1] } end
      for n = 1, 2 do cardFrame.lines[n]:SetText(lines[n] or "") end
      index = index + 1
    end
  end
  y = y + math.ceil(index / columns) * 108 + 8
  note("Search above the page list to find any setting. Click any card for its settings or use its switch to toggle it.")
end

local function drawSearch()
  setHeader("INV_Misc_Spyglass_02", "Search", ('Settings matching "%s"'):format(searchText))
  enabled:Hide(); moreButton:Hide()
  local results = Options.Search(searchText)
  if #results == 0 then note("No settings match. Try a shorter word."); return end
  for _, result in ipairs(results) do
    local spec = result.spec
    local ctx = Options.Context(spec, true)
    local card = CardStart(spec.title)
    local plain, deep = {}, {}
    for _, option in ipairs(result.options) do
      if option.type == "custom" or option.type == "build" then deep[#deep + 1] = option else plain[#plain + 1] = option end
    end
    renderOptions(spec, plain, ctx, card)
    for _, option in ipairs(deep) do note(("%s: on the %s page."):format(option.label, spec.title)) end
    card.actions[#card.actions + 1] = { label = "Open " .. spec.title, run = function() Helper.OpenSettings(spec.key) end }
    CardFinish(card)
  end
end

local function updateRail()
  for key, tab in pairs(tabs) do
    tint(tab, key == current and searchText == "")
    if tab.setDot then
      tab.setDot(isFeatureActive(key, Helper.db[key]))
    end
  end
end

draw = function()
  bagDrawPending = false
  if not window or not window:IsShown() or drag then return end
  orderCanvas, refreshFaces, questSampleIcons = nil, nil, nil
  used = {}; y = 4
  X, CW = 0, WIDTH
  confirmBar:Hide()
  local spec = Spec()
  if searchText ~= "" then drawSearch()
  elseif spec and spec.section then drawFeature(spec)
  else current = "home"; drawHome() end
  updateRail()
  showAllButton:SetShown(focused)
  footer()
  for kind, pool in pairs(pools) do
    for i = (used[kind] or 0) + 1, #pool do pool[i]:Hide() end
  end
  content:SetHeight(math.max(1, y))
end

-- Window --------------------------------------------------------------------------------------------------

local function updateDrag(elapsed)
  local x, rawY = GetCursorPosition()
  local scale = UIParent:GetEffectiveScale()
  ghost:ClearAllPoints(); ghost:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / scale + 12, rawY / scale + 10)
  local target = dragTarget()
  if target ~= drag.target then
    if drag.target then drag.target.dropBorder:Hide() end
    if target and target ~= drag.source then target.dropBorder:Show() end
    drag.target = target
  end
  if scroll:IsMouseOver() then
    local pointer = rawY / scroll:GetEffectiveScale()
    local direction = pointer > scroll:GetTop() - 24 and -1 or pointer < scroll:GetBottom() + 24 and 1 or 0
    if direction ~= 0 then
      scroll:SetVerticalScroll(math.max(0, math.min(scroll:GetVerticalScrollRange(), scroll:GetVerticalScroll() + direction * elapsed * 270)))
    end
  end
end

local function leftEdge() return focused and 18 or (RAIL + 18) end

local function updateResize()
  local x, rawY = GetCursorPosition()
  local r = resize
  if not r or not x or not rawY or not r.moved and x == r.x and rawY == r.y then return end
  local width = math.floor(math.max(r.minW, math.min(r.maxW, r.width + (x - r.x) / r.scale)) + .5)
  local height = math.floor(math.max(r.minH, math.min(r.maxH, r.height + (r.y - rawY) / r.scale)) + .5)
  if width == window:GetWidth() and height == window:GetHeight() then return end
  if not r.moved then
    window:ClearAllPoints()
    window:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", r.left, r.top)
    r.moved = true
  end
  window:SetSize(width, height)
  WIDTH = width - leftEdge() - 42
  content:SetWidth(WIDTH)
  draw()
end

local function finishResize()
  if not resize then return end
  updateResize()
  local r = resize
  resize = nil
  if not r.moved then return end
  if window:GetWidth() == r.width and window:GetHeight() == r.height then
    window:ClearAllPoints(); window:SetPoint(unpack(r.point))
    return
  end
  local saved = Helper.db.settingsWindow
  saved.contentWidth, saved.height = WIDTH, window:GetHeight()
  local point, _, relative, x, yy = window:GetPoint()
  if point then saved.position = { point, relative, x, yy } end
  footer()
end

local function railEntry(key, title, iconName, navY, hasDot, height)
  height = height or 28
  local tab = CreateFrame("Button", nil, sidebar)
  tab.isRailTab = true
  tab.bg, tab.border = W.Surface(tab, "md", { 1, 1, 1, 0 }, { 1, 1, 1, 0 })
  tab:SetSize(RAIL - 16, height); tab:SetPoint("TOPLEFT", 8, -navY)
  tab.accent = tab:CreateTexture(nil, "ARTWORK")
  W.Slice(tab.accent, "pill_fill.png", 12, 6, 12, 6)
  W.SetColor(tab.accent, unpack(W.colors.accent))
  tab.accent:SetSize(3, 14); tab.accent:SetPoint("LEFT", 3, 0)
  W.Highlight(tab, "md")
  local art = W.Icon(tab, iconPath(iconName), 18); art:SetPoint("LEFT", 12, 0)
  local name = W.Font(tab, "small"); name:SetPoint("LEFT", tab, "LEFT", 38, 0)
  name:SetPoint("RIGHT", tab, "RIGHT", hasDot and -24 or -10, 0)
  if name.SetWordWrap then name:SetWordWrap(false) end
  name:SetText(title)
  tab.name = name
  if hasDot then
    local setDot, dot = W.Dot(tab)
    dot:SetPoint("RIGHT", -10, 0)
    tab.setDot = setDot
  end
  tab:SetScript("OnClick", function()
    stopDrag()
    if searchBox and searchBox:GetText() ~= "" then searchBox:SetText(""); searchText = "" end
    current = key; scroll:SetVerticalScroll(0); draw()
  end)
  tabs[key] = tab
  return tab
end

local function build()
  window = CreateFrame("Frame", "ReadyToWorkSettingsWindow", UIParent)
  window:SetPoint("CENTER"); window:SetFrameStrata("DIALOG")
  window:SetClampedToScreen(true); window:EnableMouse(true); window:SetMovable(true)
  window:RegisterForDrag("LeftButton")
  window:SetResizable(true)
  window:SetScript("OnDragStart", function(self)
    if resize then return end
    self:StartMoving()
  end)
  window:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relative, x, yy = self:GetPoint()
    if point then Helper.db.settingsWindow.position = { point, relative, x, yy } end
  end)
  W.Shadow(window, 18, .55)
  W.Surface(window, "lg", W.colors.window, W.colors.borderStrong, "BACKGROUND", -2)

  -- Resize grip is created as the first Button child of window.
  local grip = CreateFrame("Button", nil, window)
  grip:SetSize(18, 18); grip:SetPoint("BOTTOMRIGHT", -4, 4)
  grip.glyph = W.Glyph(grip, "icon_grip.png", 16, W.colors.muted)
  grip.glyph:SetPoint("CENTER")
  grip:SetScript("OnEnter", function(self) W.SetColor(self.glyph, unpack(W.colors.label)) end)
  grip:SetScript("OnLeave", function(self) W.SetColor(self.glyph, unpack(W.colors.muted)) end)
  grip:SetScript("OnMouseDown", function(_, key)
    if key ~= "LeftButton" then return end
    local scale = window:GetEffectiveScale()
    local parentScale = UIParent:GetEffectiveScale()
    local left, top = window:GetLeft(), window:GetTop()
    local x, rawY = GetCursorPosition()
    if not left or not top or not x or not rawY or scale <= 0 then return end
    local minW, minH, maxW, maxH = window:GetResizeBounds()
    local right = (UIParent:GetRight() or UIParent:GetWidth()) * parentScale / scale
    local bottom = (UIParent:GetBottom() or 0) * parentScale / scale
    resize = { x = x, y = rawY, scale = scale, width = window:GetWidth(), height = window:GetHeight(),
      left = left - (UIParent:GetLeft() or 0) * parentScale / scale, top = top - bottom, point = { window:GetPoint() },
      minW = minW, minH = minH, maxW = math.max(minW, math.min(maxW, right - left)), maxH = math.max(minH, math.min(maxH, top - bottom)) }
  end)
  grip:SetScript("OnMouseUp", function(_, key) if key == "LeftButton" then finishResize() end end)
  table.insert(UISpecialFrames, window:GetName())

  -- Left rail: brand, search, Home, pages by group.
  sidebar = CreateFrame("Frame", nil, window)
  sidebar:SetPoint("TOPLEFT", 1, -1); sidebar:SetPoint("BOTTOMLEFT", 1, 1); sidebar:SetWidth(RAIL)
  sidebar.bg = W.Surface(sidebar, "lg", W.colors.rail, { 1, 1, 1, 0 }, "BACKGROUND", -1)
  local railSquare = W.Solid(sidebar, "BACKGROUND", W.colors.rail[1], W.colors.rail[2], W.colors.rail[3], 1)
  railSquare:SetPoint("TOPRIGHT"); railSquare:SetPoint("BOTTOMRIGHT"); railSquare:SetWidth(14)
  local cDiv = W.colors.divider
  railDivider = W.Solid(sidebar, "BORDER", cDiv[1], cDiv[2], cDiv[3], cDiv[4] or .065)
  railDivider:SetPoint("TOPRIGHT", 0, -1); railDivider:SetPoint("BOTTOMRIGHT", 0, 1); railDivider:SetWidth(1)

  local brandBadge = W.IconBadge(sidebar, rtwIcon, 18, 26)
  brandBadge:SetPoint("TOPLEFT", 14, -14)
  local brand = W.Font(sidebar, "brand")
  brand:SetPoint("LEFT", brandBadge, "RIGHT", 8, 0); brand:SetText("ReadyToWork")
  local ver = W.Font(sidebar, "micro")
  ver:SetPoint("LEFT", brand, "RIGHT", 6, -1)
  ver:SetText("v" .. (Helper.version or ""))

  local box = W.Input(sidebar, "ReadyToWorkSettingsSearch", "Search settings...")
  searchBox = box
  box:SetSize(RAIL - 28, 28); box:SetPoint("TOPLEFT", 14, -52)
  box:HookScript("OnTextChanged", function(self)
    local text = self:GetText() or ""
    if text ~= searchText then searchText = text; scroll:SetVerticalScroll(0); draw() end
  end)
  W.Tooltip(box, "Search", "Type part of a setting's name or description: the results can be changed right there.")
  W.Rule(sidebar, "TOPLEFT", 14, -90, RAIL - 28)

  tabs = {}
  local navY = 98
  railEntry("home", "Home", rtwIcon, navY, false, 30); navY = navY + 34
  local lastGroup
  for _, key in ipairs(Helper.featureOrder) do
    local spec = Helper.features[key]
    if spec.section then
      if spec.group and spec.group ~= lastGroup then
        lastGroup = spec.group
        local group = W.Font(sidebar, "micro")
        group:SetPoint("TOPLEFT", 14, -navY - 5); group:SetText(spec.group:upper()); navY = navY + 22
      end
      railEntry(key, spec.title, spec.icon, navY, spec.defaults and spec.defaults.enabled ~= nil, 28)
      navY = navY + 30
    end
  end
  minHeight = math.max(540, navY + 18)

  -- Header.
  local close = W.Button(window, "", "ghost")
  close:SetSize(28, 28); close:SetPoint("TOPRIGHT", -14, -18)
  close.glyph = W.Glyph(close, "icon_close.png", 12, W.colors.dim)
  close.glyph:SetPoint("CENTER")
  close:SetScript("OnEnter", function(self) W.SetColor(self.glyph, unpack(W.colors.text)) end)
  close:SetScript("OnLeave", function(self) W.SetColor(self.glyph, unpack(W.colors.dim)) end)
  close:SetScript("OnClick", function() window:Hide() end)

  headerBadge, headerIcon = W.IconBadge(window, questionMark, 26, 38)
  heading = W.Font(window, "title")
  heading:SetPoint("TOPLEFT", headerBadge, "TOPRIGHT", 12, -1)
  subheading = W.Font(window, "dim")
  subheading:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -4)
  subheading:SetPoint("RIGHT", window, "RIGHT", -195, 0)
  if subheading.SetWordWrap then subheading:SetWordWrap(false) end
  headerLine = W.Solid(window, "BORDER", cDiv[1], cDiv[2], cDiv[3], cDiv[4] or .065)
  headerLine:SetHeight(1)

  moreButton = W.Button(window, "")
  moreButton:SetSize(28, 28); moreButton:SetPoint("RIGHT", close, "LEFT", -6, 0)
  moreButton.glyph = W.Glyph(moreButton, "icon_more.png", 14, W.colors.label)
  moreButton.glyph:SetPoint("CENTER")
  W.Tooltip(moreButton, "More", "Restore this page's defaults, or undo this page's changes.", "ANCHOR_BOTTOM")
  moreButton:SetScript("OnClick", function(self)
    local spec = Spec()
    if not spec then return end
    local function confirm() confirmBar.key = spec.key; confirmBar.text:SetText(("Put every %s setting back to its default? Lists, profiles and positions are kept."):format(spec.title)); confirmBar:Show() end
    if not (MenuUtil and MenuUtil.CreateContextMenu) then confirm(); return end
    MenuUtil.CreateContextMenu(self, function(_, root)
      root:CreateButton("Restore defaults...", confirm)
      local count = Store.Info(spec.key)
      if count > 0 then
        root:CreateButton("Undo this page's last change", function() Store.Undo(spec.key); draw() end)
      end
      local _, _, since = Store.Info(spec.key)
      if since > 0 then
        root:CreateButton("Undo this page's changes since opening", function() Store.Undo(spec.key, true); draw() end)
      end
    end)
  end)

  enabled = CreateFrame("Button", nil, window)
  enabled.bg, enabled.border = W.Surface(enabled, "pill", W.colors.surface, W.colors.border)
  W.Highlight(enabled, "pill")
  enabled:SetSize(108, 28); enabled:SetPoint("RIGHT", moreButton, "LEFT", -6, 0)
  enabled.label = W.Font(enabled, "small")
  enabled.setSwitch, enabled.rail = W.Switch(enabled)
  enabled.rail:SetPoint("RIGHT", -6, 0)
  enabled.label:SetPoint("RIGHT", enabled.rail, "LEFT", -8, 0)
  enabled:SetScript("OnClick", function()
    local spec = Spec()
    if not spec then return end
    local command = Helper.commands[spec.command]
    if spec.key == "minimapFan" and Helper.fanStandsDown then
      if command then
        edit(spec.title, function() command("on") end, spec.key)
        draw()
      end
      return
    end
    edit(spec.title .. (Helper.db[spec.key].enabled and " off" or " on"), function()
      command(Helper.db[spec.key].enabled and "off" or "on")
    end, spec.key)
    draw()
  end)

  showAllButton = W.Button(window, "Show all")
  showAllButton:SetSize(78, 28); showAllButton:SetPoint("RIGHT", enabled, "LEFT", -6, 0)
  showAllButton:SetScript("OnClick", function() Helper.OpenSettings(current) end)
  W.Tooltip(showAllButton, "Show all", "Opens the whole settings window, with every page.", "ANCHOR_BOTTOM")

  confirmBar = CreateFrame("Frame", nil, window)
  confirmBar:SetHeight(36); confirmBar:SetFrameLevel(window:GetFrameLevel() + 20)
  confirmBar.bg, confirmBar.border = W.Surface(confirmBar, "md", W.colors.dangerBg, W.colors.dangerBorder)
  confirmBar.text = W.Font(confirmBar, "small")
  confirmBar.text:SetPoint("LEFT", 12, 0); confirmBar.text:SetPoint("RIGHT", -174, 0)
  local yes = W.Button(confirmBar, "Restore", "danger"); yes:SetSize(74, 24); yes:SetPoint("RIGHT", -86, 0)
  local no = W.Button(confirmBar, "Cancel"); no:SetSize(74, 24); no:SetPoint("RIGHT", -8, 0)
  yes:SetScript("OnClick", function()
    local key = confirmBar.key
    confirmBar:Hide()
    if key then
      local old = Helper.EditorOutput
      Helper.EditorOutput = function() end
      local ok2, problem = pcall(Store.Reset, key)
      Helper.EditorOutput = old
      if not ok2 then Helper.Print(tostring(problem)) end
    end
    draw()
  end)
  no:SetScript("OnClick", function() confirmBar:Hide() end)
  confirmBar:Hide()

  -- Page area.
  scroll = CreateFrame("ScrollFrame", nil, window)
  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(WIDTH, 1); scroll:SetScrollChild(content)
  scrollbar = CreateFrame("Slider", nil, window)
  scrollbar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 6, 0); scrollbar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 6, 0)
  scrollbar:SetWidth(10); scrollbar:SetOrientation("VERTICAL")
  local track = W.Solid(scrollbar, "BACKGROUND", 1, 1, 1, .04)
  track:SetPoint("TOP"); track:SetPoint("BOTTOM"); track:SetWidth(2)
  local thumb = scrollbar:CreateTexture(nil, "ARTWORK")
  W.Slice(thumb, "pill_fill.png", 12, 6, 12, 6)
  W.SetColor(thumb, .45, .50, .58, .65)
  thumb:SetSize(6, 32); scrollbar:SetThumbTexture(thumb)
  scrollbar:SetMinMaxValues(0, 1); scrollbar:Hide()
  scrollbar:SetScript("OnValueChanged", function(_, v) scroll:SetVerticalScroll(v) end)
  scroll:SetScript("OnScrollRangeChanged", function(self, _, maximum)
    maximum = math.max(0, maximum or 0)
    scrollbar:SetMinMaxValues(0, maximum); scrollbar:SetShown(maximum > 1)
    self:SetVerticalScroll(math.min(self:GetVerticalScroll(), maximum))
  end)
  scroll:SetScript("OnVerticalScroll", function(_, v)
    if scrollbar:GetValue() ~= v then scrollbar:SetValue(v) end
  end)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    self:SetVerticalScroll(math.max(0, math.min(self:GetVerticalScrollRange(), self:GetVerticalScroll() - delta * 36)))
  end)

  -- Footer dock: one Undo for every change, wherever it was made.
  footerBg = CreateFrame("Frame", nil, window)
  footerBg:SetHeight(44); footerBg:SetFrameLevel(window:GetFrameLevel())
  W.Surface(footerBg, "lg", W.colors.footer, { 1, 1, 1, 0 }, "BACKGROUND", -1)
  local footerTop = W.Solid(footerBg, "BACKGROUND", W.colors.footer[1], W.colors.footer[2], W.colors.footer[3], 1)
  footerTop:SetPoint("TOPLEFT"); footerTop:SetPoint("TOPRIGHT"); footerTop:SetHeight(14)
  footerBg.leftSquare = W.Solid(footerBg, "BACKGROUND", W.colors.footer[1], W.colors.footer[2], W.colors.footer[3], 1)
  footerBg.leftSquare:SetPoint("BOTTOMLEFT"); footerBg.leftSquare:SetSize(14, 14)
  footerLine = W.Solid(footerBg, "BORDER", cDiv[1], cDiv[2], cDiv[3], cDiv[4] or .065)
  footerLine:SetPoint("TOPLEFT"); footerLine:SetPoint("TOPRIGHT"); footerLine:SetHeight(1)

  local footerLevel = window:GetFrameLevel() + 2
  undoButton = W.Button(window, "Undo", "primary")
  undoButton:SetSize(72, 26); undoButton:SetFrameLevel(footerLevel)
  undoButton:SetScript("OnClick", function()
    local ok2, problem = pcall(Store.Undo)
    draw()
    if not ok2 then error(problem, 0) end
  end)
  W.Tooltip(undoButton, "Undo", function()
    local count, label, feature = Store.Count()
    if count == 0 then return "Nothing to undo since you logged in." end
    local spec = Helper.features[feature]
    return ("Takes back the newest settings change, wherever you made it: %s (%s). History lasts until logout or UI reload."):format(label or "?", spec and spec.title or feature)
  end, "ANCHOR_TOP")
  revertButton = W.Button(window, "Revert visit")
  revertButton:SetSize(88, 26); revertButton:SetPoint("LEFT", undoButton, "RIGHT", 6, 0); revertButton:SetFrameLevel(footerLevel)
  revertButton:SetScript("OnClick", function()
    local ok2, problem = pcall(Store.Undo, nil, true)
    draw()
    if not ok2 then error(problem, 0) end
  end)
  W.Tooltip(revertButton, "Revert visit", "Takes back every settings change since you opened this window, on every page.", "ANCHOR_TOP")
  local save = W.Button(window, "Reload UI")
  save:SetPoint("BOTTOMRIGHT", -26, 9); save:SetSize(78, 26); save:SetFrameLevel(footerLevel)
  save:SetScript("OnClick", function() C_UI.Reload() end)
  W.Tooltip(save, "Reload UI", "Reloading saves settings to disk and clears this session's undo history.", "ANCHOR_TOP")
  editStatus = W.Font(footerBg, "dim")
  editStatus:SetPoint("LEFT", revertButton, "RIGHT", 10, 0); editStatus:SetPoint("RIGHT", save, "LEFT", -10, 0)
  editStatus:SetWordWrap(false)

  ghost = CreateFrame("Frame", nil, UIParent)
  ghost:SetFrameStrata("TOOLTIP"); ghost:SetSize(190, 36); ghost:EnableMouse(false)
  W.Shadow(ghost, 10, .45)
  ghost.bg, ghost.border = W.Surface(ghost, "md", W.colors.cardHover, W.colors.accentBorder)
  ghost.icon = CreateFrame("Frame", nil, ghost); ghost.icon:SetSize(24, 24); ghost.icon:SetPoint("LEFT", 6, 0)
  ghost.label = W.Font(ghost, "body"); ghost.label:SetPoint("LEFT", ghost.icon, "RIGHT", 8, 0); ghost.label:SetPoint("RIGHT", -6, 0); ghost:Hide()

  window:SetScript("OnHide", function()
    bagDrawPending = false
    finishResize(); stopDrag()
    if sliderEdit then Store.Finish(sliderEdit); sliderEdit = nil end
    orderCanvas, refreshFaces = nil, nil
    confirmBar:Hide()
  end)
  local fanTimer, artTimer = 0, 0
  window:SetScript("OnUpdate", function(_, elapsed)
    if resize then
      if IsMouseButtonDown and not IsMouseButtonDown("LeftButton") then finishResize() else updateResize() end
      return
    end
    if drag then updateDrag(elapsed); return end
    if orderCanvas then
      fanTimer, artTimer = fanTimer + elapsed, artTimer + elapsed
      if fanTimer >= .12 then
        fanTimer = 0
        local view, page, revision = Helper.FanView()
        if view ~= drawnView or page ~= drawnPage or revision ~= drawnRevision then draw(); artTimer = 0
        elseif artTimer >= 2 then artTimer = 0; refreshFaces() end
      end
    end
  end)
  for _, event in ipairs({ "PLAYER_REGEN_ENABLED", "ACTIVE_TALENT_GROUP_CHANGED", "BAG_UPDATE_DELAYED", "MERCHANT_SHOW",
      "MERCHANT_CLOSED", "GET_ITEM_INFO_RECEIVED" }) do
    pcall(window.RegisterEvent, window, event)
  end
  window:SetScript("OnEvent", function(self, event, itemID, success)
    if not self:IsShown() then return end
    local key = current
    if event == "PLAYER_REGEN_ENABLED" or (event == "ACTIVE_TALENT_GROUP_CHANGED" and (key == "barProfiles" or key == "home")) then draw()
    elseif (event == "MERCHANT_SHOW" or event == "MERCHANT_CLOSED") and (key == "vendor" or key == "home") then draw()
    elseif event == "GET_ITEM_INFO_RECEIVED" and success and key == "destroy" and Helper.db.destroy.keep and Helper.db.destroy.keep[itemID] == true then draw()
    elseif event == "BAG_UPDATE_DELAYED" and (key == "open" or key == "destroy" or key == "home" or (key == "vendor" and bagPickerOpen)) then
      if not bagDrawPending then
        bagDrawPending = true
        C_Timer.After(0.25, function()
          if bagDrawPending then
            bagDrawPending = false
            if window and window:IsShown() then draw() end
          end
        end)
      end
    end
  end)
  window:Hide()
end

local function layout()
  local left = leftEdge()
  sidebar:SetShown(not focused)
  footerBg:ClearAllPoints()
  if focused then footerBg:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", 1, 1)
  else footerBg:SetPoint("BOTTOMLEFT", sidebar, "BOTTOMRIGHT", 0, 0) end
  if footerBg.leftSquare then footerBg.leftSquare:SetShown(not focused) end
  footerBg:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -1, 1)
  undoButton:ClearAllPoints(); undoButton:SetPoint("BOTTOMLEFT", left, 9)
  headerBadge:ClearAllPoints(); headerBadge:SetPoint("TOPLEFT", left, -15)
  headerLine:ClearAllPoints(); headerLine:SetPoint("TOPLEFT", left, -68); headerLine:SetPoint("TOPRIGHT", window, "TOPRIGHT", -18, -68)
  confirmBar:ClearAllPoints(); confirmBar:SetPoint("TOPLEFT", left, -72); confirmBar:SetPoint("TOPRIGHT", window, "TOPRIGHT", -18, -72)
  scroll:ClearAllPoints(); scroll:SetPoint("TOPLEFT", left, -78); scroll:SetPoint("BOTTOMRIGHT", -38, 48)
end

local function open(name, oneFeature)
  local spec = Helper.FeatureByName(name)
  if spec and spec.section then current = spec.key
  elseif name == "home" then current = "home" end
  if not window then build() end
  finishResize(); stopDrag()
  if not window:IsShown() then Store.StartVisit() end
  focused = oneFeature == true and spec ~= nil
  if searchBox and searchBox:GetText() ~= "" then searchBox:SetText(""); searchText = "" end
  local left = leftEdge()
  Helper.db.settingsWindow = Helper.db.settingsWindow or {}
  local saved = Helper.db.settingsWindow
  WIDTH = math.max(560, math.min(920, tonumber(saved.contentWidth) or 620))
  local height = math.max(minHeight, math.min(900, tonumber(saved.height) or math.max(580, minHeight)))
  local width = left + WIDTH + 42
  local scale = math.min(1, (UIParent:GetWidth() - 12) / (left + 560 + 42), (UIParent:GetHeight() - 12) / minHeight)
  width = math.min(width, (UIParent:GetWidth() - 12) / scale)
  height = math.min(height, (UIParent:GetHeight() - 12) / scale)
  WIDTH = width - left - 42
  window:SetScale(scale)
  window:SetResizeBounds(left + 560 + 42, minHeight, math.min(left + 920 + 42, (UIParent:GetWidth() - 12) / scale), math.min(900, (UIParent:GetHeight() - 12) / scale))
  window:SetSize(width, height)
  content:SetWidth(WIDTH)
  window:ClearAllPoints()
  if saved.position then window:SetPoint(saved.position[1], UIParent, saved.position[2], saved.position[3], saved.position[4])
  else window:SetPoint("CENTER", UIParent, "CENTER", 0, 0) end
  layout()
  window:Show(); scroll:SetVerticalScroll(0); draw()
end

-- Opens the settings window: on the page `name` names (a title, an older title, a key or a command word), or
-- where it was last.
function Helper.OpenSettings(name) open(name, false) end
-- Opens one page on its own, without the page list (from a helper's own button); "Show all" adds the list.
function Helper.OpenFeatureSettings(name) open(name, true) end
function Helper.ShowVendorHistory()
  open("vendor", false)
end
function Helper.RefreshSettings(name)
  local spec = Helper.FeatureByName(name)
  if window and window:IsShown() and spec and (spec.key == current or current == "home") then draw() end
end

-- A change made anywhere else shows at once: the footer always, the page when it is the one on show.
Store.OnChange(function(feature)
  if not window or not window:IsShown() then return end
  footer()
  if not inWindowEdit then
    local spec = Helper.features[feature]
    if feature == current or current == "home" or searchText ~= "" or (spec and not spec.section) then draw() end
  end
end)

Helper.commands.settings = function(rest) Helper.OpenSettings(rest ~= "" and rest or nil) end
Helper.help[#Helper.help + 1] = "/rtw settings [page] - open the settings window"
