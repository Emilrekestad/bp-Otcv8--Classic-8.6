-- Options. One window, sections on a rail, and a search box over all of them.
--
-- The public surface other modules use is unchanged: setOption(key, value,
-- force), getOption(key), toggleOption(key), toggle() / show() / hide().
--
-- What changed underneath: there is no longer a hub window plus four
-- sub-windows. Every control lives in one options.otui, and a registry built
-- from that file at startup maps an option key to its widget, its section and
-- the words that should find it. setOption pushes a value into one widget
-- instead of hunting for it in four windows.

local defaultOptions = {
	leftPanels = 0,
	classicView = true,
	dontStretchShrink = false,
	fullscreen = false,
	showPing = true,
	showFps = true,
	hdmodeBox = true,
	vsync = true,
	floorFading = 100,
	crosshair = 1,
	displayHealth = true,
	displayMana = false,
	displayHealthOnTop = false,
	showHealthManaCircle = false,
	antialiasing = true,
	profile = 1,
	actionbarLock = false,
	actionbar9 = false,
	actionbar8 = false,
	actionbar7 = false,
	actionbar6 = false,
	actionbar5 = false,
	actionbar4 = false,
	actionbar3 = false,
	actionbar2 = false,
	actionbar1 = false,
	topBar = false,
	walkCtrlTurnDelay = 150,
	walkTeleportDelay = 50,
	walkStairsDelay = 50,
	walkTurnDelay = 100,
	walkFirstStepDelay = 100,
	moveFullStack = false,
	wsadWalking = false,
	hotkeyDelay = 30,
	turnDelay = 100,
	displayText = true,
	topHealtManaBar = false,
	hidePlayerBars = true,
	backgroundFrameRate = 60,
	containerPanel = 8,
	displayNames = true,
	rightPanels = 1,
	showPrivateMessagesOnScreen = true,
	showPrivateMessagesInConsole = true,
	showLootMessagesOnScreen = false,
	showLevelsInConsole = true,
	showTimestampsInConsole = true,
	showInfoMessagesInConsole = true,
	showEventMessagesInConsole = true,
	showStatusMessagesInConsole = true,
	autoChaseOverride = true,
	dash = false,
	smartWalk = false,
	layout = DEFAULT_LAYOUT,
	cacheMap = g_app.isMobile(),
	classicControl = not g_app.isMobile()
}

optionsWindow = nil
optionsButton = nil
options = {}
extraOptions = {}

-- Section order on the rail. The id is both the nav button's id and the
-- suffix of its content panel ("section-<id>").
local SECTIONS = { "controls", "interface", "graphics", "console", "actionbars", "hotkeys", "about" }

-- The frame rate combo is a list of stops, not a slider: nobody wants 137 fps.
-- Index 6 is the engine's "no limit" (setMaxFps(0)).
local FRAME_RATE_STOPS = { 30, 60, 75, 120, 144, 0 }

-- Extra words that should find a row. The row's own label and tooltip are
-- searched already; these are the names people actually type.
local SEARCH_WORDS = {
	classicControl = "mouse click controls right-click",
	autoChaseOverride = "follow target chase attack",
	wsadWalking = "wasd keyboard movement walk keys",
	smartWalk = "diagonal movement walk",
	moveFullStack = "stack items drag amount",
	displayText = "speech bubbles talk messages",
	leftPanels = "sidebar panels containers columns",
	displayNames = "nicknames labels creatures",
	displayHealth = "hp bars creatures",
	displayHealthOnTop = "hp bars creatures overlap",
	displayMana = "mp bars",
	showPing = "latency lag ms connection",
	showFps = "fps frames per second performance",
	vsync = "tearing refresh rate performance",
	fullscreen = "window borderless screen",
	dontStretchShrink = "scaling window size zoom",
	antialiasing = "smoothing sharp pixels",
	hdmodeBox = "hd sprites resolution sharp",
	backgroundFrameRate = "fps frame limit performance cap",
	showInfoMessagesInConsole = "chat log messages",
	showEventMessagesInConsole = "chat log messages",
	showStatusMessagesInConsole = "chat log messages",
	showTimestampsInConsole = "chat log time clock",
	showLevelsInConsole = "chat log level",
	showPrivateMessagesInConsole = "chat log whisper pm",
	showPrivateMessagesOnScreen = "chat whisper pm screen",
	showLootMessagesOnScreen = "loot drops chat channel",
	actionbarLock = "hotbar keys chat",
	profile = "layout preset setup"
}

