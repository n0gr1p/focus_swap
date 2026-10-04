_addon.name = 'focus_swap'
_addon.author = 'Peter + ChatGPT'
_addon.version = '0.2'
_addon.command = 'fswap'

local enabled = true
local last_focus = false
local debounce_until = 0
local applied_startup_position = false

-- Adjust these to your real Windows monitor layout.
-- This assumes:
--   Main monitor: 1920x1080 at x=0,y=0
--   Right monitor: 1920x1080 at x=1920,y=0
--[[local layouts = {
    main  = { x = 0,    y = 0,   w = 1920, h = 1035 },

    slot1 = { x = 1920, y = 0,   w = 960,  h = 517  },
    slot2 = { x = 2880, y = 0,   w = 960,  h = 517  },
    slot3 = { x = 1920, y = 517, w = 960,  h = 518  },
    slot4 = { x = 2880, y = 517, w = 960,  h = 518  },
    slot5 = { x = -1920,    y = 0,   w = 1770, h = 1035 },
    slot6  = { x = 0,    y = -1080,   w = 1920, h = 1035 },
}]]--
local layouts = {
    -- Main monitor
    main  = { x = 0,    y = 0,   w = 1920, h = 1035 },

    -- Right monitor: 3 wide x 2 high
    -- Each slot preserves approximately the same aspect ratio as 1920x1035.
    --
    -- Usable right-monitor area:
    -- x = 1920 -> 3840
    -- y = 0    -> 1035
    --
    -- Slot size: 640x345
    -- Grid height: 690
    -- Remaining vertical space: 345
    -- Centered with ~172px above and ~173px below.

    slot1 = { x = 1920, y = 172, w = 640, h = 345 },
    slot2 = { x = 2560, y = 172, w = 640, h = 345 },
    slot3 = { x = 3200, y = 172, w = 640, h = 345 },

    slot4 = { x = 1920, y = 517, w = 640, h = 345 },
    slot5 = { x = 2560, y = 517, w = 640, h = 345 },
    slot6 = { x = 3200, y = 517, w = 640, h = 345 },
}

-- Set your starting character layout here.
-- Use exact in-game character names.
local positions = {
    Terrasjr = 'main',
    Nyoourke = 'slot1',
    Redrogue = 'slot2',
    Niightsiide = 'slot3',
    Ponponponponpon = 'slot4',
    Etamame = 'slot5',
    Lalaithe = 'slot6',
}

local function find_current_main()
    for name, pos in pairs(positions) do
        if pos == 'main' then
            return name
        end
    end

    return nil
end

-- Current logical main is inherited from the positions table on load.
local current_main = find_current_main()

local function now()
    return os.clock()
end

local function get_name()
    local player = windower.ffxi.get_player()
    return player and player.name or nil
end

local function move_to(layout_name)
    local layout = layouts[layout_name]
    if not layout then
        windower.add_to_chat(167, '[focus_swap] Unknown layout: ' .. tostring(layout_name))
        return
    end

    -- Requires WinControl plugin loaded.
    windower.send_command(('wincontrol resize %d %d; wait 0.1; wincontrol move %d %d')
        :format(layout.w, layout.h, layout.x, layout.y))
end

local function sync_last_focus_state()
    if windower.has_focus then
        last_focus = windower.has_focus()
    else
        last_focus = false
    end
end

local function apply_default_position()
    local my_name = get_name()
    if not my_name then
        -- Player data may not exist yet during early load. Try again next prerender.
        return false
    end

    local my_slot = positions[my_name]
    if not my_slot then
        windower.add_to_chat(167, '[focus_swap] No starting position configured for ' .. my_name)
        applied_startup_position = true
        return true
    end

    move_to(my_slot)
    current_main = find_current_main()

    windower.add_to_chat(207, ('[focus_swap] Applied default position: %s = %s, current_main = %s')
        :format(my_name, my_slot, tostring(current_main)))

    -- Prevent a focused side-window from instantly promoting itself right after
    -- startup/reset just because it still has focus.
    sync_last_focus_state()
    debounce_until = now() + 1.0
    return true
end

local function apply_swap(new_main, old_slot)
    local my_name = get_name()
    if not my_name then return end

    local old_main = current_main or find_current_main()

    if not old_main then
        windower.add_to_chat(167, '[focus_swap] No current main could be determined.')
        return
    end

    if not old_slot or old_slot == 'main' then
        return
    end

    -- Already main, nothing to do.
    if new_main == old_main then
        positions[new_main] = 'main'
        current_main = new_main
        sync_last_focus_state()
        return
    end

    if my_name == new_main then
        move_to('main')
    elseif my_name == old_main then
        move_to(old_slot)
    end

    positions[new_main] = 'main'
    positions[old_main] = old_slot
    current_main = new_main

    sync_last_focus_state()
    debounce_until = now() + 1.0
end

local function promote_self()
    local my_name = get_name()
    if not my_name then return end

    local my_slot = positions[my_name]

    if not my_slot then
        windower.add_to_chat(167, '[focus_swap] No starting position configured for ' .. my_name)
        return
    end

    if my_slot == 'main' then
        return
    end

    local msg = ('focus_swap:promote:%s:%s'):format(my_name, my_slot)
    windower.send_ipc_message(msg)

    -- Also apply locally immediately because some Windower IPC setups may not echo
    -- the message back to the sender.
    apply_swap(my_name, my_slot)
end

windower.register_event('ipc message', function(msg)
    if type(msg) ~= 'string' then return end

    if msg == 'focus_swap:reset' then
        apply_default_position()
        return
    end

    local new_main, old_slot = msg:match('^focus_swap:promote:([^:]+):([^:]+)$')
    if not new_main or not old_slot then return end

    apply_swap(new_main, old_slot)
end)

windower.register_event('prerender', function()
    if not enabled then return end

    if not applied_startup_position then
        applied_startup_position = apply_default_position()
        return
    end

    if now() < debounce_until then return end
    if not windower.has_focus then return end

    local focused = windower.has_focus()

    -- Rising edge only: false -> true
    if focused and not last_focus then
        promote_self()
    end

    last_focus = focused
end)

windower.register_event('addon command', function(cmd, ...)
    cmd = cmd and cmd:lower() or ''

    if cmd == 'on' then
        enabled = true
        sync_last_focus_state()
        windower.add_to_chat(207, '[focus_swap] Enabled.')
    elseif cmd == 'off' then
        enabled = false
        windower.add_to_chat(207, '[focus_swap] Disabled.')
    elseif cmd == 'pos' then
        local my_name = get_name()
        local pos = my_name and positions[my_name] or 'unknown'
        windower.add_to_chat(207, ('[focus_swap] %s = %s, current_main = %s')
            :format(tostring(my_name), tostring(pos), tostring(current_main)))
    elseif cmd == 'apply' then
        local my_name = get_name()
        local pos = my_name and positions[my_name]
        if pos then
            move_to(pos)
            sync_last_focus_state()
            debounce_until = now() + 1.0
        else
            windower.add_to_chat(167, '[focus_swap] No starting position configured for ' .. tostring(my_name))
        end
    elseif cmd == 'reset' then
        windower.send_ipc_message('focus_swap:reset')
        apply_default_position()
    elseif cmd == 'help' or cmd == '' then
        windower.add_to_chat(207, '[focus_swap] Commands:')
        windower.add_to_chat(207, '//fswap on')
        windower.add_to_chat(207, '//fswap off')
        windower.add_to_chat(207, '//fswap pos')
        windower.add_to_chat(207, '//fswap apply')
        windower.add_to_chat(207, '//fswap reset')
    end
end)
