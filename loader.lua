TAPPEDOUT_BASE_URL = "https://tappedout.net/mtg-decks/"
TAPPEDOUT_URL_SUFFIX = "/"
ARCHIDEKT_BASE_URL = "https://archidekt.com/api/decks/"
ARCHIDEKT_URL_SUFFIX = "/small/"
SCRYFALL_ID_BASE_URL = "https://api.scryfall.com/cards/"
SCRYFALL_MULTIVERSE_BASE_URL = "https://api.scryfall.com/cards/multiverse/"
SCRYFALL_NAME_BASE_URL = "https://api.scryfall.com/cards/named/?exact="

DECK_SOURCE_ARCHIDEKT = "archidekt"
DECK_SOURCE_TAPPEDOUT = "tappedout"

MAINDECK_POSITION_OFFSET = {0.0, 0.2, 0.1286}
DOUBLEFACE_POSITION_OFFSET = {1.47, 0.2, 0.1286}
SIDEBOARD_POSITION_OFFSET = {-1.47, 0.2, 0.1286}
COMMANDER_POSITION_OFFSET = {0.7286, 0.2, -0.8257}
TOKENS_POSITION_OFFSET = {-0.7286, 0.2, -0.8257}

------ GLOBAL STATE
lock = false
playerColor = nil
deckSource = nil

------ UTILITY
local function iterateLines(s)
    if string.sub(s, -1) ~= '\n' then
        s = s .. '\n'
    end

    return string.gmatch(s, "(.-)\n")
end

local function vecSum(v1, v2)
    return {v1[1] + v2[1], v1[2] + v2[2], v1[3] + v2[3]}
end

local function vecMult(v, s)
    return {v[1] * s, v[2] * s, v[3] * s}
end

local function printErr(s)
    printToColor(s, playerColor, {r=1, g=0, b=0})
end

local function printInfo(s)
    printToColor(s, playerColor)
end

------ CARD SPAWNING

-- Spawns the given card [face] at [position].
-- Card will be face down if [flipped].
-- Calls [onFullySpawned] when the object is spawned.
local function spawnCard(face, position, flipped, onFullySpawned)
    local rotation
    if flipped then
        rotation = vecSum(self.getRotation(), {0, 0, 180})
    else
        rotation = self.getRotation()
    end

    return spawnObject({
        type = "Card",
        sound = false,
        rotation = rotation,
        position = position,
        scale = vecMult(self.getScale(), (1 / 3.5)),
        callback_function = (function(obj)
            obj.setName(face.name)
            obj.setDescription(face.oracleText)
            obj.setCustomObject({
                face = face.imageURI,
                back = "https://gamepedia.cursecdn.com/mtgsalvation_gamepedia/f/f8/Magic_card_back.jpg?version=0ddc8d41c3b69c2c3c4bb5d72669ffd7"
            })
            onFullySpawned(obj)
        end)
    })
end

-- Spawns a deck named [name] containing the given [cards] at [position].
-- Deck will be face down if [flipped].
-- Calls [onFullySpawned] when the object is spawned.
local function spawnDeck(cards, name, position, flipped, onFullySpawned, onError)
    local cardObjects = {}

    local sem = 0
    local function incSem() sem = sem + 1 end
    local function decSem() sem = sem - 1 end

    for _, card in ipairs(cards) do
        for i=1,(card.count or 1) do
            if not card.faces or not card.faces[1] then
                card.faces = {{
                    name = card.name,
                    oracleText = "Card not found",
                    imageURI = "https://vignette.wikia.nocookie.net/yugioh/images/9/94/Back-Anime-2.png/revision/latest?cb=20110624090942",
                }}
            end

            for _, face in ipairs(card.faces) do
                incSem()
                spawnCard(face, position, flipped, function(obj)
                    table.insert(cardObjects, obj)
                    decSem()
                end)
            end
        end
    end

    Wait.condition(
        function()
            local deckObject

            if cardObjects[1] and cardObjects[2] then
                deckObject = cardObjects[1].putObject(cardObjects[2])
                deckObject.setPosition(position)
                deckObject.setName(name)
            else
                deckObject = cardObjects[1]
            end

            onFullySpawned(deckObject)
        end,
        function() return (sem == 0) end,
        5,
        function() onError("Error collating deck... timed out.") end
    )
end

------ SCRYFALL

