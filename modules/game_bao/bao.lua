-- Old Man Bao - Hunter's Journal.
--
-- Mirrors game_bazaar's structure: one raw opcode claimed via
-- ProtocolGame.registerOpcode, a sub-type byte inside the payload for routing,
-- full state cached client-side on sync and redrawn from cache (not
-- re-requested on every tab switch).
--
-- Reminder for anyone editing this file: the CLIENT runs Lua 5.1. Integer
-- division (//), goto, and bitwise operators are all syntax errors here even
-- though the server's 5.5 accepts them.

-- 0x4C/0x4D: see the matching comment in bao_protocol.lua for why. The
-- previous 0x65/0x66 collided with native walk-north / map-row opcodes.
local OPCODE_BAO_REQUEST = 0x4C -- client -> server
local OPCODE_BAO_SEND = 0x4D    -- server -> client

local RESP_SYNC_FULL = 0x01
local RESP_OPEN_WINDOW = 0x02
local RESP_ERROR = 0x03
local RESP_SHOP_DATA = 0x04
local RESP_STATUS = 0x05
local RESP_BOUNTY_DATA = 0x06
local RESP_LEDGER_DATA = 0x07
local RESP_PROFILE_DATA = 0x08

local ACTION_REQUEST_SYNC = 0x01
local ACTION_ACCEPT_HUNT = 0x02
local ACTION_ABANDON_HUNT = 0x03
local ACTION_CLAIM_REWARD = 0x04
local ACTION_PURCHASE_ITEM = 0x05
local ACTION_REQUEST_SHOP = 0x06
local ACTION_REQUEST_BOUNTY = 0x07
local ACTION_TURNIN_BOUNTY = 0x08
local ACTION_REQUEST_LEDGER = 0x0A
local ACTION_BUY_LEDGER = 0x0B
local ACTION_REQUEST_PROFILE = 0x0C
-- 0x09 was ACTION_REROLL_BOUNTY, dropped when the board went weekly. Left
-- unassigned rather than reused, so nothing can be misrouted onto it.

local COLOR_POSITIVE = '#8fd97f'
local COLOR_URGENT = '#e8825c'
local COLOR_GOLD = '#f0c674'
local COLOR_PRIMARY = '#f6f1e2'
local COLOR_TERTIARY = '#9a9a9a'
local COLOR_MUTED = '#6f6f6f'

local window = nil
local baoState = nil   -- last full sync payload, cached
local shopState = nil  -- last shop data payload, cached
local bountyState = nil
local ledgerState = nil
local profileState = nil
local currentTab = 'profile'
local pendingConfirm = nil
local statusEvent = nil
local bountyTicker = nil

-- Tier -> chip colour, reading low-to-high danger so the chip itself signals
-- difficulty rather than only naming a place. Keys must match
-- BaoConfig.Hunts' tier strings (server-authoritative,
-- tfs-source/data/lib/bao/bao_config.lua) exactly.
local TIER_COLORS = {
  ['I - Doorstep'] = '#3f6b3a',
  ['II - Outskirts'] = '#2f6b60',
  ['III - Far Roads'] = '#2f5a7d',
  ['IV - Deep Country'] = '#523a78',
  ['V - The Wilds'] = '#8a5220',
  ['VI - The Frontier'] = '#7a2c2c',
  ["VII - World's End"] = '#7d2049',
}

-- Display order for the Chapter filter. The server sorts the catalog by the
-- same ranking before sending it, so this only has to agree with it.
local TIER_ORDER = {
  'I - Doorstep', 'II - Outskirts', 'III - Far Roads', 'IV - Deep Country',
  'V - The Wilds', 'VI - The Frontier', "VII - World's End",
}

local SORT_MODES = {
  { label = 'Chapter', key = 'danger' },
  { label = 'Shortest first', key = 'short' },
  { label = 'Longest first', key = 'long' },
  { label = 'Name', key = 'name' },
}

-- ─── Small helpers ──────────────────────────────────────────────────────

-- 1234567 -> "1,234,567". Long reputation figures are unreadable as a raw run
-- of digits, and this window is mostly about watching one of them climb.
local function comma(value)
  local formatted = tostring(math.floor(value or 0))
  local k
  repeat
    formatted, k = string.gsub(formatted, '^(-?%d+)(%d%d%d)', '%1,%2')
  until k == 0
  return formatted
end

local function percentOf(current, total)
  if not total or total <= 0 then
    return 0
  end
  return math.min(100, math.floor((current / total) * 100))
end

