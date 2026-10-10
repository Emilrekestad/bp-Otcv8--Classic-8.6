HOTKEY_MANAGER_USE = nil
HOTKEY_MANAGER_USEONSELF = 1
HOTKEY_MANAGER_USEONTARGET = 2
HOTKEY_MANAGER_USEWITH = 3
HotkeyColors = {
	textAutoSend = "#FFFFFF",
	itemUseSelf = "#00FF00",
	itemUseWith = "#F5B325",
	itemUse = "#8888FF",
	extraAction = "#FFAA00",
	text = "#888888",
	itemUseTarget = "#FF0000"
}
hotkeysManagerLoaded = false
hotkeysWindow = nil
configSelector = nil
hotkeysButton = nil
currentHotkeyLabel = nil
currentItemPreview = nil
itemWidget = nil
addHotkeyButton = nil
removeHotkeyButton = nil
hotkeyText = nil
hotKeyTextLabel = nil
sendAutomatically = nil
selectObjectButton = nil
clearObjectButton = nil
useOnSelf = nil
useOnTarget = nil
useWith = nil
defaultComboKeys = nil
perCharacter = true
mouseGrabberWidget = nil
useRadioGroup = nil
currentHotkeys = nil
boundCombosCallback = {}
hotkeysList = {}
hotkeyConfigs = {}
currentConfig = 1
configValueChanged = false
renameWindow = nil

function init()
	if not g_app.isMobile() then
		hotkeysButton = modules.client_topmenu.addLeftGameButton("hotkeysButton", tr("Hotkeys") .. " (Ctrl+K)", "/images/topbuttons/hotkeys", toggle, false, 7)
	end

	g_keyboard.bindKeyDown("Ctrl+K", toggle)

	hotkeysWindow = g_ui.displayUI("hotkeys_manager")

	hotkeysWindow:setVisible(false)

	configSelector = hotkeysWindow:getChildById("configSelector")
	currentHotkeys = hotkeysWindow:getChildById("currentHotkeys")
	currentItemPreview = hotkeysWindow:recursiveGetChildById("itemPreview")
	addHotkeyButton = hotkeysWindow:getChildById("addHotkeyButton")
	removeHotkeyButton = hotkeysWindow:getChildById("removeHotkeyButton")
	hotkeyText = hotkeysWindow:getChildById("hotkeyText")
	hotKeyTextLabel = hotkeysWindow:getChildById("hotKeyTextLabel")
	sendAutomatically = hotkeysWindow:getChildById("sendAutomatically")
	selectObjectButton = hotkeysWindow:getChildById("selectObjectButton")
	clearObjectButton = hotkeysWindow:getChildById("clearObjectButton")
	useOnSelf = hotkeysWindow:getChildById("useOnSelf")
	useOnTarget = hotkeysWindow:getChildById("useOnTarget")
	useWith = hotkeysWindow:getChildById("useWith")
	useRadioGroup = UIRadioGroup.create()

	useRadioGroup:addWidget(useOnSelf)
	useRadioGroup:addWidget(useOnTarget)
	useRadioGroup:addWidget(useWith)

	function useRadioGroup:onSelectionChange(selected)
		onChangeUseType(selected)
	end

	mouseGrabberWidget = g_ui.createWidget("UIWidget")

	mouseGrabberWidget:setVisible(false)
	mouseGrabberWidget:setFocusable(false)

	mouseGrabberWidget.onMouseRelease = onChooseItemMouseRelease

	function currentHotkeys:onChildFocusChange(hotkeyLabel)
		onSelectHotkeyLabel(hotkeyLabel)
	end

	g_keyboard.bindKeyPress("Down", function ()
		currentHotkeys:focusNextChild(KeyboardFocusReason)
	end, hotkeysWindow)
	g_keyboard.bindKeyPress("Up", function ()
		currentHotkeys:focusPreviousChild(KeyboardFocusReason)
	end, hotkeysWindow)

	if hotkeysWindow.action and setupExtraHotkeys then
		setupExtraHotkeys(hotkeysWindow.action)
	end

	connect(g_game, {
		onGameStart = online,
		onGameEnd = offline
	})

	for i = 1, configSelector:getOptionsCount() do
		hotkeyConfigs[i] = g_configs.create("/hotkeys_" .. i .. ".otml")
	end

	refreshConfigLabels()
	load()
