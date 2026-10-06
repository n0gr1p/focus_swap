_addon.name = 'focus_swap'
_addon.author = 'Peter + ChatGPT'
_addon.version = '0.4.2'
_addon.command = 'fswap'

local enabled = true
local last_focus = false
local debounce_until = 0
local last_join_request = 0
local last_state_broadcast = 0
local last_coordinator_seen = 0
local applied_layout_signature = nil
local population_reflow_due = nil
local population_reflow_reason = nil
local pending_promote_id = nil

local JOIN_RETRY_SECONDS = 0.5
local STATE_HEARTBEAT_SECONDS = 2.0
local COORDINATOR_TIMEOUT_SECONDS = 6.0
local POPULATION_SETTLE_SECONDS = 1.0
local MAX_CLIENTS = 10

-- Monitor geometry.
--
-- main is always the focused/active game window.
-- right is the usable area of the secondary monitor, excluding the taskbar.
local main_layout = { x = 0, y = 0, w = 1920, h = 1035 }
local right_monitor = { x = 1920, y = 0, w = 1920, h = 1035 }

-- Runtime-only state. Character names are used only as transient IPC identity;
-- there is no configured character -> slot mapping.
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

local function sync_last_focus_state()
    last_focus = is_focused()
end

local function assignment_count()
    local count = 0

    for _ in pairs(assignments) do
        count = count + 1
    end

    return count
end

local function side_slot_index(slot)
    if type(slot) ~= 'string' then
        return nil
    end

    local index = tonumber(slot:match('^slot(%d+)$'))
    if index and index >= 1 and index <= (MAX_CLIENTS - 1) then
        return index
    end

    return nil
end

local function is_valid_slot(slot)
    return slot == 'main' or side_slot_index(slot) ~= nil
end

local function layout_mode(total_clients)
    local side_count = math.max(0, total_clients - 1)

    if side_count == 0 then
        return 'main-only', 0, 0
    elseif side_count == 1 then
        return 'single', 1, 1
    elseif side_count == 2 then
        return 'two-wide', 2, 1
    elseif side_count <= 4 then
        return 'quad', 2, 2
    else
        return 'nine', 3, 3
    end
end

local function layout_for(slot, total_clients)
    if slot == 'main' then
        return {
            x = main_layout.x,
            y = main_layout.y,
            w = main_layout.w,
            h = main_layout.h,
        }
    end

    local index = side_slot_index(slot)
    if not index then
        return nil
    end

    local side_count = math.max(0, total_clients - 1)
    if index > side_count then
        return nil
    end

    local _, columns, rows = layout_mode(total_clients)
    if columns == 0 or rows == 0 then
        return nil
    end

    local aspect = main_layout.w / main_layout.h
    local cell_w = math.floor(right_monitor.w / columns)
    local natural_h = math.floor((cell_w / aspect) + 0.5)
    local max_h = math.floor(right_monitor.h / rows)
    local cell_h = math.min(natural_h, max_h)

    local grid_w = cell_w * columns
    local grid_h = cell_h * rows
    local grid_x = right_monitor.x + math.floor((right_monitor.w - grid_w) / 2)
    local grid_y = right_monitor.y + math.floor((right_monitor.h - grid_h) / 2)

    local zero_index = index - 1
    local column = zero_index % columns
    local row = math.floor(zero_index / columns)

    if row >= rows then
        return nil
    end

    return {
        x = grid_x + (column * cell_w),
        y = grid_y + (row * cell_h),
        w = cell_w,
        h = cell_h,
    }
end

local function geometry_signature(slot, total_clients)
    local layout = layout_for(slot, total_clients)
    if not layout then
        return nil
    end

    return ('%s:%d:%d:%d:%d')
        :format(slot, layout.x, layout.y, layout.w, layout.h)
end

local function move_to(slot, total_clients)
    local layout = layout_for(slot, total_clients)
    if not layout then
        windower.add_to_chat(
            167,
            ('[focus_swap] No layout available for %s with %d clients.')
                :format(tostring(slot), total_clients)
        )
        return false
    end

    -- Requires WinControl plugin loaded.
    windower.send_command(
        ('wincontrol resize %d %d; wait 0.1; wincontrol move %d %d')
            :format(layout.w, layout.h, layout.x, layout.y)
    )

    return true
end

