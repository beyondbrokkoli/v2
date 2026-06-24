-- lua/registry_export.lua
local structs_mod = require("structs")

local cfg_gfx = nil
pcall(function() cfg_gfx = require("config_gfx") end)

local cfg_sim = nil
pcall(function() cfg_sim = require("config_sim") end)

-- [NEW] Fetch the network config
local cfg_net = nil
pcall(function() cfg_net = require("config_net") end)

local reg = nil
pcall(function() reg = require("registry_vk") end)

local function enforce_strict_invariants(specs)
    print(" |- [HARNESS] Running Invariant Asserts...")
    local found_structs = {}

    for _, struct in ipairs(specs) do
        found_structs[struct.name] = struct
    end

    -- 1. MULTI-TENANT MULTIPLEXER ASSERTIONS
    local rt_init = found_structs["RenderThreadInit"]
    assert(rt_init, "[FATAL] Gremlin removed RenderThreadInit!")

    local wsi_found = false
    local swapchain_arr_found = false
    for _, m in ipairs(rt_init.members) do
        if m.name == "swapchain" and m.type == "VkSwapchainKHR" then wsi_found = true end
        if m.name == "swapchain_images" and m.count == 10 then swapchain_arr_found = true end
    end
    assert(wsi_found, "[FATAL INVARIANT] RenderThreadInit is missing the Vulkan Swapchain pointer. Multi-tenant WSI isolation broken!")
    assert(swapchain_arr_found, "[FATAL INVARIANT] RenderThreadInit swapchain_images array missing or count modified!")

    -- 2. RENDER PACKET ROUTING ASSERTIONS
    local r_packet = found_structs["RenderPacket"]
    assert(r_packet, "[FATAL] Gremlin removed RenderPacket!")

    local target_win_found = false
    for _, m in ipairs(r_packet.members) do
        if m.name == "target_window_id" and m.type == "uint32_t" then target_win_found = true end
    end
    assert(target_win_found, "[FATAL INVARIANT] RenderPacket is missing 'target_window_id'. Render multiplexing will bleed between OS windows!")
    assert(r_packet.force_align and r_packet.align == 64, "[FATAL INVARIANT] RenderPacket must be strictly 64-byte aligned for lock-free ring buffer cache-line efficiency!")

    -- 3. DETERMINISTIC NETCODE ASSERTIONS
    local lockstep = found_structs["LockstepPacket"]
    assert(lockstep, "[FATAL] Gremlin removed LockstepPacket!")
    assert(lockstep.wire_format == true, "[FATAL INVARIANT] LockstepPacket lost its wire_format flag! Struct padding will cause a deterministic desync!")
    assert(lockstep.align == 1, "[FATAL INVARIANT] LockstepPacket alignment altered. Must be 1-byte packed for network transmission!")

    print(" |- [HARNESS] All system-critical invariants passed.")
end

local function get_sorted_keys(t)
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys)
    return keys
end

local function map_glsl_type(type_str)
    if type_str == "float" then return "float" end
    if string.find(type_str, "mat4") then return "mat4" end
    return "uint"
end