-- Words that should find a whole section even when no single row matches.
local SECTION_WORDS = {
	controls = "keyboard mouse walking movement",
	interface = "hud panels layout bars names",
	graphics = "video display light",
	console = "chat log messages channels",
	actionbars = "hotbar action bars buttons",
	hotkeys = "keys binds shortcuts macros",
	about = "version website compendium motd news"
}

-- key -> { widget, row, section, text } for every option the window shows.
local rows = {}
local sectionPanels = {}
local navButtons = {}
local currentSection = nil
local searchText = ""

local function lower(text)
	return tostring(text or ""):lower()
end

-- The searchable text of a row: its own label, its tooltip, its section, and
-- the synonyms above.
local function rowSearchText(key, widget, section)
	local parts = { lower(key), lower(section) }

	local text = widget.getText and widget:getText() or nil
	if text and #text > 0 then
		table.insert(parts, lower(text))
	end

	local tooltip = widget.getTooltip and widget:getTooltip() or nil
	if tooltip and #tooltip > 0 then
		table.insert(parts, lower(tooltip))
	end

	if SEARCH_WORDS[key] then
		table.insert(parts, SEARCH_WORDS[key])
	end

	return table.concat(parts, " ")
end

-- Walks one section panel and registers every widget whose id is an option
-- key. The row is the direct child of the section that contains the widget --
-- that is what gets shown or hidden by a search.
local function registerSection(sectionId)
	local panel = optionsWindow:recursiveGetChildById("section-" .. sectionId)

	if not panel then
		g_logger.error("client_options: section-" .. sectionId .. " is missing from options.otui")
		return
	end

	sectionPanels[sectionId] = panel

	local function walk(widget, row)
		for _, child in ipairs(widget:getChildren()) do
			local id = child:getId()

			if id and (defaultOptions[id] ~= nil or extraOptions[id] ~= nil) then
				rows[id] = {
					widget = child,
					row = row or child,
					section = sectionId,
					text = rowSearchText(id, child, sectionId)
				}
			end

			walk(child, row or child)
		end
	end

	walk(panel, nil)
end

local function eachSectionRow(sectionId, fn)
	for key, entry in pairs(rows) do
		if entry.section == sectionId then
			fn(key, entry)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Sections
-- ---------------------------------------------------------------------------

function selectSection(sectionId)
	if not sectionPanels[sectionId] then
		return
	end

	currentSection = sectionId

	-- Choosing a section leaves search mode.
	if #searchText > 0 then
		searchText = ""

		local edit = optionsWindow:getChildById("searchEdit")
		if edit and #edit:getText() > 0 then
			edit:setText("")
		end
	end

	for _, id in ipairs(SECTIONS) do
		local panel = sectionPanels[id]

		if panel then
			-- Every row is visible again: a previous search may have hidden some.
			eachSectionRow(id, function(_, entry)
				entry.row:setVisible(true)
			end)
			panel:setVisible(id == sectionId)
		end

		if navButtons[id] then
			navButtons[id]:setChecked(id == sectionId)
		end
	end

	local status = optionsWindow:getChildById("searchStatus")
	if status then
		status:setVisible(false)
	end

	-- setValue(0) does not move a panel already at 0; reset the offset itself.
	local well = optionsWindow:getChildById("contentWell")
	if well then
		well:setVirtualOffset({ x = 0, y = 0 })
	end

	local bar = optionsWindow:getChildById("contentScrollBar")
	if bar then
		bar:setValue(0)
	end
end

-- ---------------------------------------------------------------------------
-- Search
-- ---------------------------------------------------------------------------

