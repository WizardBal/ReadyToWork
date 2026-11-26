local _, Helper = ...
local Fan = Helper.FanLayout

-- ReadyToWork's one minimap button. Left-click fans out the other addons' minimap buttons (or, with the fan
-- off, opens the settings window); right-click opens the quick menu; Shift-click opens the settings window.
-- Drag moves it around the minimap (round or square); the mouse wheel pages through the fan.
--
-- The fan was the separate addon MinimapFan (0.2.2) until ReadyToWork 1.24.0, and had its own blue bag until
-- 1.50.0, when it and ReadyToWork's brown settings bag became this one button. Its settings are
-- ReadyToWorkDB.minimapFan; the button's are ReadyToWorkDB.minimap (shown, locked). /minifan and /mmfan
-- still work (as do /rtw fan and /rtw minimap).

local entries, byButton = {}, {}
local visible = {}          -- every collected button that is currently shown by its addon
local shown = {}            -- the buttons on the current page, in fan order
local db, buttonDb, launcher, launcherGlow, menu, escapeFrame, badge, badgeText, pageText
local page, ready, pending, changing = 1, false, false, false
local buttonRevision = 0
local apply, refresh, scan, open, close, toggle, syncDriverUpdate
local lastDrag = -1
local dragging, escapePending = false, false

-- Fan motion. Slots travel from the launcher to their place and back.
local OPEN_TIME, CLOSE_TIME, STAGGER = 0.24, 0.12, 0.02
local HOVER_SCALE, AWAY_DELAY = 1.16, 1.25
local motion = { state = "closed", elapsed = 0, away = 0, fromX = 0, fromY = 0 }