-- Queries scryfall by the [cardID].
-- cardID must define at least one of scryfallID, multiverseID, or name:
-- onSuccess is called with a populated card table, and a table of associated token cardIDs.
local function queryCard(cardID, onSuccess, onError)
    local query_url

    if cardID['scryfallID'] and string.len(cardID['scryfallID']) > 0 then
        query_url = SCRYFALL_ID_BASE_URL .. cardID['scryfallID']
    elseif cardID['multiverseID'] and string.len(cardID['multiverseID']) > 0 then
        query_url = SCRYFALL_MULTIVERSE_BASE_URL .. cardID['multiverseID']
    else
        query_url = SCRYFALL_NAME_BASE_URL .. cardID['name']
    end

    webRequest = WebRequest.get(query_url, function(webReturn)
        if webReturn.is_error then
            onError(webReturn.error)
            return
        elseif string.len(webReturn.text) == 0 then
            onError("empty response")
            return
        end

        local success, data = pcall(function() return JSON.decode(webReturn.text) end)

        if not success then
            onError("failed to parse JSON response")
            return
        elseif not data then
            onError("empty JSON response")
            return
        elseif data.object == "error" then
            onError("failed to find card")
            return
        end

        -- Grab associated tokens
        local tokens = {}
        if data.all_parts and not (data.layout == "token") then
            for _, part in ipairs(data.all_parts) do
                if part.component and part.component == "token" then
                    table.insert(tokens, {
                        name = part.name,
                        scryfallID = part.id,
                    })
                end
            end
        end

        local card = cardID
        card.name = data.name
        card.faces = {}
        card.scryfallID = data.id

        if data.layout == "normal" or data.layout == "split" or data.layout == "token" then
            card['faces'][1] = {
                name = data.name,
                imageURI = data.image_uris.normal,
                oracleText = data.oracle_text,
            }
            card['doubleface'] = false
        elseif data.layout == "transform" then
            card['doubleface'] = true
            for i, face in ipairs(data.card_faces) do
                card['faces'][i] = {
                    name = face.name,
                    imageURI = face.image_uris.normal,
                    oracleText = face.oracle_text,
                }
            end
        else
            onError("Unrecognized card layout: " .. (data.layout or "nil"))
        end

        onSuccess(card, tokens)
    end)
end

-- Queries card data for all cards.
local function fetchCardData(cards, playerColor, onComplete)
    local sem = 0
    local function incSem() sem = sem + 1 end
    local function decSem() sem = sem - 1 end

    local cardData = {}
    local tokenIDs = {}

    for _, card in ipairs(cards) do
        incSem()
        queryCard(
            card,
            function(card, tokens) -- onSuccess
                table.insert(cardData, card)
                for _, token in ipairs(tokens) do
                    table.insert(tokenIDs, token)
                end
                decSem()
            end,
            function(e) -- onError
                printErr("Error querying scryfall for card [" .. card.name .. "]: " .. e, playerColor)
                decSem()
            end
        )
    end

    Wait.condition(
        function() onComplete(cardData, tokenIDs) end,
        function() return (sem == 0) end,
        30,
        function() printErr("Error loading card images... timed out.", playerColor) end
    )
end

