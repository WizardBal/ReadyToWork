-- A button that fans out the least valuable junk in your bags, cheapest
-- first, so you can destroy what you choose.
--
-- "Least valuable" is by what the whole stack sells for, so a stack of
-- twenty cheap things can outrank a single dearer one. Clicking the button
-- fans the choices out in a row, the cheapest next to the button. Tiles
-- show stack value or water rank. Clicking one destroys one stack; a
-- right-click puts it on your "never destroy" list instead.
--
-- What is offered:
--   * every grey item;
--   * optional conjured mage food and water (grouped by rank at zero copper, smallest stack first);
--   * any bag item dropped onto the button (offered first in the fan, regardless of quality or binding);
--   * never anything on the "never destroy" list.
--
-- The fan makes it safe: you see every candidate and pick.
--
-- The game allows an item to be destroyed only from a click, so this cannot
-- happen by itself when the bags fill up.

local _, Helper = ...

local Destroy = {}
Helper.Destroy = Destroy

local COMMON = Enum and Enum.ItemQuality and Enum.ItemQuality.Common or 1
-- Item outputs of Conjure Water ranks 1 through 8 in WoW Forever.
local MAGE_WATER = {
  [5350] = 1,   -- Conjured Water
  [2288] = 2,   -- Conjured Fresh Water
  [2136] = 3,   -- Conjured Purified Water
  [3772] = 4,   -- Conjured Spring Water
  [8077] = 5,   -- Conjured Mineral Water
  [8078] = 6,   -- Conjured Sparkling Water
  [8079] = 7,   -- Conjured Crystal Water
  [231778] = 8, -- Mountain Spring Water
}
local MAGE_FOOD = { [5349]=1, [1113]=2, [1114]=3, [1487]=4, [8075]=5, [8076]=6, [22895]=7 }

local SLOT_SIZE = 36
local PITCH_ACROSS, PITCH_UP = 48, 58   -- slot spacing in a row, in a column
local OPEN_TIME, STAGGER = 0.16, 0.025  -- how the fan spreads out
local AWAY_SECONDS = 2                  -- the fan folds when the mouse has left this long
local CLICK_PAUSE = 0.4                 -- after a destroy or item drop
local DELETE_TIMEOUT = 2
local DROP_HINT = "Drop a bag item here to include it in the destroy button."
local MENU_DROP_HINT = "Drop a bag item on the destroy button to include it."
local DROP_ICON = "Interface\\Icons\\INV_Misc_Bag_10"

local settings
local button, fan
local slots = {}
local target         -- the cheapest candidate, shown on the button
local fanOpen = false
local fanSettled = true   -- the slots have reached their places
local openedAt, awaySince, pausedUntil = 0, nil, 0
local deletion


local function QuestClear(bag, slot)
  local questInfo = C_Container.GetContainerItemQuestInfo
  if not questInfo then return false end
  local ok, info = pcall(questInfo, bag, slot)
  return ok and type(info) == "table" and info.isQuestItem == false and info.questID == nil
end

local function AllowsMageWater(bag, slot, info)
  return settings.mageWater and info.quality == COMMON and QuestClear(bag, slot)
end

local function CandidateValue(bag, slot, info, count, grey)
  local included = settings.included[info.itemID] ~= nil
  local conjured = MAGE_WATER[info.itemID] ~= nil or MAGE_FOOD[info.itemID] ~= nil
  if included then
    if conjured or info.hasNoValue then return 0 end
    local each = Helper.SellPrice(info.hyperlink)
    if each == nil then
      Destroy.unpriced = true
      return nil
    end
    return each * count
  end
  if MAGE_FOOD[info.itemID] then
    return settings.mageFood and info.quality == COMMON and QuestClear(bag, slot) and 0 or nil
  end
  if MAGE_WATER[info.itemID] then
    return AllowsMageWater(bag, slot, info) and 0 or nil
  end
  if not grey then
    return nil
  end
  local each = info.hasNoValue and 0 or Helper.SellPrice(info.hyperlink)
  if each == nil then
    Destroy.unpriced = true -- look again when the game has loaded it
    return nil
  end
  return each * count
end

