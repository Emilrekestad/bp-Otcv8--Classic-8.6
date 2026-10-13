-- BackpackOT Store.
--
-- See the header of game_store.otui for the layout and why it is shaped this
-- way. In short: category tabs across the top, sub-categories under them, a
-- 7-wide grid of pooled cards, and one action bar carrying the only Buy button
-- in the browsing view.

local OPCODE_STORE_TRANSFER = 0xF8
local OPCODE_STORE_HISTORY = 0xFA
local OPCODE_STORE_OPEN = 0xFB
local OPCODE_STORE_BUY = 0xFC
local OPCODE_STORE_SEND = 0xFD

-- Where "Buy Coins" sends the player. This shipped as a leftover pointing at
-- xangelserver.com -- an unrelated server's donation page -- and came back once
-- already in a rewrite, so it is worth guarding on any future edit of this file.
local DONATION_URL = "https://backpackot.com/points"

local RESP_ERROR = 0x00
local RESP_CATALOG = 0x01
local RESP_SUCCESS = 0x02
local RESP_HISTORY = 0x03

-- The user-facing name of the currency. The server calls it Tibia Coins
-- internally (player:getTibiaCoins), but every other window a player sees --
-- the Item Bazaar, Bao's ledger -- calls it BPC, and one currency with two
-- names in one client is a bug in the writing.
local CURRENCY = "BPC"

-- Status-line tones, matching the window's accent rules: green is a gain or a
-- completed action, the ember tone is reserved for a failure.
local COLOR_POSITIVE = "#8fd97f"
local COLOR_URGENT = "#e8825c"

-- Not a category title the server could ever send, so it cannot collide.
local HOME_KEY = "\1home"

-- What an offer actually IS, and where it lands once bought. Neither fact is
-- carried by the offer name -- "Golden Outfit Box" says nothing about whether
-- it arrives in your backpack, your Store Inbox, or straight onto your
-- character -- and delivery is the single most common surprise this store
-- produces. `where` is a noun phrase so the same string works both as a chip
-- and as the value half of "Delivery: Store Inbox" in the confirmation.
local OFFER_KINDS = {
  house = { kind = "House Kit", where = "Store Inbox" },
  hireling = { kind = "Hireling", where = "Store Inbox" },
  hireling_outfit = { kind = "Hireling Dress", where = "Store Inbox" },
  hireling_skill = { kind = "Hireling Skill", where = "Applied instantly" },
  blessing = { kind = "Blessing", where = "Applied to your character" },
  premium = { kind = "Premium Time", where = "Added to your account" },
  outfit = { kind = "Outfit", where = "Unlocked instantly" },
  mount = { kind = "Mount", where = "Unlocked instantly" },
  prey_wildcard = { kind = "Prey Wildcard", where = "Added to your character" },
  globalboost = { kind = "Server Boost", where = "Everyone online, right now" },
  expboost = { kind = "Boost", where = "Applied instantly" },
  battlepass = { kind = "Battle Pass", where = "Applied instantly" },
  changename = { kind = "Character Service", where = "Applied instantly" },
  sexchange = { kind = "Character Service", where = "Applied instantly" },
  weekly_task_expansion = { kind = "Task Hunt", where = "Permanent upgrade" },
  weekly_reduced_items = { kind = "Task Hunt", where = "Permanent upgrade" },
  weekly_kill_boost = { kind = "Task Hunt", where = "Applied instantly" },
  bounty_kill_boost = { kind = "Task Hunt", where = "Applied instantly" },
  -- The three resets. Without a row here they fell through to `item` and the
  -- tile told the buyer to look in a backpack that never receives anything.
  -- The wheel's type is still `wheelrespec` on the wire though the shop calls
  -- it a Wheel Reset, and it is the one reset that is not instant: the token
  -- waits in the wheel until a save takes points back out.
  charmreset = { kind = "Reset", where = "Applied instantly" },
  wheelrespec = { kind = "Reset", where = "Your next Talent Compass save" },
  ledgerreset = { kind = "Reset", where = "Applied instantly" },
  -- Prey slot, Weapon Proficiency, Talent Compass: the unlocks Old Man Bao
  -- also sells. A storage flag on the character; nothing is delivered.
  unlock = { kind = "Unlock", where = "Applied instantly" },
  -- The server sends every item to the Store Inbox unless the offer says
  -- delivery="backpack" (gamestore.lua deliverOffer). That attribute is not on
  -- the wire, so the one such offer is listed by id below.
  item = { kind = "Item", where = "Store Inbox" }
}

local BACKPACK_ITEM = { kind = "Item", where = "Your backpack" }
local BACKPACK_OFFERS = {
  [4701] = true, -- Loot Seller
}

-- What the landing screen promotes.
--
-- The two rows are picked by offer TYPE, so renaming or re-parenting a category
-- on the server cannot silently empty them. The shortlist is by offer ID,
-- because "the Dormant Waker, the Loot Seller, the five-pack of wildcards and
-- the blessing bundle" is an editorial choice and there is no attribute on the
-- wire that expresses it. Ids come from data/store/gamestore.xml; an id that no
-- longer exists is skipped rather than erroring, so this list degrades quietly.
local HOME_PREMIUM_TYPES = { premium = true }
local HOME_BOOST_TYPES = { globalboost = true }
-- The landing screen's shortlist. Six offers, three across, two rows.
--
-- (!) There were TWO shortlist bands until potions were pulled from the
-- catalogue: a Consumables row (the big potion packs, the blessing bundle, the
-- wildcard five-pack) and this one. Removing the twelve potion offers left
-- Consumables with two tiles in a four-wide grid, which is a half-empty row
-- with a heading over it -- so the two survivors moved here and the band went.
--
-- Both of them belong under Quality of Life in the catalogue anyway: Blessings
-- is a child category of it, and the wildcard pack lives in Convenience. So
-- this is not a reclassification, it is the shortlist matching the tree.
--
-- Six offers in three columns is two FULL rows. That is why the grid went from
-- four columns to three and the tiles from 216 to 290 wide -- which the long
-- names wanted regardless ("All regular Blessings" and "Daily Reward Shrine"
-- both wrapped to two lines at 216).
--
-- Ids come from data/store/gamestore.xml; an id that no longer exists is
-- skipped rather than erroring, so this list degrades quietly.
--
-- (!) Quietly is the trap, not the feature. The plain Imbuing Shrine (14307)
-- and Daily Reward Shrine (14303) were retired server-side, and this list had
-- pointed at both -- which would have shown a five-tile band with a hole in it
-- and nothing anywhere to say why. Retire an offer and check here.
local HOME_QOL = {
  4601,  -- Dormant Waker
  4701,  -- Loot Seller
  14306, -- Gilded Imbuing Shrine
  14311, -- Shiny Daily Reward Shrine
  2001,  -- All regular Blessings
  4002,  -- Prey Wildcard x5
}


-- ─── Grid geometry ─────────────────────────────────────────────────────────
--
-- (!) The grid holds a POOL of cards -- about one screenful plus a spare row
-- either side -- and never one card per offer.
--
-- Decorations alone is 173 offers, and a widget per offer means well over a
-- thousand widgets in one panel. Nothing about that is free: UIGridLayout::
-- addWidget calls update(), and internalUpdate() walks EVERY child calling
-- setRect, so filling the list is O(n^2); and scrolling moves the panel's
-- virtual offset, which re-runs that same full-list pass on every wheel tick.
-- Drawing was never the problem -- UIWidget::drawChildren already culls
-- off-screen children -- it is LAYOUT that scales with child count, so the fix
-- is to hold the child count still. Same treatment, and the same reasoning, as
-- game_achievements.
--
-- These mirror cell-size / cell-spacing / num-columns in game_store.otui. They
-- have to agree: the layout places the cards, this module computes the scroll
-- range and the row-to-offer mapping from the same numbers, and a disagreement
-- shows up as cards drifting away from the scrollbar.
local CARD_HEIGHT = 118
local CARD_SPACING = 6
local CARD_COLS = 7
local ROW_PITCH = CARD_HEIGHT + CARD_SPACING

-- A partial row can hang off the top and another off the bottom at the same
-- time, so a screenful of rows needs two spares to cover both edges.
local OVERSCAN_ROWS = 2

-- Which 13x13 icon each category takes from /images/store/categories (25 icons
-- in one 325x13 strip). These went unused while the store had a text-only rail;
-- they are back on the tabs and sub-tabs. An unmapped name falls back to index 0.
local categoryIconClips = {
  store_battlepass = 1,          -- gold star
  store_boosts = 3,              -- gilt plaque
  store_qol = 7,                 -- scroll with a green plus
  store_services = 7,
  store_potions = 10,            -- two potion flasks
  store_blessings = 8,           -- blessing ornament
  store_weapons = 12,            -- crossed weapons
  store_equipment = 13,          -- helmet
  store_backpacks = 9,           -- chest
  store_houses = 2,              -- house and hammer
  store_decorations = 6,         -- laden shelf
  store_furniture = 23,          -- armchair
  store_beds = 22,               -- bed
  store_hirelings = 5,           -- speech bubble
  store_hireling_dresses = 4,    -- garment
  store_hireling_signs = 3,      -- gilt plaque
  store_hireling_pets = 14,      -- animal head
  store_account = 20,            -- crown
  store_taskhunt = 12,
  store_prey = 18,               -- prey card
  -- names still used by older catalogue revisions
  store_premium = 20,
  store_extras = 7,
  store_consumables = 10,
  store_cosmetics = 15
}

local CATEGORY_ICON_SHEET = "/images/store/categories"
local HOME_ICON = "/images/store/icon-store-home"

-- The four landing-screen section headings, in the Item Bazaar's format: a
-- white title on the left, a muted note on the right.
--
-- The note is not decoration. Each of these four sections has exactly one thing
-- a first-time buyer gets wrong -- that Premium Time is per ACCOUNT and not per
-- character, that a boost is bought for the whole SERVER and not for you, that
-- the shortlists are shortcuts rather than the whole catalogue -- and the note
-- is where that goes. It is the same slot the Bazaar uses for "Hand-picked by
-- their sellers" and "Matched to Elite Knight".
--
-- (!) Set from here rather than in the .otui, and NOT because it is more
-- convenient. A StoreSectionHead's children cannot be overridden at the point
-- the template is placed -- the override is appended as a second child instead
-- of merged, and the unstyled duplicate is the one that ends up on screen. The
-- long version of that is on StoreSectionHead in game_store.otui.
local SECTION_HEADS = {
  premiumCap = { text = "Featured",
                 note = "Account-wide, and the days stack" },
  boostCap   = { text = "Server Boosts",
                 note = "Bought by one player, felt by everyone online" },
  pickCap    = { text = "Quality of Life",
                 note = "Bought once, kept forever" },
}

-- The Featured spotlight's own copy. The blurb prefers the server's own
-- description for the Premium Time category, so a catalogue edit reaches the
-- landing screen without a client change; this is only the fallback.
local SPOTLIGHT_TITLE = "Premium Time"
local SPOTLIGHT_BLURB =
  "Premium areas, faster travel, more spells, house rental, offline training " ..
  "and larger depots -- on every character on the account."

