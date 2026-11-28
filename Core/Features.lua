-- The feature registry, and every feature declared once. The saved defaults, the settings the undo history
-- watches, the settings window's pages and cards, the quick menu, every entry's tooltip, the home page's
-- status lines and what each feature does after an undo or reset all come from here. Declaration order is
-- the order of the settings window, the quick menu and the introduction.

local _, Helper = ...

-- Registry -----------------------------------------------------------------------------------------------

-- Helper.features[key] = declaration; Helper.featureOrder lists them in declaration order.
-- A declaration:
--   key         saved section, ReadyToWorkDB[key]   title    its name everywhere (window, menu, README)
--   command     word after /rtw                      aliases  other /rtw words for it
--   icon        icon file name                       group    settings window group
--   description one line under the title             rowTip   the quick menu row's tooltip, when longer
--   section     true: has a page in the settings window
--   defaults    the saved section's defaults         data     extra top-level saved sections it owns
--   prefs       the user-editable fields, journalled for undo
--   atomic      prefs restored whole on undo         noReset  prefs /rtw reset leaves alone
--   position    key in ReadyToWorkDB.positions, journalled too
--   frames      { [positions key] = title } of its movable frames (unlock mode)
--   options     typed entries, see below             tips     [entry name] = tooltip, for entries not in options
--   status      function(db, ctx) -> lines for the home page and the Status card
--   context     function() -> extra values each menu and page build shares (bar profiles: the spec)
--   menuAlways  the menu shows its options while it is off
--   apply       function(changed, db, command, captured) after an undo or reset
--   capture     function(db) before undo, its result reaches apply
--
-- An option:
--   type     "toggle" | "choice" | "slider" | "action" | "build" | "custom" | "note"
--   key      the pref it shows (toggle, choice, slider)    feature  another declaration's section, if not this one
--   label    its name                                       tip      its tooltip
--   labelFn  function(db, ctx) -> label, when it carries a number
--   get      function(db, ctx) -> value                     set      function(value, db, command, ctx)
--   cmd      command word: toggles send "<cmd> on|off", choices and sliders "<cmd> <value>"
--   choices  { {value, label}, ... } or function(db, ctx) -> that list
--   min, max, step (slider); menuChoices { values } and menuFormat function(value) -> label for the menu
--   run      function(db, command, ctx) (action)            danger  red, asks for a second click
--   build    function(root, db, command, ctx, kit) (build: entries made in code; the window shows them too)
--   render   custom card renderer's name (custom)           text    (note)
--   card     "status" | "behaviour" | "appearance" | "lists" (default by type)
--   menu, window   false: left out there                    when    function(db, ctx) -> shown?
--   style    "direction": the window draws direction cards
Helper.features, Helper.featureOrder = {}, {}