end

function terminate()
	disconnect(g_game, {
		onGameStart = online,
		onGameEnd = offline
	})
	g_keyboard.unbindKeyDown("Ctrl+K")
	unload()
	closeRenameWindow()
	hotkeysWindow:destroy()

	if hotkeysButton then
		hotkeysButton:destroy()
	end

	mouseGrabberWidget:destroy()
end

function online()
	selectCharacterConfig()
	reload()
	hide()
end

function offline()
	unload()
	hide()
end

function show()
	if not g_game.isOnline() then
		return
	end

	hotkeysWindow:show()
	hotkeysWindow:raise()
	hotkeysWindow:focus()
end

function hide()
	closeRenameWindow()
	hotkeysWindow:hide()
end

function toggle()
	if not hotkeysWindow:isVisible() then
		show()
	else
		hide()
	end
end

function ok()
	save()
	hide()
end

function cancel()
	reload()
	hide()
end

-- One key, one action (2026-10-10): a key on the action bar is not also a hotkey here.
function isTakenByActionBar(keyCombo)
	return modules.game_actionbar and modules.game_actionbar.isHotkeyUsed and modules.game_actionbar.isHotkeyUsed(keyCombo) or false
end

function load(forceDefaults)
	hotkeysManagerLoaded = false
	currentConfig = 1
	local hotkeysNode = g_settings.getNode("hotkeys") or {}
	local index = getCharacterKey()

	if hotkeysNode[index] ~= nil and hotkeysNode[index] > 0 and hotkeysNode[index] <= #hotkeyConfigs then
		currentConfig = hotkeysNode[index]
	end

	configSelector:setCurrentIndex(currentConfig, true)

	local hotkeySettings = hotkeyConfigs[currentConfig]:getNode("hotkeys")
	local hotkeys = {}

	if not table.empty(hotkeySettings) then
		hotkeys = hotkeySettings
	end

	hotkeyList = {}

	local dropped = 0

	if not forceDefaults and not table.empty(hotkeys) then
		for keyCombo, setting in pairs(hotkeys) do
			keyCombo = tostring(keyCombo)

			if addKeyCombo(keyCombo, setting) == false then
				dropped = dropped + 1
			else
				hotkeyList[keyCombo] = setting
			end
		end
	end

	if currentHotkeys:getChildCount() == 0 then
		loadDefautComboKeys()
	end

	updateConfigHint()

	configValueChanged = false
	hotkeysManagerLoaded = true

	-- keys the action bar owns are dropped for good, not just hidden
	if dropped > 0 then
		configValueChanged = true

		save()
	end
end

function unload()
	local gameRootPanel = modules.game_interface.getRootPanel()

	for keyCombo, callback in pairs(boundCombosCallback) do
		g_keyboard.unbindKeyPress(keyCombo, callback, gameRootPanel)
	end

	boundCombosCallback = {}

	currentHotkeys:destroyChildren()

	currentHotkeyLabel = nil

	updateHotkeyForm(true)

	hotkeyList = {}
end

function reset()
	unload()
	load(true)
end

function reload()
	unload()
	load()
end

function save()
	if not configValueChanged then
		return
	end

	local hotkeySettings = hotkeyConfigs[currentConfig]:getNode("hotkeys") or {}

	table.clear(hotkeySettings)

	for _, child in pairs(currentHotkeys:getChildren()) do
		hotkeySettings[child.keyCombo] = {
			autoSend = child.autoSend,
			itemId = child.itemId,
			subType = child.subType,
			useType = child.useType,
			value = child.value,
			action = child.action
		}
	end

	hotkeyList = hotkeySettings

	hotkeyConfigs[currentConfig]:setNode("hotkeys", hotkeySettings)
	hotkeyConfigs[currentConfig]:save()

	local index = getCharacterKey()
	local hotkeysNode = g_settings.getNode("hotkeys") or {}
	hotkeysNode[index] = currentConfig

	g_settings.setNode("hotkeys", hotkeysNode)
	g_settings.save()
end

function onConfigChange()
	if not configSelector then
		return
	end

	local index = getCharacterKey()
	local hotkeysNode = g_settings.getNode("hotkeys") or {}
	hotkeysNode[index] = configSelector.currentIndex

	g_settings.setNode("hotkeys", hotkeysNode)
	reload()
