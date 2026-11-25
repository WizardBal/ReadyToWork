-- Talk & quests: three separate switches for talking to NPCs.
--   Skip talk  picks an NPC's only chat option (the speech-bubble icon), page after page, while nothing on
--              the page waits on you: no quest to take and no finished quest to hand in.
--   Accept     takes the quests an NPC offers.
--   Turn in    hands in finished quests and takes the reward when there is no choice to make.
-- A strip of three buttons on the dialogue and quest windows flips them; so do the quick menu, the settings
-- page, key bindings and /rtw talk. Holding Shift while you start talking pauses all three until that
-- conversation ends.
--
-- Never done for you, because the game asks first or it costs something: choosing between rewards, a quest
-- that costs gold to hand in, a PvP-flag quest, a quest from an item or an area (the game turns those into a
-- pop-up), and any option that isn't a plain chat line (vendor, trainer, flight master, innkeeper, bank) or
-- that reads like unlearning, resetting, binding or teleporting. Gold confirmations the game pops up are
-- never answered. At most MAX_STEPS automatic steps happen per conversation, and the same page is never
-- answered twice, so an NPC that loops can't keep it busy.
--
-- From Blizzard's own code (build 70938): GossipFrameShared.lua selects with SelectOptionByIndex(orderIndex)
-- and itself picks a lone option flagged selectOptionWhenOnlyOption; the Mainline QuestFrame.lua accepts with
-- AcknowledgeAutoAcceptQuest() when QuestGetAutoAccept(), else AcceptQuest(); asks before PvP quests
-- (QuestFlagsPVP) and quests with GetQuestMoneyToGet() > 0; and hands in with GetQuestReward(choice), choice 0
-- when there is none. The chat icon is file 132053 (interface/gossipframe/gossipgossipicon.blp).

local _, Helper = ...

local Talk = {}
Helper.Talk = Talk

local CHAT_ICON = 132053
local MAX_STEPS = 15
local END_DELAY = 1.5   -- a conversation has ended when no dialogue or quest window comes back within this
local DENY = { "unlearn", "reset", "home", "bind", "teleport", "duel", "buy", "purchase", "cost" }
local SWITCHES = {
  { key = "skip", word = "skip", label = "Skip talk",
    tip = "Picks an NPC's only chat line for you, page after page, while nothing on the page waits on you." },
  { key = "accept", word = "accept", label = "Accept", tip = "Takes the quests an NPC offers." },
  { key = "turnIn", word = "turnin", label = "Turn in",
    tip = "Hands in finished quests, and takes the reward when there is no choice to make." },
}
local BY_WORD = {}
for _, switch in ipairs(SWITCHES) do BY_WORD[switch.word] = switch end

local settings
local steps, paused, seen, tried = 0, false, {}, {}
local last          -- the last conversation event, to act on at once when a switch is turned on mid-talk
local strip
local endToken = 0

local function Plain(value)
  if issecretvalue and issecretvalue(value) then return nil end
  return value
end

local function Call(func, ...)
  if type(func) ~= "function" then return nil end
  local ok, a, b, c, d, e, f, g, h = pcall(func, ...)
  if ok then return a, b, c, d, e, f, g, h end
end

local function Say(text)
  if settings.chat then Helper.Print(text) end
end

-- Whether automation may act now. Shift at any point of a conversation pauses it until the conversation ends.
local function Ready()
  if not settings.enabled then return false end
  if IsShiftKeyDown and IsShiftKeyDown() then paused = true end
  return not paused and steps < MAX_STEPS
end

local function Step()
  steps = steps + 1
end

local function Ended()
  steps, paused, seen, tried, last = 0, false, {}, {}, nil
end

-- A window closed: the conversation is over unless another window follows soon (handing in a quest from a
-- dialogue closes one and opens the other, and the dialogue comes back afterwards).
local function MaybeEnded()
  endToken = endToken + 1
  local token = endToken
  C_Timer.After(END_DELAY, function()
    if token == endToken and not (GossipFrame and GossipFrame:IsShown()) and not (QuestFrame and QuestFrame:IsShown()) then
      Ended()
    end
  end)
end

local function Shown(host)
  endToken = endToken + 1
end

local function Wanted(trivial, ignored)
  return not Plain(ignored) and (settings.acceptGrey or not Plain(trivial))
end

-- Dialogue windows -------------------------------------------------------------------------------------------

