// AUTO-GENERATED SSoT - DO NOT MODIFY
#ifndef REGISTRY_GLSL
#define REGISTRY_GLSL

// --- CONSTANTS ---
const uint MODE_DUAL = 0U;
const uint MODE_GEOM = 1U;
const uint MODE_POINT_CLOUD_PASS = 88U;
const uint MODE_POINTS = 2U;
const uint WORLD_GRID_CELLS = 262144U;
const uint WORLD_MAP_HEIGHT = 256U;
const uint WORLD_MAP_WIDTH = 256U;
const uint WORLD_OFFSET_X = 2560U;
const uint WORLD_OFFSET_Z = 2560U;
const uint WORLD_SPACING = 20U;

// --- std430 SSBO DEFINITIONS ---
struct mat4_t {
    float m[16];
};

struct RtsTileInstance {
    float px;
    float py;
    float pz;
    uint tile_data;
};

struct PushConstants {
    mat4 viewProj;
    uint aos_current_idx;
    uint aos_prev_idx;
    float dt;
    float total_time;
    uint target_state;
    uint hover_idx;
    uint flags;
    // Tail padded by 4 bytes
};

struct NetworkFrame {
    uint tick;
    uint state;
    // Engine injected 3 pad bytes for std430
    uint state_checksum;
    uint remote_checksum;
    uint remote_peer_id;
    // Engine injected 7 pad bytes for std430
    uint commands[8][2];
};

struct RollbackBuffer {
    uint head_tick;
    uint confirmed_tick;
    uint is_rollback_active;
    // Engine injected 3 pad bytes for std430
    uint rollback_target;
    // Engine injected 136 pad bytes for std430
    uint frames[512];
    // Tail padded by 40 bytes
};

#endif // REGISTRY_GLSL
