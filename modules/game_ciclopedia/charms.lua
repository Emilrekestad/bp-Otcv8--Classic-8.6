protoData = protoData or {}

local function requestBestiaryInfo()
	local protocolGame = g_game.getProtocolGame()
	if protocolGame then
    local msg = OutputMessage.create()
    msg:addU8(CyclopediaOpcode.Info)
    msg:addU8(2) -- which tab asked (charms tab); the server keys its cooldown on it, older servers ignore it
    protocolGame:send(msg)
	end  

end

local function parseSendBuyCharmRune(runeId, action, raceId)
	local protocolGame = g_game.getProtocolGame()
	if protocolGame then
    local msg = OutputMessage.create()
    msg:addU8(CyclopediaOpcode.Charm)
    msg:addU8(runeId)
    msg:addU8(action)
    msg:addU16(raceId or 0)
    protocolGame:send(msg)
	end  
end

local BestiaryData = 0x01
local bankGold = 0
local inventoryGold = 0
local selectedRaceId = 0
local goldPoints
withdrawWindow = nil
storedContentContainer = nil

local function readCharmCreatureOutfit(msg)
	if readCyclopediaCreatureOutfit then
		return readCyclopediaCreatureOutfit(msg)
	end

	return {
		name = msg:getString(),
		type = msg:getU16(),
		head = msg:getU8(),
		body = msg:getU8(),
		legs = msg:getU8(),
		feet = msg:getU8(),
		addons = msg:getU8()
	}
end

local function isCharmsView()
	return modules.game_ciclopedia and modules.game_ciclopedia.getCurrentType and modules.game_ciclopedia.getCurrentType() == "charms"
end

local function registerCharmsProtocol()
	if registerBestiaryProtocol then
		registerBestiaryProtocol()
	end
end

-- ---------------------------------------------------------------------------
-- Charm currencies, tiers and the shared confirm dialog.
--
-- (!) There are TWO currencies and this window only ever knew about one.
-- Major charms are unlocked and upgraded with charm POINTS; minor charms with
-- MINOR CHARM ECHOES, which the server mints whenever a major charm is
-- upgraded. Every affordability check here tested the point balance, so all
-- 11 minor charms rendered as affordable and then failed server-side with
-- "You do not have enough minor charm echoes."
--
-- The category now arrives on a byte the server was ALREADY sending as a
-- constant 0 (read into an unused `getGold` local), so the packet is exactly
-- the same size and an un-updated client is unaffected.
local CATEGORY_MINOR = 1
local TIER_ROMAN = { [1] = 'I', [2] = 'II', [3] = 'III' }
local MAX_TIER = 3

local charmPointsBalance = 0
local minorEchoBalance = 0
local charmResetCost = 0
-- Assignments are capped (6 on premium, 2 otherwise) and the refusal comes
-- back as a bare server message with no warning beforehand. The count rides
-- along in the charm packet, so the Select confirmation can say it up front.
local freeCharmSlots = 0

local function balanceFor(category)
	return category == CATEGORY_MINOR and minorEchoBalance or charmPointsBalance
end

local function currencyIcon(category)
	return category == CATEGORY_MINOR and '/images/modern_ui/charm' or '/images/modern_ui/charm_big'
end

local function currencyName(category)
	return category == CATEGORY_MINOR and 'Minor Charm Echoes' or 'Charm Points'
end

-- All four charm actions confirm through the same little window. The
-- show/raise/focus/lock dance was copy-pasted three times; upgrade and reset
-- would have made it five.
local function confirmAction(text, send)
	if not buyWindow then
		createBuyWindow()
	end
	buyWindow:show()
	buyWindow:raise()
	buyWindow:focus()

	local buyText = buyWindow:recursiveGetChildById('buyText')
	local buttonYes = buyWindow:recursiveGetChildById('buttonYes')
	buyText:setText(text)

	buttonYes.onClick = function()
		buyHide()
		charmsWindow:show()
		charmsWindow:raise()
		charmsWindow:focus()
		charmsWindow:lock()
		send()
		resetCharmsData()
	end