-- Showcase tile geometry, mirroring the spotlight's `offers` grid and
-- boostRow / pickRow in the .otui. Every one of these must agree with that row's
-- `cell-size` and `cell-spacing`: UIGridLayout resizes every child to the cell,
-- so a template that disagrees is silently clipped or padded, and the band
-- arithmetic below would measure a height the tiles do not occupy.
--
-- Three shapes, because the three kinds of tile carry different things:
--
--   spotlight  180x52, 2 across   Premium Time price points, on the plaque
--   boost      171x66, 5 across   painted cap + headline + price  (887 wide)
--   shortlist  290x72, 3 across   artwork slot + name + price     (886 wide)
--
-- Premium Time has no tile row of its own any more -- it is the spotlight, and
-- its four price points sit inside it. Boosts took the full width the premium
-- column used to occupy, which turned them from two rows of three into one row
-- of six: 6 x 141 + 5 x 8 = 886 of 888.
local TILE_HEIGHT = 72
local TILE_SPACING = 8
local TILE_COLS = 3

local PREMIUM_TILE_HEIGHT = 52
local PREMIUM_COLS = 2

local BOOST_TILE_HEIGHT = 66
local BOOST_SPACING = 8
local BOOST_COLS = 5

-- ─── Server Boost accent ───────────────────────────────────────────────────
--
-- Every boost cap bar is painted this one leaf green, with the name on it in
-- near-black.
--
-- (!) It was SIX different hues -- gold, amber, violet, green, blue, red, one
-- per boost. That was the fix for six identical grey rectangles, and it
-- overcorrected: a rainbow across the widest band on the landing screen, with
-- five accents that carried no meaning. The boosts are one KIND of thing, so
-- they get one colour, and the name on each bar is what tells them apart.
--
-- The green is the owner's, matched to a leaf.
--
-- (!) The first attempt at it was #6a9a45, chosen LIGHT so the cap's near-black
-- text would still contrast -- and the owner's answer was that it is not the
-- green they asked for. It was not: letting the text colour pick the green is
-- backwards. The green is the requirement; the text works around it.
--
-- So the green went deep and rich the way a leaf actually is, and the cap text
-- inverted from near-black to cream (see StoreBoostTile). Light-on-dark also
-- matches every other surface in this window, where the one exception is the
-- Featured plaque.
local BOOST_ACCENT = "#4a7a30"

-- ─── Section pages ─────────────────────────────────────────────────────────
--
-- A top-level tab shown as a stack of headed sections rather than as one flat
-- grid: Account, Quality of Life, Backpacks. Its sub-categories become the
-- headings, and there is no sub-tab strip at all.
--
-- These mirror StoreOfferRow / StoreBlessingBand / StoreSectionHead in
-- game_store.otui and have to agree with them -- the .otui places the tiles,
-- this module computes the row heights that make the grids visible, and a
-- disagreement is a row that shows its first line and silently hides the rest.
local SECTION_TILE_HEIGHT = 116
local SECTION_TILE_SPACING = 8
local SECTION_TILE_COLS = 2

local BLESSING_TILE_HEIGHT = 76
local BLESSING_TILE_SPACING = 8
local BLESSING_TILE_COLS = 2
local BLESSING_BAND_HEIGHT = 244

local SECTION_HEAD_HEIGHT = 30
local SECTION_GAP = 12

-- How big a tab can be and still be worth showing whole.
--
-- Sub-tabs earn their click on a catalogue you cannot see at once -- House is
-- 317 offers across five kinds of furniture, and no page shows that. Below
-- this, they were only hiding four fifths of the tab behind a chip: Account
-- was Premium Time (4) and Character Services (2) behind two of them, with
-- half a row empty in each.
--
-- 48 is three full screens of the section page's own tiles, which is the point
-- where scrolling to compare two sections stops being reasonable. Today it
-- takes Account (6), Backpacks (11) and Quality of Life (21), and leaves House
-- with its chips.
local SECTION_PAGE_MAX = 48

-- The one line under each section heading. Same slot, same job as the landing
-- screen's SECTION_HEADS notes: the single thing a first-time buyer gets wrong
-- about that group, not a summary of it.
--
-- Keyed by the category name the SERVER sends, so renaming a category there
-- (data/scripts/network/gamestore/gamestore.lua, RENAMED_CATEGORIES) means
-- renaming its key here. A section with no entry simply shows no note.
local SECTION_NOTES = {
  ["Premium Time"] = "Every character on the account, and the days stack",
  ["Character Services"] = "Out of combat, in a protection zone",
  ["Convenience"] = "Bought once, kept forever",
  ["Blessings"] = "Cuts what you lose when you die",
  ["Training & Gear"] = "Dummies arrive as kits for your house",
  ["Task Hunt"] = "AstraClient only",
  ["Utility"] = "Changes what you can carry",
  ["Cosmetic"] = "Twenty slots, like any backpack -- these are for the look",
}

-- Space a tab spends on its icon before the text starts, matching the
-- icon-offset / text-offset pair on StoreTabButton and StoreSubTab.
local TAB_ICON_LEAD = 26
local SUBTAB_ICON_LEAD = 24

-- The usable width of the tab strip. Hard-coded rather than measured off the
-- live widget: the window is a fixed 920 with 16px of frame padding either
-- side, and buildTabs can run before the strip has been through a layout pass,
-- where getWidth() would still be 0 and every tab would come out minimum width.
-- 888 of window less the wallet block that now shares this row -- balance 104,
-- 4, Get 56 -- and 12 of clearance.
local TAB_STRIP_WIDTH = 712
local SUBTAB_STRIP_WIDTH = 560

-- The height of homePanel once the window frame, the tab strip and the footer
-- have taken their share of the fixed 920x560. The showcase still measures
-- itself from the tiles the server actually sent; this is only what it has to
-- fit inside.
--
--   MainWindow 620 - padding-top 35 - padding-bottom 10   = 575 of client area
--   less tabBar 23, homePanel margin-top 10,
--        closeButton 21, homePanel margin-bottom 8        = 513
--
-- The window went 560 -> 620 in this revision: the believed ceiling of 600 came
-- from updater.lua's `g_window.resize`, which runs AFTER a
-- `setMinimumSize({800, 640})` on the line above and is therefore clamped. The
-- real floor is 640. See the size note in game_store.otui.
--
-- (!) An earlier version declared 457 and drew 476, so the last band overhung
-- the footer on every install -- and because a Panel does not clip, nothing
-- said so except the showcase's missing bottom edge. The sections measure 506
-- now, and drawHome still warns if that ever stops being true.
local HOME_PANEL_HEIGHT = 513

local categories = {}
local offersByCat = {}
local offerById = {}
local topOrder = {}
local childOrder = {}
local history = {}

local gameStoreWindow = nil
local gameStoreButton = nil
local transferWindow = nil
local changeNameWindow = nil
local msgWindow = nil
local pendingBuyOffer = nil

local view = "home"
local activeTop = nil
local activeLeaf = nil
local searchQuery = nil
local selectedOfferId = nil
local visible = {}

-- The card pool and its scroll state. `pool` is a fixed set of widgets; which
-- offer each one shows is rebound as the grid scrolls.
local pool = {}
local poolFirstRow = -1
local scrollValue = 0
local suppressScrollEvent = false

local premiumPoints = 0
local entriesPerPage = 24
local currentPage = 1
local totalPages = 1

local statusEvent = nil
local pendingConfirm = nil

-- Where the player was standing when a purchase forced a catalogue refresh.
-- Without this, buying anything dropped you back on the landing screen, which
-- is a long way from wherever you were shopping.
local restoreState = nil

local function trim(value)
  return (value or ""):gsub("^%s*(.-)%s*$", "%1")
end

function comma_value(n)
  local left, num, right = string.match(tostring(n), "^([^%d]*%d)(%d*)(.-)$")
  if not left then
    return tostring(n)
  end
  return left .. (num:reverse():gsub("(%d%d%d)", "%1,"):reverse()) .. right
end

-- (!) Only ever call this with an id that is unique across the whole window.
-- recursiveGetChildById resolves a repeated id by traversal order, which is
-- luck rather than design -- and `art`, `name`, `price`, `title` and `value`
-- all appear on several templates in this file. Those are always reached
-- through the widget that owns them (card:getChildById('name'), and so on).
local function find(id)
  return gameStoreWindow and gameStoreWindow:recursiveGetChildById(id)
end

-- The server hands category and offer text straight out of the XML attribute,
-- entities and all, so "Barrel &amp; Anchor Lamp" arrives on the wire with the
-- entity intact and renders literally. Nothing between the XML and the socket
-- decodes it, so the client does -- for the five standard XML entities, which
-- is all this catalogue contains.
local XML_ENTITIES = { amp = "&", lt = "<", gt = ">", quot = "\"", apos = "'" }

local function unescape(text)
  if not text or not text:find("&", 1, true) then
    return text
  end
  return (text:gsub("&(%a+);", function(name)
    return XML_ENTITIES[name] or ("&" .. name .. ";")
  end))
end

local function getStoreImage(icon)
  if not icon or icon == "" then
    return nil
  end

  -- Most house offers carry the extension in the attribute itself
  -- (icon="Baby_Bonelord.png") and the old code appended a second one, so the
  -- lookup silently found nothing. None of those files ship today, so this
  -- changes no artwork -- but it is what the attribute plainly means.
  icon = icon:gsub("%.png$", "")

  local source = "/images/store/" .. icon
  if g_resources.fileExists(source .. ".png") then
    return source
  end

  source = "/images/game/prey/" .. icon
  if g_resources.fileExists(source .. ".png") then
    return source
  end

  return nil
end

-- Draws an offer into a StoreArt slot: a store PNG, an item sprite, an outfit
-- or a mount, whichever the offer actually is.
--
-- The four visuals are sized here rather than in the .otui because the same
-- template is used at four scales -- 68px on a card and in the confirmation,
-- 48px in the action bar, 44px on a landing tile -- and a hard-coded 64 would
-- overflow the smallest of them.
--
-- (!) Less ART_INSET. StoreArt is the client's inventory-slot artwork now, not
-- a bare transparent panel, so the visual has to sit INSIDE a 1px bevel on
-- each side; filling the slot edge to edge paints over the recess that makes
-- it read as a slot at all. Two pixels a side is the smallest inset that
-- survives a sprite with hard edges.
local ART_INSET = 4

-- Hireling name plaques. The server packs the material and the ink colour
-- into the offer's own `icon` string ("hplaque:oak:f2dcb8") rather than adding
-- a wire field, so this is the only place that has to know the shape.
--
-- The card draws the REAL plaque picture, nine-sliced exactly as the world
-- draws it, with "Hireling" standing in for the name -- a plaque is bought for
-- how it will look over a head, and the item sprite it is delivered as says
-- nothing about that.
local PLAQUE_PREFIX = "hplaque:"

