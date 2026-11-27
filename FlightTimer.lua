-- Shows how long a flight path takes, counting down while you fly.
--
-- The game does not provide durations. ReadyToWork remembers completed flights
-- and uses them for later trips. Untimed routes use DungeonJournal, InFlight,
-- or distance-based estimates when available. Otherwise the timer counts up.

local _, Helper = ...

local Flight = {}
Helper.Flight = Flight

local TAKEOFF_WAIT = 20   -- seconds for a picked flight to leave the ground
local MIN_FLIGHT = 5      -- anything shorter is not a flight worth keeping
local MIN_PACE_FLIGHTS = 2
local FREQUENT_FLIER_NODE = 110300

local settings
local display, watcher, previewTimer
local pending   -- picked on the flight map, not in the air yet
local flight    -- in the air
local joinedMidway   -- a flight already under way at login or /reload: its take-off time is unknown
local taxiMap

-- A value addons may read; some values are hidden from them in places.
local function Plain(value)
  if type(issecretvalue) == "function" and issecretvalue(value) then
    return nil
  end
  return value
end

local function Call(func, ...)
  if type(func) ~= "function" then
    return nil
  end
  local ok, a, b = pcall(func, ...)
  if not ok then
    return nil
  end
  return Plain(a), Plain(b)
end

local function OnTaxi()
  local flying = Call(UnitOnTaxi, "player")
  if flying ~= nil then
    return flying == true or flying == 1
  end
end

local function NodeName(index)
  local name = Call(TaxiNodeName, index)
  return type(name) == "string" and name ~= "" and name or nil
end

-- The flight map's names for where you are and for the picked destination.
local function RouteEndpoints(slot)
  local from, originSlot
  for index = 1, tonumber(Call(NumTaxiNodes)) or 0 do
    if Call(TaxiNodeGetType, index) == "CURRENT" then
      from, originSlot = NodeName(index), index
      break
    end
  end
  local destination = NodeName(slot)
  if taxiMap then
    local origin, target = taxiMap.current and taxiMap.slots[taxiMap.current], taxiMap.slots[slot]
    if not from and origin then from, originSlot = origin.name, taxiMap.current end
    if not destination and target then destination = target.name end
  end
  return from, destination, originSlot
end

local function TaxiMapID()
  local mapID = FlightMapFrame and Call(FlightMapFrame.GetMapID, FlightMapFrame)
  if type(mapID) ~= "number" or mapID <= 0 then
    mapID = Call(GetTaxiMapID)
  end
  if type(mapID) == "number" and mapID > 0 then
    return mapID
  end
end

local function TaxiNodes(mapID)
  if not (mapID and C_TaxiMap) then
    return
  end
  local nodes = Call(C_TaxiMap.GetAllTaxiNodes, mapID)
  if type(nodes) ~= "table" then
    return
  end
  return nodes
end

local function RouteNodeIDs(from, to, originSlot, destSlot)
  if not originSlot then
    return
  end
  local mapID = TaxiMapID()
  local originID, destID
  for _, node in ipairs(TaxiNodes(mapID) or {}) do
    local index, id = Plain(node.slotIndex), Plain(node.nodeID)
    if type(id) == "number" and id > 0 then
      if index == originSlot then originID = id end
      if index == destSlot then destID = id end
    end
  end
  -- TakeTaxiNode's post-hook can run after the flight map has closed.
  if not (originID and destID) and taxiMap and (not mapID or taxiMap.id == mapID) then
    local origin, destination = taxiMap.slots[originSlot], taxiMap.slots[destSlot]
    if origin and destination and from and to and from == origin.name and to == destination.name then
      return origin.id, destination.id
    end
  end
  return originID, destID
end

local function FlightSpeedFactor()
  local legacy = Constants and Constants.LegacyConsts
  local treeID = legacy and legacy.LEGACY_TREE_ADVENTURE_ID
  if not treeID or not C_Traits then
    return
  end
  local configID = Call(C_Traits.GetConfigIDByTreeID, treeID)
  local node = configID and Call(C_Traits.GetNodeInfo, configID, FREQUENT_FLIER_NODE)
  local rank = node and Plain(node.activeRank)
  if type(rank) == "number" then
    return rank > 0 and 1 / 1.2 or 1
  end