end

local function firstToUpper(str)
    return (str:gsub("^%l", string.upper))
end

function readCyclopediaCharmResources(msg)
	return {
		charmPoints = msg:getU32(),
		minorEchoes = msg:getU32(),
		maxCharmPoints = msg:getU32(),
		maxMinorEchoes = msg:getU32(),
		gold = msg:getU64()
	}
end

function sendBestiaryCharmsData(msg)
	local charmsView = isCharmsView()
	if charmsView and not charmsWindow then
		charmsWindow = g_ui.loadUI("styles/charms", getContentContainer())
	end

	local resources = readCyclopediaCharmResources(msg)
	charmPointsBalance = resources.charmPoints
	minorEchoBalance = resources.minorEchoes
	local goldAmount = resources.gold

	if charmsView and charmAmount then
		charmAmount:setText(comma_value(charmPointsBalance))
	end
	if charmsView and echoAmount then
		echoAmount:setText(comma_value(minorEchoBalance))
	end
	if charmsView and goldPoints then
		goldPoints:setText(comma_value(goldAmount))
	end
	BestiaryChangeAmount(charmPointsBalance, goldAmount)

	local charmsList = {}
	local charms = msg:getU8()
	for i = 1, charms do
		local runeId = msg:getU8()
		local runeName = msg:getString()
		local runeDescription = msg:getString()
		-- (!) This byte used to be a constant 0 read into an unused `getGold`.
		-- It now carries the charm's CATEGORY, which is the only way to know
		-- which of the two currencies the server will actually charge.
		local category = msg:getU8()
		local unlockPoints = msg:getU16()

		-- (!) This is the TIER (0-3), not a boolean. It was named
		-- `activatedStatus` and compared with `== 1`, so a charm at tier 2 or 3
		-- matched neither the unlocked nor the locked list and vanished from the
		-- window entirely, taking its creature assignment out of reach with it.
		local tier, assigned, raceId, removeRuneCost = msg:getU8(), false, 0, 0
		if tier > 0 then
			local isAssigned = msg:getU8()
			if isAssigned > 0 then
				assigned = true
				raceId = msg:getU16()
				removeRuneCost = msg:getU32()
				protoData[raceId] = readCharmCreatureOutfit(msg)
			end
		else
			msg:getU8()
		end

		table.insert(charmsList, {
			id = runeId,
			name = runeName,
			description = runeDescription,
			price = unlockPoints,
			category = category,
			tier = tier,
			assigned = assigned,
			raceId = raceId,
			removeRuneCost = removeRuneCost
		})
	end

	if charmsView and charmDescription and charmRune and charmInfoPrice and unlockCharmButton then
		createCharms(charmsList)
	end

	-- Both of these were parsed and dropped. The reset price is what the
	-- Reset Charms button quotes; the slot count is what tells the player why
	-- an assignment is about to be refused.
	charmResetCost = msg:getU32()
	freeCharmSlots = msg:getU8()

	if charmsView and resetCharmsButton then
		resetCharmsButton:setVisible(true)
		resetCharmsButton:setTooltip(string.format(
			'Clears every charm and its creature, refunds all charm points spent on major charms, and costs %s gold. Minor charm echoes are NOT refunded.',
			comma_value(charmResetCost)))
	end

	local finishedMonstersSize = msg:getU16()
	local generatedMonsters = {}
	for i = 1, finishedMonstersSize do
		local raceId = msg:getU16()
		local sPData = readCharmCreatureOutfit(msg)
		protoData[raceId] = sPData
		if charmsView and monsterSelecter and sPData then
			local monsterRow = g_ui.createWidget('MonsterCharm', monsterSelecter)
			if (i % 2 == 0) then monsterRow:setBackgroundColor("#484848") end

			monsterRow:setText(firstToUpper(sPData.name))
			monsterRow:setId("monsterWidget" .. i)
			table.insert(generatedMonsters, "monsterWidget" .. i)

			monsterRow.onClick = function(self)
				for j = 1, #generatedMonsters do
					local row = monsterSelecter:getChildById("monsterWidget" .. j)
					if row then
						row:setBackgroundColor((j % 2 == 0) and "#484848" or "#404040")
					end
				end

				-- Picking a creature arms the ASSIGN button now, not the
				-- progression one -- enabling Unlock/Upgrade here would have let a
				-- click spend points the player could not afford.
				local assignButton = informationContainer:recursiveGetChildById('assignCharmButton')
				if assignButton and assignButton:isVisible() then
					assignButton:enable()
					assignButton:setOpacity(1)
				end

				charmMonster:show()
				charmMonster:setOutfit(protoData[raceId])
				monsterRow:setBackgroundColor("#585858")
				selectedRaceId = raceId
			end
		end
	end
