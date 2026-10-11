minimapWidget = nil
minimapWindowBig = nil
loaded = false
oldZoom = nil
oldPos = nil

function init()
	minimapWindowBig = g_ui.loadUI("minimap_big", modules.game_interface.getRootPanel())
	minimapWidget = minimapWindowBig:recursiveGetChildById("minimapWidgetBig")
	minimapWidget.onMousePress = onMinimapMousePress
	routeFlagsToMainMinimap()

	g_keyboard.bindKeyDown("Ctrl+M", toggle)
	minimapWindowBig:hide()
	connect(g_game, {
		onGameStart = online,
		onGameEnd = offline
	})
	connect(LocalPlayer, {
		onPositionChange = updateCameraPosition
	})

	if g_game.isOnline() then
		online()
	end
end

function terminate()
	disconnect(g_game, {
		onGameStart = online,
		onGameEnd = offline
	})
	disconnect(LocalPlayer, {
		onPositionChange = updateCameraPosition
	})
	g_keyboard.unbindKeyDown("Ctrl+M")
	minimapWindowBig:destroy()
end

function toggle()
	if minimapWindowBig:isVisible() then
		minimapWindowBig:hide()
	else
		minimapWindowBig:show()
		syncFlagsFromMainMinimap()

		-- show() doesn't guarantee the widget's layout is ready in this same
		-- frame, so calling updateCameraPosition() immediately can silently
		-- no-op on the very first open (its own layout-readiness guard fails)
		-- - the map would only actually position itself after a subsequent
		-- close/reopen. Poll until layout is ready instead, same pattern
		-- already used for the initial onGameStart case below.
		local function safeUpdate()
			if minimapWidget and minimapWidget:isVisible() and minimapWidget:getLayout() then
				updateCameraPosition()
			else
				scheduleEvent(safeUpdate, 50)
			end
		end
		safeUpdate()
	end
end

function close()
	if minimapWindowBig:isVisible() then
		minimapWindowBig:hide()
	end
end

function online()
	loadMap()
	local function safeUpdate()
		if minimapWidget and minimapWidget:isVisible() and minimapWidget:getLayout() then
			updateCameraPosition()
		else
			scheduleEvent(safeUpdate, 100)
		end
	end
	safeUpdate()
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

	minimapWidget:load()
end

-- Marks: game_minimap is the one owner. It loads the saved marks at login and
-- saves them at logout. This big map used to keep its own list that was never
-- saved, so marks made here were lost. Now every mark added or removed here is
-- also added to or removed from game_minimap's widget, and this map copies
-- game_minimap's marks each time it opens.
local function getMainMinimap()
	local main = modules.game_minimap and modules.game_minimap.minimapWidget

	if main and not main:isDestroyed() then
		return main
	end

	return nil
end

local function onBigFlagMouseRelease(flag, pos, button)
	if button ~= MouseRightButton then
		return false
	end

	local menu = g_ui.createWidget("PopupMenu")

	menu:setGameMenu(true)
	menu:addOption(tr("Delete mark"), function ()
		local main = getMainMinimap()

		if main and flag.pos then
			main:removeFlag(flag.pos)
		end

		flag:destroy()
	end)
	menu:display(pos)

	return true
end

function routeFlagsToMainMinimap()
	function minimapWidget:addFlag(pos, icon, description, temporary)
		UIMinimap.addFlag(self, pos, icon, description, temporary)

		local flag = pos and self:getFlag(pos)

		if flag then
			flag.onMouseRelease = onBigFlagMouseRelease
		end

		local main = getMainMinimap()

		if main and main ~= self then
			main:addFlag(pos, icon, description, temporary)
		end
	end

	function minimapWidget:removeFlag(pos, icon, description)
		UIMinimap.removeFlag(self, pos, icon, description)

		local main = getMainMinimap()

		if main and main ~= self and pos then
			main:removeFlag(pos, icon, description)
		end
	end
end

function syncFlagsFromMainMinimap()
	local main = getMainMinimap()

	if not main or not main.flags or not minimapWidget.flags then
		return
	end

	-- Drop marks that were deleted on the small map.
	local stale = {}

	for _, flag in pairs(minimapWidget.flags) do
		local mainFlag = flag.pos and main:getFlag(flag.pos)

		if not mainFlag then
			table.insert(stale, flag)
		end
	end

	for _, flag in ipairs(stale) do
		flag:destroy()
	end

	-- Copy marks made on the small map. UIMinimap.addFlag skips ones we have,
	-- and calling it directly does not send them back to the small map.
	for _, mainFlag in pairs(main.flags) do
		UIMinimap.addFlag(minimapWidget, mainFlag.pos, mainFlag.icon, mainFlag.description, mainFlag.temporary)

		local flag = minimapWidget:getFlag(mainFlag.pos)

		if flag then
			flag.onMouseRelease = onBigFlagMouseRelease
		end
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
		minimapWidget:setCameraPosition(pos)
		minimapWidget:setCrossPosition(pos)
	end
end
