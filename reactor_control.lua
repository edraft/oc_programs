local component = require("component")
local event     = require("event")
local computer  = require("computer")
local term      = require("term")

local gpu       = component.gpu
local screen    = component.screen
local laser     = component.laser_verst_rker     -- component.laser_amplifier
local redstone  = component.redstone
local reactor   = component.reaktor_logikadapter -- component.reactor_logic_adapter -- can be nil

if not (gpu and screen and laser and redstone) then
    io.stderr:write("Required components missing\n")
    return
end

local running         = true

-- RedLogic bundled side
local rsSide          = 2
local fireColor       = 4
local chargeColor     = 1
local fuelColor       = 10
local cavityColor     = 12

-- Colors
local COLOR_ACTIVE    = 0x00CC00
local COLOR_INACTIVE  = 0x333333
local COLOR_WARN      = 0xCC0000
local COLOR_READY     = 0x00CCCC
local COLOR_BG        = 0x000000
local COLOR_GRAPH_PWR = 0x00A0FF
local COLOR_GRAPH_HT  = 0xFF8000

-- 1 MEU = 10,000,000 EU
local EU_PER_MEU      = 10000000
local requiredMEU     = 125
local requiredEU      = requiredMEU * EU_PER_MEU

local charging        = false
local fuelOpen        = false
local cavityOpen      = false

local lastMessage     = ""
local lastMessageTime = 0
local firstDraw       = true
local buttons         = {}

local MAX_HISTORY     = 400
local plasmaHistory   = {}
local energyHistory   = {}

local function msg(m)
    lastMessage = m or ""
    lastMessageTime = computer.uptime()
end

local function clear()
    local w, h = gpu.getResolution()
    gpu.setBackground(COLOR_BG)
    gpu.fill(1, 1, w, h, " ")
end

local function setBundled(color, value)
    redstone.setBundledOutput(rsSide, color, value)
end

local function updateOutputs()
    setBundled(chargeColor, charging and 255 or 0)
    setBundled(fuelColor, fuelOpen and 255 or 0)
    setBundled(cavityColor, cavityOpen and 255 or 0)
end

local function pulseFire()
    setBundled(fireColor, 255)
    os.sleep(0.3)
    setBundled(fireColor, 0)
end

local function getLaserEnergy()
    local ok, e = pcall(laser.getEnergy)
    if not ok then e = 0 end
    return e, e >= requiredEU
end

local function sampleReactor()
    if not reactor then
        return nil, nil
    end

    local okP, plasma = pcall(reactor.getPlasmaHeat)
    local okE, prod   = pcall(reactor.getProducing)

    if not okP then plasma = 0 end
    if not okE then prod = 0 end
    if plasma < 0 then plasma = 0 end
    if prod < 0 then prod = 0 end

    return plasma, prod
end

local function getReactorStatus()
    if not reactor then
        return nil, nil
    end

    local okI, ign = pcall(reactor.isIgnited)
    local okC, can = pcall(reactor.canIgnite)

    if not okI then ign = nil end
    if not okC then can = nil end

    return ign, can
end

-- Unit scaling: MEU -> KEU -> EU with thresholds
local function formatEnergy(eu)
    local meu = eu / EU_PER_MEU
    if meu >= 0.1 then
        return string.format("%.2f MEU", meu)
    end
    local keu = eu / 1000
    if keu >= 0.1 then
        return string.format("%.2f KEU", keu)
    end
    return string.format("%.0f EU", eu)
end

local function formatTemp(kelvin)
    local gk = kelvin / 1e9
    if gk >= 0.1 then
        return string.format("%.2f GK", gk)
    end
    local mk = kelvin / 1e6
    if mk >= 0.1 then
        return string.format("%.2f MK", mk)
    end
    return string.format("%.0f K", kelvin)
end

local function addButton(name, x1, y1, x2, y2, action)
    buttons[name] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, action = action, disabled = false }
end

-- Buttons: colored block, brackets exactly at the edges
local function buttonDraw(b, label, fg, bg)
    local w = b.x2 - b.x1 + 1
    if w < 2 then return end

    local innerMax = w - 2
    if innerMax < 0 then innerMax = 0 end

    if #label > innerMax then
        label = label:sub(1, innerMax)
    end

    local innerPad = innerMax - #label
    local leftInner = math.floor(innerPad / 2)
    local rightInner = innerPad - leftInner

    local display = "[" ..
        string.rep(" ", leftInner) ..
        label ..
        string.rep(" ", rightInner) ..
        "]"

    local cy = math.floor((b.y1 + b.y2) / 2)

    local oldFg, oldBg = gpu.getForeground(), gpu.getBackground()
    if b.disabled then
        fg, bg = 0xAAAAAA, COLOR_INACTIVE
    else
        fg = fg or 0xFFFFFF
        bg = bg or 0x444444
    end

    gpu.setForeground(fg)
    gpu.setBackground(bg)
    gpu.fill(b.x1, b.y1, w, b.y2 - b.y1 + 1, " ")
    gpu.set(b.x1, cy, display)

    gpu.setForeground(oldFg)
    gpu.setBackground(oldBg)