end

function getCharacterKey()
	return g_game.getCharacterName() .. "_" .. g_game.getClientVersion()
end

-- Names are written into the .otml file, so keep them to what a Tibia name
-- can hold. That also keeps "#" and "(" out, which is what keeps every
-- combobox label unique (see refreshConfigLabels).
function cleanConfigName(text)
	text = tostring(text or ""):gsub("[^%w%s%-'%.]", "")
	text = text:gsub("%s+", " ")
	text = text:gsub("^ ", ""):gsub(" $", "")

	return text
end

function getConfigName(index)
	local config = hotkeyConfigs[index]

	if not config then
		return ""
	end

	return config:getValue("name")
end

-- The combobox popup selects an option by its TEXT, so two configs with the
-- same name would both select the first. Duplicates carry their number.
function refreshConfigLabels()
	local counts = {}

	for i = 1, #hotkeyConfigs do
		local key = getConfigName(i):lower()
		counts[key] = (counts[key] or 0) + 1
	end

	for i, option in ipairs(configSelector.options) do
		local name = getConfigName(i)

		if name == "" then
			option.text = tr("Hotkeys config #%d", i)
		elseif counts[name:lower()] > 1 then
			option.text = string.format("%s (#%d)", name, i)
		else
			option.text = name
		end
	end

	local current = configSelector:getCurrentOption()

	if current then
		configSelector:setText(current.text)
	end
end

function findConfigByName(name)
	local wanted = cleanConfigName(name):lower()

	if wanted == "" then
		return nil
	end

	for i = 1, #hotkeyConfigs do
		if getConfigName(i):lower() == wanted then
			return i
		end
	end

	return nil
end

-- A config named after the character always wins at login. It is stored as
-- the character's last-used config, so Cancel and Reset All stay on it, and
-- switching by hand still works until the next login.
function selectCharacterConfig()
	local index = findConfigByName(g_game.getCharacterName())

	if not index then
		return
	end

	local hotkeysNode = g_settings.getNode("hotkeys") or {}
	hotkeysNode[getCharacterKey()] = index

	g_settings.setNode("hotkeys", hotkeysNode)
end

function openRenameWindow()
	if renameWindow then
		renameWindow:raise()
		renameWindow:focus()

		return
	end

	renameWindow = g_ui.createWidget("HotkeyRenameWindow", rootWidget)
	renameWindow.configIndex = currentConfig
	local nameEdit = renameWindow:getChildById("nameEdit")

	nameEdit:setText(getConfigName(currentConfig))
	nameEdit:setCursorPos(-1)
	renameWindow:raise()
	renameWindow:focus()
	nameEdit:focus()
end

function closeRenameWindow()
	if renameWindow then
		renameWindow:destroy()

		renameWindow = nil
	end
end

function useCharacterName()
	if not renameWindow then
		return
	end

	local nameEdit = renameWindow:getChildById("nameEdit")

	nameEdit:setText(g_game.getCharacterName())
	nameEdit:setCursorPos(-1)
	nameEdit:focus()
end

-- Saved at once: the name belongs to the config file, not to the hotkey
-- edits that Ok/Cancel decide on.
function confirmRename()
	if not renameWindow then
		return
	end

	local config = hotkeyConfigs[renameWindow.configIndex]
	local name = cleanConfigName(renameWindow:getChildById("nameEdit"):getText())

	-- Config:setValue appends a second node rather than replacing the old one
	-- (OTMLNode::addChild), so the old name has to go first.
	config:remove("name")
	config:setValue("name", name)
	config:save()
	refreshConfigLabels()
	updateConfigHint()
	closeRenameWindow()
end

-- One line under the config box: a tip, or a confirmation when the config on
-- screen is the one this character gets at login (the FIRST match, so a later
-- duplicate still shows the tip).
function updateConfigHint()
	local hint = hotkeysWindow:getChildById("configHint")

	if not hint then
		return
	end

	local characterName = g_game.getCharacterName()

	if characterName ~= "" and findConfigByName(characterName) == currentConfig then
		hint:setText(tr("Loads when you log in with %s.", characterName))
		hint:setColor("#c8c8c8")
	else
		hint:setText(tr("Tip: use your character's name to load it at login."))
		hint:setColor("#9a9a9a")
	end
end

