CharacterList = {}
local charactersWindow, loadBox, characterList, errorBox, waitingWindow, autoReconnectButton, updateWaitEvent, resendWaitEvent, loginEvent, autoReconnectEvent = nil
local lastLogout = 0

-- Pinned characters. At most MAX_PINS names per account, kept on this computer
-- only (there is no server-side store for them). One settings key per account,
-- holding a plain list of names:  characterPins-<account>: [ Name A, Name B ]
--
-- setList/getList rather than a nested setNode table: Config::setList writes a
-- list of values under one key and getList reads it straight back, which is
-- exactly the shape needed and needs no round-trip through OTML children.
local MAX_PINS = 2
local accountStatusText, accountDaysText, accountStatusUrgent, flashNoteEvent = nil

local function pinsKey()
	local account = G and G.account or ""
	return "characterPins-" .. tostring(account):lower()
end

local function loadPins()
	local stored = g_settings.getList(pinsKey()) or {}
	local names = {}

	for _, name in ipairs(stored) do
		if type(name) == "string" and #name > 0 and #names < MAX_PINS then
			table.insert(names, name)
		end
	end

	return names
end

local function savePins(names)
	g_settings.setList(pinsKey(), names)
	g_settings.save()
end

local function isPinned(pins, name)
	for i, pinned in ipairs(pins) do
		if pinned == name then
			return i
		end
	end
end

-- Pinned first, highest level first among them; everything else keeps the
-- order the server sent (the query is ORDER BY name). A plain 0x64 list has no
-- levels, so there the pinned block keeps server order too.
local function sortCharacters(characters, pins)
	local order = {}
	for i, characterInfo in ipairs(characters) do
		order[characterInfo] = i
	end

	local sorted = {}
	for _, characterInfo in ipairs(characters) do
		table.insert(sorted, characterInfo)
	end

	table.sort(sorted, function(a, b)
		local pinnedA = isPinned(pins, a.name) ~= nil
		local pinnedB = isPinned(pins, b.name) ~= nil

		if pinnedA ~= pinnedB then
			return pinnedA
		end

		if pinnedA then
			local levelA = a.level or 0
			local levelB = b.level or 0

			if levelA ~= levelB then
				return levelA > levelB
			end
		end

		return order[a] < order[b]
	end)

	return sorted
end

local function tryLogin(charInfo, tries)
	tries = tries or 1

	if tries > 50 then
		return
	end

	if g_game.isOnline() then
		if tries == 1 then
			g_game.safeLogout()
		end

		loginEvent = scheduleEvent(function ()
			tryLogin(charInfo, tries + 1)
		end, 100)

		return
	end

	CharacterList.hide()
	g_game.loginWorld(G.account, G.password, charInfo.worldName, charInfo.worldHost, charInfo.worldPort, charInfo.characterName, G.authenticatorToken, G.sessionKey)
	g_logger.info("Login to " .. charInfo.worldHost .. ":" .. charInfo.worldPort)

	loadBox = displayCancelBox(tr("Please wait"), tr("Connecting to game server..."))

	connect(loadBox, {
		onCancel = function ()
			loadBox = nil

			g_game.cancelLogin()
			CharacterList.show()
		end
	})
	g_settings.set("last-used-character", charInfo.characterName)
	g_settings.set("last-used-world", charInfo.worldName)
end

-- Stage C (docs/client-launcher/PLAN.md 3.2): never enter the game on an old
-- client. It reuses the account check's manifest for 60 s. An old client gets
-- "Your client is out of date" with Update now / Back and no way past it.
local function checkThenLogin(charInfo)
	if not Updater or not Updater.check or UPDATER_DEV then
		return tryLogin(charInfo)
	end

	local done = false

	Updater.check({
		stage = "character",
		onShow = function ()
			done = true

			CharacterList.destroyLoadBox()
		end,
		onCurrent = function ()
			done = true

			CharacterList.destroyLoadBox()
			tryLogin(charInfo)
		end,
		onBack = function ()
			CharacterList.destroyLoadBox()
			CharacterList.show()
		end,
		onUpdated = function ()
			if EnterGame and EnterGame.saveRelogin then
				EnterGame.saveRelogin(charInfo.characterName, charInfo.worldName)
			end
		end
	})

	if not done then
		loadBox = displayCancelBox(tr("Please wait"), tr("Checking for updates..."))

		connect(loadBox, {
			onCancel = function ()
				loadBox = nil

				Updater.cancel()
				CharacterList.show()
			end
		})
	end