end

-- Indicators: NO brackets, just colored label
local function drawIndicator(x1, y1, x2, y2, label, state, colorOn, colorOff)
    local w = x2 - x1 + 1
    if w <= 0 then return end

    local fg, bg
    if state == nil then
        bg = COLOR_INACTIVE
        fg = 0xAAAAAA
    elseif state then
        bg = colorOn or COLOR_ACTIVE
        fg = 0x000000
    else
        bg = colorOff or COLOR_WARN
        fg = 0xFFFFFF
    end

    if #label > w then
        label = label:sub(1, w)
    end

    local pad          = w - #label
    local left         = math.floor(pad / 2)
    local right        = pad - left
    local cy           = math.floor((y1 + y2) / 2)

    local oldFg, oldBg = gpu.getForeground(), gpu.getBackground()
    gpu.setForeground(fg)
    gpu.setBackground(bg)
    gpu.fill(x1, y1, w, y2 - y1 + 1, " ")
    gpu.set(x1 + left, cy, label .. string.rep(" ", right))
    gpu.setForeground(oldFg)
    gpu.setBackground(oldBg)
end

local function inside(b, x, y)
    return x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2
end

local function pushHistory(history, value)
    history[#history + 1] = value
    if #history > MAX_HISTORY then
        table.remove(history, 1)
    end
end

local function drawFrame(x1, y1, x2, y2, title)
    local w = x2 - x1 + 1
    if w < 2 or y2 - y1 < 1 then return end

    local oldFg, oldBg = gpu.getForeground(), gpu.getBackground()
    gpu.setForeground(0xFFFFFF)
    gpu.setBackground(COLOR_BG)

    gpu.set(x1, y1, "┌" .. string.rep("─", w - 2) .. "┐")
    gpu.set(x1, y2, "└" .. string.rep("─", w - 2) .. "┘")
    for y = y1 + 1, y2 - 1 do
        gpu.set(x1, y, "│")
        gpu.set(x2, y, "│")
    end

    if title and #title > 0 and w > 4 then
        local t = " " .. title .. " "
        if #t > w - 4 then
            t = t:sub(1, w - 4)
        end
        gpu.set(x1 + 2, y1, t)
    end

    gpu.setForeground(oldFg)
    gpu.setBackground(oldBg)
end

-- History → fixed-width graph
local function drawGraph(x1, y1, x2, y2, history, label, color, valueText)
    local w = x2 - x1 + 1
    local h = y2 - y1 + 1
    if w <= 0 or h <= 2 then return end

    local oldFg, oldBg = gpu.getForeground(), gpu.getBackground()
    gpu.setBackground(COLOR_BG)
    gpu.fill(x1, y1, w, h, " ")

    gpu.setForeground(0xFFFFFF)
    if label then
        gpu.set(x1, y1, label)
    end
    if valueText then
        gpu.set(x1 + w - #valueText, y1, valueText)
    end

    local n = #history
    if n == 0 then
        gpu.setForeground(oldFg)
        gpu.setBackground(oldBg)
        return
    end

    local maxVal = 0
    for i = 1, n do
        local v = history[i]
        if v and v > maxVal then
            maxVal = v
        end
    end
    if maxVal <= 0 then
        gpu.setForeground(oldFg)
        gpu.setBackground(oldBg)
        return
    end

    gpu.setForeground(color or 0xFFFFFF)

    local cols    = w
    local step    = n / cols
    local baseY   = y2
    local usableH = h - 2
    if usableH < 1 then usableH = 1 end

    for col = 0, cols - 1 do
        local from = math.floor(col * step) + 1
        local to   = math.floor((col + 1) * step)
        if from > n then break end
        if to < from then to = from end
        if to > n then to = n end

        local colMax = 0
        for i = from, to do
            local v = history[i]
            if v and v > colMax then
                colMax = v
            end
        end

        local ratio = colMax / maxVal
        if ratio < 0 then ratio = 0 end
        if ratio > 1 then ratio = 1 end

        local height = math.floor(ratio * usableH + 0.5)
        if height > 0 then
            local colX = x1 + col
            gpu.fill(colX, baseY - height + 1, 1, height, "█")
        end
    end

    gpu.setForeground(oldFg)
    gpu.setBackground(oldBg)
end

local function draw()
    local w, h = gpu.getResolution()
    if firstDraw then
        clear()
        firstDraw = false
    end

    buttons = {}

    gpu.setBackground(COLOR_BG)
    gpu.fill(1, 1, w, 2, " ")
    gpu.set(2, 1, "edrafts Reactor Control")
    gpu.set(2, 2, string.rep("─", w - 4))

    local exitLabel = "[ X ]"
    local exW       = #exitLabel
    local exX1      = w - exW + 1
    addButton("exit", exX1, 1, w, 1, function() running = false end)
    buttonDraw(buttons.exit, "X", 0xFFFFFF, COLOR_WARN)

    local frameX1      = 2
    local frameX2      = w - 1

    -- Laser frame: text+bar, then Charge button
    local laserFrameY1 = 4
    local laserFrameY2 = laserFrameY1 + 3 -- top, 2 inner lines, bottom

    -- Control frame: indicators + control buttons
    local ctrlFrameY1  = laserFrameY2 + 1
    local ctrlFrameY2  = ctrlFrameY1 + 2 -- top, 1 inner lines, bottom

    local graphsTopAll = ctrlFrameY2 + 1
    local graphsBotAll = h - 1
    if graphsBotAll - graphsTopAll < 6 then
        graphsBotAll = graphsTopAll + 6
        if graphsBotAll > h - 1 then
            graphsBotAll = h - 1
        end
    end

    drawFrame(frameX1, laserFrameY1, frameX2, laserFrameY2, "Laser")
    drawFrame(frameX1, ctrlFrameY1, frameX2, ctrlFrameY2, "Reactor Control")

    local energyFrameY1 = graphsTopAll
    local energyFrameY2 = math.floor((graphsTopAll + graphsBotAll) / 2)
    local heatFrameY1   = energyFrameY2 + 1
    local heatFrameY2   = graphsBotAll

    drawFrame(frameX1, energyFrameY1, frameX2, energyFrameY2, "Power History")
    drawFrame(frameX1, heatFrameY1, frameX2, heatFrameY2, "Heat History")

    local energyEU, ready = getLaserEnergy()

    if ready and charging then
        charging = false
        updateOutputs()
        msg("Laser charged – charging OFF.")
    end

    -- LASER FRAME CONTENT
    local laserInnerX1  = frameX1 + 1
    local laserInnerX2  = frameX2 - 1
    local laserTextY    = laserFrameY1 + 1
    local laserBtnY     = laserFrameY1 + 2

    local laserValueStr = formatEnergy(energyEU)
    local laserLabel    = string.format("Laser energy: %s / %d MEU", laserValueStr, requiredMEU)

    gpu.setBackground(COLOR_BG)
    gpu.fill(laserInnerX1, laserTextY, laserInnerX2 - laserInnerX1 + 1, 1, " ")
    gpu.set(laserInnerX1, laserTextY, laserLabel)

    local barX = laserInnerX1 + #laserLabel + 2
    if barX < laserInnerX2 then
        local barW  = laserInnerX2 - barX + 1
        local ratio = energyEU / requiredEU
        if ratio < 0 then ratio = 0 end
        if ratio > 1 then ratio = 1 end
        local fill = math.floor(barW * ratio + 0.5)

        gpu.setBackground(COLOR_BG)
        gpu.fill(barX, laserTextY, barW, 1, " ")
        local oldFg = gpu.getForeground()
        if ready then
            gpu.setForeground(COLOR_ACTIVE)
        else
            gpu.setForeground(COLOR_WARN)
        end
        if fill > 0 then
            gpu.fill(barX, laserTextY, fill, 1, "█")
        end
        gpu.setForeground(oldFg)
    end

    -- Charge button in Laser frame (left side)
    local btnW     = 12
    local btnH     = 1
    local gap      = 2

    local chargeX1 = laserInnerX1
    local chargeX2 = chargeX1 + btnW - 1

    addButton("charge", chargeX1, laserBtnY, chargeX2, laserBtnY, function()
        charging = not charging
        updateOutputs()
        msg("Charging: " .. (charging and "ON" or "OFF"))
    end)

    local chargeFg, chargeBg =
        charging and 0x000000 or 0xFFFFFF,
        charging and COLOR_ACTIVE or COLOR_INACTIVE

    buttonDraw(buttons.charge, "Charge", chargeFg, chargeBg)

    -- CONTROL FRAME: indicators + control buttons
    local ctrlInnerX1        = frameX1 + 1
    local ctrlInnerX2        = frameX2 - 1
    local ctrlRowY           = ctrlFrameY1 + 1

    -- Indicators on the right: [Can Ignite] [Ignited]  (no brackets visually)
    local totalIndW          = 2 * btnW + gap
    local indRightX2         = ctrlInnerX2
    local indRightX1         = indRightX2 - totalIndW + 1

    local i1X1               = indRightX1
    local i1X2               = i1X1 + btnW - 1
    local i2X1               = i1X1 + btnW + gap
    local i2X2               = i2X1 + btnW - 1

    local ignited, canIgnite = getReactorStatus()

    drawIndicator(i1X1, ctrlRowY, i1X2, ctrlRowY, "Can Ignite", canIgnite, COLOR_ACTIVE, COLOR_INACTIVE)
    drawIndicator(i2X1, ctrlRowY, i2X2, ctrlRowY, "Ignited", ignited, COLOR_ACTIVE, COLOR_WARN)

    -- Control buttons: Ignite, Fuel, Cavity next to each other (left side)
    local igniteX1 = ctrlInnerX1
    local igniteX2 = igniteX1 + btnW - 1

    local fuelX1   = igniteX2 + gap + 1
    local fuelX2   = fuelX1 + btnW - 1

    local cavityX1 = fuelX2 + gap + 1
    local cavityX2 = cavityX1 + btnW - 1

    addButton("ignite", igniteX1, ctrlRowY, igniteX2, ctrlRowY, function()
        local _, ok = getLaserEnergy()
        if not ok then
            msg("Not enough energy.")
            return
        end
        pulseFire()
        msg("Ignition triggered.")
    end)

    addButton("fuel", fuelX1, ctrlRowY, fuelX2, ctrlRowY, function()
        fuelOpen = not fuelOpen
        updateOutputs()
        msg("Fuel: " .. (fuelOpen and "ON" or "OFF"))
    end)

    addButton("cavity", cavityX1, ctrlRowY, cavityX2, ctrlRowY, function()
        cavityOpen = not cavityOpen
        updateOutputs()
        msg("Cavity: " .. (cavityOpen and "ON" or "OFF"))
    end)

    buttons.ignite.disabled = not ready

    local ignFg, ignBg = nil, nil
    if ready then ignFg, ignBg = 0x000000, COLOR_READY end

    local fuelFg, fuelBg =
        fuelOpen and 0x000000 or 0xFFFFFF,
        fuelOpen and COLOR_ACTIVE or COLOR_INACTIVE

    local cavFg, cavBg =
        cavityOpen and 0x000000 or 0xFFFFFF,
        cavityOpen and COLOR_ACTIVE or COLOR_INACTIVE

    buttonDraw(buttons.ignite, "Ignite", ignFg, ignBg)
    buttonDraw(buttons.fuel, "Fuel", fuelFg, fuelBg)
    buttonDraw(buttons.cavity, "Cavity", cavFg, cavBg)

    -- GRAPHS
    local plasma, prod = sampleReactor()

    if plasma ~= nil and prod ~= nil then
        pushHistory(energyHistory, prod)
        pushHistory(plasmaHistory, plasma)

        local energyValStr = formatEnergy(prod)
        local plasmaValStr = formatTemp(plasma)

        local eInnerX1 = frameX1 + 1
        local eInnerX2 = frameX2 - 1
        local eInnerY1 = energyFrameY1 + 1
        local eInnerY2 = energyFrameY2 - 1

        local hInnerX1 = frameX1 + 1
        local hInnerX2 = frameX2 - 1
        local hInnerY1 = heatFrameY1 + 1
        local hInnerY2 = heatFrameY2 - 1

        drawGraph(eInnerX1, eInnerY1, eInnerX2, eInnerY2,
            energyHistory, "", COLOR_GRAPH_PWR, energyValStr)
        drawGraph(hInnerX1, hInnerY1, hInnerX2, hInnerY2,
            plasmaHistory, "", COLOR_GRAPH_HT, plasmaValStr)
    else
        local eInnerX1 = frameX1 + 1
        local eInnerX2 = frameX2 - 1
        local eInnerY1 = energyFrameY1 + 1
        local eInnerY2 = heatFrameY2 - 1
        gpu.setBackground(COLOR_BG)
        gpu.fill(eInnerX1, eInnerY1, eInnerX2 - eInnerX1 + 1, eInnerY2 - eInnerY1 + 1, " ")
        gpu.set(eInnerX1, eInnerY1, "No reactor adapter found")
    end

    gpu.setBackground(COLOR_BG)
    gpu.fill(1, h, w, 1, " ")
    if lastMessage ~= "" and computer.uptime() - lastMessageTime < 8 then
        gpu.set(2, h, lastMessage)
    end
end

local function handleTouch(_, _, x, y)
    for _, b in pairs(buttons) do
        if inside(b, x, y) then
            if not b.disabled and b.action then b.action() end
            draw()
            return
        end
    end
end

local function main()
    term.clear()
    updateOutputs()
    draw()

    while running do
        local ev = { event.pull(0.3) }
        if not ev[1] then
            draw()
        elseif ev[1] == "touch" then
            handleTouch(table.unpack(ev))
        elseif ev[1] == "interrupted" then
            running = false
        end
    end

    charging   = false
    fuelOpen   = false
    cavityOpen = false
    updateOutputs()
    clear()
end

main()
