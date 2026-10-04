_addon.name = 'focus_swap'
_addon.author = 'Peter + ChatGPT'
_addon.version = '0.3'
_addon.command = 'fswap'

local enabled = true
local last_focus = false
local debounce_until = 0
local last_join_request = 0
local last_state_broadcast = 0
local last_coordinator_seen = 0

local JOIN_RETRY_SECONDS = 0.5
local STATE_HEARTBEAT_SECONDS = 2.0
local COORDINATOR_TIMEOUT_SECONDS = 6.0

-- Monitor layout:
--   Main monitor:  1920x1080 at x=0,y=0
--   Right monitor: 1920x1080 at x=1920,y=0
--
-- The six side slots form a 3-wide x 2-high grid while preserving the
-- approximate 1920x1035 game-window aspect ratio.
local layouts = {
    main  = { x = 0,    y = 0,   w = 1920, h = 1035 },

    slot1 = { x = 1920, y = 172, w = 640, h = 345 },
    slot2 = { x = 2560, y = 172, w = 640, h = 345 },
    slot3 = { x = 3200, y = 172, w = 640, h = 345 },

    slot4 = { x = 1920, y = 517, w = 640, h = 345 },
    slot5 = { x = 2560, y = 517, w = 640, h = 345 },
    slot6 = { x = 3200, y = 517, w = 640, h = 345 },
}

local slot_order = {
    'slot1',
    'slot2',
    'slot3',
    'slot4',
    'slot5',
    'slot6',
}

-- Runtime-only state. Character names are used only as transient IPC identity;
-- there is no configured name -> slot mapping.
local instance_id = nil
local my_slot = nil
local coordinator_id = nil
local current_main = nil
local assignments = {}

local function now()
    return os.clock()
end

local function is_focused()
    return windower.has_focus and windower.has_focus() or false
end

local function get_instance_id()
    if instance_id then
        return instance_id
    end

    local player = windower.ffxi.get_player()
    if player and player.name then
        instance_id = player.name
    end

    return instance_id
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
    last_focus = is_focused()
end

local function slot_rank(slot)
    if slot == 'main' then
        return 0
    end

    for i, candidate in ipairs(slot_order) do
        if candidate == slot then
            return i
        end
    end

    return 999
end

local function find_free_slot()
    for _, slot in ipairs(slot_order) do
        local occupied = false

        for _, assigned_slot in pairs(assignments) do
            if assigned_slot == slot then
                occupied = true
                break
            end
        end

        if not occupied then
            return slot
        end
    end

    return nil
end

