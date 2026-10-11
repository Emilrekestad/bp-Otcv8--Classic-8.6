-- Character Bazaar client module.
--
-- Presentation only. Every number shown here comes from the server and every
-- action is a request the server re-validates: the client never decides
-- eligibility, computes a fee, or trusts its own idea of a minimum bid or a
-- deadline. Rules live in src/character_bazaar.cpp; the wire format is
-- data/scripts/network/character_bazaar/character_bazaar.lua.
--
-- Protocol: one opcode each way with a sub-type byte, matching game_bazaar.
-- 0x5E (client -> server) / 0x2E (server -> client) have been this system's
-- since the first release; the C++ used to parse them and now Lua does.

local OPCODE_REQUEST = 0x5E
local OPCODE_SEND = 0x2E

local ACTION_RULES = 0x01
local ACTION_CREATE = 0x02
local ACTION_BROWSE = 0x03
local ACTION_DETAIL = 0x04
local ACTION_BID = 0x05
local ACTION_MINE = 0x06
local ACTION_CANCEL = 0x07
local ACTION_BUYNOW = 0x08
-- Create WITH a Buy Now price. 0x02 is left meaning "create without one" so a
-- server and client from either side of the update still agree on it.
local ACTION_CREATE_V2 = 0x09

local RESP_RULES = 0x01
local RESP_RESULT = 0x02
local RESP_BROWSE = 0x03
local RESP_DETAIL = 0x04
local RESP_MINE = 0x05

local STATUS_ACTIVE = 1
local STATUS_FINISHED = 2
local STATUS_EXPIRED = 3
local STATUS_WITHDRAWN = 4

local RELATION_NONE = 0
local RELATION_SELLER = 1
local RELATION_LEADING = 2
local RELATION_OUTBID = 3
local RELATION_WON = 4

local VIEW_ACTIVE = 0
local VIEW_HISTORY = 1

local PAGE_SIZE = 24
local MAX_COINS = 4294967295

-- Token scale, mirrored from the header comment in characterbazaar.otui.
local COLOR_PRIMARY = '#f6f1e2'
local COLOR_SECONDARY = '#c8c8c8'
local COLOR_TERTIARY = '#9a9a9a'
local COLOR_MONEY = '#f0c674'
local COLOR_POSITIVE = '#8fd97f'
local COLOR_URGENT = '#e8825c'
local COLOR_WARN = '#e8b964'

-- Vocation ids as the server numbers them (promotions are base + 4, Monk 9/10).
local VOCATION_OPTIONS = {
  {'All vocations', 0}, {'Knights', 4}, {'Paladins', 3}, {'Sorcerers', 1}, {'Druids', 2}, {'Monks', 9},
}
local SORT_OPTIONS = {
  {'Ending soon', 0}, {'Newest', 1}, {'Price: low to high', 2}, {'Price: high to low', 3},
  {'Level: high to low', 4}, {'Level: low to high', 5},
}
local HISTORY_SORT_OPTIONS = {
  {'Recently ended', 0}, {'Newest listing', 1}, {'Price: low to high', 2}, {'Price: high to low', 3},
  {'Level: high to low', 4}, {'Level: low to high', 5},
}

local RELATION_TEXT = {
  [RELATION_SELLER] = {'Your listing', COLOR_WARN},
  [RELATION_LEADING] = {'You are the highest bidder', COLOR_POSITIVE},
  [RELATION_OUTBID] = {'You have been outbid', COLOR_URGENT},
  [RELATION_WON] = {'You won this character', COLOR_POSITIVE},
}

local window
local detailWindow
local currentTab = 'browse'
local currentView = VIEW_ACTIVE
local browseState = {page = 0, pages = 1, total = 0}
local rules
local balance = 0
local detail
local detailRequested = false
local selectedMine
local pendingConfirm
local statusEvent
local detailStatusEvent
local tickEvent
local levelFilterEvent
-- One browse per mouse-wheel spin over a filter combo, sent 250 ms after the
-- last notch, instead of one per notch. Clicking an option still sends at once.
local filterWheelChange = false
local filterWheelEvent
local FILTER_WHEEL_DELAY_MS = 250
local sellPending = false
local liveCards = {}

-- ---------------------------------------------------------------- helpers

local function comma(value)
  local formatted = tostring(math.floor(tonumber(value) or 0))
  while true do
    local replaced
    formatted, replaced = formatted:gsub('^(%d+)(%d%d%d)', '%1,%2')
    if replaced == 0 then
      break
    end
  end
  return formatted
end