-- Queries for the given card IDs, collates deck, and spawns objects.
local function loadDeck(cardIDs, deckName, onComplete)
    local maindeckPosition = self.positionToWorld(MAINDECK_POSITION_OFFSET)
    local doublefacePosition = self.positionToWorld(DOUBLEFACE_POSITION_OFFSET)
    local sideboardPosition = self.positionToWorld(SIDEBOARD_POSITION_OFFSET)
    local commanderPosition = self.positionToWorld(COMMANDER_POSITION_OFFSET)
    local tokensPosition = self.positionToWorld(TOKENS_POSITION_OFFSET)

    printInfo("Querying Scryfall for card data...")

    fetchCardData(cardIDs, playerColor, function(cards, tokenIDs)
        if tokenIDs and tokenIDs[1] then
            printInfo("Querying Scryfall for tokens...")
        end

        fetchCardData(tokenIDs, playerColor, function(tokens, _)
            local maindeck = {}
            local sideboard = {}
            local commander = {}
            local doubleface = {}

            for _, card in ipairs(cards) do
                if card.sideboard then
                    table.insert(sideboard, card)
                elseif card.commander then
                    table.insert(commander, card)
                elseif card.doubleface then
                    table.insert(doubleface, card)
                else
                    table.insert(maindeck, card)
                end
            end

            printInfo("Spawning deck...")

            local sem = 5
            local function decSem() sem = sem - 1 end

            spawnDeck(maindeck, deckName, maindeckPosition, true,
                function() -- onSuccess
                    decSem()
                end,
                function(e) -- onError
                    printErr(e, playerColor)
                    decSem()
                end
            )

            spawnDeck(doubleface, deckName .. " - double face cards", doublefacePosition, true,
                function(obj) -- onSuccess
                    if obj then
                        obj.setDescription("Combine these into states.")
                    end
                    decSem()
                end,
                function(e) -- onError
                    printErr(e, playerColor)
                    decSem()
                end
            )

            spawnDeck(sideboard, deckName .. " - sideboard", sideboardPosition, true,
                function() -- onSuccess
                    decSem()
                end,
                function(e) -- onError
                    printErr(e, playerColor)
                    decSem()
                end
            )

            spawnDeck(commander, deckName .. " - commanders", commanderPosition, false,
                function() -- onSuccess
                    decSem()
                end,
                function(e) -- onError
                    printErr(e, playerColor)
                    decSem()
                end
            )

            spawnDeck(tokens, deckName .. " - tokens", tokensPosition, true,
                function() -- onSuccess
                    decSem()
                end,
                function(e) -- onError
                    printErr(e, playerColor)
                    decSem()
                end
            )

            Wait.condition(
                function() onComplete() end,
                function() return (sem == 0) end,
                10,
                function() printErr("Error spawning deck objects... timed out.") end
            )
        end)
    end)
end

------ DECK BUILDER SCRAPING
local function parseDeckIDTappedout(s)
    return s:match("tappedout%.net/mtg%-decks/([^%s/]*)") or s:match("(%S*)")
end

local function queryDeckTappedout(slug, onSuccess, onError)
    if not slug or string.len(slug) == 0 then
        onError("Invalid tappedout deck slug: " .. slug)
        return
    end

    local url = TAPPEDOUT_BASE_URL .. slug .. TAPPEDOUT_URL_SUFFIX

    printInfo("Fetching decklist from tappedout...")

    WebRequest.get(url .. "?fmt=multiverse", function(webReturn)
        if webReturn.is_error then
            onError("Web request error: " .. webReturn.error)
            return
        elseif string.len(webReturn.text) == 0 then
            onError("Web request error: empty response")
            return
        end

        multiverseData = webReturn.text

        WebRequest.get(url .. "?fmt=txt", function(webReturn)
            if webReturn.is_error then
                onError("Web request error: " .. webReturn.error)
                return
            elseif string.len(webReturn.text) == 0 then
                onError("Web request error: empty response")
                return
            end

            txtData = webReturn.text

            local cards = {}

            local i = 1
            local sb = false
            for line in iterateLines(multiverseData) do
                line = string.gsub(line, "[\n\r]", "")

                if string.len(line) > 0 then
                    if line == "SB:" then
                        sb = true
                    else
                        local count, multiverseID = string.match(line, "(%d+) (.*)")

                        cards[i] = {
                            count = count,
                            multiverseID = multiverseID,
                            sideboard = sb,
                        }

                        i = i + 1
                    end
                end
            end

            local i = 1
            local sb = false
            for line in iterateLines(txtData) do
                line = string.gsub(line, "[\n\r]", "")

                if string.len(line) > 0 then
                    if line == "Sideboard:" then
                        sb = true
                    else
                        local _, name = string.match(line, "(%d+) (.+)")

                        cards[i]['name'] = name

                        i = i + 1
                    end
                end
            end

            onSuccess(cards, slug)
        end)
    end)
end

local function parseDeckIDArchidekt(s)
    return s:match("archidekt%.com/decks/(%d*)") or s:match("(%d*)")
end

