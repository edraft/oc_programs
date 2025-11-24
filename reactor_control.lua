local component = require("component")
local event     = require("event")
local computer  = require("computer")
local term      = require("term")

--------------------------------------------------------------------
-- Configuration loading
--------------------------------------------------------------------
local function loadConfig()
    -- Default configuration (used if config file is missing or incomplete)
    local defaults = {
        -- RedLogic bundled side + colors
        rsSide          = 5,
        fireColor       = 4,  -- ignition
        chargeColor     = 1,  -- charging laser
        fuelColor       = 10, -- fuel injection
        cavityColor     = 12, -- cavity supply

        -- GUI colors
        COLOR_ACTIVE    = 0x00CC00,
        COLOR_INACTIVE  = 0x333333,
        COLOR_WARN      = 0xCC0000,
        COLOR_READY     = 0x00CCCC,
        COLOR_BG        = 0x000000,
        COLOR_GRAPH_PWR = 0x00A0FF, -- output power
        COLOR_GRAPH_HT  = 0xFF8000, -- heat

        -- Energy settings
        EU_PER_MEU      = 10000000, -- 1 MEU = 10,000,000 energy units
        requiredMEU     = 125,      -- target MEU for ignition

        -- History / graph settings
        MAX_HISTORY     = 400
    }

    -- Path to the config file; change if you prefer another location/name
    local configPath = "/etc/reactor_control.cfg"

    local ok, cfg = pcall(dofile, configPath)
    if not ok or type(cfg) ~= "table" then
        -- Use defaults if config not found or invalid
        return defaults
    end

    -- Fill in missing values with defaults
    for k, v in pairs(defaults) do
        if cfg[k] == nil then
            cfg[k] = v
        end
    end

    return cfg
end

local config          = loadConfig()

--------------------------------------------------------------------
-- Local references to settings
--------------------------------------------------------------------
local rsSide          = config.rsSide
local fireColor       = config.fireColor
local chargeColor     = config.chargeColor
local fuelColor       = config.fuelColor
local cavityColor     = config.cavityColor

local COLOR_ACTIVE    = config.COLOR_ACTIVE
local COLOR_INACTIVE  = config.COLOR_INACTIVE
local COLOR_WARN      = config.COLOR_WARN
local COLOR_READY     = config.COLOR_READY
local COLOR_BG        = config.COLOR_BG
local COLOR_GRAPH_PWR = config.COLOR_GRAPH_PWR
local COLOR_GRAPH_HT  = config.COLOR_GRAPH_HT

local EU_PER_MEU      = config.EU_PER_MEU
local requiredMEU     = config.requiredMEU
local requiredEU      = requiredMEU * EU_PER_MEU

local MAX_HISTORY     = config.MAX_HISTORY

--------------------------------------------------------------------
-- Components
--------------------------------------------------------------------
local gpu             = component.gpu
local screen          = component.screen
local laser           = component.laser_amplifier
local redstone        = component.redstone
local reactor         = component.reaktor_logic_adapter -- can be nil

if not (gpu and screen and laser and redstone) then
    io.stderr:write("Required components missing\n")
    return
end

--------------------------------------------------------------------
-- State
--------------------------------------------------------------------
local running         = true

local charging        = false
local fuelOpen        = false
local cavityOpen      = false

local lastMessage     = ""
local lastMessageTime = 0
local firstDraw       = true
local buttons         = {}

local plasmaHistory   = {}
local energyHistory   = {}

--------------------------------------------------------------------
-- Helper functions
--------------------------------------------------------------------
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

local function addButton(name, x1, y1, x2, y2, action)
    buttons[name] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, action = action, disabled = false }
end

local function buttonDraw(b, label, fg, bg)
    local w = b.x2 - b.x1 + 1
    if #label > w then label = label:sub(1, w) end

    local pad          = w - #label
    local left         = math.floor(pad / 2)
    local right        = pad - left
    local cy           = math.floor((b.y1 + b.y2) / 2)

    local oldFg, oldBg = gpu.getForeground(), gpu.getBackground()

    if b.disabled then
        fg, bg = 0xAAAAAA, COLOR_INACTIVE
    else
        fg = fg or 0xFFFFFF
        bg = bg or 0x444444
    end

    gpu.setForeground(fg)
    gpu.setBackground(bg)
    for y = b.y1, b.y2 do
        gpu.fill(b.x1, y, w, 1, " ")
    end
    gpu.set(b.x1 + left, cy, label .. string.rep(" ", right))

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

