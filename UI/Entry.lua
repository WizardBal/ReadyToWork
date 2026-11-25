-- Ways in from Blizzard's own interface: an entry in the game's Options > AddOns list, and key bindings
-- (Options > Keybindings > AddOns > ReadyToWork, declared in Bindings.xml) for the settings window, the quick
-- menu, unlock mode and the three Talk & quests switches.

local _, Helper = ...
local W = Helper.Widgets

BINDING_HEADER_READYTOWORK = "ReadyToWork"
BINDING_NAME_READYTOWORK_SETTINGS = "Open the settings window"
BINDING_NAME_READYTOWORK_MENU = "Open the quick menu"
BINDING_NAME_READYTOWORK_UNLOCK = "Unlock frames (move, resize, reset)"
BINDING_NAME_READYTOWORK_TALK_SKIP = "Switch Skip talk on or off"
BINDING_NAME_READYTOWORK_TALK_ACCEPT = "Switch Accept (quests) on or off"
BINDING_NAME_READYTOWORK_TALK_TURNIN = "Switch Turn in (quests) on or off"

-- Called by Bindings.xml.
function ReadyToWork_Binding(which)
  if not Helper.db then return end
  if which == "settings" then
    Helper.OpenSettings()
  elseif which == "menu" then
    Helper.ShowMenu()
  elseif which == "unlock" then
    Helper.commands.unlock()
  elseif type(which) == "string" and which:match("^talk ") and Helper.Talk then
    Helper.Talk.Flip(which:sub(6))
  end
end

local category

-- Opens the game's key bindings (ReadyToWork's are under AddOns).
function Helper.OpenKeyBindings()
  local id = Settings and Settings.KEYBINDINGS_CATEGORY_ID
  if id and Settings.OpenToCategory then
    local ok = pcall(Settings.OpenToCategory, id)
    if ok then return end
  end
  Helper.Print("Key bindings: Game Menu > Options > Keybindings > AddOns > ReadyToWork.")
end

local function BuildPanel()
  local panel = CreateFrame("Frame")
  panel:Hide()
  local icon = W.Icon(panel, "Interface\\Icons\\INV_Misc_Bag_10", 36)
  icon:SetPoint("TOPLEFT", 16, -16)
  local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 12, -2)
  title:SetText("ReadyToWork " .. Helper.version)
  local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  text:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -14)
  text:SetWidth(560)
  text:SetJustifyH("LEFT")
  text:SetText("ReadyToWork has its own settings window, with every helper's options, a search box and one Undo for every change. Open it here, with /rtw settings, or by Shift-clicking ReadyToWork's minimap button. Right-click that button for the quick menu.")
  -- (Blizzard's options panel is closed first, out of combat only, so ReadyToWork's window isn't hidden behind it)
  local function CloseOptions()
    if SettingsPanel and SettingsPanel.Close and not InCombatLockdown() then pcall(SettingsPanel.Close, SettingsPanel) end
  end
  local buttons = {
    { "Open ReadyToWork settings", function() CloseOptions(); Helper.OpenSettings("home") end },
    { "Unlock frames", function() CloseOptions(); Helper.commands.unlock() end },
    { "Key bindings", function() Helper.OpenKeyBindings() end },
  }
  local previous
  for _, info in ipairs(buttons) do
    local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    b:SetSize(200, 26)
    if previous then b:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -8) else b:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -18) end
    b:SetText(info[1])
    b:SetScript("OnClick", info[2])
    previous = b
  end
  return panel
end

Helper.Feature(function()
  if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end
  local ok, made = pcall(function()
    local registered = Settings.RegisterCanvasLayoutCategory(BuildPanel(), "ReadyToWork")
    Settings.RegisterAddOnCategory(registered)
    return registered
  end)
  if ok then category = made end
end)

-- Opens ReadyToWork's entry in the game's options, if it has one.
function Helper.OpenBlizzardEntry()
  if category and category.GetID and Settings.OpenToCategory then
    pcall(Settings.OpenToCategory, category:GetID())
  end
end