function loadDefautComboKeys()
	if not defaultComboKeys then
		for i = 1, 12 do
			addKeyCombo("F" .. i)
		end

		for i = 1, 12 do
			addKeyCombo("Shift+F" .. i)
		end
	else
		for keyCombo, keySettings in pairs(defaultComboKeys) do
			addKeyCombo(keyCombo, keySettings)
		end
	end
end

function setDefaultComboKeys(combo)
	defaultComboKeys = combo
end

function onChooseItemMouseRelease(self, mousePosition, mouseButton)
	local item = nil

	if mouseButton == MouseLeftButton then
		local clickedWidget = modules.game_interface.getRootPanel():recursiveGetChildByPos(mousePosition, false)

		if clickedWidget then
			if clickedWidget:getClassName() == "UIGameMap" then
				local tile = clickedWidget:getTile(mousePosition)

				if tile then
					local thing = tile:getTopMoveThing()

					if thing and thing:isItem() then
						item = thing
					end
				end
			elseif clickedWidget:getClassName() == "UIItem" and not clickedWidget:isVirtual() then
				item = clickedWidget:getItem()
			end
		end
	end

	if item and currentHotkeyLabel and ItemsDatabase.isPotionOrRune(item:getId()) then
		show()
		g_mouse.popCursor("target")
		self:ungrabMouse()
		-- Shown after show() (which raises hotkeysWindow) so the error box
		-- ends up on top of it instead of landing behind it.
		displayErrorBox(tr("Hotkeys"), tr("Potions and runes cannot be assigned to hotkeys on this server."))
		return true
	end

	if item and currentHotkeyLabel then
		currentHotkeyLabel.itemId = item:getId()

		if item:isFluidContainer() then
			currentHotkeyLabel.subType = item:getSubType()
		end

		if item:isMultiUse() then
			currentHotkeyLabel.useType = HOTKEY_MANAGER_USEWITH
		else
			currentHotkeyLabel.useType = HOTKEY_MANAGER_USE
		end

		currentHotkeyLabel.value = nil
		currentHotkeyLabel.autoSend = false

		updateHotkeyLabel(currentHotkeyLabel)
		updateHotkeyForm(true)
	end

	show()
	g_mouse.popCursor("target")
	self:ungrabMouse()

	return true
end

function startChooseItem()
	if g_ui.isMouseGrabbed() then
		return
	end

	mouseGrabberWidget:grabMouse()
	g_mouse.pushCursor("target")
	hide()
end

function clearObject()
	currentHotkeyLabel.action = nil
	currentHotkeyLabel.itemId = nil
	currentHotkeyLabel.subType = nil
	currentHotkeyLabel.useType = nil
	currentHotkeyLabel.autoSend = nil
	currentHotkeyLabel.value = nil

	updateHotkeyLabel(currentHotkeyLabel)
	updateHotkeyForm(true)
end

function addHotkey()
	local assignWindow = g_ui.createWidget("HotkeyAssignWindow", rootWidget)

	assignWindow:grabKeyboard()

	local comboLabel = assignWindow:getChildById("comboPreview")
	comboLabel.keyCombo = ""
	assignWindow.onKeyDown = hotkeyCapture
end