-- Scores one row against the typed words. Every word must hit something, so
-- "music volume" does not match every row that mentions music.
local function scoreRow(entry, words)
	local score = 0

	for _, word in ipairs(words) do
		local at = entry.text:find(word, 1, true)

		if not at then
			return 0
		end

		if at == 1 then
			score = score + 3
		else
			score = score + 1
		end
	end

	return score
end

function onSearchChange(text)
	searchText = lower(text)

	local status = optionsWindow:getChildById("searchStatus")

	if #searchText < 2 then
		if currentSection then
			-- Back to the section that was open, without clearing the box again.
			for _, id in ipairs(SECTIONS) do
				local panel = sectionPanels[id]

				if panel then
					eachSectionRow(id, function(_, entry)
						entry.row:setVisible(true)
					end)
					panel:setVisible(id == currentSection)
				end

				if navButtons[id] then
					navButtons[id]:setChecked(id == currentSection)
				end
			end
		end

		if status then
			status:setVisible(false)
		end

		return
	end

	local words = {}
	for word in searchText:gmatch("%S+") do
		table.insert(words, word)
	end

	local hits = 0

	for _, id in ipairs(SECTIONS) do
		local panel = sectionPanels[id]
		local sectionHits = 0

		-- A section whose own name is searched shows all of its rows.
		local sectionText = lower(id) .. " " .. (SECTION_WORDS[id] or "")
		local sectionMatch = true

		for _, word in ipairs(words) do
			if not sectionText:find(word, 1, true) then
				sectionMatch = false
				break
			end
		end

		-- Three action bar checkboxes share one row, so a row is shown when ANY
		-- of the settings on it matches -- decided after every key is scored,
		-- not as each one is visited.
		local rowMatch = {}

		eachSectionRow(id, function(_, entry)
			local match = sectionMatch or scoreRow(entry, words) > 0

			rowMatch[entry.row] = rowMatch[entry.row] or match

			if match then
				sectionHits = sectionHits + 1
			end
		end)

		for row, match in pairs(rowMatch) do
			row:setVisible(match)
		end

		hits = hits + sectionHits

		if panel then
			panel:setVisible(sectionHits > 0)
		end

		if navButtons[id] then
			navButtons[id]:setChecked(false)
		end
	end

	if status then
		if hits == 0 then
			status:setText(tr("Nothing matches '%s'.", text))
		else
			status:setText(tr("%d settings match '%s'.", hits, text))
		end

		status:setVisible(true)
	end

	local well = optionsWindow:getChildById("contentWell")
	if well then
		well:setVirtualOffset({ x = 0, y = 0 })
	end
end

function clearSearch()
	local edit = optionsWindow:getChildById("searchEdit")

	if edit then
		edit:setText("")
	end

	selectSection(currentSection or SECTIONS[1])
end

-- ---------------------------------------------------------------------------

function init()
	for k, v in pairs(defaultOptions) do
		g_settings.setDefault(k, v)

		options[k] = v
	end

	for _, v in ipairs(g_extras.getAll()) do
		extraOptions[v] = g_extras.get(v)

		g_settings.setDefault("extras_" .. v, extraOptions[v])
	end

	optionsWindow = g_ui.displayUI("options")

	optionsWindow:hide()

	function optionsWindow.onEnter()
		hide()
	end

	-- The frame rate combo is filled here rather than in the .otui so the stop
	-- list lives next to the code that reads it back.
	local frameRate = optionsWindow:recursiveGetChildById("backgroundFrameRate")
	if frameRate then
		for _, fps in ipairs(FRAME_RATE_STOPS) do
			frameRate:addOption(fps == 0 and tr("No limit") or tostring(fps))
		end
	end

	for _, id in ipairs(SECTIONS) do
		navButtons[id] = optionsWindow:recursiveGetChildById(id)
		registerSection(id)
	end

	local version = optionsWindow:recursiveGetChildById("aboutVersion")
	if version then
		version:setText("BackpackOT Client " .. g_app.getVersion() .. "\nrev " .. g_app.getBuildRevision())
	end

	selectSection(SECTIONS[1])
	setHotkeysAvailable(g_game.isOnline())

	g_keyboard.bindKeyDown("Ctrl+Shift+F", function()
		toggleOption("fullscreen")
	end)
	g_keyboard.bindKeyDown("Ctrl+N", toggleDisplays)

	optionsButton = modules.client_topmenu.addLeftButton("optionsButton", tr("Options"), "/images/topbuttons/options", toggle)

	addEvent(function()
		setup()
	end)
	connect(g_game, {
		onGameStart = online,
		onGameEnd = offline
	})
