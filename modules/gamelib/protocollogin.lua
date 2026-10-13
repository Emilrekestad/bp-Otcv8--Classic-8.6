-- @docclass
ProtocolLogin = extends(Protocol, "ProtocolLogin")

LoginServerError = 10
LoginServerTokenSuccess = 12
LoginServerTokenError = 13
LoginServerUpdate = 17
LoginServerMotd = 20
LoginServerUpdateNeeded = 30
LoginServerSessionKey = 40
LoginServerCharacterList = 100
LoginServerExtendedCharacterList = 101
LoginServerProxyList = 110

-- Since 10.76
LoginServerRetry = 10
LoginServerErrorNew = 11

-- BackpackOT client gate: the BPOT marker signature (docs/client-launcher/GATE.md
-- sections 4 and 5). Port of BackpackOTClient::generateSignature
-- (tfs-source/src/backpackotclient.h) to the engine's bit32: arguments are read
-- modulo 2^32, results are unsigned. Only a plain + does not wrap, so the one
-- sum is reduced with % 2^32. Checked against the C++ test vectors:
-- tools/client-gate-release/gate_signature.lua is this code.
local bor, bxor = bit32.bor, bit32.bxor
local lshift, rshift = bit32.lshift, bit32.rshift
local UINT32 = 4294967296

local function rotateLeft(value, bits)
  return bor(lshift(value, bits), rshift(value, 32 - bits))
end

-- C++: hash ^= value + 0x9E3779B9 + (hash << 6) + (hash >> 2);
--      return rotateLeft(hash, 7) ^ (value >> 3);
local function mixSignature(hash, value)
  local sum = (value + 0x9E3779B9 + lshift(hash, 6) + rshift(hash, 2)) % UINT32
  hash = bxor(hash, sum)
  return bxor(rotateLeft(hash, 7), rshift(value, 3))
end

-- os, version: the two u16 at the head of the packet, exactly as written.
-- xteaKey: the four key words, in the order they were written (1..4).
-- challengeTimestamp, challengeRandom: 0 (or nil) in the login-server packet.
-- Returns the number to write with msg:addU32 (0..4294967295).
function generateBpotSignature(os, version, xteaKey, challengeTimestamp, challengeRandom)
  local hash = 0xC19BC793
  hash = mixSignature(hash, 0xA0722E49)
  hash = mixSignature(hash, 0xD17CE629)
  hash = mixSignature(hash, os)
  hash = mixSignature(hash, version)
  for i = 1, 4 do
    hash = mixSignature(hash, xteaKey[i])
  end
  hash = mixSignature(hash, challengeTimestamp or 0)
  hash = mixSignature(hash, challengeRandom or 0)
  return bxor(hash, 0x0FA53ED2)
end

-- BackpackOT character list: the login server answers 0x65
-- (LoginServerExtendedCharacterList) with outfit, level and vocation per
-- character, then a 0xA1 block with today's boosted creature and boss -- but
-- ONLY when the login packet starts its markers with "A" + this signature
-- (GATE.md layout B: "A" + u32 | "BPOT" + u32 + u16 | u16 0). Without it the
-- answer is the plain 8.60 list (0x64, names only). Server side:
-- tfs-source/src/protocollogin.cpp getCharacterList and astraclient.h.
LoginServerBoostedInfo = 0xA1
BPOT_LOGIN_MARKER = "A"

-- Port of AstraClient::generateSignature; same mixer as the BPOT signature.
function generateLoginSignature(os, version, xteaKey)
  local hash = 0xA57AC11E
  hash = mixSignature(hash, 0x41737472) -- 'Astr'
  hash = mixSignature(hash, 0x61436C69) -- 'aCli'
  hash = mixSignature(hash, os)
  hash = mixSignature(hash, version)
  for i = 1, 4 do
    hash = mixSignature(hash, xteaKey[i])
  end
  hash = mixSignature(hash, 0) -- challengeTimestamp, unused at login
  hash = mixSignature(hash, 0) -- challengeRandom, unused at login
  return bxor(hash, 0x4D415354)