end

local function updateWait(timeStart, timeEnd)
	if waitingWindow then
		local time = g_clock.seconds()

		if time <= timeEnd then
			local percent = (time - timeStart) / (timeEnd - timeStart) * 100
			local timeStr = string.format("%.0f", timeEnd - time)
			local progressBar = waitingWindow:getChildById("progressBar")

			progressBar:setPercent(percent)

			local label = waitingWindow:getChildById("timeLabel")

			label:setText(tr("Trying to reconnect in %s seconds.", timeStr))

			updateWaitEvent = scheduleEvent(function ()
				updateWait(timeStart, timeEnd)
			end, 1000 * progressBar:getPercentPixels() / 100 * (timeEnd - timeStart))

			return true
		end
	end

	if updateWaitEvent then
		updateWaitEvent:cancel()

		updateWaitEvent = nil
	end
end

local function resendWait()
	if waitingWindow then
		waitingWindow:destroy()

		waitingWindow = nil

		if updateWaitEvent then
			updateWaitEvent:cancel()

			updateWaitEvent = nil
		end

		if charactersWindow then
			local selected = characterList:getFocusedChild()

			if selected then
				local charInfo = {
					worldHost = selected.worldHost,
					worldPort = selected.worldPort,
					worldName = selected.worldName,
					characterName = selected.characterName
				}

				tryLogin(charInfo)
			end
		end
	end
end

local function onLoginWait(message, time)
	CharacterList.destroyLoadBox()

	waitingWindow = g_ui.displayUI("waitinglist")
	local label = waitingWindow:getChildById("infoLabel")

	label:setText(message)

	updateWaitEvent = scheduleEvent(function ()
		updateWait(g_clock.seconds(), g_clock.seconds() + time)
	end, 0)
	resendWaitEvent = scheduleEvent(resendWait, time * 1000)
end

function onGameLoginError(message)
	CharacterList.destroyLoadBox()

	-- The server's client gate refused this client (GATE.md section 1): only
	-- an update helps, so offer one and do not reconnect by itself.
	if EnterGame and EnterGame.isGateMessage and EnterGame.isGateMessage(message) and Updater and Updater.check and not UPDATER_DEV then
		local function closeBox()
			local box = errorBox
			errorBox = nil

			if box then
				box:destroy()
			end

			return box ~= nil
		end

		local function checkNow()
			if closeBox() then
				EnterGame.checkForUpdates(CharacterList.showAgain, g_settings.get("last-used-character"), g_settings.get("last-used-world"))
			end
		end

		local function close()
			if closeBox() then
				CharacterList.showAgain()
			end
		end

		errorBox = displayGeneralBox(tr("Login Error"), message, {
			{
				text = tr("Check for updates"),
				callback = checkNow
			},
			{
				text = tr("Ok"),
				callback = close
			}
		}, checkNow, close)

		return
	end

	errorBox = displayErrorBox(tr("Login Error"), message)

	function errorBox.onOk()
		errorBox = nil

		CharacterList.showAgain()
	end

	scheduleAutoReconnect()
end

function onGameLoginToken(unknown)
	CharacterList.destroyLoadBox()

	errorBox = displayErrorBox(tr("Two-Factor Authentication"), "A new authentication token is required.\nPlease login again.")

	function errorBox.onOk()
		errorBox = nil

		EnterGame.show()
	end
end

function onGameConnectionError(message, code)
	CharacterList.destroyLoadBox()

	if (not g_game.isOnline() or code ~= 2) and not errorBox then
		local text = translateNetworkError(code, g_game.getProtocolGame() and g_game.getProtocolGame():isConnecting(), message)
		errorBox = displayErrorBox(tr("Connection Error"), text)

		function errorBox.onOk()
			errorBox = nil

			CharacterList.showAgain()
		end
	end

	scheduleAutoReconnect()
end

function onGameUpdateNeeded(signature)
	CharacterList.destroyLoadBox()

	errorBox = displayErrorBox(tr("Update needed"), tr("Enter with your account again to update your client."))

	function errorBox.onOk()
		errorBox = nil

		CharacterList.showAgain()
	end
end

function onGameEnd()
	scheduleAutoReconnect()
	CharacterList.showAgain()
end

function onLogout()
	lastLogout = g_clock.millis()
end

