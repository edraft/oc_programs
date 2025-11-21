local event = require("event")
local component = require("component")

local from = nil
local to = nil

local function clone()
    if not from then
        print("from not set")
        return
    end

    if not to then
        print("to not set")
        return
    end

    local fromShort = from:sub(1, 3)
    local toShort = to:sub(1, 3)

    print("Cloning " .. fromShort .. " to " .. toShort)
    os.execute("cp -r /mnt/" .. fromShort .. "/* /mnt/" .. toShort)
    local fromFs = component.proxy(from)
    local toFs = component.proxy(to)
    if fromFs and toFs then
        local label = fromFs.getLabel()
        if label then
            print("Set label")
            toFs.setLabel(label)
        end
    end

    print("Done...")
end

local function fs_added(id)
    if not id then
        return
    end

    if not from then
        print("Set from " .. id)
        from = id
        return
    end

    print("Set to " .. id)
    to = id
end

local function fs_removed(id)
    if not id then
        return
    end

    if from == id then
        print("Del from " .. id)
        from = nil
    end

    if to == id then
        print("Del to " .. id)
        to = nil
    end
end

local stop = false
while not stop do
    local ev = { event.pull() }
    if ev[1] == "interrupted" then
        stop = true
    elseif ev[1] == "component_added" then
        if ev[3] == "filesystem" then
            fs_added(ev[2])
            if from and to then
                clone()
            end
        end
    elseif ev[1] == "component_removed" then
        if ev[3] == "filesystem" then
            fs_removed(ev[2])
        end
    end
end

print("bye bye...")
