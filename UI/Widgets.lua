-- Drawing pieces for ReadyToWork's own windows: Obsidian Minimal (2026) palette, 9-slice rounded
-- surfaces, hairline borders, soft drop shadows, masked icons, pill switches, glowing status dots, and
-- crisp vector glyphs. The settings window (UI\Window.lua), unlock mode and the introduction use them.

local _, Helper = ...
local W = {}
Helper.Widgets = W

W.MEDIA = "Interface\\AddOns\\ReadyToWork\\Media\\"

W.colors = {
  window = { .055, .059, .068, .985 },
  rail = { .075, .080, .094, 1 },
  header = { .064, .069, .080, 1 },
  footer = { .066, .071, .084, 1 },
  card = { .094, .101, .118, .98 },
  cardHover = { .118, .127, .148, 1 },
  surface = { .128, .138, .160, 1 },
  surfaceHover = { .168, .180, .208, 1 },
  input = { .047, .051, .060, 1 },
  border = { 1, 1, 1, .085 },
  borderStrong = { 1, 1, 1, .145 },
  divider = { 1, 1, 1, .065 },
  text = { .95, .96, .98, 1 },
  heading = { .90, .92, .96, 1 },
  label = { .82, .85, .90, 1 },
  dim = { .55, .59, .66, 1 },
  muted = { .42, .46, .53, 1 },
  link = { .88, .92, .96, 1 },
  accent = { .18, .80, .58, 1 },
  accentBg = { .10, .36, .27, .42 },
  accentBgStrong = { .12, .44, .32, .68 },
  accentBorder = { .22, .84, .62, .45 },
  on = { .20, .84, .58, 1 },
  offTrack = { .22, .21, .24, 1 },
  off = { .56, .59, .65, 1 },
  danger = { .95, .44, .46, 1 },
  dangerBg = { .36, .11, .13, .82 },
  dangerBorder = { .95, .44, .46, .42 },
}

local FONT_OBJECTS = {
  title = "GameFontNormalLarge",
  brand = "GameFontNormalLarge",
  heading = "GameFontNormal",
  body = "GameFontHighlight",
  small = "GameFontHighlightSmall",
  dim = "GameFontDisableSmall",
  micro = "GameFontDisableSmall",
}
local FONT_SIZES = {
  title = 17,
  brand = 15,
  heading = 13,
  body = 12,
  small = 11,
  dim = 11,
  micro = 10,
}
local COLORS = {
  title = "text",
  brand = "text",
  heading = "heading",
  body = "text",
  small = "label",
  dim = "dim",
  micro = "muted",
}

local SURFACE_FILES = {
  lg = { "panel_fill.png", "panel_border.png", 16, 16, 16, 16 },
  md = { "card_fill.png", "card_border.png", 12, 12, 12, 12 },
  pill = { "pill_fill.png", "pill_border.png", 12, 6, 12, 6 },
}