end

function ProtocolLogin:login(host, port, accountName, accountPassword, authenticatorToken, stayLogged)
  if string.len(host) == 0 or port == nil or port == 0 then
    signalcall(self.onLoginError, self, tr("You must enter a valid server address and port."))
    return
  end

  self.accountName = accountName
  self.accountPassword = accountPassword
  self.authenticatorToken = authenticatorToken
  self.stayLogged = stayLogged
  self.connectCallback = self.sendLoginPacket

  self:connect(host, port)
end

function ProtocolLogin:cancelLogin()
  self:disconnect()
end

function ProtocolLogin:sendLoginPacket()
  local msg = OutputMessage.create()
  msg:addU8(ClientOpcodes.ClientEnterAccount)
  -- kept: the BPOT signature covers the os and version exactly as written
  local packetOs = g_game.getOs()
  local packetVersion = g_game.getCustomProtocolVersion() > 0 and g_game.getCustomProtocolVersion()
                        or g_game.getProtocolVersion()
  msg:addU16(packetOs)
  msg:addU16(packetVersion)

  if g_game.getFeature(GameClientVersion) then
    msg:addU32(g_game.getClientVersion())
  end

  if g_game.getFeature(GameContentRevision) then
    msg:addU16(g_things.getContentRevision())
    msg:addU16(0)
  else
    msg:addU32(g_things.getDatSignature())
  end
  msg:addU32(g_sprites.getSprSignature())
  msg:addU32(PIC_SIGNATURE)

  if g_game.getFeature(GamePreviewState) then
    msg:addU8(0)
  end

  local xteaKey = nil
  local offset = msg:getMessageSize()
  if g_game.getFeature(GameLoginPacketEncryption) then
    -- first RSA byte must be 0
    msg:addU8(0)

    -- xtea key
    self:generateXteaKey()
    xteaKey = self:getXteaKey()
    msg:addU32(xteaKey[1])
    msg:addU32(xteaKey[2])
    msg:addU32(xteaKey[3])
    msg:addU32(xteaKey[4])
  end

  if g_game.getFeature(GameAccountNames) then
    msg:addString(self.accountName)
  else
    msg:addU32(tonumber(self.accountName))
  end

  msg:addString(self.accountPassword)

  if self.getLoginExtendedData then
    local data = self:getLoginExtendedData()
    msg:addString(data)
  else
    if xteaKey then
      -- First marker "A" (GATE.md layout B): asks for the rich character list.
      msg:addString(BPOT_LOGIN_MARKER)
      msg:addU32(generateLoginSignature(packetOs, packetVersion, xteaKey))
    else
      msg:addString("OTCv8")
      local version = g_app.getVersion():split(" ")[1]:gsub("%.", "")
      if version:len() == 2 then
        version = version .. "0"
      end
      msg:addU16(tonumber(version))
    end
    -- BackpackOT client gate (GATE.md section 2.2): "BPOT", the signature and
    -- this client's release, then u16 0, because the padding below is random.
    if xteaKey then
      msg:addString("BPOT")
      msg:addU32(generateBpotSignature(packetOs, packetVersion, xteaKey))
      msg:addU16(tonumber(APP_VERSION) or 0)
      msg:addU16(0) -- end of markers
    end
  end

  local paddingBytes = g_crypt.rsaGetSize() - (msg:getMessageSize() - offset)
  assert(paddingBytes >= 0)
  for i = 1, paddingBytes do
    msg:addU8(math.random(0, 0xff))
  end

  if g_game.getFeature(GameLoginPacketEncryption) then
    msg:encryptRsa()
  end

  if g_game.getFeature(GameOGLInformation) then
    msg:addU8(1) --unknown
    msg:addU8(1) --unknown

    if g_game.getProtocolVersion() >= 1072 then
      msg:addString(string.format('%s %s', g_graphics.getVendor(), g_graphics.getRenderer()))
    else
      msg:addString(g_graphics.getRenderer())
    end
    msg:addString(g_graphics.getVersion())
  end

  -- add RSA encrypted auth token
  if g_game.getFeature(GameAuthenticator) then
    offset = msg:getMessageSize()

    -- first RSA byte must be 0
    msg:addU8(0)
    msg:addString(self.authenticatorToken)

    if g_game.getFeature(GameSessionKey) then
      msg:addU8(booleantonumber(self.stayLogged))
    end

    paddingBytes = g_crypt.rsaGetSize() - (msg:getMessageSize() - offset)
    assert(paddingBytes >= 0)
    for i = 1, paddingBytes do
      msg:addU8(math.random(0, 0xff))
    end

    msg:encryptRsa()
  end

  if g_game.getFeature(GamePacketSizeU32) then
    self:enableBigPackets()
  end

  if g_game.getFeature(GameProtocolChecksum) then
    self:enableChecksum()
  end

  self:send(msg)
  if g_game.getFeature(GameLoginPacketEncryption) then
    self:enableXteaEncryption()
  end
  self:recv()
