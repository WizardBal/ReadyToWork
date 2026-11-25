local _, Helper = ...
local Art = {}
Helper.FanArt = Art

-- Copy only visual regions into editor-owned frames. The original launcher keeps
-- its parent, scripts and click behavior even while the order control is open.
local function public(...)
  if canaccessallvalues and not canaccessallvalues(...) then return end
  return ...
end

local function anchorOffset(point, width, height)
  local x = point:find("LEFT") and -width / 2 or point:find("RIGHT") and width / 2 or 0
  local y = point:find("TOP") and height / 2 or point:find("BOTTOM") and -height / 2 or 0
  return x, y
end

local function box(region, source, depth)
  local width, height = region:GetSize()
  if region:IsObjectType("FontString") then
    if not width or width<=0 then width=region:GetStringWidth() end
    if not height or height<=0 then height=region:GetStringHeight() end
  end
  if not width or not height or width <= 0 or height <= 0 then return end
  local scale = region:GetEffectiveScale() / source:GetEffectiveScale()
  width, height = width * scale, height * scale
  if region == source then return 0, 0, width, height end
  local x, y = region:GetCenter()
  local sx, sy = source:GetCenter()
  if x and y and sx and sy then return x * scale - sx, y * scale - sy, width, height end
  -- A collapsed fan can lack absolute rectangles. Follow the artwork's anchors.
  if depth >= 8 then return end
  local p, other, q, dx, dy = region:GetPoint(1)
  other = other or region:GetParent()
  if not p or not other or other == region then return end
  local ox, oy, ow, oh = box(other, source, depth + 1)
  if not ox then return end
  local ax, ay = anchorOffset(p, width, height)
  local bx, by = anchorOffset(q or p, ow, oh)
  return ox + bx - ax + dx * scale, oy + by - ay + dy * scale, width, height
end

local function texture(region, source)
  local x, y, w, h = box(region, source, 0)
  if not x then return end
  local atlas = public(region:GetAtlas())
  local file = public(region:GetTexture())
  if atlas=="" then atlas=nil end
  if not atlas and type(file)~="string" and type(file)~="number" then return end
  return {x=x, y=y, w=w, h=h, atlas=atlas, file=file, uv={public(region:GetTexCoord())},
    rotation=public(region:GetRotation()), color={public(region:GetVertexColor())},
    blend=public(region:GetBlendMode()), desaturation=public(region:GetDesaturation())}
end