function addKeyCombo(keyCombo, keySettings, focus)
	if keyCombo == nil or #keyCombo == 0 then
		return
	end

	if isTakenByActionBar(keyCombo) then
		return false
	end

	if not keyCombo then
		return
	end

	local hotkeyLabel = currentHotkeys:getChildById(keyCombo)

	if not hotkeyLabel then
		hotkeyLabel = g_ui.createWidget("HotkeyListLabel")

		hotkeyLabel:setId(keyCombo)

		local children = currentHotkeys:getChildren()
		children[#children + 1] = hotkeyLabel

		table.sort(children, function (a, b)
			if a:getId():len() < b:getId():len() then
				return true
			elseif a:getId():len() == b:getId():len() then
				return a:getId() < b:getId()
			else
				return false
			end
		end)

		for i = 1, #children do
			if children[i] == hotkeyLabel then
				currentHotkeys:insertChild(i, hotkeyLabel)

				break
			end
		end

		if keySettings then
			currentHotkeyLabel = hotkeyLabel
			hotkeyLabel.keyCombo = keyCombo
			hotkeyLabel.autoSend = toboolean(keySettings.autoSend)
			hotkeyLabel.action = keySettings.action
			hotkeyLabel.itemId = tonumber(keySettings.itemId)
			hotkeyLabel.subType = tonumber(keySettings.subType)
			hotkeyLabel.useType = tonumber(keySettings.useType)

			if keySettings.value then
				hotkeyLabel.value = tostring(keySettings.value)
			end
		else
			hotkeyLabel.keyCombo = keyCombo
			hotkeyLabel.autoSend = false
			hotkeyLabel.itemId = nil
			hotkeyLabel.subType = nil
			hotkeyLabel.useType = nil
			hotkeyLabel.action = nil
			hotkeyLabel.value = ""
		end

		updateHotkeyLabel(hotkeyLabel)

		local gameRootPanel = modules.game_interface.getRootPanel()

		if keyCombo:lower():find("ctrl") and boundCombosCallback[keyCombo] then
			g_keyboard.unbindKeyPress(keyCombo, boundCombosCallback[keyCombo], gameRootPanel)
		end

		boundCombosCallback[keyCombo] = function (k, c, ticks)
			prepareKeyCombo(keyCombo, ticks)
		end

		g_keyboard.bindKeyPress(keyCombo, boundCombosCallback[keyCombo], gameRootPanel)

		if not keyCombo:lower():find("ctrl") then
			local keyComboCtrl = "Ctrl+" .. keyCombo

			if not boundCombosCallback[keyComboCtrl] then
				boundCombosCallback[keyComboCtrl] = function (k, c, ticks)
					prepareKeyCombo(keyComboCtrl, ticks)
				end

				g_keyboard.bindKeyPress(keyComboCtrl, boundCombosCallback[keyComboCtrl], gameRootPanel)
			end
		end
	end

	if focus then
		currentHotkeys:focusChild(hotkeyLabel)
		currentHotkeys:ensureChildVisible(hotkeyLabel)
		updateHotkeyForm(true)
	end

	configValueChanged = true
end

function prepareKeyCombo(keyCombo, ticks)
	local hotKey = hotkeyList[keyCombo]

	if keyCombo:lower():find("ctrl") and not hotKey or hotKey and hotKey.itemId == nil and (not hotKey.value or #hotKey.value == 0) and not hotKey.action then
		keyCombo = keyCombo:gsub("Ctrl%+", "")
		keyCombo = keyCombo:gsub("ctrl%+", "")
		hotKey = hotkeyList[keyCombo]
	end

	if not hotKey then
		return
	end

	if hotKey.itemId == nil and hotKey.action == nil then
		scheduleEvent(function ()
			doKeyCombo(keyCombo, ticks >= 5)
		end, g_settings.getNumber("hotkeyDelay"))
	else
		doKeyCombo(keyCombo, ticks >= 5)
	end
end

function doKeyCombo(keyCombo, repeated)
	if not g_game.isOnline() then
		return
	end

	if modules.game_console and modules.game_console.isTypingKey(keyCombo) then
		return
	end

	if modules.game_walking then
		modules.game_walking.checkTurn()
	end

	local hotKey = hotkeyList[keyCombo]

	if not hotKey then
		return
	end

	local hotkeyDelay = 100

	if hotKey.hotkeyDelayTo == nil or g_clock.millis() > hotKey.hotkeyDelayTo + hotkeyDelay then
		hotkeyDelay = 200
	end

	if hotKey.hotkeyDelayTo ~= nil and g_clock.millis() < hotKey.hotkeyDelayTo then
		return
	end

	if hotKey.action then
		executeExtraHotkey(hotKey.action, repeated)
	elseif hotKey.itemId == nil then
		if not hotKey.value or #hotKey.value == 0 then
			return
		end

		if hotKey.autoSend then
			modules.game_console.sendMessage(hotKey.value)
		else
			modules.game_console.setTextEditText(hotKey.value)
		end

		hotKey.hotkeyDelayTo = g_clock.millis() + hotkeyDelay
	elseif hotKey.useType == HOTKEY_MANAGER_USE then
		if g_game.getClientVersion() < 780 then
			local item = g_game.findPlayerItem(hotKey.itemId, hotKey.subType or -1)

			if item then
				g_game.use(item)
			end
		else
			g_game.useInventoryItem(hotKey.itemId)
		end

		hotKey.hotkeyDelayTo = g_clock.millis() + hotkeyDelay
	elseif hotKey.useType == HOTKEY_MANAGER_USEONSELF then
		if g_game.getClientVersion() < 780 then
			local item = g_game.findPlayerItem(hotKey.itemId, hotKey.subType or -1)

			if item then
				g_game.useWith(item, g_game.getLocalPlayer())
			end
		else
			g_game.useInventoryItemWith(hotKey.itemId, g_game.getLocalPlayer(), hotKey.subType or -1)
		end

		hotKey.hotkeyDelayTo = g_clock.millis() + hotkeyDelay
	elseif hotKey.useType == HOTKEY_MANAGER_USEONTARGET then
		local attackingCreature = g_game.getAttackingCreature()

		if not attackingCreature then
			local item = Item.create(hotKey.itemId)

			if g_game.getClientVersion() < 780 then
				local tmpItem = g_game.findPlayerItem(hotKey.itemId, hotKey.subType or -1)

				if not tmpItem then
					return
				end

				item = tmpItem
			end

			modules.game_interface.startUseWith(item, hotKey.subType or -1)

			return
		end

		if not attackingCreature:getTile() then
			return
		end

		if g_game.getClientVersion() < 780 then
			local item = g_game.findPlayerItem(hotKey.itemId, hotKey.subType or -1)

			if item then
				g_game.useWith(item, attackingCreature, hotKey.subType or -1)
			end
		else
			g_game.useInventoryItemWith(hotKey.itemId, attackingCreature, hotKey.subType or -1)
		end

		hotKey.hotkeyDelayTo = g_clock.millis() + hotkeyDelay
	elseif hotKey.useType == HOTKEY_MANAGER_USEWITH then
		local item = Item.create(hotKey.itemId)

		if g_game.getClientVersion() < 780 then
			local tmpItem = g_game.findPlayerItem(hotKey.itemId, hotKey.subType or -1)

			if not tmpItem then
				return true
			end

			item = tmpItem
		end

		modules.game_interface.startUseWith(item, hotKey.subType or -1)
	end
end

function updateHotkeyLabel(hotkeyLabel)
	if not hotkeyLabel then
		return
	end

	if hotkeyLabel.action ~= nil then
		hotkeyLabel:setText(tr("%s: (Action: %s)", hotkeyLabel.keyCombo, getActionDescription(hotkeyLabel.action)))
		hotkeyLabel:setColor(HotkeyColors.extraAction)
	elseif hotkeyLabel.useType == HOTKEY_MANAGER_USEONSELF then
		hotkeyLabel:setText(tr("%s: (use object on yourself)", hotkeyLabel.keyCombo))
		hotkeyLabel:setColor(HotkeyColors.itemUseSelf)
	elseif hotkeyLabel.useType == HOTKEY_MANAGER_USEONTARGET then
		hotkeyLabel:setText(tr("%s: (use object on target)", hotkeyLabel.keyCombo))
		hotkeyLabel:setColor(HotkeyColors.itemUseTarget)
	elseif hotkeyLabel.useType == HOTKEY_MANAGER_USEWITH then
		hotkeyLabel:setText(tr("%s: (use object with crosshair)", hotkeyLabel.keyCombo))
		hotkeyLabel:setColor(HotkeyColors.itemUseWith)
	elseif hotkeyLabel.itemId ~= nil then
		hotkeyLabel:setText(tr("%s: (use object)", hotkeyLabel.keyCombo))
		hotkeyLabel:setColor(HotkeyColors.itemUse)
	else
		local text = hotkeyLabel.keyCombo .. ": "

		if hotkeyLabel.value then
			text = text .. hotkeyLabel.value
		end

		hotkeyLabel:setText(text)

		if hotkeyLabel.autoSend then
			hotkeyLabel:setColor(HotkeyColors.autoSend)
		else
			hotkeyLabel:setColor(HotkeyColors.text)
		end
	end
end

function updateHotkeyForm(reset)
	configValueChanged = true

	if hotkeysWindow.action then
		if currentHotkeyLabel then
			hotkeysWindow.action:enable()

			if currentHotkeyLabel.action then
				hotkeysWindow.action:setCurrentIndex(translateActionToActionComboboxIndex(currentHotkeyLabel.action), true)
			else
				hotkeysWindow.action:setCurrentIndex(1, true)
			end
		else
			hotkeysWindow.action:disable()
			hotkeysWindow.action:setCurrentIndex(1, true)
		end
	end

	local hasCustomAction = hotkeysWindow.action and hotkeysWindow.action.currentIndex > 1

	if currentHotkeyLabel and not hasCustomAction then
		removeHotkeyButton:enable()

		if currentHotkeyLabel.itemId ~= nil then
			hotkeyText:clearText()
			hotkeyText:disable()
			hotKeyTextLabel:disable()
			sendAutomatically:setChecked(false)
			sendAutomatically:disable()
			selectObjectButton:disable()
			clearObjectButton:enable()
			currentItemPreview:setItemId(currentHotkeyLabel.itemId)

			if currentHotkeyLabel.subType then
				currentItemPreview:setItemSubType(currentHotkeyLabel.subType)
			end

			if currentItemPreview:getItem():isMultiUse() then
				useOnSelf:enable()
				useOnTarget:enable()
				useWith:enable()

				if currentHotkeyLabel.useType == HOTKEY_MANAGER_USEONSELF then
					useRadioGroup:selectWidget(useOnSelf)
				elseif currentHotkeyLabel.useType == HOTKEY_MANAGER_USEONTARGET then
					useRadioGroup:selectWidget(useOnTarget)
				elseif currentHotkeyLabel.useType == HOTKEY_MANAGER_USEWITH then
					useRadioGroup:selectWidget(useWith)
				end
			else
				useOnSelf:disable()
				useOnTarget:disable()
				useWith:disable()
				useRadioGroup:clearSelected()
			end
		else
			useOnSelf:disable()
			useOnTarget:disable()
			useWith:disable()
			useRadioGroup:clearSelected()
			hotkeyText:enable()
			hotkeyText:focus()
			hotKeyTextLabel:enable()

			if reset then
				hotkeyText:setCursorPos(-1)
			end

			hotkeyText:setText(currentHotkeyLabel.value)
			sendAutomatically:setChecked(currentHotkeyLabel.autoSend)
			sendAutomatically:setEnabled(currentHotkeyLabel.value and #currentHotkeyLabel.value > 0)
			selectObjectButton:enable()
			clearObjectButton:disable()
			currentItemPreview:clearItem()
		end
	else
		removeHotkeyButton:disable()
		hotkeyText:disable()
		sendAutomatically:disable()
		selectObjectButton:disable()
		clearObjectButton:disable()
		useOnSelf:disable()
		useOnTarget:disable()
		useWith:disable()
		hotkeyText:clearText()
		useRadioGroup:clearSelected()
		sendAutomatically:setChecked(false)
		currentItemPreview:clearItem()
	end
end

function removeHotkey()
	if currentHotkeyLabel == nil then
		return
	end

	local gameRootPanel = modules.game_interface.getRootPanel()
	configValueChanged = true

	g_keyboard.unbindKeyPress(currentHotkeyLabel.keyCombo, boundCombosCallback[currentHotkeyLabel.keyCombo], gameRootPanel)

	boundCombosCallback[currentHotkeyLabel.keyCombo] = nil

	currentHotkeyLabel:destroy()

	currentHotkeyLabel = nil
end

function updateHotkeyAction()
	if not hotkeysManagerLoaded then
		return
	end

	if currentHotkeyLabel == nil then
		return
	end

	configValueChanged = true
	currentHotkeyLabel.action = translateActionComboboxIndexToAction(hotkeysWindow.action.currentIndex)

	updateHotkeyLabel(currentHotkeyLabel)
	updateHotkeyForm()
end

function onHotkeyTextChange(value)
	if not hotkeysManagerLoaded then
		return
	end

	if currentHotkeyLabel == nil then
		return
	end

	currentHotkeyLabel.value = value
	configValueChanged = true

	updateHotkeyLabel(currentHotkeyLabel)
	updateHotkeyForm()
end

function onSendAutomaticallyChange(autoSend)
	if not hotkeysManagerLoaded then
		return
	end

	if currentHotkeyLabel == nil then
		return
	end

	if not currentHotkeyLabel.value or #currentHotkeyLabel.value == 0 then
		return
	end

	configValueChanged = true
	currentHotkeyLabel.autoSend = autoSend

	updateHotkeyLabel(currentHotkeyLabel)
	updateHotkeyForm()
end

function onChangeUseType(useTypeWidget)
	if not hotkeysManagerLoaded then
		return
	end

	if currentHotkeyLabel == nil then
		return
	end

	configValueChanged = true

	if useTypeWidget == useOnSelf then
		currentHotkeyLabel.useType = HOTKEY_MANAGER_USEONSELF
	elseif useTypeWidget == useOnTarget then
		currentHotkeyLabel.useType = HOTKEY_MANAGER_USEONTARGET
	elseif useTypeWidget == useWith then
		currentHotkeyLabel.useType = HOTKEY_MANAGER_USEWITH
	else
		currentHotkeyLabel.useType = HOTKEY_MANAGER_USE
	end

	updateHotkeyLabel(currentHotkeyLabel)
	updateHotkeyForm()
end

function onSelectHotkeyLabel(hotkeyLabel)
	currentHotkeyLabel = hotkeyLabel

	if currentHotkeys and hotkeyLabel then
		currentHotkeys:ensureChildVisible(hotkeyLabel)
	end

	updateHotkeyForm(true)
end

function hotkeyCapture(assignWindow, keyCode, keyboardModifiers)
	local keyCombo = determineKeyComboDesc(keyCode, keyboardModifiers)
	local comboPreview = assignWindow:getChildById("comboPreview")

	if isTakenByActionBar(keyCombo) then
		comboPreview:setText(tr("%s is on your action bar. Remove it there first.", keyCombo))

		comboPreview.keyCombo = ""

		comboPreview:resizeToText()
		assignWindow:getChildById("addButton"):disable()

		return true
	end

	comboPreview:setText(tr("Current hotkey to add: %s", keyCombo))

	comboPreview.keyCombo = keyCombo

	comboPreview:resizeToText()
	assignWindow:getChildById("addButton"):enable()

	return true
end

function hotkeyCaptureOk(assignWindow, keyCombo)
	addKeyCombo(keyCombo, nil, true)
	assignWindow:destroy()
end


-- True when this window has a hotkey on that key (the action bar's Edit Hotkey
-- dialog asks, to warn before it takes the key over).
function isKeyComboUsed(keyCombo)
	if not keyCombo or keyCombo:len() == 0 or not currentHotkeys then
		return false
	end

	for _, child in ipairs(currentHotkeys:getChildren()) do
		if child.keyCombo and child.keyCombo:lower() == keyCombo:lower() then
			return true
		end
	end

	return false
end

-- Called by game_actionbar whenever its keys change. Every hotkey here whose
-- key is now on the action bar is unbound and deleted, and the player is told.
function syncWithActionBar()
	if not hotkeysManagerLoaded or not currentHotkeys then
		return
	end

	local gameRootPanel = modules.game_interface.getRootPanel()
	local removed = {}

	for _, child in ipairs(currentHotkeys:getChildren()) do
		local keyCombo = child.keyCombo

		if keyCombo and keyCombo:len() > 0 and isTakenByActionBar(keyCombo) then
			if boundCombosCallback[keyCombo] then
				g_keyboard.unbindKeyPress(keyCombo, boundCombosCallback[keyCombo], gameRootPanel)

				boundCombosCallback[keyCombo] = nil
			end

			-- the Ctrl+ twin this window bound for it, unless Ctrl+key is a hotkey of its own
			local ctrlCombo = "Ctrl+" .. keyCombo

			if not keyCombo:lower():find("ctrl") and boundCombosCallback[ctrlCombo] and not currentHotkeys:getChildById(ctrlCombo) then
				g_keyboard.unbindKeyPress(ctrlCombo, boundCombosCallback[ctrlCombo], gameRootPanel)

				boundCombosCallback[ctrlCombo] = nil
			end

			hotkeyList[keyCombo] = nil

			if currentHotkeyLabel == child then
				currentHotkeyLabel = nil
			end

			child:destroy()

			removed[#removed + 1] = keyCombo
		end
	end

	if #removed > 0 then
		configValueChanged = true

		save()
		updateHotkeyForm(true)

		if modules.game_textmessage and modules.game_textmessage.displayStatusMessage then
			modules.game_textmessage.displayStatusMessage(tr("%s is on your action bar now. It was removed from the Hotkeys window.", table.concat(removed, ", ")))
		end
	end
end