end

function createBuyWindow()
	-- if buyWindow then return end
	buyWindow = g_ui.displayUI('styles/buy_charm_rune')
	buyWindow:hide()
end

function buyHide()
	buyWindow:hide()
end

-- `c` is one charm: id, name, description, price (the NEXT tier's, 0 once
-- maxed), tier 0-3, category, assigned, raceId, removeRuneCost.
function setupCharm(c)
	charmMonster:hide()
	monsterSelecter:show()
	charmDescription:setText(c.description)
	charmRune:setImageSource('/images/game/charms/' .. c.id)

	local maxed = c.tier >= MAX_TIER
	local balance = balanceFor(c.category)
	local affordable = (not maxed) and c.price > 0 and balance >= c.price

	local tierLabel = informationContainer:recursiveGetChildById('charmTier')
	if tierLabel then
		tierLabel:setText(c.tier > 0 and TIER_ROMAN[c.tier] or '')
	end

	local priceIcon = charmPriceContainer:recursiveGetChildById('charmIcon')
	if priceIcon then
		priceIcon:setImageSource(currencyIcon(c.category))
	end

	charmInfoPrice:setText(maxed and '-' or comma_value(c.price))
	charmInfoPrice:setColor((maxed or affordable) and '#ffffff' or '#d33c3c')

	-- ---- progression: Unlock -> Upgrade -> Maxed --------------------------
	if maxed then
		unlockCharmButton:setText('Maxed')
		unlockCharmButton:disable()
		unlockCharmButton:setOpacity(0.5)
	else
		unlockCharmButton:setText(c.tier == 0 and 'Unlock' or 'Upgrade')
		unlockCharmButton:setEnabled(affordable)
		unlockCharmButton:setOpacity(affordable and 1 or 0.5)
	end

	unlockCharmButton.onClick = function()
		if maxed then
			return
		end
		local text
		if c.tier == 0 then
			text = string.format('Do you want to unlock the Charm %s? This will cost you %s %s.',
				c.name, comma_value(c.price), currencyName(c.category))
		else
			text = string.format('Do you want to upgrade the Charm %s to tier %s? This will cost you %s %s.',
				c.name, TIER_ROMAN[c.tier + 1], comma_value(c.price), currencyName(c.category))
		end
		confirmAction(text, function() parseSendBuyCharmRune(c.id, 0, nil) end)
	end

	-- ---- assignment: Select / Remove --------------------------------------
	local assignButton = informationContainer:recursiveGetChildById('assignCharmButton')

	if c.tier == 0 then
		-- Nothing to assign, and no creature list to pick from.
		if assignButton then assignButton:setVisible(false) end
		monsterSelecter:hide()
	else
		if assignButton then
			assignButton:setVisible(true)
			if c.assigned then
				assignButton:setText('Remove')
				assignButton:enable()
				assignButton:setOpacity(1)
			else
				-- Enabled by the creature rows once something is actually picked.
				assignButton:setText('Select')
				assignButton:disable()
				assignButton:setOpacity(0.5)
			end

			assignButton.onClick = function()
				if c.assigned then
					confirmAction(string.format(
						'Do you want to remove the Charm %s from this creature? This will cost you %s gold pieces.',
						c.name, comma_value(c.removeRuneCost)),
						function() parseSendBuyCharmRune(c.id, 2, c.raceId) end)
				else
					confirmAction(string.format(
						'Do you want to use the Charm %s for this creature? You have %d charm %s free.',
						c.name, freeCharmSlots, freeCharmSlots == 1 and 'slot' or 'slots'),
						function() parseSendBuyCharmRune(c.id, 1, selectedRaceId) end)
				end
			end
		end

		if c.assigned then
			charmMonster:show()
			if protoData[c.raceId] then
				charmMonster:setOutfit(protoData[c.raceId])
			end
			monsterSelecter:setOpacity(0.5)
			monsterSelecter:disable()
		else
			monsterSelecter:setOpacity(1)
			monsterSelecter:enable()
		end
	end

	createBuyWindow()