function scheduleAutoReconnect()
	if g_clock.millis() < lastLogout + 2000 then
		return
	end

	if autoReconnectEvent then
		removeEvent(autoReconnectEvent)
	end

	autoReconnectEvent = scheduleEvent(executeAutoReconnect, 5000)
end

function executeAutoReconnect()
	if not autoReconnectButton or not autoReconnectButton:isChecked() or g_game.isOnline() then
		return
	end

	if errorBox then
		errorBox:destroy()

		errorBox = nil
	end

	CharacterList.doLogin()
end

function CharacterList.init()
	if USE_NEW_ENERGAME then
		return
	end

	connect(g_game, {
		onLoginError = onGameLoginError
	})
	connect(g_game, {
		onLoginToken = onGameLoginToken
	})
	connect(g_game, {
		onUpdateNeeded = onGameUpdateNeeded
	})
	connect(g_game, {
		onConnectionError = onGameConnectionError
	})
	connect(g_game, {
		onGameStart = CharacterList.destroyLoadBox
	})
	connect(g_game, {
		onLoginWait = onLoginWait
	})
	connect(g_game, {
		onGameEnd = onGameEnd
	})
	connect(g_game, {
		onLogout = onLogout
	})

	if G.characters then
		CharacterList.create(G.characters, G.characterAccount)
	end
end

function CharacterList.terminate()
	if USE_NEW_ENERGAME then
		return
	end

	disconnect(g_game, {
		onLoginError = onGameLoginError
	})
	disconnect(g_game, {
		onLoginToken = onGameLoginToken
	})
	disconnect(g_game, {
		onUpdateNeeded = onGameUpdateNeeded
	})
	disconnect(g_game, {
		onConnectionError = onGameConnectionError
	})
	disconnect(g_game, {
		onGameStart = CharacterList.destroyLoadBox
	})
	disconnect(g_game, {
		onLoginWait = onLoginWait
	})
	disconnect(g_game, {
		onGameEnd = onGameEnd
	})
	disconnect(g_game, {
		onLogout = onLogout
	})

	if charactersWindow then
		characterList = nil

		charactersWindow:destroy()

		charactersWindow = nil
	end

	if loadBox then
		g_game.cancelLogin()
		loadBox:destroy()

		loadBox = nil
	end

	if waitingWindow then
		waitingWindow:destroy()

		waitingWindow = nil
	end

	if updateWaitEvent then
		removeEvent(updateWaitEvent)

		updateWaitEvent = nil
	end

	if resendWaitEvent then
		removeEvent(resendWaitEvent)

		resendWaitEvent = nil
	end

	if loginEvent then
		removeEvent(loginEvent)

		loginEvent = nil
	end

	CharacterList = nil
end

