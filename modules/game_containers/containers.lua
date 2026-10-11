local gameStart = 0

function init()
	connect(Container, {
		onOpen = onContainerOpen,
		onClose = onContainerClose,
		onSizeChange = onContainerChangeSize,
		onUpdateItem = onContainerUpdateItem
	})
	connect(g_game, {
		onGameStart = markStart,
		onGameEnd = clean
	})
	reloadContainers()
end

function terminate()
	disconnect(Container, {
		onOpen = onContainerOpen,
		onClose = onContainerClose,
		onSizeChange = onContainerChangeSize,
		onUpdateItem = onContainerUpdateItem
	})
	disconnect(g_game, {
		onGameStart = markStart,
		onGameEnd = clean
	})
end

function reloadContainers()
	clean()

	for _, container in pairs(g_game.getContainers()) do
		onContainerOpen(container)
	end
end

function clean()
	for containerid, container in pairs(g_game.getContainers()) do
		destroy(container)
	end
end

function markStart()
	gameStart = g_clock.millis()
end

function destroy(container)
	if container.window then
		container.window:destroy()

		container.window = nil
		container.itemsPanel = nil
	end
end

function refreshContainerItems(container)
	for slot = 0, container:getCapacity() - 1 do
		local itemWidget = container.itemsPanel:getChildById("item" .. slot)
		local slotItem = container:getItem(slot)

		itemWidget:setItem(slotItem)
		ItemsDatabase.setTier(itemWidget, slotItem)

		-- No rarity logic

	end

	if container:hasPages() then
		refreshContainerPages(container)
	end
end

function toggleContainerPages(containerWindow, hasPages)
	if hasPages == containerWindow.pagePanel:isOn() then
		return
	end

	containerWindow.pagePanel:setOn(hasPages)

	if hasPages then
		containerWindow.miniwindowScrollBar:setMarginTop(containerWindow.miniwindowScrollBar:getMarginTop() + containerWindow.pagePanel:getHeight())
		containerWindow.contentsPanel:setMarginTop(containerWindow.contentsPanel:getMarginTop() + containerWindow.pagePanel:getHeight())
	else
		containerWindow.miniwindowScrollBar:setMarginTop(containerWindow.miniwindowScrollBar:getMarginTop() - containerWindow.pagePanel:getHeight())
		containerWindow.contentsPanel:setMarginTop(containerWindow.contentsPanel:getMarginTop() - containerWindow.pagePanel:getHeight())
	end
end

-- Depot pages: the mouse wheel fires many events per notch, and each one used
-- to send a page request, so a fast spin flooded the server. A wheel event is
-- ignored for PAGE_WHEEL_GATE_MS after any page request from the same window.
local PAGE_WHEEL_GATE_MS = 200

local function seekContainerPage(container, firstIndex)
	if container.window then
		container.window.lastPageSeek = g_clock.millis()
	end
	g_game.seekInContainer(container:getId(), firstIndex)
end

function refreshContainerPages(container)
	local currentPage = 1 + math.floor(container:getFirstIndex() / container:getCapacity())
	local pages = 1 + math.floor(math.max(0, container:getSize() - 1) / container:getCapacity())

	container.window:recursiveGetChildById("pageLabel"):setText(string.format("Page %i of %i", currentPage, pages))

	local prevPageButton = container.window:recursiveGetChildById("prevPageButton")

	if currentPage == 1 then
		prevPageButton:setEnabled(false)
		prevPageButton.onClick = nil
	else
		prevPageButton:setEnabled(true)

		function prevPageButton.onClick()
			seekContainerPage(container, container:getFirstIndex() - container:getCapacity())
		end
	end

	local nextPageButton = container.window:recursiveGetChildById("nextPageButton")

	if pages <= currentPage then
		nextPageButton:setEnabled(false)
		nextPageButton.onClick = nil
	else
		nextPageButton:setEnabled(true)

		function nextPageButton.onClick()
			seekContainerPage(container, container:getFirstIndex() + container:getCapacity())
		end
	end

	local pagePanel = container.window:recursiveGetChildById("pagePanel")

	if pagePanel then
		function pagePanel.onMouseWheel(widget, mousePos, mouseWheel)
			if pages == 1 then
				return
			end

			local last = container.window and container.window.lastPageSeek
			if last and g_clock.millis() - last < PAGE_WHEEL_GATE_MS then
				return true
			end

			-- onClick is nil on the first and last page, so those send nothing.
			local button = mouseWheel == MouseWheelUp and prevPageButton or nextPageButton
			if button.onClick then
				button.onClick()
			end
			return true
		end
	end
end

