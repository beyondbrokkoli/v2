-- main.lua
io.stdout:setvbuf("no")
package.path = "./lua/?.lua;" .. package.path

local ffi = require("ffi")
local bit = require("bit")
local json_util = require("json_util")
local structs = require("structs")
local reg_vk = require("registry_vk")
local cfg_gfx = require("config_gfx")
local cfg_sim = require("config_sim")
local cfg_net = require("config_net")

local WindowAPI = require("window_api")
local EngineAPI = require("engine_api")

local app_ctx = {
    cfg_gfx = cfg_gfx,
    cfg_sim = cfg_sim,
    cfg_net = cfg_net
}

local math = require("math")
local vmath = require("vmath")
local manifest = require("pipeline_manifest")
local net = require("network")
local Fixed = require("fixed_math")

local seq = require("sequence").init(app_ctx)
local render_queue = require("render_queue").init(app_ctx)
local Game = require("game_state").init(app_ctx)
local Pump = require("net_pump").init(app_ctx)
local FSM = require("fsm_core").init(app_ctx, Game)

local primary_win_id = 0

local function sys_sleep(ms)
    if jit.os == "Windows" then 
        ffi.C.Sleep(ms) 
    else 
        ffi.C.usleep(ms * 1000) 
    end
end

local get_time_hires
if jit.os == "Windows" then
    local kernel32 = ffi.load("kernel32")
    local freq = ffi.new("int64_t[1]")
    kernel32.QueryPerformanceFrequency(freq)
    local inv_freq = 1.0 / tonumber(freq[0])
    get_time_hires = function()
        local count = ffi.new("int64_t[1]")
        kernel32.QueryPerformanceCounter(count)
        return tonumber(count[0]) * inv_freq
    end
else
    local CLOCK_MONOTONIC = 1
    get_time_hires = function()
        local ts = ffi.new("timespec")
        ffi.C.clock_gettime(CLOCK_MONOTONIC, ts)
        return tonumber(ts.tv_sec) + (tonumber(ts.tv_nsec) * 1e-9)
    end
end

local function http_post(url, json_payload)
    local payload_path = "matchmaker_payload.json"
    local f = assert(io.open(payload_path, "w"), "Failed to open temp file")
    f:write(json_payload)
    f:close()
    local cmd = string.format('curl -s -X POST -H "Content-Type: application/json" -d "@%s" %s', payload_path, url)
    local pf = io.popen(cmd)
    local res = pf:read("*a")
    pf:close()
    os.remove(payload_path)
    return res
end

local function http_get(url)
    local cmd = string.format('curl -s "%s"', url)
    local f = io.popen(cmd)
    if not f then return "" end
    local res = f:read("*a")
    f:close()
    return res
end

local function get_local_ip()
    local cmd = ""
    if jit.os == "Windows" then
        cmd = 'powershell -Command "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike \'127.*\' -and $_.IPAddress -notlike \'169.254.*\' } | Select-Object -First 1).IPAddress"'
    else
        cmd = "ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i==\"src\") print $(i+1)}'"
    end
    local f = io.popen(cmd)
    if not f then return "127.0.0.1" end
    local res = f:read("*a")
    f:close()
    res = res:gsub("%s+", "")
    if not res:match("^%d+%.%d+%.%d+%.%d+$") then return "127.0.0.1" end
    return res
end

local function extract_true_64bit_token(json_string)
    local token_digits = json_string:match('"session_token"%s*:%s*(%d+)')
    assert(token_digits, "FATAL: Could not locate session_token digits in JSON payload")
    local val = ffi.cast("uint64_t", 0)
    for i = 1, #token_digits do
        local byte = string.byte(token_digits, i)
        if byte >= 48 and byte <= 57 then
            val = (val * 10) + (byte - 48)
        else
            break
        end
    end
    return val
end

