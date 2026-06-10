local net = require("network")
local Pump = require("net_pump")
local State = require("sim_world")
local bit = require("bit")
local ffi = require("ffi")

local FSM = {}

function FSM.tick_playing_state(ctx, FIXED_DT, bytes_terrain, bytes_elevation)
    local remote_highest = ctx.rollback_arena.confirmed_tick
    
    if remote_highest > ctx.sim_tick_count + 2 then
        ctx.accumulator = ctx.accumulator + ((remote_highest - ctx.sim_tick_count) * FIXED_DT)
    end
    
    if ctx.sim_tick_count > remote_highest + 120 then
        ctx.accumulator = 0
    end
    
    if ctx.sim_tick_count % 120 == (ctx.net_identity * 10) then
        if ctx.last_bot_tick ~= ctx.sim_tick_count then
            ctx.pending_click = math.random(0, ctx.total_tiles - 1)
            ctx.last_bot_tick = ctx.sim_tick_count
        end
    end
    
    while ctx.accumulator >= FIXED_DT do
        local c_idx = bit.band(ctx.sim_tick_count, 127)
        local frame = ctx.rollback_arena.frames[c_idx]
        
        if frame.tick ~= ctx.sim_tick_count then
            for p = 0, 7 do
                frame.player_input[p] = 0
                frame.click_grid_idx[p] = -1
            end
            frame.state_checksum = 0
            frame.remote_checksum = 0
        end
        
        frame.tick = ctx.sim_tick_count
        if ctx.pending_click ~= -1 then
            frame.click_grid_idx[ctx.net_identity] = ctx.pending_click
            ctx.pending_click = -1
        end
        
        ctx.rollback_arena.head_tick = ctx.sim_tick_count
        Pump.send_dynamic_history(ctx)
        Pump.intercept_network(ctx, ctx.sim_tick_count)
        
        if ctx.rollback_arena.is_rollback_active == 1 then
            local t_tgt = ctx.rollback_arena.rollback_target
            local r_idx = bit.band(t_tgt - 1, 127)
            
            ffi.copy(ctx.rts_grid.terrain, ctx.snapshot_ring.terrain[r_idx], bytes_terrain)
            ffi.copy(ctx.rts_grid.elevation, ctx.snapshot_ring.elevation[r_idx], bytes_elevation)
            
            for t = t_tgt, ctx.sim_tick_count - 1 do
                local f_idx = bit.band(t, 127)
                local f = ctx.rollback_arena.frames[f_idx]
                State.update_simulation(ctx.rts_grid, t, f, 8)
                
                -- [FIX]: Proper Hash Chaining with baseline seed 0
                local h_terrain = net.HashState(ctx.rts_grid.terrain, bytes_terrain, 0)
                f.state_checksum = net.HashState(ctx.rts_grid.elevation, bytes_elevation, h_terrain)
                
                ffi.copy(ctx.snapshot_ring.terrain[f_idx], ctx.rts_grid.terrain, bytes_terrain)
                ffi.copy(ctx.snapshot_ring.elevation[f_idx], ctx.rts_grid.elevation, bytes_elevation)
            end
            ctx.rollback_arena.is_rollback_active = 0
        end
        
        if ctx.sim_tick_count <= remote_highest + 4 then
            State.update_simulation(ctx.rts_grid, ctx.sim_tick_count, frame, 8)
            
            -- [FIX]: Proper Hash Chaining with baseline seed 0
            local h_terrain = net.HashState(ctx.rts_grid.terrain, bytes_terrain, 0)
            frame.state_checksum = net.HashState(ctx.rts_grid.elevation, bytes_elevation, h_terrain)
            
            ffi.copy(ctx.snapshot_ring.terrain[c_idx], ctx.rts_grid.terrain, bytes_terrain)
            ffi.copy(ctx.snapshot_ring.elevation[c_idx], ctx.rts_grid.elevation, bytes_elevation)
            
            ctx.sim_tick_count = ctx.sim_tick_count + 1

            local conf_tick = ctx.rollback_arena.confirmed_tick
            local sweep_start = math.max(0, conf_tick - 60)

            for v_tick = sweep_start, conf_tick do
                local v_idx = bit.band(v_tick, 127)
                local v_frame = ctx.rollback_arena.frames[v_idx]

                if v_frame.tick == v_tick and v_frame.state_checksum ~= 0 and v_frame.remote_checksum ~= 0 then
                    if v_frame.state_checksum ~= v_frame.remote_checksum then
                        print(string.format("[FATAL DESYNC] Tick: %d | Local: 0x%08X | Remote: 0x%08X", v_tick, v_frame.state_checksum, v_frame.remote_checksum))
                        os.exit(1)
                    end
                end
            end
        end
        
        ctx.accumulator = ctx.accumulator - FIXED_DT
    end
end

return FSM