function onContainerOpen(container, previousContainer)
	local containerWindow = nil

	if previousContainer then
		containerWindow = previousContainer.window
		previousContainer.window = nil
		previousContainer.itemsPanel = nil
	else
		containerWindow = g_ui.createWidget("ContainerWindow", modules.game_interface.getContainerPanel())

		-- g_ui.createWidget() parents the window via C++ addChild, which skips
		-- UIMiniWindow:setParent's Lua override - the only place that calls
		-- fitOnParent()/fitAll() to shrink or close sibling windows so this one
		-- fits within the panel's actual height. Without this, newly opened
		-- loot windows just stack past the visible bottom of the screen,
		-- especially now that the minimap bar permanently reserves a fixed
		-- 280px at the top of the right side panels (see game_minimap/minimap.lua).
		containerWindow:fitOnParent()

		containerWindow:setBorderWidth(2)
		containerWindow:setBorderColor("#FFFFFF")
		scheduleEvent(function ()
			if containerWindow then
				containerWindow:setBorderWidth(0)
			end
		end, 300)
	end

	containerWindow:setId("container" .. container:getId())

	if gameStart + 1000 < g_clock.millis() then
		containerWindow:clearSettings()
	end

	local containerPanel = containerWindow:getChildById("contentsPanel")
	local containerItemWidget = containerWindow:getChildById("containerItemWidget")

	function containerWindow.onClose()
		g_game.close(container)
		containerWindow:hide()
	end

	function containerWindow.onDrop(container, widget, mousePos)
		if modules.game_supplystash and modules.game_supplystash.shouldBlockItemDrop and modules.game_supplystash.shouldBlockItemDrop(container, widget, mousePos) then
			return true
		end

		if containerPanel:getChildByPos(mousePos) then
			return false
		end

		local child = containerPanel:getChildByIndex(-1)

		if child then
			return child:onDrop(widget, mousePos, true)
		end
	end

	function containerWindow.onMouseRelease(widget, mousePos, mouseButton)
		if mouseButton == MouseButton4 then
			if container:hasParent() then
				return g_game.openParent(container)
			end
		elseif mouseButton == MouseButton5 then
			for i, item in ipairs(container:getItems()) do
				if item:isContainer() then
					return g_game.open(item, container)
				end
			end
		end
	end

	local scrollbar = containerWindow:getChildById("miniwindowScrollBar")

	scrollbar:mergeStyle({
		["$!on"] = {}
	})

	local upButton = containerWindow:getChildById("upButton")

	function upButton.onClick()
		g_game.openParent(container)
	end

	upButton:setVisible(container:hasParent())

	local name = container:getName()
	name = name:sub(1, 1):upper() .. name:sub(2)

	containerWindow:setText(name)
	local containerItem = container:getContainerItem()
	if containerItem then
		containerItemWidget:setItemId(containerItem:getId())
	else
		containerItemWidget:setItem(nil)
	end
	containerPanel:destroyChildren()

	for slot = 0, container:getCapacity() - 1 do
		local itemWidget = g_ui.createWidget("Item", containerPanel)

		itemWidget:setId("item" .. slot)

		local slotItem = container:getItem(slot)

		itemWidget:setItem(slotItem)
		ItemsDatabase.setTier(itemWidget, slotItem)

		-- No rarity logic


		itemWidget:setMargin(0)

		itemWidget.position = container:getSlotPosition(slot)

		if not container:isUnlocked() then
			itemWidget:setBorderColor("red")
		end
	end

	container.window = containerWindow
	container.itemsPanel = containerPanel

	toggleContainerPages(containerWindow, container:hasPages())
	refreshContainerPages(container)

	local layout = containerPanel:getLayout()
	local cellSize = layout:getCellSize()

	containerWindow:setContentMinimumHeight(cellSize.height)
	containerWindow:setContentMaximumHeight((cellSize.height + 3) * layout:getNumLines())

	if container:hasPages() then
		local height = containerWindow.miniwindowScrollBar:getMarginTop() + containerWindow.pagePanel:getHeight() + 17

		if containerWindow:getHeight() < height then
			containerWindow:setHeight(height)
		end
	end

	-- A depot box opening from the chest reuses the chest's 1-row window, so both
	-- get a fixed starting height; the player can still drag either one.
	local lowerName = container:getName():lower()
	local defaultLines = nil
	if lowerName == "depot chest" then
		defaultLines = 1
	elseif lowerName:find("^depot box") then
		defaultLines = 2
	end

	if defaultLines then
		containerWindow:setContentHeight(math.min(defaultLines, layout:getNumLines()) * (cellSize.height + 3))
	elseif not previousContainer then
		local filledLines = math.max(math.ceil(container:getItemsCount() / layout:getNumColumns()), 1)

		containerWindow:setContentHeight(filledLines * (cellSize.height + 3))
	end

	containerWindow:setup()
end

function onContainerClose(container)
	destroy(container)
end

function onContainerChangeSize(container, size)
	if not container.window then
		return
	end

	refreshContainerItems(container)
end

function onContainerUpdateItem(container, slot, item, oldItem)
	if not container.window then
		return
	end

	local itemWidget = container.itemsPanel:getChildById("item" .. slot)

	itemWidget:setItem(item)
	ItemsDatabase.setTier(itemWidget, item)

	-- No rarity logic

end