local function drawGraph(x1, y1, x2, y2, history, label, color, valueText)
    local w = x2 - x1 + 1
    local h = y2 - y1 + 1
    if w <= 0 or h <= 2 then return end

    local oldFg, oldBg = gpu.getForeground(), gpu.getBackground()
    gpu.setBackground(COLOR_BG)
    gpu.fill(x1, y1, w, h, " ")

    if label then
        gpu.setForeground(0xFFFFFF)
        gpu.set(x1, y1, label)
        if valueText then
            gpu.set(x1 + w - #valueText, y1, valueText)
        end
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

    local cols = w
    local step = n / cols
    local baseY = y2
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

--------------------------------------------------------------------
-- Drawing / UI
--------------------------------------------------------------------
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
    buttonDraw(buttons.exit, exitLabel, 0xFFFFFF, COLOR_WARN)

    local energyEU, ready = getLaserEnergy()
    local emeu = energyEU / EU_PER_MEU

    if ready and charging then
        charging = false
        updateOutputs()
        msg("Laser charged – charging OFF.")
    end

    gpu.fill(1, 4, w, 1, " ")
    gpu.set(2, 4, string.format("Laser energy: %.2f MEU / %d MEU", emeu, requiredMEU))

    local barX, barY = 2, 6
    local barW = w - 4
    local barH = 3

    gpu.fill(barX, barY, barW, barH, " ")
    gpu.set(barX, barY, "┌" .. string.rep("─", barW - 2) .. "┐")
    gpu.set(barX, barY + barH - 1, "└" .. string.rep("─", barW - 2) .. "┘")
    for i = barY + 1, barY + barH - 2 do
        gpu.set(barX, i, "│")
        gpu.set(barX + barW - 1, i, "│")
    end

    local ratio = energyEU / requiredEU
    if ratio < 0 then ratio = 0 end
    if ratio > 1 then ratio = 1 end
    local fill = math.floor((barW - 2) * ratio + 0.5)

    do
        local oldFg = gpu.getForeground()
        if ready then
            gpu.setForeground(COLOR_ACTIVE)
        else
            gpu.setForeground(COLOR_WARN)
        end
        if fill > 0 then
            gpu.fill(barX + 1, barY + 1, fill, barH - 2, "█")
        end
        gpu.setForeground(oldFg)
    end

    local btnW, btnH  = 14, 3
    local rowY        = barY + barH + 2
    local gap         = 2

    -- ignition (left side)
    local zX1, zY1    = 2, rowY
    local zX2, zY2    = zX1 + btnW - 1, zY1 + btnH - 1

    -- three buttons (right side)
    local totalRightW = 3 * btnW + 2 * gap
    local rightX2     = w - 2
    local rightX1     = rightX2 - totalRightW + 1

    local cX1, cY1    = rightX1, rowY
    local cX2, cY2    = cX1 + btnW - 1, cY1 + btnH - 1

    local fX1, fY1    = cX1 + btnW + gap, rowY
    local fX2, fY2    = fX1 + btnW - 1, fY1 + btnH - 1

    local hX1, hY1    = fX1 + btnW + gap, rowY
    local hX2, hY2    = hX1 + btnW - 1, hY1 + btnH - 1

    addButton("ignite", zX1, zY1, zX2, zY2, function()
        local _, ok = getLaserEnergy()
        if not ok then
            msg("Not enough energy.")
            return
        end
        pulseFire()
        msg("Ignition triggered.")
    end)

    addButton("charge", cX1, cY1, cX2, cY2, function()
        charging = not charging
        updateOutputs()
        msg("Charging: " .. (charging and "ON" or "OFF"))
    end)

    addButton("fuel", fX1, fY1, fX2, fY2, function()
        fuelOpen = not fuelOpen
        updateOutputs()
        msg("Fuel: " .. (fuelOpen and "ON" or "OFF"))
    end)

    addButton("cavity", hX1, hY1, hX2, hY2, function()
        cavityOpen = not cavityOpen
        updateOutputs()
        msg("Cavity: " .. (cavityOpen and "ON" or "OFF"))
    end)

    buttons.ignite.disabled = not ready

    local ignFg, ignBg = nil, nil
    if ready then ignFg, ignBg = 0x000000, COLOR_READY end

    local chargeFg, chargeBg =
        charging and 0x000000 or 0xFFFFFF,
        charging and COLOR_ACTIVE or COLOR_INACTIVE

    local fuelFg, fuelBg =
        fuelOpen and 0x000000 or 0xFFFFFF,
        fuelOpen and COLOR_ACTIVE or COLOR_INACTIVE

    local cavFg, cavBg =
        cavityOpen and 0x000000 or 0xFFFFFF,
        cavityOpen and COLOR_ACTIVE or COLOR_INACTIVE

    buttonDraw(buttons.ignite, "Ignite", ignFg, ignBg)
    buttonDraw(buttons.charge, "Charge", chargeFg, chargeBg)
    buttonDraw(buttons.fuel, "Fuel", fuelFg, fuelBg)
    buttonDraw(buttons.cavity, "Cavity", cavFg, cavBg)

    -- reactor graphs (stacked vertically)
    local graphsTop    = rowY + btnH + 2
    local graphsBottom = h - 1
    if graphsBottom <= graphsTop then graphsBottom = graphsTop + 2 end
    local midY = math.floor((graphsTop + graphsBottom) / 2)

    local plasma, prod = sampleReactor()

    if plasma ~= nil and prod ~= nil then
        pushHistory(energyHistory, prod)
        pushHistory(plasmaHistory, plasma)

        local energyMEU   = prod / EU_PER_MEU
        local plasmaGK    = plasma / 1000000000 -- 1e9 = gigakelvin

        local energyLabel = "Output Power"
        local energyVal   = string.format("%.2f MEU", energyMEU)
        local plasmaLabel = "Plasma Heat"
        local plasmaVal   = string.format("%.2f GK", plasmaGK)

        drawGraph(2, graphsTop, w - 1, midY,
            energyHistory, energyLabel, COLOR_GRAPH_PWR, energyVal)
        drawGraph(2, midY + 1, w - 1, graphsBottom,
            plasmaHistory, plasmaLabel, COLOR_GRAPH_HT, plasmaVal)
    else
        gpu.fill(1, graphsTop, w, graphsBottom - graphsTop + 1, " ")
        gpu.set(2, graphsTop, "No reactor adapter detected")
    end

    gpu.setBackground(COLOR_BG)
    gpu.fill(1, h, w, 1, " ")
    if lastMessage ~= "" and computer.uptime() - lastMessageTime < 8 then
        gpu.set(2, h, lastMessage)
    end
end

--------------------------------------------------------------------
-- Event handling
--------------------------------------------------------------------
local function handleTouch(_, _, x, y)
    for _, b in pairs(buttons) do
        if inside(b, x, y) then
            if not b.disabled and b.action then b.action() end
            draw()
            return
        end
    end
end

--------------------------------------------------------------------
-- Main
--------------------------------------------------------------------
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
