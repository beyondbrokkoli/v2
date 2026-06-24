-- lua/engine_api.lua
local ffi = require("ffi")
local C = require("core_abi")

local EngineAPI = {}

function EngineAPI.publish_instance(win_id, instance_ptr)
    C.vx_sys_publish_instance(win_id, instance_ptr)
end

function EngineAPI.acquire_render_packet()
    return C.vx_stream_acquire()
end

function EngineAPI.get_render_packet(idx)
    return C.vx_stream_packet(idx)
end

function EngineAPI.commit_render_packet(idx)
    C.vx_stream_commit(idx)
end

function EngineAPI.is_running()
    return C.vx_core_is_running() == 1
end

function EngineAPI.shutdown()
    C.vx_core_shutdown()
end

function EngineAPI.mark_finished()
    C.vx_core_mark_finished()
end

function EngineAPI.kill_thread()
    C.vx_thread_kill()
end

function EngineAPI.init_stream(win_id, wsi_ptr)
    C.vx_stream_init(win_id, wsi_ptr)
end

function EngineAPI.start_thread()
    C.vx_thread_start()
end

function EngineAPI.setup_transfer(q_family_index)
    C.vx_transfer_setup(q_family_index)
end

function EngineAPI.request_transfer(src, dst, size, t_sem, sig_val)
    return C.vx_transfer_request(src, dst, size, t_sem, sig_val)
end

return EngineAPI