local function generate_ssot(glsl_path, c_header_path)
    -- [NEW] Run the assert floodgate first!
    enforce_strict_invariants(structs_mod.specs)

    local glsl = io.open(glsl_path, "w")
    local c_hdr = io.open(c_header_path, "w")

    -- 1. HEADERS
    glsl:write("// AUTO-GENERATED SSoT - DO NOT MODIFY\n")
    glsl:write("#ifndef REGISTRY_GLSL\n#define REGISTRY_GLSL\n\n")
    c_hdr:write("// AUTO-GENERATED SSoT - DO NOT MODIFY\n")
    c_hdr:write("#pragma once\n#include <stdint.h>\n\n")

    glsl:write("// --- CONSTANTS ---\n")
    c_hdr:write("// --- ENGINE CONSTANTS ---\n")

    -- 2A. EXPORT PRESENTATION MODES (From Domain B: Graphics)
    if cfg_gfx and cfg_gfx.mode then
        for _, k in ipairs(get_sorted_keys(cfg_gfx.mode)) do
            glsl:write(string.format("const uint MODE_%s = %dU;\n", string.upper(k), cfg_gfx.mode[k]))
            c_hdr:write(string.format("#define MODE_%s %d\n", string.upper(k), cfg_gfx.mode[k]))
        end
    end

    -- 2B. EXPORT NETWORK SIMULATION STATES (From Engine Memory Domain)
    if cfg_net and cfg_net.net_state then
        for _, k in ipairs(get_sorted_keys(cfg_net.net_state)) do
            c_hdr:write(string.format("#define FRAME_STATE_%s %d\n", string.upper(k), cfg_net.net_state[k]))
        end
    end

    -- 2C. EXPORT DIMENSIONAL MANIFESTO VALUES (From Domain A: Simulation)
    if cfg_sim and cfg_sim.world then
        for _, k in ipairs(get_sorted_keys(cfg_sim.world)) do
            local val = cfg_sim.world[k]
            if type(val) == "number" then
                if math.floor(val) == val then
                    glsl:write(string.format("const uint WORLD_%s = %dU;\n", string.upper(k), val))
                    c_hdr:write(string.format("#define WORLD_%s %d\n", string.upper(k), val))
                else
                    glsl:write(string.format("const float WORLD_%s = %.1f;\n", string.upper(k), val))
                    c_hdr:write(string.format("#define WORLD_%s %.1ff\n", string.upper(k), val))
                end
            end
        end
    end
    c_hdr:write("\n")

    -- 3. INTERLOCKING ALIGNMENT REGISTRY
    local dynamic_sizes = {
        float = 4, uint32_t = 4, int32_t = 4,
        uint64_t = 8, int64_t = 8,
        uint16_t = 2, int16_t = 2,
        uint8_t = 1, int8_t = 1
    }

    local function resolve_member_size(type_str)
        if dynamic_sizes[type_str] then return dynamic_sizes[type_str] end
        if string.find(type_str, "*") then return 8 end
        if string.find(type_str, "64") then return 8 end
        if string.find(type_str, "32") or type_str == "float" then return 4 end
        if string.find(type_str, "16") then return 2 end
        if string.find(type_str, "8") then return 1 end

        -- [NEW] Sync the C-Generator to recognize native Vulkan handles as 8 bytes
        if string.sub(type_str, 1, 2) == "Vk" then return 8 end
        if string.sub(type_str, 1, 4) == "PFN_" then return 8 end

        return dynamic_sizes[type_str] or 64
    end

    glsl:write("\n// --- std430 SSBO DEFINITIONS ---\n")
    c_hdr:write("// --- ENGINE MEMORY STRUCTURES ---\n")

    for _, struct in ipairs(structs_mod.specs) do
        local is_glsl = not struct.c_only and not struct.wire_format

        if struct.vk_shield then c_hdr:write("#ifdef VX_ENABLE_VULKAN_STRUCTS\n") end

        if struct.wire_format then
            c_hdr:write("#pragma pack(push, 1)\n")
            c_hdr:write(string.format("typedef struct {\n"))
        else
            local safe_align = struct.align or 8
            local attr = struct.force_align and string.format("__attribute__((aligned(%d)))", safe_align) or ""
            c_hdr:write(string.format("typedef struct %s {\n", attr))
        end

        if is_glsl then glsl:write(string.format("struct %s {\n", struct.name)) end

        -- THE MAGIC: We just blindly iterate. No math required!
        for _, m in ipairs(struct.members) do
            local arr_str = ""
            if type(m.count) == "table" then
                for _, dim in ipairs(m.count) do arr_str = arr_str .. string.format("[%d]", dim) end
            elseif m.count then
                arr_str = string.format("[%d]", m.count)
            end

            c_hdr:write(string.format("    %s %s%s;\n", m.type, m.name, arr_str))

            if is_glsl then
                if m.is_pad then
                    glsl:write(string.format("    // Engine injected pad: %s[%s]\n", m.type, tostring(m.count)))
                else
                    local glsl_type = map_glsl_type(m.type)
                    glsl:write(string.format("    %s %s%s;\n", glsl_type, m.name, arr_str))
                end
            end
        end

        if struct.wire_format then
            c_hdr:write("} " .. struct.name .. ";\n#pragma pack(pop)\n\n")
        else
            c_hdr:write("} " .. struct.name .. ";\n\n")
        end

        if struct.vk_shield then c_hdr:write("#endif // VX_ENABLE_VULKAN_STRUCTS\n\n") end
        if is_glsl then glsl:write("};\n\n") end
    end

    glsl:write("#endif // REGISTRY_GLSL\n")
    glsl:close()
    c_hdr:close()

    print("[LUA SSOT] Dual-Domain Architecture SSoT Generated successfully.")
end

return { generate = generate_ssot }