end

local function RouteDetails(from, to, originSlot, destSlot)
  local faction = Call(UnitFactionGroup, "player")
  local originID, destID = RouteNodeIDs(from, to, originSlot, destSlot)
  local key
  if faction and originID and destID then
    key = ("%s:%d>%d"):format(faction, originID, destID)
  elseif faction and from and to then
    key = faction .. ":" .. from .. ">" .. to
  end
  return { key = key, faction = faction, originID = originID, destID = destID, speed = FlightSpeedFactor() }
end

local function ImportedTime(route)
  if not (Helper.FlightTimes and route and route.faction and route.originID and route.destID) then
    return
  end
  for _, source in ipairs({ Helper.FlightTimes.forever, Helper.FlightTimes.classic }) do
    local factionRoutes = source[route.faction]
    local destinations = factionRoutes and factionRoutes[route.originID]
    local seconds = destinations and destinations[route.destID]
    if seconds then
      return seconds * (route.speed or 1)
    end
  end
end

-- The length of the route drawn on the flight map, hop by hop, in map
-- units. nil when the client cannot say.
local function RouteLength(slot)
  local hops = tonumber(Call(GetNumRoutes, slot))
  if not hops or hops < 1 then
    return nil
  end
  local total = 0
  for hop = 1, hops do
    local fromX, fromY = Call(TaxiGetSrcX, slot, hop), Call(TaxiGetSrcY, slot, hop)
    local toX, toY = Call(TaxiGetDestX, slot, hop), Call(TaxiGetDestY, slot, hop)
    if type(fromX) ~= "number" or type(fromY) ~= "number" or type(toX) ~= "number" or type(toY) ~= "number" then
      return nil
    end
    total = total + math.sqrt((toX - fromX) ^ 2 + (toY - fromY) ^ 2)
  end
  return total > 0 and total or nil
end

-- The continent you are on: flight maps of different continents are drawn
-- to different scales, so each keeps its own pace.
local function Continent()
  if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetMapInfo) then
    return 0
  end
  local mapID = Call(C_Map.GetBestMapForUnit, "player")
  local continentType = Enum and Enum.UIMapType and Enum.UIMapType.Continent or 2
  for _ = 1, 10 do
    if type(mapID) ~= "number" or mapID == 0 then
      break
    end
    local info = Call(C_Map.GetMapInfo, mapID)
    if type(info) ~= "table" then
      break
    end
    if info.mapType == continentType then
      return mapID
    end
    mapID = info.parentMapID
  end
  return 0
end

-- Seconds the route is expected to take, and whether that is a timed fact
-- (true) or an estimate (false). nil when nothing is known.
function Flight.Expected(from, to, length, continent, route)
  local baseline = route and route.key and settings.baseTimes[route.key]
  if type(baseline) == "number" and baseline > 0 and route.speed then
    return baseline * route.speed, true
  end
  if not from or not to then
    return ImportedTime(route), false
  end
  local key = from .. ">" .. to
  local known = settings.times[key]
  if type(known) == "number" and known > 0 then
    return known, not route
  end
  local journal = type(ForeverDungeonJournalDB) == "table" and ForeverDungeonJournalDB.flightTimes
  local theirs = type(journal) == "table" and journal[key]
  if type(theirs) == "number" and theirs > 0 then
    return theirs, not route
  end
  local imported = ImportedTime(route)
  if imported then
    return imported, false
  end
  local pace = settings.pace[tostring(continent or 0)]
  if length and type(pace) == "table" and (pace.flights or 0) >= MIN_PACE_FLIGHTS and (pace.length or 0) > 0 then
    return length * pace.seconds / pace.length, false
  end
  return nil
end

