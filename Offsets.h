// Offsets.h — the ONLY file you need to edit.
//
// Every feature in the menu stays disabled ("offset not set") until its
// address/offset below is filled in for YOUR game version.
//
//  * ADDR_*  : STATIC addresses as shown in IDA / Ghidra (example 0x1008A1234).
//              The tweak adds the ASLR slide at runtime. The slide is printed at
//              the top of the menu, so: static = runtime_address - slide.
//  * OFF_*   : byte offsets of a field inside a struct. NOOFF = not set.
//  * 0 / NOOFF / -1 mean "not set". The tweak never writes to unset entries.
//
// IMPORTANT: GTA SA on arm64 is 64-bit, so struct offsets from the 32-bit PC
// version do NOT apply. Find them with a memory scanner (scan float 100 for
// health, change it in game, re-scan...) or by reversing the binary.

#pragma once
#include <stdint.h>

/* ===== do not edit this block ===== */
#define NOOFF 0x7FFFFFFF
typedef struct { uintptr_t base; int n; intptr_t off[4]; } Path;
/* ================================== */

// ---------------------------------------------------------------------------
// 1) Static addresses
// ---------------------------------------------------------------------------
#define ADDR_PLAYER_PED      0x0   // global variable holding the CPlayerPed* of player 1
#define ADDR_MONEY           0x0   // int32 : player money
#define ADDR_MONEY_DISPLAY   0x0   // int32 : money shown on screen (optional but recommended)
#define ADDR_STATS_FLOATS    0x0   // start of CStats float stats array (4 bytes each)
#define ADDR_GRAVITY         0x0   // float : gravity constant (default 0.008)
#define ADDR_TIMESCALE       0x0   // float : game speed (default 1.0)
#define ADDR_CLOCK_HOURS     0x0   // uint8 : in-game hour
#define ADDR_FORCED_WEATHER  0x0   // int16 : forced weather (-1 = none)
#define ADDR_TRAFFIC_MULT    0x0   // float : car density multiplier
#define ADDR_PED_MULT        0x0   // float : pedestrian density multiplier
#define ADDR_CHEATS          0x0   // start of the game's built-in cheat flag array (1 byte each)

// ---------------------------------------------------------------------------
// 2) Struct field offsets
// ---------------------------------------------------------------------------
// Player ped
#define OFF_PED_HEALTH         NOOFF  // float
#define OFF_PED_ARMOR          NOOFF  // float
#define OFF_PED_PHYS_FLAGS     NOOFF  // uint32 physical flags (bullet/fire/explosion/melee proof bits)
#define OFF_PED_PLAYERDATA     NOOFF  // pointer to player data
#define OFF_PLAYERDATA_WANTED  NOOFF  // pointer to wanted-level object (inside player data)
#define OFF_WANTED_LEVEL       NOOFF  // int32 wanted level (inside wanted object)
#define OFF_PLAYERDATA_SPRINT  NOOFF  // float sprint energy (inside player data)
#define OFF_PLAYERDATA_BREATH  NOOFF  // float breath / oxygen (inside player data)
#define OFF_PED_VEHICLE        NOOFF  // pointer to the vehicle the player is in (null on foot)

// Vehicle
#define OFF_VEH_HEALTH         NOOFF  // float
#define OFF_VEH_PHYS_FLAGS     NOOFF  // uint32 physical flags

// Weapons array inside the ped (13 slots)
#define OFF_PED_WEAPONS        NOOFF  // offset of weapon slot 0 inside the ped
#define WEAPON_STRIDE          NOOFF  // size of one weapon slot
#define WEAPON_TYPE_OFF        NOOFF  // int32 weapon type inside a slot
#define WEAPON_AMMO_OFF        NOOFF  // int32 total ammo inside a slot

// Bit masks inside the physical flags (0 = feature disabled)
#define MASK_PED_INVINCIBLE    0x0
#define MASK_VEH_PROOF         0x0