local SHADOW_PARTS = {
  { anchors = { { "BOTTOMRIGHT", "TOPLEFT" } }, w = true, h = true, tc = { 0, .25, 0, .25 } },
  { anchors = { { "BOTTOMLEFT", "TOPRIGHT" } }, w = true, h = true, tc = { .75, 1, 0, .25 } },
  { anchors = { { "TOPRIGHT", "BOTTOMLEFT" } }, w = true, h = true, tc = { 0, .25, .75, 1 } },
  { anchors = { { "TOPLEFT", "BOTTOMRIGHT" } }, w = true, h = true, tc = { .75, 1, .75, 1 } },
  { anchors = { { "BOTTOMLEFT", "TOPLEFT" }, { "BOTTOMRIGHT", "TOPRIGHT" } }, h = true, tc = { .25, .75, 0, .25 } },
  { anchors = { { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }, h = true, tc = { .25, .75, .75, 1 } },
  { anchors = { { "TOPRIGHT", "TOPLEFT" }, { "BOTTOMRIGHT", "BOTTOMLEFT" } }, w = true, tc = { 0, .25, .25, .75 } },
  { anchors = { { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" } }, w = true, tc = { .75, 1, .25, .75 } },
}

-- Shared animation loop for pill switches so idle widgets carry zero OnUpdate cost.
local activeSwitches = {}
local switchDriver
local function ensureSwitchDriver()
  if switchDriver then return end
  switchDriver = CreateFrame("Frame")
  switchDriver:Hide()
  switchDriver:SetScript("OnUpdate", function(_, elapsed)
    local any = false
    local step = math.min(1, (elapsed or 0.016) * 14)
    for state in pairs(activeSwitches) do
      local diff = state.target - state.pos
      if math.abs(diff) <= 0.01 or not state.parent:IsShown() then
        state.pos = state.target
        state.place(state.pos)
        activeSwitches[state] = nil
      else
        state.pos = state.pos + diff * step
        state.place(state.pos)
        any = true
      end
    end
    if not any then switchDriver:Hide() end
  end)
end

-- Applies vertex color to a white-base texture and records `.rgba` for tests and state inspection.
function W.SetColor(tex, r, g, b, a)
  if type(r) == "table" then
    r, g, b, a = r[1], r[2], r[3], r[4]
  end
  a = a or 1
  if tex.SetVertexColor then tex:SetVertexColor(r, g, b, a) end
  tex.rgba = { r, g, b, a }
  return tex
end

-- Loads a 9-slice media texture onto `tex`.
function W.Slice(tex, file, ml, mt, mr, mb)
  tex:SetTexture(W.MEDIA .. file)
  if tex.SetTextureSliceMargins then tex:SetTextureSliceMargins(ml, mt, mr, mb) end
  if tex.SetTextureSliceMode then
    local mode = Enum and Enum.UITextureSliceMode and Enum.UITextureSliceMode.Stretched or 0
    tex:SetTextureSliceMode(mode)
  end
  return tex
end

-- Creates a rounded 9-slice fill and hairline border on `parent`.
function W.Surface(parent, radius, fill, border, bgLayer, bgSubLevel)
  local spec = SURFACE_FILES[radius] or SURFACE_FILES.md
  local bg = parent:CreateTexture(nil, bgLayer or "BACKGROUND", nil, bgSubLevel or 0)
  bg:SetAllPoints(parent)
  W.Slice(bg, spec[1], spec[3], spec[4], spec[5], spec[6])
  local fc = fill or W.colors.card
  W.SetColor(bg, fc[1], fc[2], fc[3], fc[4] or 1)

  local borderTex = parent:CreateTexture(nil, "BORDER", nil, 1)
  borderTex:SetAllPoints(parent)
  W.Slice(borderTex, spec[2], spec[3], spec[4], spec[5], spec[6])
  local bc = border or W.colors.border
  W.SetColor(borderTex, bc[1], bc[2], bc[3], bc[4] or 1)
  return bg, borderTex
end

-- Soft 8-part outer drop shadow around `frame`.
function W.Shadow(frame, size, alpha)
  size = size or 18
  alpha = alpha or 0.55
  local parts = {}
  for i, spec in ipairs(SHADOW_PARTS) do
    local t = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
    t:SetTexture(W.MEDIA .. "shadow.png")
    t:SetTexCoord(spec.tc[1], spec.tc[2], spec.tc[3], spec.tc[4])
    for _, anchor in ipairs(spec.anchors) do
      t:SetPoint(anchor[1], frame, anchor[2], 0, 0)
    end
    if spec.w then t:SetWidth(size) end
    if spec.h then t:SetHeight(size) end
    t:SetVertexColor(1, 1, 1, alpha)
    parts[i] = t
  end
  return parts
end

-- Subtle vertical sheen near the top of an elevated surface.
function W.TopSheen(parent, alpha)
  local sheen = parent:CreateTexture(nil, "ARTWORK", nil, -6)
  sheen:SetPoint("TOPLEFT", 1, -1)
  sheen:SetPoint("TOPRIGHT", -1, -1)
  sheen:SetHeight(24)
  if sheen.SetGradient and CreateColor then
    sheen:SetColorTexture(1, 1, 1, 1)
    pcall(sheen.SetGradient, sheen, "VERTICAL", CreateColor(1, 1, 1, 0), CreateColor(1, 1, 1, alpha or .03))
  else
    sheen:SetColorTexture(1, 1, 1, (alpha or .03) * 0.5)
  end
  return sheen
end

-- A text line in the game's own font object for `style`, refined to modern point sizes.
function W.Font(parent, style)
  style = FONT_OBJECTS[style] and style or "body"
  local label = parent:CreateFontString(nil, "OVERLAY", FONT_OBJECTS[style])
  if label.GetFont and label.SetFont then
    local face, _, flags = label:GetFont()
    if face and FONT_SIZES[style] then
      pcall(label.SetFont, label, face, FONT_SIZES[style], flags or "")
    end
  end
  if label.SetShadowOffset then label:SetShadowOffset(0, -1) end
  if label.SetShadowColor then label:SetShadowColor(0, 0, 0, .45) end
  label:SetJustifyH("LEFT")
  local c = W.colors[COLORS[style]]
  label:SetTextColor(c[1], c[2], c[3], c[4] or 1)
  return label
end

function W.Solid(parent, layer, r, g, b, a)
  local region = parent:CreateTexture(nil, layer)
  region:SetColorTexture(r, g, b, a or 1)
  region.rgba = { r, g, b, a or 1 }
  return region
end

function W.Background(parent, color)
  local texture = parent:CreateTexture(nil, "BACKGROUND")
  texture:SetAllPoints()
  local a = color[4] or 1
  texture:SetColorTexture(color[1], color[2], color[3], a)
  texture.rgba = { color[1], color[2], color[3], a }
  return texture
end

function W.Rule(parent, anchor, x, y, width)
  local c = W.colors.divider
  local line = W.Solid(parent, "BORDER", c[1], c[2], c[3], c[4] or .065)
  line:SetPoint(anchor, x, y)
  line:SetSize(width, 1)
  return line
end

-- An icon texture cropped cleanly with an anti-aliased rounded-square mask.
function W.Icon(parent, texture, size)
  local art = parent:CreateTexture(nil, "ARTWORK")
  art:SetTexture(texture)
  art:SetSize(size, size)
  art:SetTexCoord(.07, .93, .07, .93)
  if parent.CreateMaskTexture and art.AddMaskTexture then
    local ok, mask = pcall(parent.CreateMaskTexture, parent)
    if ok and mask then
      mask:SetTexture(W.MEDIA .. "mask_icon.png", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
      mask:SetAllPoints(art)
      art:AddMaskTexture(mask)
      art.mask = mask
    end
  end
  return art
end

-- Recessed rounded container holding a centered rounded-masked icon.
function W.IconBadge(parent, texture, iconSize, boxSize)
  boxSize = boxSize or (iconSize + 10)
  local box = CreateFrame("Frame", nil, parent)
  box:SetSize(boxSize, boxSize)
  box:EnableMouse(false)
  box.bg, box.border = W.Surface(box, "md", { .060, .065, .076, 1 }, W.colors.border)
  local icon = W.Icon(box, texture, iconSize)
  icon:SetPoint("CENTER")
  box.icon = icon
  return box, icon
end

-- Crisp monochrome vector glyph from ReadyToWork\Media\.
function W.Glyph(parent, file, size, color)
  local glyph = parent:CreateTexture(nil, "ARTWORK")
  glyph:SetTexture(W.MEDIA .. file)
  glyph:SetSize(size, size)
  local c = color or W.colors.label
  W.SetColor(glyph, c[1], c[2], c[3], c[4] or 1)
  return glyph
end

function W.Shade(parent, r1, g1, b1, r2, g2, b2)
  local band = parent:CreateTexture(nil, "BACKGROUND")
  band:SetAllPoints()
  if band.SetGradient and CreateColor then
    band:SetTexture("Interface\\Buttons\\WHITE8X8")
    band:SetGradient("HORIZONTAL", CreateColor(r1, g1, b1), CreateColor(r2, g2, b2))
  else
    band:SetColorTexture(r1, g1, b1, 1)
  end
  return band
end

function W.Highlight(parent, radius)
  local wash = parent:CreateTexture(nil, "HIGHLIGHT")
  wash:SetAllPoints()
  local spec = SURFACE_FILES[radius or "md"] or SURFACE_FILES.md
  W.Slice(wash, spec[1], spec[3], spec[4], spec[5], spec[6])
  W.SetColor(wash, 1, 1, 1, .055)
  return wash
end

-- A modern rounded button. Styles: nil (default), "primary", "danger", "ghost".
function W.Button(parent, text, style)
  local b = CreateFrame("Button", nil, parent)
  b.bg, b.border = W.Surface(b, "md", W.colors.surface, W.colors.border)
  b.highlight = W.Highlight(b, "md")
  b.label = W.Font(b, "small")
  b.label:SetPoint("CENTER")
  b.label:SetJustifyH("CENTER")
  b.label:SetText(text)
  b.SetFill = function(self, r, g, b2, a) W.SetColor(self.bg, r, g, b2, a) end
  W.Style(b, style)
  return b
end

function W.Style(button, style)
  button.style = style
  if style == "primary" then
    W.SetColor(button.bg, unpack(W.colors.accentBgStrong))
    if button.border then W.SetColor(button.border, unpack(W.colors.accentBorder)) end
    button.label:SetTextColor(.90, .99, .95, 1)
  elseif style == "danger" then
    W.SetColor(button.bg, unpack(W.colors.dangerBg))
    if button.border then W.SetColor(button.border, unpack(W.colors.dangerBorder)) end
    button.label:SetTextColor(unpack(W.colors.danger))
  elseif style == "ghost" then
    W.SetColor(button.bg, 1, 1, 1, 0)
    if button.border then W.SetColor(button.border, 1, 1, 1, 0) end
    button.label:SetTextColor(unpack(W.colors.label))
  else
    W.SetColor(button.bg, unpack(W.colors.surface))
    if button.border then W.SetColor(button.border, unpack(W.colors.border)) end
    button.label:SetTextColor(unpack(W.colors.link))
  end
end

-- A 34x18 pill switch with smooth animated thumb slide. Returns the setter, the rail and the knob.
function W.Switch(parent)
  local rail = parent:CreateTexture(nil, "ARTWORK")
  rail:SetSize(34, 18)
  W.Slice(rail, "pill_fill.png", 12, 6, 12, 6)
  W.SetColor(rail, unpack(W.colors.offTrack))

  local border = parent:CreateTexture(nil, "ARTWORK", nil, 2)
  border:SetAllPoints(rail)
  W.Slice(border, "pill_border.png", 12, 6, 12, 6)
  W.SetColor(border, 1, 1, 1, .11)
  rail.border = border

  local knob = parent:CreateTexture(nil, "OVERLAY")
  knob:SetTexture(W.MEDIA .. "circle.png")
  knob:SetSize(12, 12)

  local function place(pos)
    knob:ClearAllPoints()
    knob:SetPoint("LEFT", rail, "LEFT", 3 + pos * 16, 0)
  end

  local state = { pos = 0, target = 0, initialized = false, parent = parent, place = place }
  place(0)

  return function(on)
    local want = on and 1 or 0
    if on then
      W.SetColor(rail, .14, .76, .50, 1)
      W.SetColor(border, .24, .90, .62, .45)
      W.SetColor(knob, 1, 1, 1, 1)
    else
      W.SetColor(rail, unpack(W.colors.offTrack))
      W.SetColor(border, 1, 1, 1, .11)
      W.SetColor(knob, .78, .81, .86, 1)
    end
    state.target = want
    if not state.initialized or not parent:IsShown() then
      state.initialized = true
      state.pos = want
      place(want)
      activeSwitches[state] = nil
    elseif math.abs(state.pos - want) > 0.01 then
      ensureSwitchDriver()
      activeSwitches[state] = true
      switchDriver:Show()
    end
  end, rail, knob, border
end

-- A circular status dot with a subtle emerald glow when on.
function W.Dot(parent)
  local dot = parent:CreateTexture(nil, "OVERLAY")
  dot:SetTexture(W.MEDIA .. "circle.png")
  dot:SetSize(7, 7)

  local glow = parent:CreateTexture(nil, "ARTWORK")
  glow:SetTexture(W.MEDIA .. "glow.png")
  glow:SetSize(18, 18)
  glow:SetPoint("CENTER", dot, "CENTER")
  glow:SetVertexColor(.20, .86, .58, .35)
  glow:Hide()
  dot.glow = glow

  return function(on)
    if on then
      W.SetColor(dot, unpack(W.colors.on))
      glow:Show()
    else
      W.SetColor(dot, .34, .37, .43, 1)
      glow:Hide()
    end
  end, dot, glow
end

-- A dark rounded search / filter EditBox with left search glyph, placeholder and inline clear button.
function W.Input(parent, name, placeholder)
  local box = CreateFrame("EditBox", name, parent)
  box:SetAutoFocus(false)
  box:SetFontObject("GameFontHighlightSmall")
  if box.GetFont and box.SetFont then
    local face, _, flags = box:GetFont()
    if face then pcall(box.SetFont, box, face, 11, flags or "") end
  end
  box:SetTextColor(unpack(W.colors.text))
  box.bg, box.border = W.Surface(box, "md", W.colors.input, W.colors.border)
  box.searchIcon = W.Glyph(box, "icon_search.png", 13, W.colors.dim)
  box.searchIcon:SetPoint("LEFT", 9, 0)
  box:SetTextInsets(28, 24, 0, 0)

  box.hint = W.Font(box, "dim")
  box.hint:SetPoint("LEFT", 28, 0)
  box.hint:SetPoint("RIGHT", -24, 0)
  box.hint:SetText(placeholder or "")

  local clear = CreateFrame("Button", nil, box)
  clear:SetSize(18, 18)
  clear:SetPoint("RIGHT", -5, 0)
  clear.glyph = W.Glyph(clear, "icon_close.png", 10, W.colors.dim)
  clear.glyph:SetPoint("CENTER")
  clear:Hide()
  clear:SetScript("OnClick", function()
    box:SetText("")
    if box.onClear then
      box.onClear(box)
    elseif box.scripts and box.scripts.OnTextChanged then
      box.scripts.OnTextChanged(box, true)
    end
  end)
  box.clear = clear

  box:SetScript("OnEditFocusGained", function(self)
    W.SetColor(self.border, unpack(W.colors.accentBorder))
  end)
  box:SetScript("OnEditFocusLost", function(self)
    W.SetColor(self.border, unpack(W.colors.border))
  end)
  box:SetScript("OnTextChanged", function(self)
    local empty = (self:GetText() or "") == ""
    self.hint:SetShown(empty)
    self.clear:SetShown(not empty)
  end)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  return box
end

-- A modern rounded checkbox matching the Obsidian Minimal palette.
function W.Checkbox(parent)
  local cb = CreateFrame("CheckButton", nil, parent)
  cb:SetSize(18, 18)
  cb.bg, cb.border = W.Surface(cb, "md", W.colors.input, W.colors.borderStrong)
  cb.highlight = W.Highlight(cb, "md")
  cb.check = W.Glyph(cb, "icon_check.png", 12, { 1, 1, 1, 1 })
  cb.check:SetPoint("CENTER")
  cb.check:Hide()

  local function sync(self)
    local on = self._checked == true
    self.check:SetShown(on)
    if on then
      W.SetColor(self.bg, .14, .65, .44, 1)
      W.SetColor(self.border, .24, .88, .62, .75)
    else
      W.SetColor(self.bg, unpack(W.colors.input))
      W.SetColor(self.border, unpack(W.colors.borderStrong))
    end
  end

  local origSet = cb.SetChecked
  cb.SetChecked = function(self, checked)
    self._checked = checked == true
    if origSet then pcall(origSet, self, self._checked) end
    sync(self)
  end

  local origGet = cb.GetChecked
  cb.GetChecked = function(self)
    if origGet then
      local ok, res = pcall(origGet, self)
      if ok and type(res) == "boolean" then return res end
    end
    return self._checked == true
  end

  local function syncFromClick(self)
    if origGet then
      local ok, res = pcall(origGet, self)
      if ok and type(res) == "boolean" then self._checked = res else self._checked = not self._checked end
    else
      self._checked = not self._checked
    end
    sync(self)
  end

  cb:SetScript("OnClick", syncFromClick)
  local origSetScript = cb.SetScript
  if type(origSetScript) == "function" then
    cb.SetScript = function(self, scriptType, handler)
      if scriptType == "OnClick" then
        if type(handler) == "function" then
          return origSetScript(self, "OnClick", function(btn, ...)
            syncFromClick(btn)
            return handler(btn, ...)
          end)
        end
        return origSetScript(self, "OnClick", syncFromClick)
      end
      return origSetScript(self, scriptType, handler)
    end
  end
  return cb
end

function W.DropBorder(control)
  local border = CreateFrame("Frame", nil, control)
  border:SetPoint("TOPLEFT", -2, 2)
  border:SetPoint("BOTTOMRIGHT", 2, -2)
  border:EnableMouse(false)
  border.bg, border.edge = W.Surface(border, "md", { .12, .55, .38, .18 }, { .28, .92, .65, 1 })
  border:Hide()
  control.dropBorder = border
end

-- Shows `tip` (and a heading) on hover over `frame`.
function W.Tooltip(frame, heading, tip, anchor)
  frame:SetScript("OnEnter", function(self)
    local text = type(tip) == "function" and tip() or tip
    if not text then return end
    GameTooltip:SetOwner(self, anchor or "ANCHOR_RIGHT")
    GameTooltip:SetText(type(heading) == "function" and heading() or heading, 1, 1, 1)
    GameTooltip:AddLine(text, nil, nil, nil, true)
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", function(self)
    if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
  end)
end
