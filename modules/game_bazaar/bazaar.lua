-- Item Bazaar client module.
--
-- Presentation only. Every number shown here comes from the server, and every
-- action is a request the server re-validates -- the client never computes a
-- fee, decides eligibility, or trusts its own idea of a price or deadline.
-- Prices and rules live in src/item_bazaar.cpp; see
-- data/scripts/network/item_bazaar/item_bazaar.lua for the wire format.
--
-- Protocol: one opcode each way with a sub-type byte, matching game_bao.
-- 0x4E/0x4F were verified free in BOTH directions -- notably 0x2A is
-- GameServerSpecialContainer client-side and the client tries Lua opcode
-- handlers before its native switch, so claiming it would have silently
-- broken special containers.

local OPCODE_REQUEST = 0x4E -- client -> server
local OPCODE_SEND = 0x4F    -- server -> client

local ACTION_SYNC = 0x01
local ACTION_BROWSE = 0x02
local ACTION_DETAIL = 0x03
local ACTION_CREATE = 0x04
local ACTION_BID = 0x05
local ACTION_BUYOUT = 0x06
local ACTION_CANCEL = 0x07
local ACTION_RELIST = 0x08
local ACTION_WITHDRAW = 0x09
local ACTION_SELLABLE = 0x0A
local ACTION_HOME = 0x0B

local RESP_CONFIG = 0x01
local RESP_BROWSE = 0x02
local RESP_DETAIL = 0x03
local RESP_MY_AUCTIONS = 0x04
local RESP_INVENTORY = 0x05
local RESP_SELLABLE = 0x06
local RESP_RESULT = 0x07
local RESP_HOME = 0x08

-- Mirrors data/lib/rarity/rarity_stats.lua and the loot channel's colours in
-- data/lib/core/container.lua, so an item reads identically everywhere.
local TIER_NAME = {[1] = 'Rare', [2] = 'Superior', [3] = 'Exalted', [4] = 'Prime', [5] = 'Unrevealed'}
-- Rarity colours, saturated a step beyond the UI greys so the tier word is the
-- one thing that reads as chromatic in the card's identity block.
--
-- Green/blue/purple/crimson (2026-09-07): the step order players already know,
-- replacing a set whose middle two were inverted against that convention. Two
-- of the old values also broke the palette rules in sec.4 of the client UI
-- guide outright -- [5] was #f0c674, the money gold, printed inches from every
-- price on the card, and [4] #f5a072 sat on top of COLOR_URGENT/#e8825c, the
-- time-pressure amber these same cards use. Prime is therefore red rather than
-- gold, far enough past the urgency amber to stay a distinct hue; keep it that
-- way if either value is ever retuned. Unrevealed stays warm yellow to match the
-- sparkle it wears in the world, but NOT at its old #f0c674 -- that was the
-- money gold exactly, printed on the same row as a price. #ffb347 is nudged
-- orange until the two separate on screen; if it is ever retuned, check it
-- against COLOR_MONEY again rather than by eye in isolation. Scarce is
-- moss rather than a true green for the same reason the others moved: rendered
-- against COLOR_POSITIVE it was the same colour, and these cards print a gain
-- and a tier word on one line.
--
-- Mirrored by RARITY_COLOR in data/lib/core/container.lua (loot channel, also
-- dark ground) and the corner marker in src/client/uiitem.cpp.
local TIER_COLOR = {
  [1] = '#9fb86a',
  [2] = '#7cc3e4',
  [3] = '#b98cf0',
  [4] = '#f2554b',
  [5] = '#ffb347',
}

-- Token scale, mirrored from the header comment in bazaar.otui. Kept here so
-- the values the Lua paints at runtime cannot drift from the ones the .otui
-- paints at load.
local COLOR_PRIMARY = '#f6f1e2'
local COLOR_SECONDARY = '#c8c8c8'
local COLOR_TERTIARY = '#9a9a9a'
local COLOR_MONEY = '#f0c674'
local COLOR_MONEY_UNIT = '#9a8449'  -- the "BPC" suffix, dimmed so the number leads
local COLOR_POSITIVE = '#8fd97f'
local COLOR_URGENT = '#e8825c'
local COLOR_WARN = '#e8b964'
-- Paid placement. Brass, which this window no longer spends on anything else
-- now that the active tab is plain light stone.
local COLOR_FEATURED = '#c8b26a'

-- Nothing about the card's geometry is computed here any more; the whole
-- budget lives in bazaar.otui's BazaarCard. Two earlier versions of this file
-- sized panels at runtime and both were wrong on screen, for opposite reasons
-- worth keeping written down:
--
--   * A bonus well stretched between a fixed identity band and the footer left
--     roughly 55px of BARE STONE inside a card whose item had one rolled
--     bonus. A hole in the middle of a card reads as a card that failed to
--     finish drawing.
--   * Sizing that well to its line count fixed the hole and created a second
--     one: the stone simply moved below the well.
--
-- The answer was structural, not arithmetic -- one recessed body holding the
-- whole item, stretched to the controls, so there is no bare stone inside the
-- card to look unfinished. Slack now falls INSIDE a described box, which is
-- where Tibia puts it too.

-- Set while an inline confirmation is on screen; holds what to run if the
-- player accepts. Cleared before the callback fires so a slow action cannot be
-- confirmed twice.
local pendingConfirm = nil
local statusEvent = nil

-- Featured carousel state. slideEvent is the tween in flight, autoEvent the
-- idle rotation; both are removed on hide so a closed window is never still
-- animating in the background.
local featured = {}
local featuredIndex = 1
local slideEvent = nil
local autoEvent = nil
local shineEvent = nil
-- Set when a Featured spotlight is clicked; parseBrowse consumes it to focus
-- and flash the matching card once the page arrives.
local pendingFocusAuction = nil
local focusPulseEvent = nil

-- Browse filter requests. resettingFilters is true while showAuctionInBrowse
-- puts the filters back to default, so each combo change does not send its
-- own browse (it sent up to five, and the first reply consumed
-- pendingFocusAuction with half-reset filters). filterWheelEvent holds the
-- one browse a mouse-wheel spin over a combo sends, 250 ms after the last
-- notch, instead of one per notch.
local resettingFilters = false
local filterWheelChange = false
local filterWheelEvent = nil
local FILTER_WHEEL_DELAY_MS = 250

-- Rarity colours for the BRIGHT parchment spotlight. The window's TIER_COLOR
-- is tuned for dark plates and washes out completely on this ground, so the
-- carousel carries its own darker set rather than reusing values that only
-- work against the forest surfaces.
-- The parchment half of the ladder. These are the same values the website
-- paints (IB_TIERS in www/system/pages/item-bazaar.php) -- the carousel and a
-- bazaar card in a browser are the same bright ground, so they must not drift.
local TIER_COLOR_ON_LIGHT = {
  [1] = '#5f7a3a',
  [2] = '#2a6fae',
  [3] = '#6f45a8',
  [4] = '#a8241f',
  [5] = '#c07a12',
}

-- How long a spotlight holds before the next one rolls in. Raised from 5s
-- once the slab gained the bonus column: five seconds is fine for a name and a
-- price, but not enough to read four rolled bonuses before it moves on.
local FEATURED_INTERVAL = 10000
local SLIDE_STEPS = 14           -- frames in the slide tween
local SLIDE_FRAME = 16           -- ms per frame
local SLIDE_OFFSET = 26          -- px the spotlight drifts while cross-fading

-- Countdown colour. Time pressure is the only thing on a card worth
-- interrupting someone for, so it is the only place the urgency tone is used.
local function timeColor(seconds)
  if seconds <= 300 then
    return COLOR_URGENT
  elseif seconds <= 3600 then
    return COLOR_WARN
  end
  return COLOR_TERTIARY
