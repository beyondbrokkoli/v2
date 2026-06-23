local ffi = require("ffi")
local cfg_net = require("config_net")
local M = {}

local struct_sizes = {
    float = 4, uint32_t = 4, int32_t = 4,
    uint64_t = 8, int64_t = 8,
    uint16_t = 2, int16_t = 2,
    uint8_t = 1, int8_t = 1
}

local function get_base_size(type_str)
    if struct_sizes[type_str] then return struct_sizes[type_str] end
    if string.find(type_str, "*") then return 8 end
    if string.find(type_str, "64") then return 8 end
    if string.find(type_str, "32") or type_str == "float" then return 4 end
    if string.find(type_str, "16") then return 2 end
    if string.find(type_str, "8") then return 1 end

    -- [NEW] Map native Vulkan handles and function pointers to 8 bytes
    if string.sub(type_str, 1, 2) == "Vk" then return 8 end
    if string.sub(type_str, 1, 4) == "PFN_" then return 8 end

    error("[FATAL] Unknown type size requested in SSoT Generator: " .. tostring(type_str))
end

M.specs = {
    -- GRAPHICS & VULKAN MEMORY DOMAIN
    {
        name = "RenderThreadInit",
        c_only = true,
        vk_shield = true, -- Flags the SSoT generator to wrap this in the macro
        members = {
            { type = "VkDevice", name = "device" },
            { type = "VkQueue", name = "queue" },
            { type = "VkQueue", name = "transfer_queue" },
            { type = "VkSwapchainKHR", name = "swapchain" },
            { type = "uint64_t", name = "swapchain_images", count = 10 },
            { type = "uint64_t", name = "swapchain_views", count = 10 },
            { type = "VkSemaphore", name = "image_available", count = 10 },
            { type = "VkSemaphore", name = "render_finished", count = 10 },
            { type = "VkFence", name = "in_flight", count = 10 },
            { type = "void*", name = "vkWaitForFences" },
            { type = "void*", name = "vkAcquireNextImageKHR" },
            { type = "void*", name = "vkResetFences" },
            { type = "void*", name = "vkQueueSubmit" },
            { type = "void*", name = "vkQueuePresentKHR" },
            { type = "void*", name = "pfnBegin" },
            { type = "void*", name = "pfnEnd" },
            { type = "void*", name = "pfnSetCullMode" },
            { type = "void*", name = "pfnSetFrontFace" },
            { type = "void*", name = "pfnSetPrimitiveTopology" },
            { type = "void*", name = "pfnSetDepthTestEnable" },
            { type = "void*", name = "pfnSetDepthWriteEnable" },
            { type = "void*", name = "pfnSetDepthCompareOp" }
        }
    },
    {
        name = "mat4_t", align = 16,
        members = { { type = "float", name = "m", count = 16 } }
    },
    {
        name = "RtsTileInstance", align = 16,
        members = {
            { type = "float", name = "px" },
            { type = "float", name = "py" },
            { type = "float", name = "pz" },
            { type = "uint32_t", name = "tile_data" }
        }
    },
    {
        name = "PushConstants", align = 16,
        members = {
            { type = "mat4_t",   name = "viewProj" },
            { type = "uint32_t", name = "aos_current_idx" },
            { type = "uint32_t", name = "aos_prev_idx" },
            { type = "float",    name = "dt" },
            { type = "float",    name = "total_time" },
            { type = "uint32_t", name = "target_state" },
            { type = "uint32_t", name = "hover_idx" },
            { type = "uint32_t", name = "flags" }
        }
    },
    {
        name = "DrawCommand", c_only = true, align = 8,
        members = {
            { type = "uint64_t", name = "pipeline_id" },
            { type = "uint64_t", name = "descriptor_set" },
            { type = "uint32_t", name = "index_count" },
            { type = "uint32_t", name = "instance_count" },
            { type = "uint32_t", name = "first_index" },
            { type = "int32_t",  name = "vertex_offset" },
            { type = "uint32_t", name = "first_instance" },
            { type = "uint16_t", name = "pc_offset" },
            { type = "uint16_t", name = "pc_size" },
            { type = "uint8_t",  name = "push_constants", count = 128 },
            { type = "int16_t",  name = "scissor_x" },
            { type = "int16_t",  name = "scissor_y" },
            { type = "uint16_t", name = "scissor_w" },
            { type = "uint16_t", name = "scissor_h" },
            { type = "uint8_t",  name = "cull_mode" },
            { type = "uint8_t",  name = "depth_test" },
            { type = "uint8_t",  name = "depth_write" },
            { type = "uint8_t",  name = "depth_compare_op" },
            { type = "uint8_t",  name = "front_face" },
            { type = "uint8_t",  name = "topology" }
        }
    },
    {
        name = "RenderPacket", c_only = true, align = 64, force_align = true,
        members = {
            { type = "DrawCommand*", name = "draw_queue" },
            { type = "uint32_t", name = "draw_count" },
            { type = "uint64_t", name = "gfx_layout" },
            { type = "uint64_t", name = "vertex_buffer" },
            { type = "uint64_t", name = "index_buffer" },
            { type = "uint64_t", name = "swapchain_image" },
            { type = "uint64_t", name = "swapchain_view" },
            { type = "uint64_t", name = "depth_image" },
            { type = "uint64_t", name = "depth_view" },
            { type = "uint32_t", name = "width" },
            { type = "uint32_t", name = "height" }
        }
    },

    -- ==========================================
    -- LOCKSTEP NETWORKING DOMAIN
    -- ==========================================
    {
       name = "PlayerCommand", align = 1, force_align = true, wire_format = true,
       members = {
            { type = "uint8_t",  name = "opcode" },
            { type = "uint8_t",  name = "flags" },
            { type = "uint16_t", name = "target_id" },
            { type = "uint32_t", name = "target_pos" }
        }
    },
    {
        name = "LockstepPacket", align = 1, wire_format = true, force_align = true,
        members = {
            { type = "uint64_t", name = "session_token" },
            { type = "uint32_t", name = "frame_tick" },
            { type = "uint32_t", name = "checksum_tick" },
            { type = "uint32_t", name = "state_checksum" },
            { type = "uint32_t", name = "base_tick" },
            { type = "uint8_t",  name = "player_id" },
            { type = "uint8_t",  name = "history_count" },
            { type = "uint16_t", name = "_align_pad" },
            { type = "uint32_t", name = "peer_acks", count = cfg_net.MAX_PLAYERS },
            { type = "PlayerCommand", name = "commands", count = { cfg_net.HISTORY_LEN, 2 } }
        }
    },
    {
        name = "NetworkFrame", align = 4, force_align = true,
        members = {
            { type = "uint32_t", name = "tick" },
            { type = "uint8_t",  name = "state" },
            { type = "uint32_t", name = "state_checksum" },
            { type = "uint32_t", name = "remote_checksum" },
            { type = "uint8_t",  name = "remote_peer_id" },
            { type = "PlayerCommand", name = "commands", count = { cfg_net.MAX_PLAYERS, 2 } }
        }
    },
    {
        name = "RollbackBuffer", align = 64, force_align = true,
        members = {
            { type = "uint32_t", name = "head_tick" },
            { type = "uint32_t", name = "confirmed_tick" },
            { type = "uint8_t",  name = "is_rollback_active" },
            { type = "uint32_t", name = "rollback_target" },
            { type = "NetworkFrame", name = "frames", count = cfg_net.RING_SIZE }
        }
    },
    {
        name = "RxPacket", c_only = true, align = 2,
        members = {
            { type = "uint16_t", name = "len" },
            { type = "uint8_t", name = "data", count = 2048 }
        }
    },
}

