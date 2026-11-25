-- The quick menu: right-click ReadyToWork's minimap button, or /rtw menu. Every helper is a row with its
-- switch; hovering the row opens its options. The entries come from the declarations in Core\Features.lua,
-- in the same order and with the same names as the settings window. The menu belongs to the screen rather
-- than to the button, so it stays open when the fan folds the button away. Every click under a helper is an
-- undoable settings edit.

local _, Helper = ...
local Options = Helper.Options

-- The feature whose options are being added: their clicks run as its edits.
local building

local function Edited(text, action)
  local feature = building
  if not feature or type(action) ~= "function" or not Helper.Store then
    return action
  end
  return function(...)
    local args = { n = select("#", ...), ... }
    return Helper.Store.Edit(feature, text, function() return action(unpack(args, 1, args.n)) end)
  end
end

local kit = Options.Kit(Edited)

-- A helper's row in the menu: its switch, with its options inside. `state` stands in for its saved settings
-- when the row must show something else (the fan while the separate MinimapFan addon runs).
local function AddFeature(root, spec, rebuild, state)
  local command = spec.command and Helper.commands[spec.command]
  if not command then return end
  state = state or Helper.db[spec.key]
  building = spec.key
  local row = kit.Check(root, spec.title, function() return state.enabled end, function()
    command(state.enabled and "off" or "on")
    rebuild()
    return MenuResponse.Open
  end)
  if state.enabled or spec.menuAlways then
    local ctx = Options.Context(spec, false)
    for _, option in ipairs(spec.options) do
      -- (an option of another section, like the minimap button's, is that section's edit)
      building = option.feature or spec.key
      local ok, problem = pcall(Options.AddToMenu, row, spec, option, ctx, kit)
      if not ok then building = nil; error(problem, 0) end
    end
  end
  building = nil
  row:AddInitializer(function(button)
    -- Forever's unchecked menu checkbox can be blank. Keep a visible box.
    if button.leftTexture1 then
      local box = button:AttachTexture()
      box:SetAllPoints(button.leftTexture1)
      box:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")
      box:SetDrawLayer("ARTWORK", -1)
    end
    -- (the row's own click is never replaced: Blizzard's menus reuse these buttons for their own menus, and a
    -- click script set by an addon could taint them. Hovering the row opens its options; a click switches it.)
  end)
end

-- A page without a switch (General): a plain submenu.
local function AddPage(root, spec)
  local sub = kit.Submenu(root, spec.title)
  local ctx = Options.Context(spec, false)
  for _, option in ipairs(spec.options) do
    building = option.feature
    Options.AddToMenu(sub, spec, option, ctx, kit)
  end
  building = nil
end

local function OpenQuickList(...)
  local menu
  local function Rebuild()
    -- Rebuild after Blizzard's click handler finishes. A checkbox refresh only redraws existing entries, so it
    -- cannot add or remove its submenu.
    C_Timer.After(0, function()
      if menu and Menu.GetManager():GetOpenMenu() == menu then
        OpenQuickList(menu:GetPoint(1))
      end
    end)
  end
  menu = MenuUtil.CreateContextMenu(UIParent, function(_, root)
    -- Blizzard reuses menu frames, so once this menu is gone its frame may be another menu's: forget it then.
    -- (Its submenus report here too as they close, so only the menu itself counts.)
    if root.AddMenuReleasedCallback then
      root:AddMenuReleasedCallback(function(released)
        if released == menu then menu = nil end
      end)
    end
    root:SetMinimumWidth(210)
    -- Submenu frames can first appear after combat starts. Plain rows throughout, so Blizzard never makes a
    -- decorative gamepad-navigation frame here (titles and dividers built in combat trip the red line).
    kit.Button(root, "Open settings window", function() Helper.OpenSettings() end)
    for _, key in ipairs(Helper.featureOrder) do
      local spec = Helper.features[key]
      if spec.section then
        if key == "minimapFan" and Helper.fanStandsDown then
          -- (shown off while the separate MinimapFan addon is loaded: clicking it says why)
          AddFeature(root, spec, Rebuild, { enabled = false })
        elseif key == "barProfiles" and not (Helper.BarLayouts and Helper.BarUI) then
          -- (bar profiles could not start on this client)
        elseif spec.defaults and spec.defaults.enabled ~= nil then
          AddFeature(root, spec, Rebuild)
        else
          AddPage(root, spec)
        end
      end
    end
  end)
  if menu and ... then
    menu:ClearAllPoints()
    menu:SetPoint(...)
  end
end

function Helper.ShowMenu()
  if not MenuUtil and C_AddOns and C_AddOns.LoadAddOn then
    C_AddOns.LoadAddOn("Blizzard_Menu")
  end
  if MenuUtil and type(MenuUtil.CreateContextMenu) == "function" then
    OpenQuickList()
  else
    Helper.Print("The Blizzard quick menu is unavailable. Use /rtw settings for the settings window.")
  end
end

Helper.commands.menu = Helper.ShowMenu
Helper.help[#Helper.help + 1] = "/rtw menu - open the quick menu"
