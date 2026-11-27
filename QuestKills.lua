local _, Helper = ...

local REFRESH_DELAY = 0.10
local RETRY_DELAYS = { 0.2, 0.65 }
local ALIASES = { "target", "mouseover" }
local ICONS = {
  { key = "sword", label = "Sword", texture = "Interface\\Icons\\INV_Sword_04" },
  { key = "bag", label = "Bag", texture = "Interface\\Icons\\INV_Misc_Bag_10" },
}
local RAID_ICONS = { "Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull" }
for index, name in ipairs(RAID_ICONS) do
  ICONS[#ICONS + 1] = {
    key = name:lower(), label = name, texture = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_" .. index,
  }
end
local iconsByKey = {}
for _, icon in ipairs(ICONS) do
  iconsByKey[icon.key] = icon
end
local PLACEMENTS = {
  left = { "RIGHT", "LEFT", -5, 0 },
  right = { "LEFT", "RIGHT", 5, 0 },
  above = { "BOTTOM", "TOP", 0, 5 },
}
local settings, lineTypes, refreshTimer
local questByID, idByTitle = {}, {}
local questRevision=0
local reindex
local markers, unitsByPlate, spareMarkers, retries = {}, {}, {}, {}
local LOG_SIZE, LOG_REPEAT = 30, 60
local NO_MATCH = "No enabled unfinished kill or loot objective of yours matches this mob."
local SWITCHED_OFF = "WoW links this mob to one of your quests, but its kind of objective is switched off."
local PARTY_UNSURE = "In a group the game doesn't say whether this quest mob is for your quest or a party member's, so it isn't marked."
local logged = {}               -- name|outcome -> when it may be logged again
local preview, previewTimer

