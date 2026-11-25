-- Adds the skill a herb, ore vein, locked chest, fishing pool or corpse needs to its tooltip, beside yours,
-- colored like a recipe: red can't, orange / yellow / green skill-up chance, grey no more skill-ups.
--
-- Where the numbers come from (GatherData.lua, built by Tools/gatherdata.py): the open Classic server database (CMaNGOS
-- classic-db) joined to the game's own Lock table. The rules are that server's:
--   gathering skill-ups (Player::UpdateGatherSkill): orange below need+25, yellow below +50, green below
--     +100, grey from +100; something that needs 1 counts as needing 5 there;
--   corpses (Spell::EffectSkinning): level under 10 needs 1, under 20 needs (level-10)*10, else level*5;
--   fishing (GameObject fishing): zone skill from skill_fishing_base_level (subzone first, then zone);
--     below it nothing is caught, and a catch is sure from zone skill + 95.
-- Your skill comes from C_SkillInfo (rank, plus bonuses as modifier). Tooltip text and units can be secret
-- values: then nothing is added.

local _, Helper = ...

local Gather = {}
Helper.Gather = Gather

local SKILL_IDS = { herb = 182, mine = 186, skin = 393, fish = 356, lock = 633, eng = 202 }
local SKILL_NAMES = { herb = "Herbalism", mine = "Mining", skin = "Skinning", fish = "Fishing", lock = "Lockpicking",
  eng = "Engineering" }
local STATUS_ORDER = { "herb", "mine", "skin", "fish", "lock" }
local COLORS = {
  red = { 1, .13, .13 }, orange = { 1, .5, .25 }, yellow = { 1, 1, 0 }, green = { .25, .75, .25 }, grey = { .55, .55, .55 },
}
-- The game's corpse lines (GlobalStrings) -> the skill they stand for.
local CORPSE_LINES = {
  { "UNIT_SKINNABLE_LEATHER", "skin" }, { "UNIT_SKINNABLE_HERB", "herb" },
  { "UNIT_SKINNABLE_ROCK", "mine" }, { "UNIT_SKINNABLE_BOLTS", "eng" },
}

local settings
local skillCache = {}
local cachedZone, cachedSub

local function Readable(value)
  if canaccessvalue then
    if not canaccessvalue(value) then return false end
    if type(value) == "table" and canaccesstable then
      return canaccesstable(value) == true
    end
    return true
  end
  return not issecretvalue or not issecretvalue(value)
end

local function Plain(value)
  if Readable(value) then return value end
end

local function Call(func, ...)
  if type(func) ~= "function" then return nil end
  local ok, a, b = pcall(func, ...)
  if ok then return Plain(a), Plain(b) end
end

local function Text(line)
  local text = Readable(line) and type(line) == "table" and Plain(line.leftText)
  return type(text) == "string" and text or nil
end

local function ReadSkillLive(id, kind)
  local info = C_SkillInfo
  if not (id and info) then return false, nil end
  local found
  local secretSeen = false
  if info.GetSkillLineInfoByID then
    local ok, attributes = pcall(info.GetSkillLineInfoByID, id)
    if not ok or not Readable(attributes) then
      secretSeen = true
    elseif type(attributes) == "table" then
      found = attributes
    end
  end
  if not found and not secretSeen and info.GetNumSkillLines and info.GetSkillLineInfo then
    local countOk, count = pcall(info.GetNumSkillLines)
    if not countOk or not Readable(count) then
      secretSeen = true
    elseif type(count) == "number" then
      for i = 1, count do
        local lineOk, attributes = pcall(info.GetSkillLineInfo, i)
        if not lineOk or not Readable(attributes) then
          secretSeen = true
          break
        elseif type(attributes) == "table" and Plain(attributes.skillID) == id then
          found = attributes
          break
        end
      end
    end
  end
  if secretSeen then return true, nil end
  if not found then return false, nil end
  local rawRank = found.rank
  if not Readable(rawRank) then return true, nil end
  if type(rawRank) ~= "number" or rawRank <= 0 then return false, nil end
  local bonus = Plain(found.modifier)
  local name = Plain(found.name)
  return false, {
    rank = rawRank,
    bonus = type(bonus) == "number" and bonus or 0,
    name = type(name) == "string" and name ~= "" and name or SKILL_NAMES[kind],
  }