local function ordered_assignment_ids()
    local ids = {}

    for id in pairs(assignments) do
        ids[#ids + 1] = id
    end

    table.sort(ids, function(a, b)
        local a_rank = slot_rank(assignments[a])
        local b_rank = slot_rank(assignments[b])

        if a_rank == b_rank then
            return a < b
        end

        return a_rank < b_rank
    end)

    return ids
end

local function serialize_assignments()
    local parts = {}

    for _, id in ipairs(ordered_assignment_ids()) do
        parts[#parts + 1] = id .. '=' .. assignments[id]
    end

    return table.concat(parts, ';')
end

local function broadcast_state()
    local id = get_instance_id()
    if not id or id ~= coordinator_id then
        return
    end

    local msg = ('focus_swap:state:%s:%s:%s')
        :format(
            tostring(coordinator_id or ''),
            tostring(current_main or ''),
            serialize_assignments()
        )

    windower.send_ipc_message(msg)
    last_state_broadcast = now()
end

local function apply_shared_state(new_coordinator, new_main, new_assignments)
    local id = get_instance_id()
    if not id then
        return
    end

    local old_slot = my_slot

    coordinator_id = new_coordinator ~= '' and new_coordinator or nil
    current_main = new_main ~= '' and new_main or nil
    assignments = new_assignments or {}

    my_slot = assignments[id]

    if my_slot and my_slot ~= old_slot then
        move_to(my_slot)
        windower.add_to_chat(
            207,
            ('[focus_swap] Runtime slot: %s%s')
                :format(
                    my_slot,
                    id == current_main and ' (main)' or ''
                )
        )

        sync_last_focus_state()
        debounce_until = now() + 1.0
    end
end

local function parse_state(msg)
    local new_coordinator, new_main, payload =
        msg:match('^focus_swap:state:([^:]*):([^:]*):(.*)$')

    if not new_coordinator then
        return false
    end

    local new_assignments = {}

    for id, slot in payload:gmatch('([^=;]+)=([^;]+)') do
        if layouts[slot] then
            new_assignments[id] = slot
        end
    end

    last_coordinator_seen = now()
    apply_shared_state(new_coordinator, new_main, new_assignments)
    return true
end

local function become_coordinator()
    local id = get_instance_id()
    if not id then
        return false
    end

    coordinator_id = id
    current_main = id
    assignments = {
        [id] = 'main',
    }
    my_slot = 'main'
    last_coordinator_seen = now()

    move_to('main')
    sync_last_focus_state()
    debounce_until = now() + 1.0

    windower.add_to_chat(207, '[focus_swap] Established dynamic layout coordinator.')
    broadcast_state()
    return true
end

local function request_slot()
    local id = get_instance_id()
    if not id or my_slot then
        return
    end

    windower.send_ipc_message(('focus_swap:join:%s'):format(id))
    last_join_request = now()
end

local function coordinator_assign(id)
    if assignments[id] then
        broadcast_state()
        return
    end

    local slot = find_free_slot()
    if not slot then
        windower.add_to_chat(167, '[focus_swap] No free side slots remain for ' .. tostring(id))
        broadcast_state()
        return
    end

    assignments[id] = slot
    windower.add_to_chat(207, ('[focus_swap] Assigned %s -> %s'):format(id, slot))
    broadcast_state()
end

local function coordinator_promote(id)
    local old_slot = assignments[id]
    if not old_slot or old_slot == 'main' then
        return
    end

    local old_main = current_main

    if old_main and assignments[old_main] == 'main' then
        assignments[old_main] = old_slot
    end

    assignments[id] = 'main'
    current_main = id

    broadcast_state()
end

local function coordinator_remove(id)
    local removed_slot = assignments[id]
    if not removed_slot then
        return
    end

    assignments[id] = nil

    if id == current_main then
        -- Keep exactly one main whenever possible. The coordinator is the
        -- preferred fallback; otherwise use the lowest-numbered occupied slot.
        local replacement = nil

        if coordinator_id and assignments[coordinator_id] then
            replacement = coordinator_id
        else
            for _, candidate in ipairs(ordered_assignment_ids()) do
                replacement = candidate
                break
            end
        end

        if replacement then
            assignments[replacement] = 'main'
            current_main = replacement
        else
            current_main = nil
        end
    end

    broadcast_state()
end

local function coordinator_reset(requester)
    if not assignments[requester] then
        return
    end

    local existing = ordered_assignment_ids()
    local rebuilt = {
        [requester] = 'main',
    }

    local slot_index = 1

    for _, id in ipairs(existing) do
        if id ~= requester then
            local slot = slot_order[slot_index]
            if slot then
                rebuilt[id] = slot
                slot_index = slot_index + 1
            end
        end
    end

    assignments = rebuilt
    current_main = requester
    broadcast_state()
end

local function promote_self()
    local id = get_instance_id()
    if not id or not my_slot or my_slot == 'main' then
        return
    end

    if not coordinator_id then
        return
    end

    windower.send_ipc_message(('focus_swap:promote_request:%s'):format(id))
end

windower.register_event('ipc message', function(msg)
    if type(msg) ~= 'string' then
        return
    end

    if parse_state(msg) then
        return
    end

    local id = msg:match('^focus_swap:join:([^:]+)$')
    if id then
        if get_instance_id() == coordinator_id then
            coordinator_assign(id)
        end
        return
    end

    id = msg:match('^focus_swap:promote_request:([^:]+)$')
    if id then
        if get_instance_id() == coordinator_id then
            coordinator_promote(id)
        end
        return
    end

    id = msg:match('^focus_swap:leave:([^:]+)$')
    if id then
        if get_instance_id() == coordinator_id then
            coordinator_remove(id)
        end
        return
    end

    id = msg:match('^focus_swap:reset_request:([^:]+)$')
    if id then
        if get_instance_id() == coordinator_id then
            coordinator_reset(id)
        end
        return
    end

    local new_coordinator = msg:match('^focus_swap:handoff:([^:]+)
    if msg == 'focus_swap:coordinator_gone' then
        coordinator_id = nil
        last_coordinator_seen = 0
        return
    end
end)

windower.register_event('prerender', function()
    if not enabled then
        return
    end

    local id = get_instance_id()
    if not id then
        return
    end

    local t = now()

    -- Initial startup or coordinator recovery. Only the focused client may
    -- establish a new coordinator, preventing every instance from racing.
    if not coordinator_id then
        if is_focused() then
            become_coordinator()
        end
        return
    end

    -- If the coordinator silently disappears, allow the focused instance to
    -- recover the layout after a short heartbeat timeout.
    if id ~= coordinator_id
        and last_coordinator_seen > 0
        and (t - last_coordinator_seen) >= COORDINATOR_TIMEOUT_SECONDS then

        coordinator_id = nil
        my_slot = nil
        assignments = {}
        current_main = nil

        if is_focused() then
            become_coordinator()
        end

        return
    end

    if id == coordinator_id and (t - last_state_broadcast) >= STATE_HEARTBEAT_SECONDS then
        broadcast_state()
    end

    if not my_slot then
        if (t - last_join_request) >= JOIN_RETRY_SECONDS then
            request_slot()
        end
        return
    end

    if t < debounce_until then
        return
    end

    local focused = is_focused()

    -- Rising edge only: false -> true.
    if focused and not last_focus then
        promote_self()
    end

    last_focus = focused
end)

windower.register_event('unload', function()
    local id = get_instance_id()
    if not id then
        return
    end

    if id == coordinator_id then
        local handoff = nil

        if current_main and current_main ~= id and assignments[current_main] then
            handoff = current_main
        else
            for _, candidate in ipairs(ordered_assignment_ids()) do
                if candidate ~= id then
                    handoff = candidate
                    break
                end
            end
        end

        assignments[id] = nil

        if handoff then
            if current_main == id then
                assignments[handoff] = 'main'
                current_main = handoff
            end

            windower.send_ipc_message(('focus_swap:handoff:%s'):format(handoff))
        else
            windower.send_ipc_message('focus_swap:coordinator_gone')
        end
    else
        windower.send_ipc_message(('focus_swap:leave:%s'):format(id))
    end
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
        local id = get_instance_id()
        windower.add_to_chat(
            207,
            ('[focus_swap] id=%s slot=%s current_main=%s coordinator=%s')
                :format(
                    tostring(id),
                    tostring(my_slot),
                    tostring(current_main),
                    tostring(coordinator_id)
                )
        )

    elseif cmd == 'apply' then
        if my_slot then
            move_to(my_slot)
            sync_last_focus_state()
            debounce_until = now() + 1.0
        else
            windower.add_to_chat(167, '[focus_swap] No runtime slot has been assigned yet.')
        end

    elseif cmd == 'reset' then
        local id = get_instance_id()
        if not id then
            return
        end

        if id == coordinator_id then
            coordinator_reset(id)
        elseif coordinator_id then
            windower.send_ipc_message(('focus_swap:reset_request:%s'):format(id))
        elseif is_focused() then
            become_coordinator()
        end

    elseif cmd == 'help' or cmd == '' then
        windower.add_to_chat(207, '[focus_swap] Commands:')
        windower.add_to_chat(207, '//fswap on')
        windower.add_to_chat(207, '//fswap off')
        windower.add_to_chat(207, '//fswap pos')
        windower.add_to_chat(207, '//fswap apply')
        windower.add_to_chat(207, '//fswap reset')
    end
end)
)
    if new_coordinator then
        if get_instance_id() == new_coordinator then
            local departing_coordinator = coordinator_id

            if departing_coordinator then
                assignments[departing_coordinator] = nil
            end

            coordinator_id = new_coordinator
            assignments[new_coordinator] = assignments[new_coordinator] or 'main'

            if not current_main or not assignments[current_main] then
                current_main = new_coordinator
                assignments[new_coordinator] = 'main'
            end

            last_coordinator_seen = now()
            broadcast_state()
        end
        return
    end

    if msg == 'focus_swap:coordinator_gone' then
        coordinator_id = nil
        last_coordinator_seen = 0
        return
    end
end)

windower.register_event('prerender', function()
    if not enabled then
        return
    end

    local id = get_instance_id()
    if not id then
        return
    end

    local t = now()

    -- Initial startup or coordinator recovery. Only the focused client may
    -- establish a new coordinator, preventing every instance from racing.
    if not coordinator_id then
        if is_focused() then
            become_coordinator()
        end
        return
    end

    -- If the coordinator silently disappears, allow the focused instance to
    -- recover the layout after a short heartbeat timeout.
    if id ~= coordinator_id
        and last_coordinator_seen > 0
        and (t - last_coordinator_seen) >= COORDINATOR_TIMEOUT_SECONDS then

        coordinator_id = nil
        my_slot = nil
        assignments = {}
        current_main = nil

        if is_focused() then
            become_coordinator()
        end

        return
    end

    if id == coordinator_id and (t - last_state_broadcast) >= STATE_HEARTBEAT_SECONDS then
        broadcast_state()
    end

    if not my_slot then
        if (t - last_join_request) >= JOIN_RETRY_SECONDS then
            request_slot()
        end
        return
    end

    if t < debounce_until then
        return
    end

    local focused = is_focused()

    -- Rising edge only: false -> true.
    if focused and not last_focus then
        promote_self()
    end

    last_focus = focused
end)

windower.register_event('unload', function()
    local id = get_instance_id()
    if not id then
        return
    end

    if id == coordinator_id then
        local handoff = nil

        if current_main and current_main ~= id and assignments[current_main] then
            handoff = current_main
        else
            for _, candidate in ipairs(ordered_assignment_ids()) do
                if candidate ~= id then
                    handoff = candidate
                    break
                end
            end
        end

        assignments[id] = nil

        if handoff then
            if current_main == id then
                assignments[handoff] = 'main'
                current_main = handoff
            end

            windower.send_ipc_message(('focus_swap:handoff:%s'):format(handoff))
        else
            windower.send_ipc_message('focus_swap:coordinator_gone')
        end
    else
        windower.send_ipc_message(('focus_swap:leave:%s'):format(id))
    end
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
        local id = get_instance_id()
        windower.add_to_chat(
            207,
            ('[focus_swap] id=%s slot=%s current_main=%s coordinator=%s')
                :format(
                    tostring(id),
                    tostring(my_slot),
                    tostring(current_main),
                    tostring(coordinator_id)
                )
        )

    elseif cmd == 'apply' then
        if my_slot then
            move_to(my_slot)
            sync_last_focus_state()
            debounce_until = now() + 1.0
        else
            windower.add_to_chat(167, '[focus_swap] No runtime slot has been assigned yet.')
        end

    elseif cmd == 'reset' then
        local id = get_instance_id()
        if not id then
            return
        end

        if id == coordinator_id then
            coordinator_reset(id)
        elseif coordinator_id then
            windower.send_ipc_message(('focus_swap:reset_request:%s'):format(id))
        elseif is_focused() then
            become_coordinator()
        end

    elseif cmd == 'help' or cmd == '' then
        windower.add_to_chat(207, '[focus_swap] Commands:')
        windower.add_to_chat(207, '//fswap on')
        windower.add_to_chat(207, '//fswap off')
        windower.add_to_chat(207, '//fswap pos')
        windower.add_to_chat(207, '//fswap apply')
        windower.add_to_chat(207, '//fswap reset')
    end
end)