// Stat indices (standard SA numbering — verify against your build)
#define STAT_FAT        21
#define STAT_STAMINA    22
#define STAT_MUSCLE     23
#define STAT_MAXHEALTH  24
#define STAT_RESPECT    68

// Built-in cheat flag indices inside the cheat array (-1 = not set)
#define CHEAT_IDX_HOVER      -1
#define CHEAT_IDX_FLYCARS    -1
#define CHEAT_IDX_WATERCARS  -1
#define CHEAT_IDX_HANDLING   -1
#define CHEAT_IDX_AGGRO      -1
#define CHEAT_IDX_RIOT       -1
#define CHEAT_IDX_PEDARMED   -1
#define CHEAT_IDX_GANGS      -1

// ---------------------------------------------------------------------------
// 3) Paths (built from the values above — normally no need to edit)
//    { base, number_of_hops, { off0, off1, ... } }
//    Each hop dereferences a pointer, then adds the next offset.
// ---------------------------------------------------------------------------
#define STATADDR(i)  ((ADDR_STATS_FLOATS) ? (ADDR_STATS_FLOATS) + 4 * (i) : 0)
#define CHEATADDR(i) (((ADDR_CHEATS) && (i) >= 0) ? (ADDR_CHEATS) + (i) : 0)

#define PATH_PLAYER_PED_OBJ    { ADDR_PLAYER_PED, 1, { 0 } }
#define PATH_PLAYER_HEALTH     { ADDR_PLAYER_PED, 1, { OFF_PED_HEALTH } }
#define PATH_PLAYER_ARMOR      { ADDR_PLAYER_PED, 1, { OFF_PED_ARMOR } }
#define PATH_PLAYER_PHYS_FLAGS { ADDR_PLAYER_PED, 1, { OFF_PED_PHYS_FLAGS } }
#define PATH_WANTED_LEVEL      { ADDR_PLAYER_PED, 3, { OFF_PED_PLAYERDATA, OFF_PLAYERDATA_WANTED, OFF_WANTED_LEVEL } }
#define PATH_PLAYER_SPRINT     { ADDR_PLAYER_PED, 2, { OFF_PED_PLAYERDATA, OFF_PLAYERDATA_SPRINT } }
#define PATH_PLAYER_BREATH     { ADDR_PLAYER_PED, 2, { OFF_PED_PLAYERDATA, OFF_PLAYERDATA_BREATH } }

#define PATH_VEH_HEALTH        { ADDR_PLAYER_PED, 2, { OFF_PED_VEHICLE, OFF_VEH_HEALTH } }
#define PATH_VEH_PHYS_FLAGS    { ADDR_PLAYER_PED, 2, { OFF_PED_VEHICLE, OFF_VEH_PHYS_FLAGS } }

#define PATH_MONEY             { ADDR_MONEY, 0, { 0 } }
#define PATH_MONEY_DISPLAY     { ADDR_MONEY_DISPLAY, 0, { 0 } }

#define PATH_STAT_MUSCLE       { STATADDR(STAT_MUSCLE), 0, { 0 } }
#define PATH_STAT_FAT          { STATADDR(STAT_FAT), 0, { 0 } }
#define PATH_STAT_STAMINA      { STATADDR(STAT_STAMINA), 0, { 0 } }
#define PATH_STAT_RESPECT      { STATADDR(STAT_RESPECT), 0, { 0 } }
#define PATH_STAT_MAXHEALTH    { STATADDR(STAT_MAXHEALTH), 0, { 0 } }

#define PATH_GRAVITY           { ADDR_GRAVITY, 0, { 0 } }
#define PATH_TIMESCALE         { ADDR_TIMESCALE, 0, { 0 } }
#define PATH_CLOCK_HOURS       { ADDR_CLOCK_HOURS, 0, { 0 } }
#define PATH_FORCED_WEATHER    { ADDR_FORCED_WEATHER, 0, { 0 } }
#define PATH_TRAFFIC_MULT      { ADDR_TRAFFIC_MULT, 0, { 0 } }
#define PATH_PED_MULT          { ADDR_PED_MULT, 0, { 0 } }