end

-- Your skill: rank, bonus, name. nil when you haven't learned it.
function Gather.Skill(kind)
  local id = SKILL_IDS[kind]
  if not id then return nil end
  local secretSeen, live = ReadSkillLive(id, kind)
  if not secretSeen then
    skillCache[kind] = live
    if not live then return nil end
    return live.rank, live.bonus, live.name
  end
  local cached = skillCache[kind]
  if cached then
    return cached.rank, cached.bonus, cached.name
  end
end

local function RefreshSkillCache()
  for kind in pairs(SKILL_IDS) do
    Gather.Skill(kind)
  end
end

local function RefreshZoneCache()
  local zone = GetRealZoneText and Call(GetRealZoneText) or nil
  if type(zone) == "string" and zone ~= "" then
    cachedZone = zone
    local sub = GetSubZoneText and Call(GetSubZoneText) or nil
    cachedSub = type(sub) == "string" and sub or ""
  end
end

-- How a gathering need looks for a given skill: "red" | "orange" | "yellow" | "green" | "grey".
function Gather.Color(rank, bonus, need)
  if not rank or rank + (bonus or 0) < need then return "red" end
  local base = need <= 1 and 5 or need
  if rank >= base + 100 then return "grey" end
  if rank >= base + 50 then return "green" end
  if rank >= base + 25 then return "yellow" end
  return "orange"
end

-- The skill a corpse of this level needs, nil for an unknown (??) level.
function Gather.CorpseNeed(level)
  if type(level) ~= "number" or level <= 0 then return nil end
  if level < 10 then return 1 end
  if level < 20 then return (level - 10) * 10 end
  return level * 5
end

local function You(rank, bonus)
  if not rank then return "not learned" end
  return bonus and bonus ~= 0 and ("you %d (%+d)"):format(rank, bonus) or ("you %d"):format(rank)
end

