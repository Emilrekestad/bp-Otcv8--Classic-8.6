-- Quest Log window.
--
-- Mirrors game_achievements / game_bao: one raw opcode claimed per direction
-- via ProtocolGame.registerOpcode (client) / PacketHandler (server), a
-- sub-type byte inside the payload for routing, full state cached
-- client-side and redrawn from cache on every filter change rather than
-- re-requested. See data/scripts/network/questlog/questlog_protocol.lua for
-- the server side and why this replaced the native quest-log packets.
--
-- Reminder for anyone editing this file: the CLIENT runs Lua 5.1. Integer
-- division (//), goto and bitwise operators are all syntax errors here even
-- though the server's 5.5 accepts them.

-- 0x54/0x55 (84/85 decimal): see questlog_protocol.lua's header for the full
-- checklist this was confirmed against (native opcodes on both ends, and
-- every other custom opcode already claimed in this codebase).
local OPCODE_QUESTLOG_REQUEST = 0x54 -- client -> server
local OPCODE_QUESTLOG_SEND = 0x55    -- server -> client

local RESP_LOG = 0x01
local RESP_LINE = 0x02

local ACTION_REQUEST_LOG = 0x01
local ACTION_REQUEST_LINE = 0x02

local COLOR_PRIMARY = '#f6f1e2'
-- Was #5f5f5f, which was nearly unreadable -- and on an account where every
-- quest is finished that meant the ENTIRE list was unreadable. Completion is
-- signalled by the rail and the "Done" marker now, so this only needs to sit
-- one clear step below an open quest's name rather than disappear.
local COLOR_DONE_NAME = '#b0b0b0'

local SHOW_MODES = {
  { label = 'All quests',  key = 'all' },
  { label = 'In progress', key = 'inprogress' },
  { label = 'Completed',   key = 'completed' },
}

local window = nil

-- The full quest list from the last RESP_LOG, cached so filtering/search
-- re-renders locally instead of round-tripping to the server.
local questCache = {}

local selectedQuestId = nil
local selectedQuestName = nil
local currentMissions = nil -- from the last RESP_LINE for selectedQuestId

-- Which completed missions the player has clicked open, keyed by their index
-- within currentMissions. Reset whenever the selected quest changes (indices
-- are only meaningful against one quest's mission list).
local expandedMissions = {}

local searchEvent = nil

-- (!) Defense against a dropped response: a live packet.log capture caught
-- the server's RESP_LOG (opcode 0x55, correctly carrying all 30 quests)
-- arriving while nothing was registered for it client-side yet (see the
-- ordering bug fixed in questlog.otmod -- game_questlog used to load behind
-- game_sidebuttons in game_interface's load-later chain, so a click on the
-- now-live sidebar button could fire a request before init() had run). That
-- turned into a silently half-populated window: a stale summary next to a
-- near-empty list, with nothing telling the player anything had failed.
-- autoload fixes the root cause, but a request that never gets a reply
-- should still say so instead of leaving the window looking like real (if
-- sparse) data. One retry, then a plain failure state.
local logRequestToken = 0
local logRequestTimeout = nil
local lineRequestTimeout = nil
local LOG_TIMEOUT_MS = 4000
local LINE_TIMEOUT_MS = 4000

-- ─── Sends ──────────────────────────────────────────────────────────────

local function sendAction(build)
  local protocolGame = g_game.getProtocolGame()
  if not protocolGame then
    return
  end
  local msg = OutputMessage.create()
  msg:addU8(OPCODE_QUESTLOG_REQUEST)
  build(msg)
  protocolGame:send(msg)
end

-- forward declarations: the timeout handlers call back into these, and the
-- request senders schedule the timeouts, so each side needs the other.
local retryRequestLog
local showLogFailure
local showLineFailure

local function armLogTimeout(token, isRetry)
  if logRequestTimeout then
    removeEvent(logRequestTimeout)
  end
  logRequestTimeout = scheduleEvent(function()
    logRequestTimeout = nil
    if token ~= logRequestToken then
      return -- superseded by a newer request (window closed/reopened)
    end
    if isRetry then
      showLogFailure()
    else
      retryRequestLog()
    end
  end, LOG_TIMEOUT_MS)
end

local function sendRequestLog(isRetry)
  logRequestToken = logRequestToken + 1
  local token = logRequestToken
  sendAction(function(msg) msg:addU8(ACTION_REQUEST_LOG) end)
  armLogTimeout(token, isRetry)
end

retryRequestLog = function()
  sendRequestLog(true)
end

local function sendRequestLine(questId)
  if lineRequestTimeout then
    removeEvent(lineRequestTimeout)
  end
  local requestedId = questId
  lineRequestTimeout = scheduleEvent(function()
    lineRequestTimeout = nil
    if requestedId == selectedQuestId then
      showLineFailure()
    end
  end, LINE_TIMEOUT_MS)

  sendAction(function(msg)
    msg:addU8(ACTION_REQUEST_LINE)
    msg:addU16(questId)
  end)
end

-- ─── Helpers ────────────────────────────────────────────────────────────

local function selectedShowMode()
  if not window then
    return 'all'
  end
  local combo = window:recursiveGetChildById('showFilter')
  local option = combo and combo:getCurrentOption()
  if not option then
    return 'all'
  end
  for _, mode in ipairs(SHOW_MODES) do
    if mode.label == option.text then
      return mode.key
    end
  end
  return 'all'
end

local function searchTerm()
  if not window then
    return ''
  end
  local edit = window:recursiveGetChildById('searchEdit')
  return edit and edit:getText():lower() or ''
end

local function matchesFilter(quest, mode, term)
  if mode == 'inprogress' and quest.completed then
    return false
  end
  if mode == 'completed' and not quest.completed then
    return false
  end
  if term ~= '' and not quest.name:lower():find(term, 1, true) then
    return false
  end
  return true
end

-- ─── Rendering: quest list (left pane) ─────────────────────────────────

local function updateSummary()
  if not window then
    return
  end
  local total = #questCache
  local done = 0
  for _, quest in ipairs(questCache) do
    if quest.completed then
      done = done + 1
    end
  end

  local summaryLine = window:recursiveGetChildById('summaryLine')
  summaryLine.onClick = nil
  summaryLine:setText(string.format('%d of %d quests complete', done, total))

  local bar = window:recursiveGetChildById('summaryBar')
  bar:setPercent(total > 0 and math.floor((done / total) * 100) or 0)

  local shownCount = window:recursiveGetChildById('shownCount')
  local mode = selectedShowMode()
  local term = searchTerm()
  local shown = 0
  for _, quest in ipairs(questCache) do
    if matchesFilter(quest, mode, term) then
      shown = shown + 1
    end
  end
  shownCount:setText(string.format('%d shown', shown))
end

showLogFailure = function()
  if not window then
    return
  end
  local summaryLine = window:recursiveGetChildById('summaryLine')
  summaryLine:setText("Couldn't load the quest log -- click to retry")
  summaryLine.onClick = function()
    summaryLine.onClick = nil
    summaryLine:setText('Loading...')
    retryRequestLog()
  end
end

showLineFailure = function()
  if not window then
    return
  end
  local statusLine = window:recursiveGetChildById('statusLine')
  local questId = selectedQuestId
  statusLine:setText("Couldn't load this quest's missions -- click to retry")
  statusLine.onClick = function()
    statusLine.onClick = nil
    statusLine:setText('Loading...')
    sendRequestLine(questId)
  end
end

local function selectQuestRow(row, questId, questName)
  -- Focusing (rather than a manual setChecked sweep over siblings) is the
  -- pattern game_bazaar's row selection already uses: focusing one row
  -- inside the same parent automatically un-focuses whatever was focused
  -- before it, and the $focus: selector in questlogwindow.otui carries the
  -- highlight -- no need to iterate the list's children by hand.
  row:focus()

  selectedQuestId = questId
  selectedQuestName = questName
  currentMissions = nil
  expandedMissions = {}

  local titleLabel = window:recursiveGetChildById('missionPaneTitle')
  titleLabel:setText(questName)

  local emptyNotice = window:recursiveGetChildById('emptyNotice')
  emptyNotice:setVisible(false)

  local detail = window:recursiveGetChildById('missionDetail')
  detail:destroyChildren()

  local statusLine = window:recursiveGetChildById('statusLine')
  statusLine.onClick = nil
  statusLine:setText('Loading...')

  sendRequestLine(questId)
end

local function drawQuestList()
  if not window then
    return
  end

  local list = window:recursiveGetChildById('questList')
  list:destroyChildren()

  local mode = selectedShowMode()
  local term = searchTerm()

  for _, quest in ipairs(questCache) do
    if matchesFilter(quest, mode, term) then
      local row = g_ui.createWidget('QLQuestRow', list)
      row.questId = quest.id

      local nameLabel = row:getChildById('name')
      nameLabel:setText(quest.name)

      local countLabel = row:getChildById('count')
      countLabel:setText(string.format('%d / %d missions', quest.missionsCompleted, quest.missionsTotal))

      local rail = row:getChildById('rail')
      local track = row:getChildById('track')
      local doneMark = row:getChildById('doneMark')

      -- Green means "still open", never "finished" -- see the accent note on
      -- QLQuestRow. A completed quest drops the meter entirely rather than
      -- showing a 100%-full one, which is what made a finished account read
      -- as a solid block of green.
      if quest.completed then
        nameLabel:setColor(COLOR_DONE_NAME)
        rail:setBackgroundColor('#3f4a3d')
        track:setVisible(false)
        doneMark:setVisible(true)
      else
        nameLabel:setColor(COLOR_PRIMARY)
        rail:setBackgroundColor('#8fd97f')
        track:setVisible(true)
        doneMark:setVisible(false)

        -- recursive, not getChildById: the meter sits inside its groove Panel
        -- ('track'), and getChildById only ever scans DIRECT children. This
        -- returned nil and crashed drawQuestList on its very first row, which
        -- is what left the window showing one quest and a stuck "Loading...".
        local bar = row:recursiveGetChildById('rowBar')
        local percent = quest.missionsTotal > 0
          and math.floor((quest.missionsCompleted / quest.missionsTotal) * 100)
          or 0
        bar:setPercent(percent)
      end

      if quest.id == selectedQuestId then
        row:focus()
      end

      row.onClick = function()
        selectQuestRow(row, quest.id, quest.name)
      end
    end
  end

  updateSummary()
end

-- ─── Rendering: mission detail (right pane) ────────────────────────────

local function drawMissionDetail()
  if not window then
    return
  end

  local detail = window:recursiveGetChildById('missionDetail')
  detail:destroyChildren()

  local emptyNotice = window:recursiveGetChildById('emptyNotice')
  local statusLine = window:recursiveGetChildById('statusLine')

  if not currentMissions or #currentMissions == 0 then
    emptyNotice:setText('Nothing to show for this quest right now.')
    emptyNotice:setVisible(true)
    statusLine:setText('')
    return
  end

  emptyNotice:setVisible(false)

  -- The hint only appears when there is actually something collapsed to open,
  -- so it is never advice the player cannot act on.
  local doneCount = 0
  for _, mission in ipairs(currentMissions) do
    if mission.completed then
      doneCount = doneCount + 1
    end
  end

  local status = string.format('%s: %d mission%s shown', selectedQuestName or '',
    #currentMissions, #currentMissions == 1 and '' or 's')
  if doneCount > 0 then
    status = status .. ' -- click a completed mission to read it'
  end
  statusLine:setText(status)

  -- (!) QLMissionCard has no OTUI height on purpose -- descriptions run one
  -- line to several, same reasoning as Bao's BaoRankRow (see fillChapterRow's
  -- comment in bao.lua): "a wrapped label only reports a true height once it
  -- has a width, and anchors have not been applied when a freshly created
  -- widget is filled -- so the width is set explicitly first."
  --
  -- (!!) A WIDTH IS NOT ENOUGH. UIWidget::updateText only wraps when the
  -- label's rect is VALID, and a rect needs both dimensions non-zero
  -- (uiwidgettext.cpp:43). These labels are anchored left/right/top with no
  -- height, so on the frame they are filled the height is 0, the text is
  -- stored unwrapped, and getTextSize() -- which measures the stored draw
  -- text, not the source string -- hands back a single line. The card is then
  -- sized for one line and the description renders CLIPPED MID-WORD at its
  -- right edge, which looks like truncated data rather than a layout fault.
  -- Setting one pixel of height before setText is what makes the rect valid.
  --
  -- A verticalBox
  -- child auto-expands its WIDTH to fill the container once laid out
  -- (confirmed against src/framework/ui/uiverticallayout.cpp -- that only
  -- depends on isFixedSize(), which nothing here sets), but that has not
  -- happened yet for a widget on the same frame it was created, so the
  -- description label's width is computed from the pane's own width and set
  -- by hand, matching Bao's fix exactly.
  local paneWidth = detail:getWidth()
  local descWidth = math.max(140, paneWidth - 3 - 12 - 12)
  -- Done rows indent their description under the title: 8 left margin + 32
  -- 'Done' chip + 6 gap on the left, 8 on the right.
  local doneDescWidth = math.max(140, paneWidth - 8 - 32 - 6 - 8)

  for index, mission in ipairs(currentMissions) do
    if mission.completed then
      local widget = g_ui.createWidget('QLMissionDone', detail)
      widget:getChildById('title'):setText(mission.name)

      local description = widget:getChildById('description')
      if expandedMissions[index] then
        -- setWidth before setText before getTextSize, same ordering rule the
        -- card below depends on.
        description:setWidth(doneDescWidth)
        -- (!) One pixel of height BEFORE setText, or the label's rect is
        -- invalid and text-wrap does not run at all -- see the note at the
        -- top of drawMissionDetail.
        description:setHeight(1)
        description:setText(mission.description)
        description:setHeight(description:getTextSize().height)
        description:setVisible(true)
        -- 4 top margin + ~14 title line + 4 gap + text + 8 bottom padding
        widget:setHeight(4 + 14 + 4 + description:getHeight() + 8)
      else
        description:setVisible(false)
        widget:setHeight(22)
      end

      widget.onClick = function()
        expandedMissions[index] = not expandedMissions[index]
        drawMissionDetail()
      end
    else
      local widget = g_ui.createWidget('QLMissionCard', detail)
      widget:getChildById('name'):setText(mission.name)

      local description = widget:getChildById('description')
      description:setWidth(descWidth)
      -- (!) See above: one pixel of height first, or the rect is invalid and
      -- the description renders as one clipped line.
      description:setHeight(1)
      description:setText(mission.description)
      local descHeight = description:getTextSize().height
      description:setHeight(descHeight)

      local extra = 10 -- bottom padding when there is no progress bar
      if mission.hasProgress then
        local progressRow = widget:getChildById('progressRow')
        local progressLabel = widget:getChildById('progressLabel')
        progressRow:setVisible(true)
        progressLabel:setVisible(true)
        -- recursive for the same reason as rowBar above: this meter is two
        -- levels down (card > progressRow > track > meter). Latent twin of
        -- the drawQuestList crash -- it would have fired the first time a
        -- quest with a counter mission (Bigfoot's Burden's dailies) was
        -- opened, rather than at list-draw time.
        widget:recursiveGetChildById('cardBar'):setPercent(mission.progressPercent)
        progressLabel:setText(mission.progressPercent .. '%')
        extra = 8 + 6 + 10 -- progressRow's own top margin + bar height + bottom margin
      end

      -- 10 top + name ~15 + 5 gap + description + (progress bar or bottom pad)
      widget:setHeight(10 + 15 + 5 + descHeight + extra)
    end
  end
end

-- ─── Network ────────────────────────────────────────────────────────────

local function parseQuestLog(msg)
  local count = msg:getU16()
  local quests = {}
  for _ = 1, count do
    local id = msg:getU16()
    local name = msg:getString()
    local completed = msg:getU8() == 1
    local missionsCompleted = msg:getU8()
    local missionsTotal = msg:getU8()
    quests[#quests + 1] = {
      id = id,
      name = name,
      completed = completed,
      missionsCompleted = missionsCompleted,
      missionsTotal = missionsTotal,
    }
  end
  return quests
end

local function parseQuestLine(msg)
  local questId = msg:getU16()
  local questName = msg:getString()
  local missionCount = msg:getU8()
  local missions = {}
  for _ = 1, missionCount do
    local name = msg:getString()
    local description = msg:getString()
    local completed = msg:getU8() == 1
    local hasProgress = msg:getU8() == 1
    local progressPercent = msg:getU8()
    missions[#missions + 1] = {
      name = name,
      description = description,
      completed = completed,
      hasProgress = hasProgress,
      progressPercent = progressPercent,
    }
  end
  return questId, questName, missions
end

local function onQuestlogOpcode(protocol, msg)
  local responseType = msg:getU8()

  if responseType == RESP_LOG then
    if logRequestTimeout then
      removeEvent(logRequestTimeout)
      logRequestTimeout = nil
    end
    questCache = parseQuestLog(msg)
    drawQuestList()
  elseif responseType == RESP_LINE then
    local questId, questName, missions = parseQuestLine(msg)
    -- A slow reply for a quest the player has since clicked away from should
    -- not overwrite what is now showing.
    if questId == selectedQuestId then
      if lineRequestTimeout then
        removeEvent(lineRequestTimeout)
        lineRequestTimeout = nil
      end
      selectedQuestName = questName
      currentMissions = missions
      drawMissionDetail()
    end
  end

  return true
end

-- ─── Filter wiring ──────────────────────────────────────────────────────

local function onFilterChanged()
  drawQuestList()
end

local function onSearchChanged()
  if searchEvent then
    removeEvent(searchEvent)
  end
  searchEvent = scheduleEvent(function()
    searchEvent = nil
    drawQuestList()
  end, 180)
end

local function populateFilters()
  local showCombo = window:recursiveGetChildById('showFilter')
  showCombo:clearOptions()
  for _, mode in ipairs(SHOW_MODES) do
    showCombo:addOption(mode.label)
  end
  showCombo:setCurrentOption(SHOW_MODES[1].label, true)
  showCombo.onOptionChange = function() onFilterChanged() end

  local search = window:recursiveGetChildById('searchEdit')
  search.onTextChange = function() onSearchChanged() end
end

-- (!) Same fix game_bao / game_achievements both need for a tall list of
-- focusable rows: UIWidget::recursiveFocus walks UP to the first focusable
-- ancestor on mouse press, and UIScrollArea:onChildFocusChange then calls
-- ensureChildVisible on it -- which scrolls the list hard mid-click, so the
-- release lands on a different row than the press. Disabling the handler on
-- the scroll area itself is the fix that cannot be defeated by nesting a
-- panel in later.
local function stopFocusScrolling()
  local list = window:recursiveGetChildById('questList')
  if list then
    list.onChildFocusChange = function() end
  end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────

function show()
  if not window then
    return
  end

  -- Fires on every open (not just the first) since this window and its
  -- questCache are process-lifetime singletons with no per-login reset --
  -- without this, reopening after a relog as a different character would
  -- show the previous character's quest data for however long the new
  -- reply takes to arrive.
  local summaryLine = window:recursiveGetChildById('summaryLine')
  summaryLine.onClick = nil
  summaryLine:setText('Loading...')

  sendRequestLog()
  window:show()
  window:raise()
  window:focus()
end

function hide()
  if window then
    window:hide()
  end
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

-- A character change must not leave the last character's quests on screen
-- or in memory. Same pattern as game_bazaar's onGameEnd: hide, then forget
-- everything that belongs to the character who just logged out.
local function onGameEnd()
  hide()

  logRequestToken = logRequestToken + 1 -- a late timeout for the old login does nothing
  if searchEvent then
    removeEvent(searchEvent)
    searchEvent = nil
  end
  if logRequestTimeout then
    removeEvent(logRequestTimeout)
    logRequestTimeout = nil
  end
  if lineRequestTimeout then
    removeEvent(lineRequestTimeout)
    lineRequestTimeout = nil
  end

  questCache = {}
  selectedQuestId = nil
  selectedQuestName = nil
  currentMissions = nil
  expandedMissions = {}

  if not window then
    return
  end
  window:recursiveGetChildById('questList'):destroyChildren()
  window:recursiveGetChildById('missionDetail'):destroyChildren()
  window:recursiveGetChildById('missionPaneTitle'):setText('Select a quest')
  window:recursiveGetChildById('emptyNotice'):setVisible(false)
  local statusLine = window:recursiveGetChildById('statusLine')
  statusLine.onClick = nil
  statusLine:setText('')
end

function init()
  g_ui.importStyle('questlogwindow')
  window = g_ui.createWidget('QuestLogWindow', rootWidget)
  window:hide()
  stopFocusScrolling()
  populateFilters()

  ProtocolGame.registerOpcode(OPCODE_QUESTLOG_SEND, onQuestlogOpcode)
  connect(g_game, { onGameEnd = onGameEnd })
end

function terminate()
  disconnect(g_game, { onGameEnd = onGameEnd })
  ProtocolGame.unregisterOpcode(OPCODE_QUESTLOG_SEND)

  if searchEvent then
    removeEvent(searchEvent)
    searchEvent = nil
  end

  if logRequestTimeout then
    removeEvent(logRequestTimeout)
    logRequestTimeout = nil
  end

  if lineRequestTimeout then
    removeEvent(lineRequestTimeout)
    lineRequestTimeout = nil
  end

  if window then
    window:destroy()
    window = nil
  end
end