-- math.floor, not `//`: this client runs Lua 5.1.
local function formatTime(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  if seconds >= 86400 then
    return string.format('%dd %dh', math.floor(seconds / 86400), math.floor((seconds % 86400) / 3600))
  elseif seconds >= 3600 then
    return string.format('%dh %dm', math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
  elseif seconds >= 60 then
    return string.format('%dm %ds', math.floor(seconds / 60), seconds % 60)
  end
  return string.format('%ds', seconds)
end

local function formatAgo(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  if seconds < 60 then
    return 'just now'
  end
  return formatTime(seconds) .. ' ago'
end

local function timeColor(seconds)
  if seconds <= 300 then
    return COLOR_URGENT
  elseif seconds <= 3600 then
    return COLOR_WARN
  end
  return COLOR_TERTIARY
end

local function sexName(sex)
  return sex == 1 and 'Male' or 'Female'
end

local function child(parent, id)
  return parent:recursiveGetChildById(id)
end

local function clearList(panel)
  while panel:getChildCount() > 0 do
    panel:getChildByIndex(1):destroy()
  end
end

local function send(build)
  local protocolGame = g_game.getProtocolGame()
  if not protocolGame then
    return false
  end
  local msg = OutputMessage.create()
  msg:addU8(OPCODE_REQUEST)
  build(msg)
  protocolGame:send(msg)
  return true
end

local function updateBalance()
  if window then
    child(window, 'balance'):getChildById('value'):setText(comma(balance))
  end
end

-- Feedback lands beside the buttons that caused it and cannot outlive the window.
function setStatus(text, isError)
  if not window then
    return
  end
  local label = window:getChildById('statusLine')
  label:setText(text or '')
  label:setColor(isError and COLOR_URGENT or COLOR_POSITIVE)
  if statusEvent then
    removeEvent(statusEvent)
    statusEvent = nil
  end
  if text and text ~= '' then
    statusEvent = scheduleEvent(function()
      statusEvent = nil
      if window then
        window:getChildById('statusLine'):setText('')
      end
    end, 8000)
  end
end

local function setDetailStatus(text, isError)
  if not detailWindow then
    return
  end
  local label = detailWindow:getChildById('detailStatus')
  label:setText(text or '')
  label:setColor(isError and COLOR_URGENT or COLOR_POSITIVE)
  if detailStatusEvent then
    removeEvent(detailStatusEvent)
    detailStatusEvent = nil
  end
  if text and text ~= '' then
    detailStatusEvent = scheduleEvent(function()
      detailStatusEvent = nil
      if detailWindow then
        detailWindow:getChildById('detailStatus'):setText('')
      end
    end, 8000)
  end
end

-- ---------------------------------------------------------------- confirm

local function confirmHost()
  if detailWindow and detailWindow:isVisible() then
    return detailWindow
  end
  return window
end

function hideConfirm()
  pendingConfirm = nil
  for _, host in ipairs({window, detailWindow}) do
    if host then
      host:getChildById('confirmOverlay'):hide()
    end
  end
end

function showConfirm(title, body, acceptText, callback)
  local host = confirmHost()
  if not host then
    return
  end
  local overlay = host:getChildById('confirmOverlay')
  local box = overlay:getChildById('box')
  box:getChildById('title'):setText(title)
  box:getChildById('body'):setText(body)
  box:getChildById('accept'):setText(acceptText or tr('Confirm'))
  pendingConfirm = callback
  overlay:show()
  overlay:raise()
end

function onConfirmAccept()
  local callback = pendingConfirm
  hideConfirm()
  if callback then
    callback()
  end
end

function onConfirmCancel()
  hideConfirm()
end

-- ---------------------------------------------------------------- wire: read

local function readOutfit(msg)
  local outfit = {}
  outfit.type = msg:getU16()
  outfit.head = msg:getU8()
  outfit.body = msg:getU8()
  outfit.legs = msg:getU8()
  outfit.feet = msg:getU8()
  outfit.addons = msg:getU8()
  return outfit
end

local function readRow(msg)
  local row = {}
  row.id = msg:getU32()
  row.name = msg:getString()
  row.level = msg:getU32()
  row.vocationId = msg:getU8()
  row.vocation = msg:getString()
  row.sex = msg:getU8()
  row.outfit = readOutfit(msg)
  row.startPrice = msg:getU32()
  row.buyoutPrice = 0 -- only the detail packet carries it; see parseDetail
  row.currentBid = msg:getU32()
  row.finalPrice = msg:getU32()
  row.bids = msg:getU16()
  row.secondsLeft = msg:getU32()
  row.endedAgo = msg:getU32()
  row.status = msg:getU8()
  row.relation = msg:getU8()
  row.endsAt = os.time() + row.secondsLeft
  return row
end

-- ---------------------------------------------------------------- paint

local function priceParts(row)
  if row.status == STATUS_FINISHED then
    return 'Sold for', row.finalPrice
  elseif row.currentBid > 0 then
    return 'Current bid', row.currentBid
  end
  return 'Starting at', row.startPrice
end

local function stateText(row)
  if row.status == STATUS_ACTIVE then
    return formatTime(math.max(0, row.endsAt - os.time())) .. ' left', timeColor(math.max(0, row.endsAt - os.time()))
  elseif row.status == STATUS_FINISHED then
    return 'Sold ' .. formatAgo(row.endedAgo), COLOR_POSITIVE
  elseif row.status == STATUS_WITHDRAWN then
    return 'Withdrawn by seller', COLOR_TERTIARY
  end
  return 'Ended without bids', COLOR_TERTIARY
end

local function paintRelation(label, relation)
  local spec = RELATION_TEXT[relation]
  if spec then
    label:setText(spec[1])
    label:setColor(spec[2])
  else
    label:setText('')
  end
end

local function setPortrait(creatureWidget, outfit)
  creatureWidget:setOutfit({type = outfit.type, head = outfit.head, body = outfit.body, legs = outfit.legs,
    feet = outfit.feet, addons = outfit.addons})
end

local function addCard(panel, row)
  local card = g_ui.createWidget('CbCard', panel)
  card:setId('card' .. tostring(row.id))
  card.data = row
  card:getChildById('auctionId'):setText(string.format('Auction #%d', row.id))
  local body = card:getChildById('body')
  setPortrait(child(body, 'portrait'), row.outfit)
  body:getChildById('name'):setText(row.name)
  body:getChildById('subtitle'):setText(string.format('Level %d %s', row.level, row.vocation))
  paintRelation(body:getChildById('relation'), row.relation)
  local caption, amount = priceParts(row)
  body:getChildById('priceLabel'):setText(caption)
  body:getChildById('price'):setText(comma(amount))
  body:getChildById('bids'):setText(row.bids == 1 and '1 bid' or string.format('%d bids', row.bids))
  local hasBuyNow = row.status == STATUS_ACTIVE and (row.buyoutPrice or 0) > 0
  for _, id in ipairs({'buyNowCaption', 'buyNowPrice', 'buyNowCoin'}) do
    body:getChildById(id):setVisible(hasBuyNow)
  end
  body:getChildById('buyNowPrice'):setText(hasBuyNow and comma(row.buyoutPrice) or '')
  local text, color = stateText(row)
  card:getChildById('timeLeft'):setText(text)
  card:getChildById('timeLeft'):setColor(color)
  card.onClick = function()
    openDetail(row.id)
  end
  card.onDoubleClick = card.onClick
  liveCards[#liveCards + 1] = card
  return card
end

local function addMineRow(panel, row)
  local widget = g_ui.createWidget('CbRow', panel)
  widget:setId('mine' .. tostring(row.id))
  widget.data = row
  setPortrait(child(widget, 'portrait'), row.outfit)
  widget:getChildById('name'):setText(row.name)
  widget:getChildById('subtitle'):setText(string.format('Level %d %s  -  Auction #%d', row.level, row.vocation, row.id))
  local spec = RELATION_TEXT[row.relation]
  local state = widget:getChildById('state')
  state:setText(spec and spec[1] or '')
  state:setColor(spec and spec[2] or COLOR_SECONDARY)
  local _, amount = priceParts(row)
  widget:getChildById('price'):setText(comma(amount))
  local text, color = stateText(row)
  widget:getChildById('timeLeft'):setText(text)
  widget:getChildById('timeLeft'):setColor(color)
  widget.onClick = function()
    selectedMine = row
    panel:focusChild(widget)
    local panelRoot = window:getChildById('minePanel')
    panelRoot:getChildById('mineWithdraw'):setEnabled(row.relation == RELATION_SELLER and row.status == STATUS_ACTIVE
      and row.currentBid == 0)
    panelRoot:getChildById('mineOpen'):setEnabled(true)
  end
  widget.onDoubleClick = function()
    openDetail(row.id)
  end
  liveCards[#liveCards + 1] = widget
  return widget
end

-- Countdowns tick locally between server refreshes so a card never shows a
-- frozen clock. One timer for every live card; stopped when the window hides.
local function repaintClocks()
  for _, widget in ipairs(liveCards) do
    if not widget:isDestroyed() and widget.data and widget.data.status == STATUS_ACTIVE then
      local text, color = stateText(widget.data)
      local label = widget:getChildById('timeLeft')
      if label then
        label:setText(text)
        label:setColor(color)
      end
    end
  end
  if detail and detailWindow and detailWindow:isVisible() and detail.status == STATUS_ACTIVE then
    local text, color = stateText(detail)
    local line = detailWindow:getChildById('stateLine')
    line:setText(string.format('Active auction  -  %s', text))
    line:setColor(color)
  end
end

local function stopTicking()
  if tickEvent then
    removeEvent(tickEvent)
    tickEvent = nil
  end
end

local function startTicking()
  stopTicking()
  tickEvent = cycleEvent(function()
    if not window or not window:isVisible() then
      stopTicking()
      return
    end
    repaintClocks()
  end, 1000)
end

-- ---------------------------------------------------------------- requests

local function selectedOption(combo)
  local option = combo:getCurrentOption()
  return option and option.data or 0
end

local function requestBrowse()
  local panel = window:getChildById('browsePanel')
  local minLevel = tonumber(panel:getChildById('minLevel'):getText()) or 0
  local maxLevel = tonumber(panel:getChildById('maxLevel'):getText()) or 0
  local vocation = selectedOption(panel:getChildById('vocationFilter'))
  local sort = selectedOption(panel:getChildById('sortMode'))
  send(function(msg)
    msg:addU8(ACTION_BROWSE)
    msg:addU8(currentView)
    msg:addU16(browseState.page)
    msg:addU8(sort)
    msg:addU8(vocation)
    msg:addU32(math.max(0, math.floor(minLevel)))
    msg:addU32(math.max(0, math.floor(maxLevel)))
  end)
end

local function requestMine()
  send(function(msg) msg:addU8(ACTION_MINE) end)
end

function requestRules()
  if not window then
    return
  end
  child(window, 'eligibility'):setText('Checking whether this character can be listed...')
  child(window, 'eligibility'):setColor(COLOR_SECONDARY)
  send(function(msg) msg:addU8(ACTION_RULES) end)
end

function openDetail(auctionId)
  detailRequested = true
  send(function(msg)
    msg:addU8(ACTION_DETAIL)
    msg:addU32(auctionId)
  end)
end

-- ---------------------------------------------------------------- wire: parse

local function parseRules(msg)
  rules = {}
  rules.enabled = msg:getU8() ~= 0
  rules.eligible = msg:getU8() ~= 0
  rules.reason = msg:getString()
  rules.minLevel = msg:getU32()
  rules.minPrice = msg:getU32()
  rules.minDuration = msg:getU32()
  rules.maxDuration = msg:getU32()
  rules.fee = msg:getU32()
  rules.commission = msg:getU8()
  rules.antiSnipe = msg:getU32()
  balance = msg:getU32()
  updateBalance()

  local panel = window:getChildById('sellPanel')
  local list = child(panel, 'rulesList')
  clearList(list)
  local function stat(label, value, color)
    local row = g_ui.createWidget('CbStat', list)
    row:getChildById('label'):setText(label)
    row:getChildById('value'):setText(value)
    if color then
      row:getChildById('value'):setColor(color)
    end
  end
  stat('Minimum level', tostring(rules.minLevel))
  stat('Lowest starting price', comma(rules.minPrice) .. ' BPC', COLOR_MONEY)
  stat('Listing fee (charged now)', comma(rules.fee) .. ' BPC', COLOR_MONEY)
  stat('Commission on the sale', string.format('%d%%', rules.commission))
  stat('Auction length', string.format('%d h to %d h', math.floor(rules.minDuration / 3600),
    math.floor(rules.maxDuration / 3600)))
  stat('Your transferable coins', comma(balance) .. ' BPC', COLOR_MONEY)

  local eligibility = child(panel, 'eligibility')
  local playerName = g_game.getLocalPlayer() and g_game.getLocalPlayer():getName() or 'This character'
  if not rules.enabled then
    eligibility:setText('The Character Bazaar is currently closed for new listings.')
    eligibility:setColor(COLOR_URGENT)
  elseif rules.eligible then
    eligibility:setText(string.format('%s can be listed. Set a starting price and a duration, then review.', playerName))
    eligibility:setColor(COLOR_POSITIVE)
  else
    eligibility:setText(string.format('%s cannot be listed right now: %s', playerName, rules.reason))
    eligibility:setColor(COLOR_URGENT)
  end

  local form = child(panel, 'sellForm')
  form:getChildById('characterLine'):setText(string.format('Listing: %s', playerName))
  if form:getChildById('startPrice'):getText() == '' then
    form:getChildById('startPrice'):setText(tostring(rules.minPrice))
  end
  if form:getChildById('duration'):getText() == '' then
    form:getChildById('duration'):setText(tostring(math.floor(rules.maxDuration / 3600)))
  end
  form:getChildById('sellHint'):setText(string.format(
    'The fee of %s BPC is taken when you confirm. On a sale you receive the winning bid minus %d%%. '
    .. 'A bid in the last %d minutes extends the auction by %d minutes.',
    comma(rules.fee), rules.commission, math.floor(rules.antiSnipe / 60), math.floor(rules.antiSnipe / 60)))
  form:getChildById('reviewButton'):setEnabled(rules.enabled and rules.eligible and not sellPending)
end

-- Buy Now prices ride AFTER the rows (2026-09-11): a U16 count, then one U32
-- per row in row order. The rows themselves are unchanged, so a client from
-- before Buy Now still reads the list and stops short of this; this client
-- reads it only if the server sent it.
local function readBuyoutTail(msg, rows)
  if msg:getUnreadSize() < 2 then
    return
  end
  local count = msg:getU16()
  for i = 1, count do
    if msg:getUnreadSize() < 4 then
      return
    end
    local price = msg:getU32()
    if rows[i] then
      rows[i].buyoutPrice = price
    end
  end
end

local function parseBrowse(msg)
  local view = msg:getU8()
  browseState.page = msg:getU16()
  browseState.total = msg:getU32()
  local count = msg:getU16()
  local panel = window:getChildById('browsePanel')
  local list = panel:getChildById('list')
  clearList(list)
  liveCards = {}
  -- Rows first, then their Buy Now prices, THEN the cards: a card is painted
  -- once, so it has to know its Buy Now before it is built.
  local rows = {}
  for _ = 1, count do
    rows[#rows + 1] = readRow(msg)
  end
  readBuyoutTail(msg, rows)
  for _, row in ipairs(rows) do
    addCard(list, row)
  end
  browseState.pages = math.max(1, math.ceil(browseState.total / PAGE_SIZE))
  panel:getChildById('pageInfo'):setText(string.format('%d %s  -  page %d of %d', browseState.total,
    view == VIEW_HISTORY and (browseState.total == 1 and 'past auction' or 'past auctions')
      or (browseState.total == 1 and 'character for sale' or 'characters for sale'),
    browseState.page + 1, browseState.pages))
  panel:getChildById('pagePrev'):setEnabled(browseState.page > 0)
  panel:getChildById('pageNext'):setEnabled(browseState.page + 1 < browseState.pages)
  local empty = panel:getChildById('listEmpty')
  empty:setVisible(count == 0)
  empty:setText(view == VIEW_HISTORY and 'No finished auctions match these filters yet.'
    or 'No characters are up for auction right now. List yours under Sell Character, or check back later.')
  startTicking()
end

local function parseMine(msg)
  local count = msg:getU16()
  local panel = window:getChildById('minePanel')
  local list = panel:getChildById('mineList')
  clearList(list)
  -- Cards from the browse list stay live; only the rows are rebuilt.
  local kept = {}
  for _, widget in ipairs(liveCards) do
    if not widget:isDestroyed() then
      kept[#kept + 1] = widget
    end
  end
  liveCards = kept
  selectedMine = nil
  for _ = 1, count do
    addMineRow(list, readRow(msg))
  end
  panel:getChildById('mineEmpty'):setVisible(count == 0)
  panel:getChildById('mineWithdraw'):setEnabled(false)
  panel:getChildById('mineOpen'):setEnabled(false)
  startTicking()
end

local SKILL_NAMES = {'Fist Fighting', 'Club Fighting', 'Sword Fighting', 'Axe Fighting', 'Distance Fighting',
  'Shielding', 'Fishing'}
local SLOT_NAMES = {[1] = 'Helmet', [2] = 'Amulet', [3] = 'Backpack', [4] = 'Armor', [5] = 'Right hand',
  [6] = 'Left hand', [7] = 'Legs', [8] = 'Boots', [9] = 'Ring', [10] = 'Ammunition'}

local function ensureDetailWindow()
  if not detailWindow then
    detailWindow = g_ui.createWidget('CbDetailWindow', rootWidget)
    detailWindow:hide()
    detailWindow:getChildById('bidField').onTextChange = function() end
  end
  return detailWindow
end

-- The detail packet's tail: wardrobe, Bao's Ledger, then the Buy Now price.
-- Called only when bytes remain after the bid history (see parseDetail).
-- Returns the Buy Now price, 0 when the listing has none.
local function readDetailTail(msg, d)
  -- Wardrobe. `outfits`/`mounts` above are the same numbers these lists carry;
  -- the server derives them from the lists so they cannot disagree.
  d.outfitBaseline = msg:getU16()
  local outfitCount = msg:getU8()
  for _ = 1, outfitCount do
    local outfit = {}
    outfit.lookType = msg:getU16()
    outfit.addons = msg:getU8()
    outfit.name = msg:getString()
    d.outfitList[#d.outfitList + 1] = outfit
  end
  d.mountList = {}
  local mountCount = msg:getU8()
  for _ = 1, mountCount do
    local mount = {}
    mount.clientId = msg:getU16()
    mount.name = msg:getString()
    d.mountList[#d.mountList + 1] = mount
  end

  -- Bao's Ledger, snapshot when the character was listed. `recorded` false
  -- means no snapshot exists (a listing older than the feature) and must read
  -- as "not recorded" rather than as an empty Ledger.
  local bao = {recorded = msg:getU8() ~= 0, tracks = {}}
  if bao.recorded then
    bao.rankId = msg:getU8()
    bao.rankName = msg:getString()
    bao.reputation = msg:getU64()
    bao.marks = msg:getU64()
    bao.chapter = msg:getU8()
    local trackCount = msg:getU8()
    for _ = 1, trackCount do
      local track = {}
      track.name = msg:getString()
      track.rank = msg:getU16()
      track.maxRank = msg:getU16()
      track.effect = msg:getString()
      bao.tracks[#bao.tracks + 1] = track
    end
  end
  d.bao = bao
  -- Last field, so an older server that stops after the Ledger still parses.
  if msg:getUnreadSize() >= 4 then
    return msg:getU32()
  end
  return 0
end

local function parseDetail(msg)
  detail = readRow(msg)
  detail.description = msg:getString()
  detail.minimumBid = msg:getU32()
  detail.isSeller = msg:getU8() ~= 0
  detail.isHighest = msg:getU8() ~= 0
  detail.canWithdraw = msg:getU8() ~= 0
  local d = {}
  d.town = msg:getString()
  d.health = msg:getU32()
  d.mana = msg:getU32()
  d.capacity = msg:getU32()
  d.magicLevel = msg:getU32()
  d.experience = msg:getU64()
  d.bank = msg:getU64()
  d.skills = {}
  for i = 1, 7 do
    d.skills[i] = msg:getU16()
  end
  d.charmPoints = msg:getU32()
  d.charms = msg:getU16()
  d.achievements = msg:getU16()
  d.achievementPoints = msg:getU16()
  d.outfits = msg:getU16()
  d.mounts = msg:getU16()
  d.blessings = msg:getU8()
  d.deaths = msg:getU16()
  d.hirelings = msg:getU16()
  d.onlineHours = msg:getU32()
  d.bountyPoints = msg:getU32()
  d.soulSeals = msg:getU32()
  d.depotItems = msg:getU32()
  d.equipment = {}
  local equipmentCount = msg:getU8()
  for _ = 1, equipmentCount do
    local item = {}
    item.slot = msg:getU8()
    item.clientId = msg:getU16()
    item.count = msg:getU8()
    item.name = msg:getString()
    d.equipment[#d.equipment + 1] = item
  end
  local history = {}
  local historyCount = msg:getU8()
  for _ = 1, historyCount do
    history[#history + 1] = {amount = msg:getU32(), ago = msg:getU32()}
  end

  -- Everything below is a TAIL added 2026-09-11 (wardrobe, Bao's Ledger, Buy
  -- Now). A server from before that update does not send it, so it is read
  -- only if bytes remain -- otherwise this client, reaching players through
  -- the updater before or after the server restart, would read past the end.
  d.outfitBaseline = 0
  d.outfitList = {}
  d.mountList = {}
  d.bao = {recorded = false, tracks = {}}
  detail.buyoutPrice = 0
  d.hasTail = msg:getUnreadSize() > 0
  if d.hasTail then
    detail.buyoutPrice = readDetailTail(msg, d)
  end

  detail.dossier = d
  detail.history = history

  local win = ensureDetailWindow()
  win:setText(string.format('Character Auction #%d', detail.id))
  setPortrait(child(win, 'portrait'), detail.outfit)
  win:getChildById('name'):setText(detail.name)
  win:getChildById('subtitle'):setText(string.format('Level %d %s  -  %s  -  from %s', detail.level, detail.vocation,
    sexName(detail.sex), d.town ~= '' and d.town or 'an unknown town'))
  local stateLine = win:getChildById('stateLine')
  if detail.status == STATUS_ACTIVE then
    local text, color = stateText(detail)
    stateLine:setText(string.format('Active auction  -  %s', text))
    stateLine:setColor(color)
  else
    local text, color = stateText(detail)
    stateLine:setText(text)
    stateLine:setColor(color)
  end
  paintRelation(win:getChildById('relationLine'), detail.relation)

  local band = win:getChildById('priceBand')
  local caption, amount = priceParts(detail)
  band:getChildById('priceCaption'):setText(caption)
  band:getChildById('price'):setText(comma(amount))
  local bidWord = detail.bids == 1 and 'bid' or 'bids'
  local capped = detail.buyoutPrice > 0 and detail.minimumBid >= detail.buyoutPrice
  local noteHasAmount = detail.status == STATUS_ACTIVE and not capped
  if noteHasAmount then
    band:getChildById('bidsNote'):setText(string.format('%d %s  -  next bid at least %s', detail.bids, bidWord,
      comma(detail.minimumBid)))
  elseif detail.status == STATUS_ACTIVE then
    -- placeBid refuses a bid that reaches the Buy Now price, so there is no
    -- "next bid" to quote here -- only Buy Now.
    band:getChildById('bidsNote'):setText(string.format('%d %s  -  bidding has reached the Buy Now price',
      detail.bids, bidWord))
  else
    band:getChildById('bidsNote'):setText(string.format('%d %s in total', detail.bids, bidWord))
  end
  -- The coin follows an amount, so it shows only when the note ends in one.
  band:getChildById('bidsNoteCoin'):setVisible(noteHasAmount)

  child(win, 'statsHead'):getChildById('title'):setText('Character')
  child(win, 'statsHead'):getChildById('note'):setText(string.format('%s hours played', comma(d.onlineHours)))
  local stats = child(win, 'statsList')
  clearList(stats)
  local function stat(label, value, color)
    local row = g_ui.createWidget('CbStat', stats)
    row:getChildById('label'):setText(label)
    row:getChildById('value'):setText(value)
    if color then
      row:getChildById('value'):setColor(color)
    end
  end
  stat('Hit Points', comma(d.health))
  stat('Mana', comma(d.mana))
  stat('Capacity', comma(d.capacity))
  stat('Experience', comma(d.experience))
  stat('Magic Level', tostring(d.magicLevel))
  for i = 1, 7 do
    stat(SKILL_NAMES[i], tostring(d.skills[i]))
  end
  stat('Bank gold', comma(d.bank), COLOR_MONEY)
  stat('Charm Points', comma(d.charmPoints))
  stat('Charms unlocked', tostring(d.charms))
  stat('Achievements', string.format('%d  (%d pts)', d.achievements, d.achievementPoints))
  stat('Outfits', tostring(d.outfits))
  stat('Mounts', tostring(d.mounts))
  stat('Blessings', tostring(d.blessings))
  stat('Deaths', tostring(d.deaths))
  stat('Hirelings', tostring(d.hirelings))
  stat('Items in depot', comma(d.depotItems))
  if d.bountyPoints > 0 then
    stat('Bounty Points', comma(d.bountyPoints))
  end
  if d.soulSeals > 0 then
    stat('Soul Seals', comma(d.soulSeals))
  end

  child(win, 'gearHead'):getChildById('title'):setText('Equipment')
  child(win, 'gearHead'):getChildById('note'):setText(#d.equipment == 0 and 'nothing worn' or
    string.format('%d %s worn', #d.equipment, #d.equipment == 1 and 'item' or 'items'))
  local gear = win:getChildById('gearPlate')
  for slot = 1, 10 do
    local widget = gear:getChildById('slot' .. slot)
    widget:setItemId(0)
    widget:setTooltip(SLOT_NAMES[slot])
  end
  for _, item in ipairs(d.equipment) do
    local widget = gear:getChildById('slot' .. item.slot)
    if widget then
      widget:setItemId(item.clientId)
      if item.count > 1 then
        widget:setItemCount(item.count)
      end
      widget:setTooltip(string.format('%s: %s', SLOT_NAMES[item.slot] or 'Slot', item.name))
    end
  end
  gear:getChildById('gearNote'):setText('Worn gear, the backpack and the depot all transfer.')

  child(win, 'descriptionHead'):getChildById('title'):setText("Seller's note")
  child(win, 'descriptionHead'):getChildById('note'):setText('')
  local description = child(win, 'description')
  if detail.description ~= '' then
    description:setText(detail.description)
    description:setColor(COLOR_SECONDARY)
  else
    description:setText('The seller left no description.')
    description:setColor(COLOR_TERTIARY)
  end

  child(win, 'historyHead'):getChildById('title'):setText('Bids')
  child(win, 'historyHead'):getChildById('note'):setText(#history > 0 and 'most recent first' or '')
  local historyList = child(win, 'historyList')
  clearList(historyList)
  for _, entry in ipairs(history) do
    local line = g_ui.createWidget('CbBidLine', historyList)
    line:getChildById('amount'):setText(comma(entry.amount))
    line:getChildById('when'):setText(formatAgo(entry.ago))
  end
  child(win, 'historyEmpty'):setVisible(#history == 0)

  -- Third column: Bao's Ledger first, since it is what a character on this
  -- server is valued on, then the wardrobe. Rebuilt on every paint.
  child(win, 'extrasHead'):getChildById('title'):setText('Ledger & Wardrobe')
  child(win, 'extrasHead'):getChildById('note'):setText('')
  local extras = child(win, 'extrasList')
  clearList(extras)
  local function heading(text)
    g_ui.createWidget('CbExtrasLabel', extras):setText(text)
  end
  local function note(text)
    g_ui.createWidget('CbExtrasNote', extras):setText(text)
  end
  local function extraStat(label, value)
    local row = g_ui.createWidget('CbStat', extras)
    row:getChildById('label'):setText(label)
    row:getChildById('value'):setText(value)
  end

  if not d.hasTail then
    note('This server did not send the Ledger, outfits or mounts. They appear once it is updated.')
  else
    local bao = d.bao
    heading("Bao's Ledger")
    if not bao.recorded then
      -- Not the same claim as an empty Ledger, and it must never read like one.
      note('Not recorded: this listing predates Ledger snapshots. It does not mean the Ledger is empty.')
    else
      extraStat('Rank', bao.rankName ~= '' and bao.rankName or tostring(bao.rankId))
      extraStat('Reputation', comma(bao.reputation))
      extraStat('Marks', comma(bao.marks))
      extraStat('Story chapter', tostring(bao.chapter))
      if #bao.tracks == 0 then
        note('No Ledger upgrades had been bought when this character was listed.')
      end
      for _, track in ipairs(bao.tracks) do
        local row = g_ui.createWidget('CbLedgerRow', extras)
        local mastered = track.maxRank > 0 and track.rank >= track.maxRank
        row:getChildById('name'):setText(track.name)
        row:getChildById('rank'):setText(track.maxRank > 0
          and string.format('%d / %d', track.rank, track.maxRank) or tostring(track.rank))
        row:getChildById('rank'):setColor(mastered and COLOR_POSITIVE or COLOR_TERTIARY)
        row:getChildById('effect'):setText(track.effect)
      end
    end

    heading(string.format('Outfits  -  %d earned, %d basic', #d.outfitList, d.outfitBaseline))
    if #d.outfitList == 0 then
      note('Nothing beyond the basic outfits every character starts with.')
    end
    for _, outfit in ipairs(d.outfitList) do
      local row = g_ui.createWidget('CbWardrobeRow', extras)
      -- Drawn in the character's own colours, the way it would actually wear it.
      child(row, 'creature'):setOutfit({type = outfit.lookType, head = detail.outfit.head, body = detail.outfit.body,
        legs = detail.outfit.legs, feet = detail.outfit.feet, addons = outfit.addons})
      row:getChildById('name'):setText(outfit.name)
      local addonNote = row:getChildById('note')
      addonNote:setText(outfit.addons >= 3 and 'Both addons' or outfit.addons == 1 and 'First addon'
        or outfit.addons == 2 and 'Second addon' or 'No addons')
      if outfit.addons >= 3 then
        addonNote:setColor(COLOR_POSITIVE)
      end
    end

    heading(string.format('Mounts  -  %d', #d.mountList))
    if #d.mountList == 0 then
      note('This character owns no mounts.')
    end
    for _, mount in ipairs(d.mountList) do
      local row = g_ui.createWidget('CbWardrobeRow', extras)
      child(row, 'creature'):setOutfit({type = mount.clientId})
      row:getChildById('name'):setText(mount.name)
      row:getChildById('note'):setText('Mount')
    end
  end

  -- The Buy Now price is a CEILING on bidding: CharacterBazaar::placeBid refuses
  -- any bid that reaches it. Once the next bid would, the bid controls hide and
  -- Buy Now is the way in.
  local bidCeiling = detail.buyoutPrice > 0 and detail.buyoutPrice - 1 or MAX_COINS
  local canBid = detail.status == STATUS_ACTIVE and not detail.isSeller and detail.minimumBid <= bidCeiling
    and detail.currentBid < MAX_COINS
  local bidField = win:getChildById('bidField')
  bidField:setEnabled(canBid)
  bidField:setText(canBid and tostring(detail.minimumBid) or '')
  win:getChildById('bidButton'):setEnabled(canBid)
  win:getChildById('bidButton'):setText(detail.isHighest and tr('Raise Bid') or tr('Place Bid'))
  win:getChildById('withdrawButton'):setVisible(detail.canWithdraw)
  bidField:setVisible(canBid)
  win:getChildById('bidCoin'):setVisible(canBid)
  win:getChildById('bidButton'):setVisible(canBid)
  -- Everyone sees a live listing's Buy Now price, the seller included; only a
  -- buyer gets the button. With no button the price carries its own caption.
  local showBuyNow = detail.status == STATUS_ACTIVE and detail.buyoutPrice > 0
  local canBuyNow = showBuyNow and not detail.isSeller
  local buyNow = win:getChildById('buyNowButton')
  buyNow:setVisible(canBuyNow)
  buyNow:setEnabled(canBuyNow)
  local buyNowCoin = win:getChildById('buyNowCoin')
  local buyNowPrice = win:getChildById('buyNowPrice')
  buyNowCoin:setVisible(showBuyNow)
  buyNowPrice:setVisible(showBuyNow)
  buyNowPrice:setText(not showBuyNow and '' or canBuyNow and comma(detail.buyoutPrice)
    or string.format('Buy Now %s', comma(detail.buyoutPrice)))

  -- Nothing is anchored to a hidden widget: the coin moves to the band's edge
  -- when the button is hidden, and Place Bid moves there when Buy Now is.
  buyNowCoin:removeAnchor(AnchorRight)
  if canBuyNow then
    buyNowCoin:addAnchor(AnchorRight, 'buyNowButton', AnchorLeft)
    buyNowCoin:setMarginRight(8)
  else
    buyNowCoin:addAnchor(AnchorRight, 'priceBand', AnchorRight)
    buyNowCoin:setMarginRight(12)
  end
  local bidButton = win:getChildById('bidButton')
  bidButton:removeAnchor(AnchorRight)
  if showBuyNow then
    bidButton:addAnchor(AnchorRight, 'buyNowPrice', AnchorLeft)
    bidButton:setMarginRight(18)
  else
    bidButton:addAnchor(AnchorRight, 'priceBand', AnchorRight)
    bidButton:setMarginRight(8)
  end

  if detailRequested then
    detailRequested = false
    win:show()
    win:raise()
    win:focus()
    if canBid then
      bidField:focus()
    end
  end
end

local function parseResult(msg)
  local success = msg:getU8() ~= 0
  local text = msg:getString()
  balance = msg:getU32()
  updateBalance()
  if sellPending then
    sellPending = false
    local form = child(window, 'sellForm')
    form:getChildById('reviewButton'):setEnabled(rules ~= nil and rules.eligible)
    child(window, 'eligibility'):setText(text)
    child(window, 'eligibility'):setColor(success and COLOR_POSITIVE or COLOR_URGENT)
  end
  if detailWindow and detailWindow:isVisible() then
    setDetailStatus(text, not success)
  else
    setStatus(text, not success)
  end
  if success then
    -- Any successful action changes what My Auctions shows.
    requestMine()
    if currentTab == 'browse' or currentTab == 'history' then
      requestBrowse()
    end
  end
end

local function onOpcode(protocol, msg)
  local responseType = msg:getU8()
  if responseType == RESP_RULES then
    parseRules(msg)
  elseif responseType == RESP_BROWSE then
    parseBrowse(msg)
  elseif responseType == RESP_DETAIL then
    parseDetail(msg)
  elseif responseType == RESP_MINE then
    parseMine(msg)
  elseif responseType == RESP_RESULT then
    parseResult(msg)
  end
  return true
end

-- ---------------------------------------------------------------- actions

local function fillCombo(combo, options, onChange)
  combo:clearOptions()
  for _, option in ipairs(options) do
    combo:addOption(option[1], option[2])
  end
  -- dontSignal: resetting the combo is not a filter change. Without it the
  -- old onOptionChange sent a browse, and selectTab then sent a second one.
  combo:setCurrentIndex(1, true)
  combo.onOptionChange = onChange
  if not combo.wheelDebounced then
    combo.wheelDebounced = true
    function combo:onMouseWheel(mousePos, direction)
      filterWheelChange = true
      local ok, handled = pcall(UIComboBox.onMouseWheel, self, mousePos, direction)
      filterWheelChange = false
      if not ok then
        perror(handled)
        return true
      end
      return handled
    end
  end
end

function selectTab(tab)
  currentTab = tab
  local browseTab = tab == 'browse' or tab == 'history'
  window:getChildById('browsePanel'):setVisible(browseTab)
  window:getChildById('minePanel'):setVisible(tab == 'mine')
  window:getChildById('sellPanel'):setVisible(tab == 'sell')
  window:getChildById('tabBrowse'):setChecked(tab == 'browse')
  window:getChildById('tabHistory'):setChecked(tab == 'history')
  window:getChildById('tabMine'):setChecked(tab == 'mine')
  window:getChildById('tabSell'):setChecked(tab == 'sell')

  if browseTab then
    local wanted = tab == 'history' and VIEW_HISTORY or VIEW_ACTIVE
    if wanted ~= currentView then
      currentView = wanted
      browseState.page = 0
      local panel = window:getChildById('browsePanel')
      fillCombo(panel:getChildById('sortMode'), wanted == VIEW_HISTORY and HISTORY_SORT_OPTIONS or SORT_OPTIONS,
        onFilterChanged)
    end
    requestBrowse()
  elseif tab == 'mine' then
    requestMine()
  elseif tab == 'sell' then
    requestRules()
  end
end

function onFilterChanged()
  if filterWheelEvent then
    removeEvent(filterWheelEvent)
    filterWheelEvent = nil
  end
  browseState.page = 0
  if filterWheelChange then
    filterWheelEvent = scheduleEvent(function()
      filterWheelEvent = nil
      if window then
        browseState.page = 0
        requestBrowse()
      end
    end, FILTER_WHEEL_DELAY_MS)
    return
  end
  requestBrowse()
end

-- Typing a level re-queries after a short pause rather than per keystroke.
function onLevelFilterChanged()
  if levelFilterEvent then
    removeEvent(levelFilterEvent)
  end
  levelFilterEvent = scheduleEvent(function()
    levelFilterEvent = nil
    if window and window:isVisible() then
      onFilterChanged()
    end
  end, 700)
end

function changePage(delta)
  local target = browseState.page + delta
  if target < 0 or target >= browseState.pages then
    return
  end
  browseState.page = target
  requestBrowse()
end

function refresh()
  if currentTab == 'browse' or currentTab == 'history' then
    requestBrowse()
  elseif currentTab == 'mine' then
    requestMine()
  elseif currentTab == 'sell' then
    requestRules()
  end
end

function onSellEdited()
  if not window then
    return
  end
  local form = child(window, 'sellForm')
  local length = #form:getChildById('description'):getText()
  local counter = form:getChildById('descriptionCount')
  counter:setText(string.format('%d / 512', length))
  counter:setColor(length > 512 and COLOR_URGENT or COLOR_TERTIARY)
end

function onReviewListing()
  if not rules or not rules.eligible or sellPending then
    return
  end
  local form = child(window, 'sellForm')
  local price = tonumber(form:getChildById('startPrice'):getText())
  local hours = tonumber(form:getChildById('duration'):getText())
  local description = form:getChildById('description'):getText()
  local eligibility = child(window, 'eligibility')
  if not price or price ~= math.floor(price) or price < rules.minPrice or price > MAX_COINS then
    eligibility:setText(string.format('Enter a whole starting price of at least %s BPC.', comma(rules.minPrice)))
    eligibility:setColor(COLOR_URGENT)
    return
  end
  local minHours, maxHours = math.floor(rules.minDuration / 3600), math.floor(rules.maxDuration / 3600)
  if not hours or hours ~= math.floor(hours) or hours < minHours or hours > maxHours then
    eligibility:setText(string.format('Enter a whole number of hours between %d and %d.', minHours, maxHours))
    eligibility:setColor(COLOR_URGENT)
    return
  end
  -- Optional. Strictly above the start price, never equal: an equal buyout is a
  -- fixed-price sale, which the server refuses (CharacterBazaar::createAuction).
  local buyoutText = form:getChildById('buyoutPrice'):getText()
  local buyout = 0
  if buyoutText ~= '' then
    buyout = tonumber(buyoutText)
    if not buyout or buyout ~= math.floor(buyout) or buyout <= price or buyout > MAX_COINS then
      eligibility:setText(string.format('A Buy Now price must be a whole number above the starting price of %s BPC, '
        .. 'or left empty.', comma(price)))
      eligibility:setColor(COLOR_URGENT)
      return
    end
  end
  if #description > 512 then
    eligibility:setText('The description must be 512 characters or fewer.')
    eligibility:setColor(COLOR_URGENT)
    return
  end
  local playerName = g_game.getLocalPlayer() and g_game.getLocalPlayer():getName() or 'this character'
  showConfirm(tr('List this character?'), string.format(
    'List %s with a starting price of %s BPC%s for %d hours.\n\nThe listing fee of %s BPC is charged now and is not '
    .. 'refunded. You will be logged out immediately and %s cannot enter the game until the auction ends. If it '
    .. 'sells, you receive the winning bid minus %d%%.',
    playerName, comma(price), buyout > 0 and string.format(' and a Buy Now price of %s BPC', comma(buyout)) or '',
    hours, comma(rules.fee), playerName, rules.commission), tr('List and Log Out'),
    function()
      sellPending = true
      form:getChildById('reviewButton'):setEnabled(false)
      eligibility:setText('Creating the auction...')
      eligibility:setColor(COLOR_SECONDARY)
      if not send(function(msg)
        msg:addU8(ACTION_CREATE_V2)
        msg:addU32(price)
        msg:addU32(buyout)
        msg:addU32(hours * 3600)
        msg:addString(description)
      end) then
        sellPending = false
        form:getChildById('reviewButton'):setEnabled(true)
        eligibility:setText('Not connected. Log in again and try once more.')
        eligibility:setColor(COLOR_URGENT)
      end
    end)
end

function onPlaceBid()
  if not detail or detail.status ~= STATUS_ACTIVE then
    return
  end
  local amount = tonumber(detailWindow:getChildById('bidField'):getText())
  if not amount or amount ~= math.floor(amount) or amount < detail.minimumBid or amount > MAX_COINS then
    setDetailStatus(string.format('Enter a whole number of at least %s BPC.', comma(detail.minimumBid)), true)
    return
  end
  local auctionId = detail.id
  showConfirm(tr('Confirm Bid'), string.format(
    'Bid %s BPC on %s (level %d %s)?\n\nYour coins are held in escrow and returned automatically if you are outbid. '
    .. 'If you win, the character moves to your account when the auction ends.',
    comma(amount), detail.name, detail.level, detail.vocation), tr('Place Bid'), function()
      send(function(msg)
        msg:addU8(ACTION_BID)
        msg:addU32(auctionId)
        msg:addU32(amount)
      end)
    end)
end

function onBuyNow()
  if not detail or detail.status ~= STATUS_ACTIVE or detail.buyoutPrice == 0 then
    return
  end
  local auctionId = detail.id
  showConfirm(tr('Buy Now'), string.format(
    'Buy %s (level %d %s) now for %s BPC?\n\nThe auction ends at once and the character moves to your account '
    .. 'immediately%s. Log out to the character list to see it.',
    detail.name, detail.level, detail.vocation, comma(detail.buyoutPrice),
    detail.currentBid > 0 and ', and the standing bidder is refunded' or ''), tr('Buy Now'), function()
      send(function(msg)
        msg:addU8(ACTION_BUYNOW)
        msg:addU32(auctionId)
      end)
    end)
end

local function confirmWithdraw(row)
  showConfirm(tr('Withdraw Listing'), string.format(
    'Take %s off the Bazaar?\n\nThe character can log in again straight away. The listing fee is not refunded.',
    row.name), tr('Withdraw'), function()
      send(function(msg)
        msg:addU8(ACTION_CANCEL)
        msg:addU32(row.id)
      end)
      if detailWindow and detail and detail.id == row.id then
        closeDetail()
      end
    end)
end

function onWithdrawDetail()
  if detail and detail.canWithdraw then
    confirmWithdraw(detail)
  end
end

function onWithdrawSelected()
  if selectedMine then
    confirmWithdraw(selectedMine)
  end
end

function onOpenSelectedMine()
  if selectedMine then
    openDetail(selectedMine.id)
  end
end

function closeDetail()
  if detailWindow then
    detailWindow:getChildById('confirmOverlay'):hide()
    detailWindow:hide()
  end
end

function openStore()
  if modules.game_store and modules.game_store.buyPoints then
    modules.game_store.buyPoints()
  elseif modules.game_store and modules.game_store.show then
    modules.game_store.show()
  else
    setStatus('The Store is not available right now.', true)
  end
end

function openWebsite()
  local website = Services and Services.website
  if type(website) ~= 'string' or not website:match('^https?://') then
    setStatus('The website address is not configured.', true)
    return
  end
  g_platform.openUrl(website:gsub('/+$', '') .. '/?subtopic=bazaar')
end

-- ---------------------------------------------------------------- lifecycle

function show()
  if not window or not g_game.isOnline() then
    return
  end
  window:show()
  window:raise()
  window:focus()
  selectTab(currentTab)
  requestRules()
end

function hide()
  hideConfirm()
  setStatus('')
  stopTicking()
  if window then
    window:hide()
  end
  closeDetail()
end

function toggle()
  if not window then
    return
  end
  if window:isVisible() then
    hide()
  else
    show()
  end
end

local function registerProtocol()
  -- Unregister first: on relog the previous registration may still be live,
  -- and registerOpcode errors on a duplicate (gamelib/protocolgame.lua).
  ProtocolGame.unregisterOpcode(OPCODE_SEND)
  ProtocolGame.registerOpcode(OPCODE_SEND, onOpcode)
end

local function onGameStart()
  registerProtocol()
end

local function onGameEnd()
  -- The opcode stays registered on purpose: onGameStart is unreliable for
  -- modules loaded this late (see game_bazaar), and the callback is inert
  -- while offline. Everything else resets for the next character.
  hide()
  rules = nil
  detail = nil
  sellPending = false
  selectedMine = nil
  if window then
    local form = child(window, 'sellForm')
    form:getChildById('startPrice'):setText('')
    form:getChildById('buyoutPrice'):setText('')
    form:getChildById('duration'):setText('')
    form:getChildById('description'):setText('')
    form:getChildById('reviewButton'):setEnabled(false)
    onSellEdited()
  end
end

function init()
  g_ui.importStyle('characterbazaar')
  window = g_ui.createWidget('CbWindow', rootWidget)
  window:hide()

  local panel = window:getChildById('browsePanel')
  fillCombo(panel:getChildById('vocationFilter'), VOCATION_OPTIONS, onFilterChanged)
  fillCombo(panel:getChildById('sortMode'), SORT_OPTIONS, onFilterChanged)
  child(window, 'rulesHead'):getChildById('title'):setText('Before you list')
  child(window, 'rulesHead'):getChildById('note'):setText('')
  child(window, 'termsHead'):getChildById('title'):setText('How a sale works')
  child(window, 'termsHead'):getChildById('note'):setText('')
  child(window, 'formHead'):getChildById('title'):setText('Your listing')
  child(window, 'formHead'):getChildById('note'):setText('')
  child(window, 'sellForm'):getChildById('reviewButton'):setEnabled(false)
  selectTab('browse')

  registerProtocol()
  connect(g_game, {onGameStart = onGameStart, onGameEnd = onGameEnd})
end

function terminate()
  disconnect(g_game, {onGameStart = onGameStart, onGameEnd = onGameEnd})
  ProtocolGame.unregisterOpcode(OPCODE_SEND)
  stopTicking()
  if statusEvent then
    removeEvent(statusEvent)
    statusEvent = nil
  end
  if detailStatusEvent then
    removeEvent(detailStatusEvent)
    detailStatusEvent = nil
  end
  if levelFilterEvent then
    removeEvent(levelFilterEvent)
    levelFilterEvent = nil
  end
  if filterWheelEvent then
    removeEvent(filterWheelEvent)
    filterWheelEvent = nil
  end
  if detailWindow then
    detailWindow:destroy()
    detailWindow = nil
  end
  if window then
    window:destroy()
    window = nil
  end
end
