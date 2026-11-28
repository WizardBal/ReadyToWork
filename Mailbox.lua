-- Zero-loss Mailbox helper:
--   * Collects gold even with full bags (Blizzard's Open All refuses at 0 free slots).
--   * Collects item attachments while honoring a configurable free-bag-slot reserve, skipping CoD,
--     GM mail, and failed/Unique items cleanly.
--   * Adds an Alts & Recent recipient dropdown beside SendMailNameEditBox.
--   * NEVER calls DeleteInboxItem, ReturnInboxItem, GetInboxText, or SendMail.

local _, Helper = ...

local Mail = {}
Helper.Mailbox = Mail

local MAX_ATTACHMENTS = 16
local STEP_DELAY = 0.15
local COMMAND_TIMEOUT = 2.5
local MAX_RECENT = 10

local settings
local open = false
local running = nil          -- "gold" | "all" | nil
local mailIndex, attachIndex = 1, MAX_ATTACHMENTS
local lastInboxCount, waitUntil = 0, 0
local failedItems, failedSlots = {}, {}
local startMoney, itemsTaken = 0, 0
local pendingTake, stoppedForSpace, disabledBlizzBtn = nil, false, false
local lastAttemptedRecipient = nil

local driver = CreateFrame("Frame")
local mailBar, altButton
local hookedSendMail, hookedFrames = false, {}

local function Plain(value)
  if issecretvalue and issecretvalue(value) then return nil end
  return value
end

local function Read(func, ...)
  if type(func) ~= "function" then return nil end
  local ok, value = pcall(func, ...)
  if ok then return Plain(value) end
end

local function FreeSlots()
  return Helper.FreeSlots and Helper.FreeSlots() or 0
end

local function Wipe(t)
  for k in pairs(t) do t[k] = nil end
end

local function HasAttachment(index, slot)
  if type(HasInboxItem) == "function" and Read(HasInboxItem, index, slot) == false then
    return false
  end
  if type(GetInboxItem) ~= "function" then
    return false
  end
  local ok, name, itemID, _, count, _, _, isCurrency = pcall(GetInboxItem, index, slot)
  if not ok then return false end
  name, itemID, count, isCurrency = Plain(name), Plain(itemID), Plain(count), Plain(isCurrency)
  if name == nil and itemID == nil then
    return false
  end
  return true, tonumber(itemID), tonumber(count) or 1, isCurrency == true
end

function Mail.Summary()
  local summary = {
    gold = 0, items = 0, stacks = 0, mails = 0,
    codSkipped = 0, gmSkipped = 0, hasCurrency = false,
  }
  local total = Read(GetInboxNumItems) or 0
  for index = 1, total do
    if type(GetInboxHeaderInfo) == "function" then
      local ok, _, _, _, _, money, cod, _, itemCount, _, _, _, _, isGM = pcall(GetInboxHeaderInfo, index)
      money, cod, itemCount, isGM = Plain(money), Plain(cod), Plain(itemCount), Plain(isGM)
      if ok then
        if isGM == true then
          summary.gmSkipped = summary.gmSkipped + 1
        elseif (tonumber(cod) or 0) > 0 then
          summary.codSkipped = summary.codSkipped + 1
        else
          local m = math.max(0, tonumber(money) or 0)
          local c = math.max(0, tonumber(itemCount) or 0)
          if m > 0 or c > 0 then
            summary.mails = summary.mails + 1
          end
          summary.gold = summary.gold + m
          if c > 0 then
            for slot = 1, MAX_ATTACHMENTS do
              local has, _, qty, isCur = HasAttachment(index, slot)
              if has then
                summary.stacks = summary.stacks + 1
                summary.items = summary.items + (qty or 1)
                if isCur then summary.hasCurrency = true end
              end
            end
          end
        end
      end
    end
  end
  return summary
end

function Mail.IsOpen()
  return open == true
end

function Mail.IsRunning()
  return running
end

local function SettlePending()
  if not pendingTake then return end
  local done = pendingTake
  pendingTake = nil
  if done.kind == "item" and not done.failed then
    local nowCount = Read(GetInboxNumItems) or 0
    local has, curID = false, nil
    if nowCount == done.inboxCount then
      has, curID = HasAttachment(done.mailIndex, done.slot)
    end
    if nowCount ~= done.inboxCount or not has or (done.itemID and curID ~= done.itemID) then
      itemsTaken = itemsTaken + (done.count or 1)
    end
  end
end

local function CurrentPlayerNameAndRealm()
  local name = Helper.PlayerFullName and Helper.PlayerFullName() or Read(UnitName, "player")
  local realm = Read(GetRealmName)
  return name, realm
end

local function FormatAltTarget(info, myRealm)
  if not info or type(info.name) ~= "string" or info.name == "" then return nil end
  if type(info.realm) == "string" and info.realm ~= "" and type(myRealm) == "string" and myRealm ~= "" and info.realm ~= myRealm then
    return info.name .. "-" .. info.realm:gsub("%s+", ""), true
  end
  return info.name, false
end

local function ColorName(name, classFile)
  local colors = _G.RAID_CLASS_COLORS
  local c = type(colors) == "table" and classFile and colors[classFile]
  if c and type(c.colorStr) == "string" then
    return "|c" .. c.colorStr .. name .. "|r"
  end
  return name
end

function Mail.Recipients()
  local myName, myRealm = CurrentPlayerNameAndRealm()
  local alts, recent = {}, {}
  local seen = {}
  if type(myName) == "string" and myName ~= "" then
    seen[myName:lower()] = true
    if type(myRealm) == "string" and myRealm ~= "" then
      seen[(myName .. "-" .. myRealm:gsub("%s+", "")):lower()] = true
    end
  end
  for _, info in ipairs(Helper.Characters and Helper.Characters.List() or {}) do
    local target, crossRealm = FormatAltTarget(info, myRealm)
    if target then
      seen[target:lower()] = true
      if info.name then seen[info.name:lower()] = true end
      local detail = {}
      if type(info.level) == "number" and info.level > 0 then detail[#detail + 1] = tostring(info.level) end
      if type(info.className) == "string" and info.className ~= "" then detail[#detail + 1] = info.className end
      if crossRealm and type(info.realm) == "string" and info.realm ~= "" then detail[#detail + 1] = info.realm end
      local label = ColorName(target, info.class)
      if #detail > 0 then
        label = label .. "  |cff999999(" .. table.concat(detail, " ") .. ")|r"
      end
      alts[#alts + 1] = { target = target, label = label }
    end
  end
  for _, name in ipairs(settings and settings.recent or {}) do
    if type(name) == "string" and name ~= "" and not seen[name:lower()] then
      seen[name:lower()] = true
      recent[#recent + 1] = name
    end
  end
  return alts, recent
end

function Mail.FillRecipient(target)
  if type(target) ~= "string" or target == "" then return false end
  local box = _G.SendMailNameEditBox
  if not box or type(box.SetText) ~= "function" then return false end
  box:SetText(target)
  if type(_G.SendMailFrame_CanSend) == "function" then
    pcall(_G.SendMailFrame_CanSend)
  end
  local subj = _G.SendMailSubjectEditBox
  if subj and type(subj.GetText) == "function" and (subj:GetText() or "") == "" and type(subj.SetFocus) == "function" then
    subj:SetFocus()
  end
  return true
end

local function RecordRecent(target)
  if not settings then return end
  local clean = type(target) == "string" and target:match("^%s*(.-)%s*$") or ""
  if clean == "" then return end
  local myName, myRealm = CurrentPlayerNameAndRealm()
  local lower = clean:lower()
  if type(myName) == "string" and lower == myName:lower() then return end
  if type(myName) == "string" and type(myRealm) == "string" and myRealm ~= "" then
    if lower == (myName .. "-" .. myRealm:gsub("%s+", "")):lower() then return end
  end
  if type(settings.recent) ~= "table" then settings.recent = {} end
  local list = settings.recent
  for i = #list, 1, -1 do
    if type(list[i]) ~= "string" or list[i]:lower() == lower then
      table.remove(list, i)
    end
  end
  table.insert(list, 1, clean)
  while #list > MAX_RECENT do
    table.remove(list)
  end
end

local function MakeBarButton(parent, name, text, style)
  local W = Helper.Widgets
  if W and W.Surface and W.Highlight and W.Font and W.Style then
    local b = CreateFrame("Button", name, parent)
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
  local b = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
  b:SetText(text)
  return b
end

local function UpdateUI()
  local enabled = settings and settings.enabled == true
  if mailBar then
    local inboxShown = not _G.InboxFrame or not _G.InboxFrame.IsShown or _G.InboxFrame:IsShown()
    local showBar = open and enabled and inboxShown
    mailBar:SetShown(showBar)
    if showBar then
      local sum = Mail.Summary()
      if running then
        mailBar.status:SetText(running == "gold" and "Collecting gold..." or "Collecting mail...")
        mailBar.allBtn:SetText(running == "all" and "Stop" or "Collect all")
        mailBar.goldBtn:SetText(running == "gold" and "Stop" or "Gold only")
        if mailBar.allBtn.SetEnabled then mailBar.allBtn:SetEnabled(running == "all") end
        if mailBar.goldBtn.SetEnabled then mailBar.goldBtn:SetEnabled(running == "gold") end
      else
        local statusParts = {}
        if sum.gold > 0 then statusParts[#statusParts + 1] = Helper.Money(sum.gold) end
        if sum.stacks > 0 then
          statusParts[#statusParts + 1] = ("%d %s"):format(sum.stacks, sum.stacks == 1 and "stack" or "stacks")
        end
        local line
        if #statusParts > 0 then
          line = "Inbox: " .. table.concat(statusParts, " · ")
        elseif sum.codSkipped > 0 or sum.gmSkipped > 0 then
          line = "Only CoD/GM mail waiting"
        else
          line = "No gold or items waiting"
        end
        if sum.codSkipped > 0 and #statusParts > 0 then
          line = line .. (" (%d CoD skipped)"):format(sum.codSkipped)
        end
        mailBar.status:SetText(line)
        mailBar.allBtn:SetText("Collect all")
        mailBar.goldBtn:SetText("Gold only")
        local canAll = sum.gold > 0 or sum.stacks > 0
        local canGold = sum.gold > 0
        if mailBar.allBtn.SetEnabled then mailBar.allBtn:SetEnabled(canAll) end
        if mailBar.goldBtn.SetEnabled then mailBar.goldBtn:SetEnabled(canGold) end
        if mailBar.allBtn.SetAlpha then mailBar.allBtn:SetAlpha(canAll and 1 or .45) end
        if mailBar.goldBtn.SetAlpha then mailBar.goldBtn:SetAlpha(canGold and 1 or .45) end
      end
      if running then
        if mailBar.allBtn.SetAlpha then mailBar.allBtn:SetAlpha(running == "all" and 1 or .45) end
        if mailBar.goldBtn.SetAlpha then mailBar.goldBtn:SetAlpha(running == "gold" and 1 or .45) end
      end
    end
  end
  if altButton then
    local sendShown = _G.SendMailFrame and _G.SendMailFrame.IsShown and _G.SendMailFrame:IsShown()
    altButton:SetShown(open and enabled and settings.altPicker ~= false and sendShown == true)
  end
end

local function OpenRecipientMenu(anchor)
  local alts, recent = Mail.Recipients()
  if _G.MenuUtil and _G.MenuUtil.CreateContextMenu then
    _G.MenuUtil.CreateContextMenu(anchor, function(_, root)
      if #alts == 0 and #recent == 0 then
        root:CreateTitle("No alts or recent recipients yet")
        return
      end
      if #alts > 0 then
        root:CreateTitle("Characters")
        for _, entry in ipairs(alts) do
          local target = entry.target
          root:CreateButton(entry.label, function() Mail.FillRecipient(target) end)
        end
      end
      if #recent > 0 then
        if #alts > 0 and root.CreateDivider then root:CreateDivider() end
        root:CreateTitle("Recent")
        for _, name in ipairs(recent) do
          local target = name
          root:CreateButton(target, function() Mail.FillRecipient(target) end)
        end
        if root.CreateDivider then root:CreateDivider() end
        root:CreateButton("Clear recent", function()
          if settings then settings.recent = {} end
        end)
      end
    end)
    return
  end
  local first = alts[1] and alts[1].target or recent[1]
  if first then Mail.FillRecipient(first) end
end

local function HookFrameVisibility(target)
  if not target or hookedFrames[target] or type(target.HookScript) ~= "function" then return end
  hookedFrames[target] = true
  pcall(target.HookScript, target, "OnShow", UpdateUI)
  pcall(target.HookScript, target, "OnHide", UpdateUI)
end

local function EnsureUI()
  if not mailBar and _G.MailFrame then
    local host = _G.InboxFrame or _G.MailFrame
    mailBar = CreateFrame("Frame", "ReadyToWorkMailBar", host)
    mailBar:SetPoint("TOPLEFT", _G.MailFrame, "BOTTOMLEFT", 2, -36)
    mailBar:SetPoint("TOPRIGHT", _G.MailFrame, "BOTTOMRIGHT", -2, -36)
    mailBar:SetHeight(34)
    local W = Helper.Widgets
    if W and W.Surface and W.Font then
      W.Shadow(mailBar, 12, .45)
      mailBar.bg, mailBar.border = W.Surface(mailBar, "md", W.colors.window, W.colors.borderStrong, "BACKGROUND", -2)
      mailBar.status = W.Font(mailBar, "small")
    else
      mailBar.status = mailBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    end
    mailBar.status:SetPoint("LEFT", 12, 0)
    mailBar.status:SetPoint("RIGHT", -180, 0)
    if mailBar.status.SetJustifyH then mailBar.status:SetJustifyH("LEFT") end
    if mailBar.status.SetWordWrap then mailBar.status:SetWordWrap(false) end

    mailBar.allBtn = MakeBarButton(mailBar, "ReadyToWorkMailCollectAllButton", "Collect all", "primary")
    mailBar.allBtn:SetSize(84, 24)
    mailBar.allBtn:SetPoint("RIGHT", -6, 0)
    mailBar.allBtn:SetScript("OnClick", function() Mail.Collect("all") end)
    mailBar.allBtn:SetScript("OnEnter", function(self)
      if not _G.GameTooltip then return end
      _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      _G.GameTooltip:SetText("Collect all mail", 1, 1, 1)
      _G.GameTooltip:AddLine("Takes all gold (even when bags are full) and item attachments until bags hit your free-slot reserve. Skips CoD and GM mail and never deletes letters.", nil, nil, nil, true)
      _G.GameTooltip:Show()
    end)
    mailBar.allBtn:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)

    mailBar.goldBtn = MakeBarButton(mailBar, "ReadyToWorkMailCollectGoldButton", "Gold only", nil)
    mailBar.goldBtn:SetSize(78, 24)
    mailBar.goldBtn:SetPoint("RIGHT", mailBar.allBtn, "LEFT", -6, 0)
    mailBar.goldBtn:SetScript("OnClick", function() Mail.Collect("gold") end)
    mailBar.goldBtn:SetScript("OnEnter", function(self)
      if not _G.GameTooltip then return end
      _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      _G.GameTooltip:SetText("Collect gold only", 1, 1, 1)
      _G.GameTooltip:AddLine("Collects gold from all non-CoD mails without taking item attachments. Works even with 0 free bag slots.", nil, nil, nil, true)
      _G.GameTooltip:Show()
    end)
    mailBar.goldBtn:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)

    HookFrameVisibility(_G.InboxFrame)
  end

  if not altButton and _G.SendMailFrame and _G.SendMailNameEditBox then
    local W = Helper.Widgets
    local restFill = { .10, .38, .28, .92 }
    local restBorder = { .24, .90, .66, .85 }
    local hoverFill = { .14, .48, .35, 1 }
    local hoverBorder = { .34, .96, .74, 1 }
    altButton = CreateFrame("Button", "ReadyToWorkMailRecipientButton", _G.SendMailFrame)
    altButton:SetSize(22, 20)
    altButton:SetPoint("LEFT", _G.SendMailNameEditBox, "RIGHT", 1, 1)
    if W and W.Surface and W.Highlight and W.Glyph then
      altButton.bg, altButton.border = W.Surface(altButton, "md", restFill, restBorder)
      W.Highlight(altButton, "md")
      altButton.glyph = W.Glyph(altButton, "icon_chevron.png", 12, { .94, 1, .97, 1 })
      altButton.glyph:SetPoint("CENTER")
    end
    altButton:SetScript("OnClick", function(self) OpenRecipientMenu(self) end)
    altButton:SetScript("OnEnter", function(self)
      if W and W.SetColor and self.bg and self.border then
        W.SetColor(self.bg, unpack(hoverFill))
        W.SetColor(self.border, unpack(hoverBorder))
      end
      if not _G.GameTooltip then return end
      _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      _G.GameTooltip:SetText("Alts & recent recipients", 1, 1, 1)
      _G.GameTooltip:AddLine("Click to pick one of your characters or a recent mail recipient.", nil, nil, nil, true)
      _G.GameTooltip:Show()
    end)
    altButton:SetScript("OnLeave", function(self)
      if W and W.SetColor and self.bg and self.border then
        W.SetColor(self.bg, unpack(restFill))
        W.SetColor(self.border, unpack(restBorder))
      end
      if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)
    HookFrameVisibility(_G.SendMailFrame)
  end
end

local function BlizzardOpenAllButton()
  local inbox = _G.InboxFrame
  local btn = type(inbox) == "table" and inbox.OpenAllMail
  if type(btn) == "table" then return btn end
  if type(_G.OpenAllMail) == "table" then return _G.OpenAllMail end
end

function Mail.Stop(cancelled)
  if not running then return end
  SettlePending()
  local finishedMode = running
  local spacePaused = stoppedForSpace
  running = nil
  pendingTake = nil
  stoppedForSpace = false
  driver:SetScript("OnUpdate", nil)
  if C_Mail and type(C_Mail.SetOpeningAll) == "function" then
    pcall(C_Mail.SetOpeningAll, false)
  end
  if disabledBlizzBtn then
    disabledBlizzBtn = false
    local blizzBtn = BlizzardOpenAllButton()
    if blizzBtn and type(blizzBtn.Enable) == "function" then
      pcall(blizzBtn.Enable, blizzBtn)
    end
  end
  local curMoney = Read(GetMoney) or startMoney
  local goldTaken = math.max(0, curMoney - startMoney)
  if settings and settings.reportChat ~= false then
    local parts = {}
    if goldTaken > 0 then parts[#parts + 1] = Helper.Money(goldTaken) end
    if itemsTaken > 0 then
      parts[#parts + 1] = ("%d %s"):format(itemsTaken, itemsTaken == 1 and "item" or "items")
    end
    local suffix = ""
    if finishedMode == "all" and spacePaused then
      local keep = settings.keepFree or 0
      suffix = keep > 0
        and (" (kept %d free bag %s — remaining items left in inbox)"):format(keep, keep == 1 and "slot" or "slots")
        or " (bags full — remaining items left in inbox)"
    end
    if #parts > 0 then
      Helper.Print("Collected " .. table.concat(parts, " and ") .. suffix .. ".")
    elseif spacePaused and not cancelled then
      Helper.Print("Not enough free bag slots to collect mail attachments.")
    end
  end
  UpdateUI()
  if Helper.RefreshSettings then Helper.RefreshSettings("Mailbox") end
end

local function Step()
  if not running or not open or not (settings and settings.enabled) then
    Mail.Stop(true)
    return
  end
  local now = Read(GetTime) or 0
  if now < waitUntil then return end
  if C_Mail and type(C_Mail.IsCommandPending) == "function" and Read(C_Mail.IsCommandPending) == true then
    if pendingTake and (now - (pendingTake.at or now)) < COMMAND_TIMEOUT then
      waitUntil = now + 0.05
      return
    elseif pendingTake then
      pendingTake.failed = true
    end
  end
  SettlePending()
  local total = Read(GetInboxNumItems) or 0
  if total ~= lastInboxCount then
    lastInboxCount = total
    mailIndex = 1
    attachIndex = MAX_ATTACHMENTS
    Wipe(failedSlots)
  end
  while mailIndex <= total do
    local ok, _, _, _, _, money, cod, _, itemCount, _, _, _, _, isGM = pcall(GetInboxHeaderInfo, mailIndex)
    money, cod, itemCount, isGM = Plain(money), Plain(cod), Plain(itemCount), Plain(isGM)
    if not ok or isGM == true or (tonumber(cod) or 0) > 0 then
      mailIndex = mailIndex + 1
      attachIndex = MAX_ATTACHMENTS
    else
      local copper = tonumber(money) or 0
      local hasMoney = copper > 0
        or (C_Mail and type(C_Mail.HasInboxMoney) == "function" and Read(C_Mail.HasInboxMoney, mailIndex) == true)
      local moneyKey = mailIndex .. ":money"
      if hasMoney and not failedSlots[moneyKey] and type(TakeInboxMoney) == "function" then
        failedSlots[moneyKey] = true
        pendingTake = { kind = "money", mailIndex = mailIndex, inboxCount = total, at = now }
        waitUntil = now + STEP_DELAY
        pcall(TakeInboxMoney, mailIndex)
        UpdateUI()
        return
      end
      if running == "all" and (tonumber(itemCount) or 0) > 0 and type(TakeInboxItem) == "function" then
        while attachIndex >= 1 do
          local slot = attachIndex
          attachIndex = attachIndex - 1
          local slotKey = mailIndex .. ":" .. slot
          if not failedSlots[slotKey] then
            local has, itemID, qty, isCur = HasAttachment(mailIndex, slot)
            if has and not (not isCur and itemID and failedItems[itemID]) then
              if isCur or FreeSlots() > (settings.keepFree or 0) then
                failedSlots[slotKey] = true
                pendingTake = {
                  kind = "item", mailIndex = mailIndex, slot = slot,
                  itemID = itemID, count = qty or 1, inboxCount = total, at = now,
                }
                waitUntil = now + STEP_DELAY
                pcall(TakeInboxItem, mailIndex, slot)
                UpdateUI()
                return
              else
                stoppedForSpace = true
                attachIndex = 0
              end
            end
          end
        end
      end
      mailIndex = mailIndex + 1
      attachIndex = MAX_ATTACHMENTS
    end
  end
  Mail.Stop(false)
end

function Mail.Collect(mode)
  mode = mode == "gold" and "gold" or "all"
  if running then
    Mail.Stop(true)
    return false
  end
  if not open or not (settings and settings.enabled) then
    return false
  end
  local sum = Mail.Summary()
  if mode == "gold" and sum.gold <= 0 then return false end
  if mode == "all" and sum.gold <= 0 and sum.stacks <= 0 then return false end
  local keep = settings.keepFree or 0
  if mode == "all" and sum.gold <= 0 and not sum.hasCurrency and FreeSlots() <= keep then
    Helper.Print(keep > 0
      and ("Free more than %d bag %s first, or lower Keep free bag slots."):format(keep, keep == 1 and "slot" or "slots")
      or "Free at least one bag slot first.")
    return false
  end
  local blizzBtn = BlizzardOpenAllButton()
  if blizzBtn and type(blizzBtn.IsEnabled) == "function" and blizzBtn:IsEnabled() and type(blizzBtn.Disable) == "function" then
    pcall(blizzBtn.Disable, blizzBtn)
    disabledBlizzBtn = true
  end
  if C_Mail and type(C_Mail.SetOpeningAll) == "function" then
    pcall(C_Mail.SetOpeningAll, true)
  end
  running = mode
  mailIndex = 1
  attachIndex = MAX_ATTACHMENTS
  lastInboxCount = Read(GetInboxNumItems) or 0
  waitUntil = 0
  Wipe(failedItems)
  Wipe(failedSlots)
  startMoney = Read(GetMoney) or 0
  itemsTaken = 0
  pendingTake = nil
  stoppedForSpace = false
  driver:SetScript("OnUpdate", function() Step() end)
  Step()
  return true
end

function Mail.Apply()
  if not settings or not settings.enabled then
    Mail.Stop(true)
  end
  UpdateUI()
end

Helper.Feature(function()
  settings = Helper.db.mailbox
  if type(settings.keepFree) ~= "number" then settings.keepFree = 0 end
  if type(settings.recent) ~= "table" then settings.recent = {} end

  if not hookedSendMail and type(_G.SendMail) == "function" and type(hooksecurefunc) == "function" then
    hookedSendMail = true
    hooksecurefunc("SendMail", function(recipient)
      local clean = Plain(recipient)
      if type(clean) == "string" and clean ~= "" then
        lastAttemptedRecipient = clean
      end
    end)
  end

  Helper.On("MAIL_SHOW", function()
    open = true
    EnsureUI()
    UpdateUI()
  end)

  Helper.On("MAIL_INBOX_UPDATE", function()
    if open then UpdateUI() end
  end)

  Helper.On("BAG_UPDATE_DELAYED", function()
    if open then UpdateUI() end
  end)

  Helper.On("MAIL_FAILED", function(itemID)
    local id = tonumber(Plain(itemID))
    if id then failedItems[id] = true end
    if pendingTake then pendingTake.failed = true end
    if not running and id == nil then lastAttemptedRecipient = nil end
  end)

  Helper.On("MAIL_OPEN_ALL_CANCELED", function()
    Mail.Stop(true)
  end)

  Helper.On("MAIL_SEND_SUCCESS", function()
    if lastAttemptedRecipient then
      RecordRecent(lastAttemptedRecipient)
      lastAttemptedRecipient = nil
      if Helper.RefreshSettings then Helper.RefreshSettings("Mailbox") end
    end
  end)

  Helper.On("MAIL_CLOSED", function()
    lastAttemptedRecipient = nil
    Mail.Stop(true)
    open = false
    UpdateUI()
  end)

  local function command(rest)
    local first, second = (rest or ""):match("^(%S*)%s*(.-)$")
    if first == "all" then
      if not open then Helper.Print("Open your mailbox first."); return end
      Mail.Collect("all")
      return
    end
    if first == "gold" then
      if not open then Helper.Print("Open your mailbox first."); return end
      Mail.Collect("gold")
      return
    end
    if first == "free" then
      local n = tonumber(second)
      if n and n >= 0 and n <= 10 then
        settings.keepFree = math.floor(n)
        Helper.Print("Mailbox will keep at least " .. settings.keepFree .. " free bag slot(s).")
      else
        Helper.Print("Usage: /rtw mail free <0-10>")
      end
      return
    end
    if first == "alts" then
      if second == "on" then settings.altPicker = true
      elseif second == "off" then settings.altPicker = false
      else settings.altPicker = settings.altPicker == false end
      UpdateUI()
      Helper.Print("Send Mail alt & recent picker " .. (settings.altPicker ~= false and "on." or "off."))
      return
    end
    if first == "chat" then
      if second == "on" then settings.reportChat = true
      elseif second == "off" then settings.reportChat = false
      else settings.reportChat = settings.reportChat == false end
      Helper.Print("Mailbox chat summary " .. (settings.reportChat ~= false and "on." or "off."))
      return
    end
    if first == "clearrecent" then
      settings.recent = {}
      Helper.Print("Cleared recent mail recipients.")
      return
    end
    Helper.Toggle(settings, first, "Mailbox")
    Mail.Apply()
  end

  Helper.commands.mail = command
  Helper.commands.mailbox = command
  Helper.help[#Helper.help + 1] =
    "/rtw mail [on|off|all|gold|free <0-10>|alts|chat] - safe mail gold/item collector and Send Mail alt picker"
end)