end

function terminate()
	disconnect(g_game, {
		onGameStart = online,
		onGameEnd = offline
	})
	g_keyboard.unbindKeyDown("Ctrl+Shift+F")
	g_keyboard.unbindKeyDown("Ctrl+N")
	optionsWindow:destroy()
	optionsButton:destroy()

	rows = {}
	sectionPanels = {}
	navButtons = {}
end

function setup()
	-- Full quality for everyone (owner 2026-10-13): the old "Optimization level"
	-- option throttled what the map draws, and Automatic drifted there by itself.
	-- Level 0 = no limit on effects, creatures, items or damage numbers.
	g_adaptiveRenderer.setLevel(0)

	for k, v in pairs(defaultOptions) do
		if type(v) == "boolean" then
			setOption(k, g_settings.getBoolean(k), true)
		elseif type(v) == "number" then
			setOption(k, g_settings.getNumber(k), true)
		elseif type(v) == "string" then
			setOption(k, g_settings.getString(k), true)
		end
	end

	for _, v in ipairs(g_extras.getAll()) do
		g_extras.set(v, g_settings.getBoolean("extras_" .. v))
	end

	if g_game.isOnline() then
		online()
	end
end

function toggle()
	if optionsWindow:isVisible() then
		hide()
	else
		show()
	end
end

function show()
	optionsWindow:show()
	optionsWindow:raise()
	optionsWindow:focus()
end

function hide()
	optionsWindow:hide()
end

function cancel()
	optionsWindow:hide()
end

function toggleDisplays()
	if options.displayNames and options.displayHealth and options.displayMana then
		setOption("displayNames", false)
	elseif options.displayHealth then
		setOption("displayHealth", false)
		setOption("displayMana", false)
	elseif not options.displayNames and not options.displayHealth then
		setOption("displayNames", true)
	else
		setOption("displayHealth", true)
		setOption("displayMana", true)
	end
end

function toggleOption(key)
	setOption(key, not getOption(key))
end

local function resolveOptionKeyValue(key, value)
	if key == "mapView" then
		return "classicView", not value
	end

	return key, value
end

local function syncOptionWidget(widget, value)
	local class = widget:getStyle().__class

	if class == "UICheckBox" then
		widget:setChecked(value)
	elseif class == "UIScrollBar" then
		widget:setValue(value)
	elseif class == "UISpinBox" then
		if widget:getValue() ~= value then
			widget:setValue(value)
		end
	elseif class == "UIComboBox" then
		if type(value) == "string" then
			widget:setCurrentOption(value, true)
		else
			if value == nil or value < 1 then
				value = 1
			end

			if widget.currentIndex ~= value then
				widget:setCurrentIndex(value, true)
			end
		end
	end
end

-- The frame rate combo's own handler: index in, fps out.
function setFrameRateIndex(index)
	local fps = FRAME_RATE_STOPS[index]

	if fps ~= nil then
		setOption("backgroundFrameRate", fps)
	end
end

-- Frame rate is stored as an fps number but shown as a combo of stops, so the
-- two directions need translating.
local function frameRateIndexOf(value)
	if value <= 0 or value >= 201 then
		return #FRAME_RATE_STOPS
	end

	local bestIndex, bestDistance = 1, math.huge

	for i, fps in ipairs(FRAME_RATE_STOPS) do
		if fps > 0 then
			local distance = math.abs(fps - value)

			if distance < bestDistance then
				bestIndex, bestDistance = i, distance
			end
		end
	end

	return bestIndex