local function BootstrapNetworkTopology(local_port, my_local_ip)
    print(string.format("[STUN] Querying external NAT edges at %s:%d...", cfg_net.STUN_SERVER, cfg_net.STUN_PORT))
    local stun_ok, my_pub_ip, my_pub_port = net.StunPunch(cfg_net.STUN_SERVER, cfg_net.STUN_PORT)
    if not stun_ok then
        print("[WARNING] STUN negotiation failed. Operating via local loopbacks.")
        my_pub_ip = my_local_ip
        my_pub_port = local_port
    else
        print(string.format("[STUN] Discovery successful. External mapped endpoint: %s:%d", my_pub_ip, my_pub_port))
    end

    print("\n[MATCHMAKING] Select Mode: (H)ost New Game or (J)oin Existing Lobby")
    io.write("> ")
    local mode_input = io.read("*l"):upper()
    local lobby_id = ""
    local session_token = nil
    local initial_payload = json_util.encode({
        public_ip = my_pub_ip, public_port = my_pub_port,
        local_ip = my_local_ip, local_port = local_port
    })

    if mode_input == "H" then
        print("Enter Target Lobby Size (2-8):")
        io.write("> ")
        local target_size = tonumber(io.read("*l")) or 2
        target_size = math.max(2, math.min(8, target_size))
        local host_payload = json_util.encode({
            public_ip = my_pub_ip, public_port = my_pub_port,
            local_ip = my_local_ip, local_port = local_port,
            target_size = target_size
        })
        print(string.format("[MATCHMAKER] Requesting new lobby for %d players...", target_size))
        local response = http_post(cfg_net.MATCHMAKER_URL .. "/host", host_payload)
        session_token = extract_true_64bit_token(response)
        lobby_id = json_util.decode(response).lobby_id
        print("[MATCHMAKER] Hosted Lobby, holding room: " .. lobby_id)
    else
        if mode_input == "J" then
            print("Enter Target 4-Character Lobby ID:")
            io.write("> ")
            lobby_id = io.read("*l"):upper()
        else
            lobby_id = mode_input:upper()
        end
        print("[MATCHMAKER] Joining Lobby: " .. lobby_id)
        local response = http_post(cfg_net.MATCHMAKER_URL .. "/join/" .. lobby_id, initial_payload)
        session_token = extract_true_64bit_token(response)
    end

    print("[MATCHMAKER] Polling quorum status. Waiting for 'locked'...")
    local status_data = nil
    while true do
        local raw_res = http_get(cfg_net.MATCHMAKER_URL .. "/status/" .. lobby_id)
        if raw_res and raw_res ~= "" then
            status_data = json_util.decode(raw_res)
            if status_data.status == "locked" then
                print(string.format("[MATCHMAKER] Quorum reached (%d/%d). Lobby is LOCKED.", status_data.player_count, cfg_net.MAX_PLAYERS))
                break
            end
        end
        sys_sleep(500)
    end

    local local_id = 0
    for i, p in ipairs(status_data.players) do
        if p.ip == my_pub_ip and tonumber(p.port) == my_pub_port and p.local_ip == my_local_ip and p.local_port == local_port then
            local_id = i - 1
            break
        end
    end

    net.SetPlayerId(local_id)
    net.SetSession(session_token)
    print(string.format("[SYSTEM] Assigning Identity: Node %d. Meshing topology...", local_id))

    local p2p_established = {}
    local active_peers = {}
    for i, p in ipairs(status_data.players) do
        local peer_id = i - 1
        if peer_id ~= local_id then
            active_peers[peer_id] = true
            if p.ip == my_pub_ip or p.ip == "127.0.0.1" or my_pub_ip == "127.0.0.1" then
                local target_ip = (p.local_ip == my_local_ip) and "127.0.0.1" or p.local_ip
                net.Connect(peer_id, target_ip, tonumber(p.local_port))
                p2p_established[peer_id] = true
                print(string.format("[ROUTING] Node %d clamped to LAN (%s:%d). Hairpin bypassed.", peer_id, target_ip, p.local_port))
            else
                net.Connect(peer_id, p.ip, tonumber(p.port))
                print(string.format("[ROUTING] Node %d is WAN. Staging for ICE...", peer_id))
            end
        end
    end

    local real_time_remaining = status_data.start_time - status_data.server_time
    local sync_start_time = get_time_hires()
    if real_time_remaining > 0 then
        print(string.format("[ICE] Quorum locked. Initiating Mutual Handshake for %.2f seconds...", real_time_remaining))
        local header_size = ffi.offsetof("LockstepPacket", "commands")
        local scratch_handshake = ffi.new("LockstepPacket")
        local handshake_buffer = ffi.new("RxPacket[32]")
        local p2p_heard = {}
        
        while (get_time_hires() - sync_start_time) < real_time_remaining do
            for peer_id, active in pairs(active_peers) do
                if active and not p2p_established[peer_id] then
                    local ping_pkt = ffi.new("LockstepPacket")
                    ping_pkt.session_token = session_token
                    ping_pkt.player_id = local_id
                    ping_pkt.frame_tick = p2p_heard[peer_id] and 1 or 0
                    net.SendTo(ping_pkt, header_size, peer_id)
                end
            end

            local count = net.RecvAll(handshake_buffer, 32)
            for i = 0, count - 1 do
                local rx_pkt = handshake_buffer[i]
                ffi.copy(scratch_handshake, rx_pkt.data, header_size)
                if scratch_handshake.session_token == session_token then
                    local sender = scratch_handshake.player_id
                    p2p_heard[sender] = true
                    if scratch_handshake.frame_tick >= 1 and not p2p_established[sender] then
                        p2p_established[sender] = true
                        print(string.format("[ICE] Mutual P2P Punch-Through SUCCESS for Node %d!", sender))
                    end
                end
            end
            sys_sleep(50)
        end
    end

    print("[ICE] Sync window closed. Evaluating routing topologies...")
    for peer_id, active in pairs(active_peers) do
        if active then
            if p2p_established[peer_id] then
                print(string.format("[ROUTING] Node %d -> P2P [DIRECT RESIDENTIAL]", peer_id))
            else
                print(string.format("[ROUTING] Node %d -> P2P [FAILED]. Tagged for Omnibus Relay.", peer_id))
            end
        end
    end

    net.SetRelayIP(cfg_net.RELAY_IP)
    net.Connect(cfg_net.MAX_PLAYERS, cfg_net.RELAY_IP, cfg_net.RELAY_PORT)
    local reg_pkt = ffi.new("LockstepPacket")
    reg_pkt.session_token = session_token
    reg_pkt.player_id = local_id
    reg_pkt.frame_tick = 0
    local header_size = ffi.offsetof("LockstepPacket", "commands")
    net.SendTo(reg_pkt, header_size, cfg_net.MAX_PLAYERS)
    print("[SYSTEM] All routes bound. Drop-in complete.")

    return session_token, local_id, p2p_established, active_peers, status_data