local function ChatOption(option)
  if type(option) ~= "table" then return false end
  local status = Plain(option.status)
  if status ~= nil and status ~= 0 then return false end
  if Plain(option.icon) ~= CHAT_ICON then return false end
  local name = Plain(option.name)
  if type(name) ~= "string" then return false end
  local lower = name:lower()
  for _, word in ipairs(DENY) do
    if lower:find(word, 1, true) then return false end
  end
  return true
end

-- The one option Skip talk may pick, or nil.
function Talk.SkipChoice()
  local G = C_GossipInfo
  if (Call(G.GetNumAvailableQuests) or 0) > 0 then return nil end
  for _, quest in ipairs(Call(G.GetActiveQuests) or {}) do
    if Plain(quest.isComplete) then return nil end
  end
  local options, usable = Call(G.GetOptions) or {}, {}
  for _, option in ipairs(options) do
    local status = Plain(option.status)
    if status == nil or status == 0 then usable[#usable + 1] = option end
  end
  if #usable ~= 1 or not ChatOption(usable[1]) then return nil end
  return usable[1]
end

local function OnGossip()
  last = OnGossip
  if not Ready() then return end
  local G = C_GossipInfo
  if not G then return end
  if settings.turnIn then
    for _, quest in ipairs(Call(G.GetActiveQuests) or {}) do
      local id = Plain(quest.questID)
      if id and Plain(quest.isComplete) and not Plain(quest.isIgnored) and not tried[id] then
        tried[id] = true; Step(); G.SelectActiveQuest(id); return
      end
    end
  end
  if settings.accept then
    for _, quest in ipairs(Call(G.GetAvailableQuests) or {}) do
      local id = Plain(quest.questID)
      if id and Wanted(quest.isTrivial, quest.isIgnored) and not tried[id] then
        tried[id] = true; Step(); G.SelectAvailableQuest(id); return
      end
    end
  end
  if settings.skip then
    local option = Talk.SkipChoice()
    if not option then return end
    local page = tostring(Plain(Call(G.GetText)) or "") .. "\1" .. tostring(Plain(option.name))
    if seen[page] then return end
    seen[page] = true
    Step()
    G.SelectOptionByIndex(Plain(option.orderIndex) or 0)
  end
end

-- Quest windows ------------------------------------------------------------------------------------------------

local function OnGreeting()
  last = OnGreeting
  if not Ready() then return end
  if settings.turnIn then
    for i = 1, Call(GetNumActiveQuests) or 0 do
      local _, complete = Call(GetActiveTitle, i)
      local id = Plain(Call(GetActiveQuestID, i)) or ("active" .. i)
      if Plain(complete) and not tried[id] then
        tried[id] = true; Step(); SelectActiveQuest(i); return
      end
    end
  end
  if settings.accept then
    for i = 1, Call(GetNumAvailableQuests) or 0 do
      local trivial, _, _, _, questID = Call(GetAvailableQuestInfo, i)
      local id = Plain(questID) or ("available" .. i)
      if Wanted(trivial) and not tried[id] then
        tried[id] = true; Step(); SelectAvailableQuest(i); return
      end
    end
  end
end

local function Title()
  local title = Plain(Call(GetTitleText))
  return type(title) == "string" and title ~= "" and title or "the quest"
end

local function OnDetail(startItemID)
  last = function() OnDetail(startItemID) end
  if not settings.accept or not Ready() then return end
  if startItemID and startItemID ~= 0 then return end                         -- the game makes it a pop-up
  if Call(QuestGetAutoAccept) and Call(QuestIsFromAreaTrigger) then return end -- ditto
  if Call(QuestFlagsPVP) then
    Say(("%s flags you for PvP: accept it yourself if you want it."):format(Title()))
    return
  end
  local title = Title()
  Step()
  if Call(QuestGetAutoAccept) then AcknowledgeAutoAcceptQuest() else AcceptQuest() end
  Say("Accepted " .. title .. ".")
end

local function Costs()
  local money = Plain(Call(GetQuestMoneyToGet))
  if type(money) == "number" and money > 0 then
    Say(("%s costs %s to hand in: do it yourself if you want to."):format(Title(), Helper.Money and Helper.Money(money) or tostring(money)))
    return true
  end
end

local function OnProgress()
  last = OnProgress
  if not settings.turnIn or not Ready() then return end
  if not Call(IsQuestCompletable) or Costs() then return end
  Step()
  CompleteQuest()
end

local function OnComplete()
  last = OnComplete
  if not settings.turnIn or not Ready() or Costs() then return end
  local choices = Plain(Call(GetNumQuestChoices)) or 0
  if choices > 1 then
    Say(("Choose your reward for %s."):format(Title()))
    return
  end
  local title = Title()
  Step()
  GetQuestReward(choices == 1 and 1 or 0)
  Say("Turned in " .. title .. ".")
end

-- The buttons ----------------------------------------------------------------------------------------------------

-- Flips one switch (a button, key binding or menu entry) as an undoable settings edit.
function Talk.Flip(word)
  local switch = BY_WORD[word]
  if not switch or not Helper.commands.talk then return end
  local value = not settings[switch.key]
  local run = function() Helper.commands.talk(switch.word .. (value and " on" or " off")) end
  if Helper.Store then Helper.Store.Edit("talk", switch.label .. (value and " on" or " off"), run) else run() end
end

local function Paint()
  if not strip then return end
  for _, button in ipairs(strip.buttons) do
    local on = settings.enabled and settings[button.switch.key]
    button.setDot(on)
    button.label:SetText(button.switch.label)
    local W = Helper.Widgets
    local setFill = W and W.SetColor or function(t, r, g, b, a) t:SetColorTexture(r, g, b, a) end
    -- On: a filled green button with white text; off: dim. Readable without hovering.
    if on then
      setFill(button.bg, .10, .48, .24, .95)
      if button.border and W and W.SetColor then W.SetColor(button.border, .24, .82, .48, .65) end
      button.label:SetTextColor(1, 1, 1)
    else
      setFill(button.bg, .13, .19, .23, .75)
      if button.border and W and W.SetColor then W.SetColor(button.border, 1, 1, 1, .085) end
      button.label:SetTextColor(.62, .66, .70)
    end
  end
end

-- The tooltip goes beside the strip, never over it. The strip sits above a window near the top of the
-- screen, so a tooltip anchored above it is pushed back down over the buttons by the screen edge.
local function ShowTip(button)
  local switch, on = button.switch, settings.enabled and settings[button.switch.key]
  GameTooltip:SetOwner(button, "ANCHOR_NONE")
  GameTooltip:SetText(switch.label .. (on and ": on" or ": off"), 1, 1, 1)
  GameTooltip:AddLine(switch.tip, nil, nil, nil, true)
  GameTooltip:AddLine("Click to turn it " .. (on and "off" or "on")
    .. ". Hold Shift while you start talking to an NPC to do it all yourself that time.", .8, .8, .8, true)
  GameTooltip:AddLine("Move or hide these buttons on the Talk & quests page.", .6, .6, .6, true)
  GameTooltip:Show()
  GameTooltip:ClearAllPoints()
  local right, screen, width = strip:GetRight(), UIParent:GetRight(), GameTooltip:GetWidth()
  local fits = true
  if right and screen and width then
    fits = right * strip:GetEffectiveScale() + 6 + width * GameTooltip:GetEffectiveScale()
      <= screen * UIParent:GetEffectiveScale()
  end
  if fits then
    GameTooltip:SetPoint("TOPLEFT", strip, "TOPRIGHT", 6, 0)
  else
    GameTooltip:SetPoint("TOPRIGHT", strip, "TOPLEFT", -6, 0)
  end
end

local function Place(host)
  if not strip or not host then return end
  strip:SetParent(host)
  strip:ClearAllPoints()
  if settings.buttons == "bottom" then
    strip:SetPoint("TOPRIGHT", host, "BOTTOMRIGHT", -4, -2)
  else
    strip:SetPoint("BOTTOMRIGHT", host, "TOPRIGHT", -4, 2)
  end
  strip:SetFrameStrata("HIGH")
  strip:SetShown(settings.enabled and settings.buttons ~= "hidden")
  Paint()
end

local function Build()
  local W = Helper.Widgets
  if strip or not W then return strip end
  strip = CreateFrame("Frame", "ReadyToWorkTalkButtons", UIParent)
  strip:SetSize(3 * 86 + 8, 24)
  strip.buttons = {}
  for i, switch in ipairs(SWITCHES) do
    local button = W.Button(strip, switch.label)
    button.switch = switch
    button:SetSize(84, 22)
    button:SetPoint("RIGHT", strip, "RIGHT", -(3 - i) * 86, 0)
    button.label:ClearAllPoints(); button.label:SetPoint("CENTER", 5, 0)
    local setDot, dot = W.Dot(button)
    dot:SetPoint("RIGHT", button.label, "LEFT", -5, 0)
    button.setDot = setDot
    button:SetScript("OnClick", function(self)
      Talk.Flip(switch.word)
      if GameTooltip:IsOwned(self) then ShowTip(self) end
    end)
    button:SetScript("OnEnter", ShowTip)
    button:SetScript("OnLeave", function(self) if GameTooltip:IsOwned(self) then GameTooltip:Hide() end end)
    strip.buttons[i] = button
  end
  return strip
end

local function Hosted(host)
  Shown(host)
  if not host or not settings.enabled then return end
  Build()
  Place(host)
end

function Talk.Refresh()
  if not strip then return end
  local host = (GossipFrame and GossipFrame:IsShown() and GossipFrame) or (QuestFrame and QuestFrame:IsShown() and QuestFrame)
  if host then Place(host) else strip:Hide() end
end

-- Status lines for the home page and the Status card.
function Talk.Status()
  local parts = {}
  for _, switch in ipairs(SWITCHES) do
    parts[#parts + 1] = switch.label .. ": " .. (settings[switch.key] and "on" or "off")
  end
  return { table.concat(parts, " · ") }
end

function Talk.StatusChips()
  local chips = {}
  for _, switch in ipairs(SWITCHES) do
    local on = settings and settings[switch.key] == true
    chips[#chips + 1] = { label = switch.label, value = on and "On" or "Off", tone = on and "accent" or "dim" }
  end
  return chips
end

Talk.MAX_STEPS = MAX_STEPS

Helper.Feature(function()
  settings = Helper.db.talk
  if settings.buttons ~= "top" and settings.buttons ~= "bottom" and settings.buttons ~= "hidden" then settings.buttons = "top" end

  Helper.On("GOSSIP_SHOW", function() Hosted(GossipFrame); OnGossip() end)
  Helper.On("GOSSIP_CLOSED", function(continuing)
    if not continuing then MaybeEnded() end
    Talk.Refresh()
  end)
  Helper.On("QUEST_GREETING", function() Hosted(QuestFrame); OnGreeting() end)
  Helper.On("QUEST_DETAIL", function(startItemID) Hosted(QuestFrame); OnDetail(startItemID) end)
  Helper.On("QUEST_PROGRESS", function() Hosted(QuestFrame); OnProgress() end)
  Helper.On("QUEST_COMPLETE", function() Hosted(QuestFrame); OnComplete() end)
  Helper.On("QUEST_FINISHED", function()
    MaybeEnded()
    Talk.Refresh()
  end)

  Helper.commands.talk = function(rest)
    local word, arg = rest:match("^(%S*)%s*(.-)$")
    local switch = BY_WORD[word]
    if switch then
      local value
      if arg == "on" then value = true elseif arg == "off" then value = false else value = not settings[switch.key] end
      settings[switch.key] = value
      Helper.Print(("%s %s."):format(switch.label, value and "on" or "off"))
      Paint()
      if value and settings.enabled and last then last() end
    elseif word == "grey" and (arg == "on" or arg == "off") then
      settings.acceptGrey = arg == "on"
      Helper.Print("Accepting grey (low-level) quests " .. arg .. ".")
    elseif word == "chat" and (arg == "on" or arg == "off") then
      settings.chat = arg == "on"
      Helper.Print("Chat lines for accepted and handed-in quests " .. arg .. ".")
    elseif word == "buttons" and (arg == "top" or arg == "bottom" or arg == "hidden") then
      settings.buttons = arg
      Helper.Print(arg == "hidden" and "The Skip talk, Accept and Turn in buttons are hidden; the quick menu, key bindings and /rtw talk still switch them."
        or ("The Skip talk, Accept and Turn in buttons sit %s the dialogue window."):format(arg == "top" and "above" or "below"))
      Talk.Refresh()
    elseif word == "on" or word == "off" or word == "" then
      Helper.Toggle(settings, word, "Talk & quests")
      Talk.Refresh()
    else
      Helper.Print("/rtw talk [on|off|skip|accept|turnin [on|off]|grey on|off|chat on|off|buttons top|bottom|hidden]")
    end
  end
  Helper.help[#Helper.help + 1] = "/rtw talk skip | accept | turnin [on|off] - skip NPC chat, accept quests, hand in quests (each on its own)"
end)