local function captureRegion(region, source)
  if (region.IsForbidden and region:IsForbidden()) or not region:IsShown() then return end
  local layer, sub = region:GetDrawLayer()
  if layer == "HIGHLIGHT" then return end
  local item
  if region:IsObjectType("FontString") then
    local text = public(region:GetText())
    if not text or text == "" then return end
    local x, y, w, h = box(region, source, 0)
    if not x then return end
    local face, size, flags = region:GetFont()
    if not face then return end
    item = {x=x, y=y, w=w, h=h, text=text, font=face, size=size*region:GetEffectiveScale()/source:GetEffectiveScale(),
      flags=flags, color={public(region:GetTextColor())}, shadow={public(region:GetShadowColor())},
      offset={public(region:GetShadowOffset())}, justify=region:GetJustifyH(), vertical=region:GetJustifyV()}
  elseif region:IsObjectType("Texture") and not region:IsObjectType("MaskTexture") then
    item = texture(region, source)
    if not item then return end
    for i = 1, region:GetNumMaskTextures() do
      local mask = region:GetMaskTexture(i)
      local data = mask and texture(mask, source)
      if data then
        item.masks = item.masks or {}
        item.masks[#item.masks+1] = data
      end
    end
  else return end
  item.layer, item.sub, item.alpha = layer, sub or 0, public(region:GetAlpha()) or 1
  return item
end

local function captureFrame(owner, source, art, depth, alpha)
  if owner:IsForbidden() then return end
  if depth > 0 then
    if not owner:IsShown() then return end
    -- Badges can hang over a launcher. Attached popups are separate windows.
    local x, y, w, h = box(owner, source, 0)
    if not x or not y or not w or not h or math.abs(x)>art.size or math.abs(y)>art.size or w>2*art.size or h>2*art.size then return end
    alpha = alpha * owner:GetAlpha()
  end
  local level = owner:GetFrameLevel() - source:GetFrameLevel()
  for _, region in ipairs({owner:GetRegions()}) do
    local ok, item = pcall(captureRegion, region, source)
    if ok and item then
      item.level, item.alpha = level, item.alpha * alpha
      art[#art+1] = item
    end
  end
  if depth < 2 then
    for _, child in ipairs({owner:GetChildren()}) do
      pcall(captureFrame, child, source, art, depth+1, alpha)
    end
  end
end

function Art.Capture(source)
  if not source then return end
  local art = {}
  local ok = pcall(function()
    art.size = math.max(32, source:GetWidth(), source:GetHeight())
    captureFrame(source, source, art, 0, 1)
  end)
  if ok and #art > 0 then return art end
end

-- Snapshots contain only public numbers, strings and tables. Idle settings pages
-- leave the existing mirrors alone unless a launcher actually changed its face.
local function same(a,b)
  if a==b then return true end
  if type(a)~="table" or type(b)~="table" then return false end
  for k,v in pairs(a) do if not same(v,b[k]) then return false end end
  for k in pairs(b) do if a[k]==nil then return false end end
  return true
end
Art.Same=same

local function position(region, reference, item)
  region:ClearAllPoints()
  region:SetSize(item.w, item.h)
  region:SetPoint("CENTER", reference, "CENTER", item.x, item.y)
end

local function paintTexture(region, item)
  if item.atlas then region:SetAtlas(item.atlas)
  elseif type(item.file) == "string" and item.file:match("^Color%-") then
    local r,g,b,a = item.file:match("^Color%-([%d%.]+)%-([%d%.]+)%-([%d%.]+)%-([%d%.]+)$")
    region:SetColorTexture(tonumber(r) or 1, tonumber(g) or 1, tonumber(b) or 1, tonumber(a) or 1)
  else region:SetTexture(item.file) end
  if #item.uv == 8 then region:SetTexCoord(unpack(item.uv)) else region:SetTexCoord(0,1,0,1) end
end

-- Pool the mirror's frames and regions, including masks, across reorders.
function Art.Draw(holder, art, fallback, label)
  local mirror = holder.mirror
  if not mirror then
    mirror = CreateFrame("Frame", nil, holder)
    mirror:EnableMouse(false); mirror:SetPoint("CENTER")
    mirror.planes, mirror.previous = {}, {}
    holder.mirror = mirror
  end
  local size = art and art.size or 32
  mirror:SetSize(size, size)
  mirror:SetScale(holder:GetWidth() / size)
  for _, region in ipairs(mirror.previous) do region:Hide() end
  mirror.previous = {}
  if not art then
    if fallback then
      art = {{file=fallback, x=0,y=0,w=28,h=28, uv={},color={},layer="ARTWORK",sub=0,level=0,alpha=1}}
    else
      local initials = (label or "?"):match("^%s*(%S+)") or "?"
      if #initials > 3 then initials = initials:gsub("[a-z]", "") end
      if initials == "" or #initials > 3 then initials = "?" end
      art = {{text=initials,x=0,y=0,w=32,h=32,font=STANDARD_TEXT_FONT,size=14,color={1,.84,.3,1},
        shadow={},offset={},justify="CENTER",vertical="MIDDLE",layer="ARTWORK",sub=0,level=0,alpha=1}}
    end
  end
  for i, item in ipairs(art) do
    local plane = mirror.planes[item.level]
    if not plane then
      plane = CreateFrame("Frame", nil, mirror)
      plane:EnableMouse(false); plane:SetAllPoints(); plane.regions = {}
      mirror.planes[item.level] = plane
    end
    plane:SetFrameLevel(math.max(0, mirror:GetFrameLevel()+item.level))
    local key = (item.text and "f" or "t") .. i
    local r = plane.regions[key]
    if not r then
      r = item.text and plane:CreateFontString(nil,item.layer) or plane:CreateTexture(nil,item.layer)
      plane.regions[key] = r
    end
    r:SetDrawLayer(item.layer, item.sub)
    position(r, mirror, item)
    if item.text then
      r:SetFont(item.font, item.size, item.flags or "")
      r:SetJustifyH(item.justify); r:SetJustifyV(item.vertical); r:SetWordWrap(false)
      if #item.color == 4 then r:SetTextColor(unpack(item.color)) else r:SetTextColor(1,1,1,1) end
      r:SetText(item.text)
      if #item.shadow==4 then r:SetShadowColor(unpack(item.shadow)) else r:SetShadowColor(0,0,0,0) end
      if #item.offset==2 then r:SetShadowOffset(unpack(item.offset)) else r:SetShadowOffset(0,0) end
    else
      paintTexture(r, item)
      if #item.color==4 then r:SetVertexColor(unpack(item.color)) else r:SetVertexColor(1,1,1,1) end
      r:SetBlendMode(item.blend or "BLEND"); r:SetDesaturation(item.desaturation or 0)
      r:SetRotation(item.rotation or 0)
      r.masks = r.masks or {}
      for j, maskData in ipairs(item.masks or {}) do
        local mask = r.masks[j]
        if not mask then mask=plane:CreateMaskTexture(); r.masks[j]=mask end
        if j > (r.maskCount or 0) then r:AddMaskTexture(mask) end
        paintTexture(mask, maskData); position(mask, mirror, maskData)
      end
      local count = item.masks and #item.masks or 0
      for j=count+1,r.maskCount or 0 do r:RemoveMaskTexture(r.masks[j]) end
      r.maskCount = count
    end
    r:SetAlpha(item.alpha)
    r:Show()
    mirror.previous[#mirror.previous+1] = r
  end
end