end

local function EngineSubmitCommand(ctx, opcode, flags, target_id, target_pos)
    local c_idx = bit.band(ctx.sim_tick_count, cfg_net.RING_MASK)
    local pending_frame = ctx.rollback_arena.frames[c_idx]

    if pending_frame.tick ~= ctx.sim_tick_count then
        pending_frame.tick = ctx.sim_tick_count
        for p = 0, cfg_net.MAX_PLAYERS - 1 do
            pending_frame.commands[p][0].opcode = 0
            pending_frame.commands[p][1].opcode = 0
        end
        pending_frame.state_checksum = 0
        pending_frame.remote_checksum = 0
        pending_frame.state = 0
        pending_frame.remote_peer_id = 0
    end

    local cmds = pending_frame.commands[ctx.net_identity]
    if cmds[0].opcode == 0 then
        cmds[0].opcode = opcode
        cmds[0].flags = flags
        cmds[0].target_id = target_id
        cmds[0].target_pos = target_pos
    elseif cmds[1].opcode == 0 then
        cmds[1].opcode = opcode
        cmds[1].flags = flags
        cmds[1].target_id = target_id
        cmds[1].target_pos = target_pos
    else
        print("[WARNING] Engine Command Buffer saturated for tick " .. ctx.sim_tick_count)
    end
end

local function boot_weaver()
    local ctx = {
        win_id = primary_win_id
    }
    for i, stage in ipairs(seq.boot) do
        print(string.format("[WEAVER] Executing Stage %d: %s", i, stage.name))
        local signal = stage.action(ctx)
        if signal == "AWAIT_SURFACE" then
            print("[WEAVER] Yielding execution, waiting for C-Core Surface...")
            while WindowAPI.get_surface(ctx.win_id) == nil do
                sys_sleep(10)
                coroutine.yield()
            end
        end
    end
    return ctx
end

local temp_vec_near = ffi.new("vec4_t")
local temp_vec_far = ffi.new("vec4_t")