-- Nicer names for a few buttons. Discovery itself does not depend on this list.
local known = {
    BalSCTMinimapButton = "BalSCT",
    -- (BalMaxSpells has no button of its own: it is part of ReadyToWork's menu)
    WhisperMessengerMinimapIcon = "Whisper Messenger",
    ForeverArtisanMinimapButton = "ForeverArtisan",
}

-- Used only when the client cannot say who created a frame.
local BLIZZARD_PREFIXES = {
    "Minimap", "MiniMap", "GameTime", "TimeManager", "QueueStatus", "LFG", "Expansion",
    "Garrison", "AddonCompartment", "Tracking",
}

local function combat() return InCombatLockdown() end
-- Whether the fan collects buttons: switched on, its button shown, and no separate MinimapFan addon running.
local function Active()
    return db ~= nil and db.enabled and not Helper.fanStandsDown and (buttonDb == nil or buttonDb.enabled ~= false)
end
local function restriction(frame, method)
    local check = frame[method]
    if not check then return false end
    local value = check(frame)
    if issecretvalue and issecretvalue(value) then return nil end
    return value == true
end
local function readable(frame)
    return frame and restriction(frame, "IsForbidden") == false
end
local function safe(frame)
    return readable(frame) and restriction(frame, "IsProtected") == false
end
local function checkFan(checkFrame)
    if not checkFrame(menu) or not checkFrame(launcher) or not checkFrame(escapeFrame) then return false end
    for _, entry in ipairs(entries) do
        if not checkFrame(entry.slot) or (entry.active and not checkFrame(entry.button)) then return false end
    end
    return true
end
local function safeFan() return checkFan(safe) end
local function say(message)
    Helper.Print(message)
end
local function library(name)
    if LibStub then return LibStub(name, true) end
end
local function later()
    if not ready or pending then return end
    pending = true
    C_Timer.After(0, function()
        pending = false
        refresh()
    end)
end

local function positionLauncher()
    if not safe(launcher) then return end
    local a = math.rad(db.angle)
    local x, y = math.cos(a), math.sin(a)
    local w, h = Minimap:GetWidth() / 2 + 6, Minimap:GetHeight() / 2 + 6
    if GetMinimapShape and GetMinimapShape() == "SQUARE" then
        local divisor = math.max(math.abs(x), math.abs(y))
        x, y = x / divisor, y / divisor
    end
    launcher:ClearAllPoints()
    launcher:SetPoint("CENTER", Minimap, "CENTER", x * w, y * h)
end

local function setLauncherActive(active)
    if launcherGlow and safe(launcher) then launcherGlow:SetShown(active) end
end

-- Position a slot inside the menu. Offsets are divided by the slot's scale
-- because anchor offsets are measured in the scaled frame's own units.
local function place(entry, x, y, scale, alpha)
    local slot = entry.slot
    slot:SetScale(scale)
    slot:ClearAllPoints()
    slot:SetPoint("CENTER", menu, "BOTTOMLEFT", x / scale, y / scale)
    slot:SetAlpha(alpha)
end

local function pointerInside()
    return launcher:IsMouseOver() or menu:IsMouseOver(10, -10, -10, 10)
end

-- A context menu opened from a collected icon keeps the fan open.
local function menuBusy()
    local manager = Menu and Menu.GetManager and Menu.GetManager()
    if manager and manager.GetOpenMenu and manager:GetOpenMenu() then return true end
    for _, name in ipairs({ "DropDownList1", "L_DropDownList1", "LibDropDownMenu_List1" }) do
        local list = _G[name]
        if list and list:IsShown() then return true end
    end
    return false
end

local function animate(_, dt)
    if not safeFan() then return end
    local state, count = motion.state, #shown
    if state == "opening" or state == "closing" then
        motion.elapsed = motion.elapsed + dt
    end

    local settled = true
    for index, entry in ipairs(shown) do
        local t = 1
        if state == "opening" then
            t = Fan.Clamp((motion.elapsed - (index - 1) * STAGGER) / OPEN_TIME, 0, 1)
            settled = settled and t >= 1
        elseif state == "closing" then
            t = 1 - Fan.Clamp((motion.elapsed - (count - index) * STAGGER * 0.5) / CLOSE_TIME, 0, 1)
            settled = settled and t <= 0
        end

        local hovered = state == "open" and entry.slot:IsMouseOver()
        local goal = hovered and HOVER_SCALE or 1
        -- Open and at rest (not growing or shrinking under the pointer): nothing to move, so it isn't placed
        -- again every frame. (Before 1.30 an open fan re-placed every icon on every frame.)
        if not (state == "open" and entry.rest and math.abs(goal - entry.grow) < 0.002) then
            entry.grow = entry.grow + (goal - entry.grow) * math.min(1, dt * 16)
            local travel = state == "opening" and Fan.EaseOutBack(t) or Fan.EaseOutCubic(t)
            place(entry,
                motion.fromX + (entry.x - motion.fromX) * travel,
                motion.fromY + (entry.y - motion.fromY) * travel,
                (0.55 + 0.45 * t) * entry.grow,
                Fan.Clamp(t * 1.8, 0, 1))
            entry.rest = state == "open" and math.abs(goal - entry.grow) < 0.002
        end
    end

    if state == "opening" and settled then
        motion.state, motion.away = "open", 0
    elseif state == "closing" and settled then
        menu:Hide()
    elseif state == "open" and db.autoClose then
        if pointerInside() or menuBusy() or IsMouseButtonDown() then
            motion.away = 0
        else
            motion.away = motion.away + dt
            if motion.away >= AWAY_DELAY then close() end
        end
    end
end

open = function()
    if not Active() or #shown == 0 or not safeFan() then return end
    motion.state, motion.elapsed, motion.away = "opening", 0, 0
    for _, entry in ipairs(shown) do
        entry.grow, entry.rest = 1, nil
        place(entry, motion.fromX, motion.fromY, 0.55, 0)
    end
    setLauncherActive(true)
    menu:Show()
    escapeFrame:Show()
    if syncDriverUpdate then syncDriverUpdate() end
end

close = function(instant)
    if not safeFan() or not menu:IsShown() then return end
    if instant or #shown == 0 then
        menu:Hide()
    elseif motion.state ~= "closing" then
        motion.state, motion.elapsed = "closing", 0
        setLauncherActive(false)
    end
end

-- Keep the actual button: no synthetic clicks, copied scripts or secure actions.
apply = function(entry)
    local button = entry.button
    if changing or not entry.active or combat() or not safe(button) or not safe(entry.slot) or not safe(menu) then return end
    changing = true
    -- LibDBIcon fixes both layers on the minimap. Let them follow the fan when it is raised.
    if button:HasFixedFrameLevel() then button:SetFixedFrameLevel(false) end
    if button:HasFixedFrameStrata() then button:SetFixedFrameStrata(false) end
    if button:GetParent() ~= entry.slot then button:SetParent(entry.slot) end
    button:ClearAllPoints()
    button:SetPoint("CENTER", entry.slot, "CENTER")
    button:SetFrameStrata("DIALOG")
    button:SetFrameLevel(entry.slot:GetFrameLevel() + 2)
    button:SetScale(32 / math.max(button:GetWidth(), button:GetHeight(), 32))
    button:SetScript("OnDragStart", nil)
    button:SetScript("OnDragStop", nil)
    if button.showOnMouseover then entry.mouseover = button.showOnMouseover end
    button.showOnMouseover = false
    if button.fadeOut then button.fadeOut:Stop() end
    button:SetAlpha(1)
    changing = false
end

local function restore(entry)
    -- A collected button can become protected. Restore it once combat ends so it
    -- can stay on its owner's minimap and the ordinary fan can be used again.
    if not entry.active or combat() or not readable(entry.button) or not readable(entry.slot) or not readable(entry.parent)
        or restriction(entry.button, "IsProtected") == nil then return end
    entry.active = false
    local button = entry.button
    button:SetParent(entry.parent)
    button:ClearAllPoints()
    for _, point in ipairs(entry.points) do button:SetPoint(unpack(point)) end
    button:SetScale(entry.scale)
    button:SetFrameStrata(entry.strata)
    button:SetFrameLevel(entry.level)
    button:SetFixedFrameStrata(entry.fixedStrata)
    button:SetFixedFrameLevel(entry.fixedLevel)
    button:SetScript("OnDragStart", entry.dragStart)
    button:SetScript("OnDragStop", entry.dragStop)
    button.showOnMouseover = entry.mouseover
    button:SetAlpha(entry.alpha)
    entry.slot:Hide()
end

-- Frames that addon launchers are normally parented to.
local function homes()
    local list = { Minimap }
    if MinimapBackdrop then list[#list + 1] = MinimapBackdrop end
    if MinimapCluster then
        list[#list + 1] = MinimapCluster
        if MinimapCluster.MinimapContainer then list[#list + 1] = MinimapCluster.MinimapContainer end
    end
    return list
end

local function isHome(frame)
    for _, home in ipairs(homes()) do
        if frame == home then return true end
    end
    return false
end

-- The game marks a global as secure when its own code created it, and names
-- the addon otherwise. That separates Blizzard's minimap buttons from addons'.
local function creator(name)
    if issecurevariable then
        local ok, secure, addon = pcall(issecurevariable, name)
        if ok then return secure, addon end
    end
    for _, prefix in ipairs(BLIZZARD_PREFIXES) do
        if name:find("^" .. prefix) then return true end
    end
    return false
end

local function cleanTitle(text)
    return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):match("^%s*(.-)%s*$"))
end

local function labelFor(button, name)
    if known[name] then return known[name] end
    local _, addon = creator(name)
    if type(addon) == "string" and addon ~= "" then
        local metadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
        local ok, title = pcall(metadata, addon, "Title")
        if ok and type(title) == "string" and cleanTitle(title) ~= "" then return cleanTitle(title) end
        return addon
    end
    local label = name:gsub("^LibDBIcon10_", ""):gsub("[Mm]ini[Mm]ap", ""):gsub("Button$", ""):gsub("Icon$", ""):gsub("_", " ")
    label = label:match("^%s*(.-)%s*$")
    return label ~= "" and label or name
end

-- Any named, icon-sized, clickable button an addon has put on the minimap.
-- Map pins are smaller, unnamed or numbered, so they are left alone.
local function looksLikeLauncher(button)
    if not safe(button) or not button.IsObjectType or not button:IsObjectType("Button") then return false end
    if button == launcher then return false end
    local name = button:GetName()
    if type(name) ~= "string" or name == "" or db.ignored[name] then return false end
    local entry = byButton[button]
    if entry and entry.active then return false end
    if name:find("%d$") and not name:find("^LibDBIcon10_") then return false end
    local width, height = button:GetWidth(), button:GetHeight()
    if width < 22 or height < 22 or width > 48 or height > 48 then return false end
    if not (button:GetScript("OnClick") or button:GetScript("OnMouseUp") or button:GetScript("OnMouseDown")) then
        return false
    end
    return not creator(name)
end

local function buttonTexture(button)
  local function texture(region)
    if (type(region) == "table" or type(region) == "userdata") and type(region.GetTexture) == "function" then return region:GetTexture() end
  end
  local icon = texture(button.icon) or texture(button.Icon) or texture(button:GetNormalTexture())
  if icon then return icon end
  for _, region in ipairs({button:GetRegions()}) do
    if region:IsObjectType("Texture") and region:GetDrawLayer() == "ARTWORK" then
      icon = texture(region)
      if icon then return icon end
    end
  end
end

local function attach(button, label)
    if not safe(button) or not button.IsObjectType or not button:IsObjectType("Button") then return end
    if button == launcher or button:GetWidth() > 80 or button:GetHeight() > 80 then return end
    local name = button:GetName()
    if name and db.ignored[name] then return end
    local entry = byButton[button]
    if entry and entry.active then return end
    -- A different launcher may already own this icon. Leave its container alone.
    if not isHome(button:GetParent()) then return end
    if not entry then
        entry = { button = button, name = name, label = label, grow = 1, x = 0, y = 0 }
        byButton[button] = entry
        entries[#entries + 1] = entry
        entry.slot = CreateFrame("Frame", nil, menu)
        entry.slot:SetSize(Fan.SLOT_SIZE, Fan.SLOT_SIZE)
        entry.slot:SetFrameStrata("DIALOG")
        entry.slot:SetFrameLevel(menu:GetFrameLevel() + 1)
        entry.slot:Hide()
        for _, method in ipairs({ "SetPoint", "ClearAllPoints", "SetParent", "SetScale", "SetFrameStrata", "SetFrameLevel" }) do
            hooksecurefunc(button, method, function() apply(entry) end)
        end
        hooksecurefunc(button, "SetScript", function(_, script, handler)
            if changing or not entry.active then return end
            if script == "OnDragStart" then entry.dragStart = handler; apply(entry)
            elseif script == "OnDragStop" then entry.dragStop = handler; apply(entry) end
        end)
        hooksecurefunc(button, "SetAlpha", function(_, alpha)
            if changing or not entry.active then return end
            entry.alpha = alpha
            apply(entry)
        end)
        button:HookScript("OnShow", later)
        button:HookScript("OnHide", later)
        button:HookScript("OnClick", function(_, mouse)
            -- Leave right-click menus open; their parent may be the original icon.
            if entry.active and mouse == "LeftButton" then C_Timer.After(0, function() close() end) end
        end)
    end
    local ok, texture = pcall(buttonTexture, button)
    entry.previewIcon = ok and (not issecretvalue or not issecretvalue(texture)) and texture or nil
    entry.parent, entry.scale = button:GetParent(), button:GetScale()
    entry.strata, entry.level = button:GetFrameStrata(), button:GetFrameLevel()
    entry.fixedStrata, entry.fixedLevel = button:HasFixedFrameStrata(), button:HasFixedFrameLevel()
    entry.alpha, entry.mouseover = button:GetAlpha(), button.showOnMouseover
    entry.dragStart, entry.dragStop = button:GetScript("OnDragStart"), button:GetScript("OnDragStop")
    entry.points = {}
    for i = 1, button:GetNumPoints() do entry.points[i] = { button:GetPoint(i) } end
    entry.active = true
    apply(entry)
end

local hookedLib
scan = function()
    if not ready or not Active() or combat() then return end
    local lib = library("LibDBIcon-1.0")
    if lib then
        if lib.RegisterCallback and lib ~= hookedLib then
            lib.RegisterCallback(Fan, "LibDBIcon_IconCreated", function() later() end)
            hookedLib = lib
        end
        for _, name in ipairs(lib:GetButtonList()) do
            attach(lib:GetMinimapButton(name), name)
        end
    end
    for name, label in pairs(known) do attach(_G[name], label) end
    -- Everything else: whatever addons have placed on the minimap themselves.
    for _, home in ipairs(homes()) do
        for _, child in ipairs({ home:GetChildren() }) do
            local ok, wanted = pcall(looksLikeLauncher, child)
            if ok and wanted then
                local name = child:GetName()
                attach(child, labelFor(child, name))
            end
        end
    end
end

-- Where the launcher and the minimap are, in UIParent units.
local viewport, presentedView
local function geometry()
    if not readable(launcher) or not readable(Minimap) then return end
    local x, y = launcher:GetCenter()
    local mapX, mapY = Minimap:GetCenter()
    if not x or not y then return end
    local ui = UIParent:GetEffectiveScale()
    local scale, mapScale = launcher:GetEffectiveScale() / ui, Minimap:GetEffectiveScale() / ui
    x, y = x * scale, y * scale
    if mapX and mapY then mapX, mapY = mapX * mapScale, mapY * mapScale else mapX, mapY = nil, nil end
    local radius = math.max(Minimap:GetWidth(), Minimap:GetHeight()) / 2 * mapScale
    if GetMinimapShape and GetMinimapShape() == "SQUARE" then radius = radius * 1.3 end
    local width, height = UIParent:GetWidth(), UIParent:GetHeight()
    if not viewport or viewport.x ~= x or viewport.y ~= y or viewport.mapX ~= mapX or viewport.mapY ~= mapY
        or viewport.width ~= width or viewport.height ~= height or viewport.radius ~= radius then
        viewport = {x=x, y=y, mapX=mapX, mapY=mapY, radius=radius, width=width, height=height}
    end
    return viewport
end

function Helper.FanView()
    return geometry(), page, buttonRevision, launcher
end

local function collect()
    if combat() then return end
    for _, entry in ipairs(entries) do
        if entry.active and (not Active() or db.ignored[entry.name] or not safe(entry.button)) then restore(entry) end
    end
    if Active() and safeFan() then
        scan()
        for _, entry in ipairs(entries) do apply(entry) end
    end
end

local function present()
    for _, entry in ipairs(shown) do entry.rest = nil end   -- (laid out again: placed again)
    if not Active() then
        close(true)
        if #visible > 0 then buttonRevision = buttonRevision + 1 end
        visible, shown = {}, {}
        pageText:SetText("")
        return
    end
    local previous = visible
    visible = {}
    for _, entry in ipairs(entries) do
        if entry.active and not db.ignored[entry.name] and entry.button:IsShown() then
            visible[#visible + 1] = entry
        end
    end
    local ranks={}
    for rank,key in ipairs(db.order) do ranks[key]=rank end
    table.sort(visible,function(a,b)
      local x,y=ranks[a.name or a.label] or math.huge,ranks[b.name or b.label] or math.huge
      if x~=y then return x<y end
      if a.label:lower() ~= b.label:lower() then return a.label:lower() < b.label:lower() end
      return (a.name or a.label) < (b.name or b.label)
    end)
    if #previous ~= #visible then
        buttonRevision = buttonRevision + 1
    else
        for i, entry in ipairs(visible) do
            if entry ~= previous[i] then buttonRevision = buttonRevision + 1; break end
        end
    end
    local pages, first, count
    page, pages, first, count = Fan.PageRange(#visible, db.pageSize, page)
    local view = geometry()
    presentedView = view
    if not view then return end
    local points, originX, originY, left, right, bottom, top = Fan.LayoutInView(count, view, db.style)
    menu:ClearAllPoints()
    menu:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", originX + left, originY + bottom)
    menu:SetSize(right - left, top - bottom)
    motion.fromX, motion.fromY = view.x - originX - left, view.y - originY - bottom

    shown = {}
    local onPage = {}
    for i, point in ipairs(points) do
        local entry = visible[first + i - 1]
        shown[i], onPage[entry] = entry, true
        entry.x, entry.y = point[1] - left, point[2] - bottom
        if not entry.slot:IsShown() then
            entry.grow = 1
            place(entry, motion.fromX, motion.fromY, 0.55, 0)
        end
        entry.slot:Show()
    end
    for _, entry in ipairs(entries) do
        if not onPage[entry] then entry.slot:Hide() end
    end
    pageText:SetText(pages > 1 and (page .. "/" .. pages) or "")
    if #shown == 0 then close(true) end
end

refresh = function()
    if not ready then return false end
    if not combat() and checkFan(readable) then collect() end
    if not safeFan() then return false end
    if escapePending then
        escapePending = false
        close(true)
    end
    present()
    return true
end

toggle = function()
    if not Active() then Helper.OpenSettings(); return end
    if not safeFan() or not menu:IsShown() or motion.state == "closing" then
        if not refresh() then return end
    end
    if menu:IsShown() and motion.state ~= "closing" then close(); return end
    if #visible == 0 then
        say(combat() and "No collected buttons are available. The fan will check for buttons after combat."
            or "No supported addon buttons found. Right-click to check again.")
        return
    end
    if GameTooltip:IsOwned(launcher) then GameTooltip:Hide() end
    open()
end

local function updateBadge()
    if not safe(badge) or not safe(launcher) then return end
    local broker = library("LibDataBroker-1.1")
    local object = broker and broker:GetDataObjectByName("WhisperMessenger")
    local count = object and tonumber(object.unread) or 0
    if not count or count < 0 then count = 0 end
    -- Only mirror notifications while we actually own WhisperMessenger's icon.
    local entry = byButton[_G.WhisperMessengerMinimapIcon]
    local show = Active() and entry and entry.active and safe(entry.button) and entry.button:IsShown() and count > 0
    badge:SetShown(not not show)
    badgeText:SetText(count > 99 and "99+" or tostring(math.floor(count)))
    if show then
        badge:SetAlpha(0.75 + 0.25 * math.sin(GetTime() * 4))
    end
    if syncDriverUpdate then syncDriverUpdate() end
end

local function stopDragging()
    if not dragging then return end
    dragging = false
    lastDrag = GetTime()
    if safe(launcher) then launcher:SetScript("OnUpdate", nil) end
end

local function build()
    menu = CreateFrame("Frame", "MinimapFanMenu", UIParent)
    menu:SetFrameStrata("DIALOG")
    menu:SetFrameLevel(100)
    menu:Hide()
    menu:SetScript("OnUpdate", animate)
    -- Escape hides a separate ordinary frame. It cannot bypass the fan's
    -- protection check if an owning addon changes a collected button.
    escapeFrame = CreateFrame("Frame", "MinimapFanEscapeFrame", UIParent)
    escapeFrame:Hide()
    escapeFrame:SetScript("OnHide", function()
        if safeFan() then close(true) else escapePending = true end
    end)
    tinsert(UISpecialFrames, "MinimapFanEscapeFrame")
    menu:SetScript("OnShow", function()
        if syncDriverUpdate then syncDriverUpdate() end
    end)
    menu:SetScript("OnHide", function()
        motion.state = "closed"
        if safe(escapeFrame) and escapeFrame:IsShown() then escapeFrame:Hide() end
        setLauncherActive(false)
        if syncDriverUpdate then syncDriverUpdate() end
    end)

    launcher = CreateFrame("Button", "ReadyToWorkMinimapButton", Minimap)
    launcher:SetSize(32, 32)
    launcher:SetFrameStrata("HIGH")
    launcher:SetFrameLevel(30)
    launcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    launcher:RegisterForDrag("LeftButton")
    launcher:EnableMouseWheel(true)
    launcher:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local bg = launcher:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(24, 24)
    bg:SetPoint("CENTER", 0, 1)
    local icon = launcher:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\AddOns\\ReadyToWork\\Media\\icon_rtw.png")
    icon:SetTexCoord(0, 1, 0, 1)
    icon:SetSize(25, 25)
    icon:SetPoint("CENTER", 0, 1)
    if launcher.CreateMaskTexture and icon.AddMaskTexture then
        local ok, mask = pcall(launcher.CreateMaskTexture, launcher)
        if ok and mask then
            mask:SetTexture("Interface\\AddOns\\ReadyToWork\\Media\\circle.png", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
            mask:SetAllPoints(icon)
            icon:AddMaskTexture(mask)
        end
    end
    local border = launcher:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    -- Stays lit while the fan is open.
    launcherGlow = launcher:CreateTexture(nil, "OVERLAY", nil, 1)
    launcherGlow:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    launcherGlow:SetBlendMode("ADD")
    launcherGlow:SetAllPoints(launcher)
    launcherGlow:Hide()
    pageText = launcher:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pageText:SetPoint("BOTTOM", 0, -7)
    badge = CreateFrame("Frame", nil, launcher, "BackdropTemplate")
    badge:SetSize(24, 16)
    badge:SetPoint("TOPRIGHT", 8, 5)
    badge:SetFrameLevel(launcher:GetFrameLevel() + 5)
    badge:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    badge:SetBackdropColor(0.65, 0.06, 0.1, 1)
    badge:SetBackdropBorderColor(1, 0.65, 0.65, 1)
    badgeText = badge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    badgeText:SetPoint("CENTER")
    badge:Hide()
    launcher:SetScript("OnClick", function(_, mouse)
        if GetTime() - lastDrag < 0.2 then return end
        if mouse == "RightButton" then
            close(true)
            Helper.ShowMenu()
        elseif IsShiftKeyDown() or not Active() then
            close(true)
            Helper.OpenSettings()
        else
            toggle()
        end
    end)
    launcher:SetScript("OnMouseWheel", function(_, delta)
        if not Active() then return end
        local previous = page
        page = page - delta
        if not refresh() then page = previous; return end
        if #visible == 0 then return end
        -- Fan the new page out; an unchanged page only opens a closed fan.
        if page ~= previous or not menu:IsShown() or motion.state == "closing" then open() end
    end)
    launcher:SetScript("OnDragStart", function(self)
        if not safe(self) or (buttonDb and buttonDb.locked) then return end
        close(true)
        dragging = true
        self:SetScript("OnUpdate", function()
            if not dragging or not safe(launcher) then return end
            local mx, my = Minimap:GetCenter()
            if not mx or not my then return end
            local x, y = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            db.angle = math.deg(Fan.Atan2(y / scale - my, x / scale - mx)) % 360
            positionLauncher()
        end)
    end)
    launcher:SetScript("OnDragStop", function()
        stopDragging()
        later()
    end)
    launcher:SetScript("OnEnter", function(self)
        if menu:IsShown() then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("ReadyToWork")
        if Active() then
            GameTooltip:AddLine("Left-click: open or close the fan of minimap buttons", 1, 1, 1)
            GameTooltip:AddLine("Mouse wheel: next page of the fan", 1, 1, 1)
        else
            GameTooltip:AddLine("Left-click: settings window", 1, 1, 1)
        end
        GameTooltip:AddLine("Right-click: quick menu", 1, 1, 1)
        GameTooltip:AddLine("Shift-click: settings window", 1, 1, 1)
        if buttonDb and buttonDb.locked then
            GameTooltip:AddLine("Locked in place (unlock it on the Minimap buttons page)", 0.8, 0.8, 0.8)
        else
            GameTooltip:AddLine("Drag: move around the minimap", 1, 1, 1)
        end
        if badge:IsShown() then GameTooltip:AddLine("Whisper Messenger has unread messages", 1, 0.55, 0.55) end
        GameTooltip:Show()
    end)
    launcher:SetScript("OnLeave", function(self)
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
    positionLauncher()
end

-- A click on the game world closes the fan. Clicks on other interface frames
-- are left alone because they may belong to a menu opened from an icon.
local function worldClicked()
    if not safeFan() or not menu:IsShown() or motion.state == "closing" or pointerInside() or menuBusy() then
        return false
    end
    if GetMouseFoci then
        local focus = GetMouseFoci()[1]
        return focus == nil or focus == WorldFrame
    end
    return GetMouseFocus and GetMouseFocus() == WorldFrame or false
end

local hookedLDB
local function hookLDB()
    local broker = library("LibDataBroker-1.1")
    if broker and broker.RegisterCallback and broker ~= hookedLDB then
        hookedLDB = broker
        broker.RegisterCallback(Fan, "LibDataBroker_AttributeChanged_WhisperMessenger_unread", function()
            if ready then updateBadge() end
        end)
        broker.RegisterCallback(Fan, "LibDataBroker_DataObjectCreated", function(_, name)
            if ready and name == "WhisperMessenger" then updateBadge() end
        end)
    end
end

local driver = CreateFrame("Frame")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
driver:RegisterEvent("ADDON_LOADED")
pcall(driver.RegisterEvent, driver, "GLOBAL_MOUSE_DOWN")
driver:SetScript("OnEvent", function(_, event, name)
    if event == "GLOBAL_MOUSE_DOWN" then
        if ready and worldClicked() then close() end
    elseif ready then
        if event == "ADDON_LOADED" or event == "PLAYER_ENTERING_WORLD" then
            hookLDB()
            updateBadge()
        end
        if event == "PLAYER_REGEN_ENABLED" then
            if not dragging and safe(launcher) and launcher:GetScript("OnUpdate") then launcher:SetScript("OnUpdate", nil) end
            positionLauncher()
        end
        later()
    end
end)
-- Active only while the fan menu or unread badge is shown (zero idle OnUpdate cost).
local elapsed = 0
local function driverOnUpdate(_, dt)
    if not ready then return end
    elapsed = elapsed + dt
    local busy = menu:IsShown() or (badge ~= nil and badge:IsShown())
    if not busy then
        syncDriverUpdate()
        return
    end
    if elapsed < 0.25 then return end
    elapsed = 0
    if menu:IsShown() and geometry() ~= presentedView and safeFan() then present() end
    updateBadge()
end
syncDriverUpdate = function()
    if not ready or not menu then
        driver:SetScript("OnUpdate", nil)
        return
    end
    if menu:IsShown() or (badge ~= nil and badge:IsShown()) then
        elapsed = 0
        driver:SetScript("OnUpdate", driverOnUpdate)
    else
        driver:SetScript("OnUpdate", nil)
    end
end

-- (Set when the separate MinimapFan addon is still loaded: this fan then stays off, and says why when asked.)
local standsDown
local STANDS_DOWN = "The separate MinimapFan addon is still loaded, so ReadyToWork's minimap fan stays off. Remove MinimapFan from AddOns and /reload to use this one."

local function fanCommand(message)
    if standsDown then say(STANDS_DOWN) return end
    if not ready then return end
    local text = (message or ""):match("^%s*(.-)%s*$")
    local command, argument = text:match("^(%S*)%s*(.-)$")
    command = command:lower()
    if command == "help" then
        say("Click to open; drag to move; Escape to close; wheel over the launcher for more pages.")
        say("/minifan (or /rtw fan) reset | off | on | scan | status | autoclose. Off restores the original addon buttons.")
        say("/minifan list shows what was collected. /minifan ignore <name> leaves a button on the minimap; /minifan include <name> takes it back.")
    elseif command=="customize" then Helper.OpenSettings("Minimap fan")
    elseif command == "list" then
        for _, entry in ipairs(entries) do
            if entry.active then
                say(entry.label .. "  |cff808080" .. (entry.name or "unnamed") .. "|r")
            end
        end
        for name in pairs(db.ignored) do say("Ignored: " .. name) end
    elseif command == "status" then
        say("ReadyToWork " .. Helper.version .. "; minimap fan " .. (db.enabled and "enabled" or "disabled") .. "; auto-close "
            .. (db.autoClose and "on" or "off") .. "; " .. #visible .. " visible buttons.")
        for _, entry in ipairs(visible) do say(entry.label) end
    elseif command == "autoclose" then
        db.autoClose = not db.autoClose
        say("The fan " .. (db.autoClose and "closes by itself when the pointer leaves it." or "stays open until you close it."))
    elseif command == "off" then
        db.enabled = false; refresh(); updateBadge()
        say(combat() and "The fan is off. Original buttons will be restored after combat."
            or "The fan is off. /minifan on to collect buttons again.")
    elseif command == "on" or command == "scan" then
        db.enabled = true; refresh()
        if command == "scan" then
            say(combat() and "Buttons will refresh after combat." or (#visible .. " buttons collected."))
        end
    elseif command == "ignore" then
        local wanted, found = argument:lower(), nil
        for _, entry in ipairs(entries) do
            local name = entry.name
            if entry.active and name and wanted ~= "" and (name:lower() == wanted or entry.label:lower() == wanted) then
                found = entry
            end
        end
        if found then
            db.ignored[found.name] = true
            close(true); refresh()
            say(found.label .. (combat() and " will return to the minimap after combat." or " is excluded from the fan."))
        else
            say("No collected button is called '" .. argument .. "'. /minifan list shows the names.")
        end
    elseif command == "include" then
        local wanted, found = argument:lower(), nil
        for name in pairs(db.ignored) do
            if name:lower() == wanted then found = name end
        end
        if found then
            db.ignored[found] = nil
            refresh()
            say(found .. " will be collected again.")
        else
            say("'" .. argument .. "' is not on the ignore list. /minifan list shows it.")
        end
    elseif command == "reset" then
        close(true); db.angle = 225; page = 1; positionLauncher(); refresh()
    elseif command == "" then
        toggle()
    else
        say("Use /minifan help for controls.")
    end
end

-- Shows or hides the button as ReadyToWorkDB.minimap says. Hidden, the fan gives its buttons back.
function Helper.RefreshLauncher()
    if not ready or not safe(launcher) then return end
    launcher:SetShown(buttonDb.enabled ~= false)
    if buttonDb.enabled == false then close(true) end
    later()
end

-- Every button the fan has found, and those left on the minimap by choice: { key, label, ignored, active }.
function Helper.FanEntries()
    local list, seen = {}, {}
    for _, entry in ipairs(entries) do
        local key = entry.name or entry.label
        if key and not seen[key] then
            seen[key] = true
            list[#list + 1] = { key = key, label = entry.label, ignored = db.ignored[key] == true, active = entry.active }
        end
    end
    for name in pairs(db and db.ignored or {}) do
        if not seen[name] then list[#list + 1] = { key = name, label = name, ignored = true, active = false } end
    end
    table.sort(list, function(a, b)
        if a.label:lower() ~= b.label:lower() then return a.label:lower() < b.label:lower() end
        return a.key < b.key
    end)
    return list
end

-- Leaves a button on the minimap (or takes it back into the fan).
function Helper.SetFanIgnored(key, ignored)
    if not db then return end
    db.ignored[key] = ignored and true or nil
    if ready then close(true); later() end
end

function Helper.SetFanPage(requested)
  page = Fan.PageRange(#visible, db.pageSize, requested)
  if ready and safeFan() then present() end
end

function Helper.FanButtons(cachedOnly)
  if not cachedOnly and ready and not combat() then refresh() end
  local list, ranks = {}, {}
  for rank, key in ipairs(db and db.order or {}) do ranks[key] = rank end
  for _, entry in ipairs(visible) do
    list[#list + 1] = {key = entry.name or entry.label, label = entry.label, button = entry.button, icon = entry.previewIcon}
  end
  table.sort(list, function(a,b)
    local x,y = ranks[a.key] or math.huge, ranks[b.key] or math.huge
    if x ~= y then return x < y end
    if a.label:lower() ~= b.label:lower() then return a.label:lower() < b.label:lower() end
    return a.key < b.key
  end)
  return list
end

function Helper.PlaceFanButton(key, targetKey)
  if not ready or key == targetKey then return end
  local list = Helper.FanButtons()
  local from, to, activeKeys = nil, nil, {}
  for index, entry in ipairs(list) do
    activeKeys[entry.key] = true
    if entry.key == key then from = index end
    if entry.key == targetKey then to = index end
  end
  if not from or not to then return end
  table.insert(list, to, table.remove(list, from))
  local order, index = {}, 1
  for _, saved in ipairs(db.order) do
    if not activeKeys[saved] then
      order[#order + 1] = saved
    elseif list[index] then
      order[#order + 1] = list[index].key
      index = index + 1
    end
  end
  for i = index, #list do order[#order + 1] = list[i].key end
  db.order = order
  Helper.RefreshFan()
end
function Helper.RefreshFan(reposition)
  if not combat() then
    if reposition and ready then positionLauncher() end
    later()
  elseif ready and safeFan() then
    present()
  end
end
Helper.commands.fan = function(rest)
    fanCommand(rest or "")
end
Helper.help[#Helper.help + 1] = "/rtw fan [on|off|reset|scan|list|status|autoclose] - the minimap button fan (also /minifan)"

Helper.Feature(function()
    -- Two fans would fight over the same buttons: while the separate MinimapFan addon is still loaded, this
    -- one stays off and says why.
    -- ReadyToWork's button is made either way: it opens the settings window and the quick menu.
    db, buttonDb = Helper.db.minimapFan, Helper.db.minimap
    local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded
    if isLoaded and isLoaded("MinimapFan") then
        -- (its /minifan stays its own: registered below only when this fan runs)
        standsDown = true
        Helper.fanStandsDown = true
        say(STANDS_DOWN)
    else
        SLASH_MINIMAPFAN1, SLASH_MINIMAPFAN2 = "/minifan", "/mmfan"
        SlashCmdList.MINIMAPFAN = fanCommand
    end
    if type(db.angle) ~= "number" or db.angle ~= db.angle or math.abs(db.angle) == math.huge then db.angle = 225 end
    db.angle = db.angle % 360
    if type(db.enabled) ~= "boolean" then db.enabled = true end
    if type(db.autoClose) ~= "boolean" then db.autoClose = true end
    if type(db.ignored) ~= "table" then db.ignored = {} end
    build()
    ready = true
    launcher:SetShown(buttonDb.enabled ~= false)
    hookLDB()
    updateBadge()
    later()
    C_Timer.After(3, later)
end)

Helper.commands.minimap = function(word)
    if not buttonDb then return end
    Helper.Toggle(buttonDb, word, "The minimap button is")
    Helper.RefreshLauncher()
    if buttonDb.enabled == false then
        Helper.Print("/rtw settings, /rtw menu and ReadyToWork's key bindings still open everything. /rtw minimap on brings the button back.")
    end
end
Helper.help[#Helper.help + 1] = "/rtw minimap [on|off] - show or hide the minimap button"