local function apply_my_layout(force)
    local id = get_instance_id()
    if not id then
        return
    end

    my_slot = assignments[id]

    if not my_slot then
        applied_layout_signature = nil
        return
    end

    local total_clients = assignment_count()
    local signature = geometry_signature(my_slot, total_clients)

    if not signature then
        return
    end

    if force or signature ~= applied_layout_signature then
        if move_to(my_slot, total_clients) then
            applied_layout_signature = signature

            local mode = layout_mode(total_clients)
            windower.add_to_chat(
                207,
                ('[focus_swap] Runtime slot: %s | clients=%d | layout=%s%s')
                    :format(
                        my_slot,
                        total_clients,
                        mode,
                        id == current_main and ' | main' or ''
                    )
            )

            sync_last_focus_state()
            debounce_until = now() + 1.0
        end
    end
end

local function slot_rank(slot)
    if slot == 'main' then
        return 0
    end

    return side_slot_index(slot) or 999
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

-- Population changes repack side clients into consecutive slots. Because slot
-- geometry is derived from total client count, this also selects the optimal
-- single / two-wide / quad / nine-grid layout automatically.
local function repack_side_slots()
    if not current_main or not assignments[current_main] then
        return
    end

    local ordered = ordered_assignment_ids()
    local rebuilt = {
        [current_main] = 'main',
    }
    local slot_index = 1

    for _, id in ipairs(ordered) do
        if id ~= current_main and slot_index <= (MAX_CLIENTS - 1) then
            rebuilt[id] = 'slot' .. tostring(slot_index)
            slot_index = slot_index + 1
        end
    end

    assignments = rebuilt
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

local function publish_state()
    apply_my_layout(false)
    broadcast_state()
end

local function schedule_population_reflow(reason)
    if get_instance_id() ~= coordinator_id then
        return
    end

    population_reflow_due = now() + POPULATION_SETTLE_SECONDS
    population_reflow_reason = reason or 'population change'
end

local function settle_population_reflow()
    if get_instance_id() ~= coordinator_id or not population_reflow_due then
        return
    end

    population_reflow_due = nil

    if current_main and assignments[current_main] then
        repack_side_slots()
    else
        assignments = {}
        current_main = nil
    end

    -- If focus changed while membership was still settling, preserve that
    -- intent without publishing an intermediate geometry state.
    if pending_promote_id
        and assignments[pending_promote_id]
        and assignments[pending_promote_id] ~= 'main' then

        local old_main = current_main
        local old_slot = assignments[pending_promote_id]

        if old_main and assignments[old_main] == 'main' then
            assignments[old_main] = old_slot
        end

        assignments[pending_promote_id] = 'main'
        current_main = pending_promote_id
    end

    pending_promote_id = nil

    local total_clients = assignment_count()
    local mode = layout_mode(total_clients)

    windower.add_to_chat(
        207,
        ('[focus_swap] Population settled: %d clients | layout=%s | reason=%s')
            :format(
                total_clients,
                mode,
                tostring(population_reflow_reason or 'population change')
            )
    )

    population_reflow_reason = nil
    publish_state()
end

local function cancel_population_reflow()
    population_reflow_due = nil
    population_reflow_reason = nil
    pending_promote_id = nil
end

local function apply_shared_state(new_coordinator, new_main, new_assignments)
    coordinator_id = new_coordinator ~= '' and new_coordinator or nil
    current_main = new_main ~= '' and new_main or nil
    assignments = new_assignments or {}

    apply_my_layout(false)
end

local function parse_state(msg)
    local new_coordinator, new_main, payload =
        msg:match('^focus_swap:state:([^:]*):([^:]*):(.*)$')

    if not new_coordinator then
        return false
    end

    local new_assignments = {}

    for id, slot in payload:gmatch('([^=;]+)=([^;]+)') do
        if is_valid_slot(slot) then
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

    apply_my_layout(true)
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
        -- A reloaded client may ask to join even though the coordinator still
        -- has its real assignment. Send stable state immediately only when no
        -- population reflow is pending; otherwise wait for the settled state.
        if assignments[id] ~= 'pending' and not population_reflow_due then
            broadcast_state()
        end
        return
    end

    if assignment_count() >= MAX_CLIENTS then
        windower.add_to_chat(
            167,
            ('[focus_swap] Layout is full (%d clients maximum). Cannot assign %s.')
                :format(MAX_CLIENTS, tostring(id))
        )
        if not population_reflow_due then
            broadcast_state()
        end
        return
    end

    -- Mark membership immediately, but do not repack or broadcast intermediate
    -- geometry. Multiple joins inside the settle window collapse into one
    -- final reflow.
    assignments[id] = 'pending'
    schedule_population_reflow('client join')
end

local function coordinator_promote(id)
    local old_slot = assignments[id]
    if not old_slot or old_slot == 'main' then
        return
    end

    if population_reflow_due then
        pending_promote_id = id
        return
    end

    local old_main = current_main

    if old_main and assignments[old_main] == 'main' then
        assignments[old_main] = old_slot
    end

    assignments[id] = 'main'
    current_main = id

    -- Population did not change, so this is intentionally only a main <->
    -- side-slot swap. Other side windows keep their existing positions.
    publish_state()