end

local STATUS_NAME = {[1] = 'Active', [2] = 'Settling', [3] = 'Sold', [4] = 'Expired', [5] = 'Cancelled'}

local window
local detailWindow
local currentTab = 'browse'
local config = {}
local balance = 0
local browseState = {page = 0, pages = 0, total = 0}
local selectedAuction
local selectedSellItem
local selectedMine
local selectedInventory
local characters = {}
local detail
local detailRequested = false

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

-- NOTE: math.floor, not the `//` operator. This client runs Lua 5.1, where
-- `//` is a syntax error -- unlike the server's Lua 5.5, where it is valid.
-- Do not copy integer division straight across from server-side scripts.
local function formatTime(seconds)
  seconds = math.max(0, seconds or 0)
  if seconds >= 86400 then
    return string.format('%dd %dh', math.floor(seconds / 86400), math.floor((seconds % 86400) / 3600))
  elseif seconds >= 3600 then
    return string.format('%dh %dm', math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
  elseif seconds >= 60 then
    return string.format('%dm %ds', math.floor(seconds / 60), seconds % 60)
  end
  return string.format('%ds', seconds)
end

local function tierLabel(tier)
  return TIER_NAME[tier] or ''
end

-- Pulls the rolled bonuses out of the stored rarity description.
-- data/lib/rarity/rarity_stats.lua writes them as bracketed fragments such as
-- "[Crit Chance: +24%]" or "(Attack: +16)"; anything outside a bracket is
-- flavour text and is deliberately dropped here so the card stays scannable.
local function parseBonuses(description)
  local bonuses = {}
  if not description or description == '' then
    return bonuses
  end
  for fragment in description:gmatch('%[([^%]]+)%]') do
    bonuses[#bonuses + 1] = fragment
  end
  for fragment in description:gmatch('%(([^%)]+)%)') do
    bonuses[#bonuses + 1] = fragment
  end
  return bonuses
end

local function send(build)
  local protocolGame = g_game.getProtocolGame()
  if not protocolGame then
    return
  end
  local msg = OutputMessage.create()
  msg:addU8(OPCODE_REQUEST)
  build(msg)
  protocolGame:send(msg)
end

local function requestBrowse()
  local panel = window:getChildById('browsePanel')
  local tierIndex = panel:getChildById('tierFilter'):getCurrentOption()
  local sortIndex = panel:getChildById('sortMode'):getCurrentOption()
  local categoryIndex = panel:getChildById('categoryFilter'):getCurrentOption()
  local buyoutOnly = panel:getChildById('buyoutOnly'):isChecked()

  -- Field order must match the ACTION_BROWSE reader in
  -- data/scripts/network/item_bazaar/item_bazaar.lua. The trailing field was a
  -- search string; it is now the category byte.
  send(function(msg)
    msg:addU8(ACTION_BROWSE)
    msg:addU16(browseState.page)
    msg:addU8(sortIndex and (sortIndex.data or 0) or 0)
    msg:addU8(tierIndex and (tierIndex.data or 0) or 0)
    msg:addU8(buyoutOnly and 1 or 0)
    msg:addU8(categoryIndex and (categoryIndex.data or 0) or 0)
  end)
end

local function updateBalance()
  -- The balance plate holds a 'value' label and a coin icon, matching the
  -- Store's widget, so the number goes in the label rather than on the panel.
  window:getChildById('balance'):getChildById('value'):setText(comma(balance))
end

local function clearList(panel)
  panel:destroyChildren()
end

-- Builds one row. `spec` carries only what the server sent; nothing is
-- derived locally beyond formatting.
local function addRow(panel, spec)
  local row = g_ui.createWidget('BazaarRow', panel)
  row:setId('row' .. tostring(spec.id))

  local item = Item.create(spec.itemtype)
  if item and spec.tier and spec.tier > 0 and item.setTier then
    item:setTier(spec.tier)
  end
  row:getChildById('item'):setItem(item)

  local nameLabel = row:getChildById('name')
  local tierName = tierLabel(spec.tier)
  if tierName ~= '' then
    nameLabel:setColoredText({tierName .. ' ', TIER_COLOR[spec.tier] or COLOR_SECONDARY, spec.name, COLOR_PRIMARY})
  else
    nameLabel:setText(spec.name)
  end

  row:getChildById('subtitle'):setText(spec.subtitle or '')
  row:getChildById('price'):setText(spec.price or '')
  row:getChildById('timeLeft'):setText(spec.timeLeft or '')
  row.data = spec
  return row
end

-- ---------------------------------------------------------------- parsing

local function parseConfig(msg)
  config.enabled = msg:getU8() ~= 0
  config.maxActiveAuctions = msg:getU16()
  config.minHours = msg:getU16()
  config.maxHours = msg:getU16()
  config.defaultHours = msg:getU16()
  config.saleFeePercent = msg:getU8()
  config.minSaleFee = msg:getU32()
  config.promotionFee = msg:getU32()
  config.antiSnipeThreshold = msg:getU16()
  balance = msg:getU32()

  updateBalance()

  local form = window:getChildById('sellPanel'):getChildById('sellForm')
  form:getChildById('hours'):setText(tostring(config.defaultHours))
  form:getChildById('promote'):setText(string.format('Promote in Item Bazaar channel (%d BPC)', config.promotionFee))
  form:getChildById('hoursLabel'):setTooltip(string.format('Between %d and %d hours', config.minHours, config.maxHours))
  form:getChildById('sellHint'):setText(string.format(
    'Sale fee is %d%% (minimum %d BPC) and is taken from your proceeds when the item sells.',
    config.saleFeePercent, config.minSaleFee))

  -- The relist form takes the same server-supplied defaults; it creates an
  -- auction through the same rules, so it must not present different ones.
  local relist = window:getChildById('inventoryPanel'):getChildById('inventoryForm')
  relist:getChildById('relistHours'):setText(tostring(config.defaultHours))
  relist:getChildById('relistPromote'):setText(
    string.format('Promote in Item Bazaar channel (%d BPC)', config.promotionFee))
  relist:getChildById('relistHoursLabel'):setTooltip(
    string.format('Between %d and %d hours', config.minHours, config.maxHours))
end

-- Builds one browse card. Same information architecture as the website
-- card -- sprite hero, rarity, name, class, bonuses, then price and the
-- bid/buy controls -- so a player can judge and buy without opening a detail
-- view. Styling is native client rather than a copy of the web look.
local function addCard(panel, spec)
  local card = g_ui.createWidget('BazaarCard', panel)
  card:setId('card' .. tostring(spec.id))
  card.data = spec

  -- The header band is gone: these two sit straight on the card's stone now,
  -- so they are direct children rather than children of a 'cap' panel.
  local capLeft = card:getChildById('capLeft')
  capLeft:setText(spec.promoted and 'PROMOTED' or ('#' .. spec.id))
  capLeft:setColor(spec.promoted and COLOR_FEATURED or COLOR_TERTIARY)

  local capTime = card:getChildById('capRight')
  capTime:setText(formatTime(spec.secondsLeft))
  capTime:setColor(timeColor(spec.secondsLeft))

  -- getChildById only walks DIRECT children, so the sprite and identity labels
  -- are reached through the fixed-height 'head' panel that holds them (that
  -- panel is what keeps the bonus text starting at the same y on every card).
  local head = card:getChildById('head')

  local item = Item.create(spec.itemtype)
  if item and spec.tier > 0 and item.setTier then
    item:setTier(spec.tier)
  end
  head:getChildById('item'):setItem(item)

  local tierWidget = head:getChildById('tier')
  local tierName = tierLabel(spec.tier)
  tierWidget:setText(tierName ~= '' and tierName:upper() or '')
  tierWidget:setColor(TIER_COLOR[spec.tier] or '#dddddd')

  head:getChildById('name'):setText(spec.name)
  head:getChildById('itemClass'):setText(spec.itemClass > 0 and ('Class ' .. spec.itemClass) or '')

  local bonusWidget = card:getChildById('bonuses')
  if spec.tier == 5 then
    bonusWidget:setColor(COLOR_MONEY)
    bonusWidget:setText('Unrevealed - identify it to roll what it holds.')
  elseif #spec.bonuses > 0 then
    bonusWidget:setColor(COLOR_POSITIVE)
    bonusWidget:setText(table.concat(spec.bonuses, '\n'))
  else
    bonusWidget:setColor(COLOR_TERTIARY)
    bonusWidget:setText('No additional bonuses.')
  end

  -- The money line lives INSIDE the body well now, under its own rule, so it
  -- is reached through priceRow rather than through foot.
  local priceRow = card:getChildById('priceRow')
  local current = spec.currentBid > 0 and spec.currentBid or spec.startPrice
  -- The amount leads and the unit recedes: at a glance the eye should catch
  -- the number, not three identical gold "BPC"s down the column.
  -- Number only: the coin beside it names the currency, matching how the
  -- balance plate and the Store both present an amount.
  local priceLabel = priceRow:getChildById('price')
  priceLabel:setText(comma(current))
  priceRow:getChildById('bidCount'):setText(string.format('%d bid%s', spec.bids, spec.bids == 1 and '' or 's'))

  -- (!) The amount and its coin are centred as ONE unit, which no static
  -- anchor can express: priceGroup is an invisible box the pair fills exactly,
  -- and it is what carries anchors.horizontalCenter. Centring the label alone
  -- would centre the number and leave the coin hanging past the middle.
  --
  -- getTextSize() rather than getWidth() on purpose. The label wraps nothing,
  -- so its draw text is its source text and the measurement is valid on this
  -- frame -- unlike a text-wrap label, whose size is a lie until its rect is.
  priceRow:getChildById('priceGroup')
    :setWidth(priceLabel:getTextSize().width + 5 + 12)

  local foot = card:getChildById('foot')

  local bidField = foot:getChildById('bidAmount')
  bidField:setText(tostring(spec.minBid))

  -- Reached through 'foot' for the same reason as the head widgets:
  -- getChildById walks direct children only.
  local bidButton = foot:getChildById('bidButton')
  bidButton.onClick = function()
    local amount = tonumber(bidField:getText())
    if not amount or amount <= 0 then
      setStatus('Enter a whole number of BPC.', true)
      return
    end
    modules.game_bazaar.confirmBid(spec, amount)
  end

  -- (!) A listing with no buyout HIDES the button rather than showing a dead
  -- full-width bar reading "No buyout". Four cards in nine were spending their
  -- best real estate saying what is not on offer.
  --
  -- The footer keeps its height either way. Shrinking it was tried and made
  -- things worse: the 23px went to the body well, which did not need it, and
  -- the bid rows of a row of cards stopped lining up with each other. Left at
  -- a constant height the empty band sits at the card's bottom EDGE, where it
  -- reads as padding, and every card in a row rules off at the same y.
  local buyButton = foot:getChildById('buyButton')
  if spec.buyout > 0 then
    buyButton:setText(string.format('Buy Now - %s BPC', comma(spec.buyout)))
    buyButton:setEnabled(true)
    buyButton:show()
    buyButton.onClick = function()
      modules.game_bazaar.confirmBuyout(spec)
    end
  else
    buyButton:hide()
  end

  card.onClick = function(self)
    selectedAuction = self.data.id
    self:focus()
  end
  card.onDoubleClick = function(self)
    modules.game_bazaar.openDetail(self.data.id)
  end
  return card
end

local function parseBrowse(msg)
  browseState.page = msg:getU16()
  browseState.total = msg:getU32()
  local count = msg:getU16()

  local panel = window:getChildById('browsePanel')
  local list = panel:getChildById('list')
  clearList(list)

  for _ = 1, count do
    local spec = {}
    spec.id = msg:getU32()
    spec.itemtype = msg:getU16()
    spec.tier = msg:getU8()
    spec.itemClass = msg:getU8()
    spec.name = msg:getString()
    spec.description = msg:getString()
    spec.startPrice = msg:getU32()
    spec.currentBid = msg:getU32()
    spec.buyout = msg:getU32()
    spec.bids = msg:getU16()
    spec.secondsLeft = msg:getU32()
    spec.promoted = msg:getU8() ~= 0

    spec.bonuses = parseBonuses(spec.description)
    -- Prefilled for one-tap bidding; the server recomputes the real minimum
    -- and rejects anything short, so this is convenience only.
    spec.minBid = spec.currentBid > 0 and (spec.currentBid + 1) or spec.startPrice

    local card = addCard(list, spec)
    -- Consume the pending jump from a Featured spotlight, if this is it.
    if pendingFocusAuction and spec.id == pendingFocusAuction then
      pendingFocusAuction = nil
      card:focus()
      pulseCard(card)
      setStatus(string.format('Showing auction #%d from Featured.', spec.id), false)
    end
  end

  local pageSize = 25
  browseState.pages = math.max(1, math.ceil(browseState.total / pageSize))
  panel:getChildById('pageInfo'):setText(string.format('%d listing%s  -  page %d of %d', browseState.total,
    browseState.total == 1 and '' or 's', browseState.page + 1, browseState.pages))
  panel:getChildById('pagePrev'):setEnabled(browseState.page > 0)
  panel:getChildById('pageNext'):setEnabled(browseState.page + 1 < browseState.pages)

  -- The jump target was not on this page. Clear it either way: a request left
  -- pending would latch onto whichever browse happened to contain that id next.
  if pendingFocusAuction then
    setStatus(string.format('Auction #%d is no longer listed.', pendingFocusAuction), true)
    pendingFocusAuction = nil
  end
end

local function parseDetail(msg)
  detail = {}
  detail.id = msg:getU32()
  detail.itemtype = msg:getU16()
  detail.tier = msg:getU8()
  detail.name = msg:getString()
  detail.startPrice = msg:getU32()
  detail.currentBid = msg:getU32()
  detail.buyout = msg:getU32()
  detail.minimumNextBid = msg:getU32()
  detail.bids = msg:getU16()
  detail.secondsLeft = msg:getU32()
  detail.status = msg:getU8()
  detail.promoted = msg:getU8() ~= 0
  detail.isSeller = msg:getU8() ~= 0
  detail.isHighBidder = msg:getU8() ~= 0
  detail.projectedFee = msg:getU32()

  detail.history = {}
  local historyCount = msg:getU16()
  for _ = 1, historyCount do
    local amount = msg:getU32()
    local ago = msg:getU32()
    detail.history[#detail.history + 1] = {amount = amount, ago = ago}
  end

  if not detailWindow then
    detailWindow = g_ui.createWidget('BazaarDetailWindow', rootWidget)
  end

  -- Show only if this update answers an explicit request, or the window is
  -- already open and simply needs refreshing.
  if detailRequested or detailWindow:isVisible() then
    detailWindow:show()
    detailWindow:raise()
    detailWindow:focus()
  end
  detailRequested = false

  local item = Item.create(detail.itemtype)
  if item and detail.tier > 0 and item.setTier then
    item:setTier(detail.tier)
  end
  detailWindow:getChildById('item'):setItem(item)

  local tierName = tierLabel(detail.tier)
  local nameLabel = detailWindow:getChildById('name')
  if tierName ~= '' then
    nameLabel:setColoredText({tierName .. ' ', TIER_COLOR[detail.tier] or '#dddddd', detail.name, '#dddddd'})
  else
    nameLabel:setText(detail.name)
  end
  detailWindow:getChildById('subtitle'):setText(string.format('Auction #%d  -  %s', detail.id,
    STATUS_NAME[detail.status] or '?'))

  local lines = {
    string.format('Starting bid:  %s BPC', comma(detail.startPrice)),
    detail.currentBid > 0 and string.format('Current bid:   %s BPC  (%d bid%s)', comma(detail.currentBid), detail.bids,
      detail.bids == 1 and '' or 's') or 'Current bid:   none yet',
    detail.buyout > 0 and string.format('Buyout:        %s BPC', comma(detail.buyout)) or 'Buyout:        not offered',
    string.format('Time left:     %s', formatTime(detail.secondsLeft)),
    string.format('Minimum bid:   %s BPC', comma(detail.minimumNextBid)),
  }
  detailWindow:getChildById('info'):getChildById('details'):setText(table.concat(lines, '\n'))

  local bidField = detailWindow:getChildById('bidAmount')
  bidField:setText(tostring(detail.minimumNextBid))

  local canAct = detail.status == 1 and not detail.isSeller
  detailWindow:getChildById('bidButton'):setEnabled(canAct)
  detailWindow:getChildById('buyoutButton'):setEnabled(canAct and detail.buyout > 0)

  local hint
  if detail.isSeller then
    hint = 'This is your own auction.'
  elseif detail.status ~= 1 then
    hint = 'This auction has ended.'
  elseif detail.isHighBidder then
    hint = 'You currently hold the highest bid.'
  elseif detail.buyout > 0 then
    hint = string.format('A bid must stay under the %s BPC buyout.', comma(detail.buyout))
  else
    hint = 'Bids are held in escrow and refunded if you are outbid.'
  end
  detailWindow:getChildById('hint'):setText(hint)
end

local function parseMyAuctions(msg)
  local count = msg:getU16()
  local list = window:getChildById('minePanel'):getChildById('mineList')
  clearList(list)
  selectedMine = nil

  for _ = 1, count do
    local spec = {}
    spec.id = msg:getU32()
    spec.itemtype = msg:getU16()
    spec.tier = msg:getU8()
    spec.name = msg:getString()
    spec.startPrice = msg:getU32()
    spec.currentBid = msg:getU32()
    spec.buyout = msg:getU32()
    spec.bids = msg:getU16()
    spec.secondsLeft = msg:getU32()
    spec.status = msg:getU8()
    spec.finalPrice = msg:getU32()
    spec.fee = msg:getU32()

    if spec.status == 3 then
      spec.price = string.format('%s BPC', comma(spec.finalPrice))
      spec.subtitle = string.format('Sold  -  fee %s BPC  -  you received %s BPC', comma(spec.fee),
        comma(spec.finalPrice - spec.fee))
      spec.timeLeft = ''
    else
      local current = spec.currentBid > 0 and spec.currentBid or spec.startPrice
      spec.price = string.format('%s BPC', comma(current))
      spec.subtitle = string.format('%s  -  %d bid%s', STATUS_NAME[spec.status] or '?', spec.bids,
        spec.bids == 1 and '' or 's')
      spec.timeLeft = spec.status == 1 and formatTime(spec.secondsLeft) or ''
    end

    local row = addRow(list, spec)
    row.onClick = function(self)
      selectedMine = self.data
      self:focus()
      -- Cancelling is only legal before the first bid; the server enforces
      -- this too, the button state is just so it is obvious why.
      window:getChildById('minePanel'):getChildById('mineCancel')
        :setEnabled(self.data.status == 1 and self.data.bids == 0)
    end
    row.onDoubleClick = function(self)
      modules.game_bazaar.openDetail(self.data.id)
    end
  end

  window:getChildById('minePanel'):getChildById('mineCancel'):setEnabled(false)
end

-- One place that turns a row into the selection: the highlight, the form
-- caption and selectedInventory always move together, whether the player
-- clicked the row or the list picked it after a refresh.
local function selectInventoryRow(row)
  selectedInventory = row.data
  window:getChildById('inventoryPanel'):getChildById('inventoryForm')
    :getChildById('inventorySelection'):setText(
      string.format('%s %s', tierLabel(row.data.tier), row.data.name))
  row:focus()
end

local function parseInventory(msg)
  local count = msg:getU16()
  local list = window:getChildById('inventoryPanel'):getChildById('inventoryList')
  clearList(list)
  selectedInventory = nil
  window:getChildById('inventoryPanel'):getChildById('inventoryForm')
    :getChildById('inventorySelection'):setText(tr('No item selected.'))

  local firstRow
  for _ = 1, count do
    local spec = {}
    spec.id = msg:getU32()
    spec.itemtype = msg:getU16()
    spec.tier = msg:getU8()
    spec.name = msg:getString()
    spec.subtitle = 'In your Bazaar Inventory'
    spec.price = ''
    spec.timeLeft = ''

    local row = addRow(list, spec)
    row.onClick = function(self)
      selectInventoryRow(self)
    end
    firstRow = firstRow or row
  end

  -- The panel focuses its first row on its own every time the list is rebuilt
  -- (after a relist or a withdraw), so that row already looks selected. Adopt
  -- it as the real selection too, otherwise List Again rejects the very row
  -- the window is highlighting and the player has to click it again to relist.
  if firstRow then
    selectInventoryRow(firstRow)
  end

  characters = {}
  local characterCount = msg:getU16()
  local combo = window:getChildById('inventoryPanel'):getChildById('inventoryForm')
    :getChildById('character')
  combo:clearOptions()
  for _ = 1, characterCount do
    local id = msg:getU32()
    local name = msg:getString()
    characters[#characters + 1] = {id = id, name = name}
    combo:addOption(name, id)
  end
end

local function parseSellable(msg)
  local count = msg:getU16()
  local list = window:getChildById('sellPanel'):getChildById('sellList')
  clearList(list)
  selectedSellItem = nil
  window:getChildById('sellPanel'):getChildById('sellForm'):getChildById('sellSelection')
    :setText('No item selected.')

  for _ = 1, count do
    local spec = {}
    spec.uid = msg:getString()
    spec.itemtype = msg:getU16()
    spec.tier = msg:getU8()
    spec.name = msg:getString()
    spec.id = spec.uid
    spec.subtitle = 'Carried'
    spec.price = ''
    spec.timeLeft = ''

    local row = addRow(list, spec)
    row.onClick = function(self)
      selectedSellItem = self.data
      self:focus()
      window:getChildById('sellPanel'):getChildById('sellForm'):getChildById('sellSelection')
        :setText(string.format('%s %s', tierLabel(self.data.tier), self.data.name))
    end
  end
end

-- Landing screen. Reads three fixed-order sections written by sendHome in
-- data/scripts/network/item_bazaar/item_bazaar.lua: promoted, recommended,
-- recently sold.
local function readHomeSection(msg)
  local entries = {}
  local count = msg:getU16()
  for _ = 1, count do
    local spec = {}
    spec.id = msg:getU32()
    spec.itemtype = msg:getU16()
    spec.tier = msg:getU8()
    spec.itemClass = msg:getU8()
    spec.name = msg:getString()
    spec.description = msg:getString()
    spec.bonuses = parseBonuses(spec.description)
    spec.price = msg:getU32()
    spec.seconds = msg:getU32()
    spec.bids = msg:getU16()
    entries[#entries + 1] = spec
  end
  return entries
end

local function addTile(panel, spec, metaText)
  local tile = g_ui.createWidget('BazaarTile', panel)
  tile.data = spec

  local item = Item.create(spec.itemtype)
  if item and spec.tier > 0 and item.setTier then
    item:setTier(spec.tier)
  end
  tile:getChildById('item'):setItem(item)

  local tierWidget = tile:getChildById('tier')
  local tierName = tierLabel(spec.tier)
  local classText = spec.itemClass > 0 and ('  Class ' .. spec.itemClass) or ''
  tierWidget:setText((tierName ~= '' and tierName:upper() or '') .. classText)
  tierWidget:setColor(TIER_COLOR[spec.tier] or COLOR_SECONDARY)

  tile:getChildById('name'):setText(spec.name)
  tile:getChildById('price'):setText(comma(spec.price))
  tile:getChildById('meta'):setText(metaText)

  -- A tile is a pointer, not a purchase: opening the real card is the only
  -- place a bid or buyout can be made.
  tile.onClick = function(self)
    self:focus()
  end
  tile.onDoubleClick = function(self)
    modules.game_bazaar.openDetail(self.data.id)
  end
  return tile
end

-- Stops every carousel timer. Called before rebuilding and on hide, so a
-- rebuilt or closed carousel can never leave an orphan tween mutating widgets
-- that no longer exist.
local function stopFeaturedTimers()
  for _, ev in ipairs({slideEvent, autoEvent, shineEvent}) do
    if ev then
      removeEvent(ev)
    end
  end
  slideEvent, autoEvent, shineEvent = nil, nil, nil
end

local function featuredStage()
  if not window then
    return nil
  end
  return window:getChildById('homePanel'):getChildById('featuredStage')
end

-- One sweep of light across the spotlight that just arrived. Purely
-- decorative, and deliberately one-shot rather than looping: a shine that
-- never stops reads as a broken widget, not as polish.
local function playShine(spotlight)
  if shineEvent then
    removeEvent(shineEvent)
    shineEvent = nil
  end
  local shine = spotlight:getChildById('shine')
  -- Purely decorative, so it is the first thing to skip when nobody is
  -- looking: no widget, or a hidden one, means no timer at all.
  if not shine or not spotlight:isVisible() then
    return
  end
  -- Sweeps a fixed distance rather than the stage's measured width: the
  -- overshoot is hidden by the stage's clipping, and it keeps the effect free
  -- of any layout dependency.
  local step, steps = 0, 26
  shine:setMarginLeft(-60)
  shine:setVisible(true)
  shineEvent = cycleEvent(function()
    step = step + 1
    shine:setMarginLeft(math.floor(-60 + 1000 * (step / steps)))
    if step >= steps then
      shine:setVisible(false)
      if shineEvent then
        removeEvent(shineEvent)
        shineEvent = nil
      end
    end
  end, SLIDE_FRAME)
end

-- Populates the single spotlight widget from one entry. Nothing is created
-- here: the widget is declared in bazaar.otui anchored to fill the stage, so
-- it renders whether or not the panel has been measured yet.
local function paintSpotlight(spec)
  local stage = featuredStage()
  if not stage or not spec then
    return
  end
  local spot = stage:getChildById('spotlight')
  spot.data = spec

  local item = Item.create(spec.itemtype)
  if item and spec.tier > 0 and item.setTier then
    item:setTier(spec.tier)
  end
  spot:getChildById('item'):setItem(item)

  -- Rarity and class are two separate chips: the rarity chip is tinted by
  -- tier, the class chip stays neutral, so they cannot be mistaken for one
  -- another the way a single run of text was.
  local tierColour = TIER_COLOR_ON_LIGHT[spec.tier] or '#6a6a6a'
  local tierWidget = spot:getChildById('tier')
  local tierName = tierLabel(spec.tier)
  tierWidget:setText(tierName ~= '' and tierName:upper() or '?')
  tierWidget:setColor(tierColour)
  tierWidget:setBorderColor(tierColour)

  local classWidget = spot:getChildById('itemClass')
  classWidget:setText(spec.itemClass > 0 and ('CLASS ' .. spec.itemClass) or 'UNRATED')
  classWidget:setVisible(true)

  spot:getChildById('name'):setText(spec.name)
  spot:getChildById('bidline'):setText(spec.bids > 0
    and string.format('%d bid%s so far', spec.bids, spec.bids == 1 and '' or 's')
    or 'No bids yet -- open at the starting price')

  -- The bonus column. An Unrevealed item has nothing rolled yet and says so
  -- rather than showing an empty panel.
  local bonusWidget = spot:getChildById('itemBonuses')
  if spec.tier == 5 then
    bonusWidget:setColor('#8a6a12')
    bonusWidget:setText('Unrevealed. Reveal it to see what it holds.')
  elseif #spec.bonuses > 0 then
    bonusWidget:setColor('#2c6b34')
    bonusWidget:setText(table.concat(spec.bonuses, '\n'))
  else
    bonusWidget:setColor('#6b6553')
    bonusWidget:setText('No additional bonuses.')
  end
  spot:getChildById('price'):setText(comma(spec.price))
  spot:getChildById('ending'):setText('Ends in ' .. formatTime(spec.seconds))
  spot:setVisible(true)
end

-- Shows the position only when there is somewhere to rotate to; a lone
-- promoted item says nothing rather than '1 / 1'.
local function updateFeaturedCount()
  window:getChildById('homePanel'):getChildById('featuredCount'):setText(
    #featured > 1 and string.format('%d / %d', featuredIndex, #featured) or '')
end

-- Advances to an entry. The transition fades the spotlight out with a small
-- rightward drift, swaps its contents, then brings it back from the left --
-- which reads as a slide without needing to know how wide the stage is.
local function slideFeaturedTo(index, animate)
  local stage = featuredStage()
  if not stage or #featured == 0 then
    return
  end
  if index < 1 then index = #featured end
  if index > #featured then index = 1 end

  featuredIndex = index
  updateFeaturedCount()

  local spot = stage:getChildById('spotlight')
  if slideEvent then
    removeEvent(slideEvent)
    slideEvent = nil
  end

  -- An off-screen transition is 28 frames of pure waste. Land on the new
  -- entry immediately instead; the next visible advance animates normally.
  if animate and not stage:isVisible() then
    animate = false
  end

  if not animate then
    spot:setMarginLeft(0)
    spot:setOpacity(1)
    paintSpotlight(featured[index])
    playShine(spot)
    return
  end

  local step = 0
  slideEvent = cycleEvent(function()
    step = step + 1
    if step <= SLIDE_STEPS then
      -- Out: drift right, fade down.
      local t = step / SLIDE_STEPS
      spot:setMarginLeft(math.floor(t * SLIDE_OFFSET))
      spot:setOpacity(1 - t)
      if step == SLIDE_STEPS then
        paintSpotlight(featured[index])
      end
    else
      -- In: arrive from the left, fade up.
      local t = (step - SLIDE_STEPS) / SLIDE_STEPS
      local eased = 1 - (1 - t) * (1 - t)
      spot:setMarginLeft(math.floor(-SLIDE_OFFSET * (1 - eased)))
      spot:setOpacity(eased)
      if step >= SLIDE_STEPS * 2 then
        spot:setMarginLeft(0)
        spot:setOpacity(1)
        removeEvent(slideEvent)
        slideEvent = nil
        playShine(spot)
      end
    end
  end, SLIDE_FRAME)
end

local function startFeaturedAuto()
  if autoEvent then
    removeEvent(autoEvent)
    autoEvent = nil
  end
  if #featured > 1 then
    autoEvent = cycleEvent(function()
      slideFeaturedTo(featuredIndex + 1, true)
    end, FEATURED_INTERVAL)
  end
end

local function buildFeatured(entries)
  local stage = featuredStage()
  if not stage then
    return
  end
  stopFeaturedTimers()

  featured = entries
  featuredIndex = 1

  local spot = stage:getChildById('spotlight')
  spot:setVisible(#entries > 0)
  stage:getChildById('promotedEmpty'):setVisible(#entries == 0)
  updateFeaturedCount()
  if #entries == 0 then
    return
  end

  local jump = function()
    local current = featured[featuredIndex]
    if current then
      modules.game_bazaar.showAuctionInBrowse(current.id)
    end
  end
  spot:getChildById('cta').onClick = jump
  spot.onClick = jump

  slideFeaturedTo(1, false)
  startFeaturedAuto()
end

local function parseHome(msg)
  local vocationName = msg:getString()
  local promoted = readHomeSection(msg)
  local recommended = readHomeSection(msg)
  local sold = readHomeSection(msg)

  -- Hunting board. The flag says whether these are a real 24h window or the
  -- all-time fallback; the heading reports which, rather than claiming a
  -- window the server cannot yet back up.
  local huntWindowed = msg:getU8() ~= 0
  local hunted = {}
  local huntCount = msg:getU16()
  for _ = 1, huntCount do
    local name = msg:getString()
    hunted[#hunted + 1] = {name = name, kills = msg:getU32()}
  end

  local homePanel = window:getChildById('homePanel')

  homePanel:getChildById('promotedHead'):getChildById('title'):setText('Featured')
  homePanel:getChildById('promotedHead'):getChildById('note'):setText(
    #promoted > 0 and 'Hand-picked by their sellers' or '')
  buildFeatured(promoted)

  -- Headings are plain white now. They used to carry a per-section hue -- gold,
  -- green, brass, ember -- plus a matching coloured bar, which meant four or
  -- five competing accents on one screen and none of them meaning anything.
  -- Colour is reserved for money, gains and urgency; structure is white.
  homePanel:getChildById('recommendHead'):getChildById('title'):setText('Suited to your character')
  homePanel:getChildById('recommendHead'):getChildById('note'):setText(
    vocationName ~= '' and ('Matched to ' .. vocationName) or '')
  local recommendRow = homePanel:getChildById('recommendRow')
  clearList(recommendRow)
  for _, spec in ipairs(recommended) do
    addTile(recommendRow, spec, formatTime(spec.seconds) .. ' left')
  end
  homePanel:getChildById('recommendEmpty'):setVisible(#recommended == 0)

  homePanel:getChildById('soldHead'):getChildById('title'):setText('Recently sold')
  homePanel:getChildById('soldHead'):getChildById('note'):setText(
    #sold > 0 and 'What the market has been paying' or 'Nothing has sold yet')
  -- "Hunting Trends", and no note beside it. The old heading was a question in
  -- a 300px column with a qualifier right-aligned against it, and the two ran
  -- straight through each other. The window is the qualifier: this board is
  -- what the server has seen, and a player reading a top-ten of monsters does
  -- not need to be told which minutes it covers before they can read it.
  homePanel:getChildById('huntHead'):getChildById('title'):setText('Hunting Trends')
  homePanel:getChildById('huntHead'):getChildById('note'):setText('')

  local huntList = homePanel:getChildById('huntBoard'):getChildById('huntList')
  clearList(huntList)
  for i, entry in ipairs(hunted) do
    local huntRow = g_ui.createWidget('BazaarHuntRow', huntList)
    huntRow:getChildById('rank'):setText(i .. '.')
    huntRow:getChildById('name'):setText(entry.name)
    huntRow:getChildById('kills'):setText(comma(entry.kills))
  end
  homePanel:getChildById('huntBoard'):getChildById('huntEmpty'):setVisible(#hunted == 0)

  local soldList = homePanel:getChildById('soldList')
  clearList(soldList)
  for _, spec in ipairs(sold) do
    local row = addRow(soldList, {
      id = spec.id,
      itemtype = spec.itemtype,
      tier = spec.tier,
      name = spec.name,
      subtitle = spec.bids > 0 and string.format('%d bid%s', spec.bids, spec.bids == 1 and '' or 's')
        or 'Bought outright',
      price = comma(spec.price),
      timeLeft = formatTime(spec.seconds) .. ' ago',
    })
    row:getChildById('price'):setColor(COLOR_MONEY)
  end
end

local function parseResult(msg)
  local success = msg:getU8() ~= 0
  local text = msg:getString()
  balance = msg:getU32()
  updateBalance()

  if success and currentTab == 'browse' then
    requestBrowse()
  end

  if text ~= '' then
    if success then
      setStatus(text, false)
    else
      setStatus(text, true)
    end
  end
end

local function onBazaarOpcode(protocol, msg)
  local responseType = msg:getU8()
  if responseType == RESP_CONFIG then
    parseConfig(msg)
  elseif responseType == RESP_BROWSE then
    parseBrowse(msg)
  elseif responseType == RESP_DETAIL then
    parseDetail(msg)
  elseif responseType == RESP_MY_AUCTIONS then
    parseMyAuctions(msg)
  elseif responseType == RESP_INVENTORY then
    parseInventory(msg)
  elseif responseType == RESP_SELLABLE then
    parseSellable(msg)
  elseif responseType == RESP_HOME then
    parseHome(msg)
  elseif responseType == RESP_RESULT then
    parseResult(msg)
  end
  return true
end

-- ---------------------------------------------------------------- actions

function selectTab(tab)
  currentTab = tab

  -- Pause the carousel the moment its tab is not the visible one. Nothing on
  -- the landing screen is worth a frame of work while Browse is on top, and
  -- the tween touches widget geometry every 16ms while it runs.
  if tab ~= 'home' then
    stopFeaturedTimers()
  end

  window:getChildById('homePanel'):setVisible(tab == 'home')
  window:getChildById('browsePanel'):setVisible(tab == 'browse')
  window:getChildById('sellPanel'):setVisible(tab == 'sell')
  window:getChildById('minePanel'):setVisible(tab == 'mine')
  window:getChildById('inventoryPanel'):setVisible(tab == 'inventory')

  window:getChildById('tabHome'):setChecked(tab == 'home')
  window:getChildById('tabBrowse'):setChecked(tab == 'browse')
  window:getChildById('tabSell'):setChecked(tab == 'sell')
  window:getChildById('tabMine'):setChecked(tab == 'mine')
  window:getChildById('tabInventory'):setChecked(tab == 'inventory')

  if tab == 'sell' then
    send(function(msg) msg:addU8(ACTION_SELLABLE) end)
  elseif tab == 'home' then
    -- Refetched on every visit: "recently sold" and the countdowns are only
    -- worth showing if they are current. The reply rebuilds the carousel,
    -- which restarts the rotation that was paused on the way out.
    send(function(msg) msg:addU8(ACTION_HOME) end)
  end
end

function onFilterChanged()
  if resettingFilters then
    return
  end
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

-- Marks a combo's mouse-wheel changes so onFilterChanged waits for the spin
-- to stop. Clicking an option still sends at once.
local function debounceComboWheel(combo)
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

function changePage(delta)
  local target = browseState.page + delta
  if target < 0 or target >= browseState.pages then
    return
  end
  browseState.page = target
  requestBrowse()
end

function refresh()
  send(function(msg) msg:addU8(ACTION_SYNC) end)
  if currentTab == 'sell' then
    send(function(msg) msg:addU8(ACTION_SELLABLE) end)
  end
  -- No separate ACTION_HOME here: the server answers SYNC with the landing
  -- screen too. Sending both back to back tripped the 400ms per-player packet
  -- cooldown and the second was dropped, which is why Market rendered empty.
end

-- Card-level bid. Confirmed before sending because a bid escrows real coins;
-- the server re-validates the amount, the minimum and the buyout ceiling
-- regardless of what the card prefilled.
function confirmBid(spec, amount)
  showConfirm(tr('Confirm Bid'), string.format(
    'Place a bid of %s BPC on %s %s?\n\nYour coins are held in escrow and refunded automatically if you are outbid.',
    comma(amount), tierLabel(spec.tier), spec.name), tr('Place Bid'), function()
      send(function(msg)
        msg:addU8(ACTION_BID)
        msg:addU32(spec.id)
        msg:addU32(amount)
      end)
    end)
end

function confirmBuyout(spec)
  showConfirm(tr('Confirm Buyout'), string.format('Buy %s %s immediately for %s BPC?',
    tierLabel(spec.tier), spec.name, comma(spec.buyout)), tr('Buy Now'), function()
      send(function(msg)
        msg:addU8(ACTION_BUYOUT)
        msg:addU32(spec.id)
      end)
    end)
end

function openDetail(auctionId)
  detailRequested = true
  send(function(msg)
    msg:addU8(ACTION_DETAIL)
    msg:addU32(auctionId)
  end)
end

function closeDetail()
  if detailWindow then
    detailWindow:hide()
  end
end

function onPlaceBid()
  if not detail then
    return
  end
  local amount = tonumber(detailWindow:getChildById('bidAmount'):getText())
  if not amount or amount <= 0 then
    setStatus('Enter a whole number of BPC Coins.', true)
    return
  end

  local auctionId = detail.id
  showConfirm(tr('Confirm Bid'), string.format('Place a bid of %s BPC on %s %s?\n\nYour coins are held in ' ..
    'escrow and refunded automatically if you are outbid.', comma(amount), tierLabel(detail.tier), detail.name),
    tr('Place Bid'), function()
      send(function(msg)
        msg:addU8(ACTION_BID)
        msg:addU32(auctionId)
        msg:addU32(amount)
      end)
    end)
end

function onBuyout()
  if not detail or detail.buyout <= 0 then
    return
  end
  local auctionId = detail.id
  local fee = detail.projectedFee
  showConfirm(tr('Confirm Buyout'), string.format('Buy %s %s immediately for %s BPC?', tierLabel(detail.tier),
    detail.name, comma(detail.buyout)), tr('Buy Now'), function()
      send(function(msg)
        msg:addU8(ACTION_BUYOUT)
        msg:addU32(auctionId)
      end)
      closeDetail()
    end)
end

function onCreateAuction()
  if not selectedSellItem then
    setStatus('Select an item to list first.', true)
    return
  end

  local form = window:getChildById('sellPanel'):getChildById('sellForm')
  local startPrice = tonumber(form:getChildById('startPrice'):getText())
  local buyout = tonumber(form:getChildById('buyoutPrice'):getText()) or 0
  local hours = tonumber(form:getChildById('hours'):getText())
  local promote = form:getChildById('promote'):isChecked()

  if not startPrice or startPrice < 1 then
    setStatus('The starting bid must be at least 1 BPC Coin.', true)
    return
  end
  if not hours then
    setStatus('Enter a whole number of hours.', true)
    return
  end
  -- Mirrors the server rule so the player gets told before a round trip; the
  -- server still rejects it independently.
  if buyout > 0 and buyout <= startPrice then
    setStatus('The buyout must be higher than the starting bid.', true)
    return
  end

  local item = selectedSellItem
  local summary = {
    string.format('Item:          %s %s', tierLabel(item.tier), item.name),
    string.format('Starting bid:  %s BPC', comma(startPrice)),
    buyout > 0 and string.format('Buyout:        %s BPC', comma(buyout)) or 'Buyout:        none',
    string.format('Duration:      %d hour%s', hours, hours == 1 and '' or 's'),
    promote and string.format('Promotion:     yes (%d BPC, non-refundable)', config.promotionFee or 5)
      or 'Promotion:     no',
    string.format('Sale fee:      %d%% if it sells', config.saleFeePercent or 10),
  }

  showConfirm(tr('Create Auction'), table.concat(summary, '\n'), tr('Create'), function()
    send(function(msg)
      msg:addU8(ACTION_CREATE)
      msg:addString(item.uid)
      msg:addU32(startPrice)
      msg:addU32(buyout)
      msg:addU16(hours)
      msg:addU8(promote and 1 or 0)
    end)
  end)
end

function onCancelAuction()
  if not selectedMine then
    return
  end
  local auctionId = selectedMine.id
  showConfirm(tr('Cancel Auction'), 'Cancel this auction? The item returns to your Bazaar Inventory.',
    tr('Cancel Auction'), function()
      send(function(msg)
        msg:addU8(ACTION_CANCEL)
        msg:addU32(auctionId)
      end)
    end)
end

-- Relist straight out of the Bazaar Inventory. The item is already escrowed,
-- so this skips the whole withdraw-to-character-and-list-again round trip --
-- ItemBazaar::relistItem reuses the existing escrow row rather than performing
-- another item handover.
function onRelist()
  if not selectedInventory then
    setStatus('Select an item in your Bazaar Inventory first.', true)
    return
  end

  local relistForm = window:getChildById('inventoryPanel'):getChildById('inventoryForm')
  local startPrice = tonumber(relistForm:getChildById('relistStart'):getText())
  local buyout = tonumber(relistForm:getChildById('relistBuyout'):getText()) or 0
  local hours = tonumber(relistForm:getChildById('relistHours'):getText())
  local promote = relistForm:getChildById('relistPromote'):isChecked()

  if not startPrice or startPrice < 1 then
    setStatus('The starting bid must be at least 1 BPC.', true)
    return
  end
  if not hours then
    setStatus('Enter a whole number of hours.', true)
    return
  end
  -- Mirrors the server rule so the player hears about it before a round trip;
  -- the server still rejects it independently.
  if buyout > 0 and buyout <= startPrice then
    setStatus('The buyout must be higher than the starting bid.', true)
    return
  end

  -- No confirmation step: the item is already escrowed here and the form
  -- above states every term, so relisting is a one-click action. The client
  -- checks above and the server both still reject bad input.
  local item = selectedInventory
  send(function(msg)
    msg:addU8(ACTION_RELIST)
    msg:addU32(item.id)
    msg:addU32(startPrice)
    msg:addU32(buyout)
    msg:addU16(hours)
    msg:addU8(promote and 1 or 0)
  end)
end

function onWithdraw()
  if not selectedInventory then
    setStatus('Select an item to withdraw.', true)
    return
  end
  local combo = window:getChildById('inventoryPanel'):getChildById('inventoryForm')
    :getChildById('character')
  local option = combo:getCurrentOption()
  if not option or not option.data then
    setStatus('Choose a character to deliver to.', true)
    return
  end

  local itemId = selectedInventory.id
  local characterId = option.data
  send(function(msg)
    msg:addU8(ACTION_WITHDRAW)
    msg:addU32(itemId)
    msg:addU32(characterId)
  end)
end

-- Opens the Store's coin-purchase flow. Guarded because game_store is a
-- separate module that a server can ship without; the Bazaar must not error if
-- it is absent.
-- ---------------------------------------------------------------- feedback
--
-- Everything below replaces displayInfoBox / displayErrorBox / displayGeneralBox.
-- Those parent their widget to rootWidget and never tear it down on game end,
-- which is why the old Create Auction dialog outlived a relog; they also left
-- the box standing after a button fired, because UIMessageBox:addButton only
-- connects the callback and never destroys the box.

-- A one-line result, shown next to the buttons that caused it and cleared on
-- a timer. Global (not local) so closures created earlier in the file -- the
-- per-card bid handlers -- can reach it at call time.
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
    end, 6000)
  end
end

-- The detail window is a separate root-level widget and renders above the main
-- one, so a confirmation raised while it is open has to be hosted by it.
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

-- Jumps from a Featured spotlight to the real card in Browse.
--
-- Filters are cleared first on purpose: the promoted item is very unlikely to
-- survive whatever the player last filtered by, and silently landing on an
-- empty Browse would read as a broken button. parseBrowse consumes
-- pendingFocusAuction once the page arrives.
function showAuctionInBrowse(auctionId)
  if not window then
    return
  end
  local panel = window:getChildById('browsePanel')
  if filterWheelEvent then
    removeEvent(filterWheelEvent)
    filterWheelEvent = nil
  end
  -- One browse for the whole reset, sent below. pcall so an error cannot
  -- leave the flag stuck on and every later filter change silent.
  resettingFilters = true
  local ok, err = pcall(function()
    panel:getChildById('categoryFilter'):setCurrentIndex(1)
    panel:getChildById('tierFilter'):setCurrentIndex(1)
    panel:getChildById('sortMode'):setCurrentIndex(1)
    panel:getChildById('buyoutOnly'):setChecked(false)
  end)
  resettingFilters = false
  if not ok then
    perror(err)
  end

  browseState.page = 0
  pendingFocusAuction = auctionId
  selectTab('browse')
  requestBrowse()
end

-- Three flashes of the accent border. Long enough to find the card in a grid
-- of twelve, short enough not to sit there blinking at someone.
--
-- Module-scoped rather than local: parseBrowse is defined earlier in the file
-- and a local declared here would not be in scope there.
function pulseCard(card)
  if focusPulseEvent then
    removeEvent(focusPulseEvent)
    focusPulseEvent = nil
  end
  local flashes, step = 6, 0
  focusPulseEvent = cycleEvent(function()
    step = step + 1
    -- setImageColor, not setBorderColor: the card is textured artwork now and
    -- has no border colour to flash.
    card:setImageColor(step % 2 == 1 and COLOR_MONEY or COLOR_POSITIVE)
    if step >= flashes then
      -- Ends on the $focus tint the card carries anyway, so the override it
      -- leaves behind matches the state it is in.
      card:setImageColor('#a6d495')
      removeEvent(focusPulseEvent)
      focusPulseEvent = nil
    end
  end, 180)
end

function openStore()
  if modules.game_store and modules.game_store.buyPoints then
    modules.game_store.buyPoints()
  elseif modules.game_store and modules.game_store.show then
    modules.game_store.show()
  else
    setStatus('The Store is not available right now.', false)
  end
end

function show()
  if not window then
    return
  end
  window:show()
  window:raise()
  window:focus()
  refresh()
end

function hide()
  -- Clear the confirmation and any pending status BEFORE hiding: an overlay
  -- left visible would reappear on the next open, still holding a callback for
  -- an action the player has since walked away from.
  hideConfirm()
  setStatus('')
  -- Stop every timer: a hidden window that is still tweening the carousel
  -- burns frames and, worse, keeps touching widgets after a rebuild.
  stopFeaturedTimers()
  if focusPulseEvent then
    removeEvent(focusPulseEvent)
    focusPulseEvent = nil
  end
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

-- ---------------------------------------------------------------- lifecycle

-- Equipment categories. Values MUST match the ItemCategory enum in
-- tfs-source/src/item_bazaar.h -- the server derives and stores the number and
-- filters on it directly; this list only puts labels on those numbers. Ordered
-- the way a player shops (weapons, off-hand, then worn slots) rather than by
-- enum value.
local CATEGORY_OPTIONS = {
  {'Sword', 1}, {'Club', 2}, {'Axe', 3}, {'Distance', 4}, {'Wand / Rod', 6},
  {'Fist', 8}, {'Shield', 5}, {'Quiver', 9}, {'Ammunition', 7},
  {'Helmet', 10}, {'Armor', 11}, {'Legs', 12}, {'Boots', 13},
  {'Amulet', 14}, {'Ring', 15},
}

local function setupFilters()
  local panel = window:getChildById('browsePanel')

  local categoryCombo = panel:getChildById('categoryFilter')
  categoryCombo:clearOptions()
  categoryCombo:addOption('All types', 0)
  for _, entry in ipairs(CATEGORY_OPTIONS) do
    categoryCombo:addOption(entry[1], entry[2])
  end
  categoryCombo.onOptionChange = onFilterChanged
  debounceComboWheel(categoryCombo)

  local tierCombo = panel:getChildById('tierFilter')
  tierCombo:clearOptions()
  tierCombo:addOption('All', 0)
  for tier = 1, 5 do
    tierCombo:addOption(TIER_NAME[tier], tier)
  end
  tierCombo.onOptionChange = onFilterChanged
  debounceComboWheel(tierCombo)

  local sortCombo = panel:getChildById('sortMode')
  sortCombo:clearOptions()
  sortCombo:addOption('Ending soon', 0)
  sortCombo:addOption('Newest', 1)
  sortCombo:addOption('Price: low', 2)
  sortCombo:addOption('Price: high', 3)
  sortCombo:addOption('Buyout', 4)
  sortCombo:addOption('Rarity', 5)
  -- Groups the list by equipment type, so browsing "all types" still arrives
  -- sorted like a shop rather than interleaved.
  sortCombo:addOption('Equipment type', 6)
  sortCombo.onOptionChange = onFilterChanged
  debounceComboWheel(sortCombo)
end

local function registerProtocol()
  -- Unregister first: on relog the previous registration may still be live,
  -- and registerOpcode errors on a duplicate (gamelib/protocolgame.lua).
  ProtocolGame.unregisterOpcode(OPCODE_SEND)
  ProtocolGame.registerOpcode(OPCODE_SEND, onBazaarOpcode)
end

local function unregisterProtocol()
  ProtocolGame.unregisterOpcode(OPCODE_SEND)
end

-- No button is created here: the Bazaar is opened from the white plate under
-- the Store button (itemBazaarButton in modules/game_inventory/inventory.otui,
-- which calls modules.game_bazaar.toggle()). It moved there from the side
-- buttons panel on 2026-09-10, swapping places with Options.
local function onGameStart()
  registerProtocol()
end

local function onGameEnd()
  -- Deliberately does NOT unregister the opcode. onGameStart is unreliable
  -- for this module (see init), so dropping the handler on logout would leave
  -- it permanently unregistered after a relog. The callback is inert while
  -- offline, and registerProtocol is idempotent.
  hide()
end

function init()
  g_ui.importStyle('bazaar')
  window = g_ui.createWidget('BazaarWindow', rootWidget)
  window:hide()

  setupFilters()
  -- Opens on the landing screen: the first question is "what is worth looking
  -- at", not "show me everything". Browse is one click away.
  selectTab('home')

  -- Register the opcode handler immediately rather than waiting for
  -- g_game's onGameStart. That signal was observed never to reach this
  -- module (verified: init ran and connect() was called, yet the handler
  -- never registered while online, and the client logged "unhandled opcode
  -- 79" for every Bazaar packet). opcodeCallbacks in gamelib/protocolgame.lua
  -- is a plain module-level table that lives for the whole client session, so
  -- registering once here is safe and order-independent.
  registerProtocol()

  -- Still connected so a relog re-registers; registerProtocol unregisters
  -- first, so repeat calls are harmless.
  connect(g_game, {onGameStart = onGameStart, onGameEnd = onGameEnd})
end

function terminate()
  disconnect(g_game, {onGameStart = onGameStart, onGameEnd = onGameEnd})
  unregisterProtocol()

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
  -- The side-panel button belongs to game_sidebuttons, not this module, so
  -- there is nothing to destroy here.
end