local function parsePlaqueIcon(icon)
  if type(icon) ~= "string" or icon:sub(1, #PLAQUE_PREFIX) ~= PLAQUE_PREFIX then
    return nil
  end
  local material, colour = icon:match("^" .. PLAQUE_PREFIX .. "([%w_]+):(%x%x%x%x%x%x)$")
  if not material then
    return nil
  end
  return material, "#" .. colour
end

local function setOfferVisual(art, offer)
  local image = art:getChildById("image")
  local item = art:getChildById("item")
  local outfit = art:getChildById("outfit")
  local mount = art:getChildById("mount")
  local plaque = art:getChildById("plaque")

  art:show()

  image:hide()
  item:hide()
  outfit:hide()
  mount:hide()
  plaque:hide()

  local box = math.min(64, math.max(16, art:getHeight() - ART_INSET))
  image:setWidth(box)
  image:setHeight(box)
  item:setWidth(box)
  item:setHeight(box)

  local material, ink = parsePlaqueIcon(offer.icon)
  if material then
    local source = "/images/game/hirelings/plaque_" .. material .. ".png"
    if g_resources.fileExists(source) then
      plaque:setImageSource(source)
      local label = plaque:getChildById("plaqueCardName")
      label:setText("Hireling")
      label:setColor(ink)
      plaque:show()
      return
    end
    -- No picture shipped for this material: fall through to the item sprite
    -- rather than showing an empty slot.
  end

  local imageSource = getStoreImage(offer.icon)
  if imageSource then
    image:setImageSource(imageSource)
    image:show()
    return
  end

  -- Hireling dresses are outfits too: the wire sends the LOOKTYPE in offer.id
  -- (the server writes offer.eid there), so drawing them through the item path
  -- renders whatever item happens to share that number. House pets are the
  -- same shape -- the card shows the animal itself rather than a basket.
  if offer.oftype == "outfit" or offer.oftype == "hireling_outfit" or offer.oftype == "hireling_pet" then
    local outfitData = { type = offer.id }
    -- A dress is worn by a person, so it is previewed on the player's own
    -- colours. An animal has one sprite layer and no addons, so it is drawn
    -- bare -- borrowing the player's colours there would be meaningless.
    local player = g_game.getLocalPlayer()
    if player and offer.oftype ~= "hireling_pet" then
      outfitData = player:getOutfit()
      outfitData.type = offer.id
    end
    outfit:setOutfit(outfitData)
    outfit:show()
  elseif offer.oftype == "mount" then
    mount:setOutfit({ type = offer.id })
    mount:show()
  elseif offer.id and offer.id > 0 then
    item:setItemId(offer.id)
    item:show()
  else
    local fallback = getStoreImage("mount")
    if fallback then
      image:setImageSource(fallback)
      image:show()
    end
  end
end

-- (!) Hides the SLOT too, not just what is in it. Now that StoreArt draws the
-- client's recessed inventory frame, leaving it up with nothing inside puts an
-- empty socket next to "Pick an offer to see what it does" in the action bar.
-- Anchors resolve against a hidden widget's rect, so the labels beside it do
-- not shift when it goes.
local function hideArt(art)
  for _, id in ipairs({ "image", "item", "outfit", "mount", "plaque" }) do
    art:getChildById(id):hide()
  end
  art:hide()
end

-- Every offer the landing screen shows, keyed by id. Rebuilt with the
-- catalogue, and used both to fill the showcase and to decide which top-level
-- sections still need a tab.
local promoted = {}

local function rebuildPromoted()
  promoted = {}
  for _, offer in pairs(offerById) do
    if HOME_PREMIUM_TYPES[offer.oftype] or HOME_BOOST_TYPES[offer.oftype] then
      promoted[offer.offerId] = true
    end
  end
  for _, list in ipairs({ HOME_QOL }) do
    for _, id in ipairs(list) do
      if offerById[id] then
        promoted[id] = true
      end
    end
  end
end

-- Offers of a top-level section, including everything under its children.
local function sectionOffers(title)
  local out = {}
  local leaves = childOrder[title]
  if not leaves or #leaves == 0 then
    leaves = { title }
  end
  for _, leaf in ipairs(leaves) do
    for _, offer in ipairs(offersByCat[leaf] or {}) do
      out[#out + 1] = offer
    end
  end
  return out
end

-- A top-level section small enough to show whole gets a SECTION PAGE: its
-- sub-categories become headings on one scrolling page, and it has no sub-tab
-- strip at all.
--
-- This replaced a narrower rule that flattened a section into one grid row if
-- it fit in one -- which took Account and nothing else, and threw away the very
-- thing the sub-tabs had been carrying. Premium Time is not Character Services;
-- blessings are not exercise dummies. The groups are real, so the page keeps
-- them and shows them all at once instead of charging a click for each.
--
-- Sub-tabs still earn their place above SECTION_PAGE_MAX, where no page can
-- show the tab whole and navigating IS the problem being solved.
--
-- (!) A section with no children never qualifies, whatever its size: there
-- would be nothing to head the sections with. Those browse as a flat grid.
--
-- Sections that keep their sub-tabs whatever their size. A section page is the
-- right default where the groups are variations on one thing -- three sizes of
-- the same fixture, two kinds of premium time -- and reading them in one scroll
-- costs nothing.
--
-- The Hireling tab is not that. Its four groups are four different KINDS of
-- thing, bought for different reasons and used in different places: a job is a
-- contract you spend on one hireling, a dress is unlocked once for the whole
-- character, a plaque hangs over his head, a pet lives in your house. At 29
-- offers it falls well under SECTION_PAGE_MAX and would otherwise arrive as one
-- continuous scroll, which is exactly what the owner asked to be rid of.
local ALWAYS_SUBTABS = {
  ["Hireling"] = true,
}

local function isSectionPage(title)
  if ALWAYS_SUBTABS[title] then
    return false
  end
  local children = childOrder[title]
  if not children or #children == 0 then
    return false
  end
  return #sectionOffers(title) <= SECTION_PAGE_MAX
end

-- (!) A top-level section whose every offer is already on the landing screen
-- gets NO tab. That is how Server Boosts stays a real category on the server --
-- keeping its ids, prices and delivery rules -- while costing nothing in the
-- tab strip. A section with even one unpromoted offer keeps its tab, which is
-- why Account survives (Name Change and Sex Change are not promoted).
local function isFullyPromoted(title)
  local offers = sectionOffers(title)
  if #offers == 0 then
    return false
  end
  for _, offer in ipairs(offers) do
    if not promoted[offer.offerId] then
      return false
    end
  end
  return true
end

local function kindInfo(offer)
  if offer and BACKPACK_OFFERS[offer.offerId] then
    return BACKPACK_ITEM
  end
  return OFFER_KINDS[offer and offer.oftype or "item"] or OFFER_KINDS.item
end

local function offerDescription(offer)
  local description = offer.description
  if not description or description == "" then
    local category = categories[offer.categoryTitle]
    description = category and category.description or ""
  end
  return description
end

-- The label a card and the action bar show. A pack size belongs in front of the
-- name -- "125x Mana Potion" is what you are buying, and it is also the only
-- thing telling the two Mana Potion offers apart.
--
-- (This is why offers are no longer merged by name into one card with two
-- prices, the way the single-column list did it: six pairs of potions were the
-- only case, and two honestly labelled cards beat one card with two buttons.)
local function offerLabel(offer)
  -- oftype, not the category: only a real item stack has a meaningful count.
  -- Premium Time carries count=30..360 (its length in days) and would otherwise
  -- read as "30x 30 Days of Premium Time".
  if offer.count and offer.count > 1 and offer.oftype == "item" then
    return comma_value(offer.count) .. "x " .. offer.name
  end
  return offer.name
end

local function priceLabel(offer)
  return comma_value(offer.price) .. " " .. CURRENCY
end

-- ─── status line ───────────────────────────────────────────────────────────

-- A one-line result, shown next to the buttons that caused it and cleared on a
-- timer. Same mechanism as the Item Bazaar's, so the two windows report success
-- and failure the same way.
function setStatus(text, isError)
  if not gameStoreWindow then
    return
  end

  local label = find("statusLine")
  label:setText(text or "")
  label:setColor(isError and COLOR_URGENT or COLOR_POSITIVE)

  if statusEvent then
    removeEvent(statusEvent)
    statusEvent = nil
  end

  if text and text ~= "" then
    statusEvent = scheduleEvent(function()
      statusEvent = nil
      if gameStoreWindow then
        find("statusLine"):setText("")
      end
    end, 6000)
  end
end

function clearStatus()
  setStatus("")
end

-- ─── protocol ──────────────────────────────────────────────────────────────

function requestCatalog()
  local protocolGame = g_game.getProtocolGame()
  if not protocolGame then
    return
  end

  local msg = OutputMessage.create()
  msg:addU8(OPCODE_STORE_OPEN)
  protocolGame:send(msg)
end

function requestHistory()
  local protocolGame = g_game.getProtocolGame()
  if not protocolGame then
    return
  end

  local msg = OutputMessage.create()
  msg:addU8(OPCODE_STORE_HISTORY)
  protocolGame:send(msg)
end

function requestBuy(offerId, newName)
  local protocolGame = g_game.getProtocolGame()
  if not protocolGame then
    return
  end

  local msg = OutputMessage.create()
  msg:addU8(OPCODE_STORE_BUY)
  msg:addU32(offerId)
  if newName then
    msg:addString(newName)
  end
  protocolGame:send(msg)
end

function requestTransfer(target, amount)
  local protocolGame = g_game.getProtocolGame()
  if not protocolGame then
    return
  end

  local msg = OutputMessage.create()
  msg:addU8(OPCODE_STORE_TRANSFER)
  msg:addString(target)
  msg:addU32(amount)
  protocolGame:send(msg)
end

-- ─── the virtual grid ──────────────────────────────────────────────────────

-- Rows that fit on screen, plus the overscan. Read off the live panel rather
-- than derived from the window size, with a fallback for the one moment the
-- panel has no height yet -- a zero here would build a pool of two rows.
local function poolRowsNeeded(list)
  local height = list:getHeight()
  if height <= 0 then
    height = 420
  end
  return math.ceil(height / ROW_PITCH) + OVERSCAN_ROWS
end

local function fillCard(card, offer)
  setOfferVisual(card:getChildById("art"), offer)
  card:getChildById("name"):setText(offerLabel(offer))
  card:getChildById("price"):setText(priceLabel(offer))
  card:setChecked(offer.offerId == selectedOfferId)
end

-- Grows or shrinks the pool.
--
-- (!) Cards are only ever appended to, or destroyed from, the TAIL.
-- UIGridLayout assigns cells in parent child-list order, so a card's position
-- in `pool` IS its cell; inserting in the middle would renumber every slot
-- after it.
local function resizePool(list, rows)
  local wanted = rows * CARD_COLS

  while #pool > wanted do
    local card = table.remove(pool)
    card:destroy()
  end

  while #pool < wanted do
    local card = g_ui.createWidget("StoreCard", list)
    card.boundId = nil
    card.slotShown = true
    card.onClick = function(self)
      if self.boundId then
        selectOffer(self.boundId)
      end
    end
    -- Double click buys what you just selected. The confirmation still stands
    -- in front of the purchase, so this is a shortcut rather than a hazard.
    card.onDoubleClick = function(self)
      if self.boundId then
        selectOffer(self.boundId)
        onOfferBuy(self.boundId)
      end
      return true
    end
    pool[#pool + 1] = card
  end
end

-- Points every pooled card at the offer belonging to its slot, and refills it
-- only when that actually changed. Scrolling one row past a card leaves the
-- rest untouched -- seven fillCard calls per row crossed, not 173.
local function bindPool(firstRow, force)
  local base = firstRow * CARD_COLS

  for slot = 1, #pool do
    local card = pool[slot]
    local offer = visible[base + slot]
    local shown = offer ~= nil

    if shown then
      if force or card.boundId ~= offer.offerId then
        card.boundId = offer.offerId
        fillCard(card, offer)
      else
        card:setChecked(offer.offerId == selectedOfferId)
      end
    else
      card.boundId = nil
    end

    -- (!) Hidden, never destroyed -- and only touched when the flag actually
    -- flips, because setVisible runs a layout pass. UIGridLayout skips
    -- invisible children without consuming a cell, so trailing blanks cost
    -- nothing and leave the filled slots exactly where they are, which is what
    -- a short final row needs.
    if card.slotShown ~= shown then
      card.slotShown = shown
      card:setVisible(shown)
    end
  end
end

-- Applies a scroll position. Whole rows change which offers are bound; the
-- remainder is a pixel offset the grid layout applies to the pool as a whole.
local function applyScroll()
  local list = find("cardList")
  if not list then
    return
  end

  local row = math.floor(scrollValue / ROW_PITCH)
  local offset = scrollValue - row * ROW_PITCH

  if row ~= poolFirstRow then
    poolFirstRow = row
    bindPool(row, false)
  end

  -- (!) This is what lets the stock grid layout drive a virtual list. The cards
  -- keep cell indices 0..n forever and the panel's virtual offset is what
  -- slides them, so the offset only ever has to cover one row of travel.
  list:setVirtualOffset({ x = 0, y = offset })
end

-- The scrollbar is driven by hand rather than by ScrollablePanel, which sizes
-- its range from getChildrenRect -- and getChildrenRect now describes the pool,
-- which is one screenful. The range has to describe the whole list.
local function updateScrollRange(list, bar)
  local rows = math.ceil(#visible / CARD_COLS)
  local content = rows > 0 and (rows * ROW_PITCH - CARD_SPACING) or 0
  local maxScroll = math.max(0, content - math.max(list:getHeight(), 0))

  -- setMaximum clamps the current value and fires onValueChange when it does;
  -- the guard keeps that from re-entering applyScroll mid-rebuild.
  suppressScrollEvent = true
  bar:setMinimum(0)
  bar:setMaximum(maxScroll)
  suppressScrollEvent = false

  if scrollValue > maxScroll then
    scrollValue = maxScroll
  end
end

function drawCards(keepScroll)
  if not gameStoreWindow then
    return
  end

  local list = find("cardList")
  local bar = find("cardScroll")
  if not list or not bar then
    return
  end

  local notice = find("emptyNotice")
  if #visible == 0 then
    notice:setText(searchQuery and
      ("Nothing in the store matches \"" .. searchQuery .. "\".") or
      "Nothing on sale in this section.")
    notice:show()
  else
    notice:hide()
  end

  find("shownCount"):setText(#visible == 1 and "1 offer" or (comma_value(#visible) .. " offers"))

  resizePool(list, poolRowsNeeded(list))

  if not keepScroll then
    scrollValue = 0
  end
  updateScrollRange(list, bar)
  suppressScrollEvent = true
  bar:setValue(scrollValue)
  suppressScrollEvent = false

  -- force: the pool still holds the previous section's cards, and an unchanged
  -- offer id is no promise that its price or its artwork did not move.
  poolFirstRow = math.floor(scrollValue / ROW_PITCH)
  bindPool(poolFirstRow, true)
  list:setVirtualOffset({ x = 0, y = scrollValue - poolFirstRow * ROW_PITCH })
end

-- ─── the action bar ────────────────────────────────────────────────────────

function updateActionBar()
  if not gameStoreWindow then
    return
  end

  local art = find("actionBar"):getChildById("art")
  local nameLabel = find("actionName")
  local descLabel = find("actionDesc")
  local price = find("actionPrice")
  local coin = find("actionCoin")
  local buy = find("buyButton")

  local offer = selectedOfferId and offerById[selectedOfferId]

  if not offer then
    -- Nothing selected: the bar states the section you are in and what that
    -- section does. This is where the category description went, and it is what
    -- keeps the bar from ever being dead space.
    hideArt(art)

    if searchQuery then
      nameLabel:setText("Search results")
      descLabel:setText("Every offer whose name contains \"" .. searchQuery ..
        "\". Pick a category tab to leave the search.")
    else
      local category = activeLeaf and categories[activeLeaf]
      nameLabel:setText(category and category.title or "")
      descLabel:setText(category and category.description ~= "" and category.description or
        "Pick an offer to see what it does and what it costs.")
    end

    price:hide()
    coin:hide()
    buy:hide()
    return
  end

  setOfferVisual(art, offer)

  local info = kindInfo(offer)
  nameLabel:setText(offerLabel(offer))
  descLabel:setText(info.kind .. "  -  " .. info.where .. "\n" .. offerDescription(offer))

  local affordable = offer.price <= premiumPoints
  price:setText(comma_value(offer.price) .. " " .. CURRENCY)
  price:setEnabled(affordable)
  price:show()
  coin:show()

  buy:setText(offer.count > 1 and offer.oftype == "item" and
    ("Buy " .. comma_value(offer.count)) or "Buy")
  buy:setEnabled(affordable)
  buy:show()
end

function selectOffer(offerId)
  selectedOfferId = offerId
  for _, card in ipairs(pool) do
    card:setChecked(card.boundId ~= nil and card.boundId == offerId)
  end
  updateActionBar()
end

-- ─── navigation ────────────────────────────────────────────────────────────

local function setView(name)
  view = name
  find("homePanel"):setVisible(name == "home")
  find("browsePanel"):setVisible(name == "browse")
  find("sectionPanel"):setVisible(name == "sections")
  find("historyPanel"):setVisible(name == "history")

  -- The context bar carries the sub-tab strip, the offer count and the search
  -- box. A section page has no sub-tabs but keeps the other two: the count is
  -- still worth stating, and search is the one way out of a page into the rest
  -- of the catalogue.
  find("contextBar"):setVisible(name == "browse" or name == "sections")
  find("historyButton"):setChecked(name == "history")
end

-- Fits a strip of tabs or chips to whatever the server sent.
--
-- Widths come from each button's own text, because a fixed width either wastes
-- the strip on "Houses" or clips "Prey Wildcards". If the natural total does
-- not fit, the padding shrinks first (it is the cheapest thing to lose) and
-- only then are the widths scaled, which is the point where text starts to
-- clip -- eleven top-level categories plus Home is already close to the limit
-- of one row at this font.
-- Points a tab or chip at its category's 13x13 icon.
--
-- (!) setIconClip only, never setIconSize -- setIconSize writes m_iconRect and
-- drawIcon then takes that branch and skips alignIn entirely, which would drag
-- the icon into the widget's top-left corner regardless of icon-align
-- (uiwidgetbasestyle.cpp:709). The clip is what gives the icon its size.
local function applyTabIcon(button, iconName)
  if iconName == HOME_ICON then
    button:setIcon(HOME_ICON)
    button:setIconClip("0 0 13 13")
    return
  end

  local index = categoryIconClips[iconName] or 0
  button:setIcon(CATEGORY_ICON_SHEET)
  button:setIconClip(index * 13 .. " 0 13 13")
end

-- Writes the four landing-screen headings into the StoreSectionHead templates.
-- Called once, from create(), because the headings are fixed -- unlike the tab
-- strip, which is whatever the server sent.
local function applySectionHeads()
  for id, section in pairs(SECTION_HEADS) do
    local head = find(id)
    if head then
      head:getChildById("title"):setText(tr(section.text))
      head:getChildById("note"):setText(tr(section.note))
    end
  end
end

-- Fits a strip of tabs or chips to whatever the server sent.
--
-- Widths come from each button's own text plus the fixed lead its icon needs,
-- because a uniform width either wastes the strip on "Houses" or clips
-- "Quality of Life". If the natural total does not fit, the padding shrinks
-- first (it is the cheapest thing to lose) and only then are the widths scaled,
-- which is the point where text starts to clip.
local function layoutStrip(bar, specs, style, spacing, padding, lead, stripWidth, onClick)
  bar:destroyChildren()
  if #specs == 0 then
    return
  end

  local buttons = {}
  local textWidths = {}
  local textTotal = 0

  for i, spec in ipairs(specs) do
    local button = g_ui.createWidget(style, bar)
    button:setText(spec.text)
    button.storeKey = spec.key
    button.onClick = function()
      onClick(spec.key)
    end
    if spec.icon then
      applyTabIcon(button, spec.icon)
    end
    buttons[i] = button
    textWidths[i] = button:getTextSize().width + (spec.icon and lead or 0)
    textTotal = textTotal + textWidths[i]
  end

  local available = stripWidth - spacing * (#specs - 1)
  local pad = padding
  if textTotal + 2 * pad * #specs > available then
    pad = math.max(4, math.floor((available - textTotal) / (2 * #specs)))
  end

  local natural = textTotal + 2 * pad * #specs
  local scale = (natural > available and natural > 0) and (available / natural) or 1

  for i, button in ipairs(buttons) do
    button:setWidth(math.max(24, math.floor((textWidths[i] + 2 * pad) * scale)))
  end
end

local function buildSubTabs()
  local bar = find("subTabs")

  if searchQuery then
    layoutStrip(bar, { { key = "clear", text = "Search: " .. searchQuery .. "    x" } },
      "StoreSubTab", 4, 10, SUBTAB_ICON_LEAD, SUBTAB_STRIP_WIDTH, clearSearch)
    local chip = bar:getFirstChild()
    if chip then
      chip:setChecked(true)
    end
    return
  end

  -- A section page has children in the catalogue and deliberately shows none
  -- of them as chips -- they are headings on the page instead. See
  -- isSectionPage.
  local children = activeTop and childOrder[activeTop]
  if not children or #children == 0 or isSectionPage(activeTop) then
    bar:destroyChildren()
    return
  end

  local specs = {}
  for _, title in ipairs(children) do
    specs[#specs + 1] = { key = title, text = title, icon = categories[title].icon }
  end

  layoutStrip(bar, specs, "StoreSubTab", 4, 10, SUBTAB_ICON_LEAD, SUBTAB_STRIP_WIDTH, selectLeaf)

  for _, button in ipairs(bar:getChildren()) do
    button:setChecked(button.storeKey == activeLeaf)
  end
end

function selectLeaf(title)
  activeLeaf = title
  selectedOfferId = nil
  visible = offersByCat[title] or {}

  setView("browse")
  buildSubTabs()
  drawCards(false)
  updateActionBar()
end

function selectTab(key)
  for _, button in ipairs(find("tabBar"):getChildren()) do
    button:setChecked(button.storeKey == key)
  end

  searchQuery = nil
  find("searchTextEdit"):setText("")

  if key == HOME_KEY then
    activeTop = nil
    activeLeaf = nil
    setView("home")
    drawHome()
    return
  end

  activeTop = key
  local children = childOrder[key]

  -- A section page shows every child at once, so there is no leaf to open --
  -- activeLeaf is the tab itself, which is what the action bar and the restore
  -- after a purchase both read.
  if isSectionPage(key) then
    activeLeaf = key
    selectedOfferId = nil
    visible = sectionOffers(key)
    setView("sections")
    buildSubTabs()
    drawSections(key)
    return
  end

  selectLeaf(children and #children > 0 and children[1] or key)
end

-- Jumps straight to a leaf, checking its parent tab on the way. Used by the
-- landing screen's index tiles, which are the only place in the window where
-- every sub-category is visible at once.
function gotoLeaf(title)
  local category = categories[title]
  if not category then
    return
  end

  selectTab(category.parent or title)

  -- (!) Not for a child of a SECTION PAGE. selectTab has already opened that
  -- tab whole and the child is a heading on it, so selecting the child would
  -- swap the page for a flat grid of one slice, with no chip on screen to say
  -- why or any way back -- there is no sub-tab strip in that view. Reached
  -- from search results and from the restore after a purchase.
  if category.parent and not isSectionPage(category.parent) then
    selectLeaf(title)
  end
end

local function buildTabs()
  local specs = { { key = HOME_KEY, text = "Home", icon = HOME_ICON } }
  for _, title in ipairs(topOrder) do
    if not isFullyPromoted(title) then
      specs[#specs + 1] = { key = title, text = title, icon = categories[title].icon }
    end
  end

  layoutStrip(find("tabBar"), specs, "StoreTabButton", 3, 12, TAB_ICON_LEAD,
    TAB_STRIP_WIDTH, selectTab)
end

-- ─── the landing screen ────────────────────────────────────────────────────

-- A showcase tile: artwork in a slot, name, price, and the whole tile is the
-- button. No separate Buy control -- the purchase confirmation is still what
-- actually asks before spending, so a click here is safe and the tile stays
-- small.

-- ─── boost headlines ───────────────────────────────────────────────────────
--
-- A boost tile is 142px wide with 126px of usable text, and the server's
-- descriptions are full sentences: "Boosts experience by 50% for 30 minutes."
-- is 40 characters, about 235px, and it needed two wrapped lines and a 68px
-- tile to hold them.
--
-- It does not need to. The tile's cap bar already says WHICH boost this is, so
-- the line under it only has to say how much and for how long. That is
-- derivable from the same sentence, fits one line at any tile width, and reads
-- better than the sentence did:
--
--   "Boosts experience by 50% for 30 minutes."   ->  "+50% for 30 min"
--   "Boosts movement speed by 60 for 30 minutes." ->  "+60 for 30 min"
--   "Doubles health and mana regen for 30 min..." ->  "Doubled for 30 min"
--
-- (!) Derivation only, never invention -- the magnitude and the duration both
-- come out of the server's own text, so a price or duration change on the
-- server is reflected here with no client edit. A description this cannot read
-- falls back to the raw sentence, which clips: the label is one unwrapped line
-- by design, and a boost whose wording changes shape should look wrong rather
-- than quietly claim the wrong number.
local function boostHeadline(offer)
  local text = offerDescription(offer) or ""
  if text == "" then
    return ""
  end

  local magnitude = text:match("(%d+)%%")
  if magnitude then
    magnitude = "+" .. magnitude .. "%"
  else
    local flat = text:match("[Bb]y (%d+)")
    if flat then
      magnitude = "+" .. flat
    elseif text:match("[Dd]oubles") then
      magnitude = "Doubled"
    end
  end

  local amount, unit = text:match("(%d+)%s+(minute)s?")
  if not amount then
    amount, unit = text:match("(%d+)%s+(hour)s?")
  end
  if not amount then
    amount, unit = text:match("(%d+)%s+(day)s?")
  end

  local duration
  if amount then
    duration = amount .. " " .. ({ minute = "min", hour = "h", day = "d" })[unit]
  end

  if magnitude and duration then
    return magnitude .. " for " .. duration
  end
  return magnitude or duration or text
end

-- The name a boost's painted cap carries.
--
-- Every one of them is "<Something> Boost", and the band heading two lines
-- above already says SERVER BOOSTS -- so the suffix is a word repeated seven
-- times that buys nothing and costs a clip: "Regeneration Boost" is 126px of
-- Verdana Bold-11px in a cap bar with 124px of room. Trimmed here and here
-- only; the action bar, the confirmation and the history ledger all keep the
-- offer's full name.
local function boostCapLabel(offer)
  local name = offerLabel(offer)
  return (name:gsub("%s+Boost$", ""))
end

-- The name a Premium Time price point carries inside the spotlight.
--
-- The slab's own heading already says "Premium Time" in 18px outlined type
-- directly above the four tiles, so repeating it on each of them four more
-- times is noise -- and "30 Days of Premium Time" wraps to two lines in a 52px
-- tile where "30 Days" does not. The full name survives everywhere it is the
-- only label: the confirmation, the action bar, the history ledger.
local function premiumOfferLabel(offer)
  local name = offerLabel(offer)
  return (name:gsub("%s+of Premium Time$", ""))
end

-- Builds one landing-screen tile. Three templates share this, and they differ
-- in which children they have -- which is why each lookup below is guarded
-- rather than assumed:
--
--   StoreMiniTile      art slot, name, price          (the QoL shortlist)
--   StoreBoostTile     painted accent cap, headline, price -- NO art
--   StorePremiumOffer  name and price on marble       -- NO art, NO accent
--
-- (!) `getChildById` returns nil rather than raising, so an unguarded
-- `setOfferVisual(tile:getChildById("art"), offer)` on a template without an
-- art slot is a nil-index one frame later, inside the draw, with a stack that
-- points at setOfferVisual rather than at the caller that chose the template.
local function buildTile(parent, offer, style)
  local tile = g_ui.createWidget(style or "StoreMiniTile", parent)

  local label
  if style == "StoreBoostTile" then
    label = boostCapLabel(offer)
  elseif style == "StorePremiumOffer" then
    label = premiumOfferLabel(offer)
  else
    label = offerLabel(offer)
  end
  tile:getChildById("name"):setText(label)

  local art = tile:getChildById("art")
  if art then
    setOfferVisual(art, offer)
  end

  local description = tile:getChildById("description")
  if description then
    description:setText(boostHeadline(offer))
  end

  local accent = tile:getChildById("accent")
  if accent then
    accent:setBackgroundColor(BOOST_ACCENT)
  end

  tile:getChildById("price"):setText(priceLabel(offer))
  tile.onClick = function()
    onOfferBuy(offer.offerId)
  end
  return tile
end

-- A grid inside an anchored panel has no intrinsic height, so the row's height
-- is computed from the number of tiles it was given.
--
-- Spacing is a parameter because the three grids do not share one: the boost
-- row spends 9px between columns to make three 142px tiles reach 444, and the
-- other two spend 8.
local function sizeTileRow(row, count, columns, tileHeight, spacing)
  tileHeight = tileHeight or TILE_HEIGHT
  spacing = spacing or TILE_SPACING
  local rows = count > 0 and math.ceil(count / columns) or 0
  row:setHeight(rows > 0 and (rows * tileHeight + (rows - 1) * spacing) or 0)
end

-- Fills the Featured spotlight: hero artwork, title, blurb.
--
-- The hero is the artwork of the DEAREST premium offer, not the first one --
-- the four crown PNGs get progressively grander with the term, so the 360-day
-- crown is the one that earns an 80px slot. Picked by price rather than by
-- position so a reordered catalogue cannot quietly demote it.
--
-- (!) No slot behind it. Everywhere else in this window artwork sits in the
-- client's recessed inventory frame, but that frame is dark, and punching a
-- dark hole in the plaque's face reads as damage rather than as a slot.
--
-- (!) Everything on the plaque hangs off `face`, not off the plaque itself --
-- the plaque is the gold bevel and `face` is the cream panel inset into it, and
-- getChildById is not recursive. spotlightFace() is the one place that walks
-- that step, so nothing else has to remember it.
local function spotlightFace()
  local spotlight = find("spotlight")
  return spotlight and spotlight:getChildById("face") or nil
end

local function drawSpotlight(premium)
  local spotlight = find("spotlight")
  local face = spotlightFace()
  local head = find("premiumCap")
  if not spotlight or not face or not head then
    return
  end

  local shown = #premium > 0
  spotlight:setVisible(shown)
  head:setVisible(shown)
  if not shown then
    return
  end

  local hero = premium[1]
  for _, offer in ipairs(premium) do
    if offer.price > hero.price then
      hero = offer
    end
  end

  local art = face:getChildById("art")
  local source = getStoreImage(hero.icon)
  art:setVisible(source ~= nil)
  if source then
    art:setImageSource(source)
  end

  face:getChildById("title"):setText(tr(SPOTLIGHT_TITLE))

  -- Prefer the server's own words for the category the premium offers live in,
  -- so a catalogue edit reaches the landing screen with no client change.
  local category = categories[hero.categoryTitle]
  local blurb = category and category.description or ""
  if blurb == "" then
    blurb = SPOTLIGHT_BLURB
  end
  face:getChildById("blurb"):setText(blurb)
end

function drawHome()
  if not gameStoreWindow then
    return
  end

  -- Walked in catalogue order so the rows follow the order the server declares
  -- rather than pairs() iteration order, which is not stable.
  local premium, boosts = {}, {}
  for _, title in ipairs(topOrder) do
    for _, offer in ipairs(sectionOffers(title)) do
      if HOME_PREMIUM_TYPES[offer.oftype] then
        premium[#premium + 1] = offer
      elseif HOME_BOOST_TYPES[offer.oftype] then
        boosts[#boosts + 1] = offer
      end
    end
  end

  -- Shortlists are by id, so an offer the server has dropped is skipped rather
  -- than erroring: the landing screen degrades to fewer tiles, not to a stack
  -- trace.
  local function shortlist(ids)
    local out = {}
    for _, id in ipairs(ids) do
      if offerById[id] then
        out[#out + 1] = offerById[id]
      end
    end
    return out
  end

  local picks = shortlist(HOME_QOL)

  local premiumOffers = spotlightFace():getChildById("offers")
  premiumOffers:destroyChildren()
  for _, offer in ipairs(premium) do
    buildTile(premiumOffers, offer, "StorePremiumOffer")
  end
  sizeTileRow(premiumOffers, #premium, PREMIUM_COLS, PREMIUM_TILE_HEIGHT)
  drawSpotlight(premium)

  local boostRow = find("boostRow")
  boostRow:destroyChildren()
  for _, offer in ipairs(boosts) do
    buildTile(boostRow, offer, "StoreBoostTile")
  end
  sizeTileRow(boostRow, #boosts, BOOST_COLS, BOOST_TILE_HEIGHT, BOOST_SPACING)
  find("boostCap"):setVisible(#boosts > 0)
  boostRow:setVisible(#boosts > 0)

  local pickRow = find("pickRow")
  pickRow:destroyChildren()
  for _, offer in ipairs(picks) do
    buildTile(pickRow, offer)
  end
  sizeTileRow(pickRow, #picks, TILE_COLS)
  find("pickCap"):setVisible(#picks > 0)

  -- ── section arithmetic ──────────────────────────────────────────────────
  --
  -- Walk down the showcase exactly the way the anchor chain in game_store.otui
  -- does. Keep the two in step, or the sections drift -- and on a fixed window
  -- that means tiles sliding under the footer with nothing to say so, because
  -- a Panel does not clip. There is no visual tell but a missing edge.
  --
  -- Three sections in the Bazaar's rhythm, each a 30px head then its goods,
  -- separated by 12px of air and nothing else:
  --
  --   head 30, spotlight 140                     Featured
  --   gap 12, head 30, boostRow 66               Server Boosts
  --   gap 12, head 30, pickRow 152               Quality of Life (2 rows)
  --
  -- With today's catalogue: 170 + 108 + 194 = 472 in 513.
  --
  -- Simpler than the version it replaced, and not by accident: that one had to
  -- carry a max() over two side-by-side columns because Premium Time and the
  -- boosts shared a band. Giving Premium Time the spotlight made the whole
  -- landing screen one straight column.
  local HEAD = 30
  local SECTION_GAP = 12

  local height = HEAD + find("spotlight"):getHeight()

  for _, section in ipairs({
    { count = #boosts, row = boostRow },
    { count = #picks, row = pickRow },
  }) do
    if section.count > 0 then
      height = height + SECTION_GAP + HEAD + section.row:getHeight()
    end
  end

  find("showcase"):setHeight(height)

  -- Hand-kept arithmetic checked against a hand-kept anchor chain. If the two
  -- ever drift, tiles slide off the bottom edge of a fixed window and nothing
  -- says so, which is the kind of bug that survives a screenshot review.
  if height > HOME_PANEL_HEIGHT then
    g_logger.warning(string.format(
      "game_store: landing screen wants %dpx, the window gives it %d",
      height, HOME_PANEL_HEIGHT))
  end
end

-- ─── section pages ─────────────────────────────────────────────────────────
--
-- Account, Quality of Life and Backpacks: every sub-category on one scrolling
-- page, each under its own heading, with no sub-tab strip. isSectionPage says
-- which tabs qualify and why.
--
-- Built fresh on every tab change rather than pooled the way the browse grid
-- is. That is affordable here and only here -- SECTION_PAGE_MAX caps a page at
-- 48 tiles, where the browse grid has to survive House's 317 and pays for it
-- with the whole pool machinery.
--
-- No action bar and no selection on this view. The tile carries the artwork,
-- the name, what the offer does and the price -- everything the action bar was
-- there to reveal on click -- so the click can go straight to the purchase
-- confirmation, which is still the thing that actually asks before spending.

-- A section-page tile. Also builds StoreCompactTile, which is the same tile
-- without a description slot.
local function buildOfferTile(parent, offer, style)
  local tile = g_ui.createWidget(style or "StoreOfferTile", parent)

  setOfferVisual(tile:getChildById("art"), offer)
  tile:getChildById("name"):setText(offerLabel(offer))
  tile:getChildById("price"):setText(priceLabel(offer))

  -- Guarded: StoreCompactTile deliberately has none. getChildById returns nil
  -- rather than raising, so the unguarded version of this line is a nil index
  -- one frame later, inside the draw.
  local description = tile:getChildById("description")
  if description then
    description:setText(offerDescription(offer))
  end

  tile.onClick = function()
    onOfferBuy(offer.offerId)
  end
  return tile
end

-- The bundle among a set of blessing offers: the one that grants more than one.
-- `count` is 5 for "All regular Blessings" and 1 for every single.
--
-- (!) Read off the wire, not matched by name. The name is a catalogue string
-- that something outside this repository regenerates; the count is what the
-- server actually grants.
local function blessingBundle(offers)
  local bundle = nil
  for _, offer in ipairs(offers) do
    if offer.count > 1 and (not bundle or offer.count > bundle.count) then
      bundle = offer
    end
  end
  return bundle
end

-- How a section's goods are laid out. Three shapes, picked from the offers
-- themselves rather than from a list of section names, so the catalogue can
-- move without the client following it.
--
--   ONE offer          full width. Half a row of nothing beside a lone tile
--                      reads as a section that failed to load.
--
--   ONE description    the compact tile, three across, description dropped.
--   shared by all      Ten Cosmetic backpacks each repeating "Twenty slots and
--                      one imbuement slot..." is the same sentence ten times
--                      and no information per tile -- the fact belongs to the
--                      section, which is what SECTION_NOTES is for. Exactly
--                      the argument StoreCompactTile already makes about the
--                      five blessings.
--
--   otherwise          the rich tile, two across.
local function sectionLayout(offers)
  if #offers == 1 then
    return { row = "StoreOfferRowWide", tile = "StoreOfferTile", columns = 1,
             height = SECTION_TILE_HEIGHT }
  end

  local shared = offerDescription(offers[1])
  for _, offer in ipairs(offers) do
    if offerDescription(offer) ~= shared then
      return { row = "StoreOfferRow", tile = "StoreOfferTile",
               columns = SECTION_TILE_COLS, height = SECTION_TILE_HEIGHT }
    end
  end

  return { row = "StoreCompactRow", tile = "StoreCompactTile", columns = 3,
           height = BLESSING_TILE_HEIGHT }
end

local function isBlessingSection(offers)
  if #offers == 0 then
    return false
  end
  for _, offer in ipairs(offers) do
    if offer.oftype ~= "blessing" then
      return false
    end
  end
  return blessingBundle(offers) ~= nil
end

-- The blessings band: the singles on the left, the bundle plaque standing full
-- height on the right.
--
-- The plaque earns the space with arithmetic rather than with decoration. The
-- five singles add up to more than the bundle costs and the blurb says by how
-- much -- both numbers taken from the catalogue, so a price change on the
-- server reaches the plaque with no client edit, and if the sum ever stops
-- being a saving the line is dropped rather than left claiming something that
-- is no longer true.
local function buildBlessingBand(parent, offers)
  local band = g_ui.createWidget("StoreBlessingBand", parent)
  local bundle = blessingBundle(offers)

  local singles = band:getChildById("singles")
  local singleCount, singleTotal = 0, 0
  for _, offer in ipairs(offers) do
    if offer ~= bundle then
      buildOfferTile(singles, offer, "StoreCompactTile")
      singleCount = singleCount + 1
      singleTotal = singleTotal + offer.price
    end
  end
  sizeTileRow(singles, singleCount, BLESSING_TILE_COLS, BLESSING_TILE_HEIGHT,
    BLESSING_TILE_SPACING)

  -- (!) Everything on the plaque hangs off `face`, not off the plaque itself --
  -- the plaque is the gold bevel and `face` is the cream panel inset into it.
  -- getChildById is not recursive. Same shape as StoreSpotlight.
  local hero = band:getChildById("hero")
  local face = hero:getChildById("face")

  local art = face:getChildById("art")
  local source = getStoreImage(bundle.icon)
  art:setVisible(source ~= nil)
  if source then
    art:setImageSource(source)
  end

  face:getChildById("title"):setText(tr("All Blessings"))
  face:getChildById("price"):setText(priceLabel(bundle))

  local blurb = "Every regular blessing you are still missing, in one purchase."
  if singleTotal > bundle.price then
    blurb = blurb .. "  Bought one at a time they come to " ..
      comma_value(singleTotal) .. " " .. CURRENCY .. "."
  end
  face:getChildById("blurb"):setText(blurb)

  hero.onClick = function()
    onOfferBuy(bundle.offerId)
  end

  -- The band is as tall as the taller half. A sixth single would push the grid
  -- past the plaque's 244, so the plaque follows rather than being left short.
  local height = math.max(BLESSING_BAND_HEIGHT, singles:getHeight())
  band:setHeight(height)
  hero:setHeight(height)
  return band
end

function drawSections(title)
  if not gameStoreWindow then
    return
  end

  local list = find("sectionList")
  local bar = find("sectionScroll")
  if not list or not bar then
    return
  end

  list:destroyChildren()

  local total = 0
  local first = true

  for _, leaf in ipairs(childOrder[title] or {}) do
    local offers = offersByCat[leaf] or {}
    if #offers > 0 then
      local head = g_ui.createWidget("StoreSectionHead", list)
      head:getChildById("title"):setText(leaf)
      head:getChildById("note"):setText(SECTION_NOTES[leaf] or "")

      -- 12px of air between sections and none above the first -- the landing
      -- screen's rhythm. Set from here rather than as a margin on the style
      -- because only the gaps BETWEEN sections exist.
      head:setMarginTop(first and 0 or SECTION_GAP)
      first = false

      if isBlessingSection(offers) then
        buildBlessingBand(list, offers)
      else
        local layout = sectionLayout(offers)
        local row = g_ui.createWidget(layout.row, list)
        for _, offer in ipairs(offers) do
          buildOfferTile(row, offer, layout.tile)
        end
        sizeTileRow(row, #offers, layout.columns, layout.height, SECTION_TILE_SPACING)
      end

      total = total + #offers
    end
  end

  -- Every section on this page was empty. It cannot happen with today's
  -- catalogue -- the server drops a category its own filters emptied -- but a
  -- page with nothing on it and nothing to say is worse than the sentence.
  if total == 0 then
    local notice = g_ui.createWidget("Label", list)
    notice:setHeight(80)
    notice:setTextAlign(AlignCenter)
    notice:setText("Nothing on sale in this section.")
    notice:setColor("#9a9a9a")
    notice:setFont("verdana-11px-monochrome")
  end

  find("shownCount"):setText(total == 1 and "1 offer" or (comma_value(total) .. " offers"))

  -- (!) Both, not just the bar. A new page always opens at its top, and
  -- setValue only moves the panel by firing onValueChange -- which it does not
  -- do when the value is already what it is being set to. Land on a page with
  -- the bar reading 0 and a stale virtual offset and the top of the page is
  -- scrolled away with no thumb position to explain it.
  bar:setValue(0)
  list:setVirtualOffset({ x = 0, y = 0 })
end

-- ─── search ────────────────────────────────────────────────────────────────

-- The window Enter key. With the confirmation up, Enter belongs to the
-- confirmation -- running a search behind a modal prompt would be nonsense.
function onWindowEnter()
  if not gameStoreWindow then
    return
  end
  if find("confirmOverlay"):isVisible() then
    onConfirmAccept()
    return
  end
  onSearch()
end

function onTypeSearch(self)
  find("searchButton"):setEnabled(#self:getText() > 2)
end

function clearSearch()
  searchQuery = nil
  find("searchTextEdit"):setText("")
  selectTab(activeTop or HOME_KEY)
end

function onSearch()
  if not gameStoreWindow or view == "history" then
    return
  end

  local field = find("searchTextEdit")
  local typed = trim(field:getText())
  if #typed < 3 then
    return
  end

  local needle = typed:lower()
  searchQuery = typed
  activeLeaf = nil
  selectedOfferId = nil

  -- Walked in catalogue order, so results stay grouped by the section they came
  -- from rather than arriving as a flat alphabetical mix.
  visible = {}
  for _, title in ipairs(topOrder) do
    local leaves = childOrder[title]
    if not leaves or #leaves == 0 then
      leaves = { title }
    end
    for _, leaf in ipairs(leaves) do
      for _, offer in ipairs(offersByCat[leaf] or {}) do
        if offer.name:lower():find(needle, 1, true) then
          visible[#visible + 1] = offer
        end
      end
    end
  end

  for _, button in ipairs(find("tabBar"):getChildren()) do
    button:setChecked(false)
  end

  setView("browse")
  buildSubTabs()
  drawCards(false)
  updateActionBar()
end

-- ─── catalogue ─────────────────────────────────────────────────────────────

function onStoreMessage(protocol, msg)
  local response = msg:getU8()
  if response == RESP_CATALOG then
    parseCatalog(msg)
  elseif response == RESP_SUCCESS then
    parseSuccess(msg)
  elseif response == RESP_HISTORY then
    parseHistory(msg)
  elseif response == RESP_ERROR then
    parseError(msg)
  end
end

function parseCatalog(msg)
  premiumPoints = msg:getU32()
  categories = {}
  offersByCat = {}
  offerById = {}
  topOrder = {}
  childOrder = {}

  local categoriesCount = msg:getU16()
  for _ = 1, categoriesCount do
    local categoryName = unescape(msg:getString())
    local categoryIcon = msg:getString()
    local parentName = msg:getString()
    local categoryDescription = unescape(msg:getString())
    if parentName == "" then
      parentName = nil
    end

    local category = {
      title = categoryName,
      parent = parentName,
      icon = categoryIcon,
      description = categoryDescription
    }

    categories[category.title] = category
    offersByCat[category.title] = {}

    if parentName then
      childOrder[parentName] = childOrder[parentName] or {}
      table.insert(childOrder[parentName], category.title)
    else
      table.insert(topOrder, category.title)
    end

    local offerCount = msg:getU16()
    for _ = 1, offerCount do
      local offer = {
        offerId = msg:getU32(),
        name = unescape(msg:getString()),
        icon = msg:getString(),
        price = msg:getU32(),
        id = msg:getU16(),
        count = msg:getU16(),
        description = unescape(msg:getString()),
        oftype = msg:getString(),
        categoryTitle = category.title
      }
      table.insert(offersByCat[category.title], offer)
      offerById[offer.offerId] = offer
    end
  end

  onGameStoreUpdatePoints({ points = premiumPoints })
  rebuildPromoted()
  buildTabs()

  -- A purchase forces a full refresh (prices and availability can both move),
  -- which rebuilds every tab from scratch. Put the player back where they were
  -- rather than on the landing screen.
  local restore = restoreState
  restoreState = nil

  if restore and restore.view == "history" then
    selectTab(HOME_KEY)
    showHistory()
    return
  end

  if restore and restore.leaf and categories[restore.leaf] then
    gotoLeaf(restore.leaf)

    if restore.offerId and offerById[restore.offerId] then
      selectOffer(restore.offerId)
    end

    -- (!) Browse only. `restore.scroll` is a position in the POOLED grid, and
    -- the tab it is being restored into may be a section page now, whose
    -- scrolling belongs to a different bar entirely -- pushing this value at
    -- cardScroll there would move a hidden panel and leave the visible page
    -- looking like it ignored the restore.
    if restore.view == "browse" and restore.scroll and restore.scroll > 0 then
      local bar = find("cardScroll")
      scrollValue = math.min(restore.scroll, bar:getMaximum())
      suppressScrollEvent = true
      bar:setValue(scrollValue)
      suppressScrollEvent = false
      poolFirstRow = -1
      applyScroll()
    end
    return
  end

  selectTab(HOME_KEY)
end

local function captureState()
  restoreState = {
    view = view,
    leaf = activeLeaf,
    offerId = selectedOfferId,
    scroll = scrollValue
  }
end

function parseSuccess(msg)
  local offerId = msg:getU32()
  local text = msg:getString()
  local newCoins = msg:getU32()

  premiumPoints = newCoins
  onGameStoreUpdatePoints({ points = newCoins })

  captureState()
  requestCatalog()
  requestHistory()

  if transferWindow then
    transferWindow:hide()
  end

  if msgWindow then
    msgWindow:destroy()
    msgWindow = nil
  end

  -- The result lands on the status line beside the buttons that caused it,
  -- rather than in a modal that had to hide the whole store to show itself.
  if gameStoreWindow and gameStoreWindow:isVisible() then
    setStatus(text, false)
  else
    displayInfoBoxWithCallback("Store Information", text, function()
      show()
    end)
  end
end

function parseHistory(msg)
  history = {}

  local count = msg:getU16()
  for _ = 1, count do
    local date = msg:getString()
    local amount = msg:getU32()
    local positive = msg:getU8()
    local isSecondPrice = msg:getU8()
    local title = msg:getString()
    local itemCount = msg:getU16()

    table.insert(history, {
      date = date,
      price = positive == 1 and amount or -amount,
      isSecondPrice = isSecondPrice == 1,
      name = title,
      count = itemCount
    })
  end

  currentPage = 1
  totalPages = math.max(1, math.ceil(#history / entriesPerPage))
  updateHistory()
end

function parseError(msg)
  local text = msg:getString()

  if msgWindow then
    msgWindow:destroy()
    msgWindow = nil
  end

  if gameStoreWindow and gameStoreWindow:isVisible() then
    setStatus(text, true)
  else
    displayInfoBoxWithCallback("Store Error", text, function()
      show()
    end)
  end
end

-- ─── history ───────────────────────────────────────────────────────────────

function updateHistory()
  if not gameStoreWindow then
    return
  end

  local list = find("historyList")
  list:destroyChildren()

  local index = ((currentPage - 1) * entriesPerPage) + 1
  for i = index, math.min(#history, index + entriesPerPage - 1) do
    local widget = g_ui.createWidget("HistoryWidget", list)
    widget:getChildById("date"):setText(history[i].date)
    widget:getChildById("price"):setText((history[i].price > 0 and "+" or "") .. comma_value(history[i].price))
    widget:getChildById("price"):setOn(history[i].price > 0)
    widget:getChildById("coin"):setOn(history[i].isSecondPrice)

    if history[i].count > 1 then
      widget:getChildById("description"):setText(history[i].count .. "x " .. history[i].name)
    else
      widget:getChildById("description"):setText(history[i].name)
    end
  end

  find("historyEmpty"):setVisible(#history == 0)
  find("pageLabel"):setVisible(#history > 0)
  find("pageLabel"):setText("Page " .. currentPage .. "/" .. totalPages)
  find("nextPageButton"):setVisible(currentPage < totalPages)
  find("prevPageButton"):setVisible(currentPage > 1)
end

function prevPage()
  if currentPage == 1 then
    return true
  end

  currentPage = currentPage - 1
  updateHistory()
end

function nextPage()
  if currentPage == totalPages then
    return true
  end

  currentPage = currentPage + 1
  updateHistory()
end

function showHistory()
  if not gameStoreWindow then
    return
  end

  setView("history")
  for _, button in ipairs(find("tabBar"):getChildren()) do
    button:setChecked(false)
  end
  requestHistory()
  updateHistory()
end

-- History is a detour, not a destination: leaving it returns to whatever you
-- were looking at rather than dropping you back on the landing screen.
function toggleHistory()
  if view ~= "history" then
    showHistory()
    return
  end

  -- (!) Read both before calling selectTab: selectTab reassigns activeLeaf to
  -- the section it lands on, so reading it afterwards would always return the
  -- FIRST sub-category rather than the one the player left.
  local top, leaf = activeTop, activeLeaf
  if top and leaf then
    selectTab(top)
    selectLeaf(leaf)
  else
    selectTab(HOME_KEY)
  end
end

-- ─── buying ────────────────────────────────────────────────────────────────

function hideConfirm()
  pendingConfirm = nil
  if gameStoreWindow then
    find("confirmOverlay"):hide()
  end
end

-- Facts are {label, value} pairs (at most two), shown apart from the prose.
-- The box is sized to its content, so a long description cannot push the
-- facts under the buttons.
function showConfirm(title, name, body, facts, acceptText, offer, callback)
  if not gameStoreWindow then
    return
  end

  local overlay = find("confirmOverlay")
  local box = overlay:getChildById("box")
  local art = box:getChildById("art")
  box:getChildById("title"):setText(title)
  box:getChildById("accept"):setText(acceptText or tr("Confirm"))

  local nameLabel = box:getChildById("name")
  local bodyLabel = box:getChildById("body")
  nameLabel:setText(name)
  bodyLabel:setText(body)

  local factsPanel = box:getChildById("facts")
  for i = 1, 2 do
    local row = factsPanel:getChildById("fact" .. i)
    local fact = facts and facts[i]
    row:setVisible(fact ~= nil)
    if fact then
      row:getChildById("label"):setText(fact[1])
      row:getChildById("value"):setText(fact[2])
    end
  end

  if offer then
    setOfferVisual(art, offer)
  else
    hideArt(art)
  end

  pendingConfirm = callback
  overlay:show()
  overlay:raise()

  -- Text height is known once the wrapped labels are laid out.
  box:updateLayout()
  local textHeight = nameLabel:getHeight() + bodyLabel:getMarginTop() + bodyLabel:getHeight()
  local overhang = math.max(0, textHeight - art:getHeight())
  factsPanel:setMarginTop(overhang + 14)
  local factsHeight = (facts and #facts > 1) and 43 or 25
  factsPanel:setHeight(factsHeight)
  box:setHeight(12 + 20 + 8 + 1 + 12 + art:getHeight() + overhang + 14 + factsHeight + 12 + 23 + 14)
end

function onOfferBuy(offerId)
  local offer = (offerId and offerById[offerId]) or (selectedOfferId and offerById[selectedOfferId])
  if not offer then
    setStatus("Pick an offer first.", true)
    return
  end

  if offer.price > premiumPoints then
    setStatus("That costs " .. comma_value(offer.price - premiumPoints) .. " " .. CURRENCY ..
      " more than you have.", true)
    return
  end

  pendingBuyOffer = offer

  -- Cost, delivery and what is left afterwards. "1,000 BPC" only answers a
  -- third of what a player is actually asking at this moment.
  showConfirm(tr("Buy for ") .. comma_value(offer.price) .. " " .. CURRENCY,
    offerLabel(offer), offerDescription(offer), {
      { "Delivery", kindInfo(offer).where },
      { "Balance after", comma_value(premiumPoints - offer.price) .. " " .. CURRENCY },
    }, tr("Buy"), offer, buyConfirmed)
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
  pendingBuyOffer = nil
end

function buyConfirmed()
  if msgWindow then
    msgWindow:destroy()
    msgWindow = nil
  end

  if not pendingBuyOffer then
    return
  end

  if pendingBuyOffer.oftype == "changename" then
    changeName()
    return
  end

  requestBuy(pendingBuyOffer.offerId)
  pendingBuyOffer = nil
end

-- ─── window lifecycle ──────────────────────────────────────────────────────

-- (!) The scroll area's own scrollbar binding is deliberately not used -- the
-- `vertical-scrollbar` tag is gone from the .otui. UIScrollArea:updateScrollBars
-- sizes the bar from getChildrenRect, which with a pooled list is one screenful,
-- so the bar would claim there is nothing to scroll. Everything the binding
-- would have given us is reproduced here against the real row count.
local function bindScrolling()
  local list = find("cardList")
  local bar = find("cardScroll")
  if not list or not bar then
    return
  end

  connect(bar, {
    onValueChange = function(_, value)
      if suppressScrollEvent then
        return
      end
      scrollValue = value
      applyScroll()
    end,
  })

  -- The wheel over the cards, handed straight to the bar so the wheel, the
  -- arrows and a thumb drag all travel at the same rate and arrive through the
  -- one onValueChange path above.
  list.onMouseWheel = function(_, _, direction)
    if not bar:isOn() then
      return false
    end
    if direction == MouseWheelUp then
      bar:decrement()
    else
      bar:increment()
    end
    return true
  end

  -- (!) Height only. This fires on every move as well as every resize, and a
  -- move changes nothing here -- reacting to it would refill the whole pool on
  -- each frame of a window drag.
  list.onGeometryChange = function(_, oldRect, newRect)
    if oldRect.height == newRect.height then
      return
    end
    resizePool(list, poolRowsNeeded(list))
    updateScrollRange(list, bar)
    poolFirstRow = -1
    applyScroll()
  end
end

function create()
  if gameStoreWindow then
    return
  end

  gameStoreWindow = g_ui.displayUI("game_store")
  gameStoreWindow:hide()

  gameStoreButton = modules.client_topmenu.addRightGameToggleButton(
    "gameStoreButton",
    tr("Store"),
    "/images/topbuttons/shop2",
    toggle,
    false,
    8
  )

  applySectionHeads()
  bindScrolling()
  createTransferWindow()
  requestCatalog()
end

function destroy()
  if statusEvent then
    removeEvent(statusEvent)
    statusEvent = nil
  end

  if msgWindow then
    msgWindow:destroy()
    msgWindow = nil
  end

  if gameStoreButton then
    gameStoreButton:destroy()
    gameStoreButton = nil
  end

  if gameStoreWindow then
    gameStoreWindow:destroy()
    gameStoreWindow = nil
  end

  if transferWindow then
    transferWindow:destroy()
    transferWindow = nil
  end

  if changeNameWindow then
    changeNameWindow:destroy()
    changeNameWindow = nil
  end

  -- The cards went with the window; the pool must not outlive them.
  pool = {}
  poolFirstRow = -1
  scrollValue = 0

  categories = {}
  offersByCat = {}
  offerById = {}
  topOrder = {}
  childOrder = {}
  history = {}
  visible = {}
  activeTop = nil
  activeLeaf = nil
  searchQuery = nil
  selectedOfferId = nil
  pendingBuyOffer = nil
  pendingConfirm = nil
  restoreState = nil
  view = "home"
end

local function ensureStoreWindow()
  if gameStoreWindow then
    return true
  end

  if not g_game.isOnline() then
    return false
  end

  create()
  return gameStoreWindow ~= nil
end

function hideTransferWindow()
  if transferWindow then
    transferWindow:hide()
  end
end

function show()
  hideTransferWindow()
  if not ensureStoreWindow() then
    return
  end

  clearStatus()
  requestCatalog()
  gameStoreWindow:show()
  gameStoreWindow:raise()
  gameStoreWindow:focus()
end

function hide()
  hideTransferWindow()
  if gameStoreWindow then
    hideConfirm()
    gameStoreWindow:hide()
  end
end

function toggle()
  if not ensureStoreWindow() then
    return
  end

  if gameStoreWindow:isVisible() then
    hide()
  else
    show()
  end
end

-- Public accessor so other modules (game_bazaar) can mirror the exact same
-- BPC balance shown here. The name is kept for those callers.
function getTibiaCoinsBalance()
  return premiumPoints
end

function onGameStoreUpdatePoints(data)
  premiumPoints = tonumber(data.points) or 0

  find("balance"):getChildById("value"):setText(comma_value(premiumPoints))

  if transferWindow then
    transferWindow:getChildById("coinsBalance"):setText(comma_value(premiumPoints) .. " " .. CURRENCY)
    transferWindow:getChildById("coinsAmountScrollbar"):setMaximum(premiumPoints)
    transferWindow:setOn(false)
  end
end

function buyPoints()
  g_platform.openUrl(DONATION_URL)
end

function displayInfoBoxWithCallback(title, message, callback)
  local messageBox
  local defaultCallback = function()
    if callback then
      callback()
    end
    messageBox:ok()
  end

  messageBox = UIMessageBox.display(title, message, {
    { text = "Ok", callback = defaultCallback }
  }, defaultCallback, defaultCallback)
  return messageBox
end

-- ─── name change ───────────────────────────────────────────────────────────

function changeName()
  if changeNameWindow then
    changeNameWindow:destroy()
    changeNameWindow = nil
  end

  changeNameWindow = g_ui.displayUI("changename")
  changeNameWindow:show()
  changeNameWindow:raise()
  changeNameWindow:focus()
end

function confirmChangeName()
  if not changeNameWindow or not pendingBuyOffer then
    return
  end

  local newName = trim(changeNameWindow:getChildById("targetName"):getText())
  requestBuy(pendingBuyOffer.offerId, newName)

  changeNameWindow:destroy()
  changeNameWindow = nil
  pendingBuyOffer = nil
end

function cancelChangeName()
  if changeNameWindow then
    changeNameWindow:destroy()
    changeNameWindow = nil
  end

  pendingBuyOffer = nil
end

-- ─── gifting ───────────────────────────────────────────────────────────────

function createTransferWindow()
  if transferWindow then
    return
  end

  transferWindow = g_ui.displayUI("giftcoins")
  transferWindow:hide()
end

-- The gift dialog sits OVER the store rather than replacing it: hiding the
-- store to show a 330px prompt meant the balance you were about to give away
-- disappeared at the moment you were deciding how much of it to give.
function toggleGiftCoins()
  if not transferWindow then
    return
  end

  setGiftStatus("")
  transferWindow:getChildById("coinsBalance"):setText(comma_value(premiumPoints) .. " " .. CURRENCY)
  transferWindow:getChildById("coinsAmountScrollbar"):setMaximum(premiumPoints)
  transferWindow:show()
  transferWindow:raise()
  transferWindow:focus()
  transferWindow:setOn(false)
end

-- The gift dialog is its own root window, so it carries its own status line for
-- the same reason the store does: a modal on top of a modal is not an answer.
function setGiftStatus(text, isError)
  if not transferWindow then
    return
  end

  local label = transferWindow:getChildById("statusLine")
  if not label then
    return
  end

  label:setText(text or "")
  label:setColor(isError and COLOR_URGENT or COLOR_POSITIVE)
end

-- The amount is both typed (coinsAmountEdit) and dragged (the slider). The
-- slider holds the number confirmGiftCoins reads; the edit mirrors it. This
-- flag stops the two from answering each other forever.
local syncingGiftAmount = false

local function setGiftAmountText(edit, text)
  if edit:getText() == text then
    return
  end

  syncingGiftAmount = true
  edit:setText(text)
  syncingGiftAmount = false
end

-- Slider moved (or was set from code): show its value in the edit. Zero shows
-- as an empty box with the "0" hint.
function changeCoinsAmount(value)
  if not transferWindow or syncingGiftAmount then
    return
  end

  value = math.floor(tonumber(value) or 0)
  setGiftAmountText(transferWindow:getChildById("coinsAmountEdit"), value > 0 and tostring(value) or "")
end

-- Typed into the edit: keep digits only, cap at the balance, move the slider.
function onGiftAmountTyped(text)
  if not transferWindow or syncingGiftAmount then
    return
  end

  local edit = transferWindow:getChildById("coinsAmountEdit")
  local digits = (text or ""):gsub("%D", "")
  local amount = tonumber(digits) or 0

  if amount > premiumPoints then
    amount = premiumPoints
  end

  setGiftAmountText(edit, amount > 0 and tostring(amount) or "")
  edit:setCursorPos(-1)

  syncingGiftAmount = true
  transferWindow:getChildById("coinsAmountScrollbar"):setValue(amount)
  syncingGiftAmount = false
end

function changeTaskPointsAmount(value)
  return true
end

function confirmGiftCoins()
  if not transferWindow then
    return
  end

  local target = trim(transferWindow:getChildById("recipient"):getText())
  local amount = tonumber(transferWindow:getChildById("coinsAmountScrollbar"):getValue()) or 0
  amount = math.floor(amount)

  if target == "" then
    setGiftStatus("Enter the name of the character receiving the coins.", true)
    return
  end

  if amount <= 0 then
    setGiftStatus("Choose an amount greater than zero.", true)
    return
  end

  -- Ask once before sending: a typo in the name sends the coins to someone
  -- else, and a transfer cannot be undone.
  local box
  local send = function()
    box:ok()
    requestTransfer(target, amount)
    if transferWindow then
      transferWindow:getChildById("recipient"):setText("")
      transferWindow:getChildById("coinsAmountScrollbar"):setValue(0)
      transferWindow:hide()
    end
  end
  local back = function()
    box:cancel()
  end
  box = UIMessageBox.display("Send Coins?",
    "Send " .. comma_value(amount) .. " " .. CURRENCY .. " to " .. target .. "?\n\n"
      .. "Check the name carefully. Coins sent to the wrong character cannot be returned.", {
      { text = "Send", callback = send },
      { text = "Back", callback = back }
    }, send, back)
end

function cancelGiftCoins()
  if transferWindow then
    transferWindow:hide()
  end
end

-- ─── module ────────────────────────────────────────────────────────────────

function init()
  connect(g_game, {
    onGameStart = create,
    onGameEnd = destroy
  })

  ProtocolGame.registerOpcode(OPCODE_STORE_SEND, onStoreMessage)

  if g_game.isOnline() then
    create()
  end

end

function terminate()
  disconnect(g_game, {
    onGameStart = create,
    onGameEnd = destroy
  })

  ProtocolGame.unregisterOpcode(OPCODE_STORE_SEND)
  destroy()
end
