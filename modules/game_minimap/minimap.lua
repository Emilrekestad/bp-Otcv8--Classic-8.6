minimapWidget = nil
minimapButton = nil
minimapWindow = nil
fullmapView = false
loaded = false
oldZoom = nil
oldPos = nil

-- The minimap is permanently docked in gameRightMinimapBar, a fixed bar
-- spanning both (hardcoded-to-2) right side panels, above them - see
-- gameinterface.otui/gameinterface.lua. It's always this size, it can't be
-- dragged, and there is no toggle for it.
local FIXED_WIDTH = 351
local FIXED_HEIGHT = 280

-- NonClosableMiniWindowContents (data/styles/30-miniwindow.otui) inherits an
-- "anchors.right: miniwindowScrollBar.left" override from MiniWindowContents,
-- but NonClosableMiniWindow never creates that scrollbar widget. That dangling
-- reference freezes the content panel at whatever size it first resolved to
-- instead of tracking the window's actual size. Force a clean re-fill instead
-- of trusting that inherited anchor.
local function refitMinimapContents()
	local contentsPanel = minimapWindow:getChildById("contentsPanel")
	if not contentsPanel then
		return
	end

	contentsPanel:breakAnchors()
	contentsPanel:fill("parent")
end

-- Party member roster, sent by tfs-source/data/scripts/globalevents/
-- party_minimap_sync.lua every ~500ms while you're in a party (see
-- gamelib/ui/uiminimap.lua's setPartyPositions() for the actual marker
-- rendering, shared by any UIMinimap instance).
local function onPartyPositions(protocol, opcode, roster)
	if minimapWidget then
		minimapWidget:setPartyPositions(roster)
	end
end

function init()
	local minimapBar = modules.game_interface.getRightMinimapBar()
	minimapWindow = g_ui.loadUI("minimap", minimapBar)

	minimapWidget = minimapWindow:recursiveGetChildById("minimap")
	local gameRootPanel = modules.game_interface.getRootPanel()

	minimapWindow:setup()
	minimapWindow:open()

	-- setup()/open() restore this window's *saved* parent from a previous
	-- (pre-hardcoded) session - e.g. whichever GameSidePanel it used to be
	-- docked in, which uses a verticalBox layout, not anchors. Force it back
	-- onto the fixed minimap bar before applying anchors/fixed size.
	minimapWindow:setParent(minimapBar)
	minimapWindow:breakAnchors()
	minimapWindow:fill("parent")
	minimapWindow:setWidth(FIXED_WIDTH)
	minimapWindow:setHeight(FIXED_HEIGHT)
	minimapWindow:setDraggable(false)
	refitMinimapContents()

	g_keyboard.bindKeyPress("Alt+Left", function ()
		minimapWidget:move(1, 0)
	end, gameRootPanel)
	g_keyboard.bindKeyPress("Alt+Right", function ()
		minimapWidget:move(-1, 0)
	end, gameRootPanel)
	g_keyboard.bindKeyPress("Alt+Up", function ()
		minimapWidget:move(0, 1)
	end, gameRootPanel)
	g_keyboard.bindKeyPress("Alt+Down", function ()
		minimapWidget:move(0, -1)
	end, gameRootPanel)
	connect(g_game, {
		onGameStart = online,
		onGameEnd = offline
	})
	connect(LocalPlayer, {
		onPositionChange = updateCameraPosition
	})

	ProtocolGame.registerExtendedJSONOpcode(ExtendedIds.PartyPositions, onPartyPositions)

	if g_game.isOnline() then
		online()
	end
end

function terminate()
	if g_game.isOnline() then
		saveMap()
	end

	disconnect(g_game, {
		onGameStart = online,
		onGameEnd = offline
	})
	disconnect(LocalPlayer, {
		onPositionChange = updateCameraPosition
	})

	ProtocolGame.unregisterExtendedJSONOpcode(ExtendedIds.PartyPositions)

	local gameRootPanel = modules.game_interface.getRootPanel()

	g_keyboard.unbindKeyPress("Alt+Left", gameRootPanel)
	g_keyboard.unbindKeyPress("Alt+Right", gameRootPanel)
	g_keyboard.unbindKeyPress("Alt+Up", gameRootPanel)
	g_keyboard.unbindKeyPress("Alt+Down", gameRootPanel)
	minimapWindow:destroy()

	if minimapButton then
		minimapButton:destroy()
	end