-- Builds (or rebuilds) the rows from G.characters. Split out of create() so a
-- pin can re-sort the list without a round trip to the login server.
--
-- keepFocusOn is a character name: after a re-sort the row that was selected
-- must stay selected, or pinning the character you were about to play silently
-- moves the selection to someone else.
function CharacterList.fillList(keepFocusOn)
	if not characterList then
		return
	end

	local characters = G.characters or {}
	local pins = loadPins()
	local sorted = sortCharacters(characters, pins)

	characterList:destroyChildren()

	local focusRow = nil
	local firstPinned = nil
	local lastUsedRow = nil

	for i, characterInfo in ipairs(sorted) do
		-- A hairline between the pinned characters and the rest. It says what
		-- the ordering means without a line of help text under the list.
		if #pins > 0 and i == #pins + 1 then
			g_ui.createWidget("CLPinDivider", characterList)
		end

		local widget = g_ui.createWidget("CharacterWidget", characterList)

		widget.characterName = characterInfo.name
		widget.worldName = characterInfo.worldName
		widget.worldHost = characterInfo.worldIp
		widget.worldPort = characterInfo.worldPort

		widget:getChildById("name"):setText(characterInfo.name)

		-- "Level 342 - Elite Knight". A plain 8.60 character list carries
		-- neither, so fall back to the world name rather than an empty row.
		local meta = widget:getChildById("meta")
		local level = characterInfo.level or 0
		local vocation = characterInfo.vocation

		-- "None" is what the server calls a rook character's vocation. Printing
		-- it says nothing, so the level stands on its own.
		if vocation == "None" then
			vocation = nil
		end

		local parts = {}

		if level > 0 then
			table.insert(parts, tr("Level %d", level))
		end

		if vocation and #vocation > 0 then
			table.insert(parts, vocation)
		end

		-- One world today, so its name on every row would be noise. It joins the
		-- same line the moment the account can see two of them -- never a third
		-- line, which is what makes the row twice as tall as it needs to be.
		if G.characterWorldCount and G.characterWorldCount > 1 and characterInfo.worldName then
			table.insert(parts, characterInfo.worldName)
		end

		if #parts == 0 then
			table.insert(parts, characterInfo.worldName or "")
		end

		meta:setText(table.concat(parts, "  " .. string.char(0xB7) .. "  "))

		local portrait = widget:getChildById("portrait")
		if characterInfo.outfit and characterInfo.outfit.type and characterInfo.outfit.type > 0 then
			portrait:setOutfit(characterInfo.outfit)
			portrait:setCenter(true)
			portrait:setAnimate(false)
			portrait:setVisible(true)
		else
			portrait:setVisible(false)
		end

		local pin = widget:getChildById("pin")
		local pinIndex = isPinned(pins, characterInfo.name)
		pin:setChecked(pinIndex ~= nil)

		function pin.onClick()
			CharacterList.togglePin(characterInfo.name)

			return true
		end

		connect(widget, {
			onDoubleClick = function ()
				CharacterList.doLogin()

				return true
			end
		})

		if pinIndex and not firstPinned then
			firstPinned = widget
		end

		if g_settings.get("last-used-character") == widget.characterName and g_settings.get("last-used-world") == widget.worldName then
			lastUsedRow = widget
		end

		if keepFocusOn and keepFocusOn == characterInfo.name then
			focusRow = widget
		end

		if i == 1 and not focusRow then
			focusRow = focusRow or widget
		end
	end

	-- Highest-level pinned character first: pin your main and Enter plays it.
	-- sortCharacters already put it at the top of the pinned block.
	if not keepFocusOn then
		focusRow = firstPinned or lastUsedRow or characterList:getFirstChild()
	end

	-- After an update restart: the character that was chosen (EnterGame.init)
	-- wins over the pins.
	local preselect = CharacterList.preselect
	CharacterList.preselect = nil

	if preselect then
		for _, widget in ipairs(characterList:getChildren()) do
			if widget.characterName == preselect.name and (not preselect.world or widget.worldName == preselect.world) then
				focusRow = widget
			end
		end
	end

	if focusRow then
		characterList:focusChild(focusRow, KeyboardFocusReason)
		addEvent(function ()
			if characterList and focusRow then
				characterList:ensureChildVisible(focusRow)
			end
		end)
	end

end

-- There is one line of text on this window, so a refusal borrows it rather than
-- adding permanent help text. It puts itself back.
function CharacterList.flashNote(text)
	if not charactersWindow then
		return
	end

	local label = charactersWindow:getChildById("accountStatusLabel")
	local days = charactersWindow:getChildById("accountDaysLabel")

	if not label then
		return
	end

	-- Borrow the whole line, days included, so the message has room.
	label:setText(text)
	label:setOn(true)

	if days then
		days:setText("")
	end

	if flashNoteEvent then
		removeEvent(flashNoteEvent)
	end

	flashNoteEvent = scheduleEvent(function()
		flashNoteEvent = nil

		if charactersWindow and label then
			label:setText(accountStatusText or "")
			label:setOn(accountStatusUrgent or false)

			if days then
				days:setText(accountDaysText or "")
				days:setOn(accountStatusUrgent or false)
			end
		end
	end, 3000)
end

function CharacterList.togglePin(name)
	local pins = loadPins()
	local index = isPinned(pins, name)

	if index then
		table.remove(pins, index)
	elseif #pins >= MAX_PINS then
		CharacterList.flashNote(tr("Only %d characters can be pinned. Unpin one first.", MAX_PINS))

		return
	else
		table.insert(pins, name)
	end

	savePins(pins)
	CharacterList.fillList(name)
end

function CharacterList.togglePinOnFocused()
	if not characterList then
		return
	end

	local selected = characterList:getFocusedChild()

	if selected and selected.characterName then
		CharacterList.togglePin(selected.characterName)
	end
end