end

local function coordinator_remove(id)
    if not assignments[id] then
        return
    end

    assignments[id] = nil

    if id == current_main then
        local replacement = nil

        if coordinator_id and assignments[coordinator_id] then
            replacement = coordinator_id
        else
            for _, candidate in ipairs(ordered_assignment_ids()) do
                replacement = candidate
                break
            end
        end

        current_main = replacement
    end

    -- Do not resize immediately. A mass addon reload can generate many leaves
    -- followed almost immediately by joins; all of them should collapse into
    -- one final geometry update after the population settles.
    schedule_population_reflow('client leave')
end

local function coordinator_reset(requester)
    if not assignments[requester] then
        return
    end

    cancel_population_reflow()
    current_main = requester
    repack_side_slots()

    -- Reset must physically reapply geometry even if logical slot assignments
    -- are unchanged. This repairs windows that were moved/resized externally.
    apply_my_layout(true)
    broadcast_state()
    windower.send_ipc_message('focus_swap:force_apply')

    windower.add_to_chat(
        207,
        ('[focus_swap] Layout reset. Reapplied %d-client geometry.')
            :format(assignment_count())
    )
end

local function promote_self()
    local id = get_instance_id()

    if not id or not my_slot or my_slot == 'main' or not coordinator_id then
        return
    end

    if id == coordinator_id then
        coordinator_promote(id)
    else
        windower.send_ipc_message(('focus_swap:promote_request:%s'):format(id))
    end
end

windower.register_event('ipc message', function(msg)
    if type(msg) ~= 'string' then
        return
    end

    if parse_state(msg) then
        return
    end

    if msg == 'focus_swap:force_apply' then
        apply_my_layout(true)
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

    local new_coordinator = msg:match('^focus_swap:handoff:([^:]+)$')
    if new_coordinator then
        if get_instance_id() == new_coordinator then
            local departing_coordinator = coordinator_id

            if departing_coordinator then
                assignments[departing_coordinator] = nil
            end

            coordinator_id = new_coordinator

            if not assignments[new_coordinator] then
                assignments[new_coordinator] = 'pending'
            end

            if not current_main or not assignments[current_main] then
                current_main = new_coordinator
            end

            last_coordinator_seen = now()
            schedule_population_reflow('coordinator handoff')
        end
        return
    end

    if msg == 'focus_swap:coordinator_gone' then
        coordinator_id = nil
        current_main = nil
        assignments = {}
        my_slot = nil
        applied_layout_signature = nil
        cancel_population_reflow()
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

    -- Startup/recovery: only the currently focused FFXI client may establish a
    -- coordinator, preventing multiple instances from racing for main.
    if not coordinator_id then
        if is_focused() then
            become_coordinator()
        end
        return
    end

    -- If the coordinator disappears without a clean unload, the focused client
    -- can rebuild the layout after the heartbeat timeout.
    if id ~= coordinator_id
        and last_coordinator_seen > 0
        and (t - last_coordinator_seen) >= COORDINATOR_TIMEOUT_SECONDS then

        coordinator_id = nil
        current_main = nil
        assignments = {}
        my_slot = nil
        applied_layout_signature = nil

        if is_focused() then
            become_coordinator()
        end

        return
    end

    if id == coordinator_id and population_reflow_due then
        if t >= population_reflow_due then
            settle_population_reflow()
        end
    elseif id == coordinator_id
        and (t - last_state_broadcast) >= STATE_HEARTBEAT_SECONDS then

        -- Never publish dirty/intermediate membership through the heartbeat.
        -- The settle path above owns the next authoritative geometry update.
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

        if handoff then
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
        local total_clients = assignment_count()
        local mode = layout_mode(total_clients)

        windower.add_to_chat(
            207,
            ('[focus_swap] id=%s slot=%s clients=%d layout=%s main=%s coordinator=%s')
                :format(
                    tostring(id),
                    tostring(my_slot),
                    total_clients,
                    mode,
                    tostring(current_main),
                    tostring(coordinator_id)
                )
        )

    elseif cmd == 'apply' then
        if my_slot then
            apply_my_layout(true)
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
            windower.add_to_chat(207, '[focus_swap] Requesting layout reset...')
            windower.send_ipc_message(('focus_swap:reset_request:%s'):format(id))
        elseif is_focused() then
            windower.add_to_chat(207, '[focus_swap] No coordinator found; rebuilding layout...')
            become_coordinator()
        else
            windower.add_to_chat(167, '[focus_swap] Reset requires a coordinator or focused client.')
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