-- Remembers a finished flight.
function Flight.Record(from, to, seconds, length, continent, route)
  if not from or not to or type(seconds) ~= "number" or not (seconds >= MIN_FLIGHT and seconds < math.huge) then
    return false
  end
  settings.times[from .. ">" .. to] = math.floor(seconds + 0.5)
  if route and route.key and route.speed then
    settings.baseTimes[route.key] = seconds / route.speed
  end
  if length then
    local key = tostring(continent or 0)
    local pace = settings.pace[key]
    if type(pace) ~= "table" then
      pace = { flights = 0, seconds = 0, length = 0 }
      settings.pace[key] = pace
    end
    pace.flights = pace.flights + 1
    pace.seconds = pace.seconds + seconds
    pace.length = pace.length + length
  end
  return true
end

-- The timer on screen -------------------------------------------------------

local function BuildDisplay()
  local W = Helper.Widgets
  display = CreateFrame("Frame", "ReadyToWorkFlightTimer", UIParent)
  display:SetFrameStrata("MEDIUM")
  display:Hide()

  if W then
    display:SetSize(244, 68)
    W.Shadow(display, 12, .45)
    display.bg, display.border = W.Surface(display, "md", W.colors.window, W.colors.borderStrong)
    W.TopSheen(display, .03)

    display.Title = W.Font(display, "small")
    display.Title:SetTextColor(unpack(W.colors.label))
    display.Title:SetPoint("TOPLEFT", 10, -8)
    display.Title:SetPoint("TOPRIGHT", -10, -8)
    display.Title:SetJustifyH("CENTER")
    display.Title:SetWordWrap(false)

    display.Time = W.Font(display, "title")
    display.Time:SetPoint("TOP", display.Title, "BOTTOM", 0, -2)
    display.Time:SetJustifyH("CENTER")

    display.Total = W.Font(display, "micro")
    display.Total:SetTextColor(unpack(W.colors.dim))
    display.Total:SetPoint("BOTTOM", 0, 14)
    display.Total:SetJustifyH("CENTER")

    display.Bar = CreateFrame("StatusBar", nil, display)
    display.Bar:SetPoint("BOTTOMLEFT", 10, 6)
    display.Bar:SetPoint("BOTTOMRIGHT", -10, 6)
    display.Bar:SetHeight(5)
    local track = display.Bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    W.Slice(track, "pill_fill.png", 12, 6, 12, 6)
    W.SetColor(track, 1, 1, 1, .09)
    display.Bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    display.Bar:SetStatusBarColor(unpack(W.colors.accent))
    display.Bar:SetMinMaxValues(0, 1)
  else
    display:SetSize(228, 64)
    local background = display:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0, 0, 0, 0.6)

    display.Title = display:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    display.Title:SetPoint("TOPLEFT", 8, -6)
    display.Title:SetPoint("TOPRIGHT", -8, -6)
    display.Title:SetJustifyH("CENTER")
    display.Title:SetWordWrap(false)

    display.Time = display:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    display.Time:SetPoint("TOP", display.Title, "BOTTOM", 0, -3)

    display.Total = display:CreateFontString(nil,"OVERLAY","GameFontHighlightSmall")
    display.Total:SetPoint("BOTTOM",0,12)
    display.Bar = CreateFrame("StatusBar", nil, display)
    display.Bar:SetPoint("BOTTOMLEFT", 6, 5)
    display.Bar:SetPoint("BOTTOMRIGHT", -6, 5)
    display.Bar:SetHeight(5)
    display.Bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    display.Bar:SetStatusBarColor(0.47, 0.81, 1)
    display.Bar:SetMinMaxValues(0, 1)
  end

  Helper.MakeMovable(display, "flight", false, "TOP", "TOP", 0, -150)
  display:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Flight timer")
    GameTooltip:AddLine("Drag to move.", 1, 1, 1)
    if settings.partyButton ~= false then
      GameTooltip:AddLine("The chat button sends your flight ETA to party chat.", 1, 1, 1, true)
    end
    GameTooltip:Show()
  end)
  display:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- What the timer should read `elapsed` seconds into a flight.