-- "3d 4h" / "4h 12m" / "12m 30s". The bounty board is weekly now, so this has
-- to carry a day component -- without it a fresh board reads as "167h".
local function shortDuration(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  local days = math.floor(seconds / 86400)
  local hours = math.floor((seconds % 86400) / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  if days > 0 then
    return string.format('%dd %dh', days, hours)
  end
  if hours > 0 then
    return string.format('%dh %dm', hours, minutes)
  end
  return string.format('%dm %ds', minutes, seconds % 60)
end

-- ─── Sends ──────────────────────────────────────────────────────────────

local function sendAction(build)
  local protocolGame = g_game.getProtocolGame()
  if not protocolGame then
    return
  end
  local msg = OutputMessage.create()
  msg:addU8(OPCODE_BAO_REQUEST)
  build(msg)
  protocolGame:send(msg)
end

local function sendRequestSync()
  sendAction(function(msg) msg:addU8(ACTION_REQUEST_SYNC) end)
end

local function sendRequestShop()
  sendAction(function(msg) msg:addU8(ACTION_REQUEST_SHOP) end)
end

local function sendRequestBounty()
  sendAction(function(msg) msg:addU8(ACTION_REQUEST_BOUNTY) end)
end

local function sendAcceptHunt(huntId)
  sendAction(function(msg)
    msg:addU8(ACTION_ACCEPT_HUNT)
    msg:addString(huntId)
  end)
end

local function sendAbandonHunt(slot)
  sendAction(function(msg)
    msg:addU8(ACTION_ABANDON_HUNT)
    msg:addU8(slot)
  end)
end

local function sendPurchaseItem(itemKey, amount)
  sendAction(function(msg)
    msg:addU8(ACTION_PURCHASE_ITEM)
    msg:addString(itemKey)
    -- Always sent, even for non-scalable entries, so the packet has one shape.
    -- The server pins it to 1 for anything that is not scalable.
    msg:addU16(amount or 1)
  end)
end

local function sendRequestProfile()
  sendAction(function(msg) msg:addU8(ACTION_REQUEST_PROFILE) end)
end

local function sendRequestLedger()
  sendAction(function(msg) msg:addU8(ACTION_REQUEST_LEDGER) end)
end

local function sendBuyLedger(key)
  sendAction(function(msg)
    msg:addU8(ACTION_BUY_LEDGER)
    msg:addString(key)
  end)
end

local function sendTurnInBounty(key)
  sendAction(function(msg)
    msg:addU8(ACTION_TURNIN_BOUNTY)
    msg:addString(key)
  end)
end

-- ─── Parsing ────────────────────────────────────────────────────────────

local function parseSyncFull(msg)
  local state = {}

  state.rankId = msg:getU8()
  state.rankName = msg:getString()
  state.reputation = msg:getU32()
  state.marks = msg:getU32()
  state.chaptersHeard = msg:getU8()
  state.chaptersTotal = msg:getU8()
  -- u16, matching the server: the roster is already past what a byte can
  -- describe once mastery counts are meant to grow with it.
  state.masteryCount = msg:getU16()
  state.rankRepFloor = msg:getU32()

  if msg:getU8() == 1 then
    state.pendingRankName = msg:getString()
  end

  local hasNextRank = msg:getU8()
  if hasNextRank == 1 then
    state.nextRankName = msg:getString()
    state.nextRankRepThreshold = msg:getU32()
    state.nextRankMasteriesRequired = msg:getU16()
  end

  local rankCount = msg:getU8()
  state.ranks = {}
  for i = 1, rankCount do
    state.ranks[i] = {
      id = msg:getU8(),
      name = msg:getString(),
      repThreshold = msg:getU32(),
      masteriesRequired = msg:getU16(),
      chapterTitle = msg:getString(),
      -- Empty unless this chapter has actually been heard.
      chapterText = msg:getString(),
    }
  end

  -- Chapters past the end of the ladder. No rank grants these -- they come
  -- from World's End hunts -- so they are listed separately rather than
  -- pretending there is a rank to reach for them.
  state.epilogue = {}
  local epilogueCount = msg:getU8()
  for i = 1, epilogueCount do
    state.epilogue[i] = {
      title = msg:getString(),
      unlocked = msg:getU8() == 1,
      chapterText = msg:getString(),
    }
  end

  local slotCount = msg:getU8()
  state.slots = {}
  state.slotCount = slotCount
  for i = 1, slotCount do
    local occupied = msg:getU8()
    if occupied == 1 then
      local slot = msg:getU8()
      state.slots[slot] = {
        slot = slot,
        huntId = msg:getString(),
        displayName = msg:getString(),
        targetLabel = msg:getString(),
        tier = msg:getString(),
        state = msg:getU8(),
        progress = msg:getU32(),
        requiredCount = msg:getU32(),
      }
    end
  end

  local catalogCount = msg:getU16()
  state.catalog = {}
  state.outfitByHuntId = {}
  state.catalogByHuntId = {}
  for i = 1, catalogCount do
    local entry = {
      huntId = msg:getString(),
      displayName = msg:getString(),
      targetLabel = msg:getString(),
      tier = msg:getString(),
      minRank = msg:getU8(),
      requiredCount = msg:getU32(),
      repeatable = msg:getU8() == 1,
      timesCompleted = msg:getU16(),
      rareBands = msg:getU8(),
      xp = msg:getU32(),
      reputation = msg:getU32(),
      marks = msg:getU32(),
      firstXp = msg:getU32(),
      firstReputation = msg:getU32(),
      firstMarks = msg:getU32(),
    }
    entry.outfit = {
      type = msg:getU16(),
      head = msg:getU8(),
      body = msg:getU8(),
      legs = msg:getU8(),
      feet = msg:getU8(),
      addons = msg:getU8(),
    }
    state.catalog[i] = entry
    state.outfitByHuntId[entry.huntId] = entry.outfit
    state.catalogByHuntId[entry.huntId] = entry
  end

  return state
end

local function parseShopData(msg)
  local state = { categories = {}, items = {} }

  local categoryCount = msg:getU8()
  for i = 1, categoryCount do
    state.categories[i] = {
      key = msg:getString(),
      title = msg:getString(),
      note = msg:getString(),
    }
  end

  local count = msg:getU16()
  for i = 1, count do
    state.items[i] = {
      itemKey = msg:getString(),
      displayName = msg:getString(),
      category = msg:getString(),
      description = msg:getString(),
      cost = msg:getU32(),
      itemId = msg:getU16(),
      look = msg:getU16(),
      scalable = msg:getU8() == 1,
      maxUnits = msg:getU16(),
      owned = msg:getU8() == 1,
      oneTime = msg:getU8() == 1,
      -- 0 open, 1 rank-locked, 2 needs another purchase first.
      lockKind = msg:getU8(),
      requiresName = msg:getString(),
    }
  end
  return state
end

local function parseLedgerData(msg)
  local state = { tracks = {}, books = {} }
  state.totalRanks = msg:getU16()
  state.maxRanks = msg:getU16()
  state.invested = msg:getU32()

  local bookCount = msg:getU8()
  for i = 1, bookCount do
    state.books[i] = { title = msg:getString(), subtitle = msg:getString() }
  end

  local count = msg:getU8()
  for i = 1, count do
    state.tracks[i] = {
      key = msg:getString(),
      book = msg:getU8(),
      displayName = msg:getString(),
      summary = msg:getString(),
      currentEffect = msg:getString(),
      nextEffect = msg:getString(),
      rank = msg:getU16(),
      maxRank = msg:getU16(),
      cost = msg:getU32(), -- 0 means maxed out
    }
  end
  return state
end

local function parseBountyData(msg)
  local state = { bounties = {} }
  state.secondsUntilReset = msg:getU32()
  -- Captured so the countdown can tick locally instead of the client having to
  -- re-request the board once a second just to move a clock.
  state.receivedAt = g_clock.seconds()

  state.band = msg:getString()
  state.levelLow = msg:getU16()
  state.levelHigh = msg:getU16() -- 0 means no upper bound
  state.gatedBy = msg:getString() -- "level" or "rank", whichever is lower

  local count = msg:getU8()
  for i = 1, count do
    state.bounties[i] = {
      key = msg:getString(),
      displayName = msg:getString(),
      flavor = msg:getString(),
      itemId = msg:getU16(),
      itemName = msg:getString(),
      required = msg:getU32(),
      carried = msg:getU32(),
      claimed = msg:getU8() == 1,
      marks = msg:getU32(),
      reputation = msg:getU32(),
    }
  end
  return state
end

local function parseProfileData(msg)
  local state = { tiers = {} }

  state.rankId = msg:getU8()
  state.rankName = msg:getString()
  state.reputation = msg:getU32()
  state.marks = msg:getU32()
  state.marksEarned = msg:getU32()
  state.ledgerScore = msg:getU16()
  state.huntsCompleted = msg:getU32()
  state.bountiesCompleted = msg:getU32()
  state.maxSlots = msg:getU8()
  state.chaptersHeard = msg:getU8()
  state.chaptersTotal = msg:getU8()
  state.chapterTitle = msg:getString()

  state.outfits = msg:getU16()
  state.outfitsTotal = msg:getU16()
  state.mounts = msg:getU16()
  state.mountsTotal = msg:getU16()
  state.unlocks = msg:getU16()
  state.unlocksTotal = msg:getU16()

  local tierCount = msg:getU8()
  for i = 1, tierCount do
    state.tiers[i] = {
      name = msg:getString(),
      mastered = msg:getU16(),
      total = msg:getU16(),
    }
  end

  state.milestones = {}
  local milestoneCount = msg:getU8()
  for i = 1, milestoneCount do
    state.milestones[i] = {
      label = msg:getString(),
      note = msg:getString(),
      need = msg:getString(),
      done = msg:getU8() == 1,
    }
  end
  return state
end

-- ─── Status line and confirmation ───────────────────────────────────────

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

function hideConfirm()
  pendingConfirm = nil
  if window then
    window:getChildById('confirmOverlay'):hide()
  end
end

function showConfirm(title, body, acceptText, callback)
  if not window then
    return
  end
  local overlay = window:getChildById('confirmOverlay')
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

-- ─── Drawing helpers ────────────────────────────────────────────────────

local function isHuntActive(huntId)
  if not baoState then
    return false
  end
  for _, slot in pairs(baoState.slots) do
    if slot.huntId == huntId then
      return true
    end
  end
  return false
end

local function clearPanel(panel)
  panel:destroyChildren()
end

-- Empty states are pre-declared in the .otui as siblings of each list, not
-- created inside it. A widget parented to a grid-layout panel gets resized to
-- the cell size, so a notice built in Lua would be squeezed into one 288px
-- card slot and read as a broken card rather than as a message.
--
-- Passing nil hides the notice, which is what every non-empty redraw does.
local function setEmptyNotice(id, text)
  local label = window:recursiveGetChildById(id)
  if not label then
    return
  end
  if text then
    label:setText(text)
    label:show()
  else
    label:hide()
  end
end

local function applyTierChip(card, tier)
  local chip = card:getChildById('cap'):getChildById('tierChip')
  chip:setText(tier or '')
  chip:setWidth(chip:getTextSize().width + 14)
  chip:setBackgroundColor(TIER_COLORS[tier] or '#4a4a4a')
end

-- A grid of hunt cards under a heading, inside a verticalBox list.
--
-- (!) The grid MUST be given an explicit height. A grid layout reports no
-- intrinsic size, so inside a vertical box it lays out at zero height and every
-- card in it is invisible -- with no error anywhere to say so.
local CARD_H, CARD_GAP, CARD_COLS = 206, 6, 3

local function cardGrid(parent, count)
  local grid = g_ui.createWidget('BaoCardGrid', parent)
  local rows = math.max(1, math.ceil(count / CARD_COLS))
  grid:setHeight(rows * CARD_H + (rows - 1) * CARD_GAP)
  return grid
end

-- Compact enough to fit a 74px column: 1,392 -> "1,392", 1071000 -> "1.1M".
local function shortNumber(value)
  value = value or 0
  if value >= 1000000 then
    return string.format('%.1fM', value / 1000000)
  end
  if value >= 100000 then
    return string.format('%dk', math.floor(value / 1000))
  end
  return comma(value)
end

-- Fills a card's reward strip with the reward the player would ACTUALLY get
-- next: the first-mastery figures while the hunt is unmastered, the repeat
-- figures afterwards. Showing both at once was two numbers competing for the
-- same glance when only one of them is ever the answer.
local function applyReward(card, hunt)
  local strip = card:getChildById('payout')
  local first = (hunt.timesCompleted or 0) == 0

  strip:getChildById('xpValue'):setText(shortNumber(first and hunt.firstXp or hunt.xp))
  strip:getChildById('repValue'):setText(shortNumber(first and hunt.firstReputation or hunt.reputation))
  strip:getChildById('marksValue'):setText(shortNumber(first and hunt.firstMarks or hunt.marks))

  -- Stars are how deep the rare table goes, not a rating. Hidden rather than
  -- dimmed: an empty slot reads as "worse", a missing one reads as nothing.
  local bands = hunt.rareBands or 1
  for i = 1, 3 do
    strip:getChildById('star' .. i):setVisible(i <= bands)
  end
end

local function applyPortrait(card, huntId)
  local creature = card:getChildById('portraitWell'):getChildById('creature')
  local outfit = baoState and baoState.outfitByHuntId and baoState.outfitByHuntId[huntId]
  if outfit and outfit.type and outfit.type > 0 then
    creature:setOutfit(outfit)
    creature:setVisible(true)
  else
    creature:setVisible(false)
  end
end

-- ─── Filtering and sorting ──────────────────────────────────────────────

local function selectedTierFilter()
  if not window then
    return nil
  end
  local combo = window:recursiveGetChildById('tierFilter')
  local option = combo and combo:getCurrentOption()
  if not option or option.text == 'Any chapter' then
    return nil
  end
  return option.text
end

local function selectedSortMode()
  if not window then
    return 'danger'
  end
  local combo = window:recursiveGetChildById('sortMode')
  local option = combo and combo:getCurrentOption()
  if not option then
    return 'danger'
  end
  for _, mode in ipairs(SORT_MODES) do
    if mode.label == option.text then
      return mode.key
    end
  end
  return 'danger'
end

local function tierRank(tier)
  for index, name in ipairs(TIER_ORDER) do
    if name == tier then
      return index
    end
  end
  return 99
end

-- Sorts in place. Every comparator ends with the hunt id so the ordering is
-- total: table.sort is not stable, so two entries that tie on the visible key
-- would otherwise swap places on every redraw.
local function sortHunts(list, mode)
  table.sort(list, function(a, b)
    if mode == 'short' or mode == 'long' then
      if a.requiredCount ~= b.requiredCount then
        if mode == 'short' then
          return a.requiredCount < b.requiredCount
        end
        return a.requiredCount > b.requiredCount
      end
    elseif mode == 'name' then
      if a.displayName ~= b.displayName then
        return a.displayName < b.displayName
      end
    else
      local ta, tb = tierRank(a.tier), tierRank(b.tier)
      if ta ~= tb then
        return ta < tb
      end
      if a.requiredCount ~= b.requiredCount then
        return a.requiredCount < b.requiredCount
      end
    end
    return a.huntId < b.huntId
  end)
end

-- ─── Tabs ───────────────────────────────────────────────────────────────

local function drawHunts()
  local panel = window:recursiveGetChildById('huntsList')
  clearPanel(panel)
  if not baoState then
    return
  end

  local maxSlots = baoState.slotCount or 3
  local active = {}
  for slot = 1, maxSlots do
    if baoState.slots[slot] then
      active[#active + 1] = baoState.slots[slot]
    end
  end
  local freeSlots = maxSlots - #active

  local countLabel = window:recursiveGetChildById('huntsCount')
  countLabel:setText(string.format('%d of %d hunts running', #active, maxSlots))
  -- A "slot" is never defined anywhere else, and it governs the one limit on
  -- this tab. Explaining it on hover costs nothing and answers the question
  -- exactly where it is asked.
  countLabel:setTooltip('Bao lets you carry a few hunts at once. Each one you accept fills a slot until you finish or abandon it. He sells more slots once he trusts you.')

  -- Active hunts first, in the same tab. They used to live on their own tab,
  -- which made three of eight tabs about hunts and split "what am I doing"
  -- from "what could I do".
  if #active > 0 then
    local head = g_ui.createWidget('BaoSectionHead', panel)
    head:getChildById('title'):setText('Running now')
    head:getChildById('note'):setText(string.format('%d of %d slots used', #active, maxSlots))

    local activeGrid = cardGrid(panel, #active)
    for _, slotData in ipairs(active) do
      local card = g_ui.createWidget('BaoHuntCard', activeGrid)
      applyPortrait(card, slotData.huntId)
      applyTierChip(card, slotData.tier)

      local percent = percentOf(slotData.progress, slotData.requiredCount)
      card:getChildById('cap'):getChildById('capRight'):setText(string.format('%d%%', percent))
      card:getChildById('title'):setText(slotData.displayName)
      card:getChildById('subtitle'):setText(slotData.targetLabel)
      local catalogEntry = baoState.catalogByHuntId and baoState.catalogByHuntId[slotData.huntId]
      if catalogEntry then
        applyReward(card, catalogEntry)
      end

      local progress = card:getChildById('foot'):getChildById('progress')
      progress:setPercent(percent)
      progress:setText(string.format('%s / %s', comma(slotData.progress), comma(slotData.requiredCount)))

      local button = card:getChildById('foot'):getChildById('actionButton')
      if slotData.state == 2 then
        button:setText(tr('Completed'))
        button:disable()
      else
        button:setText(tr('Abandon'))
        local slot = slotData.slot
        local name = slotData.displayName
        local shown = string.format('%s of %s', comma(slotData.progress), comma(slotData.requiredCount))
        button.onClick = function()
          showConfirm(tr('Abandon this hunt?'),
            string.format('"%s" is at %s. Abandoning wipes that progress completely - Bao does not keep half-finished work.', name, shown),
            tr('Abandon'),
            function() sendAbandonHunt(slot) end)
        end
      end
    end
  end

  local tierFilter = selectedTierFilter()
  local eligible = {}
  for _, hunt in ipairs(baoState.catalog) do
    local unlocked = hunt.minRank <= baoState.rankId
    local repeatableOrFresh = hunt.repeatable or hunt.timesCompleted == 0
    if unlocked and repeatableOrFresh and not isHuntActive(hunt.huntId)
        and (not tierFilter or hunt.tier == tierFilter) then
      eligible[#eligible + 1] = hunt
    end
  end
  sortHunts(eligible, selectedSortMode())

  local offerHead = g_ui.createWidget('BaoSectionHead', panel)
  offerHead:getChildById('title'):setText('What he will give you')
  offerHead:getChildById('note'):setText(string.format('%d available at your rank', #eligible))

  if #eligible == 0 then
    setEmptyNotice('huntsEmpty', tierFilter
      and 'Nothing there yet. Each region opens with the chapter that names it - keep hunting and Bao will tell you the next one.'
      or 'Nothing new for now. Return once your rank has grown.')
    return
  end
  setEmptyNotice('huntsEmpty', nil)

  local offerGrid = cardGrid(panel, #eligible)
  for _, hunt in ipairs(eligible) do
    local card = g_ui.createWidget('BaoHuntCard', offerGrid)
    applyPortrait(card, hunt.huntId)
    applyTierChip(card, hunt.tier)

    local capRight = card:getChildById('cap'):getChildById('capRight')
    -- Only real state goes here. The reward strip already shows the first-time
    -- figures as absolute numbers, so a "x3" badge beside them was restating
    -- the same fact in a weaker unit.
    if hunt.timesCompleted > 0 then
      capRight:setText(string.format('Mastered x%d', hunt.timesCompleted))
      capRight:setColor(COLOR_POSITIVE)
    else
      capRight:setText('')
    end

    card:getChildById('title'):setText(hunt.displayName)

    card:getChildById('subtitle'):setText(hunt.targetLabel)

    -- The payout, on the card rather than behind a hover.
    applyReward(card, hunt)

    local progress = card:getChildById('foot'):getChildById('progress')
    progress:setPercent(0)
    progress:setText(string.format('%s kills', comma(hunt.requiredCount)))

    local button = card:getChildById('foot'):getChildById('actionButton')
    if freeSlots <= 0 then
      button:setText(tr('No free slot'))
      button:disable()
    else
      button:setText(tr('Accept'))
      local huntId = hunt.huntId
      button.onClick = function() sendAcceptHunt(huntId) end
    end
  end
end


-- The bounty heading's right-hand line. Declared as a plain global so both
-- drawBounties and the once-a-second ticker use the SAME text, rather than
-- each computing its own -- which is how the two drifted apart last time.
function bountyNoteText()
  if not bountyState then
    return ''
  end

  local elapsed = g_clock.seconds() - (bountyState.receivedAt or g_clock.seconds())
  local remaining = math.max(0, (bountyState.secondsUntilReset or 0) - elapsed)

  local done = 0
  for _, bounty in ipairs(bountyState.bounties) do
    if bounty.claimed then
      done = done + 1
    end
  end

  -- A zero countdown is never shown as "0m 0s". That is what a stale or
  -- misparsed value looks like, and it reads as broken rather than as
  -- imminent -- so the honest fallback names the event instead of the clock.
  local when = remaining > 0 and ('new orders in ' .. shortDuration(remaining))
    or 'new orders at the next server save'
  return string.format('%d of %d done  |  %s', done, #bountyState.bounties, when)
end

local function drawBounties()
  local panel = window:recursiveGetChildById('bountyList')
  clearPanel(panel)

  local head = window:recursiveGetChildById('bountyHead')

  if not bountyState then
    head:getChildById('title'):setText("This week's orders")
    head:getChildById('note'):setText('')
    setEmptyNotice('bountyEmpty', 'Asking Bao what he needs...')
    return
  end

  -- The heading names the band AND the level range that produced it, so a
  -- player who levels past a threshold and finds a different board can see
  -- immediately why, instead of assuming something broke.
  -- (!) Only print the level band when LEVEL is what is limiting you. When
  -- rank is the lower gate, that band belongs to a difficulty the player has
  -- outgrown by level -- a level 7000 Stray was being told "levels 1 to 49".
  local reason
  if bountyState.gatedBy == 'rank' then
    reason = string.format('held here by your rank, %s', baoState and baoState.rankName or 'Stray')
  elseif bountyState.levelHigh and bountyState.levelHigh > 0 then
    reason = string.format('levels %d to %d', bountyState.levelLow, bountyState.levelHigh)
  else
    reason = string.format('level %d and above', bountyState.levelLow)
  end
  head:getChildById('title'):setText(string.format('%s work  -  %s', bountyState.band, reason))
  -- Orders are gated on BOTH level and rank, and the Hunts tab beside this one
  -- is gated on rank alone. Saying which of the two is holding you here is the
  -- difference between "this makes no sense" and "I know what to go and do".
  if bountyState.gatedBy == 'rank' then
    head:setTooltip('Orders are the lower of two gates: what your level can hunt, and what Bao trusts you with. Your rank is the lower one right now, so earning the next chapter opens harder orders - and they pay far more.')
  else
    head:setTooltip('Orders are matched to your level, so you are always asked for things you can actually hunt. Your rank with Bao can also hold this back if it is the lower of the two.')
  end

  head:getChildById('note'):setText(bountyNoteText())

  if #bountyState.bounties == 0 then
    setEmptyNotice('bountyEmpty', 'Bao has nothing posted for you yet.')
    return
  end
  setEmptyNotice('bountyEmpty', nil)

  for _, bounty in ipairs(bountyState.bounties) do
    local card = g_ui.createWidget('BaoBountyCard', panel)
    -- No chip on an order card. A chapter name here advertised a rank lock
    -- that does not exist (orders are gated by level), and the monster name
    -- that replaced it only repeated what the item sprite and subtitle
    -- already say. The cap carries the reward alone.
    card:getChildById('cap'):getChildById('tierChip'):hide()

    card:getChildById('item'):setItemId(bounty.itemId)
    card:getChildById('cap'):getChildById('reward'):setText(
      string.format('%s Marks | %s Rep', comma(bounty.marks), comma(bounty.reputation)))

    card:getChildById('title'):setText(bounty.displayName)
    card:getChildById('subtitle'):setText(string.format('%s  x%s', bounty.itemName, comma(bounty.required)))

    local flavor = card:getChildById('flavor')
    local progress = card:getChildById('foot'):getChildById('progress')
    local button = card:getChildById('foot'):getChildById('actionButton')

    if bounty.claimed then
      flavor:setText('Delivered. Bao has no more use for these this week.')
      flavor:setColor(COLOR_POSITIVE)
      progress:setPercent(100)
      progress:setText(tr('Paid'))
      button:setText(tr('Done'))
      button:disable()
    else
      flavor:setText(bounty.flavor)
      flavor:setColor(COLOR_MUTED)
      progress:setPercent(percentOf(bounty.carried, bounty.required))
      progress:setText(string.format('%s of %s carried', comma(bounty.carried), comma(bounty.required)))

      -- All or nothing: the full order or no payment. The button says which
      -- of those two states you are in rather than making the player compare
      -- the two numbers on the bar above it.
      if bounty.carried >= bounty.required then
        button:setText(tr('Hand in'))
        local key = bounty.key
        local itemName = bounty.itemName
        local required = bounty.required
        local marks = bounty.marks
        local reputation = bounty.reputation
        button.onClick = function()
          showConfirm(tr('Hand these over?'),
            string.format('Bao takes %s %s and pays %s Marks and %s Reputation. They leave your bags for good.',
              comma(required), itemName, comma(marks), comma(reputation)),
            tr('Hand in'),
            function() sendTurnInBounty(key) end)
        end
      else
        button:setText(tr('Need %s more', comma(bounty.required - bounty.carried)))
        button:disable()
      end
    end
  end
end

local function drawMastered()
  local panel = window:recursiveGetChildById('masteredList')
  clearPanel(panel)
  if not baoState then
    return
  end

  -- A trophy case, not a catalogue. This used to render all 61 hunts including
  -- every locked one, so at rank 0 it was a wall of grey rows under a heading
  -- that claimed they were mastered. Showing only what you have actually done
  -- also keeps what is coming a surprise, which is worth more than a preview.
  local mastered = {}
  for _, hunt in ipairs(baoState.catalog) do
    if hunt.timesCompleted > 0 then
      mastered[#mastered + 1] = hunt
    end
  end
  sortHunts(mastered, 'danger')

  local head = window:recursiveGetChildById('masteredHead')
  head:getChildById('title'):setText('What you have mastered')
  head:getChildById('note'):setText(string.format('%d hunt(s)', #mastered))

  if #mastered == 0 then
    setEmptyNotice('masteredEmpty',
      'Nothing yet. Finish a hunt through to the end and it lands here - and Bao counts it toward your next chapter.')
    return
  end
  setEmptyNotice('masteredEmpty', nil)

  local grid = cardGrid(panel, #mastered)
  for _, hunt in ipairs(mastered) do
    local card = g_ui.createWidget('BaoHuntCard', grid)
    applyPortrait(card, hunt.huntId)
    applyTierChip(card, hunt.tier)
    card:getChildById('title'):setText(hunt.displayName)
    card:getChildById('subtitle'):setText(hunt.targetLabel)
    applyReward(card, hunt)

    local capRight = card:getChildById('cap'):getChildById('capRight')
    capRight:setText(string.format('x%d', hunt.timesCompleted))
    capRight:setColor(COLOR_POSITIVE)

    local progress = card:getChildById('foot'):getChildById('progress')
    progress:setPercent(100)
    progress:setText(tr('Mastered'))

    local button = card:getChildById('foot'):getChildById('actionButton')
    button:setText(tr('Completed %dx', hunt.timesCompleted))
    button:disable()
  end
end

local function drawRewards()
  local panel = window:recursiveGetChildById('rewardsList')
  clearPanel(panel)

  local head = window:recursiveGetChildById('rewardsHead')
  head:getChildById('title'):setText('What Bao will part with')

  if not shopState then
    head:getChildById('note'):setText('')
    setEmptyNotice('rewardsEmpty', 'Opening the cabinet...')
    return
  end

  head:getChildById('note'):setText(string.format('%s Marks available',
    comma(baoState and baoState.marks or 0)))

  if #shopState.items == 0 then
    setEmptyNotice('rewardsEmpty', 'Nothing here for your rank yet. Bao opens up as he trusts you.')
    return
  end
  setEmptyNotice('rewardsEmpty', nil)

  -- Walk the categories in the order the server sent them and emit a heading
  -- only for those that actually have something in them, so a rank that has
  -- not unlocked a whole section does not see an empty title for it.
  for _, category in ipairs(shopState.categories) do
    local members = {}
    for _, item in ipairs(shopState.items) do
      if item.category == category.key then
        members[#members + 1] = item
      end
    end
    if #members > 0 then
      local sectionHead = g_ui.createWidget('BaoSectionHead', panel)
      sectionHead:getChildById('title'):setText(category.title)
      sectionHead:getChildById('note'):setText(category.note)

      for _, item in ipairs(members) do
        local row = g_ui.createWidget('BaoShopRow', panel)
        -- An outfit or mount has no item sprite, so it is drawn as a creature
        -- instead. Exactly one of the two is ever visible.
        local sprite = row:getChildById('item')
        local creature = row:getChildById('creature')
        if item.look and item.look > 0 then
          -- Same idiom the hunt portraits use: setOutfit straight onto the
          -- UICreature. No Creature object needed.
          creature:setOutfit({ type = item.look, head = 0, body = 0, legs = 0, feet = 0, addons = 0 })
          creature:show()
          sprite:hide()
        else
          sprite:setItemId(item.itemId)
          sprite:show()
          creature:hide()
        end
        row:getChildById('title'):setText(item.displayName)
        row:getChildById('subtitle'):setText(item.description)

        local badge = row:getChildById('badge')
        badge:setText(item.oneTime and 'one purchase' or '')
        badge:setColor(COLOR_TERTIARY)

        local price = row:getChildById('price')
        local button = row:getChildById('actionButton')
        price:setText(string.format('%s Marks', comma(item.cost)))

        if item.owned then
          price:setColor(COLOR_TERTIARY)
          badge:setText('owned')
          badge:setColor(COLOR_POSITIVE)
          button:setText(tr('Owned'))
          button:disable()
        elseif item.lockKind > 0 then
          -- (!) The reason goes in VISIBLE text, not only a tooltip.
          --
          -- A disabled widget never enters hover state (uiwidget.cpp:1450
          -- gates it on isEnabled), so a tooltip on a disabled button can
          -- never fire -- every "Locked" button in this window had an
          -- invisible explanation. The badge carries it instead, and the
          -- tooltip moves to the ROW, which is enabled and does hover.
          price:setColor(COLOR_TERTIARY)
          row:getChildById('subtitle'):setColor(COLOR_MUTED)
          button:setText(tr('Locked'))
          button:disable()
          badge:setColor(COLOR_TERTIARY)
          if item.lockKind == 1 then
            badge:setText(string.format('%s rank', item.requiresName))
            row:setTooltip(string.format(
              'Bao will not sell you this until he has named you %s.', item.requiresName))
          else
            badge:setText('needs another purchase')
            row:setTooltip(string.format(
              'Bao wants you to take "%s" first.', item.requiresName))
          end
        elseif baoState and baoState.marks < item.cost then
          price:setColor(COLOR_TERTIARY)
          button:setText(tr('Need %s', comma(item.cost - baoState.marks)))
          button:disable()
        else
          price:setColor(COLOR_GOLD)
          button:setText(tr('Buy'))
          local itemKey = item.itemKey
          local name = item.displayName
          local unitCost = item.cost
          local description = item.description
          local maxUnits = item.maxUnits or 1

          -- Scalable entries let the player name the quantity and watch the
          -- price follow, so the decision -- potions now, or keep saving for
          -- the Wheel -- is made in the row rather than in their head.
          local qty = 1
          local qtyDown = row:getChildById('qtyDown')
          local qtyValue = row:getChildById('qtyValue')
          local qtyUp = row:getChildById('qtyUp')

          local function refresh()
            local total = unitCost * qty
            qtyValue:setText(tostring(qty))
            price:setText(string.format('%s Marks', comma(total)))
            local afford = not baoState or baoState.marks >= total
            price:setColor(afford and COLOR_GOLD or COLOR_TERTIARY)
            button:setText(afford and tr('Buy')
              or tr('Need %s', comma(total - (baoState and baoState.marks or 0))))
            button:setEnabled(afford)
          end

          if item.scalable then
            qtyDown:show()
            qtyValue:show()
            qtyUp:show()
            -- Steps of ten past the first, so reaching a hundred is four
            -- clicks rather than ninety-nine.
            qtyDown.onClick = function()
              qty = qty > 10 and qty - 10 or 1
              refresh()
            end
            qtyUp.onClick = function()
              qty = math.min(maxUnits, qty < 10 and 10 or qty + 10)
              refresh()
            end
            refresh()
          end

          button.onClick = function()
            local total = unitCost * qty
            local ask = item.scalable
              and string.format('%d for %s Hunter Marks.', qty, comma(total))
              or string.format('Bao asks %s Hunter Marks.', comma(total))
            showConfirm(tr('Spend your Marks?'),
              string.format('%s\n\n%s', description, ask),
              tr('Buy'),
              function() sendPurchaseItem(itemKey, qty) end)
          end
        end
      end
    end
  end
end

local LEDGER_CARD_H, LEDGER_GAP, LEDGER_COLS = 146, 6, 3

local function drawLedger()
  local panel = window:recursiveGetChildById('ledgerList')
  clearPanel(panel)

  local head = window:recursiveGetChildById('ledgerHead')
  head:getChildById('title'):setText("Bao's Ledger")

  if not ledgerState then
    head:getChildById('note'):setText('')
    setEmptyNotice('ledgerEmpty', 'Bao is finding the right page...')
    return
  end
  setEmptyNotice('ledgerEmpty', nil)

  local marks = baoState and baoState.marks or 0
  local affordableTotal = 0
  for _, track in ipairs(ledgerState.tracks) do
    if track.cost > 0 and marks >= track.cost then
      affordableTotal = affordableTotal + 1
    end
  end

  head:getChildById('note'):setText(affordableTotal > 0
    and string.format('%d lesson(s) you can afford right now', affordableTotal)
    or 'Nothing affordable yet - keep hunting')
  head:getChildById('note'):setColor(affordableTotal > 0 and COLOR_POSITIVE or COLOR_TERTIARY)
  head:setTooltip('Bao teaches permanently. Every rank you buy here stays bought, and each one costs more than the last - so this is where Marks go once you have what you need from his shop. Cold Trail alone will eventually cut a 3,000-kill hunt down by nearly half.')

  -- The brag line. Two figures only: the score, and what it cost. Marks-to-
  -- spend was dropped because the window header already carries that balance
  -- a couple of inches above, and repeating it made the lifetime total read as
  -- just another running number instead of the thing this tab is about.
  local banner = g_ui.createWidget('BaoLedgerBanner', panel)
  local maxRanks = ledgerState.maxRanks or 0
  banner:getChildById('scoreValue'):setText(string.format('%s / %s',
    comma(ledgerState.totalRanks), comma(maxRanks)))
  banner:getChildById('investedValue'):setText(comma(ledgerState.invested or 0))
  local totalBar = banner:getChildById('totalBar')
  totalBar:setPercent(percentOf(ledgerState.totalRanks, maxRanks))
  totalBar:setText(string.format('%s of %s ranks written',
    comma(ledgerState.totalRanks), comma(maxRanks)))
  banner:setTooltip('Ledger Score is every rank you have ever bought here, across all three books. It never goes down, and it is what appears beside your name on the Ledger leaderboard.')

  local byBook = {}
  for _, track in ipairs(ledgerState.tracks) do
    local b = track.book or 1
    byBook[b] = byBook[b] or {}
    table.insert(byBook[b], track)
  end

  for index, book in ipairs(ledgerState.books or {}) do
    local tracks = byBook[index]
    if tracks then
      local ranks, maxRanks, affordable = 0, 0, 0
      for _, track in ipairs(tracks) do
        ranks = ranks + track.rank
        maxRanks = maxRanks + track.maxRank
        if track.cost > 0 and marks >= track.cost then
          affordable = affordable + 1
        end
      end

      local bookHead = g_ui.createWidget('BaoSectionHead', panel)
      bookHead:getChildById('title'):setText(book.title)
      local note = string.format('%d of %d ranks', ranks, maxRanks)
      if affordable > 0 then
        note = string.format('%s  |  %d affordable', note, affordable)
      end
      bookHead:getChildById('note'):setText(note)
      bookHead:getChildById('note'):setColor(affordable > 0 and COLOR_POSITIVE or COLOR_TERTIARY)
      bookHead:setTooltip(book.subtitle)

      -- (!) The grid needs an explicit height. A grid layout reports no
      -- intrinsic size, so inside this verticalBox it lays out at zero and
      -- every card in it is invisible with no error anywhere.
      local grid = g_ui.createWidget('BaoLedgerGrid', panel)
      local rows = math.ceil(#tracks / LEDGER_COLS)
      grid:setHeight(rows * LEDGER_CARD_H + math.max(0, rows - 1) * LEDGER_GAP)
      grid:setMarginBottom(8)

      for _, track in ipairs(tracks) do
        local card = g_ui.createWidget('BaoLedgerCard', grid)
        local owned = track.rank > 0
        card:getChildById('cap'):getChildById('title'):setText(track.displayName)

        -- The rank count rides ON the bar, the way a hunt card carries its
        -- kill count -- one number, one place, and it frees the cap for the
        -- track name.
        local bar = card:getChildById('bar')
        bar:setPercent(percentOf(track.rank, track.maxRank))
        bar:setText(string.format('%d / %d', track.rank, track.maxRank))

        local current = card:getChildById('current')
        if owned then
          current:setText(track.currentEffect)
          current:setColor(COLOR_POSITIVE)
        else
          current:setText(track.summary)
          current:setColor(COLOR_TERTIARY)
        end

        local nextLabel = card:getChildById('next')
        local price = card:getChildById('foot'):getChildById('price')
        local button = card:getChildById('foot'):getChildById('actionButton')

        if track.cost == 0 then
          nextLabel:setText('Nothing further to teach.')
          nextLabel:setColor(COLOR_MUTED)
          price:setText('')
          button:setText(tr('Mastered'))
          button:disable()
        else
          nextLabel:setText('Next: ' .. track.nextEffect)
          nextLabel:setColor(COLOR_TERTIARY)
          price:setText(string.format('%s Marks', comma(track.cost)))

          if marks < track.cost then
            price:setColor(COLOR_TERTIARY)
            button:setText(tr('Need %s', comma(track.cost - marks)))
            button:disable()
          else
            -- Affordable cards are the only ones that can act, so they are the
            -- only ones lit. A uniformly grey grid made a tab with three
            -- purchases waiting look identical to one with none.
            price:setColor(COLOR_GOLD)
            -- (!) setOn, not setBorderColor. The card is textured slate with
            -- no border to colour; $on swaps it to the frame's light weight,
            -- so an affordable rank physically lifts out of the grid.
            card:setOn(true)
            button:setText(tr('Learn'))
            local key = track.key
            local name = track.displayName
            local cost = track.cost
            local effect = track.nextEffect
            button.onClick = function()
              showConfirm(tr('Learn this?'),
                string.format('%s rank %d: %s\n\nBao asks %s Hunter Marks. The next rank will cost more.',
                  name, track.rank + 1, effect, comma(cost)),
                tr('Learn'),
                function() sendBuyLedger(key) end)
            end
          end
        end
      end
    end
  end
end

local function drawProfile()
  local panel = window:getChildById('profilePanel')

  local head = window:recursiveGetChildById('regionHead')
  head:getChildById('title'):setText('Where you have hunted')

  local band = panel:getChildById('identityBand')
  local grid = panel:getChildById('tileGrid')
  local regions = panel:getChildById('regionList')
  local story = panel:getChildById('storyList')
  clearPanel(grid)
  clearPanel(regions)
  clearPanel(story)

  -- Identity comes from the LOCAL PLAYER, not the packet: the client already
  -- knows the name and the exact outfit being worn, and sending them would
  -- only create a second copy to drift.
  local localPlayer = g_game.getLocalPlayer()
  if localPlayer then
    band:getChildById('playerName'):setText(localPlayer:getName())
    local creature = band:getChildById('portraitWell'):getChildById('creature')
    creature:setOutfit(localPlayer:getOutfit())
    creature:setVisible(true)
  end

  if not profileState then
    band:getChildById('rankLine'):setText('...')
    band:getChildById('storyLine'):setText('')
    band:getChildById('reputationLine'):setText('')
    head:getChildById('note'):setText('')
    return
  end

  band:getChildById('rankLine'):setText(profileState.rankName)
  -- The chapter TITLE, not a count. The count lives on the Rank tile, and
  -- naming the chapter is what makes the identity band read as a story.
  if profileState.chapterTitle ~= '' then
    band:getChildById('storyLine'):setText(profileState.chapterTitle)
  else
    band:getChildById('storyLine'):setText('His story has not begun for you yet')
  end
  band:getChildById('reputationLine'):setText(string.format('%s Reputation', comma(profileState.reputation)))

  local totalMastered, totalHunts = 0, 0
  for _, tier in ipairs(profileState.tiers) do
    totalMastered = totalMastered + tier.mastered
    totalHunts = totalHunts + tier.total
  end
  head:getChildById('note'):setText(string.format('%d of %d mastered', totalMastered, totalHunts))

  -- Eight tiles, four across. Ordered so the two a player would actually brag
  -- about -- rank and Ledger Score -- sit at the start of each row.
  local tiles = {
    { value = profileState.rankName,
      caption = string.format('Rank  -  %d of %d chapters heard',
        profileState.chaptersHeard, profileState.chaptersTotal) },
    { value = string.format('%d / %d', totalMastered, totalHunts),     caption = 'Hunts mastered' },
    { value = comma(profileState.huntsCompleted),                      caption = 'Hunts completed' },
    { value = comma(profileState.bountiesCompleted),                   caption = 'Orders delivered' },
    { value = comma(profileState.ledgerScore),                         caption = 'Ledger Score' },
    { value = comma(profileState.marksEarned),                         caption = 'Total Marks earned' },
    { value = string.format('%d / %d', profileState.outfits, profileState.outfitsTotal),
      caption = 'Outfits from Bao' },
    { value = string.format('%d / %d', profileState.mounts, profileState.mountsTotal),
      caption = 'Mounts from Bao' },
  }

  -- Three of these read almost the same at a glance, so each says exactly what
  -- it counts on hover.
  local TILE_HELP = {
    ['Hunts mastered'] = 'How many DIFFERENT hunts you have finished at least once. This is the number Bao counts toward your next chapter - repeating one hunt does not move it.',
    ['Hunts completed'] = 'Total hunt completions, including repeats of the same hunt.',
    ['Orders delivered'] = 'Weekly orders handed in, all time. The board offers nine a week and resets at server save.',
    ['Ledger Score'] = 'Every rank you have bought on Bao\'s Ledger, added together. It is the clearest single measure of how long you have worked with him.',
    ['Total Marks earned'] = 'Every Mark Bao has ever paid you. Spending never reduces it.',
  }

  for _, tile in ipairs(tiles) do
    local widget = g_ui.createWidget('BaoStatTile', grid)
    widget:getChildById('value'):setText(tile.value)
    widget:getChildById('caption'):setText(tile.caption)
    local help = TILE_HELP[tile.caption]
    if help then
      widget:setTooltip(help)
    end
  end

  for _, tier in ipairs(profileState.tiers) do
    local line = g_ui.createWidget('BaoStatLine', regions)
    local chip = line:getChildById('tierChip')
    chip:setText(tier.name)
    chip:setWidth(chip:getTextSize().width + 14)
    chip:setBackgroundColor(TIER_COLORS[tier.name] or '#4a4a4a')

    line:getChildById('value'):setText(string.format('%d / %d', tier.mastered, tier.total))
    local bar = line:getChildById('bar')
    bar:setPercent(percentOf(tier.mastered, tier.total))
    bar:setText('')
  end

  -- What Bao opens for you, beside the regions.
  --
  -- This column used to list the story chapters, which read as eight rows of
  -- "not yet told" -- structurally identical to the region list next to it and
  -- telling a new player nothing. What actually needs saying here is WHY Bao
  -- is worth their time early, so each row now names an unlock and what it
  -- costs. The story lives on the Chapters tab instead.
  local storyHead = window:recursiveGetChildById('storyHead')
  storyHead:getChildById('title'):setText('What Bao opens for you')

  local unlocked = 0
  for _, milestone in ipairs(profileState.milestones) do
    if milestone.done then
      unlocked = unlocked + 1
    end
  end
  storyHead:getChildById('note'):setText(string.format('%d of %d',
    unlocked, #profileState.milestones))

  for _, milestone in ipairs(profileState.milestones) do
    local line = g_ui.createWidget('BaoChapterLine', story)
    local mark = line:getChildById('mark')
    local title = line:getChildById('title')

    if milestone.done then
      mark:setText('x')
      mark:setColor(COLOR_POSITIVE)
      title:setText(milestone.label)
      title:setColor(COLOR_PRIMARY)
    else
      mark:setText('-')
      mark:setColor(COLOR_MUTED)
      -- The requirement is the whole point of the locked state: "Hunter,
      -- 2,500 Marks" is a goal, "locked" is a wall.
      title:setText(string.format('%s  -  %s', milestone.label, milestone.need))
      title:setColor(COLOR_TERTIARY)
    end
    line:setTooltip(milestone.note)
  end
end

-- Roman numerals for the page markers. The chapter TITLES already carry a
-- numeral ("Chapter I - The First Hunt"), but they are read as prose; the
-- marker column is what lets the eye run down the spine and see position.
local ROMAN = { 'I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X' }

-- Fills one page and sizes it. Three genuinely different states:
--
--   HEARD   gold spine, Bao's own words. The payoff.
--   NEXT    the one being reached for: two bars showing how close it is.
--   SEALED  title only. Deliberately NO requirement -- telling a Stray he
--           needs 1,499,646 more Reputation for Chapter VI is a true number
--           that only discourages, and hiding it is what makes the page
--           something to be curious about rather than a receipt.
--
-- (!) Height MUST be computed here. A wrapped label only reports a true height
-- once it has a width, and anchors have not been applied when a freshly
-- created widget is filled -- so the width is set explicitly first.
local function fillChapterRow(row, opts)
  local heard, isNext = opts.heard, opts.isNext
  local width = math.max(140, (opts.listWidth or 560) - 4 - 50 - 2 - 16)
  local accent = heard and COLOR_GOLD or (isNext and COLOR_POSITIVE or '#4a4a4a')

  row:getChildById('rail'):setBackgroundColor(accent)
  if isNext then
    -- See the ledger card: $on is a material swap, setBorderColor is a no-op
    -- on a row that no longer has a border.
    row:setOn(true)
  end

  local numeral = row:getChildById('numeral')
  numeral:setText(opts.numeral or '')
  numeral:setColor(heard and COLOR_GOLD or (isNext and COLOR_POSITIVE or '#4f4f4f'))

  local title = row:getChildById('title')
  title:setText(opts.title)
  title:setColor(heard and COLOR_PRIMARY or (isNext and COLOR_PRIMARY or COLOR_MUTED))

  local badge = row:getChildById('badge')
  badge:setText(opts.badge or '')
  badge:setColor(opts.badgeColor or COLOR_TERTIARY)

  local caption = row:getChildById('chapter')
  caption:setText(opts.caption or '')
  caption:setColor((heard or isNext) and COLOR_TERTIARY or COLOR_MUTED)

  -- Quoted, so a heard chapter reads as him speaking rather than as more
  -- interface copy.
  local prose = row:getChildById('prose')
  prose:setWidth(width)
  -- (!) One pixel of height BEFORE setText. A text-wrap label only wraps when
  -- its rect is valid, and a rect needs BOTH dimensions non-zero
  -- (UIWidget::updateText, uiwidgettext.cpp:43). prose is anchored
  -- left/right/top with no height, so without this the chapter text is stored
  -- as one unwrapped line, getTextSize() reports that single line back, the
  -- row is sized for it, and Bao's prose renders clipped mid-word at the row's
  -- right edge. Every chapter he has actually written runs past one line.
  prose:setHeight(1)
  local body = ''
  if heard and opts.text and opts.text ~= '' then
    body = '"' .. opts.text .. '"'
    prose:setColor('#c9bfa0')
  elseif isNext then
    body = 'He is close to telling you this one.'
    prose:setColor(COLOR_TERTIARY)
  else
    body = 'Sealed. He has not decided to trust you with this yet.'
    prose:setColor(COLOR_MUTED)
  end
  prose:setText(body)
  local proseHeight = prose:getTextSize().height
  prose:setHeight(proseHeight)

  -- The two bars, only on the chapter actually being reached for.
  local repTrack = row:getChildById('repTrack')
  local repLabel = row:getChildById('repLabel')
  local mastTrack = row:getChildById('mastTrack')
  local mastLabel = row:getChildById('mastLabel')
  local barHeight = 0

  if isNext and opts.progress then
    local p = opts.progress
    repTrack:show()
    repLabel:show()
    mastTrack:show()
    mastLabel:show()
    repTrack:getChildById('repMeter'):setPercent(percentOf(p.repHave, p.repNeed))
    repLabel:setText(string.format('Reputation  %s / %s', comma(p.repHave), comma(p.repNeed)))
    mastTrack:getChildById('mastMeter'):setPercent(percentOf(p.mastHave, p.mastNeed))
    mastLabel:setText(string.format('Hunts mastered  %d / %d', p.mastHave, p.mastNeed))
    barHeight = 8 + 6 + 3 + 12 + 7 + 6 + 3 + 12
  else
    repTrack:hide()
    repLabel:hide()
    mastTrack:hide()
    mastLabel:hide()
  end

  -- 12 top + title 14 + 3 + caption 12 + 7 + prose + bars + 12 bottom
  row:setHeight(12 + 14 + 3 + 12 + 7 + proseHeight + barHeight + 12)
end

local function drawRanks()
  local panel = window:recursiveGetChildById('ranksList')
  clearPanel(panel)
  if not baoState then
    return
  end

  local head = window:recursiveGetChildById('ranksHead')
  head:getChildById('title'):setText("The Hunter Who Came Home")
  head:getChildById('note'):setText(string.format('%d of %d chapters heard',
    baoState.chaptersHeard or 0, baoState.chaptersTotal or 0))
  head:setTooltip("Bao tells this in pieces, and only to hunters he has promoted. Every chapter here is a page he has already read you - the sealed ones are what he has not decided to trust you with yet.")

  local listWidth = panel:getWidth()
  local index = 0
  -- The lowest chapter not yet heard is the one being reached for; everything
  -- past it is sealed.
  local nextUnheard = nil
  for _, rank in ipairs(baoState.ranks) do
    if rank.chapterTitle ~= '' and rank.id > baoState.rankId and not nextUnheard then
      nextUnheard = rank.id
    end
  end

  -- Rank 0 tells no chapter, so it is skipped: a row reading "Stray - no
  -- chapter" is noise on a screen about the story.
  for _, rank in ipairs(baoState.ranks) do
    if rank.chapterTitle ~= '' then
      index = index + 1
      local row = g_ui.createWidget('BaoRankRow', panel)
      local reached = rank.id <= baoState.rankId
      local isNext = rank.id == nextUnheard

      fillChapterRow(row, {
        heard = reached,
        isNext = isNext,
        numeral = ROMAN[index] or tostring(index),
        title = rank.chapterTitle,
        caption = string.format('He names you %s', rank.name),
        badge = (rank.id == baoState.rankId) and 'you are here'
          or (reached and 'heard' or (isNext and 'next' or '')),
        badgeColor = isNext and COLOR_POSITIVE or COLOR_TERTIARY,
        text = rank.chapterText,
        progress = isNext and {
          repHave = baoState.reputation, repNeed = rank.repThreshold,
          mastHave = baoState.masteryCount, mastNeed = rank.masteriesRequired,
        } or nil,
        listWidth = listWidth,
      })
    end
  end

  -- Chapters no rank grants. They come from World's End hunts, so they sit
  -- past the end of the ladder rather than leaving a player waiting for a rank
  -- that will never come.
  for _, chapter in ipairs(baoState.epilogue or {}) do
    index = index + 1
    local row = g_ui.createWidget('BaoRankRow', panel)
    fillChapterRow(row, {
      heard = chapter.unlocked,
      numeral = ROMAN[index] or tostring(index),
      title = chapter.title,
      caption = "Told by a World's End hunt, not by a rank",
      badge = chapter.unlocked and 'heard' or '',
      text = chapter.chapterText,
      listWidth = listWidth,
    })
  end
end

-- ─── Header and redraw ──────────────────────────────────────────────────

local function redrawHeader()
  if not window or not baoState then
    return
  end

  local header = window:getChildById('header')
  header:getChildById('rankLabel'):setText(baoState.rankName)

  -- A pending promotion outranks the story line. Promotions are collected
  -- from Bao in person now, so the window has to say so -- otherwise a player
  -- who has met the requirements just sees a rank that refuses to change.
  local chapter = header:getChildById('chapterLabel')
  if baoState.pendingRankName then
    chapter:setText(string.format('Bao will name you %s -- go and see him', baoState.pendingRankName))
    chapter:setColor(COLOR_POSITIVE)
  elseif baoState.chaptersHeard and baoState.chaptersHeard > 0 then
    chapter:setText(string.format('%d of %d chapters of his story',
      baoState.chaptersHeard, baoState.chaptersTotal))
    chapter:setColor(COLOR_TERTIARY)
  else
    -- Teases rather than reporting a void. "He has not told you anything yet"
    -- was true but useless: a new player has no way to know Bao HAS a story,
    -- let alone that being promoted is what unlocks it.
    chapter:setText('He tells his story to those he promotes')
    chapter:setColor(COLOR_TERTIARY)
  end

  local bar = header:getChildById('reputationBar')
  local marksPlate = header:getChildById('marks')
  marksPlate:getChildById('value'):setText(comma(baoState.marks))
  -- The single most confusing thing in the window: two numbers that both go up
  -- when you finish something, only one of which you can ever spend.
  -- (!) Set on BOTH the plate and its value label. The plate is now solid
  -- (phantom:false) so it can be hovered at all, but the value label fills it
  -- and would otherwise win the hit test on its own -- whichever the pointer
  -- lands on, the same explanation appears.
  local marksHelp = "Hunter Marks are the currency. Hunts and orders pay them, and you spend them in Bao's Shop and on his Ledger. Spending them never costs you Reputation."
  marksPlate:setTooltip(marksHelp)
  marksPlate:getChildById('value'):setTooltip(marksHelp)
  bar:setTooltip('Reputation is what Bao thinks of you. It is never spent - it only ever counts up, and it is what earns you the next chapter of his story and the rank that comes with it.')

  -- (!) This is progress toward the NEXT RANK's mastery requirement, not a
  -- share of all 61 hunts. It read "2 / 3 hunts mastered", which looks like
  -- there are three hunts in the game -- so the denominator has to be named as
  -- a requirement, and the rank it is a requirement FOR.
  local mastery = header:getChildById('masteryLabel')
  local needed = baoState.nextRankMasteriesRequired
  if not needed then
    mastery:setText(string.format('%d hunts mastered', baoState.masteryCount))
  elseif baoState.masteryCount >= needed then
    -- Masteries can be satisfied long before the reputation is, and "5 of 3"
    -- is nonsense to read.
    mastery:setText(string.format('masteries done for %s', baoState.nextRankName))
  else
    mastery:setText(string.format('%d of %d masteries for %s',
      baoState.masteryCount, needed, baoState.nextRankName))
  end
  mastery:setTooltip('Distinct hunts you have finished at least once. Bao counts these toward your next chapter - repeating a hunt you have already mastered does not move it.')

  if baoState.nextRankRepThreshold then
    local span = math.max(1, baoState.nextRankRepThreshold - baoState.rankRepFloor)
    local into = math.max(0, baoState.reputation - baoState.rankRepFloor)
    bar:setPercent(math.min(100, math.floor((into / span) * 100)))
    bar:setText(string.format('%s / %s Reputation  -  %s next',
      comma(baoState.reputation), comma(baoState.nextRankRepThreshold), baoState.nextRankName))
  else
    bar:setPercent(100)
    bar:setText(string.format('%s Reputation  -  highest rank', comma(baoState.reputation)))
  end
end

local function redrawCurrentTab()
  if not window then
    return
  end
  if currentTab == 'profile' then
    drawProfile()
  elseif currentTab == 'hunts' then
    drawHunts()
  elseif currentTab == 'bounties' then
    drawBounties()
  elseif currentTab == 'mastered' then
    drawMastered()
  elseif currentTab == 'rewards' then
    drawRewards()
  elseif currentTab == 'ledger' then
    drawLedger()
  elseif currentTab == 'ranks' then
    drawRanks()
  end
end

local function redraw()
  redrawHeader()
  redrawCurrentTab()
end

-- The bounty countdown is the only thing in this window that changes without
-- the server saying so, so it is the only thing that gets a timer — and only
-- while its tab is actually visible.
local function stopBountyTicker()
  if bountyTicker then
    removeEvent(bountyTicker)
    bountyTicker = nil
  end
end

local function startBountyTicker()
  stopBountyTicker()
  local function tick()
    bountyTicker = nil
    if not window or not window:isVisible() or currentTab ~= 'bounties' then
      return
    end
    -- (!) Calls the SHARED builder rather than recomputing the text. This
    -- duplicated the countdown once before, kept reading the pre-rename
    -- `secondsUntilRotation` after the field became `secondsUntilReset`, and
    -- so resolved to nil -> 0 -- overwriting a correct "4d 13h" with
    -- "0m 0s" exactly one second after the tab opened.
    if bountyState then
      window:recursiveGetChildById('bountyHead'):getChildById('note'):setText(bountyNoteText())
    end
    bountyTicker = scheduleEvent(tick, 1000)
  end
  bountyTicker = scheduleEvent(tick, 1000)
end

function onFilterChanged()
  if currentTab == 'hunts' then
    drawHunts()
  end
end

function selectTab(tab)
  currentTab = tab

  window:getChildById('profilePanel'):setVisible(tab == 'profile')
  window:getChildById('huntsPanel'):setVisible(tab == 'hunts')
  window:getChildById('bountyPanel'):setVisible(tab == 'bounties')
  window:getChildById('masteredPanel'):setVisible(tab == 'mastered')
  window:getChildById('rewardsPanel'):setVisible(tab == 'rewards')
  window:getChildById('ledgerPanel'):setVisible(tab == 'ledger')
  window:getChildById('ranksPanel'):setVisible(tab == 'ranks')

  window:getChildById('tabProfile'):setChecked(tab == 'profile')
  window:getChildById('tabHunts'):setChecked(tab == 'hunts')
  window:getChildById('tabBounties'):setChecked(tab == 'bounties')
  window:getChildById('tabMastered'):setChecked(tab == 'mastered')
  window:getChildById('tabRewards'):setChecked(tab == 'rewards')
  window:getChildById('tabLedger'):setChecked(tab == 'ledger')
  window:getChildById('tabRanks'):setChecked(tab == 'ranks')

  if tab == 'profile' then
    -- Always re-requested: the Profile summarises half a dozen other systems,
    -- and a cached one would show a rank or a Ledger Score the player has
    -- already moved past.
    sendRequestProfile()
  elseif tab == 'rewards' then
    sendRequestShop()
  elseif tab == 'ledger' then
    sendRequestLedger()
  elseif tab == 'bounties' then
    -- Always re-requested rather than served from cache: a bounty's progress
    -- is the player's live inventory, so a cached board goes stale the moment
    -- they loot one more of the item.
    sendRequestBounty()
    startBountyTicker()
  else
    stopBountyTicker()
  end

  redrawCurrentTab()
end

-- ─── Opcode dispatch ────────────────────────────────────────────────────

local function onBaoOpcode(protocol, msg)
  local responseType = msg:getU8()
  if responseType == RESP_SYNC_FULL then
    baoState = parseSyncFull(msg)
    redraw()
  elseif responseType == RESP_OPEN_WINDOW then
    local tab = msg:getString()
    if window then
      window:show()
      window:raise()
      window:focus()
      selectTab(tab and tab ~= '' and tab or 'profile')
    end
  elseif responseType == RESP_ERROR then
    setStatus(msg:getString(), true)
  elseif responseType == RESP_STATUS then
    setStatus(msg:getString(), false)
  elseif responseType == RESP_SHOP_DATA then
    shopState = parseShopData(msg)
    if currentTab == 'rewards' then
      redrawCurrentTab()
    end
  elseif responseType == RESP_PROFILE_DATA then
    profileState = parseProfileData(msg)
    if currentTab == 'profile' then
      redrawCurrentTab()
    end
  elseif responseType == RESP_LEDGER_DATA then
    ledgerState = parseLedgerData(msg)
    if currentTab == 'ledger' then
      redrawCurrentTab()
    end
  elseif responseType == RESP_BOUNTY_DATA then
    bountyState = parseBountyData(msg)
    if currentTab == 'bounties' then
      redrawCurrentTab()
    end
  end
  return true
end

-- ─── Module lifecycle ───────────────────────────────────────────────────

local function populateFilters()
  local tierCombo = window:recursiveGetChildById('tierFilter')
  tierCombo:clearOptions()
  tierCombo:addOption('Any chapter')
  for _, tier in ipairs(TIER_ORDER) do
    tierCombo:addOption(tier)
  end
  tierCombo:setCurrentOption('Any chapter', true)
  tierCombo.onOptionChange = function() onFilterChanged() end

  local sortCombo = window:recursiveGetChildById('sortMode')
  sortCombo:clearOptions()
  for _, mode in ipairs(SORT_MODES) do
    sortCombo:addOption(mode.label)
  end
  sortCombo:setCurrentOption(SORT_MODES[1].label, true)
  sortCombo.onOptionChange = function() onFilterChanged() end
end

-- (!) Kills the "first click on Accept does nothing and the list jumps" bug.
--
-- UIWidget::recursiveFocus walks UP the parent chain on mouse press and lets
-- the first FOCUSABLE ancestor be focused. Cards and buttons here are already
-- non-focusable, but the BaoCardGrid panel between them and the list is a
-- plain Panel, and Panels are focusable by default -- so the grid got focused
-- and UIScrollArea:onChildFocusChange called ensureChildVisible on it. That
-- grid is several 206px rows tall, so "make it visible" scrolls the list hard,
-- the content moves under the cursor mid-click, and the release lands on a
-- different widget than the press -- which means the button never fires.
--
-- Disabling the handler on the scroll areas themselves is the fix that cannot
-- be defeated by nesting a new panel in later.
local SCROLL_LISTS = {
  'huntsList', 'bountyList', 'masteredList', 'rewardsList', 'ledgerList', 'ranksList',
}

local function stopFocusScrolling()
  for _, id in ipairs(SCROLL_LISTS) do
    local list = window:recursiveGetChildById(id)
    if list then
      list.onChildFocusChange = function() end
    end
  end
end

-- A character change must not leave the last character's Bao data on screen
-- or a confirm armed for them. Same pattern as game_bazaar's onGameEnd: hide,
-- then forget everything that belongs to the character who logged out. The
-- header keeps its old text until the next login's sync redraws it (show()
-- asks for one), but the window is hidden until then.
local function onGameEnd()
  hide()
  if statusEvent then
    removeEvent(statusEvent)
    statusEvent = nil
  end
  baoState = nil
  shopState = nil
  bountyState = nil
  ledgerState = nil
  profileState = nil
  pendingConfirm = nil
end

function init()
  g_ui.importStyle('bao')
  window = g_ui.createWidget('BaoWindow', rootWidget)
  window:hide()
  stopFocusScrolling()
  populateFilters()

  ProtocolGame.registerOpcode(OPCODE_BAO_SEND, onBaoOpcode)
  connect(g_game, { onGameEnd = onGameEnd })
end

function terminate()
  disconnect(g_game, { onGameEnd = onGameEnd })
  ProtocolGame.unregisterOpcode(OPCODE_BAO_SEND)
  stopBountyTicker()
  if statusEvent then
    removeEvent(statusEvent)
    statusEvent = nil
  end
  if window then
    window:destroy()
    window = nil
  end
  baoState = nil
  shopState = nil
  bountyState = nil
  ledgerState = nil
  profileState = nil
  pendingConfirm = nil
end

function hide()
  if not window then
    return
  end
  hideConfirm()
  stopBountyTicker()
  window:hide()
end

function show()
  if not window then
    return
  end
  sendRequestSync()
  window:show()
  window:raise()
  window:focus()
  -- (!) Re-select the current tab rather than only syncing. Every tab except
  -- Hunts and Active needs its OWN request (shop, bounties, ledger, profile),
  -- and selectTab is what issues it. Without this, opening the window on the
  -- default Profile tab sat on "Bao is checking his books..." until the player
  -- switched away and back.
  selectTab(currentTab)
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
