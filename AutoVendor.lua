-- Vendors: when a vendor opens, repair (if it can), then sell grey items through the merchant's bulk action
-- and the white items you chose one stack at a time. Hold Shift while opening the vendor to skip both once.
-- The vendor window gets a Sell items button (hover it to see what will be sold), a drop target for
-- choosing white items, and a Buy back button that takes back what ReadyToWork sold this visit.
--
-- Every gold figure comes from the game: a sale counts once the items have left your bags (and, one stack at
-- a time, once the vendor's buyback list shows them), a repair once the game's repair cost has dropped, a
-- buyback once its row has left the buyback list.

local ADDON, Helper = ...

local Vendor = {}
Helper.Vendor = Vendor

local TICK = 0.2
local PER_TICK = 6
local START_DELAY = 0.1
local SETTLE = 3
local MAX_SECONDS = 90
local CLICK_MAX = 40
local LOG_SIZE = 30
local CONFIRM_DELAY = 1        -- seconds before a repair or buyback is checked once more
local PREVIEW_LINES = 12

local open = false
local generation, startup = 0, 0
local session, vendorBar, button, buybackButton, dropButton
local addedThisVisit = {}
local uncertainStacks, uncertainLinks = {}, {}
local lastSale              -- what ReadyToWork sold at this vendor visit: { visit, rows = { [key] = row }, order }
local repairCheck, repairBlocked
local buybackCheck

-- A remembered item is kept by its plain name (an item link can change format between game versions).
local function PlainName(label)
  if type(label) ~= "string" then return label end
  return label:match("|h%[(.-)%]|h") or label
end
Vendor.PlainName = PlainName

-- A remembered item for display: its item link when the game has the item loaded, else its saved name.
function Vendor.Label(id)
  local name = Helper.db.vendor.included[id]
  local getInfo = C_Item and C_Item.GetItemInfo
  if getInfo then
    local ok, _, link = pcall(getInfo, id)
    if ok and type(link) == "string" and not (issecretvalue and issecretvalue(link)) then return link end
  end
  return type(name) == "string" and name or ("Item #" .. id)
end

-- Daily summary counters so Status & Home cards stay accurate without keeping a log UI.
local function TodayBucket(settings)
  local day = type(date) == "function" and date("%Y-%m-%d") or "today"
  if type(settings.today) ~= "table" or settings.today.day ~= day then
    settings.today = { day = day, items = 0, copper = 0, repaired = 0 }
  end
  return settings.today
end

function Vendor.TodayTotals(settings)
  if type(settings) ~= "table" then return 0, 0, 0 end
  local today = type(date) == "function" and date("%Y-%m-%d") or "today"
  if type(settings.today) == "table" and settings.today.day == today then
    return settings.today.items or 0, settings.today.copper or 0, settings.today.repaired or 0
  end
  local items, copper, repaired = 0, 0, 0
  for _, entry in ipairs(settings.log or {}) do
    if type(entry) == "table" and entry.t and type(date) == "function" and date("%Y-%m-%d", entry.t) == today then
      if entry.items then items, copper = items + entry.items, copper + (entry.copper or 0) end
      if entry.repair then repaired = repaired + entry.repair end
    end
  end
  return items, copper, repaired
end

-- History entries are plain data, formatted when shown: { t = time, items, copper, manual, note }, or
-- { t, note } for a line about something else.
local function Log(entry)
  local settings = Helper.db and Helper.db.vendor
  if not settings or settings.recordLog==false then return end
  if type(settings.log) ~= "table" then
    settings.log = {}
  end
  if type(entry) ~= "table" then entry = { note = tostring(entry) } end
  entry.t = type(time) == "function" and time() or nil
  settings.log[#settings.log + 1] = entry
  while #settings.log > LOG_SIZE do
    table.remove(settings.log, 1)
  end
end

-- One history entry as a line of text.
function Vendor.LogLine(entry)
  if type(entry) ~= "table" then
    return tostring(entry)
  end
  local stamp = entry.t and type(date) == "function" and date("%m-%d %H:%M:%S", entry.t) or ""
  if entry.repair then
    return ("%s Repaired  ·  %s%s"):format(stamp, Helper.Money(entry.repair), entry.guild and "  ·  guild funds" or "")
  end
  if entry.boughtBack then
    return ("%s Bought back  ·  %d item%s  ·  %s"):format(stamp, entry.boughtBack, entry.boughtBack == 1 and "" or "s",
      Helper.Money(entry.copper or 0))
  end
  if entry.items then
    local text = ("%s sale  ·  %d item%s  ·  %s"):format(entry.manual and "Manual" or "Automatic",
      entry.items, entry.items == 1 and "" or "s", Helper.Money(entry.copper or 0))
    if entry.note then text = text .. "  ·  " .. entry.note end
    return stamp .. " " .. text
  end
  return stamp .. " " .. tostring(entry.note or "")
end

-- A pending item price is requested by SellPrice and may resolve before
-- the merchant batch runs again.
local function saleableWhite(info, bag, slot)
  if not info or info.quality ~= 1 or info.hasNoValue or not info.itemID then return false end
  local quest = C_Container.GetContainerItemQuestInfo and C_Container.GetContainerItemQuestInfo(bag, slot)
  return type(quest) == "table" and quest.isQuestItem == false and quest.questID == nil
end

local function eligible(info, bag, slot)
  if not info or info.hasNoValue or info.isLocked then return false end
  if info.quality == Helper.POOR then return true end
  return info.itemID and Helper.db.vendor.included[info.itemID] and saleableWhite(info, bag, slot)
end

-- White items you could choose: those in your bags (as links) and those already chosen.
function Vendor.WhiteItems()
  local choices={}
  for id in pairs(Helper.db.vendor.included) do choices[id]=Vendor.Label(id) end
  for _,bag in ipairs(Helper.Bags()) do
    for slot=1,C_Container.GetContainerNumSlots(bag) or 0 do
      local info=C_Container.GetContainerItemInfo(bag,slot)
      if saleableWhite(info, bag, slot) and info.hyperlink then choices[info.itemID] = info.hyperlink end
    end
  end
  return choices
end
function Vendor.SetIncluded(id, label)
  local included = Helper.db.vendor.included
  if label and not included[id] and open then addedThisVisit[id] = true end
  included[id] = label and (PlainName(label) or ("Item #" .. id)) or nil
  Vendor.UpdateButton()
  if Helper.RefreshSettings then Helper.RefreshSettings("Vendors") end
end

function Vendor.HoldRestoredItems(previous)
  if open then
    for id in pairs(Helper.db.vendor.included) do if not previous[id] then addedThisVisit[id]=true end end
  end
end
function Vendor.DropBagItem()
  local id, _, bag, slot = Helper.CursorBagItem()
  if not id then return false end
  -- A full stack can leave its slot empty while held. Return it first, then
  -- check the original slot before remembering its ID.
  ClearCursor()
  local waitedForPrice = false
  local function confirm(retried)
    local info = C_Container.GetContainerItemInfo(bag, slot)
    if not info or info.itemID ~= id then
      if not retried then C_Timer.After(0, function() confirm(true) end)
      else Helper.Print("The item could not be verified in its original bag slot.") end
      return
    end
    local white = saleableWhite(info, bag, slot) and info.hyperlink
    local price = white and Helper.SellPrice(info.hyperlink)
    if white and price == nil and not waitedForPrice and Item and Item.CreateFromItemID then
      waitedForPrice = true
      Item:CreateFromItemID(id):ContinueOnItemLoad(function() confirm(true) end)
      return
    end
    if not white or (price or 0) <= 0 then
      Helper.Print("Choose a white item with a vendor price that is clear of quest requirements.")
      return
    end
    local included = Helper.db.vendor.included
    if included[id] then
      Helper.Print(info.hyperlink .. " is already on your vendor list.")
    else
      local function add()
        Vendor.SetIncluded(id,info.hyperlink)
        Helper.Print(info.hyperlink .. " added to your vendor list.")
      end
      if Helper.ApplyEditorAction then Helper.ApplyEditorAction("vendor","Add vendor item",add) else add() end
    end
  end
  confirm(false)
  return true
end

function Vendor.FindJunk(skipNew)
  local junk, loading = {}, false
  for _, bag in ipairs(Helper.Bags()) do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if eligible(info, bag, slot) and not (skipNew and addedThisVisit[info.itemID]) then
        local key = Helper.ItemLinkKey(info.hyperlink)
        if key then
          local price = Helper.SellPrice(info.hyperlink)
          if price and price > 0 then
            junk[#junk + 1] = {
              bag = bag, slot = slot, itemID = info.itemID, count = info.stackCount, link = info.hyperlink,
              price = price, key = key, grey = info.quality == Helper.POOR, guid = Helper.BagItemGUID(bag, slot),
            }
          elseif price == nil then
            loading = true
          end
        end
      end
    end
  end
  return junk, loading
end

-- What a sale would sell now, one row per item, most valuable first: { key, link, count, value, grey }, the total
-- value, the number of items, and whether some prices are still loading.
function Vendor.Preview()
  local junk, loading = Vendor.FindJunk()
  local rows, byKey, total, count = {}, {}, 0, 0
  for _, item in ipairs(junk) do
    local row = byKey[item.key]
    if not row then
      row = { key = item.key, link = item.link, count = 0, value = 0, grey = item.grey }
      byKey[item.key], rows[#rows + 1] = row, row
    end
    row.count, row.value = row.count + item.count, row.value + item.count * item.price
    total, count = total + item.count * item.price, count + item.count
  end
  table.sort(rows, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    return a.key < b.key
  end)
  return rows, total, count, loading
end

-- Remembers what ReadyToWork sold at this visit, for Buy back.
local function NoteSold(key, link, count, price)
  if not key or count <= 0 then return end
  if not lastSale or lastSale.visit ~= generation then lastSale = { visit = generation, rows = {}, order = {} } end
  local row = lastSale.rows[key]
  if not row then
    row = { key = key, link = link, count = 0, price = price }
    lastSale.rows[key] = row
    lastSale.order[#lastSale.order + 1] = key
  end
  row.count = row.count + count
end

-- Buyback is small, and looking for a new matching row avoids depending on
-- whether this client appends or prepends it.
local function BuybackCounts(item)
  local counts = {}
  for index = 1, GetNumBuybackItems() do
    if Helper.ItemLinkKey(GetBuybackItemLink(index)) == item.key then
      local _, _, cost, quantity = GetBuybackItemInfo(index)
      if type(quantity) == "number" and quantity > 0 and cost == quantity * item.price then
        counts[quantity] = (counts[quantity] or 0) + 1
      end
    end
  end
  return counts
end

-- Repairs ---------------------------------------------------------------------------------------------------

-- Who pays for a repair of `cost`: "guild" (when chosen and the guild bank lets you withdraw enough), "self",
-- or nil when neither can.
local function RepairFunds(cost)
  local settings = Helper.db.vendor
  if settings.repairGuild and type(CanGuildBankRepair) == "function" and CanGuildBankRepair() then
    local amount = type(GetGuildBankWithdrawMoney) == "function" and GetGuildBankWithdrawMoney() or 0
    local bank = type(GetGuildBankMoney) == "function" and GetGuildBankMoney() or 0
    -- (-1: a guild leader, who may take the whole bank)
    if amount == -1 then amount = bank else amount = math.min(amount or 0, bank or 0) end
    if amount >= cost then return "guild" end
  end
  if GetMoney() >= cost then return "self" end
end

-- What still needs repairing here: the game's cost, or 0. nil when this vendor can't repair.
local function RepairCost()
  if type(CanMerchantRepair) ~= "function" or type(GetRepairAllCost) ~= "function" or not CanMerchantRepair() then return nil end
  local cost, canRepair = GetRepairAllCost()
  return canRepair and type(cost) == "number" and cost or 0
end

-- A repair counts once the game's repair cost has dropped: the drop is what was paid.
local function ConfirmRepair(final)
  local check = repairCheck
  if not check or check.visit ~= generation then return end
  local left = RepairCost() or check.cost
  if left >= check.cost then
    if final then
      repairCheck = nil
      Log({ note = "repair not confirmed" })
      Helper.Print("The repair couldn't be confirmed: check your gear's durability.")
    end
    return
  end
  repairCheck = nil
  local settings = Helper.db.vendor
  local spent = check.cost - left
  local bucket = TodayBucket(settings)
  bucket.repaired = (bucket.repaired or 0) + spent
  if check.guild then
    settings.repairGuildSpent = (settings.repairGuildSpent or 0) + spent
  else
    settings.repairSpent = (settings.repairSpent or 0) + spent
  end
  Log({ repair = spent, guild = check.guild or nil })
  if settings.reportChat ~= false and settings.reportRepairs ~= false then
    local first = not settings.repairedOnce
    settings.repairedOnce = true
    Helper.Print(("Repaired %s for %s%s.%s"):format(left > 0 and "some items" or "all items", Helper.Money(spent),
      check.guild and " from guild funds" or "", first and " (/rtw vendor repair off stops automatic repairs.)" or ""))
  end
  if Helper.RefreshSettings then Helper.RefreshSettings("Vendors") end
end

-- Repairs everything at the open vendor. `byClick`: asked for, so every outcome is said.
function Vendor.Repair(byClick)
  if not open then
    if byClick then Helper.Print("Open a vendor first.") end
    return false
  end
  local cost = RepairCost()
  if not cost then
    if byClick then Helper.Print("This vendor can't repair.") end
    return false
  end
  if cost <= 0 then
    if byClick then Helper.Print("Nothing needs repairing.") end
    return false
  end
  if repairBlocked and not byClick then return false end
  local funds = RepairFunds(cost)
  if not funds then
    Helper.Print(("Repairs cost %s, more than you have, so nothing was repaired."):format(Helper.Money(cost)))
    return false
  end
  repairCheck = { cost = cost, guild = funds == "guild", visit = generation }
  local ok = pcall(RepairAllItems, funds == "guild" or nil)
  if not ok then
    repairCheck = nil
    Helper.Print("The game didn't let ReadyToWork repair. Use the vendor's repair button.")
    return false
  end
  ConfirmRepair(false)
  if repairCheck then C_Timer.After(CONFIRM_DELAY, function() ConfirmRepair(true) end) end
  return true
end

-- Buying back -----------------------------------------------------------------------------------------------

-- The buyback rows that hold what ReadyToWork sold at this visit: { index, key, link, quantity, cost }.
function Vendor.BuybackRows()
  local rows = {}
  if not open or not lastSale or lastSale.visit ~= generation or type(GetNumBuybackItems) ~= "function" then return rows end
  local remaining = {}
  for key, row in pairs(lastSale.rows) do remaining[key] = row.count end
  for index = GetNumBuybackItems(), 1, -1 do
    local link = GetBuybackItemLink(index)
    local key = Helper.ItemLinkKey(link)
    local _, _, cost, quantity = GetBuybackItemInfo(index)
    local want = key and remaining[key]
    if want and type(quantity) == "number" and quantity > 0 and quantity <= want and type(cost) == "number" then
      remaining[key] = want - quantity
      rows[#rows + 1] = { index = index, key = key, link = link, quantity = quantity, cost = cost }
    end
  end
  return rows
end

local function BuybackSignature(index)
  local _, _, cost, quantity = GetBuybackItemInfo(index)
  return (Helper.ItemLinkKey(GetBuybackItemLink(index)) or "?") .. "|" .. tostring(quantity) .. "|" .. tostring(cost)
end

-- A buyback counts once its row has left the vendor's buyback list.
local function ConfirmBuyback()
  local check = buybackCheck
  if not check then return end
  buybackCheck = nil
  local still = {}
  for index = 1, GetNumBuybackItems() do
    local signature = BuybackSignature(index)
    still[signature] = (still[signature] or 0) + 1
  end
  local items, copper = 0, 0
  for _, row in ipairs(check.rows) do
    local signature = row.key .. "|" .. tostring(row.quantity) .. "|" .. tostring(row.cost)
    if (still[signature] or 0) > 0 then
      still[signature] = still[signature] - 1
    else
      items, copper = items + row.quantity, copper + row.cost
      local sold = lastSale and lastSale.rows[row.key]
      if sold then sold.count = math.max(0, sold.count - row.quantity) end
    end
  end
  local settings = Helper.db.vendor
  if items > 0 then
    settings.lifetime = math.max(0, settings.lifetime - copper)
    Log({ boughtBack = items, copper = copper })
    Helper.Print(("Bought back %d item%s for %s."):format(items, items == 1 and "" or "s", Helper.Money(copper)))
  else
    Helper.Print("The game didn't give anything back. The vendor's Buyback tab still has it.")
  end
  Vendor.UpdateButton()
  if Helper.RefreshSettings then Helper.RefreshSettings("Vendors") end
end

-- Buys back everything ReadyToWork sold at this visit (only rows that match what it sold).
function Vendor.BuyBack()
  if not open then Helper.Print("Open a vendor first."); return false end
  if session then Helper.Print("Wait for the sale to finish."); return false end
  local rows = Vendor.BuybackRows()
  if #rows == 0 then Helper.Print("Nothing ReadyToWork sold at this visit is on the buyback list."); return false end
  local total = 0
  for _, row in ipairs(rows) do total = total + row.cost end
  if GetMoney() < total then
    Helper.Print(("Buying it all back costs %s, more than you have."):format(Helper.Money(total)))
    return false
  end
  buybackCheck = { rows = rows }
  -- (from the highest index down, so each buyback leaves the lower indexes where they were)
  for _, row in ipairs(rows) do
    if not pcall(BuybackItem, row.index) then break end
  end
  C_Timer.After(CONFIRM_DELAY, ConfirmBuyback)
  return true
end

local function LayoutButtons()
  if not vendorBar then return end
  local showSell = button and button:IsShown()
  local showBuyback = buybackButton and buybackButton:IsShown()
  local anchor = vendorBar
  local anchorPoint = "LEFT"
  if showSell then
    button:ClearAllPoints()
    button:SetSize(showBuyback and 98 or 116, 26)
    button:SetPoint("LEFT", anchor, anchorPoint, 6, 0)
    anchor, anchorPoint = button, "RIGHT"
  end
  if showBuyback then
    buybackButton:ClearAllPoints()
    buybackButton:SetSize(showSell and 94 or 112, 26)
    buybackButton:SetPoint("LEFT", anchor, anchorPoint, 6, 0)
    anchor, anchorPoint = buybackButton, "RIGHT"
  end
  if dropButton then
    dropButton:ClearAllPoints()
    dropButton:SetHeight(26)
    dropButton:SetPoint("LEFT", anchor, anchorPoint, 6, 0)
    dropButton:SetPoint("RIGHT", vendorBar, "RIGHT", -6, 0)
    if showSell and showBuyback then
      dropButton:SetText("+ Auto-vendor")
    elseif showSell or showBuyback then
      dropButton:SetText("Drop to auto-vendor")
    else
      dropButton:SetText("Drop white item to auto-vendor")
    end
  end
end

-- The vendor window's own buttons. Sell items shows whenever a vendor is open, there are items to sell and
-- nothing is selling them: after Shift, with the feature off, or when the game refused. Buy back shows after
-- ReadyToWork sold something at this visit that is still on the buyback list.
function Vendor.UpdateButton()
  if not button then
    return
  end
  local count = open and not session and #Vendor.FindJunk() or 0
  if count > 0 then
    button:SetText(("Sell items (%d)"):format(count))
    button:Show()
  else
    button:Hide()
  end
  if buybackButton then
    local rows = open and not session and Vendor.BuybackRows() or {}
    buybackButton:SetShown(#rows > 0)
  end
  LayoutButtons()
end

-- The Sell items tooltip: what a click would sell, most valuable first.
local function ShowPreview(owner)
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:SetText("Sell items")
  local rows, total, count, loading = Vendor.Preview()
  for index, row in ipairs(rows) do
    if index > PREVIEW_LINES then
      GameTooltip:AddLine(("and %d more"):format(#rows - PREVIEW_LINES), .8, .8, .8)
      break
    end
    GameTooltip:AddDoubleLine(("%s x%d"):format(row.link or row.key, row.count), Helper.Money(row.value), 1, 1, 1, 1, 1, 1)
  end
  if count > 0 then
    GameTooltip:AddDoubleLine(("%d item%s"):format(count, count == 1 and "" or "s"), Helper.Money(total), .5, .9, .6, .5, .9, .6)
  end
  if loading then GameTooltip:AddLine("Some prices are still loading.", .8, .8, .8) end
  GameTooltip:AddLine("Paid grey items, and white items you chose. Hold Shift while opening a vendor to skip the automatic sale.", .6, .6, .6, true)
  GameTooltip:Show()
end
Vendor.ShowPreview = ShowPreview

local function MakeMerchantButton(name, text, style)
  local W = Helper.Widgets
  if W then
    local b = CreateFrame("Button", name, vendorBar)
    b.bg, b.border = W.Surface(b, "md", W.colors.surface, W.colors.border)
    W.Highlight(b, "md")
    b.label = W.Font(b, "small")
    b.label:SetPoint("CENTER")
    b.label:SetJustifyH("CENTER")
    b.label:SetText(text)
    W.Style(b, style)
    b.SetText = function(self, label) self.label:SetText(label) end
    b.GetText = function(self) return self.label:GetText() end
    return b
  end
  local b = CreateFrame("Button", name, vendorBar, "UIPanelButtonTemplate")
  b:SetText(text)
  return b
end

local function BuildButton()
  if button or not MerchantFrame then
    return
  end
  local W = Helper.Widgets
  vendorBar = CreateFrame("Frame", "ReadyToWorkVendorBar", MerchantFrame)
  vendorBar:SetPoint("TOPLEFT", MerchantFrame, "BOTTOMLEFT", 2, -36)
  vendorBar:SetPoint("TOPRIGHT", MerchantFrame, "BOTTOMRIGHT", -2, -36)
  vendorBar:SetHeight(36)
  if W then
    W.Shadow(vendorBar, 12, .45)
    W.Surface(vendorBar, "md", W.colors.window, W.colors.borderStrong, "BACKGROUND", -2)
  end

  button = MakeMerchantButton("ReadyToWorkSellGreysButton", "Sell items", "primary")
  button:SetScript("OnClick", function()
    Vendor.SellNow()
  end)
  button:SetScript("OnEnter", ShowPreview)
  button:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
  button:Hide()

  buybackButton = MakeMerchantButton("ReadyToWorkBuybackButton", "Buy back sale", nil)
  buybackButton:SetScript("OnClick", function() Vendor.BuyBack() end)
  buybackButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Buy back sale")
    local total = 0
    for _, row in ipairs(Vendor.BuybackRows()) do
      GameTooltip:AddDoubleLine(("%s x%d"):format(row.link or row.key, row.quantity), Helper.Money(row.cost), 1, 1, 1, 1, 1, 1)
      total = total + row.cost
    end
    GameTooltip:AddDoubleLine("Costs", Helper.Money(total), .5, .9, .6, .5, .9, .6)
    GameTooltip:AddLine("Buys back what ReadyToWork sold at this visit, for what the vendor paid.", .6, .6, .6, true)
    GameTooltip:Show()
  end)
  buybackButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
  buybackButton:Hide()

  dropButton = MakeMerchantButton("ReadyToWorkVendorDrop", "Drop white item to auto-vendor", nil)
  if W then
    W.SetColor(dropButton.bg, unpack(W.colors.input))
    W.SetColor(dropButton.border, unpack(W.colors.accentBorder))
    dropButton.label:SetTextColor(unpack(W.colors.text))
    dropButton.icon = W.Icon(dropButton, "Interface\\Icons\\INV_Misc_Bag_10", 16)
    dropButton.icon:SetPoint("LEFT", 8, 0)
    dropButton.label:ClearAllPoints()
    dropButton.label:SetPoint("LEFT", 28, 0)
    dropButton.label:SetPoint("RIGHT", -8, 0)
    if dropButton.label.SetWordWrap then dropButton.label:SetWordWrap(false) end
  end
  dropButton:SetScript("OnReceiveDrag", Vendor.DropBagItem)
  dropButton:SetScript("OnClick", function()
    if GetCursorInfo() == "item" then Vendor.DropBagItem() end
  end)
  dropButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Add to auto-vendor")
    GameTooltip:AddLine("Drop a white item from your bags to remember it for future visits.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  dropButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

  LayoutButtons()
end

local function Reconcile()
  local attempt = session and session.pending
  if not attempt or attempt.issuing or not open or attempt.generation ~= generation then return end
  local item = attempt.item
  local remaining, sameStack = Helper.CountBagItem(item.itemID, item.guid)
  local removed = attempt.bagCount - remaining
  if removed <= 0 or removed > item.count or (item.guid and item.count - sameStack ~= removed) then return end
  if not item.guid then
    local slot = C_Container.GetContainerItemInfo(item.bag, item.slot)
    local atSlot = slot and Helper.ItemLinkKey(slot.hyperlink) == item.key and slot.stackCount or 0
    if atSlot ~= item.count - removed then return end
  end
  local after = BuybackCounts(item)
  if (after[removed] or 0) <= (attempt.buyback[removed] or 0) and
      not (attempt.full and GetMoney()-attempt.money == removed*item.price) then return end
  session.items = session.items + removed
  session.value = session.value + item.price * removed
  session.pending = nil
  NoteSold(item.key, item.link, removed, item.price)
end

local function bagCounts()
  local counts = {}
  for _, bag in ipairs(Helper.Bags()) do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID then counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1) end
    end
  end
  return counts
end

local function bulkProgress()
  local batch = session and session.bulk
  if not batch then return end
  local removed, value = 0, 0
  local counts = bagCounts()
  for id,item in pairs(batch.items) do
    local count = math.min(item.count, math.max(0, item.before - (counts[id] or 0)))
    removed, value = removed+count, value+count*item.price
    if count > (item.noted or 0) then
      NoteSold(item.key, item.link, count - (item.noted or 0), item.price)
      item.noted = count
    end
  end
  -- (the greys leaving your bags while the vendor is open is the sale: comparing money too broke as soon as
  -- you bought or repaired in the same seconds, and automatic selling then stopped for the session)
  if value > batch.credited then
    session.value = session.value + value-batch.credited
    session.items = session.items + removed-batch.counted
    batch.credited,batch.counted=value,removed
  end
  if removed == batch.total and batch.counted == removed then session.bulk=nil end
end
local function nativeSale(junk)
  if not (C_MerchantFrame and C_MerchantFrame.SellAllJunkItems and C_MerchantFrame.IsSellAllJunkEnabled
      and C_MerchantFrame.IsSellAllJunkEnabled()) or GetCursorInfo() then return false end
  local batch={items={},money=GetMoney(),at=GetTime(),total=0,credited=0,counted=0}
  local counts = bagCounts()
  for _,item in ipairs(junk) do
    if item.grey then
      local row=batch.items[item.itemID] or {before=counts[item.itemID] or 0,price=item.price,count=0,key=item.key,link=item.link}
      row.count=row.count+item.count
      batch.items[item.itemID]=row
      batch.total=batch.total+item.count
    end
  end
  if batch.total==0 then return false end
  session.bulk=batch
  local ok=pcall(C_MerchantFrame.SellAllJunkItems)
  if not ok then batch.blocked = true end
  return true
end
local function Finish(reason)
  local done = session
  if not done then return end
  bulkProgress()
  Reconcile()
  session = nil
  done.ticker:Cancel()
  local pending = done.pending
  if pending and not pending.blocked then
    local item = pending.item
    if item.guid then
      uncertainStacks[item.guid] = true
      uncertainLinks[item.key] = uncertainLinks[item.key] or "known stack"
    else
      uncertainLinks[item.key] = "unknown stack"
    end
  end

  if done.items>0 or reason~="done" then
    Log({ items = done.items, copper = done.value, manual = done.byClick or nil,
      note = reason ~= "done" and reason or nil })
  end
  if done.items > 0 then
    local vdb = Helper.db.vendor
    local bucket = TodayBucket(vdb)
    bucket.items = (bucket.items or 0) + done.items
    bucket.copper = (bucket.copper or 0) + done.value
    vdb.lifetime = vdb.lifetime + done.value
    local reportSales = vdb.reportChat ~= nil and vdb.reportChat == true or (vdb.reportChat == nil and vdb.reportSales == true)
    if reportSales then
      Helper.Print(("Sold %d item%s for %s."):format(done.items, done.items == 1 and "" or "s", Helper.Money(done.value)))
    end
  end
  if pending then
    if pending.blocked and not done.byClick then
      Vendor.clickOnly = true
      Helper.Print("The game blocked automatic selling. Use the Sell items button under the vendor window.")
    else
      Helper.Print("Could not confirm the last item sale. Check your bags or the vendor's buyback list.")
    end
  end
  Vendor.UpdateButton()
  if Helper.RefreshSettings then Helper.RefreshSettings("Vendors") end
end

local function MaySubmit()
  return session and open and session.generation == generation and not session.cancelled
    and (session.byClick or Helper.db.vendor.enabled)
end

local function Hand(item, now)
  if not MaySubmit() or session.pending or GetCursorInfo() ~= nil then return false end
  local info = C_Container.GetContainerItemInfo(item.bag, item.slot)
  if not eligible(info,item.bag,item.slot)
      or info.itemID ~= item.itemID or info.stackCount ~= item.count
      or Helper.ItemLinkKey(info.hyperlink) ~= item.key
      or (item.guid and Helper.BagItemGUID(item.bag, item.slot) ~= item.guid) then return false end

  local attempt = {
    item = item, at = now, generation = generation, issuing = true,
    bagCount = Helper.CountBagItem(item.itemID), buyback = BuybackCounts(item), money = GetMoney(), full = GetNumBuybackItems() >= (BUYBACK_ITEMS_PER_PAGE or 12),
  }
  if not MaySubmit() then return false end
  session.pending = attempt
  local ok = pcall(Helper.UseItem, item.bag, item.slot)
  attempt.issuing = false
  attempt.blocked = attempt.blocked or not ok
  Reconcile()
  return true
end

local function Step()
  if not session then return end
  Reconcile()
  local now = GetTime()
  if session.bulk then
    bulkProgress()
    if session.bulk then
      if not session.bulk.blocked and now-session.bulk.at < SETTLE then return end
      if session.bulk.blocked then
        if not session.byClick then
          Vendor.clickOnly = true
          Helper.Print("The game blocked automatic selling. Use Sell items at the merchant.")
        end
        Finish("bulk sale blocked")
        return
      end
      -- Not all confirmed yet: what is left (greys the bulk sale missed, and the white items you chose) is
      -- sold one stack at a time below. (Before 1.30 the whites were skipped for the visit.)
      session.bulk = nil
      if session.byClick then
        Finish("done")
        return
      end
    end
  end
  local pending = session.pending
  if pending then
    if pending.blocked or now - pending.at >= SETTLE then
      Finish(pending.blocked and "blocked" or "unconfirmed")
    end
    return
  end
  if not MaySubmit() or session.byClick then
    Finish(session.cancelled and "disabled" or "done")
    return
  end
  if now - session.startedAt >= MAX_SECONDS then Finish("timeout"); return end

  local junk, loading = Vendor.FindJunk(true)
  if not session.triedBulk then
    if loading and now - session.startedAt < SETTLE then return end
    session.triedBulk = true
    if not loading and nativeSale(junk) then return end
  end
  local handed = 0
  for _, item in ipairs(junk) do
    local uncertainLink = uncertainLinks[item.key]
    local previouslySubmitted = uncertainStacks[item.guid] or uncertainLink == "unknown stack"
      or (not item.guid and uncertainLink ~= nil)
    if not previouslySubmitted and Hand(item, now) then
      handed = handed + 1
      if not session or session.pending or handed >= PER_TICK then return end
    end
  end
  if handed == 0 and not (loading and now - session.startedAt < SETTLE) then Finish("done") end
end

local function Begin(byClick)
  if not (Helper.UseItem and GetNumBuybackItems and GetBuybackItemInfo and GetBuybackItemLink and GetCursorInfo) then
    return false
  end
  session = { byClick = byClick, startedAt = GetTime(), generation = generation, items = 0, value = 0 }
  session.ticker = C_Timer.NewTicker(TICK, Step)
  Vendor.UpdateButton()
  return true
end

function Vendor.Start()
  if session or not open or not Helper.db.vendor.enabled or Vendor.clickOnly then return end
  local junk, loading = Vendor.FindJunk(true)
  if (#junk > 0 or loading) and Begin(false) then
    Step()
  else Vendor.UpdateButton() end
end

function Vendor.SellNow()
  if not open then Helper.Print("Open a vendor first."); return end
  if session then return end
  startup = startup + 1
  if GetCursorInfo and GetCursorInfo() ~= nil then Helper.Print("Empty your cursor before selling items."); return end
  local junk, loading = Vendor.FindJunk()
  if #junk == 0 then Helper.Print("No sale items with a known price are ready."); return end
  if not Begin(true) then Helper.Print("Item sales are unavailable at this vendor."); return end
  if not loading and nativeSale(junk) then
    bulkProgress()
    if session.bulk then return end
    junk = Vendor.FindJunk()
  end
  local now = GetTime()
  for index, item in ipairs(junk) do
    if index > CLICK_MAX then break end
    Hand(item, now)
    -- Additional protected requests belong to another hardware click if
    -- the game hasn't confirmed this stack by the time the call returns.
    if not session or session.pending then break end
  end
  Step()
end

Helper.Feature(function()
  local settings = Helper.db.vendor

  Helper.On("MERCHANT_SHOW", function()
    open = false
    if session then Finish("closed") end
    generation, startup = generation + 1, startup + 1
    addedThisVisit = {}
    -- (unconfirmed stacks are a single visit's question: a new vendor visit starts with a clean slate)
    uncertainStacks, uncertainLinks = {}, {}
    open = true
    repairCheck, buybackCheck = nil, nil
    BuildButton()
    local skip = IsShiftKeyDown()
    local repair = settings.repair and not skip
    if (settings.enabled and not skip and not Vendor.clickOnly) or repair then
      local request = startup
      C_Timer.After(START_DELAY, function()
        if request ~= startup then return end
        -- (repairs first: a sale is confirmed by the bags, so the two don't get in each other's way)
        if repair then Vendor.Repair(false) end
        if settings.enabled and not skip and not Vendor.clickOnly then Vendor.Start() else Vendor.UpdateButton() end
      end)
    else
      Vendor.UpdateButton()
    end
  end)
  Helper.On("UPDATE_INVENTORY_DURABILITY", function() ConfirmRepair(false) end)
  Helper.On("MERCHANT_CLOSED", function()
    startup = startup + 1
    Finish("closed")
    open = false
    Vendor.UpdateButton()
  end)
  local function Observe()
    Reconcile()
    if open and not session then Vendor.UpdateButton() end
  end
  Helper.On("BAG_UPDATE_DELAYED", Observe)
  Helper.On("MERCHANT_UPDATE", Observe)
  local refreshPending
  Helper.On("GET_ITEM_INFO_RECEIVED", function()
    if open and not refreshPending then
      refreshPending=true
      C_Timer.After(0.15,function() refreshPending=nil; if open then Observe() end end)
    end
  end)

  local function Blocked(addon, action)
    if addon == ADDON and type(action) == "string" and action:find("RepairAllItems", 1, true) then
      -- (asked again only by a click: the game wants its own repair button used)
      repairCheck, repairBlocked = nil, true
      Log("the game blocked " .. action)
      Helper.Print("The game wants its own repair button used: automatic repairs are paused until you log in again.")
    end
    if addon == ADDON and session and session.bulk and type(action) == "string" and action:find("SellAllJunkItems", 1, true) then
      session.bulk.blocked = true
    end
    if addon == ADDON and session and session.pending
        and type(action) == "string" and action:find("UseContainerItem", 1, true) then
      session.pending.blocked = true
      Log("the game blocked " .. action)
    end
  end
  Helper.On("ADDON_ACTION_FORBIDDEN", Blocked)
  Helper.On("ADDON_ACTION_BLOCKED", Blocked)

  Helper.commands.vendor = function(word)
    local sub, rest = (word or ""):match("^(%S*)%s*(.-)$")
    if word == "total" then
      Helper.Print("Lifetime vendor earnings: " .. Helper.Money(settings.lifetime) .. "; repairs: "
        .. Helper.Money(settings.repairSpent or 0) .. (settings.repairGuildSpent and settings.repairGuildSpent > 0
          and (" (and " .. Helper.Money(settings.repairGuildSpent) .. " from guild funds)") or ""))
    elseif word == "now" then
      Vendor.SellNow()
    elseif word == "log" then
      local log = type(settings.log) == "table" and settings.log or {}
      if #log == 0 then
        print("|cff79cfffReadyToWork:|r No vendor log entries yet.")
      else
        print("|cff79cfffReadyToWork:|r Recent vendor activity:")
        for _, entry in ipairs(log) do
          print("  " .. Vendor.LogLine(entry))
        end
      end
      if Helper.ShowVendorHistory then Helper.ShowVendorHistory() end
    elseif word == "buyback" then
      Vendor.BuyBack()
    elseif sub == "chat" then
      settings.reportChat = rest == "on" or (rest ~= "off" and not settings.reportChat)
      Helper.Print(settings.reportChat and "Vendor chat reports are on." or "Vendor chat reports are off.")
    elseif sub == "repair" then
      local option, state = rest:match("^(%S*)%s*(.-)$")
      if rest == "now" then
        Vendor.Repair(true)
      elseif option == "guild" then
        settings.repairGuild = state == "on" or (state ~= "off" and not settings.repairGuild)
        Helper.Print(settings.repairGuild and "Repairs use guild funds when the guild bank allows it." or "Repairs use your own gold.")
      else
        settings.repair = rest == "on" or (rest ~= "off" and not settings.repair)
        Helper.Print(settings.repair and "Repairing at vendors is on." or "Repairing at vendors is off.")
      end
    else
      if not Helper.Toggle(settings, word, "Selling grey items at vendors is") then
        startup = startup + 1
        if session and not session.byClick then
          session.cancelled = true
          Step()
        end
        Vendor.UpdateButton()
      end
    end
  end
  Helper.help[#Helper.help + 1] = "/rtw vendor [on|off|now|log|total|buyback] - sell junk and included items when a vendor opens (hold Shift to skip once)"
  Helper.help[#Helper.help + 1] = "/rtw vendor repair [on|off|now|guild on|guild off] - repair at vendors"
end)