local function matrix_raycast_terrain(mouse_x, mouse_y, screen_w, screen_h, viewProj_inv, grid, net_identity)
    local nx = (mouse_x / screen_w) * 2.0 - 1.0
    local ny = (mouse_y / screen_h) * 2.0 - 1.0

    vmath.multiply_mat4_vec4(viewProj_inv, nx, ny, 0.0, 1.0, temp_vec_near)
    vmath.multiply_mat4_vec4(viewProj_inv, nx, ny, 1.0, 1.0, temp_vec_far)

    local near_w = 1.0 / temp_vec_near.w
    local ox, oy, oz = temp_vec_near.x * near_w, temp_vec_near.y * near_w, temp_vec_near.z * near_w

    local far_w = 1.0 / temp_vec_far.w
    local fx, fy, fz = temp_vec_far.x * far_w, temp_vec_far.y * far_w, temp_vec_far.z * far_w

    local dx, dy, dz = fx - ox, fy - oy, fz - oz
    local inv_mag = 1.0 / math.sqrt(dx^2 + dy^2 + dz^2)
    dx, dy, dz = dx * inv_mag, dy * inv_mag, dz * inv_mag

    local t = 0.0
    local p = net_identity or 0
    if dy < 0.0 then
        local dist_to_ceiling = (10.0 - oy) / dy
        if dist_to_ceiling > 0.0 then t = dist_to_ceiling end
    end

    for i = 1, 100 do
        local px = ox + dx * t
        local py = oy + dy * t
        local pz = oz + dz * t

        local grid_x = math.floor((px + cfg_sim.world.offset_x) / cfg_sim.world.spacing + 0.5)
        local grid_z = math.floor((pz + cfg_sim.world.offset_z) / cfg_sim.world.spacing + 0.5)

        if grid_x >= 0 and grid_x < cfg_sim.world.map_width and grid_z >= 0 and grid_z < cfg_sim.world.map_height then
            local idx = grid_z * cfg_sim.world.map_width + grid_x
            local max_elevation = 0
            for peer = 0, 7 do
                local peer_elev = grid.elevation[peer][idx]
                if peer_elev > max_elevation then
                    max_elevation = peer_elev
                end
            end
            local float_elevation = Fixed.to_float(max_elevation)
            if py <= float_elevation + 0.1 then return idx end
        end
        t = t + (cfg_sim.world.spacing * 0.1)
    end
    return 65535
end