function Helper.Declare(spec)
  assert(type(spec) == "table" and type(spec.key) == "string", "Declare needs a key")
  if not Helper.features[spec.key] then
    Helper.featureOrder[#Helper.featureOrder + 1] = spec.key
  end
  spec.prefs, spec.tips, spec.atomic = spec.prefs or {}, spec.tips or {}, spec.atomic or {}
  spec.options = spec.options or {}
  Helper.features[spec.key] = spec
  return spec
end

-- Saved sections that belong to no single feature.
local CORE_DEFAULTS = { positions = {}, chars = {} }

-- The defaults for the whole saved table, built from the declarations.
function Helper.Defaults()
  local defaults = {}
  for key, value in pairs(CORE_DEFAULTS) do defaults[key] = value end
  for _, key in ipairs(Helper.featureOrder) do
    local spec = Helper.features[key]
    if spec.defaults then defaults[key] = spec.defaults end
    for name, value in pairs(spec.data or {}) do defaults[name] = value end
  end
  return defaults
end

-- The tooltip text for a menu or settings entry, by its name: an option's label, a feature's title, or an
-- extra name in `tips`.
Helper.generalTips = {}
function Helper.Tip(name)
  if name == nil then return nil end
  if Helper.generalTips[name] then return Helper.generalTips[name] end
  for _, key in ipairs(Helper.featureOrder) do
    local spec = Helper.features[key]
    if spec.title == name then return spec.rowTip or spec.description end
    if spec.tips[name] then return spec.tips[name] end
    for _, option in ipairs(spec.options) do
      if option.tip and (option.label == name or option.name == name) then return option.tip end
    end
  end
end

-- Gives a menu entry its tooltip: `tip` if given, else the tooltip for `name` (or the entry's text).
function Helper.Explain(description, text, name, tip)
  tip = tip or Helper.Tip(name or text)
  if tip and description and type(description.SetTooltip) == "function" then
    description:SetTooltip(function(tooltip)
      tooltip:SetText(text, 1, 1, 1)
      tooltip:AddLine(tip, nil, nil, nil, true)
    end)
  end
  return description
end

-- The feature a /rtw word belongs to, if any.
function Helper.FeatureForCommand(word)
  for _, key in ipairs(Helper.featureOrder) do
    local spec = Helper.features[key]
    if spec.command == word then return key end
    for _, alias in ipairs(spec.aliases or {}) do
      if alias == word then return key end
    end
  end
end

-- The declaration a settings page name stands for: a title, an older title, a key, a command word, or an alias.
function Helper.FeatureByName(name)
  if type(name) ~= "string" then return nil end
  local wanted = name:lower()
  for _, key in ipairs(Helper.featureOrder) do
    local spec = Helper.features[key]
    if (type(spec.title) == "string" and spec.title:lower() == wanted)
        or (type(spec.oldTitle) == "string" and spec.oldTitle:lower() == wanted)
        or key:lower() == wanted
        or (type(spec.command) == "string" and spec.command:lower() == wanted) then
      return spec
    end
    for _, alias in ipairs(spec.aliases or {}) do
      if type(alias) == "string" and alias:lower() == wanted then return spec end
    end
  end
end

local Declare = Helper.Declare

-- Shared pieces -------------------------------------------------------------------------------------------

local function Count(list)
  local n = 0
  for _ in pairs(type(list) == "table" and list or {}) do n = n + 1 end
  return n
end

local function FlightClock(seconds)
  if Helper.Flight and Helper.Flight.TotalClock then return Helper.Flight.TotalClock(seconds) end
  seconds = math.max(0, math.floor((seconds or 0) + 0.5))
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  return ("%02d:%02d:%02d"):format(hours, minutes, seconds % 60)
end

local function VendorTotals(db)
  if Helper.Vendor and Helper.Vendor.TodayTotals then return Helper.Vendor.TodayTotals(db) end
  local today = type(date) == "function" and date("%Y-%m-%d") or "today"
  if type(db.today) == "table" and db.today.day == today then
    return db.today.items or 0, db.today.copper or 0, db.today.repaired or 0
  end
  local items, copper, repaired = 0, 0, 0
  for _, entry in ipairs(db.log or {}) do
    if type(entry) == "table" and entry.t and type(date) == "function" and date("%Y-%m-%d", entry.t) == today then
      if entry.items then items, copper = items + entry.items, copper + (entry.copper or 0) end
      if entry.repair then repaired = repaired + entry.repair end
    end
  end
  return items, copper, repaired
end

local DIRECTIONS = { { "auto", "Auto" }, { "left", "Left" }, { "right", "Right" }, { "up", "Up" }, { "down", "Down" } }

local function Direction(tip)
  return { type = "choice", key = "direction", label = "Flyout direction", choices = DIRECTIONS, style = "direction",
    card = "appearance", tip = tip or "Which way the choices fan out from the button. Auto picks the side with the most room." }
end

-- An action that runs one of the feature's /rtw words.
local function Word(label, word, tip, extra)
  local option = { type = "action", label = label, tip = tip, run = function(_, command) command(word) end }
  for k, v in pairs(extra or {}) do option[k] = v end
  return option
end

Helper.generalTips = {
  ["Open settings window"] = "Opens the full ReadyToWork settings window.",
  ["Reset positions"] = "Puts the flight timer, destroy button and bar swap button back where they started.",
  ["Introduction"] = "What ReadyToWork does, in a few lines.",
  ["Unlock frames"] = "Outlines every ReadyToWork frame on screen so you can drag, resize or reset it. Click Done, press Escape or type /rtw unlock again to finish.",
  ["Flyout direction"] = "Which way the choices fan out from the button. Auto picks the side with the most room.",
}

-- Bags & Vendors ------------------------------------------------------------------------------------------

Declare{
  key = "vendor", title = "Sell & repair", oldTitle = "Vendors", aliases = { "Auto-sell greys", "Auto-sell grays" }, command = "vendor",
  icon = "INV_Misc_Coin_01", group = "Bags & Vendors", section = true, perChar = true,
  description = "Repairs, then sells your gray items and white items you choose, when you open a vendor.",
  rowTip = "Repairs and sells your gray items when a vendor opens. Hold Shift while opening the vendor to skip both once.",
  -- today: { day, items, copper, repaired } daily summary. included: chosen white items, [item ID] = name.
  -- repair: repair everything at vendors that can; repairGuild: from guild funds when the guild bank allows it.
  -- repairSpent and repairGuildSpent: lifetime totals, the game's repair costs.
  defaults = { enabled = true, log = {}, included = {}, lifetime = 0, reportChat = true,
    repair = true, repairGuild = false, repairSpent = 0, repairGuildSpent = 0 },
  prefs = { "enabled", "included", "reportChat", "repair", "repairGuild" },
  status = function(db)
    local items, copper = VendorTotals(db)
    return {
      items > 0 and ("Sold %d item%s for %s today"):format(items, items == 1 and "" or "s", Helper.Money(copper))
        or "Nothing sold today",
      (db.repair and "Auto-repair on · " or "") .. "Lifetime: " .. Helper.Money(db.lifetime),
    }
  end,
  statusChips = function(db)
    local items, copper, repaired = VendorTotals(db)
    local chips = {
      { label = "Sold today",
        value = items > 0 and ("%s · %d %s"):format(Helper.Money(copper), items, items == 1 and "item" or "items") or "None yet",
        tone = items > 0 and "accent" or "dim" },
      { label = "Sold lifetime", value = Helper.Money(db.lifetime) },
      { label = "Repairs today",
        value = db.repair and (repaired > 0 and Helper.Money(repaired) or "None yet") or "Off",
        tone = (not db.repair or repaired == 0) and "dim" or nil },
      { label = "Repairs lifetime",
        value = db.repair and Helper.Money(db.repairSpent or 0) or "Off",
        tone = not db.repair and "dim" or nil },
    }
    local atVendor = MerchantFrame and MerchantFrame:IsShown()
    if atVendor and Helper.Vendor and Helper.Vendor.Preview then
      local _, total, count = Helper.Vendor.Preview()
      chips[#chips + 1] = {
        label = "Ready to sell",
        value = count > 0 and ("%s · %d %s"):format(Helper.Money(total), count, count == 1 and "item" or "items") or "Nothing",
        tone = count > 0 and "accent" or "dim",
      }
    end
    return chips
  end,
  options = {
    { type = "toggle", key = "repair", label = "Repair at vendors", cmd = "repair",
      tip = "Repairs all your gear when a vendor that can repair opens. Hold Shift while opening the vendor to skip it once." },
    { type = "toggle", key = "repairGuild", label = "Use guild funds first", cmd = "repair guild",
      sub = true, requires = "Repair at vendors",
      enabled = function(db) return db.repair == true end,
      tip = "Pays for repairs from the guild bank when you may withdraw enough; otherwise from your own gold." },
    { type = "toggle", key = "reportChat", label = "Report in chat",
      tip = "Says in chat what was repaired and sold at each vendor visit." },
    { type = "build", label = "Also sell these white items", window = false,
      tip = "White items in your bags. A ticked item is sold with your grays at every vendor.",
      build = function(root, db, _, _, kit)
        local list = kit.Submenu(root, "Also sell these white items")
        local items = {}
        for id, name in pairs(Helper.Vendor.WhiteItems()) do
          local label = type(name) == "string" and name or ("Item #" .. id)
          items[#items + 1] = { id = id, name = label, sortName = (label:match("|h%[(.-)%]|h") or label):lower() }
        end
        table.sort(items, function(a, b)
          if a.sortName == b.sortName then return a.id < b.id end
          return a.sortName < b.sortName
        end)
        for _, item in ipairs(items) do
          local id, name = item.id, item.name
          kit.Check(list, name, function() return db.included[id] ~= nil end, function()
            if db.included[id] then Helper.Vendor.SetIncluded(id, nil) else Helper.Vendor.SetIncluded(id, name) end
          end)
        end
      end },
    { type = "custom", render = "vendorItems", card = "lists", label = "Remembered items",
      tip = "White items sold with your grays. Drop an item from your bags here, or choose from your bags." },
  },
  capture = function(db)
    local ids = {}
    for id in pairs(db.included or {}) do ids[id] = true end
    return ids
  end,
  apply = function(changed, _, _, previous)
    local vendor = Helper.Vendor
    if not vendor then return end
    if changed.included and vendor.HoldRestoredItems then vendor.HoldRestoredItems(previous or {}) end
    if vendor.UpdateButton then vendor.UpdateButton() end
  end,
}

Declare{
  key = "open", title = "Auto-open", oldTitle = "Containers", aliases = { "Auto-open containers", "Open containers" }, command = "open",
  icon = "INV_Box_01", group = "Bags & Vendors", section = true, perChar = true,
  description = "Opens clams and other containers in your bags when it's safe to.",
  -- which: "clams", "common" (white and grey containers) or "all". keepFree: open only with this many bag
  -- slots free. skip: item IDs never to open (-> their link).
  defaults = { enabled = true, which = "common", keepFree = 1, chat = true, skip = {} },
  prefs = { "enabled", "which", "keepFree", "chat", "skip" },
  status = function(db)
    local opener = Helper.Opener
    if opener and opener.IsPausedForSpace and opener.IsPausedForSpace() then
      local waiting = opener.WaitingCount and opener.WaitingCount() or 0
      return { ("Paused · %d waiting"):format(waiting), "Open your bags to resume" }
    end
    local labels = opener and opener.WhichLabels and opener.WhichLabels() or {}
    return { ("Opens: %s"):format(labels[db.which] or db.which or "?"),
      db.keepFree and db.keepFree > 0 and ("Keeps %d free slot%s"):format(db.keepFree, db.keepFree == 1 and "" or "s")
        or "Opens even with full bags" }
  end,
  statusChips = function(db)
    local opener = Helper.Opener
    local paused = opener and opener.IsPausedForSpace and opener.IsPausedForSpace()
    local waiting = opener and opener.WaitingCount and opener.WaitingCount() or 0
    local chips = {}
    if paused then
      chips[#chips + 1] = { label = "State", value = "Paused (open bags)", tone = "warn" }
    end
    chips[#chips + 1] = { label = "Waiting", value = tostring(waiting), tone = waiting > 0 and "accent" or nil }
    chips[#chips + 1] = { label = "Free slots", value = tostring(Helper.FreeSlots and Helper.FreeSlots() or 0) }
    chips[#chips + 1] = { label = "Never opened", value = tostring(Count(db.skip)) }
    return chips
  end,
  options = {
    { type = "choice", key = "which", label = "Which containers",
      tip = "Which containers open by themselves: only clams, white and gray containers, or all of them.",
      choices = function()
        local labels = Helper.Opener.WhichLabels()
        return { { "clams", labels.clams }, { "common", labels.common }, { "all", labels.all } }
      end,
      set = function(value, _, command) command(value) end },
    { type = "slider", key = "keepFree", label = "Keep free bag slots", min = 0, max = 10, cmd = "free",
      menuChoices = { 0, 1, 2, 4 }, menuFormat = function(n) return n == 0 and "None needed" or ("At least " .. n) end,
      tip = "Opens containers only while at least this many bag slots are free, so the loot has room." },
    { type = "toggle", key = "chat", label = "Chat report", cmd = "chat", tip = "Says in chat what was opened." },
    { type = "build", label = "Never open", card = "lists",
      tip = "Containers that are never opened by themselves. Tick one to leave it closed.",
      build = function(root, db, _, _, kit)
        local opener = Helper.Opener
        local never = kit.Submenu(root, "Never open")
        local listed = {}
        for itemID, link in pairs(opener.Openable()) do
          listed[itemID] = true
          kit.Check(never, link or ("item " .. itemID), function() return db.skip[itemID] ~= nil end, function()
            opener.SetSkip(itemID, link, db.skip[itemID] == nil)
          end)
        end
        for itemID, link in pairs(db.skip) do
          if not listed[itemID] then
            kit.Check(never, type(link) == "string" and link or ("item " .. itemID), function() return db.skip[itemID] ~= nil end,
              function() opener.SetSkip(itemID, link, db.skip[itemID] == nil) end)
          end
        end
        if not next(listed) and not next(db.skip) then
          never:CreateButton("No containers in your bags.")
        end
      end },
  },
  apply = function()
    if Helper.Opener and Helper.Opener.Refresh then Helper.Opener.Refresh() end
  end,
}

Declare{
  key = "fastLoot", title = "Fast loot", aliases = { "fastloot", "speedloot", "Speed loot" }, command = "loot",
  icon = "INV_Misc_Bag_10", group = "Bags & Vendors", section = true,
  description = "Grabs all loot slots at once without waiting on the loot window.",
  rowTip = "Picks up every unlocked loot slot in one frame without the loot window delay or flash. Hold your Auto Loot key (Shift by default) to inspect loot normally.",
  defaults = { enabled = true, hideWindow = true, always = false },
  prefs = { "enabled", "hideWindow", "always" },
  status = function(db)
    local cvarOn = Helper.FastLoot and Helper.FastLoot.GameAutoLootOn and Helper.FastLoot.GameAutoLootOn()
    local mode = db.always and "Active even with WoW Auto Loot off"
      or (cvarOn and "WoW Auto Loot is on" or "WoW Auto Loot is off (hold Shift or enable below)")
    return { mode, db.hideWindow ~= false and "Hides loot window flash" or "Keeps loot window visible" }
  end,
  statusChips = function(db)
    local cvarOn = Helper.FastLoot and Helper.FastLoot.GameAutoLootOn and Helper.FastLoot.GameAutoLootOn()
    return {
      { label = "WoW Auto Loot", value = cvarOn and "On" or "Off",
        tone = cvarOn and "accent" or (db.always and "dim" or "warn") },
      { label = "Loot window", value = db.hideWindow ~= false and "Hidden" or "Shown",
        tone = db.hideWindow ~= false and "accent" or "dim" },
      { label = "Free slots", value = tostring(Helper.FreeSlots and Helper.FreeSlots() or 0) },
    }
  end,
  options = {
    { type = "action", label = "Enable WoW Auto Loot", card = "status", header = true,
      tip = "Turns on the game's built-in Auto Loot setting so looting happens without holding a modifier key.",
      when = function(db)
        return not db.always and Helper.FastLoot ~= nil and Helper.FastLoot.GameAutoLootOn ~= nil
          and not Helper.FastLoot.GameAutoLootOn()
      end,
      run = function()
        if C_CVar and C_CVar.SetCVar then C_CVar.SetCVar("autoLootDefault", "1")
        elseif SetCVar then SetCVar("autoLootDefault", "1") end
      end },
    { type = "toggle", key = "hideWindow", label = "Hide loot window while fast-looting", cmd = "hide",
      tip = "Hides the brief loot window flash when everything can be picked up at once. Automatically shows the window if bags are full, a slot is locked, or an item needs confirmation." },
    { type = "toggle", key = "always", label = "Auto-loot even when WoW Auto Loot is off", cmd = "always",
      tip = "Fast-loots automatically even if the game's Auto Loot setting is switched off. Hold your Auto Loot key (Shift by default) to open the loot window normally." },
    { type = "note", text = "Hold your Auto Loot key (Shift by default) while looting to open the loot window normally. Bind-on-Pickup prompts, locked slots, and items that don't fit in full bags always show the loot window." },
  },
  apply = function()
    if Helper.FastLoot and Helper.FastLoot.Apply then Helper.FastLoot.Apply() end
  end,
}

Declare{
  key = "mailbox", title = "Mailbox", aliases = { "mail" }, command = "mail",
  icon = "INV_Letter_15", group = "Bags & Vendors", section = true,
  description = "Collects gold even with full bags, honors a free-slot reserve, and adds an alt picker when sending.",
  rowTip = "Safe one-click Collect all / Gold only bar on your inbox plus an Alts & Recent dropdown on Send Mail. Never deletes letters or touches CoD/GM mail.",
  defaults = { enabled = true, keepFree = 0, altPicker = true, reportChat = true, recent = {} },
  prefs = { "enabled", "keepFree", "altPicker", "reportChat", "recent" },
  noReset = { recent = true },
  status = function(db)
    local mail = Helper.Mailbox
    if mail and mail.IsOpen and mail.IsOpen() then
      local sum = mail.Summary and mail.Summary() or { gold = 0, stacks = 0 }
      return {
        sum.gold > 0 and ("Inbox gold: " .. Helper.Money(sum.gold)) or "No inbox gold waiting",
        sum.stacks > 0 and ("%d item stack%s waiting"):format(sum.stacks, sum.stacks == 1 and "" or "s")
          or "No attachments waiting",
      }
    end
    local keep = db.keepFree or 0
    return {
      keep > 0 and ("Keeps %d free bag slot%s"):format(keep, keep == 1 and "" or "s")
        or "Collects until bags are full (gold always collected)",
      ("%d recent recipient%s saved"):format(#(db.recent or {}), #(db.recent or {}) == 1 and "" or "s"),
    }
  end,
  statusChips = function(db)
    local mail = Helper.Mailbox
    local isOpen = mail and mail.IsOpen and mail.IsOpen()
    local sum = isOpen and mail.Summary and mail.Summary() or nil
    local alts = Helper.Characters and Helper.Characters.List and #Helper.Characters.List() or 0
    local chips = {}
    if sum then
      chips[#chips + 1] = {
        label = "Inbox gold",
        value = sum.gold > 0 and Helper.Money(sum.gold) or "None",
        tone = sum.gold > 0 and "accent" or "dim",
      }
      chips[#chips + 1] = {
        label = "Attachments",
        value = sum.stacks > 0 and ("%d stack%s"):format(sum.stacks, sum.stacks == 1 and "" or "s") or "None",
        tone = sum.stacks > 0 and "accent" or "dim",
      }
    end
    chips[#chips + 1] = {
      label = "Free-slot reserve",
      value = (db.keepFree or 0) > 0 and tostring(db.keepFree) or "0 (none)",
    }
    chips[#chips + 1] = { label = "Known alts", value = tostring(alts) }
    chips[#chips + 1] = { label = "Recent", value = tostring(#(db.recent or {})) }
    return chips
  end,
  options = {
    { type = "slider", key = "keepFree", label = "Keep free bag slots", min = 0, max = 10, cmd = "free",
      menuChoices = { 0, 1, 2, 4 }, menuFormat = function(n) return n == 0 and "None needed" or ("Keep " .. n) end,
      tip = "Stops taking item attachments once only this many bag slots remain free. Gold is still collected even with full bags." },
    { type = "toggle", key = "altPicker", label = "Show Alts & Recent picker on Send Mail", cmd = "alts",
      tip = "Adds a quick dropdown button next to the To box on Send Mail to fill in any character on your account or a recent recipient." },
    { type = "toggle", key = "reportChat", label = "Report collected mail in chat", cmd = "chat",
      tip = "Prints one short summary line after a batch finishes showing how much gold and how many items were collected." },
    { type = "action", label = "Clear recent recipients", danger = true, card = "lists",
      when = function(db) return type(db.recent) == "table" and #db.recent > 0 end,
      tip = "Forgets recently mailed names (your own account characters stay in the list).",
      run = function(_, command) command("clearrecent") end },
    { type = "note", text = "100% zero-loss safe: Mailbox never deletes or returns mail, never auto-sends, and always skips CoD and GM messages." },
  },
  apply = function()
    if Helper.Mailbox and Helper.Mailbox.Apply then Helper.Mailbox.Apply() end
  end,
}

Declare{
  key = "destroy", title = "Quick destroy", oldTitle = "Destroy button", command = "destroy",
  icon = "INV_Gizmo_02", group = "Bags & Vendors", section = true, perChar = true, position = "destroy",
  frames = { destroy = "Destroy button" },
  description = "A button that offers your cheapest junk to destroy when your bags fill up.",
  -- mode "full": the button shows when `freeSlots` or fewer bag slots are free; "always": whenever there is
  -- something to destroy. mageWater and mageFood: offer conjured mage water and food. keep: item IDs never
  -- to offer. included: any bag items dropped onto the button (offered first). click "fan": the button fans
  -- out up to `fanSize` choices, cheapest first; "destroy": it destroys the cheapest at once.
  defaults = {
    enabled = true, mode = "full", freeSlots = 2,
    mageWater = true, mageFood = true, direction = "auto", keep = {}, included = {},
    click = "fan", fanSize = 8, reportDestroyed = true,
  },
  prefs = { "enabled", "mode", "freeSlots", "mageWater", "mageFood", "direction", "keep",
    "included", "click", "fanSize", "reportDestroyed" },
  status = function(db)
    return { db.mode == "always" and "Shows whenever there is junk"
        or ("Shows with %d or fewer bag slots free"):format(db.freeSlots or 2),
      ("%d protected · %d included by hand"):format(Count(db.keep), Count(db.included)) }
  end,
  statusChips = function(db)
    return {
      chips = {
        { label = "Protected", value = tostring(Count(db.keep)) },
        { label = "Included", value = tostring(Count(db.included)) },
        { label = "Free slots", value = tostring(Helper.FreeSlots and Helper.FreeSlots() or 0) },
      },
      note = "Alt-drag the button to move it, or right-click it for settings.",
    }
  end,
  options = {
    Direction(),
    { type = "choice", key = "mode", label = "Show when",
      tip = "When the destroy button appears: only when your bags are nearly full, or whenever there is junk.",
      choices = function(db)
        return { { "full", ("%d or fewer bag slots free"):format(db.freeSlots or 2) }, { "always", "Whenever there is junk" } }
      end,
      set = function(value, _, command) command(value) end },
    { type = "slider", key = "freeSlots", label = "Free bag slots for the destroy button", min = 0, max = 16, menu = false,
      requires = "Show when: nearly full",
      enabled = function(db) return db.mode ~= "always" end,
      tip = "With Show when set to nearly full bags: the button appears once this many bag slots or fewer are free.",
      set = function(value, db) db.freeSlots = value; if Helper.Destroy then Helper.Destroy.Refresh() end end },
    { type = "choice", key = "click", label = "On click",
      tip = "What clicking the destroy button does: show the choices, or destroy the cheapest at once.",
      get = function(db) return db.click == "destroy" and "destroy" or "fan" end,
      choices = { { "fan", "Show choices, cheapest first" }, { "destroy", "Destroy the cheapest at once" } },
      set = function(value, _, command) command("click " .. value) end },
    { type = "choice", key = "fanSize", label = "Choices shown", tip = "How many items the destroy button's fan shows at most.",
      requires = "On click: Show choices",
      enabled = function(db) return db.click ~= "destroy" end,
      choices = { { 5, "Up to 5" }, { 8, "Up to 8" }, { 12, "Up to 12" } },
      set = function(value, _, command) command("show " .. value) end },
    { type = "toggle", key = "mageFood", label = "Conjured mage food", cmd = "food",
      tip = "Offers conjured mage food too: one tile per rank, smallest stack first." },
    { type = "toggle", key = "mageWater", label = "Conjured mage water", cmd = "water",
      tip = "Offers conjured mage water too: one tile per rank, smallest stack first." },
    { type = "toggle", key = "reportDestroyed", label = "Report destroyed items in chat", tip = "Says in chat what each click destroyed." },
    { type = "build", label = "Manually included items", card = "lists",
      tip = "Items you dragged onto the destroy button. Drop any bag item there to offer it first in the fan.",
      build = function(root) Helper.Destroy.AddIncludedItemsMenu(root) end },
    { type = "action", name = "Clear keep list", label = "Clear keep list", window = false, danger = true,
      when = function() return Helper.Destroy.KeptCount() > 0 end,
      labelFn = function() return ("Clear keep list (%d)"):format(Helper.Destroy.KeptCount()) end,
      tip = "Forgets the items you said never to destroy.", run = function(_, command) command("keep clear") end },
    Word("Reset position", "reset", "Puts the destroy button back where it started.", { name = "Reset destroy position", card = "appearance" }),
    { type = "custom", render = "protection", card = "lists", label = "Protected from Quick destroy",
      tip = "Items that are never offered. Drag a bag item onto the drop area to protect it." },
  },
  apply = function()
    if Helper.Destroy and Helper.Destroy.Refresh then Helper.Destroy.Refresh() end
  end,
}

-- Action bars ---------------------------------------------------------------------------------------------

local function Bars() return Helper.BarLayouts, Helper.BarUI end

Declare{
  key = "barProfiles", title = "Bar profiles", command = "bars",
  icon = "INV_Misc_Book_09", group = "Action bars", section = true, position = "barProfiles",
  frames = { barProfiles = "Bar profile swap button" },
  description = "Saved action bar layouts you can swap between, per spec.",
  -- The menu row's switch and the optional swap button (BarSwap.lua). The profiles live in `bars`.
  defaults = { enabled = true, button = false, direction = "auto", reportChat = false },
  -- bars[character] = { name, profiles = { [name key] = { name, layout } }, active = { [spec] = name key },
  -- specs = { [spec] = { base, autoUpdate } } }. Undo of a load is kept for the session only.
  data = { bars = {} },
  prefs = { "enabled", "button", "direction", "reportChat" },
  -- (every entry is made for the spec you are in when the menu or page is built, and does nothing after a
  -- spec switch)
  context = function()
    local bars = Bars()
    return { spec = bars and bars.ActiveSpec() }
  end,
  status = function(_, ctx)
    local bars = Bars()
    if not bars or not ctx.spec then return { "Can't tell which spec is active" } end
    local own, other = bars.Profiles(ctx.spec)
    local loaded
    for _, group in ipairs({ own, other }) do
      for _, entry in ipairs(group) do if entry.active then loaded = entry.name end end
    end
    local name, changed = bars.Updatable(ctx.spec)
    local lines = { loaded and (("%s loaded on %s"):format(loaded, bars.SpecName(ctx.spec)))
      or ("No profile loaded on " .. bars.SpecName(ctx.spec)) }
    if name and changed and changed > 0 then lines[#lines + 1] = ("%d change%s since the load"):format(changed, changed == 1 and "" or "s") end
    lines[#lines + 1] = ("%d profile%s saved"):format(#own + #other, #own + #other == 1 and "" or "s")
    return lines
  end,
  statusChips = function(_, ctx)
    local bars = Bars()
    if not bars or not ctx.spec then
      return { { label = "Active spec", value = "Unavailable", tone = "dim" } }
    end
    local own, other = bars.Profiles(ctx.spec)
    local loaded
    for _, group in ipairs({ own, other }) do
      for _, entry in ipairs(group) do if entry.active then loaded = entry.name end end
    end
    local name, changed = bars.Updatable(ctx.spec)
    local chips = {
      { label = "Active spec", value = bars.SpecName(ctx.spec) },
      { label = "Loaded", value = loaded or "None", tone = loaded and "accent" or "dim" },
      { label = "Saved", value = tostring(#own + #other) },
    }
    if name and changed and changed > 0 then
      chips[#chips + 1] = { label = "Unsaved changes", value = tostring(changed), tone = "warn" }
      local reason = bars.AutoUpdateHoldReason and bars.AutoUpdateHoldReason(ctx.spec)
      if reason then return { chips = chips, note = reason } end
    end
    return chips
  end,
  options = {
    Direction(),
    { type = "toggle", label = "Auto-update current spec profile",
      tip = "Writes your bar changes into the profile loaded on this spec as you make them.",
      get = function() return Helper.BarLayouts.AutoUpdate() end,
      set = function(value) Helper.BarLayouts.AutoUpdate(value) end },
    { type = "toggle", key = "reportChat", label = "Report in chat", cmd = "chat",
      tip = "Says in chat when profiles are loaded, saved, updated, renamed, deleted, or undone." },
    { type = "build", label = "Profiles", window = false,
      build = function(root, _, _, ctx, kit)
        local bars = Bars()
        if not ctx.spec then
          root:CreateButton("(can't tell which spec is active)", function() end)
          return
        end
        local own, other = bars.Profiles(ctx.spec)
        local check = "|TInterface\\Buttons\\UI-CheckBox-Check:14:14|t "
        if #own + #other == 0 then
          root:CreateButton("(no profiles yet: save one below)", function() end)
        end
        for _, entry in ipairs(own) do
          kit.Button(root, (entry.active and check or "") .. "Load " .. entry.name, function() bars.Load(entry.key, ctx.spec) end,
            "Load profile")
        end
        for _, entry in ipairs(other) do
          -- (ticked too when it is the one loaded here: an update would write to it)
          kit.Button(root, ("%sLoad %s  |cff999999(from %s)|r"):format(entry.active and check or "", entry.name,
            bars.SpecName(entry.spec)), function() bars.Load(entry.key, ctx.spec) end, "Load profile")
        end
      end },
    { type = "action", label = "Save as new profile...", tip = "Saves your current bars under a new name.",
      when = function(_, ctx) return ctx.spec ~= nil end,
      run = function() local _, ui = Bars(); ui.AskSaveNew() end },
    -- Only the profile loaded on this spec (saved in either spec), once you have changed the bars since loading
    -- it. Changes only in slots it keeps as saved get an entry that says why, never a silently missing option.
    { type = "action", name = "Update", label = "Update", tip = "Updates this profile with the action slots you changed.",
      when = function(_, ctx)
        if not ctx.spec then return false end
        local name, changed = Helper.BarLayouts.Updatable(ctx.spec)
        return name ~= nil and changed > 0
      end,
      labelFn = function(_, ctx)
        local name, changed = Helper.BarLayouts.Updatable(ctx.spec)
        return ('Update "%s" (%d change%s)'):format(name, changed, changed == 1 and "" or "s")
      end,
      run = function(_, _, ctx) Helper.BarLayouts.UpdateActive(ctx.spec, (Helper.BarLayouts.Updatable(ctx.spec))) end },
    -- One level of profile lists, as deep as every other ReadyToWork option: a menu opened from a minimap button
    -- at the screen's edge has no room for a fourth level, and the game drew it over the third.
    { type = "build", label = "Rename and delete", window = false,
      build = function(root, _, _, ctx, kit)
        local bars, ui = Bars()
        if not ctx.spec then return end
        local own, other = bars.Profiles(ctx.spec)
        if #own + #other == 0 then return end
        local all = {}
        for _, entry in ipairs(own) do all[#all + 1] = entry end
        for _, entry in ipairs(other) do all[#all + 1] = entry end
        for _, pair in ipairs({ { "Rename...", function(entry) ui.AskRename(entry.name) end },
            { "Delete...", function(entry) ui.AskDelete(entry.name) end } }) do
          local list = kit.Submenu(root, pair[1])
          for _, entry in ipairs(all) do
            local name = entry.name
            if entry.spec ~= ctx.spec then name = name .. ("  |cff999999(%s)|r"):format(bars.SpecName(entry.spec)) end
            list:CreateButton(name, function() pair[2](entry) end)
          end
        end
      end },
    { type = "action", name = "Undo last load", label = "Undo last load",
      tip = "Puts your bars back as they were before the last load on this spec, keeping slots you changed since. Kept until logout or UI reload.",
      when = function(_, ctx) return ctx.spec ~= nil and Helper.BarLayouts.HasUndo(ctx.spec) end,
      labelFn = function(_, ctx) return ("Undo last load (%s)"):format(Helper.BarLayouts.SpecName(ctx.spec)) end,
      run = function(_, _, ctx) Helper.BarLayouts.Undo(ctx.spec) end },
    { type = "custom", render = "profiles", card = "lists", label = "Saved profiles",
      tip = "Your bar profiles. Load, rename or delete them here." },
    { type = "toggle", key = "button", label = "Swap button", cmd = "button", card = "appearance",
      tip = "The blue book button that switches bar profiles. Alt-drag it to move it." },
    Word("Reset swap button", "button reset", "Puts the blue book swap button back where it started.", { card = "appearance" }),
  },
  tips = {
    ["Load profile"] = "Puts this profile's spells, items and macros on your bars.",
    ["Rename..."] = "Gives a saved profile a new name.",
    ["Delete..."] = "Deletes a saved profile, after asking.",
  },
  apply = function()
    if Helper.BarUI and Helper.BarUI.Refresh then Helper.BarUI.Refresh() end
  end,
}

Declare{
  key = "maxSpells", title = "Spell ranks", oldTitle = "Max spell ranks", command = "spells", aliases = { "maxspells" },
  icon = "INV_Misc_Book_03", group = "Action bars", section = true, perChar = true, menuAlways = true,
  description = "Keeps your bars on the highest rank of each spell, and places new spells.",
  rowTip = "Keeps your action bars on the highest rank of each spell you know, and places newly learned spells in empty slots.",
  -- enabled: upgrade bar spells to the highest rank known. autoPlace: put newly learned spells in empty bar
  -- slots. blockGamePush stays on silently by default so switching specs doesn't re-push dropped spells.
  defaults = { enabled = true, autoPlace = true, reportChanges = false },
  prefs = { "enabled", "autoPlace", "reportChanges" },
  status = function(db)
    return { db.enabled and "Upgrading bar spells" or "Rank upgrades off",
      db.autoPlace and "Places new spells" or "New spells manual" }
  end,
  statusChips = function(db)
    return {
      { label = "Rank upgrades", value = db.enabled and "Active" or "Off", tone = db.enabled and "accent" or "dim" },
      { label = "New spells", value = db.autoPlace and "Auto-place" or "Manual", tone = db.autoPlace and "accent" or "dim" },
    }
  end,
  options = {
    { type = "toggle", key = "autoPlace", label = "Place new spells", cmd = "place",
      tip = "Puts spells new to this character in empty bar slots. Spells you had before, or that come back with a spec switch, stay off." },
    { type = "toggle", key = "reportChanges", label = "Report automatic bar changes in chat",
      tip = "Says in chat each time a bar slot is upgraded or a new spell is placed." },
    Word("Scan now", "scan", "Looks at your bars for lower spell ranks now.", { card = "status", header = true }),
  },
  apply = function(changed, db, command)
    if not command then return end
    if changed.autoPlace then command(db.autoPlace and "place on" or "place off") end
  end,
}

-- World ---------------------------------------------------------------------------------------------------

local function QuestIcons()
  local list = {}
  for _, icon in ipairs(Helper.QuestMarkers and Helper.QuestMarkers.icons or {}) do
    list[#list + 1] = { icon.key, ("|T%s:16:16|t  %s"):format(icon.texture, icon.label) }
  end
  return list
end

Declare{
  key = "questKills", title = "Quest markers", command = "questkills",
  icon = "Ability_Hunter_SniperShot", group = "World", section = true,
  description = "Marks the mobs your quests still need, on their nameplates.",
  rowTip = "Marks nearby quest health bars, your selected target, and the distant quest creature under your pointer when its nameplate is available.",
  -- partyGuesses: in a group, also mark quest mobs the game won't tie to a quest (they may be a party member's).
  defaults = {
    enabled = true, kills = true, loot = true, showCount = true, targetOnly = false,
    killIcon = "sword", lootIcon = "bag", size = 22, placement = "above",
    partyGuesses = false, cursorHover = true,
  },
  prefs = { "enabled", "kills", "loot", "showCount", "targetOnly", "cursorHover", "partyGuesses", "killIcon", "lootIcon", "size",
    "placement" },
  status = function(db)
    local marks = (db.kills and db.loot) and "kill and loot objectives" or db.kills and "kill objectives" or db.loot and "loot sources" or "nothing"
    return { "Marks " .. marks .. (db.targetOnly and ", on your target only" or ""),
      db.partyGuesses and "In groups: includes party guesses" or "In groups: your quests only" }
  end,
  statusChips = function(db)
    local tracking = (db.kills and db.loot) and "Kills & loot" or db.kills and "Kills only" or db.loot and "Loot only" or "Nothing"
    return {
      { label = "Tracking", value = tracking, tone = (db.kills or db.loot) and "accent" or "dim" },
      { label = "Scope", value = db.targetOnly and "Target only" or "All nameplates" },
      { label = "Groups", value = db.partyGuesses and "Includes party guesses" or "Your quests only" },
    }
  end,
  options = {
    { type = "toggle", key = "kills", label = "Kill objectives", tip = "Marks mobs you still need to kill for a quest." },
    { type = "toggle", key = "loot", label = "Loot sources", tip = "Marks mobs that drop items your quests still need." },
    { type = "toggle", key = "showCount", label = "Remaining count",
      tip = "Shows a high-contrast badge on each marker with how many kills or loot items you still need." },
    { type = "toggle", key = "cursorHover", label = "Distant hover icon at cursor",
      tip = "Shows the quest icon above your pointer while hovering a distant, unselected creature." },
    { type = "toggle", key = "targetOnly", label = "Target only", tip = "Restricts quest icons to the currently selected creature." },
    { type = "toggle", key = "partyGuesses", label = "Party guesses",
      tip = "In a group, also marks mobs that may be for a party member's quest (the game doesn't say whose)." },
    { type = "custom", render = "questSamples", card = "appearance", label = "Preview",
      tip = "How your quest icons look beside a nameplate." },
    { type = "choice", key = "killIcon", label = "Kill icon", card = "appearance", choices = QuestIcons,
      tip = "The icon shown by mobs you still need to kill." },
    { type = "choice", key = "lootIcon", label = "Loot icon", card = "appearance", choices = QuestIcons,
      tip = "The icon shown by mobs that drop items your quests still need." },
    { type = "slider", key = "size", label = "Icon size", min = 12, max = 40, card = "appearance",
      menuChoices = { 16, 22, 28, 34 }, menuFormat = tostring, tip = "How big the quest icons are, in pixels." },
    { type = "choice", key = "placement", label = "Icon position", card = "appearance", tip = "Where the quest icon sits beside a nameplate.",
      choices = { { "left", "Left of nameplate" }, { "right", "Right of nameplate" }, { "above", "Above nameplate" } } },
    { type = "action", label = "Preview icons", tip = "Shows your chosen quest icons for a moment.", card = "appearance",
      run = function() Helper.QuestMarkers.preview() end },
  },
  apply = function()
    if Helper.QuestMarkers and Helper.QuestMarkers.refresh then Helper.QuestMarkers.refresh() end
  end,
}

Declare{
  key = "talk", title = "Talk & quests", command = "talk",
  icon = "INV_Misc_Note_01", group = "World", section = true, perChar = true,
  description = "Skips NPC chat, accepts quests and hands them in: three switches, each on its own.",
  rowTip = "Three separate switches: Skip talk picks an NPC's only chat line page after page; Auto-accept takes offered quests; Auto-turn in hands in finished ones. A strip of buttons on the dialog and quest windows flips them. Hold Shift while you start talking to do it yourself that time.",
  -- buttons: where the Skip talk / Accept / Turn in strip sits on the dialogue and quest windows.
  defaults = { enabled = true, skip = false, accept = false, turnIn = false, acceptGrey = true, chat = true, buttons = "top" },
  prefs = { "enabled", "skip", "accept", "turnIn", "acceptGrey", "chat", "buttons" },
  status = function()
    return Helper.Talk and Helper.Talk.Status() or {}
  end,
  statusChips = function()
    return Helper.Talk and Helper.Talk.StatusChips and Helper.Talk.StatusChips() or {}
  end,
  options = {
    { type = "toggle", key = "skip", label = "Skip talk", cmd = "skip",
      tip = "Picks an NPC's only chat line for you (the speech-bubble icon), page after page, while nothing on the page waits on you: no quest to take, no finished quest to hand in. Vendor, trainer, flight, innkeeper and bank options are never picked." },
    { type = "toggle", key = "turnIn", label = "Auto-turn in quests", cmd = "turnin",
      tip = "Hands in finished quests and takes the reward when there is no choice. With a choice of rewards, or a quest that costs gold, the window stays open for you." },
    { type = "toggle", key = "accept", label = "Auto-accept quests", cmd = "accept",
      tip = "Automatically takes the quests an NPC offers. A quest that flags you for PvP is left for you." },
    { type = "toggle", key = "acceptGrey", label = "Include gray quests", cmd = "grey",
      sub = true, requires = "Auto-accept quests",
      enabled = function(db) return db.accept == true end,
      tip = "Also takes quests far below your level (gray in the list) when Auto-accept quests is on. Untick it to leave those for you." },
    { type = "toggle", key = "chat", label = "Report in chat", cmd = "chat",
      tip = "A chat line for each quest accepted or handed in, and when a window was left open for you (a reward to choose, a cost, PvP)." },
    { type = "choice", key = "buttons", label = "Buttons", card = "appearance", cmd = "buttons",
      tip = "Where the Skip talk, Accept and Turn in buttons sit on the dialog and quest windows.",
      choices = { { "top", "Above the window" }, { "bottom", "Below the window" }, { "hidden", "Hidden" } } },
    { type = "note", text = "Hold Shift while you start talking to an NPC to do everything yourself that time. Key bindings for each switch are under Options > Keybindings > ReadyToWork." },
  },
  apply = function()
    if Helper.Talk and Helper.Talk.Refresh then Helper.Talk.Refresh() end
  end,
}

Declare{
  key = "gather", title = "Gather tooltips", oldTitle = "Gathering skill", command = "gather",
  icon = "Trade_Herbalism", group = "World", section = true,
  description = "Shows the skill herbs, ore, locked chests, fishing pools and corpses need, on their tooltips.",
  rowTip = "Hover a herb, ore vein, locked chest, fishing pool or skinnable corpse: its tooltip shows the skill it needs beside yours, colored like a recipe (red: can't yet; orange, yellow, green: skill-up chance; gray: no more skill-ups).",
  defaults = { enabled = true, herbs = true, ore = true, corpses = true, chests = true, fishing = true },
  prefs = { "enabled", "herbs", "ore", "corpses", "chests", "fishing" },
  status = function()
    return Helper.Gather and Helper.Gather.Status() or {}
  end,
  statusChips = function()
    return Helper.Gather and Helper.Gather.StatusChips and Helper.Gather.StatusChips() or {}
  end,
  options = {
    { type = "toggle", key = "herbs", label = "Herbs", cmd = "herbs",
      tip = "Herb tooltips show the Herbalism they need, e.g. \"Herbalism 205 · you 190\"." },
    { type = "toggle", key = "ore", label = "Ore", cmd = "ore",
      tip = "Ore veins and deposits show the Mining they need." },
    { type = "toggle", key = "corpses", label = "Corpses", cmd = "corpses",
      tip = "A corpse the game calls Skinnable (or that needs Herbalism, Mining or Engineering) shows how much skill it needs, worked out from its level." },
    { type = "toggle", key = "chests", label = "Locked chests", cmd = "chests",
      tip = "Locked chests and footlockers show the Lockpicking they need. Some chests of one name have different locks: then the range is shown." },
    { type = "toggle", key = "fishing", label = "Fishing pools", cmd = "fishing",
      tip = "Fishing pools show the Fishing this zone needs (below it nothing bites) and the skill at which every catch is sure." },
    { type = "note", text = "Colors work like recipes: red, you can't yet; orange, a skill-up every time; yellow and green, less often; gray, no more skill-ups. For fishing: red, nothing is caught; yellow, some get away; green, every catch is sure." },
  },
}

Declare{
  key = "flight", title = "Flight timer", command = "flight",
  icon = "Ability_Mount_Gryphon_01", group = "World", section = true, position = "flight",
  frames = { flight = "Flight timer" },
  description = "Counts down to landing on flight paths, and learns each route's time.",
  defaults = { enabled = true, partyButton = true, showTotal = true, showRouteTime = true, times = {}, baseTimes = {}, pace = {} },
  prefs = { "enabled", "partyButton", "showRouteTime", "showTotal" },
  status = function(db)
    local seconds = db.totalSeconds or 0
    return { ("%d route%s timed"):format(Count(db.times), Count(db.times) == 1 and "" or "s"),
      FlightClock(seconds) .. " in the air" }
  end,
  statusChips = function(db)
    local seconds = db.totalSeconds or 0
    return {
      { label = "Routes timed", value = tostring(Count(db.times)) },
      { label = "Time in air", value = FlightClock(seconds), tone = seconds > 0 and "accent" or nil },
    }
  end,
  options = {
    { type = "toggle", key = "partyButton", label = "ETA button", cmd = "party",
      tip = "A chat button on the timer. Click it to send your ETA to your group's chat." },
    { type = "toggle", key = "showTotal", label = "Show lifetime flight time",
      tip = "Shows on the timer how long you have spent on flight paths in all." },
    { type = "toggle", key = "showRouteTime", label = "Show route time at flight masters",
      tip = "Adds each destination's known flight time to its tooltip on the flight map." },
    Word("Preview timer", "test", "Shows the timer for 15 seconds so you can drag it into place.", { card = "appearance" }),
    Word("Reset position", "reset", "Puts the flight timer back where it started.", { name = "Reset timer position", card = "appearance" }),
  },
  apply = function()
    if Helper.Flight and Helper.Flight.RefreshOptions then Helper.Flight.RefreshOptions() end
  end,
}

-- Interface -----------------------------------------------------------------------------------------------

Declare{
  key = "minimapFan", title = "Minimap buttons", oldTitle = "Minimap fan", aliases = { "Minimap & fan" }, command = "fan",
  icon = "INV_Misc_Spyglass_03", group = "Interface", section = true,
  description = "One minimap button: it fans out your other addons' minimap buttons and opens ReadyToWork.",
  rowTip = "Gathers your addons' minimap buttons behind ReadyToWork's minimap button, which fans them out.",
  -- enabled: collect the minimap buttons into the fan (UI\Launcher.lua, was the addon Minimap Fan).
  defaults = { enabled = true, autoClose = true, angle = 225, ignored = {}, order = {}, pageSize = 15, style = "fan" },
  prefs = { "enabled", "autoClose", "angle", "ignored", "order", "pageSize", "style" },
  atomic = { order = true },
  noReset = { angle = true },
  status = function(db)
    local count = Helper.FanButtons and #Helper.FanButtons(true) or 0
    return { db.enabled and ("%d button%s in the fan"):format(count, count == 1 and "" or "s") or "Fan off: buttons stay on minimap",
      ("%d left on the minimap"):format(Count(db.ignored)) }
  end,
  statusChips = function(db)
    local count = Helper.FanButtons and #Helper.FanButtons(true) or 0
    return {
      chips = {
        { label = "In fan", value = db.enabled and tostring(count) or "Off", tone = db.enabled and "accent" or "dim" },
        { label = "On minimap", value = tostring(Count(db.ignored)) },
      },
      note = "Left-click: fan · Right-click: quick menu · Shift-click: settings",
    }
  end,
  options = {
    { type = "toggle", key = "enabled", feature = "minimap", label = "Show minimap button",
      tip = "ReadyToWork's minimap button. Hidden, the fan can't open; /rtw settings and the key bindings still work.",
      set = function(value, _, command) command(value and "on" or "off") end },
    { type = "toggle", key = "locked", feature = "minimap", label = "Lock minimap button",
      sub = true, requires = "Show minimap button",
      enabled = function(db) return db.enabled ~= false end,
      tip = "Stops the minimap button from being dragged around the minimap." },
    { type = "action", label = "Customize fan…", tip = "Opens the fan's layout and button order in the settings window.", window = false,
      run = function() Helper.OpenSettings("Minimap buttons") end },
    { type = "toggle", key = "autoClose", label = "Auto-close", tip = "Closes the fan shortly after the pointer leaves it.",
      set = function(value, db, command) if db.autoClose ~= value then command("autoclose") end end },
    Word("Reset position", "reset", "Puts the minimap button back where it started on the minimap.", { name = "Reset fan position", card = "appearance" }),
    { type = "custom", render = "fanEditor", card = "appearance", label = "Fan layout",
      tip = "How the fan opens, how many buttons a page holds, and their order." },
    { type = "custom", render = "fanButtons", card = "lists", label = "Collected buttons",
      tip = "Every minimap button the fan found. Untick one to leave it on the minimap." },
  },
  apply = function(changed)
    if Helper.RefreshFan then Helper.RefreshFan(changed.angle) end
  end,
}

-- ReadyToWork's minimap button (UI\Launcher.lua). Its options are on the Minimap & fan page.
Declare{
  key = "minimap", title = "Minimap button", command = "minimap",
  defaults = { enabled = true, locked = false },
  prefs = { "enabled", "locked" },
  apply = function()
    if Helper.RefreshLauncher then Helper.RefreshLauncher() end
  end,
}

Declare{
  key = "general", title = "General",
  icon = "INV_Misc_Gear_01", group = "Interface", section = true,
  singleCard = true, cardTitle = "Workspace & controls",
  description = "Moving ReadyToWork's frames, key bindings and the introduction.",
  -- hints: [positions key] = true once that frame's one-line hint was shown.
  defaults = { hints = {}, updateChat = false },
  prefs = { "updateChat" },
  status = function()
    local count = 0
    for _ in pairs(Helper.Frames and Helper.Frames.Movable() or {}) do count = count + 1 end
    return { ("%d movable frames"):format(count), "Key bindings under Options > Keybindings > ReadyToWork" }
  end,
  statusChips = function()
    local count = 0
    for _ in pairs(Helper.Frames and Helper.Frames.Movable() or {}) do count = count + 1 end
    return {
      { label = "Movable frames", value = tostring(count), tone = "accent" },
    }
  end,
  options = {
    { type = "note", text = "Unlock frames outlines every RTW frame so you can drag to move, scroll to resize, or right-click to reset. Alt-drag also moves any frame anytime." },
    { type = "toggle", key = "updateChat", label = "Announce updates in chat",
      tip = "Prints a short chat notice once when ReadyToWork updates to a new version (off by default)." },
    { type = "action", label = "Unlock frames", run = function() Helper.commands.unlock() end },
    { type = "action", label = "Key bindings", tip = "Opens the game's key bindings, where ReadyToWork's are under ReadyToWork.",
      run = function() if Helper.OpenKeyBindings then Helper.OpenKeyBindings() end end },
    { type = "action", label = "Introduction", run = function() if Helper.ShowIntro then Helper.ShowIntro() end end },
    { type = "action", label = "Reset positions", danger = true, run = function() Helper.ResetPositions() end },
    { type = "custom", render = "characterCopy", label = "Character settings",
      tip = "Copy per-character settings and item lists from another character on this account." },
  },
}
