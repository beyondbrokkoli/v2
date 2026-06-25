local ffi = require("ffi")
local bit = require("bit")
local reg = require("registry_vk")
local vk_struct, vk_format, vk_image, vk_layout = reg.vk_struct, reg.vk_format, reg.vk_image, reg.vk_layout
local vk_swapchain, vk_result = reg.vk_swapchain, reg.vk_result

local Swapchain = {}

function Swapchain.Init(vk, core_state, width, height, old_swapchain, explicit_surface)
    print("[SWAPCHAIN] Building the display chain...")
    local surface = explicit_surface or core_state.surface
    local surfaceCaps = ffi.new("VkSurfaceCapabilitiesKHR")
    vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(core_state.physicalDevice, surface, surfaceCaps)

    if surfaceCaps.maxImageExtent.width == 0 or surfaceCaps.maxImageExtent.height == 0 then
        print("[SWAPCHAIN WARNING] Surface extent is 0x0 (Minimized/Transitioning). Aborting rebuild.")
        return nil
    end

    -- FIX: Decouple Swapchain Extent from Logical Extent
    local actualExtent = surfaceCaps.currentExtent
    local scWidth, scHeight = width, height

    -- 1. Swapchain Extent: Must obey currentExtent if it's not 0xFFFFFFFF (Vulkan Spec)
    if actualExtent.width ~= 4294967295 then
        scWidth = math.max(1, tonumber(actualExtent.width))
        scHeight = math.max(1, tonumber(actualExtent.height))
    else
        scWidth = math.max(1, math.max(tonumber(surfaceCaps.minImageExtent.width), math.min(tonumber(surfaceCaps.maxImageExtent.width), width)))
        scHeight = math.max(1, math.max(tonumber(surfaceCaps.minImageExtent.height), math.min(tonumber(surfaceCaps.maxImageExtent.height), height)))
    end

    -- 2. Logical Extent: Strictly aligned with the engine's requested dimensions
    local logicalWidth = math.max(1, math.max(tonumber(surfaceCaps.minImageExtent.width), math.min(tonumber(surfaceCaps.maxImageExtent.width), width)))
    local logicalHeight = math.max(1, math.max(tonumber(surfaceCaps.minImageExtent.height), math.min(tonumber(surfaceCaps.maxImageExtent.height), height)))

    local swapchainInfo = ffi.new("VkSwapchainCreateInfoKHR")
    ffi.fill(swapchainInfo, ffi.sizeof(swapchainInfo))
    swapchainInfo.sType = vk_struct.swapchain_create
    swapchainInfo.surface = surface
    swapchainInfo.oldSwapchain = old_swapchain or ffi.cast("VkSwapchainKHR", 0)
    swapchainInfo.minImageCount = surfaceCaps.minImageCount + 1
    swapchainInfo.imageFormat = vk_format.b8g8r8a8_srgb
    swapchainInfo.imageColorSpace = vk_swapchain.color_space_srgb_nonlinear

    -- Use scWidth/scHeight for the actual Swapchain images
    swapchainInfo.imageExtent.width = scWidth
    swapchainInfo.imageExtent.height = scHeight

    swapchainInfo.imageArrayLayers = 1
    swapchainInfo.imageUsage = vk_image.usage_color_attachment
    swapchainInfo.preTransform = surfaceCaps.currentTransform
    swapchainInfo.compositeAlpha = vk_swapchain.composite_alpha_opaque
    swapchainInfo.presentMode = vk_swapchain.present_mode_fifo
    swapchainInfo.clipped = 1

    local pSwapchain = ffi.new("VkSwapchainKHR[1]")
    local res = vk.vkCreateSwapchainKHR(core_state.device, swapchainInfo, nil, pSwapchain)
    if res == vk_result.error_out_of_date then
        print("[SWAPCHAIN WARNING] Surface volatile. Retrying next frame...")
        return nil
    end
    assert(res == vk_result.success, "FATAL: Failed to create Swapchain! Error: " .. tonumber(res))

    local swapchain = pSwapchain[0]
    local pImageCount = ffi.new("uint32_t[1]")
    vk.vkGetSwapchainImagesKHR(core_state.device, swapchain, pImageCount, nil)
    local imageCount = pImageCount[0]

    local images = ffi.new("VkImage[?]", imageCount)
    vk.vkGetSwapchainImagesKHR(core_state.device, swapchain, pImageCount, images)

    local imageViews = ffi.new("VkImageView[?]", imageCount)
    for i = 0, imageCount - 1 do
        local viewInfo = ffi.new("VkImageViewCreateInfo")
        ffi.fill(viewInfo, ffi.sizeof(viewInfo))
        viewInfo.sType = vk_struct.image_view_create
        viewInfo.image = images[i]
        viewInfo.viewType = vk_image.view_type_2d
        viewInfo.format = vk_format.b8g8r8a8_srgb
        viewInfo.subresourceRange.aspectMask = vk_image.aspect_color
        viewInfo.subresourceRange.levelCount = 1
        viewInfo.subresourceRange.layerCount = 1
        assert(vk.vkCreateImageView(core_state.device, viewInfo, nil, imageViews + i) == vk_result.success)
    end

    -- Allocate Reverse-Z Depth Buffer (Using Logical Extent)
    local dImgInfo = ffi.new("VkImageCreateInfo")
    ffi.fill(dImgInfo, ffi.sizeof(dImgInfo))
    dImgInfo.sType = vk_struct.image_create
    dImgInfo.imageType = vk_image.type_2d

    -- Use logicalWidth/logicalHeight for the Depth Buffer
    dImgInfo.extent.width = logicalWidth
    dImgInfo.extent.height = logicalHeight

    dImgInfo.extent.depth = 1
    dImgInfo.mipLevels = 1
    dImgInfo.arrayLayers = 1
    dImgInfo.format = vk_format.d32_sfloat
    dImgInfo.tiling = vk_image.tiling_optimal
    dImgInfo.initialLayout = vk_layout.undefined
    dImgInfo.usage = vk_image.usage_depth_attachment
    dImgInfo.samples = vk_image.sample_count_1

    local pDepthImage = ffi.new("VkImage[1]")
    assert(vk.vkCreateImage(core_state.device, dImgInfo, nil, pDepthImage) == 0)

    local memReqs = ffi.new("VkMemoryRequirements")
    vk.vkGetImageMemoryRequirements(core_state.device, pDepthImage[0], memReqs)

    local memProperties = ffi.new("VkPhysicalDeviceMemoryProperties")
    vk.vkGetPhysicalDeviceMemoryProperties(core_state.physicalDevice, memProperties)

    local memoryTypeIndex = -1
    for i = 0, memProperties.memoryTypeCount - 1 do
        if bit.band(memReqs.memoryTypeBits, bit.lshift(1, i)) ~= 0 and bit.band(memProperties.memoryTypes[i].propertyFlags, 1) ~= 0 then
            memoryTypeIndex = i
            break
        end
    end

    local dAllocInfo = ffi.new("VkMemoryAllocateInfo", { sType = vk_struct.mem_alloc, allocationSize = memReqs.size, memoryTypeIndex = memoryTypeIndex })
    local pDepthMemory = ffi.new("VkDeviceMemory[1]")
    assert(vk.vkAllocateMemory(core_state.device, dAllocInfo, nil, pDepthMemory) == 0)
    assert(vk.vkBindImageMemory(core_state.device, pDepthImage[0], pDepthMemory[0], 0) == 0)

    local dViewInfo = ffi.new("VkImageViewCreateInfo", {
        sType = vk_struct.image_view_create,
        image = pDepthImage[0],
        viewType = vk_image.view_type_2d,
        format = vk_format.d32_sfloat,
        subresourceRange = { aspectMask = vk_image.aspect_depth, levelCount = 1, layerCount = 1 }
    })
    local pDepthView = ffi.new("VkImageView[1]")
    assert(vk.vkCreateImageView(core_state.device, dViewInfo, nil, pDepthView) == 0)

    print(string.format("[SWAPCHAIN] Created (SC: %dx%d | Logical: %dx%d) with %d images & Depth Buffer!",
        scWidth, scHeight, logicalWidth, logicalHeight, imageCount))

    return {
        handle = swapchain,
        images = images,
        imageViews = imageViews,
        imageCount = imageCount,
        format = vk_format.b8g8r8a8_srgb,
        -- CRITICAL: Return Logical Extent so the engine renders to the intended viewport
        extent = { width = logicalWidth, height = logicalHeight },
        depthImage = pDepthImage[0],
        depthMemory = pDepthMemory[0],
        depthImageView = pDepthView[0]
    }
end

function Swapchain.Destroy(vk, core_state, sc_state)
    print("[TEARDOWN] Destroying Swapchain, Image Views & Depth Buffer...")
    if not sc_state then return end

    for i = 0, sc_state.imageCount - 1 do
        if sc_state.imageViews[i] ~= nil then
            vk.vkDestroyImageView(core_state.device, sc_state.imageViews[i], nil)
        end
    end

    if sc_state.handle ~= nil then
        vk.vkDestroySwapchainKHR(core_state.device, sc_state.handle, nil)
    end

    if sc_state.depthImageView then vk.vkDestroyImageView(core_state.device, sc_state.depthImageView, nil) end
    if sc_state.depthImage then vk.vkDestroyImage(core_state.device, sc_state.depthImage, nil) end
    if sc_state.depthMemory then vk.vkFreeMemory(core_state.device, sc_state.depthMemory, nil) end
end

return Swapchain