local function Readable(value)
  if canaccessvalue then
    if not canaccessvalue(value) then
      return false
    end
    -- (a table can be readable itself and still hold hidden values: then it can't be indexed)
    if type(value) == "table" and canaccesstable then
      return canaccesstable(value) == true
    end
    return true
  end
  return not issecretvalue or not issecretvalue(value)
end

local function Public(value)
  if Readable(value) then
    return value
  end
end

local function Read(getter, ...)
  if type(getter) ~= "function" then
    return
  end
  local ok, value, second = pcall(getter, ...)
  if ok then
    return Public(value), Public(second)
  end
end

local function Normalize(text)
  if not Readable(text) or type(text) ~= "string" then
    return
  end
  text = text:gsub("|H.-|h%[(.-)%]|h", "%1"):gsub("|H.-|h(.-)|h", "%1")
    :gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|A.-|a", "")
    :gsub("%s+", " "):match("^%s*(.-)%s*$")
  if text ~= "" then
    return text:lower()
  end
end

local function ObjectiveLabel(text)
  local label = Normalize(text)
  if not label then
    return
  end
  label = label:gsub("^•%s*", ""):gsub("^[-*]%s+", "")
  -- The quest log and the tooltip can put the counter on opposite ends, or in brackets.
  local have, need, body = label:match("^(%d+)%s*/%s*(%d+)%s+(.+)$")
  if not body then
    body, have, need = label:match("^(.-)%s*:%s*(%d+)%s*/%s*(%d+)$")
  end
  if not body then
    body, have, need = label:match("^(.-)%s*%((%d+)%s*/%s*(%d+)%)$")
  end
  if not body then
    body, have, need = label:match("^(.-)%s+(%d+)%s*/%s*(%d+)$")
  end
  return body or label, tonumber(have), tonumber(need)
end

local function IsUnfinished(have, need)
  return type(have) ~= "number" or type(need) ~= "number" or need <= 0 or have < need
end

local ScheduleRefresh
local function activeRowsReady() ScheduleRefresh(true) end

-- A fingerprint of what the index holds: the quest log updates many times a minute in a group, and a rebuild
-- that changed nothing needs no new look at every nameplate (each look builds a tooltip).
local indexSignature
local function Signature(byID)
  local parts = {}
  for id, labels in pairs(byID) do
    for label, entry in pairs(labels) do
      if entry then
        parts[#parts + 1] = id .. ":" .. label .. "=" .. tostring(entry.kind) .. ":" .. tostring(entry.remaining or 0)
      else
        parts[#parts + 1] = id .. ":" .. label .. "=false"
      end
    end
  end
  table.sort(parts)
  return table.concat(parts, ";")
end

-- Rebuilds the index of your unfinished objectives. Returns whether it changed.
local function IndexObjectives()
  local previousByID, previousTitles = questByID, idByTitle
  questByID, idByTitle = {}, {}
  local active=LibQuestieDB and LibQuestieDB.ActiveQuests and LibQuestieDB.ActiveQuests(activeRowsReady)
  for index = 1, active and #active or Read(C_QuestLog.GetNumQuestLogEntries) or 0 do
    local info = active and active[index] or Read(C_QuestLog.GetInfo, index)
    if type(info) == "table" and Public(info.isHeader) == false then
      local id, title = Public(info.questID), Normalize(info.title)
      if type(id) == "number" and id > 0 then
        if title then
          if idByTitle[title] == nil then idByTitle[title] = id
          elseif idByTitle[title] ~= id then idByTitle[title] = false end
        end
        if Read(C_QuestLog.IsComplete, id) == false then
          local objectives = Read(C_QuestLog.GetQuestObjectives, id)
          if type(objectives) == "table" then
            local labels = {}
            for _, objective in ipairs(objectives) do
              if Readable(objective) and type(objective) == "table" then
                local label, textHave, textNeed = ObjectiveLabel(objective.text)
                if label then
                  local kind = Public(objective.type)
                  local have, need = Public(objective.numFulfilled), Public(objective.numRequired)
                  if type(have) ~= "number" or type(need) ~= "number" then
                    have, need = textHave, textNeed
                  end
                  local unfinished = (kind == "monster" or kind == "item")
                    and Public(objective.finished) == false
                    and IsUnfinished(have, need)
                  local remaining = unfinished and type(have) == "number" and type(need) == "number"
                    and need > have and (need - have) or nil
                  -- (two objectives with the same text: an unfinished one wins, a finished one never overwrites it)
                  if unfinished then
                    local existing = labels[label]
                    if not existing then
                      labels[label] = { kind = kind, remaining = remaining }
                    elseif remaining and (not existing.remaining or remaining > existing.remaining) then
                      existing.remaining = remaining
                    end
                  elseif labels[label] == nil then
                    labels[label] = false
                  end
                end
              end
            end
            for _, entry in pairs(labels) do
              if entry then
                questByID[id] = labels
                break
              end
            end
          end
        end
      end
    end
  end
  local signature = Signature(questByID)
  if signature == indexSignature and previousByID then
    questByID, idByTitle = previousByID, previousTitles
    return false
  end
  indexSignature = signature
  questRevision = questRevision + 1
  return true
end

local function NameKey(name)
  local normalized = Normalize(name)
  return normalized and normalized:gsub("%s*%-%s*", " ")
end

-- The tooltip says which quest objectives a mob counts for: a quest title line, then (in a group, under
-- each member who has the quest) its objective lines. Your own quest log says which of those you still
-- need, so whose progress a line shows doesn't matter: a mob that counts for an objective you haven't
-- finished is yours to kill or loot. (Matching the lines to your name failed inside dungeons, where
-- you're grouped and the game can hide names: no marker at all.) A quest that isn't in your log, or an
-- objective you've finished, isn't marked.
-- The kind of mark for quests of yours the tooltip names when it hides their objective lines: their
-- unfinished objectives decide. A quest with only loot left marks a loot source, only kills a kill target;
-- with both, a loot source (the mob is in the quest either way).
local function KindOfQuests(quests)
  local itemCount, itemRem, monsterCount, monsterRem = 0, nil, 0, nil
  local seen = {}
  for _, labels in ipairs(quests) do
    if not seen[labels] then
      seen[labels] = true
      for _, entry in pairs(labels) do
        if entry then
          if entry.kind == "item" then
            itemCount = itemCount + 1
            itemRem = itemCount == 1 and entry.remaining or nil
          elseif entry.kind == "monster" then
            monsterCount = monsterCount + 1
            monsterRem = monsterCount == 1 and entry.remaining or nil
          end
        end
      end
    end
  end
  if itemCount > 0 and settings.loot then
    return "item", itemRem
  end
  if monsterCount > 0 and settings.kills then
    return "monster", monsterRem
  end
end

-- Every unfinished objective of yours, whatever its quest: for a quest line the game won't identify.
local function AllLabels()
  local all = {}
  for _, labels in pairs(questByID) do
    for label, entry in pairs(labels) do
      if entry then
        local existing = all[label]
        if not existing then
          all[label] = { kind = entry.kind, remaining = entry.remaining }
        elseif entry.remaining and (not existing.remaining or entry.remaining > existing.remaining) then
          existing.remaining = entry.remaining
        end
      end
    end
  end
  return all
end

-- Inside dungeons (Zul'Farrak, 2026-11-16) the game hides the mob's name, the quest line's ID and title,
-- and usually the objective text. What is left is that the tooltip HAS a quest line: the mob counts for a
-- quest. Then:
--   * a readable objective line is matched against all your unfinished objectives (exact);
--   * a quest line of yours the game named, with its objectives hidden, is decided by that quest;
--   * a quest line nobody can identify, with nothing readable under it, returns nil with QUEST_HIDDEN: the
--     game's own related-to-your-quest check decides, or failing that your log does (GuessKind).
-- A readable objective you have finished (20/20) still means not needed.
local QUEST_HIDDEN = "The game hides which quest this unit's tooltip lists."

local function MatchTooltip(data)
  if type(data) ~= "table" then
    return nil, "WoW did not expose a readable unit tooltip."
  end
  local lines = Public(data.lines)
  if type(lines) ~= "table" then
    return nil, "WoW did not expose readable tooltip lines."
  end
  local labels, sawQuest, hidden, unnamedQuest, readableObjective
  local sawKill, killRemaining, sawLoot, lootRemaining
  local named = {}   -- quests of yours the tooltip names
  local shown = {}   -- what the tooltip showed, for the log when nothing matches
  for _, line in ipairs(lines) do
    local lineType = Readable(line) and type(line) == "table" and Public(line.type)
    if not lineType then
      labels = nil   -- (an unreadable line: what follows can't be tied to the quest above it)
      hidden = true
    elseif lineType == lineTypes.QuestTitle then
      sawQuest = true
      local id = Public(line.id)
      local title = Normalize(line.leftText)
      -- Prefer the authoritative quest ID. Use a unique title for older payloads.
      if not (type(id) == "number" and id > 0) then
        id = title and idByTitle[title] or nil
      end
      if id then
        labels = questByID[id]
        if labels then named[#named + 1] = labels end
        if #shown < 6 then
          shown[#shown + 1] = "quest " .. (title or ("#" .. tostring(id))) .. (labels and "" or " (nothing of it left to do)")
        end
      else
        -- The game won't say which quest: its objective lines are matched against all of yours.
        unnamedQuest = true
        labels = AllLabels()
        if #shown < 6 then shown[#shown + 1] = "a quest the game won't name" end
      end
    elseif lineType == lineTypes.QuestObjective and labels then
      local label = ObjectiveLabel(line.leftText)
      if not label then
        hidden = true   -- (inside dungeons the game hides this text from addons: "Troll Temper 14/20")
      else
        readableObjective = true
      end
      if #shown < 6 then
        shown[#shown + 1] = "objective " .. (label and ('"' .. label .. '"') or "hidden")
      end
      local entry = label and labels[label]
      local kind = entry and entry.kind
      local rem = entry and entry.remaining
      if kind == "monster" and settings.kills then
        sawKill = true
        if rem and (not killRemaining or rem > killRemaining) then killRemaining = rem end
      elseif kind == "item" and settings.loot then
        sawLoot = true
        if rem and (not lootRemaining or rem > lootRemaining) then lootRemaining = rem end
      end
    end
  end
  if sawKill then
    return "monster", nil, nil, killRemaining
  end
  if sawLoot then
    return "item", nil, nil, lootRemaining
  end
  local detail = #shown > 0 and ("its tooltip showed: " .. table.concat(shown, ", ")) or nil
  if hidden or unnamedQuest then
    -- A quest of yours the game named, with what it says under it hidden: that quest's own unfinished
    -- objectives decide.
    local kind, rem = KindOfQuests(named)
    if kind then
      return kind, "hidden", nil, rem
    end
    -- A quest line nobody can identify and nothing readable under it: still a quest mob.
    if unnamedQuest and not readableObjective then
      return nil, QUEST_HIDDEN, detail
    end
    if unnamedQuest then
      return false, NO_MATCH, detail   -- (its objectives were readable: none of them is one you still need)
    end
    return nil, "WoW hid this unit's quest objective lines.", detail
  end
  if not sawQuest then
    return nil, "WoW did not expose quest objectives for this unit."
  end
  return false, NO_MATCH, detail
end

-- The game says the mob is a quest mob (C_QuestLog.UnitIsRelatedToActiveQuest, or a quest line it won't
-- name) but not which quest: a kill objective of yours whose text names the mob, else, from "you still have a
-- loot objective", a loot source. Returns the kind (or false) and why not.
-- That last guess can't tell your quests from your party's: in a group the game flags a party member's quest
-- mobs too, and they were marked as your loot (user, 2026-11-16: "showing loot for people in my party that are
-- on a quest, I am not on that quest"). In a group (`strict`) only the name match counts, unless
-- settings.partyGuesses is on.
-- Whether objective text `label` names the mob `name` as a whole word ("rat" is in "rats slain", not in
-- "pirates slain"; before 1.30 any part of a word matched).
local function NamesMob(label, name)
  local pattern = "%f[%w]" .. name:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
  for _, ending in ipairs({ "", "s", "es" }) do
    if label:find(pattern .. ending .. "%f[^%w]") then
      return true
    end
  end
  return false
end

local function GuessKind(unit, strict)
  local name = NameKey(Read(UnitName, unit))
  local itemCount, itemRem, monsterCount, monsterRem = 0, nil, 0, nil
  local matchedName, matchedRem = false, nil
  for _, labels in pairs(questByID) do
    for label, entry in pairs(labels) do
      if entry then
        if entry.kind == "monster" then
          monsterCount = monsterCount + 1
          monsterRem = monsterCount == 1 and entry.remaining or nil
          if name and NamesMob(label, name) then
            matchedName = true
            if entry.remaining and (not matchedRem or entry.remaining > matchedRem) then
              matchedRem = entry.remaining
            end
          end
        elseif entry.kind == "item" then
          itemCount = itemCount + 1
          itemRem = itemCount == 1 and entry.remaining or nil
        end
      end
    end
  end
  if matchedName then
    return settings.kills and "monster" or false, SWITCHED_OFF, matchedRem
  end
  if strict then
    return false, PARTY_UNSURE
  end
  if itemCount > 0 then
    return settings.loot and "item" or false, SWITCHED_OFF, itemRem
  end
  return monsterCount > 0 and settings.kills and "monster" or false, SWITCHED_OFF, monsterRem
end

-- Guessing is only safe alone: in a group a quest mob may be a party member's.
local function MustBeSure()
  return not settings.partyGuesses and Read(IsInGroup) == true
end

local function SameUnit(unit, other)
  return Read(UnitIsUnit, unit, other) == true
end

local function MatchUnitTooltip(unit,data)
  data=data or Read(C_TooltipInfo.GetUnit,unit)
  local guid=type(data)=="table" and Public(data.guid)
  if guid then
    local current=Read(UnitGUID,unit)
    if current and current~=guid then return nil,"WoW is still updating the unit tooltip." end
  end
  return MatchTooltip(data)
end

local function NeededObjective(unit, tooltipData)
  if not next(questByID) then
    return false, "Your log has no unfinished kill or loot objectives."
  end
  local attack, dead, player = Read(UnitCanAttack, "player", unit), Read(UnitIsDeadOrGhost, unit), Read(UnitIsPlayer, unit)
  if attack == nil or dead == nil or player == nil then
    return nil, "WoW did not expose whether this unit is a living, attackable NPC."
  end
  if not attack or dead or player then
    return false, "The unit must be a living, attackable NPC."
  end

  -- The tooltip identifies the exact active quest and objective. The generic
  -- quest-unit flag is not required, since some quest loot sources lack it.
  local kind, reason, detail, remaining = MatchUnitTooltip(unit, tooltipData)
  if kind then
    return kind, reason, nil, remaining
  end
  for _, alias in ipairs(ALIASES) do
    if unit ~= alias and SameUnit(unit, alias) then
      local match, matchReason, matchDetail, matchRem = MatchUnitTooltip(alias)
      if match then
        return match, matchReason, matchDetail, matchRem
      end
    end
  end
  -- No quest in its tooltip (none there, or not loaded yet): the game's own word that it belongs to one
  -- of your quests. Only ever a yes; a no keeps the retries for a tooltip still loading.
  local related = C_QuestLog.UnitIsRelatedToActiveQuest and Read(C_QuestLog.UnitIsRelatedToActiveQuest, unit)
  if kind == nil and related == true then
    local guess, why, guessRem = GuessKind(unit, MustBeSure())
    if guess then
      return guess, "related", nil, guessRem
    end
    return false, why
  end
  -- The tooltip lists a quest, but the game hides which one and everything under it (inside dungeons):
  -- the mob is a quest mob, and your log says what you still need from quest mobs.
  if kind == nil and reason == QUEST_HIDDEN then
    local guess, why, guessRem = GuessKind(unit, MustBeSure())
    if guess then
      return guess, "listed", nil, guessRem
    end
    return false, why
  end
  if kind == false and reason == NO_MATCH then
    detail = (detail and (detail .. "; ") or "") .. "the game's own quest check says "
      .. (related == true and "yes" or related == false and "no" or "nothing readable")
  end
  return kind, reason, detail
end

local function IsNameplateUnit(unit)
  return Readable(unit) and type(unit) == "string" and unit:match("^nameplate%d+$")
end

local function PlateUnit(plate)
  if Readable(plate) and plate and not plate:IsForbidden() then
    local unit = Read(plate.GetUnit, plate) or Public(plate.namePlateUnitToken)
    if IsNameplateUnit(unit) then
      return unit
    end
  end
end

-- High-contrast remaining count pill layered on top of a marker or preview icon.
local function AttachBadge(frame, anchor)
  local W = Helper.Widgets
  frame.countBg = frame:CreateTexture(nil, "OVERLAY", nil, 1)
  if W then
    W.Slice(frame.countBg, "pill_fill.png", 12, 6, 12, 6)
    W.SetColor(frame.countBg, 0.04, 0.05, 0.07, 0.94)
    frame.countBorder = frame:CreateTexture(nil, "OVERLAY", nil, 2)
    W.Slice(frame.countBorder, "pill_border.png", 12, 6, 12, 6)
    W.SetColor(frame.countBorder, 0.28, 0.95, 0.56, 0.80)
    frame.countBorder:SetAllPoints(frame.countBg)
    frame.countBorder:Hide()
  else
    frame.countBg:SetColorTexture(0.04, 0.05, 0.07, 0.94)
  end
  frame.countBg:SetPoint("BOTTOMRIGHT", anchor or frame, "BOTTOMRIGHT", 4, -3)
  frame.countBg:Hide()

  frame.countText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  if frame.countText.SetDrawLayer then frame.countText:SetDrawLayer("OVERLAY", 3) end
  frame.countText:SetPoint("CENTER", frame.countBg, "CENTER", 0, 0)
  frame.countText:SetJustifyH("CENTER")
  frame.countText:SetTextColor(0.35, 1.0, 0.55, 1)
  frame.countText:SetShadowOffset(1, -1)
  frame.countText:SetShadowColor(0, 0, 0, 0.95)
  frame.countText:Hide()
end

local function UpdateBadge(frame, count, iconSize, show)
  local visible = show ~= false and type(count) == "number" and count > 0
  if not visible then
    frame.count = nil
    if frame.countBg then frame.countBg:Hide() end
    if frame.countBorder then frame.countBorder:Hide() end
    if frame.countText then frame.countText:Hide() end
    return
  end
  local label = count > 99 and "99+" or tostring(count)
  iconSize = type(iconSize) == "number" and iconSize or 22
  local fontSize = math.max(9, math.min(16, math.floor(iconSize * 0.48 + 0.5)))
  if frame.countFontSize ~= fontSize and frame.countText.SetFont then
    local face = (frame.countText.GetFont and frame.countText:GetFont()) or "Fonts\\FRIZQT__.TTF"
    pcall(frame.countText.SetFont, frame.countText, face, fontSize, "OUTLINE")
    frame.countFontSize = fontSize
  end
  frame.countText:SetText(label)
  local pillH = math.max(13, fontSize + 4)
  local textW = (frame.countText.GetStringWidth and frame.countText:GetStringWidth()) or 0
  local pillW = math.max(pillH, math.ceil(math.max(textW, #label * fontSize * 0.58)) + 6)
  frame.countBg:SetSize(pillW, pillH)
  frame.countBg:Show()
  if frame.countBorder then frame.countBorder:Show() end
  frame.countText:Show()
  frame.count = count
end

local function NewMarker(parent)
  local marker = CreateFrame("Frame", nil, parent)
  marker.icon = marker:CreateTexture(nil, "ARTWORK")
  marker.icon:SetAllPoints()
  AttachBadge(marker, marker)
  return marker
end

local function SetMarkerArt(marker, kind, remaining)
  local key = kind == "item" and settings.lootIcon or settings.killIcon
  local art = iconsByKey[key]
  if marker.art ~= art then
    marker.icon:SetTexture(art.texture)
    marker.icon:SetTexCoord(0, 1, 0, 1)
    marker.art = art
  end
  if marker.size ~= settings.size then
    marker:SetSize(settings.size, settings.size)
    marker.size = settings.size
  end
  UpdateBadge(marker, remaining, settings.size, settings.showCount ~= false)
end

local function PaintMarker(marker, anchor, kind, placement, remaining)
  placement=placement or settings.placement
  SetMarkerArt(marker, kind, remaining)
  if marker.anchor ~= anchor or marker.placement ~= placement then
    local position = PLACEMENTS[placement]
    marker:ClearAllPoints()
    marker:SetPoint(position[1], anchor, position[2], position[3], position[4])
    marker.anchor, marker.placement = anchor, placement
  end
end

local function HideMarker(unit)
  local marker = markers[unit]
  if marker then
    unitsByPlate[marker:GetParent()] = nil
    marker:SetScript("OnUpdate",nil)
    marker:Hide()
    marker:ClearAllPoints()
    marker:SetParent(UIParent)
    marker.anchor, marker.count = nil, nil
    markers[unit] = nil
    spareMarkers[#spareMarkers + 1] = marker
  end
end

-- Mouseover may also refer to a portrait or a unit frame. Only the world and
-- this creature's own plate count as hovering the creature.
local function WorldHover(plate)
  if Read(IsMouselooking) or Read(IsCursorVisible)==false then return false end
  local foci=Read(GetMouseFoci)
  if type(foci)~="table" then return false end
  local focus=foci[1]
  if not Readable(focus) then return false end
  if not focus or focus==WorldFrame or focus==UIParent then return true end
  while focus and not Read(focus.IsForbidden,focus) do
    if focus==plate then return true end
    focus=Read(focus.GetParent,focus)
  end
  return false
end

local function PlateBar(plate)
  local frame = plate and Public(plate.UnitFrame)
  local bars = frame and Public(frame.HealthBarsContainer)
  return bars and Public(bars.healthBar) or (frame and Public(frame.healthBar)) or bars
end

local function HealthBar(plate)
  local bar=PlateBar(plate)
  local frame=plate and Public(plate.UnitFrame)
  if frame and Read(frame.IsShowOnlyName,frame)==true then return end
  if bar and not Read(bar.IsForbidden,bar) and Read(bar.IsVisible,bar)==true and Read(bar.GetEffectiveAlpha,bar)~=0 then return bar end
end

local function NeedsPlateMarker(unit, plate)
  if not settings.enabled or not plate or PlateUnit(plate)~=unit or not Read(plate.IsVisible,plate) then return false end
  return (Read(UnitExists,"target") and SameUnit(unit,"target")) or (not settings.targetOnly and HealthBar(plate))
end

-- A distant world mouseover can have quest data without a nameplate. One mouse-transparent
-- frame follows the pointer only for that case. Quest matching stays off the animation path.
local cursorMarker, hoverRequest
local function WantsCursor(plate)
  if not settings.enabled or settings.cursorHover==false or settings.targetOnly or
      not Read(UnitExists,"mouseover") or (Read(UnitExists,"target") and SameUnit("mouseover","target")) then return false end
  if plate and (not Read(plate.IsVisible,plate) or not SameUnit(PlateUnit(plate),"mouseover")) then plate=nil end
  return not HealthBar(plate) and WorldHover(plate)
end

local function HideCursorMarker()
  if cursorMarker then
    cursorMarker:Hide()
    cursorMarker.guid,cursorMarker.plate=nil,nil
  end
end

local function PositionAtCursor(marker)
  local x,y=Read(GetCursorPosition)
  local scale=UIParent:GetEffectiveScale()
  if type(x)~="number" or type(y)~="number" or not scale or scale<=0 then return false end
  x,y=x/scale,y/scale+12
  if marker.x~=x or marker.y~=y then
    marker:ClearAllPoints()
    marker:SetPoint("BOTTOM",UIParent,"BOTTOMLEFT",x,y)
    marker.x,marker.y=x,y
  end
  return true
end

local function FollowCursor(marker,elapsed)
  marker.checkIn=marker.checkIn-elapsed
  if marker.checkIn<=0 then
    marker.checkIn=.05
    if not WantsCursor(marker.plate) or Read(UnitIsDeadOrGhost,"mouseover")~=false
        or (marker.guid and marker.guid~=Read(UnitGUID,"mouseover")) then
      HideCursorMarker()
      return
    end
  end
  if not PositionAtCursor(marker) then HideCursorMarker() end
end

local function ShowMarker(unit, plate, kind, remaining)
  local marker = markers[unit]
  if not marker or marker:GetParent() ~= plate then
    HideMarker(unit)
    marker = table.remove(spareMarkers) or NewMarker(UIParent)
    marker:SetParent(plate)
    marker:EnableMouse(false)
    markers[unit], unitsByPlate[plate] = marker, unit
  end
  local frame = Public(plate.UnitFrame)
  local bar = HealthBar(plate)
  local level = Read((frame or plate).GetFrameLevel, frame or plate)
  if type(level) == "number" then marker:SetFrameLevel(level + 2) end
  PaintMarker(marker, bar or plate, kind, not bar and "above" or nil, remaining)
  marker.kind,marker.guid,marker.revision=kind,Read(UnitGUID,unit),questRevision
  marker:Show()
end

-- What happened with quest mobs, for `/rtw questkills log`: the last LOG_SIZE outcomes, each mob's
-- same outcome at most once a minute. Plain mobs (no quest in their tooltip) aren't logged.
local function UnitLabel(unit)
  local name = Read(UnitName, unit)
  return type(name) == "string" and name ~= "" and name or nil
end

local lastLogBody, lastLogCount = nil, 0
local function Log(name, outcome)
  if settings.recordLog==false then return end
  local key = (name or "?") .. "|" .. outcome
  local now = GetTime()
  if (logged[key] or 0) > now then
    return
  end
  logged[key] = now + LOG_REPEAT
  if type(settings.log) ~= "table" then
    settings.log = {}
  end
  local zone = Read(GetRealZoneText)
  local inside = Read(IsInInstance)
  local stamp = type(date) == "function" and date("%m-%d %H:%M:%S") or ""
  local body = ("%s%s: %s - %s"):format(type(zone) == "string" and zone or "?",
    inside == true and " (instance)" or "", name or "a mob whose name the game hides here", outcome)
  -- The same line again: one line with a count (Blackrock Depths filled all 30 lines with one, once a minute).
  if body == lastLogBody and #settings.log > 0 then
    lastLogCount = lastLogCount + 1
    settings.log[#settings.log] = ("%s %s (%d times)"):format(stamp, body, lastLogCount)
    return
  end
  lastLogBody, lastLogCount = body, 1
  settings.log[#settings.log + 1] = stamp .. " " .. body
  while #settings.log > LOG_SIZE do
    table.remove(settings.log, 1)
  end
end

local function UpdateCursor(plate,data)
  if not WantsCursor(plate) then HideCursorMarker(); return false end
  local kind, _, _, remaining = NeededObjective("mouseover", data)
  local guid=Read(UnitGUID,"mouseover")
  if not kind then
    if kind~=nil or not guid or not cursorMarker or cursorMarker.guid~=guid or cursorMarker.revision~=questRevision
        or not settings[cursorMarker.kind=="item" and "loot" or "kills"] then
      HideCursorMarker()
    end
    return kind
  end
  if not cursorMarker then
    cursorMarker=NewMarker(UIParent)
    cursorMarker:EnableMouse(false)
    cursorMarker:SetFrameStrata("TOOLTIP")
    cursorMarker:SetClampedToScreen(true)
    cursorMarker:SetScript("OnUpdate",FollowCursor)
  end
  local newlyMarked=not cursorMarker:IsShown() or cursorMarker.guid~=guid or cursorMarker.kind~=kind
  cursorMarker.kind,cursorMarker.guid,cursorMarker.plate,cursorMarker.revision=kind,guid,plate,questRevision
  cursorMarker.checkIn=0
  SetMarkerArt(cursorMarker, kind, remaining)
  if PositionAtCursor(cursorMarker) then
    cursorMarker:Show()
    if newlyMarked and settings.recordLog~=false then
      Log(UnitLabel("mouseover"),kind=="item" and "loot icon shown above cursor" or "kill icon shown above cursor")
    end
  else HideCursorMarker() end
  return true
end

local function UpdateUnit(unit,plate,data)
  plate=plate or Read(C_NamePlate.GetNamePlateForUnit,unit,false)
  if not plate and markers[unit] then plate=markers[unit]:GetParent() end
  if not NeedsPlateMarker(unit,plate) then HideMarker(unit); return false end
  local previous=unitsByPlate[plate]
  if previous and previous ~= unit then HideMarker(previous) end
  local needed, reason, detail, remaining = NeededObjective(unit, data)
  if needed then
    ShowMarker(unit, plate, needed, remaining)
    Log(UnitLabel(unit), (needed == "item" and "marked as a loot source" or "marked as a kill objective")
      .. (reason == "related" and " (the game links it to your quest; its tooltip named none)" or "")
      .. (reason == "hidden" and " (the game hid its objective lines; decided by the quest its tooltip names)" or "")
      .. (reason == "listed" and " (its tooltip lists a quest the game won't name; decided by your log)" or ""))
    return true
  end
  if needed == false and (reason == NO_MATCH or reason == SWITCHED_OFF or reason == PARTY_UNSURE) then
    Log(UnitLabel(unit), "not marked: " .. reason .. (detail and (" (" .. detail .. ")") or ""))
  end
  local marker=markers[unit]
  if needed==nil and marker and marker:GetParent()==plate and marker.revision==questRevision
      and marker.guid and marker.guid==Read(UnitGUID,unit) then
    ShowMarker(unit, plate, marker.kind, marker.count)
  else HideMarker(unit) end
  return needed
end

-- Some builds resolve only numbered nameplate tokens through GetNamePlateForUnit.
-- UnitIsUnit also protects against a tooltip arriving as Blizzard recycles a frame.
local function FocusPlate(alias)
  local function match(plate)
    local unit=PlateUnit(plate)
    if unit and Read(plate.IsVisible,plate) and SameUnit(unit,alias) then return unit,plate end
  end
  local unit,plate=match(Read(C_NamePlate.GetNamePlateForUnit,alias,false))
  if unit then return unit,plate end
  local plates=Read(C_NamePlate.GetNamePlates)
  if type(plates)=="table" then
    for _,candidate in pairs(plates) do
      unit,plate=match(candidate)
      if unit then return unit,plate end
    end
  end
end

local function ClearMarkers()
  for unit in pairs(markers) do
    HideMarker(unit)
  end
  retries = {}
  hoverRequest=nil
  HideCursorMarker()
end

local function RetryUnit(unit, attempt, request)
  local delay = RETRY_DELAYS[attempt]
  if not delay then
    retries[unit] = nil
    return
  end
  C_Timer.After(delay, function()
    if retries[unit] == request then
      if not reindex and UpdateUnit(unit) == nil then
        RetryUnit(unit, attempt + 1, request)
      else
        retries[unit] = nil
      end
    end
  end)
end

local watchedBars=setmetatable({}, {__mode="k"})
local CheckUnit,UpdateFocus
local function BarVisibilityChanged(bar)
  local plate=watchedBars[bar]
  local unit=PlateUnit(plate)
  if settings.enabled and not reindex and unit then
    if SameUnit(unit,"mouseover") then UpdateFocus("mouseover") else CheckUnit(unit,plate) end
  end
end

CheckUnit=function(unit,plate,data)
  plate=plate or Read(C_NamePlate.GetNamePlateForUnit,unit,false)
  local bar=plate and PlateUnit(plate)==unit and PlateBar(plate)
  if bar and not Read(bar.IsForbidden,bar) and bar.HookScript then
    if not watchedBars[bar] then
      bar:HookScript("OnShow",BarVisibilityChanged)
      bar:HookScript("OnHide",BarVisibilityChanged)
    end
    watchedBars[bar]=plate
  end
  if UpdateUnit(unit,plate,data) == nil then
    if not retries[unit] then
      local request = {}
      retries[unit] = request
      RetryUnit(unit, 1, request)
    end
  else
    retries[unit] = nil
  end
end

local previousFocus={}
UpdateFocus=function(alias, data)
  local unit,plate
  if settings.enabled and not reindex and next(questByID) and Read(UnitExists,alias) then
    unit,plate=FocusPlate(alias)
  end
  local old=previousFocus[alias]
  previousFocus[alias]=unit
  if old and old~=unit then CheckUnit(old,markers[old] and markers[old]:GetParent()) end
  if unit then CheckUnit(unit,plate,data) end
  if alias=="mouseover" then
    if not reindex and next(questByID) then return UpdateCursor(plate,data) end
    HideCursorMarker()
  end
  return false
end

local function MouseoverChanged()
  local guid=Read(UnitGUID,"mouseover")
  if not guid or (cursorMarker and cursorMarker.guid~=guid) then HideCursorMarker() end
  local request={}
  hoverRequest=request
  local function check(attempt)
    if hoverRequest~=request then return end
    if UpdateFocus("mouseover")==nil and RETRY_DELAYS[attempt] then
      C_Timer.After(RETRY_DELAYS[attempt],function() check(attempt+1) end)
    end
  end
  check(1)
end

local function RefreshVisible()
  local plates=Read(C_NamePlate.GetNamePlates)
  for _,plate in pairs(type(plates)=="table" and plates or {}) do
    local unit=PlateUnit(plate)
    if unit then CheckUnit(unit,plate) end
  end
  UpdateFocus("target")
  UpdateFocus("mouseover")
end

-- `rebuild`: the quest log may have changed. Nameplates are looked at again only when your objectives did, or
-- something else asked (a group change).
local lookAgain = false
ScheduleRefresh = function(rebuild)
  if not settings.enabled then
    return
  end
  reindex = reindex or rebuild
  lookAgain = lookAgain or not rebuild
  if refreshTimer then
    return
  end
  refreshTimer = C_Timer.NewTimer(REFRESH_DELAY, function()
    refreshTimer = nil
    local changed = false
    if reindex then
      changed = IndexObjectives()
      reindex = false
    end
    if changed or lookAgain then
      lookAgain = false
      RefreshVisible()
    end
  end)
end

local function Preview()
  if not preview then
    local W = Helper.Widgets
    preview = CreateFrame("Frame", nil, UIParent)
    preview:SetPoint("TOP", UIParent, "TOP", 0, -210)
    preview:SetFrameStrata("DIALOG")
    if W then
      preview:SetSize(360, 108)
      W.Shadow(preview, 14, .48)
      preview.bg, preview.border = W.Surface(preview, "lg", W.colors.window, W.colors.borderStrong)
      W.TopSheen(preview, .03)
      local title = W.Font(preview, "heading")
      title:SetPoint("TOP", 0, -10)
      title:SetJustifyH("CENTER")
      title:SetText("Quest marker preview")
      for index, label in ipairs({ "Kill target", "Loot target" }) do
        local plate = CreateFrame("Frame", nil, preview)
        plate:SetSize(88, 20)
        plate:SetPoint("CENTER", preview, "CENTER", index == 1 and -84 or 84, -18)
        W.Surface(plate, "md", { .58, .14, .14, 1 }, { .95, .36, .36, .55 })
        local name = W.Font(plate, "small")
        name:SetTextColor(unpack(W.colors.text))
        name:SetPoint("CENTER")
        name:SetJustifyH("CENTER")
        name:SetText(label)
        preview[index] = { plate = plate, marker = NewMarker(plate) }
      end
    else
      preview:SetSize(345, 100)
      local background = preview:CreateTexture(nil, "BACKGROUND")
      background:SetAllPoints()
      background:SetColorTexture(0.04, 0.04, 0.04, 0.94)
      local title = preview:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      title:SetPoint("TOP", 0, -7)
      title:SetText("Quest marker preview")
      for index, label in ipairs({ "Kill target", "Loot target" }) do
        local plate = CreateFrame("Frame", nil, preview)
        plate:SetSize(84, 17)
        plate:SetPoint("CENTER", preview, "CENTER", index == 1 and -82 or 82, -20)
        local bar = plate:CreateTexture(nil, "BACKGROUND")
        bar:SetAllPoints()
        bar:SetColorTexture(0.56, 0.11, 0.10)
        local name = plate:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("CENTER")
        name:SetText(label)
        preview[index] = { plate = plate, marker = NewMarker(plate) }
      end
    end
  end
  for index, sample in ipairs(preview) do
    PaintMarker(sample.marker, sample.plate, index == 1 and "monster" or "item", nil, index == 1 and 4 or 2)
    sample.marker:Show()
  end
  preview:Show()
  if previewTimer then previewTimer:Cancel() end
  previewTimer = C_Timer.NewTimer(6, function() preview:Hide() end)
end

local function CheckTarget()
  if not settings.enabled then
    Helper.Print("Quest markers are off.")
    return
  end
  if Read(UnitExists, "target") ~= true then
    Helper.Print("Target the mob you want to check.")
    return
  end
  if reindex then
    IndexObjectives()
    reindex = false
  end
  UpdateFocus("target")
  for unit, marker in pairs(markers) do
    if SameUnit(unit, "target") then
      Helper.Print(marker.kind == "item" and "Matched an unfinished loot objective." or "Matched an unfinished kill objective.")
      return
    end
  end
  local kind, reason = NeededObjective("target")
  Helper.Print(kind and "Matched a quest objective. Forever currently exposes no visible nameplate anchor for the target." or reason)
end

Helper.Feature(function()
  lineTypes = Enum and Enum.TooltipDataLineType
  if not (lineTypes and lineTypes.QuestTitle and lineTypes.QuestObjective
      and C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo and C_QuestLog.IsComplete
      and C_QuestLog.GetQuestObjectives and C_TooltipInfo and C_TooltipInfo.GetUnit
      and C_NamePlate and C_NamePlate.GetNamePlates and C_NamePlate.GetNamePlateForUnit) then
    return
  end
  settings = Helper.db.questKills
  local defaults = Helper.features.questKills.defaults
  if not iconsByKey[settings.killIcon] then settings.killIcon = defaults.killIcon end
  if not iconsByKey[settings.lootIcon] then settings.lootIcon = defaults.lootIcon end
  if not PLACEMENTS[settings.placement] then settings.placement = defaults.placement end
  if type(settings.size) ~= "number" or settings.size < 12 or settings.size > 40 then settings.size = defaults.size end

  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit,function(tip,data)
      if tip~=GameTooltip or not settings.enabled or not Read(UnitExists,"mouseover") then return end
      local _,unit=Read(tip.GetUnit,tip)
      local guid=data and Public(data.guid)
      local current=guid and Read(UnitGUID,"mouseover")
      if guid and current then
        if guid~=current then return end
      elseif unit~="mouseover" and (not unit or not SameUnit(unit,"mouseover")) then return end
      UpdateFocus("mouseover",data)
    end)
  end
  Helper.QuestMarkers = {
    icons = ICONS,
    refresh = ScheduleRefresh,
    preview = Preview,
    check = CheckTarget,
    attachBadge = AttachBadge,
    updateBadge = UpdateBadge,
    reset = function()
      for key, value in pairs(defaults) do
        if key ~= "enabled" then settings[key] = value end
      end
      ScheduleRefresh()
    end,
  }

  Helper.On("NAME_PLATE_UNIT_ADDED", function(unit)
    if not settings.enabled or reindex or not IsNameplateUnit(unit) then
      return
    end
    retries[unit] = nil
    CheckUnit(unit)
    -- The default unit frame can finish attaching its health bar after the event.
    C_Timer.After(0,function()
      if settings.enabled and not reindex then
        if SameUnit(unit,"mouseover") then UpdateFocus("mouseover") else CheckUnit(unit) end
      end
    end)
  end)
  Helper.On("NAME_PLATE_UNIT_REMOVED", function(unit)
    if IsNameplateUnit(unit) then
      retries[unit] = nil
      HideMarker(unit)
      if previousFocus.mouseover==unit then C_Timer.After(0,function() UpdateFocus("mouseover") end) end
    end
  end)
  Helper.OnUnit("UNIT_HEALTH", Helper.WORLD_UNITS, function(unit)
    if IsNameplateUnit(unit) and markers[unit] and Read(UnitIsDeadOrGhost, unit) ~= false then
      HideMarker(unit)
    end
  end)
  for _, event in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_TURNED_IN" }) do
    Helper.On(event, function() ScheduleRefresh(true) end)
  end
  Helper.On("GROUP_ROSTER_UPDATE", function() ScheduleRefresh() end)   -- (joining or leaving a group changes what is sure)
  -- An enemy's nameplate the game keeps from addons (forbidden): nothing can be drawn on it. Said once a
  -- zone in the log, so a dungeon without markers can be told apart from a quest that wasn't recognised.
  local forbiddenNoted
  Helper.On("FORBIDDEN_NAME_PLATE_UNIT_ADDED", function(unit)
    if forbiddenNoted or not settings.enabled or not next(questByID) or not Readable(unit) then
      return
    end
    if Read(UnitCanAttack, "player", unit) == true then
      forbiddenNoted = true
      Log(nil, "the game keeps enemy nameplates here from addons: markers can't be drawn on them")
    end
  end)
  Helper.On("PLAYER_REGEN_DISABLED", function() ScheduleRefresh() end)
  Helper.On("PLAYER_REGEN_ENABLED", function() ScheduleRefresh() end)
  Helper.On("PLAYER_ENTERING_WORLD", function()
    forbiddenNoted = nil
    logged, lastLogBody, lastLogCount = {}, nil, 0
    ClearMarkers()
    ScheduleRefresh(true)
  end)
  Helper.On("PLAYER_TARGET_CHANGED", function()
    UpdateFocus("target")
    UpdateFocus("mouseover")
  end)
  Helper.On("UPDATE_MOUSEOVER_UNIT", MouseoverChanged)

  Helper.commands.questkills = function(rest)
    if rest == "check" then
      CheckTarget()
    elseif rest == "preview" then
      Preview()
    elseif rest == "party on" or rest == "party off" then
      settings.partyGuesses = rest == "party on"
      Helper.Print(settings.partyGuesses
        and "In a group, quest mobs the game won't tie to a quest are marked too. Some may be for a party member's quest."
        or "In a group, only mobs that are sure to be for your own quests are marked.")
      ScheduleRefresh()
    elseif rest == "log" then
      local log = type(settings.log) == "table" and settings.log or {}
      Helper.Print(#log == 0 and "No quest mob has been logged yet." or "the last quest mobs seen:")
      for _, line in ipairs(log) do
        Helper.Print(line)
      end
    elseif Helper.Toggle(settings, rest, "Quest markers") then
      ScheduleRefresh(true)
    else
      if refreshTimer then
        refreshTimer:Cancel()
        refreshTimer = nil
      end
      ClearMarkers()
    end
  end
  Helper.help[#Helper.help + 1] = "/rtw questkills on | off | preview | check | log - private quest mob markers"
  Helper.help[#Helper.help + 1] = "/rtw questkills party on | off - in a group, also mark mobs that may be for a party member's quest"
  ScheduleRefresh(true)
end)
