-- Settings edits and the one undo history.
--
-- Every change to a feature's settings runs as an edit: the settings window, the quick menu, /rtw commands
-- and frame drags all go through Store.Edit. An edit snapshots the feature's declared prefs (and its frame
-- position) before and after; an edit that changed nothing leaves no trace. Undo puts a recorded edit's
-- values back without touching later, unrelated changes, then lets the feature apply them.
--
-- Only declared prefs are journalled. Counters, logs, flight times and the spellbook cache keep updating
-- while edits run. Moving or resizing the settings window is not an edit. History lasts until logout or
-- UI reload and keeps the last LIMIT edits.

local _, Helper = ...
local Store = {}
Helper.Store = Store

local LIMIT = 50
local history = {}      -- oldest first: { feature, label, entries }
local visitStart = 0    -- #history when the settings window last opened
local active = {}       -- [feature] = true while an edit of it runs: nested edits join it
local listeners = {}

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end
Store.Copy = copy

local function equal(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for key, v in pairs(a) do if not equal(v, b[key]) then return false end end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end
Store.Equal = equal

local function pack(...) return { n = select("#", ...), ... } end

local function Notify(feature, how)
  for _, listener in ipairs(listeners) do
    Helper.Safely(listener, feature, how)
  end
end

-- Calls `listener(feature, how)` after an edit is recorded ("edit") or undone ("undo").
function Store.OnChange(listener)
  listeners[#listeners + 1] = listener
end

-- Starts an edit of `feature`. opts.profiles: also watch this character's bar profiles (the settings window's
-- Bar profiles actions can change them).
function Store.Begin(feature, label, opts)
  local db, spec = Helper.db, Helper.features[feature]
  local entries = {}
  local function watch(owner, field, tag, atomic)
    if type(owner) == "table" then
      entries[#entries + 1] = { owner = owner, field = field, tag = tag, atomic = atomic, before = copy(owner[field]) }
    end
  end
  if db and spec then
    for _, field in ipairs(spec.prefs) do watch(db[feature], field, field, spec.atomic[field] == true) end
    if spec.position then watch(db.positions, spec.position, "position", true) end
    if opts and opts.profiles and Helper.BarLayouts and Helper.BarLayouts.CharacterKey then
      local id = Helper.BarLayouts.CharacterKey()
      if id then watch(db.bars, id, "profiles") end
    end
  end
  return { feature = feature, label = label, entries = entries }
end

-- Ends an edit. Returns the tags that changed, or nil when nothing did (and nothing is recorded).
function Store.Finish(edit)
  local changes, tags = {}, {}
  for _, entry in ipairs(edit.entries) do
    local after = entry.owner[entry.field]
    if not equal(entry.before, after) then
      entry.after = copy(after)
      changes[#changes + 1] = entry
      tags[entry.tag] = true
    end
  end
  if #changes == 0 then return nil end
  edit.entries = changes
  history[#history + 1] = edit
  while #history > LIMIT do
    table.remove(history, 1)
    visitStart = math.max(0, visitStart - 1)
  end
  Notify(edit.feature, "edit")
  return tags
end

-- Runs `fn` as an edit of `feature` and returns what it returns. An edit already running for the same
-- feature takes this one in.
function Store.Edit(feature, label, fn, opts)
  if not Helper.db or not Helper.features[feature] or active[feature] then
    return fn()
  end
  local edit = Store.Begin(feature, label, opts)
  active[feature] = true
  local results = pack(pcall(fn))
  active[feature] = nil
  Store.Finish(edit)
  if not results[1] then error(results[2], 0) end
  return unpack(results, 2, results.n)
end

-- Sets one pref as an edit, then lets the feature apply it.
function Store.Set(feature, key, value, label)
  local db = Helper.db and Helper.db[feature]
  if type(db) ~= "table" then return end
  local tags
  if active[feature] then
    -- (part of an edit already running, which records it)
    if equal(db[key], value) then return end
    db[key] = copy(value)
    tags = { [key] = true }
  else
    local edit = Store.Begin(feature, label or key)
    db[key] = copy(value)
    tags = Store.Finish(edit)
  end
  if tags then Store.Apply(feature, tags) end
end

-- Puts back `before` where the value is still `after`. Tables that changed in parts are restored part by part,
-- so a later, unrelated change to the same list or profile is kept.
local function restore(owner, key, before, after, atomic)
  local current = owner[key]
  if equal(current, before) then return end
  if equal(current, after) and (atomic or type(current) ~= "table" or type(before) ~= "table") then
    owner[key] = copy(before)
    return true
  end
  if atomic or type(current) ~= "table" or type(after) ~= "table" or (before ~= nil and type(before) ~= "table") then return end
  local original, changed = before or {}, false
  for k, v in pairs(after) do
    if not equal(v, original[k]) and restore(current, k, original[k], v) then changed = true end
  end
  for k, v in pairs(original) do
    if after[k] == nil and current[k] == nil then current[k] = copy(v); changed = true end
  end
  return changed
end

-- Lets `feature` act on settings that changed underneath it (after an undo or a reset): its command switches it
-- on or off, its apply hook does the rest, and a moved frame goes back to its saved place. Messages the
-- feature prints while doing so are not shown: the caller says what happened.
function Store.Apply(feature, changed, captured)
  local spec, db = Helper.features[feature], Helper.db and Helper.db[feature]
  if not spec or not db then return end
  local command = spec.command and Helper.commands[spec.command]
  local output = Helper.EditorOutput
  Helper.EditorOutput = function() end
  local ok, problem = pcall(function()
    if changed.enabled and command then command(db.enabled and "on" or "off") end
    if spec.apply then spec.apply(changed, db, command, captured) end
    if changed.position and spec.position and Helper.RestorePlacement then Helper.RestorePlacement(spec.position) end
  end)
  Helper.EditorOutput = output
  if not ok then error(problem, 0) end
end

-- Undoes edits. With `feature`, the last edit of that feature, or with `all` every edit of it since the settings
-- window opened; without, the last edit of any feature. Returns the tags that changed (nil when nothing was
-- undone), the feature and the edit's label.
function Store.Undo(feature, all)
  local picked = {}
  for index = #history, 1, -1 do
    local edit = history[index]
    if all and index <= visitStart then break end
    if not feature or edit.feature == feature then
      picked[#picked + 1] = index
      if not all then break end
    end
  end
  if #picked == 0 then return nil end
  local target = history[picked[1]].feature
  local label = history[picked[1]].label
  local captured, changed, order = {}, {}, {}
  for _, index in ipairs(picked) do -- (newest first; removing from the end keeps the other indexes right)
    local edit = table.remove(history, index)
    local entryFeature = edit.feature
    if not changed[entryFeature] then
      local spec = Helper.features[entryFeature]
      captured[entryFeature] = spec and spec.capture and spec.capture(Helper.db[entryFeature])
      changed[entryFeature], order[#order + 1] = {}, entryFeature
    end
    for _, entry in ipairs(edit.entries) do
      if restore(entry.owner, entry.field, entry.before, entry.after, entry.atomic) then changed[entryFeature][entry.tag] = true end
    end
  end
  visitStart = math.min(visitStart, #history)
  local problem
  for _, changedFeature in ipairs(order) do
    if next(changed[changedFeature]) then
      local ok, err = pcall(Store.Apply, changedFeature, changed[changedFeature], captured[changedFeature])
      if not ok and not problem then problem = err end
    end
    Notify(changedFeature, "undo")
  end
  if problem then error(problem, 0) end
  return changed[target], target, label, changed
end

-- All recorded edits: how many, the newest one's label and feature, and how many came since the window opened.
function Store.Count()
  local last = history[#history]
  return #history, last and last.label, last and last.feature, #history - visitStart
end

-- How many edits of `feature` are recorded, the last one's label, and how many came since the window opened.
function Store.Info(feature)
  local total, label, since = 0, nil, 0
  for index, edit in ipairs(history) do
    if edit.feature == feature then
      total, label = total + 1, edit.label
      if index > visitStart then since = since + 1 end
    end
  end
  return total, label, since
end

function Store.StartVisit()
  visitStart = #history
end

-- Puts `feature`'s settings back to their defaults, as one edit Undo can take back. Lists the player made
-- (every pref whose value is a table: chosen items, kept items, button order), profiles, logs and frame
-- positions are kept. Returns the tags that changed.
function Store.Reset(feature)
  local spec, db = Helper.features[feature], Helper.db and Helper.db[feature]
  if not spec or not db then return nil end
  local edit = Store.Begin(feature, "Restore defaults")
  for _, field in ipairs(spec.prefs) do
    local default = spec.defaults and spec.defaults[field]
    if type(default) ~= "table" and type(db[field]) ~= "table" and not (spec.noReset and spec.noReset[field]) then
      db[field] = default
    end
  end
  local tags = Store.Finish(edit)
  if tags then Store.Apply(feature, tags) end
  return tags
end

-- The window's and the other helpers' entry point, kept under its old name: runs `action` as an edit.
function Helper.ApplyEditorAction(key, label, action, profiles)
  return Store.Edit(key, label, action, { profiles = profiles })
end

-- /rtw undo and /rtw reset ----------------------------------------------------------------------------------

local function FindFeature(text)
  text = (text or ""):lower()
  if text == "" then return nil end
  for _, key in ipairs(Helper.featureOrder) do
    local spec = Helper.features[key]
    if key:lower() == text
        or (type(spec.command) == "string" and spec.command:lower() == text)
        or (type(spec.title) == "string" and spec.title:lower() == text)
        or (type(spec.oldTitle) == "string" and spec.oldTitle:lower() == text)
        or (type(spec.menu) == "string" and spec.menu:lower() == text) then
      return key
    end
    for _, alias in ipairs(spec.aliases or {}) do
      if type(alias) == "string" and alias:lower() == text then return key end
    end
  end
end
Store.FindFeature = FindFeature

Helper.commands.undo = function()
  local changed, feature, label = Store.Undo()
  if not changed then
    Helper.Print("Nothing to undo: no settings changed since logging in.")
    return
  end
  local spec = Helper.features[feature]
  Helper.Print(("Undid %s (%s)."):format(label or "the last change", spec and spec.title or feature))
end

Helper.commands.reset = function(rest)
  local feature = FindFeature(rest)
  if not feature or not Helper.features[feature].prefs[1] then
    local names = {}
    for _, key in ipairs(Helper.featureOrder) do
      local spec = Helper.features[key]
      if spec.prefs[1] and spec.command then names[#names + 1] = spec.command end
    end
    Helper.Print("/rtw reset <name> puts one helper's settings back to their defaults: " .. table.concat(names, ", ") .. ".")
    return
  end
  local spec = Helper.features[feature]
  if Store.Reset(feature) then
    Helper.Print(("%s settings are back to their defaults. Lists you made are kept. /rtw undo takes it back."):format(spec.title or feature))
  else
    Helper.Print(("%s settings were already at their defaults."):format(spec.title or feature))
  end
end

Helper.help[#Helper.help + 1] = "/rtw undo - undo the last settings change, wherever it was made"
Helper.help[#Helper.help + 1] = "/rtw reset <name> - put one helper's settings back to their defaults"