end

function toggle()
	if not minimapButton then
		return
	end

	if minimapButton:isOn() then
		minimapWindow:close()
		minimapButton:setOn(false)
	else
		minimapWindow:open()
		minimapButton:setOn(true)
	end
end

function onMiniWindowClose()
	if minimapButton then
		minimapButton:setOn(false)
	end
end

function online()
	loadMap()
	-- Give it a bit more time and check for layout
	local function safeUpdate()
		if minimapWidget and minimapWidget:getLayout() then
			updateCameraPosition()
		else
			scheduleEvent(safeUpdate, 100)
		end
	end
	safeUpdate()
end

function offline()
	saveMap()

	if minimapWidget then
		minimapWidget:clearPartyPositions()
	end
end

function loadMap()
	local clientVersion = g_game.getClientVersion()

	g_minimap.clean()

	loaded = false
	local characterFile = nil
	local minimapFile = "/minimap.otmm"
	local dataMinimapFile = "/data" .. minimapFile
	local versionedMinimapFile = "/minimap" .. clientVersion .. ".otmm"
	local localPlayer = g_game.getLocalPlayer()

	if localPlayer then
		local playerName = localPlayer:getName()

		if playerName then
			characterFile = "/minimap-" .. playerName .. ".otmm"
		end
	end

	if characterFile and g_resources.fileExists(characterFile) then
		loaded = g_minimap.loadOtmm(characterFile)
	end

	if not loaded and g_resources.fileExists(dataMinimapFile) then
		loaded = g_minimap.loadOtmm(dataMinimapFile)
	end

	if g_resources.fileExists(dataMinimapFile) then
		loaded = g_minimap.loadOtmm(dataMinimapFile)
	end

	if not loaded and g_resources.fileExists(versionedMinimapFile) then
		loaded = g_minimap.loadOtmm(versionedMinimapFile)
	end

	if not loaded and g_resources.fileExists(minimapFile) then
		loaded = g_minimap.loadOtmm(minimapFile)
	end

	if not loaded then
		print("Minimap couldn't be loaded, file missing?")
	end

	-- Marks and zoom. load() is Lua (gamelib/ui/uiminimap.lua), not C++.
	-- This module is the one owner of the saved marks: it loads them here and
	-- saves them in saveMap() at logout. With the load commented out, logout
	-- saved an empty list over the player's marks. game_minimap_big sends its
	-- marks to this widget so the save keeps them too.
	minimapWidget:load()
end

function saveMap()
	local localPlayer = g_game.getLocalPlayer()

	if localPlayer then
		local playerName = localPlayer:getName()

		if playerName then
			characterFile = "/minimap-" .. playerName .. ".otmm"

			g_minimap.saveOtmm(characterFile)
			minimapWidget:save()
		end
	else
		local clientVersion = g_game.getClientVersion()
		local minimapFile = "/minimap" .. clientVersion .. ".otmm"

		g_minimap.saveOtmm(minimapFile)
		minimapWidget:save()
	end
end

function updateCameraPosition()
	if not minimapWidget or not minimapWidget:isVisible() or not minimapWidget:getLayout() then
		return
	end

	local player = g_game.getLocalPlayer()
	if not player then
		return
	end

	local pos = player:getPosition()
	if not pos then
		return
	end

	if not minimapWidget:isDragging() then
		if not fullmapView then
			minimapWidget:setCameraPosition(pos)
		end

		minimapWidget:setCrossPosition(pos)
	end
end

function toggleFullMap()
	if not fullmapView then
		fullmapView = true

		minimapWindow:hide()
		minimapWidget:setParent(modules.game_interface.getRootPanel())
		minimapWidget:fill("parent")
		minimapWidget:setAlternativeWidgetsVisible(true)
	else
		fullmapView = false

		minimapWidget:setParent(minimapWindow:getChildById("contentsPanel"))
		minimapWidget:fill("parent")
		minimapWindow:show()
		minimapWidget:setAlternativeWidgetsVisible(false)
	end

	local zoom = oldZoom or 0
	local pos = oldPos or minimapWidget:getCameraPosition()
	oldZoom = minimapWidget:getZoom()
	oldPos = minimapWidget:getCameraPosition()

	minimapWidget:setZoom(zoom)
	minimapWidget:setCameraPosition(pos)
end