-- One tooltip line for a gathering need: a number, or a list (objects of one name with different locks).
function Gather.Line(kind, need)
  local rank, bonus, name = Gather.Skill(kind)
  name = name or SKILL_NAMES[kind]
  local low, high = need, need
  if type(need) == "table" then low, high = need[1], need[#need] end
  local color
  if low == high then
    color = Gather.Color(rank, bonus, low)
  else
    local have = rank and rank + (bonus or 0)
    color = (not have or have < low) and "red" or have < high and "orange" or Gather.Color(rank, bonus, high)
  end
  local needText = low == high and tostring(low) or ("%d-%d"):format(low, high)
  local text = ("%s %s · %s"):format(name, needText, You(rank, bonus))
  if low ~= high then text = text .. " (depends on the lock)" end
  return text, color
end

-- The fishing line for the zone you're in, nil when the zone's skill isn't known.
function Gather.FishingLine()
  local data = Helper.GatherData
  local liveZone = GetRealZoneText and Call(GetRealZoneText) or nil
  local liveSub = GetSubZoneText and Call(GetSubZoneText) or nil
  local zone, sub
  if type(liveZone) == "string" then
    zone = liveZone
    sub = type(liveSub) == "string" and liveSub or ""
    if zone ~= "" then
      cachedZone, cachedSub = zone, sub
    end
  else
    zone, sub = cachedZone, cachedSub
  end
  if type(zone) ~= "string" then return nil end
  local need = type(sub) == "string" and sub ~= "" and data.fishSubzones[zone .. "\t" .. sub] or data.fishZones[zone]
  if not need then return nil end
  local rank, bonus, name = Gather.Skill("fish")
  name = name or SKILL_NAMES.fish
  local have = rank and rank + (bonus or 0)
  local sure = need + 95
  local color = (not have or have < need) and "red" or have < sure and "yellow" or "green"
  local needText = need <= 1 and ("any %s"):format(name) or ("%s %d"):format(name, need)
  return ("%s here · %s · sure catch at %d"):format(needText, You(rank, bonus), math.max(sure, 1)), color
end

local function Add(tooltip, text, color)
  if not text or (tooltip.IsForbidden and tooltip:IsForbidden()) then return end
  local rgb = COLORS[color] or COLORS.grey
  tooltip:AddLine(text, rgb[1], rgb[2], rgb[3])
end

-- A game object's entry ID from its GUID (GameObject-0-server-instance-zone-ID-spawn), when the tooltip has one.
local function ObjectID(guid)
  guid = Plain(guid)
  if type(guid) ~= "string" then return nil end
  local id = select(6, strsplit("-", guid))
  return guid:match("^GameObject") and tonumber(id) or nil
end

-- The line a world object's tooltip gets, by its name (and ID, for chests).
function Gather.ObjectLine(name, guid)
  local data = Helper.GatherData
  if type(name) ~= "string" or not data then return nil end
  if settings.herbs and data.herbs[name] then return Gather.Line("herb", data.herbs[name]) end
  if settings.ore and data.mine[name] then return Gather.Line("mine", data.mine[name]) end
  if settings.chests then
    local id = ObjectID(guid)
    local need = id and data.lockIDs[id] or data.lock[name]
    if need then return Gather.Line("lock", need) end
  end
  if settings.fishing and data.pools[name] then return Gather.FishingLine() end
end

-- The line a corpse's tooltip gets: the game says "Skinnable" (or "Requires Herbalism", ...), not how much.
function Gather.CorpseLine(lines, level)
  if not settings.corpses or type(lines) ~= "table" then return nil end
  for _, line in ipairs(lines) do
    local text = Text(line)
    if text then
      for _, pair in ipairs(CORPSE_LINES) do
        local wanted = _G[pair[1]]
        if type(wanted) == "string" and text == wanted then
          local need = Gather.CorpseNeed(level)
          if not need then
            local rank, bonus, name = Gather.Skill(pair[2])
            return ("%s: level unknown · %s"):format(name or SKILL_NAMES[pair[2]], You(rank, bonus)), "grey"
          end
          return Gather.Line(pair[2], need)
        end
      end
    end
  end
end

-- Status lines for the home page and the Status card.
function Gather.Status()
  local known = {}
  for _, kind in ipairs(STATUS_ORDER) do
    local rank, bonus, name = Gather.Skill(kind)
    if rank then known[#known + 1] = ("%s %d%s"):format(name, rank, bonus ~= 0 and (" (%+d)"):format(bonus) or "") end
  end
  local shown = {}
  for _, pair in ipairs({ { "herbs", "herbs" }, { "ore", "ore" }, { "corpses", "corpses" }, { "chests", "locked chests" }, { "fishing", "fishing pools" } }) do
    if settings and settings[pair[1]] then shown[#shown + 1] = pair[2] end
  end
  return { #known > 0 and ("Your skills: " .. table.concat(known, " · ")) or "No gathering skill learned yet",
    #shown > 0 and ("On tooltips of " .. table.concat(shown, ", ")) or "Every kind is switched off" }
end

function Gather.StatusChips()
  local chips = {}
  for _, kind in ipairs(STATUS_ORDER) do
    local rank, bonus, name = Gather.Skill(kind)
    if rank then
      chips[#chips + 1] = {
        label = name,
        value = bonus ~= 0 and ("%d (%+d)"):format(rank, bonus) or tostring(rank),
        tone = "accent",
      }
    end
  end
  if #chips == 0 then
    chips[1] = { label = "Gathering skills", value = "None learned yet", tone = "dim" }
  end
  return chips
end

local WORDS = { herbs = "Herbs", ore = "Ore", corpses = "Corpses", chests = "Locked chests", fishing = "Fishing pools" }

local function LevelPattern()
  local fmt = _G and _G.TOOLTIP_UNIT_LEVEL
  if type(fmt) == "string" and fmt ~= "" then
    local pat = fmt:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("%%%%s", ".-"):gsub("%%%%d", "(%%d+)")
    if pat:find("(%d+)", 1, true) then return pat end
  end
  return "[Ll]evel%s+(%d+)"
end

local function TooltipLevel(lines)
  if type(lines) ~= "table" then return nil end
  local pat = LevelPattern()
  for _, line in ipairs(lines) do
    local text = Text(line)
    if text then
      local lvl = text:match(pat) or text:match("[Ll]evel%s+(%d+)")
      if lvl then return tonumber(lvl) end
    end
  end
end

Helper.Feature(function()
  settings = Helper.db.gather
  RefreshSkillCache()
  RefreshZoneCache()
  Helper.On("PLAYER_ENTERING_WORLD", function()
    RefreshSkillCache()
    RefreshZoneCache()
  end)
  for _, event in ipairs({ "SKILL_LINES_CHANGED", "CHAT_MSG_SKILL" }) do
    Helper.On(event, RefreshSkillCache)
  end
  if Helper.OnUnit then
    Helper.OnUnit("UNIT_INVENTORY_CHANGED", { "player" }, RefreshSkillCache)
  end
  for _, event in ipairs({ "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA" }) do
    Helper.On(event, RefreshZoneCache)
  end
  if not (Helper.GatherData and TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType) then
    return
  end
  local types = Enum.TooltipDataType
  TooltipDataProcessor.AddTooltipPostCall(types.Object, function(tooltip, data)
    if tooltip ~= GameTooltip or not settings.enabled or not Readable(data) or type(data) ~= "table" then return end
    local lines = Plain(data.lines)
    local name = type(lines) == "table" and Text(lines[1]) or nil
    if not name and _G and _G.GameTooltipTextLeft1 and _G.GameTooltipTextLeft1.GetText then
      name = Call(_G.GameTooltipTextLeft1.GetText, _G.GameTooltipTextLeft1)
    end
    local text, color = Gather.ObjectLine(name, data.guid)
    Add(tooltip, text, color)
  end)
  TooltipDataProcessor.AddTooltipPostCall(types.Unit, function(tooltip, data)
    if tooltip ~= GameTooltip or not settings.enabled or not settings.corpses or not Readable(data) or type(data) ~= "table" then return end
    local lines = Plain(data.lines)
    if type(lines) ~= "table" then return end
    local guid = Plain(data.guid)
    local unit = type(guid) == "string" and UnitTokenFromGUID and Call(UnitTokenFromGUID, guid) or nil
    if not unit then
      local candidate
      if tooltip.GetUnit then
        local _, tipUnit = Call(tooltip.GetUnit, tooltip)
        candidate = tipUnit
      end
      if type(candidate) ~= "string" or candidate == "" then candidate = "mouseover" end
      if UnitExists and Call(UnitExists, candidate) then
        local candGuid = UnitGUID and Call(UnitGUID, candidate)
        if not (type(guid) == "string" and type(candGuid) == "string" and guid ~= candGuid) then
          unit = candidate
        end
      end
    end
    local dead = unit and UnitIsDead and Call(UnitIsDead, unit)
    if dead == false then return end
    local level = unit and UnitLevel and Call(UnitLevel, unit)
    if type(level) ~= "number" then
      level = TooltipLevel(lines)
    end
    local text, color = Gather.CorpseLine(lines, level)
    Add(tooltip, text, color)
  end)

  Helper.commands.gather = function(rest)
    local word, arg = rest:match("^(%S*)%s*(.-)$")
    if WORDS[word] and (arg == "on" or arg == "off") then
      settings[word] = arg == "on"
      Helper.Print(("%s: skill on their tooltips %s."):format(WORDS[word], arg))
    elseif word == "on" or word == "off" or word == "" then
      Helper.Toggle(settings, word, "Gathering skill on tooltips")
    else
      Helper.Print("/rtw gather [on|off|herbs on|off|ore on|off|corpses on|off|chests on|off|fishing on|off]")
    end
  end
  Helper.help[#Helper.help + 1] = "/rtw gather [on|off] - the skill herbs, ore, chests, fishing pools and corpses need, on their tooltips"
end)