end

local function comparePrices(a, b)
	return a.price < b.price
end

-- (!) The split is on TIER, not on a boolean. See the note in
-- sendBestiaryCharmsData: `activated == 1` / `== 0` silently dropped every
-- charm above tier 1.
function createCharms(charmsData)
	local unlockedCharms = {}
	local lockedCharms = {}
	for i = 1, #charmsData do
		if charmsData[i].tier > 0 then
			table.insert(unlockedCharms, charmsData[i])
		else
			table.insert(lockedCharms, charmsData[i])
		end
	end

	table.sort(unlockedCharms, comparePrices)
	table.sort(lockedCharms, comparePrices)

	local generatedCharms = {}
	local firstCharm = false

	-- One card builder for both lists. They were two near-identical 40-line
	-- blocks that had already drifted apart (only the locked one set
	-- `row.unlocked`, only the unlocked one touched the monster portrait).
	local function buildCard(c, index)
		local row = g_ui.createWidget('Charm', charmSelecter)
		local widgetId = "charmWidget" .. index
		row:setId(widgetId)
		table.insert(generatedCharms, widgetId)

		row.unlocked = c.tier > 0
		row.charmRune:setImageSource('/images/game/charms/' .. c.id)
		row:setText(c.name)

		if c.tier > 0 then
			row.charmDisabler:hide()
		end

		local tierLabel = row:recursiveGetChildById('charmTier')
		if tierLabel then
			tierLabel:setText(c.tier > 0 and TIER_ROMAN[c.tier] or '')
		end

		local charmPriceContainer = row.charmPriceContainer
		local priceLabel = charmPriceContainer:recursiveGetChildById('charmPrice')
		local priceIcon = charmPriceContainer:recursiveGetChildById('charmIcon')
		if priceIcon then
			priceIcon:setImageSource(currencyIcon(c.category))
		end

		local maxed = c.tier >= MAX_TIER
		if maxed then
			priceLabel:setText('-')
			priceLabel:setColor('#ffffff')
		else
			priceLabel:setText(c.price >= 1000 and comma_value(c.price) or tostring(c.price))
			-- Priced in the currency the SERVER will charge, so a minor charm no
			-- longer reads as affordable off the point balance.
			priceLabel:setColor(balanceFor(c.category) >= c.price and '#ffffff' or '#d33c3c')
		end

		local charmMonsterWidget = row.charmMonsterContainer:recursiveGetChildById("charmMonster")
		if c.assigned and protoData[c.raceId] and charmMonsterWidget then
			charmMonsterWidget:setOutfit(protoData[c.raceId])
		end

		local affectedCharm = row.borderContainer
		local function selectThis()
			for _, id in ipairs(generatedCharms) do
				local other = charmSelecter:getChildById(id)
				if other then
					other.borderContainer:setBorderColor('#000000')
					other.borderContainer:setBorderWidth(0)
				end
			end
			setupCharm(c)
			affectedCharm:setBorderWidth(2)
			affectedCharm:setBorderColor('white')
		end

		affectedCharm.onClick = selectThis

		if not firstCharm then
			firstCharm = true
			affectedCharm:setBorderWidth(2)
			affectedCharm:setBorderColor('white')
			setupCharm(c)
		end
	end

	for i = 1, #unlockedCharms do
		buildCard(unlockedCharms[i], i)
	end
	for i = 1, #lockedCharms do
		buildCard(lockedCharms[i], i + #unlockedCharms)
	end
end

function initCharms()
	charmsWindow = g_ui.loadUI("styles/charms", getContentContainer())
	charmsWindow:show()
	
	-- Selecter for charms
	blackBG02 = charmsWindow:recursiveGetChildById('blackBG02')
		charmAmount = blackBG02:recursiveGetChildById('charmAmount')
	blackBG03 = charmsWindow:recursiveGetChildById('blackBG03')
		echoAmount = blackBG03:recursiveGetChildById('echoAmount')
	resetCharmsButton = charmsWindow:recursiveGetChildById('resetCharmsButton')
	
		goldPoints = charmsWindow:recursiveGetChildById('goldPoints')
		
	charmsContainer = charmsWindow:recursiveGetChildById('charmsContainer')
		charmSelecter = charmsContainer:recursiveGetChildById('charmSelecter')
	
	informationContainer = charmsWindow:recursiveGetChildById('informationContainer')
		monsterContainer = informationContainer:recursiveGetChildById('monsterContainer')
			charmMonster = monsterContainer:recursiveGetChildById('charmMonster')
		unlockCharmButton = informationContainer:recursiveGetChildById('unlockCharmButton')
		charmDescription = informationContainer:recursiveGetChildById('charmDescription')
		charmContainer = informationContainer:recursiveGetChildById('charmContainer')
		charmRune = informationContainer:recursiveGetChildById('charmRune')
		charmDisabler = informationContainer:recursiveGetChildById('charmDisabler')
		charmPriceContainer = informationContainer:recursiveGetChildById('charmPriceContainer')
			charmInfoPrice = charmPriceContainer:recursiveGetChildById('charmInfoPrice')
		monsterSelecter = informationContainer:recursiveGetChildById('monsterSelecter')
	
	connect(g_game, {
		onEnterGame = registerCharmsProtocol, 
		onPendingGame = registerCharmsProtocol,
		onGameStart = registerCharmsProtocol
	})
	
	registerCharmsProtocol()

	-- Action 3. Fully implemented server-side and previously unreachable: the
	-- client parsed its price and threw it away. The cost is read at CLICK
	-- time because it scales with level and is refreshed on every charm
	-- packet, so capturing it here would quote a stale number.
	if resetCharmsButton then
		resetCharmsButton.onClick = function()
			confirmAction(string.format(
				'Reset ALL charms? Every charm is locked again and unassigned. Charm points spent on major charms are refunded; minor charm echoes are NOT. This costs %s gold pieces.',
				comma_value(charmResetCost)),
				function() parseSendBuyCharmRune(0, 3, 0) end)
		end
	end

	-- We make the request
	requestBestiaryInfo()
end

function resetCharmsData()
	clearCharmsContainer()
	clearCharmsMonsterList()
	
	scheduleEvent(function() 
	requestBestiaryInfo()
	end, 10)
end

function clearCharmsContainer()
	while charmSelecter:getChildCount() > 0 do
		local child = charmSelecter:getLastChild()
		charmSelecter:destroyChildren(child)
	end
end

function clearCharmsMonsterList()
	while monsterSelecter:getChildCount() > 0 do
		local child = monsterSelecter:getLastChild()
		monsterSelecter:destroyChildren(child)
	end
end