end

function ProtocolLogin:onConnect()
  self.gotConnection = true
  self:connectCallback()
  self.connectCallback = nil
end

function ProtocolLogin:onRecv(msg)
  while not msg:eof() do
    local opcode = msg:getU8()
    if opcode == LoginServerErrorNew then
      self:parseError(msg)
    elseif opcode == LoginServerError then
      self:parseError(msg)
    elseif opcode == LoginServerMotd then
      self:parseMotd(msg)
    elseif opcode == LoginServerUpdateNeeded then
      signalcall(self.onLoginError, self, tr("Client needs update."))
    elseif opcode == LoginServerTokenSuccess then
      local unknown = msg:getU8()
    elseif opcode == LoginServerTokenError then
      -- TODO: prompt for token here
      local unknown = msg:getU8()
      signalcall(self.onLoginError, self, tr("Invalid authentication token."))
    elseif opcode == LoginServerCharacterList then
      self:parseCharacterList(msg)
    elseif opcode == LoginServerExtendedCharacterList then
      self:parseExtendedCharacterList(msg)
    elseif opcode == LoginServerBoostedInfo then
      self:parseBoostedInfo(msg)
    elseif opcode == LoginServerUpdate then
      local signature = msg:getString()
      signalcall(self.onUpdateNeeded, self, signature)      
    elseif opcode == LoginServerSessionKey then
      self:parseSessionKey(msg)
    elseif opcode == LoginServerProxyList then
      local proxies = {}
      local proxiesCount = msg:getU8()
      for i=1, proxiesCount do
        local host = msg:getString()
        local port = msg:getU16()
        local priority = msg:getU16()        
        table.insert(proxies, {host=host, port=port, priority=priority})
      end      
      signalcall(self.onProxyList, self, proxies)
    else
      self:parseOpcode(opcode, msg)
    end
  end
  self:disconnect()
end

function ProtocolLogin:parseError(msg)
  local errorMessage = msg:getString()
  signalcall(self.onLoginError, self, errorMessage)
end

function ProtocolLogin:parseMotd(msg)
  local motd = msg:getString()
  signalcall(self.onMotd, self, motd)
end

function ProtocolLogin:parseSessionKey(msg)
  local sessionKey = msg:getString()
  signalcall(self.onSessionKey, self, sessionKey)
end