function CharacterList.create(characters, account, otui)
	otui = otui or "characterlist"

	if charactersWindow then
		charactersWindow:destroy()
	end

	charactersWindow = g_ui.displayUI(otui)
	characterList = charactersWindow:getChildById("characters")
	autoReconnectButton = charactersWindow:getChildById("autoReconnect")
	G.characters = characters
	G.characterAccount = account

	-- The world name only earns a line on the row when there is more than one
	-- of them; with a single world it is the same string on every row.
	local worlds = {}
	local worldCount = 0

	for _, characterInfo in ipairs(characters) do
		local worldName = characterInfo.worldName or ""

		if not worlds[worldName] then
			worlds[worldName] = true
			worldCount = worldCount + 1
		end
	end

	G.characterWorldCount = worldCount

	local accountStatusLabel = charactersWindow:getChildById("accountStatusLabel")

	CharacterList.fillList()

	function characterList:onChildFocusChange(focusedChild)
		removeEvent(autoReconnectEvent)

		autoReconnectEvent = nil

		characterList:ensureChildVisible(focusedChild)
	end

	-- Two labels, not one line: what the account is, quietly on the left, and
	-- how much premium is left, bold and bright on the right. The old window
	-- buried "Premium Account (337) days left" in one grey sentence under a
	-- caption that repeated it.
	local accountDaysLabel = charactersWindow:getChildById("accountDaysLabel")
	local status = ""

	if account.status == AccountStatus.Frozen then
		status = tr(" (Frozen)")
	elseif account.status == AccountStatus.Suspended then
		status = tr(" (Suspended)")
	end

	if account.subStatus == SubscriptionStatus.Free and account.premDays < 1 then
		accountStatusText = ("%s%s"):format(tr("Free Account"), status)
		accountDaysText = ""
	elseif account.premDays == 0 or account.premDays == 65535 then
		accountStatusText = ("%s%s"):format(tr("Premium Account"), status)
		accountDaysText = tr("Unlimited")
	else
		accountStatusText = ("%s%s"):format(tr("Premium Account"), status)
		accountDaysText = tr("%d days left", account.premDays)
	end

	accountStatusUrgent = account.premDays > 0 and account.premDays <= 7
	accountStatusLabel:setText(accountStatusText)
	accountStatusLabel:setOn(accountStatusUrgent)
	accountDaysLabel:setText(accountDaysText)
	accountDaysLabel:setOn(accountStatusUrgent)

	function autoReconnectButton.onCheckChange(widget, checked)
		g_settings.set("autoReconnect", checked)
	end
end

function CharacterList.destroy()
	CharacterList.hide(true)

	if charactersWindow then
		characterList = nil

		charactersWindow:destroy()

		charactersWindow = nil
	end
end

function CharacterList.show()
	if loadBox or errorBox or not charactersWindow then
		return
	end

	charactersWindow:show()
	charactersWindow:raise()
	charactersWindow:focus()

	local autoReconnect = g_settings.getBoolean("autoReconnect", true)

	autoReconnectButton:setChecked(autoReconnect)
end

function CharacterList.hide(showLogin)
	removeEvent(autoReconnectEvent)

	autoReconnectEvent = nil
	showLogin = showLogin or false

	charactersWindow:hide()

	if showLogin and EnterGame and not g_game.isOnline() then
		EnterGame.show()
	end
end

function CharacterList.showAgain()
	if characterList and characterList:hasChildren() then
		CharacterList.show()
	end
end

function CharacterList.isVisible()
	if charactersWindow and charactersWindow:isVisible() then
		return true
	end

	return false
end

function CharacterList.doLogin()
	removeEvent(autoReconnectEvent)

	autoReconnectEvent = nil
	local selected = characterList:getFocusedChild()

	if selected then
		local charInfo = {
			worldHost = selected.worldHost,
			worldPort = selected.worldPort,
			worldName = selected.worldName,
			characterName = selected.characterName
		}

		charactersWindow:hide()

		if loginEvent then
			removeEvent(loginEvent)

			loginEvent = nil
		end

		checkThenLogin(charInfo)
	else
		displayErrorBox(tr("Error"), tr("You must select a character to login!"))
	end
end

function CharacterList.destroyLoadBox()
	if loadBox then
		loadBox:destroy()

		loadBox = nil
	end
end

function CharacterList.cancelWait()
	if waitingWindow then
		waitingWindow:destroy()

		waitingWindow = nil
	end

	if updateWaitEvent then
		removeEvent(updateWaitEvent)

		updateWaitEvent = nil
	end

	if resendWaitEvent then
		removeEvent(resendWaitEvent)

		resendWaitEvent = nil
	end

	CharacterList.destroyLoadBox()
	CharacterList.showAgain()
end