local function main()
    print("Enter Node ID (0-7) OR Preferred Local Port (e.g., 50000): ")
    io.write("> ")
    local user_input = tonumber(io.read("*l")) or 50000
    local local_port = user_input
    if local_port < 1000 then
        local_port = 50000 + local_port
    end

    assert(net.Host(local_port), "FATAL: Failed to bind local socket port " .. local_port)
    local my_local_ip = get_local_ip()
    local session_token, local_id, p2p_established, active_peers, status_data = BootstrapNetworkTopology(local_port, my_local_ip)

    local ctx = {
        session_token = session_token,
        net_identity = local_id,
        win_id = primary_win_id,
        sim_tick_count = 1,
        accumulator = 0.0,
        net_accumulator = 0.0,
        total_tiles = cfg_sim.world.map_width * cfg_sim.world.map_height,
        p2p_established = p2p_established,
        peer_active = ffi.new(string.format("bool[%d]", cfg_net.MAX_PLAYERS)),
        peer_highest_tick = ffi.new(string.format("uint32_t[%d]", cfg_net.MAX_PLAYERS)),
        peer_ack_of_me = ffi.new(string.format("uint32_t[%d]", cfg_net.MAX_PLAYERS)),
        rts_grid = Game.InitState(session_token),
        rollback_arena = ffi.new("RollbackBuffer"),
        snapshot_ring = ffi.new(string.format("%s[%d]", Game.GetStateName(), cfg_net.RING_SIZE))
    }

    for p = 0, cfg_net.MAX_PLAYERS - 1 do
        if p < #status_data.players then
            ctx.peer_active[p] = true
        else
            ctx.peer_active[p] = false
        end
    end

    print("[LUA IO] Booting Headless Weaver (LABORATORY)...")
    local co = coroutine.create(boot_weaver)
    local status, engine_ctx
    while coroutine.status(co) ~= "dead" do
        status, engine_ctx = coroutine.resume(co)
        if not status then error("Fatal Weaver Crash: " .. tostring(engine_ctx)) end
    end

    print("[LUA IO] Weaver sequence complete! Unpacking Context...")
    local vk_rt = engine_ctx.vk_runtime
    local sc = engine_ctx.sc_state
    local desc = engine_ctx.desc_state
    local gfx = engine_ctx.gfx_state
    local sync = engine_ctx.sync_state
    local memory = require("memory")

    print("[LUA CO] Initializing VRAM Index Buffer with Strict Topology...")
    local index_ptr = ffi.cast("uint32_t*", memory.Mapped["MASTER_INDEX_BLOCK"])
    local iso_indices = ffi.new("uint32_t[36]", {
        0, 2, 3,  0, 3, 4,  0, 4, 5,  0, 5, 2,
        2, 6, 7,  2, 7, 3,  3, 7, 11, 3, 11, 4,
        4, 11, 10, 4, 10, 5, 5, 10, 6, 5, 6, 2
    })
    ffi.copy(index_ptr, iso_indices, 36 * 4)

    print("[LUA CO] Allocating Direct FFI Render Queues...")
    local MAX_DRAW_COMMANDS = 1024
    local render_queues = ffi.new("DrawCommand[?]", MAX_DRAW_COMMANDS * cfg_gfx.cfg.frame_slots)
    local frame_count = 0

    local vmath = require("vmath")
    local pc = ffi.new("PushConstants")
    pc.aos_current_idx, pc.aos_prev_idx = 0, 0
    pc.dt = 0.0

    local camera_mod = require("camera")
    local cam = camera_mod.new()
    local inv_vp = ffi.new("mat4_t")
    local total_time = 0.0
    local wants_hotswap = false
    local master_ptr = ffi.cast("float*", memory.Mapped["MASTER_GPU_BLOCK"])
    local active_render_mode = cfg_gfx.mode.dual
    local is_resizing = false
    local last_resize_time = get_time_hires()
    local RESIZE_COOLDOWN = 0.25

    local TICK_RATE = cfg_net.TICK_RATE
    local FIXED_DT = 1.0 / TICK_RATE

    print("[LUA CO] Packing Data-Driven Color Palette...")
    local staging_ptr = ffi.cast("float*", memory.Mapped["PALETTE_STAGING"])
    staging_ptr[0] = 0.2; staging_ptr[1] = 0.8; staging_ptr[2] = 0.2; staging_ptr[3] = 1.0
    staging_ptr[4] = 0.2; staging_ptr[5] = 0.5; staging_ptr[6] = 1.0; staging_ptr[7] = 1.0
    staging_ptr[8] = 1.0; staging_ptr[9] = 0.2; staging_ptr[10] = 0.2; staging_ptr[11] = 1.0
    staging_ptr[40] = 1.0; staging_ptr[41] = 1.0; staging_ptr[42] = 1.0; staging_ptr[43] = 1.0
    staging_ptr[44] = 1.0; staging_ptr[45] = 0.0; staging_ptr[46] = 0.0; staging_ptr[47] = 1.0
    staging_ptr[48] = 0.0; staging_ptr[49] = 0.0; staging_ptr[50] = 1.0; staging_ptr[51] = 1.0
    staging_ptr[52] = 1.0; staging_ptr[53] = 0.0; staging_ptr[54] = 0.0; staging_ptr[55] = 1.0

    local palette_job_id = memory.TransferAsync("PALETTE_STAGING", "PALETTE_HAVEN", 16384)
    local palette_ready = false

    print("[LUA CO] Entering Deterministic Rollback Render Loop...")
    local prev_mouse_left = 0
    local pending_click = 65535

    print("[LUA CO] Pre-computing Universal Geometry Template...")
    local vram_template = ffi.new("RtsTileInstance[?]", ctx.total_tiles)
    for z = 0, cfg_sim.world.map_height - 1 do
        for x = 0, cfg_sim.world.map_width - 1 do
            local i = z * cfg_sim.world.map_width + x
            vram_template[i].px = (x * cfg_sim.world.spacing) - cfg_sim.world.offset_x
            vram_template[i].pz = (z * cfg_sim.world.spacing) - cfg_sim.world.offset_z
        end
    end

    local gfx_pipeline_module = require("graphics_pipeline")
    local pump_deletion_queue = gfx_pipeline_module.PumpDeletionQueue

    print("[NET] Scene loaded. Camera unlocked. Awaiting Timeline Synchronization...")
    local last_time = get_time_hires()
    local last_heartbeat = get_time_hires()

    while EngineAPI.is_running() do
        if WindowAPI.was_resized(ctx.win_id) then
            is_resizing = true
            last_resize_time = get_time_hires()
        end

        local current_time = get_time_hires()
        local frame_time = math.max(0.001, math.min(current_time - last_time, 0.25))
        last_time = current_time

        local mouse_left = WindowAPI.is_mouse_down(ctx.win_id, 0)
        local mouse_x, mouse_y = WindowAPI.get_mouse_pos(ctx.win_id)

        if mouse_left and prev_mouse_left == 0 then
            local click_x, click_y = WindowAPI.get_click_pos(ctx.win_id)
            local clicked_idx = matrix_raycast_terrain(
                click_x, click_y, sc.extent.width, sc.extent.height,
                inv_vp, ctx.rts_grid, ctx.net_identity
            )

            if clicked_idx ~= 65535 then
                local is_elevated = false
                for peer = 0, cfg_net.MAX_PLAYERS - 1 do
                    if ctx.rts_grid.elevation[peer][clicked_idx] > 0 then
                        is_elevated = true
                        break
                    end
                end
                if is_elevated then
                    EngineSubmitCommand(ctx, 2, 0, 0, clicked_idx)
                else
                    EngineSubmitCommand(ctx, 1, 0, 0, clicked_idx)
                end
            end
        end
        prev_mouse_left = mouse_left and 1 or 0

        Pump.intercept_network(ctx, ctx.sim_tick_count)
        ctx.accumulator = ctx.accumulator + frame_time
        ctx.net_accumulator = ctx.net_accumulator + frame_time
        FSM.tick_playing_state(ctx, FIXED_DT)

        if ctx.net_accumulator >= FIXED_DT then
            Pump.send_dynamic_history(ctx)
            ctx.net_accumulator = ctx.net_accumulator % FIXED_DT
        end

        if current_time - last_heartbeat >= 1.0 then
            last_heartbeat = current_time
            print(string.format("\n[HEARTBEAT] Sim Tick: %d | Confirmed: %d | Accum: %.4f",
                ctx.sim_tick_count, ctx.rollback_arena.confirmed_tick, ctx.accumulator))
            for p = 0, cfg_net.MAX_PLAYERS - 1 do
                if ctx.peer_active[p] and p ~= ctx.net_identity then
                    print(string.format(" -> [DIAGNOSTIC] Peer %d | Highest Tick: %d | AckOfMe: %d",
                        p, ctx.peer_highest_tick[p], ctx.peer_ack_of_me[p]))
                end
            end
        end

        local last_key = WindowAPI.get_last_key(ctx.win_id)
        if last_key == cfg_gfx.key.esc then
            EngineAPI.shutdown()
        elseif last_key == cfg_gfx.key.f5 then
            wants_hotswap = true
        elseif last_key == cfg_gfx.key.num1 then
            active_render_mode = cfg_gfx.mode.dual
        elseif last_key == cfg_gfx.key.num2 then
            active_render_mode = cfg_gfx.mode.geom
        elseif last_key == cfg_gfx.key.num3 then
            active_render_mode = cfg_gfx.mode.points
        end

        if is_resizing then
            if (get_time_hires() - last_resize_time) > RESIZE_COOLDOWN then
                local new_w, new_h = WindowAPI.get_window_size(ctx.win_id)
                if new_w > 0 and new_h > 0 then
                    print("\n[LUA CO] Window Stable. Initiating Mini-Weaver Rebuild...")
                    EngineAPI.kill_thread()
                    vk_rt.vk.vkDeviceWaitIdle(vk_rt.device)
                    require("graphics_pipeline").Destroy(vk_rt.vk, vk_rt, gfx)
                    require("renderer").Destroy(vk_rt.vk, vk_rt.device, sync, cfg_gfx.cfg.frame_slots)

                    cfg_gfx.win.w = new_w
                    cfg_gfx.win.h = new_h

                    local mini_ctx = {
                        win_id = ctx.win_id,
                        vk_runtime = vk_rt,
                        desc_state = desc,
                        old_swapchain = sc.handle
                    }

                    local resize_co = coroutine.create(function()
                        for _, stage in ipairs(seq.resize) do
                            print(string.format("[MINI-WEAVER] Executing: %s", stage.name))
                            stage.action(mini_ctx)
                        end
                        return mini_ctx
                    end)

                    local status, new_ctx
                    while coroutine.status(resize_co) ~= "dead" do
                        status, new_ctx = coroutine.resume(resize_co)
                        if not status then error("Mini-Weaver Crash: " .. tostring(new_ctx)) end
                    end

                    require("swapchain").Destroy(vk_rt.vk, vk_rt, sc)
                    sc = new_ctx.sc_state
                    gfx = new_ctx.gfx_state
                    sync = new_ctx.sync_state

                    seq.boot[10].action(new_ctx)
                    print("[LUA CO] Mini-Weaver Rebuild Complete.\n")
                    is_resizing = false
                    last_time = get_time_hires()
                else
                    last_resize_time = get_time_hires() - (RESIZE_COOLDOWN * 0.9)
                end
            end
        else
            if not palette_ready and palette_job_id ~= -1 then
                if memory.IsTransferComplete(vk_rt, palette_job_id) then
                    print("[LUA CO] Async Transfer Complete! Palette Haven Online.")
                    palette_ready = true
                end
            end

            total_time = total_time + frame_time
            pc.total_time = total_time
            camera_mod.update(cam, frame_time, mouse_x, mouse_y, sc.extent.width, sc.extent.height)
            camera_mod.get_matrices(cam, sc.extent.width, sc.extent.height, pc.viewProj, inv_vp)

            local write_idx = EngineAPI.acquire_render_packet()
            if write_idx ~= -1 then
                local alpha = ctx.accumulator / FIXED_DT
                pc.dt = alpha
                render_queue.PackFrame(write_idx, pc, ctx.rts_grid, vram_template, render_queues, active_render_mode, master_ptr, memory, gfx, desc, sc, ctx.total_tiles, ctx.net_identity, ctx.win_id)

                if wants_hotswap then
                    print("\n[LUA] Initiating Lock-Free Shader Hotswap...")
                    require("graphics_pipeline").HotReloadShaders(vk_rt.vk, vk_rt, gfx, frame_count)
                    wants_hotswap = false
                    print("[LUA] Hotswap Complete. New pipelines active.\n")
                end

                EngineAPI.commit_render_packet(write_idx)
                pump_deletion_queue(vk_rt.vk, vk_rt, frame_count)
                frame_count = frame_count + 1
            end
        end
        sys_sleep(1)
    end

    print("\n[LUA IO] Render Loop Terminated. Commencing Teardown...")
    print("[TEARDOWN] Terminating Async Render Thread and Worker Pool...")
    EngineAPI.kill_thread()
    vk_rt.vk.vkDeviceWaitIdle(vk_rt.device)
    require("graphics_pipeline").Destroy(vk_rt.vk, vk_rt, gfx)
    require("compute_pipeline").Destroy(vk_rt.vk, vk_rt, engine_ctx.comp_state)
    require("descriptors").Destroy(vk_rt.vk, vk_rt.device, desc)
    require("swapchain").Destroy(vk_rt.vk, vk_rt, sc)
    require("renderer").Destroy(vk_rt.vk, vk_rt.device, sync, cfg_gfx.cfg.frame_slots)

    print("[TEARDOWN] Freeing VRAM and CPU Memory Arenas...")
    memory.DestroyBuffer("MASTER_GPU_BLOCK", vk_rt)
    memory.DestroyBuffer("MASTER_INDEX_BLOCK", vk_rt)
    memory.DestroyBuffer("PALETTE_STAGING", vk_rt)
    memory.DestroyBuffer("PALETTE_HAVEN", vk_rt)
    net.Shutdown()
    memory.DestroyTransferSubsystem(vk_rt)
    require("vulkan_core").Destroy(vk_rt, cfg_gfx.cfg)

    print("[LUA IO] Teardown Complete. Safe Exit.")
end

main()
EngineAPI.mark_finished()