-- Code Generation and FFI Binding Setup
local cdef_builder = ""
for _, struct in ipairs(M.specs) do
    local attr = struct.force_align and "__attribute__((packed, aligned("..struct.align..")))" or "__attribute__((packed))"
    cdef_builder = cdef_builder .. string.format("typedef struct %s {\n", attr)

    local offset = 0
    local pad_id = 0

    for _, m in ipairs(struct.members) do
        local m_size = get_base_size(m.type)

        -- C-Side Padding for FFI sync (Disabled for wire formats)
        if not struct.wire_format then
            local rem = offset % m_size
            if rem ~= 0 then
                local pad_bytes = m_size - rem
                cdef_builder = cdef_builder .. string.format("    uint8_t _pad_%d[%d];\n", pad_id, pad_bytes)
                offset = offset + pad_bytes
                pad_id = pad_id + 1
            end
        end

        -- Array Generation
        local arr = ""
        local element_count = 1
        if type(m.count) == "table" then
            for _, dim in ipairs(m.count) do
                arr = arr .. string.format("[%d]", dim)
                element_count = element_count * dim
            end
        elseif m.count then
            arr = string.format("[%d]", m.count)
            element_count = m.count
        end

        -- [NEW] Intercept Vulkan types and map them to void* strictly for Lua's FFI parser.
        -- This prevents the need to load bloated Vulkan headers in the networking backend.
        local ffi_type = m.type
        if string.sub(ffi_type, 1, 2) == "Vk" or string.sub(ffi_type, 1, 4) == "PFN_" then
            ffi_type = "void*"
        end

        cdef_builder = cdef_builder .. string.format(" %s %s%s;\n", ffi_type, m.name, arr);

        local real_size = m_size * element_count
        if struct_sizes[m.type] then
            real_size = struct_sizes[m.type] * element_count
        end
        offset = offset + real_size
    end

    if not struct.wire_format then
        -- [NEW] Fallback to 8-byte standard C ABI alignment if omitted
        local safe_align = struct.align or 8

        local tail_rem = offset % safe_align
        if tail_rem ~= 0 then
            local tail_pad = safe_align - tail_rem
            cdef_builder = cdef_builder .. string.format("    uint8_t _pad_tail[%d];\n", tail_pad)
            offset = offset + tail_pad
        end
    end

    cdef_builder = cdef_builder .. "} " .. struct.name .. ";\n\n"
    struct_sizes[struct.name] = offset
end

ffi.cdef(cdef_builder)
return M