-- Cheaper first, with grey before white at equal value. Mage water goes
-- weakest first. Other ties go to smaller stacks and then to bag order.
local function Cheaper(left, right)
  if left.included ~= right.included then
    return left.included
  end
  if left.value ~= right.value then
    return left.value < right.value
  end
  if left.grey ~= right.grey then
    return left.grey
  end
  local leftRank, rightRank = MAGE_WATER[left.itemID] or MAGE_FOOD[left.itemID], MAGE_WATER[right.itemID] or MAGE_FOOD[right.itemID]
  if leftRank ~= rightRank then
    return (leftRank or math.huge) < (rightRank or math.huge)
  end
  if left.count ~= right.count then
    return left.count < right.count
  end
  if left.bag ~= right.bag then
    return left.bag < right.bag
  end
  return left.slot < right.slot
end

local function AddSmallestStack(groups, item)
  local previous = groups[item.itemID]
  if previous and previous.count <= item.count then
    previous.total = previous.total + item.count
  else
    item.total = item.count + (previous and previous.total or 0)
    groups[item.itemID] = item
  end
end

-- Manually included items first, then other candidates, cheapest first.
-- Grouped rows point to the smallest eligible stack. `count` is that
-- stack's size and `total` is the quantity shown on the tile. A filtered
-- lookup checks one rank just before a click destroys it.
function Destroy.List(limit, waterItemID)
  local list, groups = {}, {}
  if not waterItemID then
    Destroy.unpriced = false
  end
  for _, bag in ipairs(Helper.Bags()) do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID and Helper.ItemLinkKey(info.hyperlink) and (not waterItemID or info.itemID == waterItemID)
          and not info.isLocked and not settings.keep[info.itemID] then
        local grey = info.quality == Helper.POOR
        local count = info.stackCount or 1
        local value = CandidateValue(bag, slot, info, count, grey)
        if value ~= nil then
          local item = {
            bag = bag, slot = slot, itemID = info.itemID, count = count, value = value,
            link = info.hyperlink, icon = info.iconFileID, quality = info.quality, grey = grey,
            guid = Helper.BagItemGUID(bag, slot),
            included = settings.included[info.itemID] ~= nil,
          }
          if item.included or MAGE_WATER[item.itemID] or MAGE_FOOD[item.itemID] then
            AddSmallestStack(groups, item)
          else
            list[#list + 1] = item
          end
        end
      end
    end
  end
  for _, item in pairs(groups) do
    list[#list + 1] = item
  end
  table.sort(list, Cheaper)
  if limit then
    for index = #list, limit + 1, -1 do
      list[index] = nil
    end
  end
  return list
end

-- The cheapest candidate, or nil.
function Destroy.Find()
  return Destroy.List(1)[1]
end

-- Free slots in ordinary bags (not quivers or other special bags).
-- (not the reagent bag: its room doesn't take junk or loot)
function Destroy.FreeSlots()
  return Helper.FreeSlots()
end

function Destroy.ShouldShow(found)
  if not settings.enabled or not found then
    return false
  end
  -- While the choices are out the button stays, even once there is room.
  return found.included or fanOpen or settings.mode == "always" or Destroy.FreeSlots() <= settings.freeSlots
end

-- Destroying ------------------------------------------------------------------

-- Coalesce bag updates and refresh after clicks, using the current bag state.
local queued = false
local function RefreshSoon()
  if queued then
    return
  end
  queued = true
  C_Timer.After(0.1, function()
    queued = false
    Destroy.Refresh()
  end)
end

local function CheckDeletion(timedOut)
  if not deletion or deletion.issuing then return end
  local item = deletion.item
  local kind = GetCursorInfo()
  if deletion.cursorCleared and kind == nil and Helper.CountBagItem(item.itemID) == deletion.bagCount - item.count then
    deletion = nil
    pausedUntil = GetTime() + CLICK_PAUSE
    if settings.reportDestroyed~=false then
      local worth = item.value and item.value > 0 and (" (worth %s)"):format(Helper.Money(item.value)) or ""
      Helper.Print(("Destroyed %s%s%s."):format(
        item.link or "an item", item.count > 1 and (" x" .. item.count) or "", worth))
    end
    RefreshSoon()
    return "confirmed"
  end
  if timedOut or (deletion.cursorCleared and kind ~= nil) then
    deletion = nil
    -- The game refused it and left it on the cursor: it goes back to its bag, not left in your hand.
    local _, cursorID = GetCursorInfo()
    if kind == "item" and cursorID == item.itemID and ClearCursor then
      ClearCursor()
      Helper.Print(("The game didn't destroy %s; it is back in your bag."):format(item.link or "the item"))
      RefreshSoon()
      return "unconfirmed"
    end
    Helper.Print("Could not confirm destruction. Check the item on your cursor and in your bags.")
    RefreshSoon()
    return "unconfirmed"
  end
  return "pending"
end

-- Requests one deletion from the hardware click, then observes the outcome.
-- Uncommon or better (only items you dragged onto the button can be): a second click within CONFIRM_SECONDS.
local CONFIRM_SECONDS = 4
local confirmKey, confirmUntil
function Destroy.DestroyItem(item)
  if not settings.enabled or not item or deletion or not Helper.PickupItem or not DeleteCursorItem then
    return "unavailable"
  end
  if (item.quality or 0) >= 2 then
    local key = (item.guid or "") .. ":" .. tostring(item.bag) .. ":" .. tostring(item.slot)
    if confirmKey ~= key or GetTime() > (confirmUntil or 0) then
      confirmKey, confirmUntil = key, GetTime() + CONFIRM_SECONDS
      Helper.Print(("%s is uncommon or better: click it again within %d seconds to destroy it."):format(
        item.link or "That item", CONFIRM_SECONDS))
      return "unavailable"
    end
    confirmKey, confirmUntil = nil, nil
  end
  if GetCursorInfo() ~= nil then
    Helper.Print("Empty your cursor before destroying an item.")
    return "unavailable"
  end
  if MAGE_WATER[item.itemID] or MAGE_FOOD[item.itemID] then
    local current = Destroy.List(1, item.itemID)[1]
    if not current or current.count ~= item.count then
      Destroy.Refresh() -- show the new stack size before acting
      return "unavailable"
    end
    item = current
  end
  -- The bags may have changed since it was drawn. Destroy only what was
  -- shown, and only if it is still there.
  local info = C_Container.GetContainerItemInfo(item.bag, item.slot)
  local key = Helper.ItemLinkKey(item.link)
  if not info or info.itemID ~= item.itemID or info.quality ~= item.quality or info.isLocked
      or info.stackCount ~= item.count or settings.keep[item.itemID]
      or not key or Helper.ItemLinkKey(info.hyperlink) ~= key
      or (item.guid and Helper.BagItemGUID(item.bag, item.slot) ~= item.guid)
      or CandidateValue(item.bag, item.slot, info, item.count, info.quality == Helper.POOR) ~= item.value then
    Destroy.Refresh()
    return "unavailable"
  end

  local bagCount = Helper.CountBagItem(item.itemID)
  Helper.PickupItem(item.bag, item.slot)
  local kind, itemID, cursorLink = GetCursorInfo()
  if kind ~= "item" or itemID ~= item.itemID or Helper.ItemLinkKey(cursorLink) ~= key then
    -- (whatever the pickup put on the cursor goes back where it came from, not left in the player's hand)
    if kind ~= nil and ClearCursor then ClearCursor() end
    Destroy.Refresh()
    return "unavailable"
  end
  local attempt = { item = item, bagCount = bagCount, issuing = true }
  deletion = attempt
  local ok = pcall(DeleteCursorItem)
  -- A later cursor drop could be the player moving or selling the item.
  -- Only reconcile a delayed bag update if our call cleared the cursor.
  attempt.cursorCleared = ok and GetCursorInfo() == nil
  attempt.issuing = false
  local result = CheckDeletion(not ok)
  if result == "pending" then
    C_Timer.After(DELETE_TIMEOUT, function()
      if deletion == attempt then CheckDeletion(true) end
    end)
  end
  return result
end

-- Puts an item on the "never destroy" list.
function Destroy.Keep(itemID, link)
  settings.keep[itemID] = link or settings.keep[itemID] or true
  Helper.Print((link or "That item") .. " is protected. Manage protected items in Quick destroy settings.")
  Destroy.Refresh()
end

function Destroy.KeptCount()
  local count = 0
  for _ in pairs(settings.keep) do
    count = count + 1
  end
  return count
end

-- The fan ---------------------------------------------------------------------

-- "45c", "1s 20c", "2g 5s": short enough to sit under an icon.
local function ShortMoney(copper)
  copper = math.floor(copper + 0.5)
  if copper < 100 then
    return copper .. "c"
  elseif copper < 10000 then
    local rest = copper % 100
    return math.floor(copper / 100) .. "s" .. (rest > 0 and (" " .. rest .. "c") or "")
  end
  local silver = math.floor(copper / 100) % 100
  return math.floor(copper / 10000) .. "g" .. (silver > 0 and (" " .. silver .. "s") or "")
end

local function ShowItemTooltip(owner, item, lines)
  GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
  if not (GameTooltip.SetBagItem and pcall(GameTooltip.SetBagItem, GameTooltip, item.bag, item.slot)) then
    GameTooltip:SetText(item.link or "Item")
  end
  GameTooltip:AddLine(" ")
  local rank = MAGE_WATER[item.itemID] or MAGE_FOOD[item.itemID]
  if rank then
    GameTooltip:AddLine(("Rank %d · %d total"):format(rank, item.total), 1, 1, 1)
  elseif item.included then
    GameTooltip:AddLine(("Manually included · %d in bags"):format(item.total), 1, 1, 1)
  end
  for _, line in ipairs(lines) do
    GameTooltip:AddLine(line[1], line[2], line[3], line[4], true)
  end
  GameTooltip:Show()
end

local function ClickHint(item)
  return item.total and ("Click to destroy the smallest stack (%d)."):format(item.count) or "Click to destroy it."
end

local function SetSlotBorder(slot, isGrey)
  local W = Helper.Widgets
  if slot.styled and W then
    W.SetColor(slot.Border, isGrey and { .50, .54, .62, .72 } or { .90, .93, .98, .88 })
  else
    slot.Border:SetColorTexture(isGrey and 0.45 or 0.9, isGrey and 0.45 or 0.9, isGrey and 0.45 or 0.9, 0.95)
  end
end

local function SlotFor(index)
  local slot = slots[index]
  if slot then
    return slot
  end
  local W = Helper.Widgets
  slot = CreateFrame("Button", nil, fan)
  slot:SetSize(SLOT_SIZE, SLOT_SIZE)
  slot:SetFrameStrata("DIALOG")

  if W then
    slot.styled = true
    W.Shadow(slot, 8, .38)
    slot.bg, slot.Border = W.Surface(slot, "md", W.colors.window, W.colors.borderStrong)
    slot.Icon = W.Icon(slot, nil, SLOT_SIZE - 6)
    slot.Icon:SetPoint("CENTER")
    slot.Count = slot:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    slot.Count:SetPoint("BOTTOMRIGHT", -3, 3)
    slot.ValueBg = CreateFrame("Frame", nil, slot)
    slot.ValueBg:SetSize(34, 14)
    slot.ValueBg:SetPoint("TOP", slot, "BOTTOM", 0, -2)
    slot.ValueBg:EnableMouse(false)
    W.Surface(slot.ValueBg, "pill", { .055, .059, .068, .92 }, W.colors.border)
    slot.Value = W.Font(slot.ValueBg, "micro")
    slot.Value:SetTextColor(unpack(W.colors.text))
    slot.Value:SetPoint("CENTER")
    slot.Value:SetJustifyH("CENTER")
    local highlight = W.Highlight(slot, "md")
    W.SetColor(highlight, .95, .30, .32, .24)
  else
    slot.Border = slot:CreateTexture(nil, "BACKGROUND")
    slot.Border:SetPoint("TOPLEFT", -2, 2)
    slot.Border:SetPoint("BOTTOMRIGHT", 2, -2)
    slot.Icon = slot:CreateTexture(nil, "ARTWORK")
    slot.Icon:SetAllPoints()
    slot.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    slot.Count = slot:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    slot.Count:SetPoint("BOTTOMRIGHT", -2, 2)
    -- What the stack is worth, under the icon: the order at a glance.
    slot.Value = slot:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    slot.Value:SetPoint("TOP", slot, "BOTTOM", 0, -3)
    local highlight = slot:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 0.2, 0.2, 0.3)
  end

  slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  slot:SetScript("OnClick", function(self, mouse)
    local item = self.item
    if not item or GetTime() < pausedUntil or GetCursorInfo() ~= nil then
      return
    end
    if mouse == "RightButton" then
      Destroy.Keep(item.itemID, item.link)
    elseif Destroy.DestroyItem(item) == "confirmed" and not item.total then
      self:Hide() -- grouped water tiles refresh in place
    end
  end)
  slot:SetScript("OnEnter", function(self)
    if self.item then
      local valueLine = (MAGE_WATER[self.item.itemID] or MAGE_FOOD[self.item.itemID])
          and "This conjured item has no vendor value."
        or (self.item.value == 0 and "This item has no vendor value."
          or ("The stack sells for %s."):format(Helper.Money(self.item.value)))
      ShowItemTooltip(self, self.item, {
        { ClickHint(self.item), 1, 0.3, 0.3 },
        { valueLine, 1, 1, 1 },
        { "Right-click: never offer this item again.", 0.6, 0.6, 0.6 },
      })
    end
  end)
  slot:SetScript("OnLeave", function() GameTooltip:Hide() end)
  slots[index] = slot
  return slot
end

-- Which way the row runs: away from the nearer side of the screen, or up or
-- down when there is no room sideways. Returns the step between slots.
local function FanStep(count)
  local dir=settings.direction
  if dir=="left" then return -PITCH_ACROSS,0 elseif dir=="right" then return PITCH_ACROSS,0 elseif dir=="up" then return 0,PITCH_UP elseif dir=="down" then return 0,-PITCH_UP end
  local x, y = button:GetCenter()
  local width, height = UIParent:GetWidth(), UIParent:GetHeight()
  if not (x and y and width and height) then
    return -PITCH_ACROSS, 0
  end
  local toLeft = x > width / 2
  local room = toLeft and x or (width - x)
  if room >= (count + 0.5) * PITCH_ACROSS then
    return toLeft and -PITCH_ACROSS or PITCH_ACROSS, 0
  end
  return 0, y < height / 2 and PITCH_UP or -PITCH_UP
end

-- Puts each slot where it belongs `elapsed` seconds into opening.
local function PlaceSlots(elapsed)
  local shown = 0
  for _, slot in ipairs(slots) do
    if slot.item then
      shown = shown + 1
    end
  end
  local stepX, stepY = FanStep(shown)
  local moving = false
  for index, slot in ipairs(slots) do
    if slot.item then
      local progress = (elapsed - (index - 1) * STAGGER) / OPEN_TIME
      if progress < 1 then
        moving = true
      end
      progress = math.max(0, math.min(1, progress))
      local eased = 1 - (1 - progress) ^ 3
      slot:ClearAllPoints()
      slot:SetPoint("CENTER", button, "CENTER", stepX * index * eased, stepY * index * eased)
      slot:SetAlpha(eased)
    end
  end
  return moving
end

local function FillFan()
  local list = Destroy.List(settings.fanSize)
  for index, item in ipairs(list) do
    local slot = SlotFor(index)
    slot.item = item
    slot.Icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    slot.Count:SetText(item.total or (item.count > 1 and item.count or ""))
    local rank = MAGE_WATER[item.itemID] or MAGE_FOOD[item.itemID]
    slot.Value:SetText(rank and ("Rank " .. rank) or ShortMoney(item.value))
    if slot.ValueBg then
      slot.ValueBg:SetWidth(math.max(30, (slot.Value:GetStringWidth() or 24) + 10))
    end
    SetSlotBorder(slot, item.grey)
    slot:Show()
    if GameTooltip:IsOwned(slot) then
      slot:GetScript("OnEnter")(slot)
    end
  end
  for index = #list + 1, #slots do
    slots[index].item = nil
    slots[index]:Hide()
    if GameTooltip:IsOwned(slots[index]) then
      GameTooltip:Hide()
    end
  end
  fanSettled = false
  return #list
end

function Destroy.CloseFan()
  if not fanOpen then
    return
  end
  fanOpen = false
  fan:Hide()
  for _, slot in ipairs(slots) do
    slot.item = nil
    slot:Hide()
  end
  Destroy.Refresh()
end

function Destroy.OpenFan()
  if fanOpen or not button or not button:IsShown() then
    return
  end
  fanOpen = true
  openedAt, awaySince = GetTime(), nil
  if FillFan() == 0 then
    Destroy.CloseFan()
    return
  end
  PlaceSlots(0)
  fan:Show()
end

function Destroy.IsFanOpen()
  return fanOpen
end

-- Spreads the row out, then watches for the mouse to leave.
local function FanUpdate()
  local now = GetTime()
  if not fanSettled then
    fanSettled = not PlaceSlots(now - openedAt)
  end
  local over = button:IsMouseOver()
  for _, slot in ipairs(slots) do
    over = over or (slot.item ~= nil and slot:IsMouseOver())
  end
  if over then
    awaySince = nil
  else
    awaySince = awaySince or now
    if now - awaySince > AWAY_SECONDS then
      Destroy.CloseFan()
    end
  end
end

-- The button --------------------------------------------------------------------

local function IncludeCursorItem()
  if not settings.enabled or deletion then
    return
  end
  local itemID, link = Helper.CursorBagItem()
  if not itemID then
    return
  end
  if settings.keep[itemID] then
    Helper.Print("That item is on your never-destroy list.")
    return
  end

  pausedUntil = GetTime() + CLICK_PAUSE -- a drop can also dispatch a click-up
  local label = link or ("Item %d"):format(itemID)
  local alreadyIncluded = settings.included[itemID] ~= nil
  settings.included[itemID] = label
  ClearCursor()
  Helper.Print(label .. (alreadyIncluded and " is already included in the destroy button." or " added to the destroy button."))
  RefreshSoon()
end

function Destroy.Refresh()
  if not button or deletion then
    return
  end
  local dragging = settings.enabled and Helper.CursorBagItem() ~= nil
  local found
  if not dragging then
    found = Destroy.Find()
  end
  if not dragging and not Destroy.ShouldShow(found) then
    target = nil
    button:Hide()
    if fanOpen then
      Destroy.CloseFan()
    end
    return
  end
  target = found
  button.Icon:SetTexture(dragging and DROP_ICON or found.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
  button.Count:SetText(found and (found.total or (found.count > 1 and found.count or "")) or "")
  button:Show()
  if fanOpen and not dragging then
    FillFan()
    PlaceSlots(GetTime() - openedAt)
  end
  if found and not settings.fanHint then
    -- Said once, the first time the button appears.
    settings.fanHint = true
    Helper.Print("Click the red-edged button to see what can be destroyed, cheapest first. Click an item to destroy it, right-click to protect it. Alt-drag moves the button.")
  end
  if GameTooltip:IsOwned(button) then
    button:GetScript("OnEnter")(button)
  end
end

-- A left click on the button: fan the choices out, or, if set that way,
-- destroy the cheapest at once.
function Destroy.Click()
  if GetTime() < pausedUntil then
    return
  end
  if fanOpen then
    Destroy.CloseFan()
  elseif settings.click == "destroy" and target and not target.included then
    Destroy.DestroyItem(target)
  else
    Destroy.OpenFan()
  end
end

-- (menu entries' changes run as settings edits, so Undo covers them; the tooltips are in Core\Features.lua)
local function AsEdit(label, fn)
  return function()
    if Helper.Store then return Helper.Store.Edit("destroy", label, fn) end
    return fn()
  end
end

function Destroy.AddIncludedItemsMenu(root)
  local submenu = root:CreateButton("Manually included items")
  if Helper.Explain then Helper.Explain(submenu, "Manually included items") end
  local itemIDs = {}
  for itemID in pairs(settings.included) do
    itemIDs[#itemIDs + 1] = itemID
  end
  if #itemIDs == 0 then
    submenu:CreateButton(MENU_DROP_HINT)
  end
  table.sort(itemIDs)
  for _, itemID in ipairs(itemIDs) do
    local label = settings.included[itemID]
    submenu:CreateButton("Remove " .. label, AsEdit("Remove " .. label, function()
      settings.included[itemID] = nil
      Destroy.Refresh()
    end))
  end
end

-- A right click on the button opens its options.
function Destroy.CurrentItem()
  return target
end

function Destroy.Options()
  Destroy.CloseFan()
  Helper.OpenFeatureSettings("Quick destroy")
end

local function BuildButton()
  local W = Helper.Widgets
  button = CreateFrame("Button", "ReadyToWorkDestroyButton", UIParent)
  button:SetFrameStrata("MEDIUM")
  button:Hide()

  if W then
    button:SetSize(42, 42)
    W.Shadow(button, 10, .42)
    button.bg, button.border = W.Surface(button, "md", W.colors.window, W.colors.dangerBorder)
    button.Icon = W.Icon(button, nil, 32)
    button.Icon:SetPoint("CENTER")

    -- Marks it as the thing that destroys, not a bag slot.
    local mark = button:CreateTexture(nil, "OVERLAY")
    mark:SetSize(16, 16)
    mark:SetPoint("TOPRIGHT", 4, 4)
    mark:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")

    button.Count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    button.Count:SetPoint("BOTTOMRIGHT", -4, 3)

    W.Highlight(button, "md")
  else
    button:SetSize(40, 40)

    button.Icon = button:CreateTexture(nil, "ARTWORK")
    button.Icon:SetAllPoints()
    button.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    local border = button:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", -2, 2)
    border:SetPoint("BOTTOMRIGHT", 2, -2)
    border:SetColorTexture(0.6, 0.1, 0.1, 0.9)

    -- Marks it as the thing that destroys, not a bag slot.
    local mark = button:CreateTexture(nil, "OVERLAY")
    mark:SetSize(18, 18)
    mark:SetPoint("TOPRIGHT", 5, 5)
    mark:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")

    button.Count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    button.Count:SetPoint("BOTTOMRIGHT", -2, 2)

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.18)
  end

  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:SetScript("OnReceiveDrag", IncludeCursorItem)
  button:SetScript("OnClick", function(_, mouse)
    if IsAltKeyDown() then
      return -- Alt is for dragging
    end
    if GetCursorInfo() ~= nil then
      if mouse == "LeftButton" then
        IncludeCursorItem()
      end
    elseif mouse == "RightButton" then
      Destroy.Options()
    else
      Destroy.Click()
    end
  end)
  button:SetScript("OnEnter", function(self)
    if target and not target.included and settings.click == "destroy" then
      ShowItemTooltip(self, target, {
        { ClickHint(target), 1, 0.3, 0.3 },
        { ("The least valuable junk in your bags: %s for the stack."):format(Helper.Money(target.value)), 1, 1, 1 },
        { DROP_HINT, 0.6, 0.6, 0.6 },
        { "Right-click: settings.", 0.6, 0.6, 0.6 },
        { "Alt-drag: move this button.", 0.6, 0.6, 0.6 },
      })
    else
      GameTooltip:SetOwner(self, "ANCHOR_LEFT")
      GameTooltip:SetText("Destroy button")
      GameTooltip:AddLine(DROP_HINT, 1, 1, 1, true)
      if target then
        GameTooltip:AddLine("Click: choose a stack to destroy.", 1, 1, 1, true)
      end
      GameTooltip:AddLine("Right-click: settings.", 0.6, 0.6, 0.6)
      GameTooltip:AddLine("Alt-drag: move this button.", 0.6, 0.6, 0.6)
      GameTooltip:Show()
    end
  end)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)

  Helper.MakeMovable(button, "destroy", true, "BOTTOMRIGHT", "BOTTOMRIGHT", -250, 130)

  fan = CreateFrame("Frame", nil, UIParent)
  fan:Hide()
  fan:SetScript("OnUpdate", FanUpdate)
end

Helper.Feature(function()
  settings = Helper.db.destroy
  if not Helper.PickupItem or type(DeleteCursorItem) ~= "function" then
    return -- this client cannot destroy items from an addon
  end
  BuildButton()

  -- Bag scans only when something can have changed what is offered. (Before 1.30 the quest log, every item
  -- lock, every cursor change and every item the game loaded rescanned all bags: hundreds of timers a minute.)
  local unpricedTries, wasDragging = 0, false
  Helper.On("BAG_UPDATE_DELAYED", function()
    unpricedTries = 0
    CheckDeletion()
    RefreshSoon()
  end)
  Helper.On("CURSOR_CHANGED", function()
    CheckDeletion()
    -- (holding a bag item shows the drop target; putting it down hides it again)
    local dragging = settings.enabled and Helper.CursorBagItem() ~= nil
    if dragging or wasDragging then
      RefreshSoon()
    end
    wasDragging = dragging
  end)
  Helper.On("PLAYER_ENTERING_WORLD", RefreshSoon)
  Helper.On("GET_ITEM_INFO_RECEIVED", function()
    -- a value the game had not loaded; an item that never loads stops asking after a while
    if Destroy.unpriced and unpricedTries < 20 then
      unpricedTries = unpricedTries + 1
      RefreshSoon()
    end
  end)
  Helper.On("ITEM_LOCK_CHANGED", function()
    if button and button:IsShown() then RefreshSoon() end
  end)
  RefreshSoon()

  local function Switch(key, argument)
    if argument == "on" then
      settings[key] = true
    elseif argument == "off" then
      settings[key] = false
    else
      settings[key] = not settings[key]
    end
    return settings[key]
  end

  Helper.commands.destroy = function(rest)
    local word, argument = rest:match("^(%S*)%s*(.-)$")
    if word == "always" then
      settings.mode = "always"
      Helper.Print("The destroy button shows whenever there is something to destroy.")
    elseif word == "full" or word == "slots" then
      settings.mode = "full"
      local n = tonumber(argument)
      if n then
        settings.freeSlots = math.max(0, math.floor(n))
      end
      Helper.Print(("The destroy button shows when %d or fewer bag slots are free."):format(settings.freeSlots))
    elseif word == "click" then
      if argument == "destroy" or argument == "fan" then
        settings.click = argument
      end
      if settings.click == "destroy" then
        Destroy.CloseFan()
        Helper.Print("Clicking the button destroys the cheapest item at once.")
      else
        Helper.Print("Clicking the button fans out the choices, cheapest first.")
      end
    elseif word == "show" then
      local n = tonumber(argument)
      if n then
        settings.fanSize = math.max(3, math.min(12, math.floor(n)))
      end
      Helper.Print(("The fan shows up to %d items."):format(settings.fanSize))
    elseif word == "food" then
      Helper.Print(Switch("mageFood", argument)
        and "Conjured mage food is offered too, weakest first."
        or "Conjured mage food is left alone.")
    elseif word == "water" then
      Helper.Print(Switch("mageWater", argument)
        and "Conjured mage water is offered too, weakest first."
        or "Conjured mage water is left alone.")
    elseif word == "keep" then
      if argument == "clear" then
        settings.keep = {}
        Helper.Print("Forgot the never-destroy list.")
      else
        Helper.Print(("%d item(s) on the never-destroy list. Right-click an item in the fan to add it; /rtw destroy keep clear forgets them."):format(Destroy.KeptCount()))
      end
    elseif word == "reset" then
      button.ResetPosition()
      Helper.Print("Destroy button moved back to its starting place.")
    else
      if not Helper.Toggle(settings, word, "The destroy button is") then
        Destroy.CloseFan()
      end
    end
    Destroy.Refresh()
  end
  Helper.help[#Helper.help + 1] = "/rtw destroy [on|off] - a button that fans out your least valuable junk to destroy (Alt-drag moves it)"
  Helper.help[#Helper.help + 1] = "/rtw destroy full [slots] | always | reset - show it when bags are nearly full (default 2 free), always, or put it back"
  Helper.help[#Helper.help + 1] = "/rtw destroy click fan|destroy | show 8 - what a click does, and how many items the fan shows"
  Helper.help[#Helper.help + 1] = "/rtw destroy food | water [on|off] | keep [clear] - conjured food/water and the never-destroy list"
end)