function ProtocolLogin:parseCharacterList(msg)
  local characters = {}

  if g_game.getProtocolVersion() > 1010 then
    local worlds = {}

    local worldsCount = msg:getU8()
    for i=1, worldsCount do
      local world = {}
      local worldId = msg:getU8()
      world.worldName = msg:getString()
      world.worldIp = msg:getString()
      world.worldPort = msg:getU16()
      world.previewState = msg:getU8()
      worlds[worldId] = world
    end

    local charactersCount = msg:getU8()
    for i=1, charactersCount do
      local character = {}
      local worldId = msg:getU8()
      character.name = msg:getString()
      character.worldName = worlds[worldId].worldName
      character.worldIp = worlds[worldId].worldIp
      character.worldPort = worlds[worldId].worldPort
      character.previewState = worlds[worldId].previewState
      characters[i] = character
    end

  else
    local charactersCount = msg:getU8()
    for i=1,charactersCount do
      local character = {}
      character.name = msg:getString()
      character.worldName = msg:getString()
      character.worldIp = iptostring(msg:getU32())
      character.worldPort = msg:getU16()

      if g_game.getFeature(GamePreviewState) then
        character.previewState = msg:getU8()
      end

      characters[i] = character
    end
  end

  local account = {}
  if g_game.getProtocolVersion() > 1077 then
    account.status = msg:getU8()
    account.subStatus = msg:getU8()

    account.premDays = msg:getU32()
    if account.premDays ~= 0 and account.premDays ~= 65535 then
      account.premDays = math.floor((account.premDays - os.time()) / 86400)
    end
  else
    account.status = AccountStatus.Ok
    account.premDays = msg:getU16()
    account.subStatus = account.premDays > 0 and SubscriptionStatus.Premium or SubscriptionStatus.Free
  end

  signalcall(self.onCharacterList, self, characters, account)
end

-- 0x65: the plain 8.60 list plus outfit, level and vocation per character.
-- Built by ProtocolLogin::getCharacterList in tfs-source/src/protocollogin.cpp;
-- the two must stay in step. (This replaces OTCv8's own use of opcode 101, a
-- serialised table plus an .otui name, which no BackpackOT server sends.)
function ProtocolLogin:parseExtendedCharacterList(msg)
  local characters = {}

  local charactersCount = msg:getU8()
  for i = 1, charactersCount do
    local character = {}
    character.name = msg:getString()
    character.worldName = msg:getString()
    character.worldIp = iptostring(msg:getU32())
    character.worldPort = msg:getU16()
    character.outfit = {
      type = msg:getU16(),
      head = msg:getU8(),
      body = msg:getU8(),
      legs = msg:getU8(),
      feet = msg:getU8(),
      addons = msg:getU8()
    }
    character.level = msg:getU32()
    character.vocation = msg:getString()
    characters[i] = character
  end

  local account = {}
  account.status = AccountStatus.Ok
  account.premDays = msg:getU16()
  account.subStatus = account.premDays > 0 and SubscriptionStatus.Premium or SubscriptionStatus.Free

  signalcall(self.onCharacterList, self, characters, account)
end

-- 0xA1, sent straight after the 0x65 list: today's boosted creature and boss.
-- It MUST be read even though nothing shows it yet, or the rest of the
-- message would be read as opcodes. Each entry is built by
-- addBoostedLoginEntry (tfs-source/src/protocollogin.cpp): a "valid" byte,
-- and only when it is 1 the u32 race id, the name and the outfit. (Until
-- 2026-10-13 this read name + outfit straight away, ran out of data on every
-- login and logged "InputMessage eof reached".)
function ProtocolLogin:parseBoostedInfo(msg)
  local function readEntry()
    local entry = {}
    if msg:getU8() == 0 then
      return entry
    end
    entry.raceId = msg:getU32()
    entry.name = msg:getString()
    entry.outfit = {
      type = msg:getU16(),
      head = msg:getU8(),
      body = msg:getU8(),
      legs = msg:getU8(),
      feet = msg:getU8(),
      addons = msg:getU8()
    }
    return entry
  end

  local boosted = {
    creature = readEntry(),
    boss = readEntry()
  }
  signalcall(self.onBoostedInfo, self, boosted)
end

function ProtocolLogin:parseOpcode(opcode, msg)
  signalcall(self.onOpcode, self, opcode, msg)
end

function ProtocolLogin:onError(msg, code)
  local text = translateNetworkError(code, self:isConnecting(), msg)
  signalcall(self.onLoginError, self, text)
end