-- Returns the title, the time text and how full the bar is (nil: no bar).
function Flight.Describe(current, elapsed)
  local title = current.to and ("To " .. current.to) or "In flight"
  if not current.expected then
    -- Nothing to count down from yet: show how long it has been.
    return title, Helper.Clock(elapsed), nil, current.to and "learning route" or nil
  end
  local left = current.expected - elapsed
  local text
  if left <= 0 then
    -- A timed route is about to land; an estimate has simply run out.
    text = current.exact and "landing" or "any moment"
  elseif current.exact then
    text = Helper.Clock(left)
  else
    text = "about " .. Helper.Clock(left)
  end
  return title, text, math.min(1, elapsed / current.expected), nil
end

-- Telling the party ---------------------------------------------------------

-- A duration for chat, in words people read at a glance: 330 -> "5m 30s", 45 -> "45s", 300 -> "5m".
-- (Rounded the same way as the timer's 5:30, so both give the same number.)
function Flight.Duration(seconds)
  seconds = math.max(0, math.floor((seconds or 0) + 0.5))
  local minutes, rest = math.floor(seconds / 60), seconds % 60
  if minutes == 0 then
    return rest .. "s"
  elseif rest == 0 then
    return minutes .. "m"
  end
  return ("%dm %ds"):format(minutes, rest)
end

-- Lifetime flight time formatted as HH:MM:SS (e.g. 7118 -> "01:58:38").
function Flight.TotalClock(seconds)
  seconds = math.max(0, math.floor((seconds or 0) + 0.5))
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  local rest = seconds % 60
  return ("%02d:%02d:%02d"):format(hours, minutes, rest)
end

-- The line the ETA button sends `elapsed` seconds into a flight: the same numbers the timer shows,
-- and "about" when it shows them. A flight already under way when ReadyToWork loaded (`midway`) has no
-- known take-off time, so it gives no air time either.
function Flight.EtaMessage(current, elapsed)
  local where = current.to and ("Flying to " .. current.to) or "On a flight"
  if not current.expected then
    if current.midway then
      return where .. ": landing time unknown."
    end
    return ("%s: landing time unknown (in the air %s)."):format(where, Flight.Duration(elapsed))
  end
  local left = current.expected - elapsed
  if left < 0.5 then   -- (what the timer would show as 0:00)
    return where .. (current.exact and ": landing now." or ": should land any moment.")
  end
  return ("%s: landing in %s%s."):format(where, current.exact and "" or "about ", Flight.Duration(left))
end

local SAMPLE = { to = "Somewhere, Far Away", expected = 151, exact = true }   -- (what `test` shows)

-- The line to send now, or nil and why not.
local function EtaNow()
  if display.sample then
    return Flight.EtaMessage(SAMPLE, 0)
  end
  if not flight then
    return nil, "You're not on a flight."
  end
  return Flight.EtaMessage(flight, GetTime() - flight.startedAt)
end

local function SendEta()
  local message, why = EtaNow()
  if not message then
    Helper.Print(why)
    return
  end
  if display.sample then
    Helper.Print("Your party would see: " .. message)
    return
  end
  local chat = Helper.GroupChannel and Helper.GroupChannel()
  if not chat then
    Helper.Print("Join a party to send your ETA.")
    return
  end
  if C_ChatInfo and Call(C_ChatInfo.InChatMessagingLockdown) == true then
    Helper.Print("The game isn't letting addons send chat right now. Try again in a moment.")
    return
  end
  local send = C_ChatInfo and C_ChatInfo.SendChatMessage
  if type(send) ~= "function" or not pcall(send, message, chat) then
    Helper.Print("Couldn't send your ETA to party chat.")
  end
end

-- Shows the party button (unless switched off), dimmed with its reason when there is nobody to tell.
local function RefreshPartyButton()
  if display and display.Total then display.Total:SetShown(settings.showTotal~=false) end
  local button = display.Party
  local shown = settings.partyButton ~= false
  button:SetShown(shown)
  if shown then
    button:SetEnabled(display.sample or (Helper.GroupChannel and Helper.GroupChannel() ~= nil))
  end
end

Flight.RefreshOptions=RefreshPartyButton

local function BuildPartyButton()
  local W = Helper.Widgets
  local button = CreateFrame("Button", nil, display)
  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-Chat-Up")
  if W then
    button:SetSize(22, 22)
    button:SetPoint("RIGHT", display, "RIGHT", -8, -2)
    button.bg, button.border = W.Surface(button, "md", W.colors.surface, W.colors.border)
    W.Highlight(button, "md")
    icon:SetSize(14, 14)
    icon:SetPoint("CENTER")
  else
    button:SetSize(18, 18)
    -- (below the title, which can run the full width, beside the centred time, above the bar)
    button:SetPoint("RIGHT", display, "RIGHT", -6, -4)
    icon:SetAllPoints()
    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  end
  button.icon = icon
  button:SetMotionScriptsWhileDisabled(true)
  button:SetScript("OnEnable", function(self) self.icon:SetDesaturated(false) self.icon:SetAlpha(1) end)
  button:SetScript("OnDisable", function(self) self.icon:SetDesaturated(true) self.icon:SetAlpha(0.5) end)
  button:SetScript("OnClick", SendEta)
  -- (The game's tooltip calls UpdateTooltip on its owner while hovered, so the line shown keeps up with
  -- the countdown: it is always the line a click sends.)
  function button:UpdateTooltip()
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Send your ETA to party chat")
    local message, why = EtaNow()
    if not message then
      GameTooltip:AddLine(why or "", 1, 1, 1, true)
    elseif display.sample then
      GameTooltip:AddLine("Preview only: a click shows the line in your chat.", 1, 1, 1, true)
      GameTooltip:AddLine(message, 0.6, 0.85, 1, true)
    elseif not (Helper.GroupChannel and Helper.GroupChannel()) then
      GameTooltip:AddLine("Join a party to send your ETA.", 1, 1, 1, true)
    else
      GameTooltip:AddLine("Click to send:", 1, 1, 1)
      GameTooltip:AddLine(message, 0.6, 0.85, 1, true)
    end
    GameTooltip:AddLine("Hide this button: Flight timer options, or /rtw flight party off.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end
  button:SetScript("OnEnter", button.UpdateTooltip)
  button:SetScript("OnLeave", function(self)
    if GameTooltip:IsOwned(self) then
      GameTooltip:Hide()
    end
  end)
  display.Party = button
end

local function Refresh()
  local elapsed = GetTime() - flight.startedAt
  local title, text, fill, note = Flight.Describe(flight, elapsed)
  display.Title:SetText(note and (title .. "  (" .. note .. ")") or title)
  display.Time:SetText(text)
  display.Total:SetText("Time spent flying: " .. Flight.TotalClock((settings.totalSeconds or 0) + elapsed))
  display.Bar:SetShown(fill ~= nil)
  if fill then
    display.Bar:SetValue(fill)
  end
  RefreshPartyButton()
  if display.Party:IsShown() and GameTooltip:IsOwned(display.Party) then
    display.Party:UpdateTooltip()   -- (also here, in step with the timer)
  end
end

local function Land()
  local done = flight
  flight = nil
  display:Hide()
  ReadyToWorkTravel.current=nil
  if done then settings.totalSeconds=(settings.totalSeconds or 0)+math.max(0,math.floor(GetTime()-done.startedAt)) end
  if done and not done.partial then
    Flight.Record(done.from, done.to, GetTime() - done.startedAt, done.length, done.continent, done.route)
  end
end

local function CancelPreviewTimer()
  if previewTimer then
    if previewTimer.Cancel then previewTimer:Cancel() end
    previewTimer = nil
  end
end

-- Watches for take-off and landing. Runs only while a flight is picked or
-- under way.
local function Watch(self, elapsed)
  self.wait = (self.wait or 0) - elapsed
  if self.wait > 0 then
    return
  end
  self.wait = 0.1

  local flying = OnTaxi()
  if flight then
    if flying == false then
      Land()
    elseif settings.enabled then
      display:Show()
      Refresh()
    end
  elseif flying then
    flight = pending or { partial = true, midway = joinedMidway }
    pending = nil   -- (joinedMidway goes when the watcher stops, after this flight)
    CancelPreviewTimer()
    display.sample = nil   -- (a real flight replaces the `test` preview)
    local now=GetServerTime()
    flight.startedAt=GetTime()-math.max(0,now-(flight.departed or now))
    flight.departed=flight.departed or now
    ReadyToWorkTravel.current=flight
    if not flight.partial then
      flight.expected, flight.exact = Flight.Expected(flight.from, flight.to, flight.length, flight.continent, flight.route)
    end
    if settings.enabled then
      display:Show()
      Refresh()
    else
      display:Hide()   -- (a `test` preview left up while the timer is off)
    end
  elseif pending and GetTime() - pending.at > TAKEOFF_WAIT then
    pending = nil -- never left the ground
  end

  if not flight and not pending then
    joinedMidway = nil
    self:Hide()
  end
end

Helper.Feature(function()
  settings = Helper.db.flight
  ReadyToWorkTravel=type(ReadyToWorkTravel)=="table" and ReadyToWorkTravel or {}
  BuildDisplay()
  BuildPartyButton()

  watcher = CreateFrame("Frame")
  watcher:Hide()
  watcher:SetScript("OnUpdate", Watch)

  local hooked = setmetatable({},{__mode="k"})
  local function hover(button)
    if not settings.enabled or settings.showRouteTime==false then return end
    if not settings.enabled or not GameTooltip:IsShown() or not button then return end
    local slot = button.taxiNodeData and Plain(button.taxiNodeData.slotIndex) or Call(button.GetID,button)
    if not slot then return end
    local node = taxiMap and taxiMap.slots[slot]
    local reachable = Enum and Enum.FlightPathState and node and node.state == Enum.FlightPathState.Reachable
    if not reachable and Call(TaxiNodeGetType,slot) ~= "REACHABLE" then return end
    local from,to,origin=RouteEndpoints(slot)
    local seconds,exact=Flight.Expected(from,to,RouteLength(slot),Continent(),RouteDetails(from,to,origin,slot))
    GameTooltip:AddLine(seconds and ((exact and "Flight time: " or "Estimated flight: ")..Flight.Duration(seconds)) or "Flight time not recorded yet (learns on first flight)",0.65,0.85,1)
    GameTooltip:Show()
  end
  local function attachPins()
    if FlightMapFrame and FlightMapFrame.EnumeratePinsByTemplate then
      if FlightMapFrame.AcquirePin and not hooked[FlightMapFrame] then
        hooked[FlightMapFrame] = true
        local queued = false
        hooksecurefunc(FlightMapFrame, "AcquirePin", function(_, template)
          if template ~= "FlightMap_FlightPointPinTemplate" or queued then return end
          queued = true
          C_Timer.After(0, function() queued = false; attachPins() end)
        end)
      end
      for pin in FlightMapFrame:EnumeratePinsByTemplate("FlightMap_FlightPointPinTemplate") do
        if not hooked[pin] then pin:HookScript("OnEnter",hover); hooked[pin]=true end
      end
    end
    if TaxiNodeOnButtonEnter and not hooked[TaxiNodeOnButtonEnter] then
      hooksecurefunc("TaxiNodeOnButtonEnter",hover); hooked[TaxiNodeOnButtonEnter]=true
    end
  end
  Helper.On("TAXIMAP_OPENED", function()
    C_Timer.After(0,attachPins)
    local mapID, slots, current = TaxiMapID(), {}, nil
    for _, node in ipairs(TaxiNodes(mapID) or {}) do
      local slot, id, name = Plain(node.slotIndex), Plain(node.nodeID), Plain(node.name)
      if type(slot) == "number" and type(id) == "number" and id > 0 then
        local state = Plain(node.state)
        slots[slot] = { id = id, name = name, state = state }
        if Enum and Enum.FlightPathState and state == Enum.FlightPathState.Current then current = slot end
      end
    end
    taxiMap = { id = mapID, slots = slots, current = current }
  end)

  -- Picking a destination on the flight map.
  if type(hooksecurefunc) == "function" and type(TakeTaxiNode) == "function" then
    hooksecurefunc("TakeTaxiNode", function(slot)
      local from, to, originSlot = RouteEndpoints(slot)
      pending = {
        from = from, to = to, at = GetTime(), length = RouteLength(slot), continent = Continent(),
        route = RouteDetails(from, to, originSlot, slot),
      }
      taxiMap = nil
      watcher.wait = 0
      watcher:Show()
    end)
  end
  local function MarkPartial()
    local current = flight or pending
    if current then
      current.partial, current.to, current.expected = true, nil, nil
    end
  end
  if type(hooksecurefunc) == "function" and type(TaxiRequestEarlyLanding) == "function" then
    hooksecurefunc("TaxiRequestEarlyLanding", MarkPartial)
  end
  Helper.On("PLAYER_DEAD", MarkPartial)

  -- A flight that was not picked on the flight map (a quest ride, or one
  -- already under way at login) is shown counting up and not remembered.
  local function Check()
    if not flight and not pending and OnTaxi() then
      watcher.wait = 0
      watcher:Show()
    end
  end
  local function restoreFlight(settled)
    if flight or pending then return end
    local saved, flying = ReadyToWorkTravel.current, OnTaxi()
    if type(saved) == "table" and type(saved.departed) == "number" then
      local age = GetServerTime() - saved.departed
      if flying and age >= 0 and age < math.max(1800, (tonumber(saved.expected) or 0) + 600) then
        saved.at = GetTime()
        pending = saved
        watcher.wait = 0
        watcher:Show()
        return
      end
      if settled and flying == false then ReadyToWorkTravel.current = nil end
    end
    if flying then joinedMidway = true; Check() end
  end
  Helper.On("PLAYER_ENTERING_WORLD", function()
    restoreFlight(false)
    C_Timer.After(2, function() restoreFlight(true) end)
  end)
  Helper.On("PLAYER_CONTROL_LOST", function()
    C_Timer.After(1, Check)
  end)

  Helper.commands.flight = function(rest)
    local word = rest:match("^(%S*)")
    if word == "reset" then
      display.ResetPosition()
      Helper.Print("Flight timer moved back to its starting place.")
    elseif word == "test" then
      -- Shows the timer for a moment so it can be dragged into place.
      if not flight then
        CancelPreviewTimer()
        display.sample = true
        display.Total:SetText("Time spent flying: " .. Flight.TotalClock(settings.totalSeconds or 0))
        display.Title:SetText("To " .. SAMPLE.to)
        display.Time:SetText(Helper.Clock(SAMPLE.expected))
        display.Bar:Show()
        display.Bar:SetValue(0.4)
        RefreshPartyButton()
        display:Show()
        previewTimer = C_Timer.NewTimer(15, function()
          previewTimer = nil
          if not flight then
            display.sample = nil
            display:Hide()   -- (the preview flag goes when a flight starts)
          end
        end)
        Helper.Print("Flight timer shown for 15 seconds. Drag it where you want it.")
      end
    elseif word == "party" then
      local value = rest:match("^party%s+(%S+)")
      if value == "on" or value == "off" then
        settings.partyButton = value == "on"
      else
        settings.partyButton = settings.partyButton == false
      end
      RefreshPartyButton()
      Helper.Print("The flight timer's party button is " .. (settings.partyButton and "on." or "off."))
    elseif word == "forget" then
      settings.times, settings.baseTimes, settings.pace = {}, {}, {}
      Helper.Print("Forgot ReadyToWork's learned flight times.")
    else
      if not Helper.Toggle(settings, word, "The flight timer is") then
        CancelPreviewTimer()
        display.sample = nil
        if display:IsShown() then display:Hide() end
      end
    end
  end
  Helper.help[#Helper.help + 1] = "/rtw flight [on|off] - show a timer while on a flight path"
  Helper.help[#Helper.help + 1] = "/rtw flight test | reset | forget - show it for placing, put it back, forget learned times"
  Helper.help[#Helper.help + 1] = "/rtw flight party [on|off] - the timer's button that sends your ETA to party chat"
end)