end

function setOption(key, value, force)
	local requestedKey = key
	local requestedValue = value
	key, value = resolveOptionKeyValue(key, value)

	if extraOptions[key] ~= nil then
		g_extras.set(key, value)
		g_settings.set("extras_" .. key, value)

		if key == "debugProxy" and modules.game_proxy then
			if value then
				modules.game_proxy.show()
			else
				modules.game_proxy.hide()
			end
		end

		return
	end

	if modules.game_interface == nil then
		return
	end

	if not force and options[key] == value then
		return
	end

	local gameMapPanel = modules.game_interface.getMapPanel()

	if key == "vsync" then
		g_window.setVerticalSync(value)
	elseif key == "showFps" then
		modules.client_topmenu.setFpsVisible(value)
	elseif key == "showPing" then
		modules.client_topmenu.setPingVisible(value)
	elseif key == "fullscreen" then
		g_window.setFullscreen(value)
	elseif key == "dontStretchShrink" then
		addEvent(function()
			modules.game_interface.updateStretchShrink()
		end)
	elseif key == "backgroundFrameRate" then
		local fps = value

		if fps <= 0 or fps >= 201 then
			fps = 0 -- the engine's "no limit"
		end

		g_app.setMaxFps(fps)
	elseif key == "crosshair" then
		gameMapPanel:setCrosshair("")
	elseif key == "displayNames" then
		gameMapPanel:setDrawNames(value)
	elseif key == "displayHealth" then
		gameMapPanel:setDrawHealthBars(value)
	elseif key == "displayMana" then
		gameMapPanel:setDrawManaBar(value)
	elseif key == "displayHealthOnTop" then
		gameMapPanel:setDrawHealthBarsOnTop(value)
	elseif key == "displayText" then
		gameMapPanel:setDrawTexts(value)
	elseif key == "dash" then
		g_game.setMaxPreWalkingSteps(2)
	elseif key == "wsadWalking" then
		if modules.game_console and modules.game_console.consoleToggleChat:isChecked() ~= value then
			modules.game_console.consoleToggleChat:setChecked(value)
		end
	elseif key == "antialiasing" then
		g_app.setSmooth(value)
	elseif key == "hdmodeBox" then
		if g_sprites and g_sprites.setScaleFactor then
			g_sprites.setScaleFactor(value and 2 or 1)
		end
	end

	-- Push the value into the one widget that shows it.
	local entry = rows[key]

	if entry then
		if key == "backgroundFrameRate" then
			syncOptionWidget(entry.widget, frameRateIndexOf(value))
		else
			syncOptionWidget(entry.widget, value)
		end
	end

	if requestedKey ~= key and rows[requestedKey] then
		syncOptionWidget(rows[requestedKey].widget, requestedValue)
	end

	g_settings.set(key, value)

	options[key] = value

	if key == "profile" then
		modules.client_profiles.onProfileChange()
	end

	if key == "classicView" or key == "rightPanels" or key == "leftPanels" or key == "cacheMap" or key == "hdmodeBox" then
		modules.game_interface.refreshViewMode()
	elseif key:find("actionbar") then
		if modules.game_actionbar then
			modules.game_actionbar.refresh()
		end
	end
end

function getOption(key)
	if key == "mapView" then
		return not options.classicView
	end

	return options[key]
end

function online()
	g_app.setSmooth(g_settings.getBoolean("antialiasing"))
	setHotkeysAvailable(true)
end

function offline()
	setHotkeysAvailable(false)
end

-- Hotkeys are a game window: offer the button only when there is a game.
function setHotkeysAvailable(value)
	if not optionsWindow then
		return
	end

	local button = optionsWindow:recursiveGetChildById("openHotkeysButton")
	local note = optionsWindow:recursiveGetChildById("hotkeysOfflineNote")

	if button then
		button:setEnabled(value)
	end

	if note then
		note:setVisible(not value)
	end
end
