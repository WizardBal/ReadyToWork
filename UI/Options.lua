-- Reading and changing the typed options in Core\Features.lua. The quick menu (UI\Menu.lua) and the settings
-- window (UI\Window.lua) both go through here, so an entry behaves the same in both.

local _, Helper = ...
local Options = {}
Helper.Options = Options

-- The values every entry of one build shares: where it is shown, and the feature's own context.
function Options.Context(spec, window)
  local ctx = { window = window == true }
  if spec.context then
    local ok, extra = pcall(spec.context)
    if ok and type(extra) == "table" then
      for k, v in pairs(extra) do ctx[k] = v end
    end
  end
  return ctx
end

-- The feature whose saved section an option changes (usually its own).
function Options.Owner(spec, option)
  return (option and option.feature) or spec.key
end

function Options.DB(spec, option)
  return Helper.db and Helper.db[Options.Owner(spec, option)]
end

function Options.Command(spec, option)
  local owner = Helper.features[Options.Owner(spec, option)]
  return owner and owner.command and Helper.commands[owner.command]
end

function Options.Shown(spec, option, ctx)
  if ctx.window and option.window == false then return false end
  if not ctx.window and option.menu == false then return false end
  if option.type == "note" and not ctx.window then return false end
  if option.type == "custom" and not ctx.window then return false end
  if option.when then
    local ok, yes = pcall(option.when, Options.DB(spec, option), ctx)
    return ok and yes == true
  end
  return true
end

function Options.Label(spec, option, ctx)
  if option.labelFn then
    local ok, text = pcall(option.labelFn, Options.DB(spec, option), ctx)
    if ok and type(text) == "string" then return text end
  end
  return option.label
end

-- The tooltip's name: the label, or `name` when the label carries a number.
function Options.TipName(option)
  return option.name or option.label
end

function Options.Get(spec, option, ctx)
  local db = Options.DB(spec, option)
  if option.get then return option.get(db, ctx) end
  if not db then return nil end
  if option.type == "toggle" then return db[option.key] == true end
  return db[option.key]
end

-- Changes an option the way its declaration says: its own setter, its /rtw word, or the saved value plus the
-- feature's apply hook.
function Options.Set(spec, option, value, ctx)
  local db, command = Options.DB(spec, option), Options.Command(spec, option)
  if option.set then return option.set(value, db, command, ctx) end
  if option.cmd and command then
    local word = option.type == "toggle" and (value and "on" or "off") or tostring(value)
    return command(option.cmd .. " " .. word)
  end
  db[option.key] = value
  local owner = Helper.features[Options.Owner(spec, option)]
  if owner and owner.apply then owner.apply({ [option.key] = true }, db, command) end
end

function Options.Choices(spec, option, ctx)
  local list = option.choices
  if type(list) == "function" then
    local ok, result = pcall(list, Options.DB(spec, option), ctx)
    list = ok and result or {}
  end
  return list or {}
end

function Options.Run(spec, option, ctx)
  return option.run(Options.DB(spec, option), Options.Command(spec, option), ctx)
end

function Options.Enabled(spec, option, ctx)
  if not option.enabled then return true end
  local ok, yes = pcall(option.enabled, Options.DB(spec, option), ctx)
  return ok and yes == true
end

-- The card an option belongs on in the settings window.
function Options.Card(option)
  if option.card then return option.card end
  return "behaviour"
end

-- Runs `fn` as a settings edit of the option's owner (Undo covers it).
function Options.AsEdit(spec, option, label, fn)
  if Helper.Store then
    return Helper.Store.Edit(Options.Owner(spec, option), label, fn)
  end
  return fn()
end

-- Menu entry makers. `wrap(text, action)` may turn each action into an undoable edit; the settings window
-- passes none, since it runs every click as its own edit. Clients whose menus have no tick boxes or radio
-- buttons get plain entries that say which way they are set.
function Options.Kit(wrap)
  wrap = wrap or function(_, action) return action end
  local kit = {}
  function kit.Check(root, text, isOn, toggle, name, tip)
    toggle = wrap(text, toggle)
    if type(root.CreateCheckbox) == "function" then
      return Helper.Explain(root:CreateCheckbox(text, isOn, toggle), text, name, tip)
    end
    return Helper.Explain(root:CreateButton((isOn() and "On: " or "Off: ") .. text, toggle), text, name, tip)
  end
  function kit.Choice(root, text, isChosen, choose, name, tip)
    choose = wrap(text, choose)
    if type(root.CreateRadio) == "function" then
      return Helper.Explain(root:CreateRadio(text, isChosen, choose), text, name, tip)
    end
    return Helper.Explain(root:CreateButton((isChosen() and "> " or "   ") .. text, choose), text, name, tip)
  end
  function kit.Button(root, text, action, name, tip)
    return Helper.Explain(root:CreateButton(text, wrap(text, action)), text, name, tip)
  end
  function kit.Submenu(root, text, name, tip)
    return Helper.Explain(root:CreateButton(text), text, name, tip)
  end
  return kit
end

-- Adds one option's entries under `root` (a menu description, or the settings window's stand-in for one).
function Options.AddToMenu(root, spec, option, ctx, kit)
  if not Options.Shown(spec, option, ctx) then return end
  local label, tipName, tip = Options.Label(spec, option, ctx), Options.TipName(option), option.tip
  local kind = option.type
  if kind == "toggle" then
    kit.Check(root, label, function() return Options.Get(spec, option, ctx) == true end, function()
      Options.Set(spec, option, Options.Get(spec, option, ctx) ~= true, ctx)
    end, tipName, tip)
  elseif kind == "choice" or (kind == "slider" and option.menuChoices) then
    local list = kind == "choice" and Options.Choices(spec, option, ctx) or {}
    if kind == "slider" then
      for _, value in ipairs(option.menuChoices) do
        list[#list + 1] = { value, option.menuFormat and option.menuFormat(value) or tostring(value) }
      end
    end
    local sub = kit.Submenu(root, label, tipName, tip)
    for _, choice in ipairs(list) do
      local value = choice[1]
      kit.Choice(sub, choice[2], function() return Options.Get(spec, option, ctx) == value end,
        function() Options.Set(spec, option, value, ctx) end)
    end
  elseif kind == "action" then
    kit.Button(root, label, function() return Options.Run(spec, option, ctx) end, tipName, tip)
  elseif kind == "build" then
    option.build(root, Options.DB(spec, option), Options.Command(spec, option), ctx, kit)
  end
end

-- Every option of every feature whose label or tooltip holds `text` (for the settings window's search).
function Options.Search(text)
  local results = {}
  text = (text or ""):lower():match("^%s*(.-)%s*$")
  if text == "" then return results end
  for _, key in ipairs(Helper.featureOrder) do
    local spec = Helper.features[key]
    if spec.section then
      local matches = {}
      local function hit(s) return type(s) == "string" and s:lower():find(text, 1, true) ~= nil end
      for _, option in ipairs(spec.options) do
        if option.type ~= "note" and option.window ~= false and (hit(option.label) or hit(option.tip) or hit(option.name)) then
          matches[#matches + 1] = option
        end
      end
      if #matches > 0 or hit(spec.title) or hit(spec.description) then
        results[#results + 1] = { spec = spec, options = matches }
      end
    end
  end
  return results
end
