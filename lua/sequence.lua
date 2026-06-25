local ffi = require("ffi")
local reg = require("registry_vk")
local manifest = require("pipeline_manifest")
local WindowAPI = require("window_api")
local EngineAPI = require("engine_api")

local SequenceModule = {}

function SequenceModule.init(app_ctx)
    local cfg_gfx = app_ctx.cfg_gfx
    local map_grid_cells = app_ctx.cfg_sim.world.grid_cells

    local seq = {}

    seq.boot = {
        {
            name = "Vulkan Instance",
            action = function(ctx)
                local vulkan = require("vulkan_core")
                ctx.vk_runtime = vulkan.create_instance(reg.vk_reqs.instance_ext, cfg_gfx.cfg)
                EngineAPI.publish_instance(ctx.win_id, ctx.vk_runtime.instance)
            end
        },
        {
            name = "GLFW Window Boot",
            action = function(ctx)
                print("[WEAVER] Ordering C-Core to Boot GLFW Window...")
                WindowAPI.boot(ctx.win_id, cfg_gfx.win.w, cfg_gfx.win.h)
                return "AWAIT_SURFACE"
            end
        },
        {
            name = "Vulkan Logical Device",
            action = function(ctx)
                local vulkan = require("vulkan_core")
                local surface_ptr = WindowAPI.get_surface(ctx.win_id)
                vulkan.finalize_device_and_swapchain(ctx.vk_runtime, surface_ptr, reg.vk_reqs.device_ext)
            end
        },
        {
            name = "Memory Arenas Allocation",
            action = function(ctx)
                local memory = require("memory")
                print("[WEAVER] Booting DMA Engine & VRAM Allocator...")
                memory.InitTransferSubsystem(ctx.vk_runtime)

                local grid_bytes = map_grid_cells * 16
                local gpu_bytes = math.floor(grid_bytes * 8 * 1.1)
                memory.CreateHostVisibleBuffer("MASTER_GPU_BLOCK", "uint8_t", gpu_bytes, 416, ctx.vk_runtime)
                memory.CreateHostVisibleBuffer("MASTER_INDEX_BLOCK", "uint32_t", map_grid_cells * 6, 320, ctx.vk_runtime)
                memory.CreateHostVisibleBuffer("PALETTE_STAGING", "float", 4096, 1, ctx.vk_runtime)
                memory.CreateBufferHaven("PALETTE_HAVEN", 16384, 384, ctx.vk_runtime)
                print("[WEAVER] Strict VRAM Mapping Complete.")
            end
        },
        {
            name = "Swapchain Initialization",
            action = function(ctx)
                local swapchain = require("swapchain")
                ctx.sc_state = swapchain.Init(ctx.vk_runtime.vk, ctx.vk_runtime, cfg_gfx.win.w, cfg_gfx.win.h, ctx.old_swapchain)
            end
        },
        {
            name = "Descriptors Matrix",
            action = function(ctx)
                local descriptors = require("descriptors")
                local memory = require("memory")
                local master_gpu_buffer = memory.Buffers["MASTER_GPU_BLOCK"]
                local palette_haven_buffer = memory.Buffers["PALETTE_HAVEN"]
                ctx.desc_state = descriptors.Init(ctx.vk_runtime.vk, ctx.vk_runtime.device, master_gpu_buffer, palette_haven_buffer, cfg_gfx.cfg)
            end
        },
        {
            name = "Compute Graph Pipelines",
            action = function(ctx)
                local compute = require("compute_pipeline")
                local layout = ctx.desc_state.pipelineLayout
                ctx.comp_state = compute.Init(ctx.vk_runtime.vk, ctx.vk_runtime.device, layout, manifest.compute)
            end
        },
        {
            name = "Graphics Pipelines",
            action = function(ctx)
                local graphics = require("graphics_pipeline")
                local layout = ctx.desc_state.pipelineLayout
                local colorFormat = ctx.sc_state.format
                -- UPDATED: Removed width/height arguments
                ctx.gfx_state = graphics.Init(ctx.vk_runtime.vk, ctx.vk_runtime, layout, colorFormat, manifest.graphics)
            end
        },
        {
            name = "Renderer Synchronization",
            action = function(ctx)
                local renderer = require("renderer")
                ctx.sync_state = renderer.InitSync(ctx.vk_runtime.vk, ctx.vk_runtime.device, cfg_gfx.cfg.frame_slots)
            end
        },
        {
            name = "Async Overlord Handoff",
            action = function(ctx)
                print("[WEAVER] Packing C-Core Mailbox and firing Render Thread...")
                -- UPDATED: Use abstracted WSI handoff function
                app_ctx.register_tenant(ctx.win_id, ctx.vk_runtime, ctx.sc_state, ctx.sync_state, cfg_gfx.cfg.frame_slots)

                EngineAPI.setup_transfer(ctx.vk_runtime.tIndex)
                EngineAPI.start_thread()
                print("[WEAVER] Engine Initialization Complete. Async Overlord is LIVE.")
            end
        }
    }

    seq.resize = { seq.boot[5], seq.boot[8], seq.boot[9] }

    return seq
end

return SequenceModule