local function queryDeckArchidekt(deckID, onSuccess, onError)
    if not deckID or string.len(deckID) == 0 then
        onError("Invalid archidekt deck ID: " .. deckID)
        return
    end

    local url = ARCHIDEKT_BASE_URL .. deckID .. ARCHIDEKT_URL_SUFFIX

    printInfo("Fetching decklist from archidekt...")

    WebRequest.get(url, function(webReturn)
        if webReturn.is_error then
            onError("Web request error: " .. webReturn.error)
            return
        elseif string.len(webReturn.text) == 0 then
            onError("Web request error: empty response")
            return
        end

        local success, data = pcall(function() return JSON.decode(webReturn.text) end)

        if not success then
            onError("Failed to parse JSON response from archidekt.")
            return
        elseif not data then
            onError("Empty response from archidekt.")
            return
        elseif not data.cards then
            onError("Empty response from archidekt. Did you enter a valid deck ID?")
            return
        end

        local deckName = data.name
        local cards = {}

        for i, card in ipairs(data.cards) do
            if card and card.card and not (card.category == "Maybeboard") then
                cards[#cards+1] = {
                    count = card.quantity,
                    sideboard = (card.category == "Sideboard"),
                    commander = (card.category == "Commander"),
                    name = card.card.oracleCard.name,
                    scryfallID = card.card.uid,
                }
            end
        end

        onSuccess(cards, deckName)
    end)
end

function importDeck()
    if lock then
        printErr("Error: Deck import started while importer locked.")
    end

    local deckDescriptor = getDeckInputValue()

    if string.len(deckDescriptor) == 0 then
        printInfo("Please enter a deck ID or URL.")
        return 1
    end

    local deckID, queryDeckFunc
    if deckSource == DECK_SOURCE_TAPPEDOUT then
        queryDeckFunc = queryDeckTappedout
        deckID = parseDeckIDTappedout(deckDescriptor)
        if not deckID then
            printErr("Failed to parse Tappedout deck ID")
            return 1
        end
    elseif deckSource == DECK_SOURCE_ARCHIDEKT then
        queryDeckFunc = queryDeckArchidekt
        deckID = parseDeckIDArchidekt(deckDescriptor)
        if not deckID then
            printErr("Failed to parse Archidekt deck ID")
            return 1
        end
    else
        printErr("Error. Unknown deck source: " .. deckSource)
        return 1
    end

    lock = true
    printToAll("Starting deck import...")

    queryDeckFunc(
        deckID,
        function(cardIDs, deckName) -- onSuccess
            loadDeck(cardIDs, deckName, function()
                printToAll("Deck import complete!")
                lock = false
            end)
        end,
        function(e) -- onError
            printErr(e, playerColor)
            printToAll("Deck import failed.")
            lock = false
        end
    )

    return 1
end

------ UI
local function drawUI()
    self.createInput({
        input_function = "onLoadDeckInput",
        function_owner = self,
        label          = "Enter deck URL/ID.",
        alignment      = 2,
        position       = {x=0, y=0.1, z=0.78},
        width          = 2000,
        height         = 100,
        font_size      = 60,
        validation     = 1,
        value = "",
    })

    self.createButton({
        click_function = "onLoadDeckTappedoutButton",
        function_owner = self,
        label          = "Load Deck (Tappedout)",
        position       = {1, 0.1, 1.15},
        rotation       = {0, 0, 0},
        width          = 850,
        height         = 160,
        font_size      = 80,
        color          = {0.5, 0.5, 0.5},
        font_color     = {r=1, b=1, g=1},
        tooltip        = "Click to load deck from tappedout.net",
    })

    self.createButton({
        click_function = "onLoadDeckArchidektButton",
        function_owner = self,
        label          = "Load Deck (Archidekt)",
        position       = {-1, 0.1, 1.15},
        rotation       = {0, 0, 0},
        width          = 850,
        height         = 160,
        font_size      = 80,
        color          = {0.5, 0.5, 0.5},
        font_color     = {r=1, b=1, g=1},
        tooltip        = "Click to load deck from archidekt.com",
    })
end

function getDeckInputValue()
    for i, input in pairs(self.getInputs()) do
        if input.label == "Enter deck URL/ID." then
            return string.gsub(input.value, "^%s*(.-)%s*$", "%1")
        end
    end

    return ""
end

function onLoadDeckInput(_, _, _) end

function onLoadDeckTappedoutButton(_, pc, _)
    if lock then
        printToColor("Another deck is currently being imported. Please wait for that to finish.", pc)
        return
    end

    playerColor = pc
    deckSource = DECK_SOURCE_TAPPEDOUT

    startLuaCoroutine(self, "importDeck")
end

function onLoadDeckArchidektButton(_, pc, _)
    if lock then
        printToColor("Another deck is currently being imported. Please wait for that to finish.", pc)
        return
    end

    playerColor = pc
    deckSource = DECK_SOURCE_ARCHIDEKT

    startLuaCoroutine(self, "importDeck")
end

------ TTS CALLBACKS
function onLoad()
    drawUI()
end