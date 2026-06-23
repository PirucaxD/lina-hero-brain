---@meta
---Lina brain - augmentation companion script. See changelog.md for version history.
---
---Pattern: baseline UCZone Lina stays enabled. This script will add the
---decisions baseline can't make (Phase 0 gaps, see Lina/notes.md Phase 0.F):
---  G1. Proactive burst / R-early commit (baseline is "Only if Lethal").
---  G2. Timed Ethereal-setup sequencing (baseline uses ether as linkbreak only).
---  G3. Fiery Soul stack maintenance + chase-autos + R-first edge cases.
---  + Layer 2 threat-reactive save chain (baseline has none).
---
---Two layers (built in Phase E/F):
---  Layer 1 - aggressive, key-activated, HOLD-only adaptive (TAP stubbed).
---  Layer 2 - defensive, always-on, fires after the framework Dodger.
---
---v0.5.36: header docblock no longer carries a version string or inline
---changelog (drifted from v0.2.0 to v0.5.35). Full history lives in changelog.md.

local Order  = require("lib.order")
local Damage = require("lib.damage")
local Anim   = require("lib.anim")
-- v0.5.50.2: force-clear the require cache for the lib modules before
-- requiring them. Umbrella reloads Lina.lua on script reload but Lua's
-- package.loaded cache persists across reloads, so lib changes (e.g.
-- v0.5.50 catalog ramp model) deployed AFTER an initial brain load
-- never take effect until Dota is fully restarted. v0.5.50 demo log
-- confirmed this: file SHAs matched runtime but compute_arrival_time
-- was using OLD catalog values (speed_source=live_or_fallback instead
-- of live_with_ramp; speed=live instead of avg-during-prep). Clearing
-- package.loaded[*] makes the next require() re-read from disk.
-- Safe because lib modules are pure-data + pure-functions (no stateful
-- globals to lose). Lina is the only consumer at this load site.
if package and package.loaded then
    package.loaded["lib.signal"]      = nil
    package.loaded["lib.target"]      = nil
    package.loaded["lib.threat_data"] = nil
    package.loaded["lib.npc"]         = nil
    package.loaded["lib.dedup"]       = nil
    package.loaded["lib.geometry"]    = nil
    package.loaded["lib.native"]      = nil
    package.loaded["lib.defense"]     = nil
    package.loaded["lib.escape"]      = nil
    package.loaded["lib.item_saves"]  = nil
end
local Signal = require("lib.signal")
local Target = require("lib.target")      -- v0.2.0: IsAlive / NotIllusion / NotClone
local TD     = require("lib.threat_data") -- v0.2.0: category chains + recommended saves
local NPCLib = require("lib.npc")         -- v0.2.0: item / item_ready / has_shard / origin
local Dedup  = require("lib.dedup")       -- v0.2.0: threat-response + anim dedup
local Geometry = require("lib.geometry")  -- v0.3.0: lead-target prediction (offense)
local Native = require("lib.native")      -- v0.4.4: pause native Hit & Run / Orb Walker in combos
local Defense = require("lib.defense")    -- v0.5.0: generic Layer-2 save dispatcher (Tier-2)
local Escape = require("lib.escape")      -- v0.5.57: danger-aware escape destination picker (Phase 5)
local Farm   = require("lib.farm")        -- v0.5.78: stateless farm geometry (line/point AoE optimizers + worth-casting)
local ItemSaves = require("lib.item_saves") -- v0.5.108: hero-agnostic defensive item save bodies
local HeroValue = require("lib.hero_value") -- v0.5.164 D1: per-hero combat-value model (Phase D value-weighting)

local MS = Enum.ModifierState
local UO = Enum.UnitOrder

-- v0.5.46.3 forward declaration: defense_dispatcher is constructed at
-- ~L1853 (Defense.New) but functions defined earlier in the file
-- (state.scan_and_arm_committed_attackers at L797, etc.) reference it.
-- Without a forward declaration the early references resolve to a
-- GLOBAL `defense_dispatcher` (nil) at function-call time, causing
-- silent failures like the v0.5.46.2 demo `commit_attacker_diag |
-- exit=no_dispatcher` that completely disabled the commit-attacker
-- chain. The L1853 line drops its `local` keyword so the assignment
-- targets this forward-declared upvalue instead of shadowing it.
local defense_dispatcher
-- v0.5.47.3 forward declarations: same class of upvalue-capture bug as
-- defense_dispatcher above. v0.5.47.2 demo log L5070-5076:
--
--   [Lua error] C:\Umbrella\scripts\Lina.lua:982: attempt to call a nil
--   value (global 'fs_shard_window_active')
--   stack traceback:
--       Lina.lua:982: in field 'scan_and_arm_committed_attackers'
--
-- fs_shard_window_active is defined at ~L2090, record_save at ~L2099,
-- but state.scan_and_arm_committed_attackers (L797 area) calls both
-- inside its Dispatch invocation. Lua resolved them as nil globals at
-- function-call time; the call crashed the function, no save was issued
-- for the auto-attack commit. User reported: "Target that are commiting
-- to attack lina have response only for skills, auto attacks no" --
-- ROOT CAUSE was the crashed Dispatch, not a chain or arm-time gate.
-- L2090 / L2099 lines drop their `local` keyword to target these
-- forward-declared upvalues instead of shadowing them.
local fs_shard_window_active
local record_save
-- v0.5.99.3 forward declaration: same class again. resolve_live_cast_point is
-- defined at ~L4032 (local function) but on_hard_disable's cast-point arming
-- branch (~L3948) calls it ~84 lines BEFORE that def -> it resolved as a nil global
-- at call time and crashed the 'ult_burst' anim subscriber (v0.5.99.2 demo:
-- "Lina.lua:3948: attempt to call a nil value (global 'resolve_live_cast_point')"
-- x3). The modcreate cast-point paths (handle_lotus_first / handle_threat_on_self
-- at ~L9072/9204) call it AFTER the def so they never crashed -- which is why only
-- the anim path bit. Latent since the v0.5.39 cast-point arming; the demo's ult
-- casts triggered the anim path for the first time. The L4032 line drops its
-- `local` keyword to target this forward-declared upvalue.
local resolve_live_cast_point

-- ThreatData owns these universal Dota-side facts; the consuming logic stays
-- in this hero file (Tier-2 data-only extraction).
local THREATS_ON_SELF       = TD.THREATS_ON_SELF
local ENEMY_BUFF_THREATS    = TD.ENEMY_BUFF_THREATS
local LOTUS_WORTHY_INCOMING = TD.LOTUS_WORTHY_INCOMING
local ABILITY_TO_THREAT     = TD.ABILITY_TO_THREAT
-- v0.5.39 BUG-3: cast-point-armed threat catalog (Sniper Assassinate, Lion
-- Finger, Lina Laguna, AA Ice Blast, OD Sanity Eclipse, Tinker Laser, Zeus
-- Thundergod's, Doom). Consulted by handle_lotus_first / handle_threat_on_self
-- (modifier-create entry) and on_hard_disable (anim entry, via the reverse
-- map built below). See lib/threat_data.lua CAST_POINT_THREATS docblock.
local CAST_POINT_THREATS    = TD.CAST_POINT_THREATS or {}
-- v0.5.39 BUG-3: reverse map ability_name -> { mod, entry } for the anim
-- subscribers. Built once at module load; the catalog is curated (~8
-- entries) so per-call iteration would also be cheap, but the reverse
-- map keeps the on_hard_disable hot path branchless on miss.
local CAST_POINT_BY_ABILITY = {}
for _mod_name, _cp_entry in pairs(CAST_POINT_THREATS) do
    if _cp_entry.ability then
        CAST_POINT_BY_ABILITY[_cp_entry.ability] = { mod = _mod_name, entry = _cp_entry }
    end
end
-- v0.5.35 task Nyx-carapace: offensive-side deflect modifier set. Iterated
-- by target_has_spell_deflect to gate R against spell-reflect targets.
local SPELL_DEFLECT_MODIFIERS = TD.SPELL_DEFLECT_MODIFIERS or {}

-- Forward-declared module state. Telemetry below reads it; the universal
-- fields are assigned just below. Combat-state fields land in Phase E/F.
local state = {}

----------------------------------------------------------------- telemetry --
local LOG = Logger("Lina")

local function v_level()
    if state.menu and state.menu.diag then return state.menu.diag:Get() end
    return 1
end

local function tlog(level, event, kv)
    if level > v_level() then return end
    local parts = { event }
    if kv then
        for k, v in pairs(kv) do
            parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
        end
    end
    local msg = table.concat(parts, " | ")
    if     level == 0 then LOG:error(msg)
    elseif level <= 2 then LOG:info(msg)
    else                   LOG:debug(msg)
    end
end

-- v0.5.24 PERF-01/09/10: file-local boolean refreshed at 1Hz from OnUpdateEx so
-- hot-path level-3 tlog sites can be wrapped `if TLOG3_ENABLED then ... end`,
-- making the kv table literal + uname() args unreachable at default verbosity.
local TLOG3_ENABLED = false

local function uname(e)
    if not e then return "<nil>" end
    -- NPC.GetUnitName throws on a valid-but-non-NPC entity; gate behind IsNPC.
    if Entity.IsNPC(e) then
        local n = NPC.GetUnitName(e)
        if n then return (n:gsub("^npc_dota_hero_", "")) end
    end
    return tostring(e)
end

-- v0.5.36 PERF-13: hoisted from the 1Hz OBS-02 label-refresh gate so we stop
-- allocating a fresh closure every second. UCZone ships :ForceLocalization on
-- Label widgets (Sniper.lua:10548); the other branches stay as graceful
-- fallbacks for any future ABI shift. All wrapped in pcall so an unsupported
-- widget is a silent no-op rather than a throw.
-- v0.5.36 REGRESSION FIX: dropped the `w._lina_set = w.ForceLocalization`
-- bound-setter cache. UCZone Label widgets are userdata with a restrictive
-- __newindex metamethod that throws on arbitrary field assignment - every
-- first-tick call raised `[C]: in metamethod 'newindex'`, the throw was not
-- pcall-wrapped, so the label refresh aborted and lbl_counters / lbl_self
-- went stuck after the v0.5.36 deploy. The hoist (allocation win) is kept;
-- the cached-setter probe is gone.
local function _lbl_set(w, s)
    if not w then return end
    if w.ForceLocalization then pcall(w.ForceLocalization, w, s); return end
    if w.SetText           then pcall(w.SetText,           w, s); return end
    if w.SetName           then pcall(w.SetName,           w, s); return end
    if w.SetValue          then pcall(w.SetValue,          w, s); return end
end

local HERO_KEY = "lina"

-- v0.5.7 E2 (A7/B4/C4): hoisted from line ~2190 to top-of-module so any
-- earlier-file closure (notably the v0.5.6 E4 no_land probe in
-- state.pending_steps_tick) can capture it. Late-declared locals are
-- invisible to closures defined above them; this was the trap that blocked
-- E4 in v0.5.6 and is the structural unblocker for v0.5.7 E3.
local LINA_MENU = "Lina"  -- hero menu name under Heroes > Hero List

-- Lina ability names (KV-verified 2026-05-28; see notes.md Phase 0.A/0.B).
-- FC is granted by Aghs Scepter (IsGrantedByScepter) - gate Ability.GetLevel>0.
-- v0.5.39 P1-DEAD: dropped A.SLOW_BURN / A.COMBUSTION (innate names with zero
-- readers across cast_range_of / ability_ready / ability_mana). Re-add the KV
-- string at the call site when an innate first becomes load-bearing in kill-math.
local A = {
    Q          = "lina_dragon_slave",
    W          = "lina_light_strike_array",
    E          = "lina_fiery_soul",
    R          = "lina_laguna_blade",
    FC         = "lina_flame_cloak",
}

-- v0.5.36 (MAINT-12): KV-fallback cast ranges as a single source of truth.
-- The KV-read primary path in cast_range_of() stays unchanged; these literals
-- are only used when Ability.GetCastRange is missing or returns <= 0. A future
-- rebalance touches one table instead of ~11 scattered numeric literals.
local FALLBACK_RANGES = {
    R        = 750,   -- Laguna Blade
    W        = 700,   -- Light Strike Array
    Q        = 1075,  -- Dragon Slave
    ETHEREAL = 800,   -- item_ethereal_blade
    EUL      = 700,   -- item_cyclone (Eul's)
    WW       = 700,   -- item_wind_waker
}

------------------------------------------------------------------- state ----
-- Universal fields (ported from Sniper.lua; hero-agnostic). Combat-specific
-- fields are added in Phase E (defense) and Phase F (offense).
state.self_npc           = nil
state.menu               = nil
state.last_save_t        = 0
-- v0.5.14 (BL-A3 / E6): dropped state.last_save_target. Mirrors v0.5.13
-- panic_override strip: Lina has no reader (no per-target STARTER_SAVE_SUPPRESS
-- gate like Sniper). v0.5.39 P1-LAST-SAVE-TGT: the orphan dispatcher-side write
-- in lib/defense.lua Dispatcher:MarkFired has been removed in the same patch.
state.last_save_intent   = "-"
state.last_layer1_intent = "-"
state.l1_counter         = 0    -- Layer 1 dispatch count
state.l2_counter         = 0    -- Layer 2 save count
state.abort_counter      = 0    -- R-abort fires
-- v0.5.14 (BL-A3 / E6): dropped state.panic_counter + state.force_counter.
-- Both were Sniper-ported field declarations with no Lina writers or readers
-- (no panic-key handler, no force-commit dispatch path). Same dead-guard
-- pattern as the v0.5.13 panic_override removal.
state.modcreate_counter  = 0    -- OnModifierCreate threat-hit count
state.skip_counter       = 0    -- queue-dedup skip count
state.armed_threats      = {}   -- threat-key -> {caster, threat_mod, eta_speed, eta_trigger}
state.anim_log_dedup     = {}   -- "<caster_idx>:<ability>" -> last_log_time
state.responded_threats  = {}   -- "<caster_idx>:<mod>" -> last_response_time
-- v0.5.14 (BL-A3 / E6): dropped state.reservations + state.displacements.
-- The reservation helpers (Reserve/Consume/Release) and displacement-track
-- writers were never ported from Sniper to Lina; the tables were declared
-- but never read or written by any Lina path. Verified via repo-wide grep:
-- the only matches outside this block live in Sniper.lua.
state.last_save_kind       = nil
state.last_save_threat_mod = nil
state.ANIM_SAVE_OVERRIDES  = {}   -- ability-name -> save chain (populated with the anim map)
state.pending_cast_verify  = nil  -- counter -> {ability, t_check, ...} (cast_verify ground truth)
-- v0.5.26 Item 3 (Laguna cast_verify_double_fail diag fix): prefix ->
-- abort timestamp. Populated by pending_steps_tick at no_land abort, consumed
-- by cast_verify_tick to suppress noisy double_fail emits when the step never
-- actually issued (HR/OW pause held the order). Bounded by combo*short names;
-- entries are checked against a 3s window so staleness self-resolves.
state.recently_aborted_intents = {}
-- v0.5.86 cleanup: removed state.imp_a10_probed_once + the imp_a10_mr_probe
-- diagnostic (the NPC.GetMagicalResist contract is known/stable; dead weight).
-- v0.5.29 task-6-A diag: throttle cursor for the tf_r_value_pick summary
-- tlog. Set to now() each time a picked-target summary fires; gated to ~1Hz
-- to keep default-verbosity log clean during sustained combo holds.
state.tf_r_pick_diag_t = 0
-- Layer 1 (offense, Phase F) constants + state. Adaptive model is HOLD-only
-- (TAP stubbed for Lina). These are consumed by the dispatchers + HOLD
-- detection wired in later increments; the foundation below only defines them.
state.COMBO_TAP_MAX_S           = 0.18  -- release within this = TAP (stubbed)
state.COMBO_CLASSIFY_RADIUS     = 1500  -- enemies in this radius: Starter (1-2) vs TF (3+)
state.LAYER1_COMMIT_WINDOW_R    = 3.0   -- hard lock after an R commit (per target)
state.LAYER1_COMMIT_WINDOW_SEQ  = 1.2   -- v0.5.15 PT-08: bumped 0.4 -> 1.2. The longest non-cyclone step delay is ether_wqr R-step at 1.0s; the 0.4s window expired before that step's own retries finished, so tf_sustain re-dispatched over pending steps from the SAME chain. 1.2s covers the longest realistic non-R chain (the #state.pending_steps gate inside layer1_pending_block / Layer-1 dispatcher picks up the rest).
-- v0.4.5: bounded-spaced per-step re-issue (Sniper model) to out-persist the
-- native Orb Walker ATTACK flood (which has no toggle). Every-frame re-issue
-- restarts the cast wind-up so the spell never phases; spaced retries of a LOST
-- cast only. Counts the first fire as attempt 1.
state.STEP_REISSUE_ATTEMPTS     = 3     -- max issues per step (1 initial + 2 retries)
state.STEP_REISSUE_SPACING      = 0.25  -- min seconds between a step's re-issues
state.STEP_REISSUE_DEADLINE     = 1.5   -- v0.5.15 PT-06: bumped 0.9 -> 1.5. ether_wqr scheduled R-step at 1.0s delay + 0.55s R cast point exceeded 0.9s and aborted legit chains. 1.5s tolerates the longest scheduled non-cyclone step (1.0s) plus a 0.55s cast point with margin.
state.combo_hold_active_mode    = nil   -- "starter" / "tf", latched on hold-start
state.last_layer1_t             = 0     -- last Layer-1 dispatch (throttle cursor)
state.last_layer1_was_r         = false -- last dispatch committed R (3.0s vs 0.4s lock)
state.pending_steps             = {}    -- scheduled combo steps (delay_s deferred)
state.last_r_target             = nil   -- R in flight: target (r_abort_tick)
state.last_r_combo_name         = nil
state.last_r_dispatch_t         = 0
state.last_offense_target       = nil   -- v0.5.163 C2: broad chase-commit stamp (ANY W/Q/R combo step, R-independent)
state.last_offense_dispatch_t   = 0
state.last_r_cast_t             = nil   -- v0.5.5: most recent R cast timestamp (never cleared); used by fs_at_cap to detect the 5s Aghs Shard 12-stack Fiery Soul window. Distinct from last_r_dispatch_t, which r_abort_tick clears on resolve.
state.last_fc_dispatch_t        = 0     -- v0.5.33 FC-B-04: throttle cursor for the Flame Cloak offensive auto-fire. The 25s ability CD prevents a real re-fire within the buff window but Ability.IsReady has a ~1-frame propagation lag at order-resolve time. 1.5s lockout is the cheapest safety net (matches the throttle pattern in state.lina_r_kill_steal_tick).
state.last_tf_tick_t            = 0     -- v0.5.39 BUG-1: timestamp of the previous state.lina_teamfight_tick that reached the post-cluster-gate dispatch region. A gap >= FC_OPENER_REARM_GAP_S (4.0s) classifies the NEXT tick as a new engagement and re-arms state.fc_tf_opener_fired so the TF-opener FC pre-amp can fire once per fight.
state.fc_tf_opener_fired        = false -- v0.5.39 BUG-1: per-engagement latch for the TF-opener FC pre-amp. Set true after the pre-r_worth FC fires; cleared when last_tf_tick_t shows a >=4s gap (new engagement). Also gates the v0.5.33 tf_burst FC block so the second FC commit in one fight is suppressed (FC's 25s CD makes a double-fire pointless and the burst-site FC was the source of the BUG-1 "never fires at engage T=0" miss because r_worth is false at full HP).
state.fc_status_probed          = false -- v0.5.36: one-shot-per-session latch for the fc_status_probe tlog. Flipped true after the first FC offensive dispatch emits its diagnostic payload (Aghs Scepter ownership, FC ability handle/level/cd, ctx ready/active/in_flight). Lets future cast_verify_double_fail FC mysteries be triaged from a default-level log instead of needing instrumented re-runs.
-- v0.5.37 PERF-08: scratch ctx + KV cache slots. scratch_ctx is the
-- single ~25-field table reused across build_layer1_ctx calls (was a
-- fresh alloc 1-2x per starter tick); cleared at the top of each call.
-- fs_cap_base_cached caches the fiery_soul_max_stacks KV read keyed on
-- the live E (Fiery Soul) ability level: the KV only changes on
-- level-up, but compute_fs_state used to pcall GetLevelSpecialValueFor
-- every call. e_level_cached is the version key (Ability.GetLevel is
-- O(1), the prior KV pcall was not).
state.scratch_ctx               = {}
state.fs_cap_base_cached        = nil
state.fs_cap_e_level_cached     = nil
state.native_hr_logged          = false -- native_hr_resolved logged once (lib/native owns pause state)
state.combo_active_until        = 0     -- combo runs until this time; HR stays paused
state.combo_press_t             = nil   -- press-edge timestamp for TAP/HOLD classify
state.combo_hold_active         = false
state.combo_key_was_down        = false
state.dump_key_was_down         = false -- v0.5.15 OBS-08: rising-edge latch for the diagnostics dump bind
state.panic_key_was_down        = false -- v0.5.37 MAINT-05: rising-edge latch for the m.panic_key one-shot panic bind
state.panic_override_until      = 0     -- v0.5.37 MAINT-05: TTL marker; while now() < this value, try_save_self bypasses the layer2 reaction-window throttle so the next eligible save fires immediately. Cleared to 0 on the first successful save dispatch (one-shot consumption). 2.0s panic window matches the tooltip 'force the defense layer to fire its next save immediately' contract without leaving the bypass armed across multiple unrelated incoming threats.
-- v0.5.39 P3-LOW-magic: single source of truth for the reserve-skip / concurrent-penalty
-- thresholds. The defense_dispatcher cfg below (reserve_skip_floor / concurrent_penalty)
-- AND armed_chain_peek's chain-walk both read from these. Keep both consumers in lock-step;
-- changing them apart silently re-opens the v0.5.7 E13 "wait on wrong save's eta_trigger"
-- bug. v0.5.39 M1 makes count_concurrent_threats a single Dispatcher:CountConcurrentExcluding
-- method, but the floor + penalty thresholds themselves still live here as the source.
state.RESERVE_SKIP_FLOOR        = -20
state.CONCURRENT_PENALTY        = 15
-- v0.5.37 PERF-07: per-frame clock sample. Set once at the top of OnUpdateEx
-- and read by tick functions that previously called now() for tick-local
-- comparisons (cast_verify_tick / persistent_threats_tick / pre_face_tick /
-- pending_steps_tick). Trades ~5 GlobalVars.GetCurTime() calls per frame for
-- one. Callbacks outside OnUpdateEx (OnModifierCreate, OnLinearProjectileCreate,
-- anim handlers, OnNpcDying) MUST keep using now() directly: they run on
-- different callback edges at different real-times. Stamp sites inside the
-- swapped tick functions still consume the same now_t variable (now sourced
-- from state.frame_t), which lags real time by a few microseconds vs the prior
-- now() call; consumers compare the stamp against the next frame's frame_t so
-- the semantics are identical.
state.frame_t                   = 0     -- v0.5.37 PERF-07: per-frame now() sample

------------------------------------------------------- helpers + pipeline --
local function now() return GlobalVars.GetCurTime() end

local function dist_to(target)
    local me = state.self_npc
    if not me or not target then return math.huge end
    local a = NPCLib.origin(me)
    local b = NPCLib.origin(target)
    if not a or not b then return math.huge end
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

-- Lina has no charge / multi-slot abilities, so the lookup is the plain
-- named one. Readiness ALWAYS gates on GetLevel>0: lina_flame_cloak is
-- granted by Aghs Scepter, so without scepter NPC.GetAbility returns a
-- handle and IsReady is true on the unlearned slot (HERO_PROMPT lesson 2).
local function find_ability(name)
    local me = state.self_npc
    if not me then return nil end
    return NPC.GetAbility(me, name)
end
local function ability(name) return find_ability(name) end
local function ability_ready(name)
    local a = ability(name)
    return a ~= nil and Ability.GetLevel(a) > 0 and Ability.IsReady(a)
end
-- v0.5.83: handle-taking readiness check (same GetLevel>0 + IsReady semantics
-- as ability_ready, but skips the by-name NPC.GetAbility re-resolve when the
-- caller already holds the handle). The GetLevel>0 guard MUST stay so an
-- unlearned slot (e.g. FC not yet leveled) reads not-ready.
local function ready_from(h)
    return h ~= nil and Ability.GetLevel(h) > 0 and Ability.IsReady(h)
end
-- v0.5.83: per-frame key-state read without allocating a fresh pcall closure
-- each frame. w:IsDown() is identical to w.IsDown(w); pcall guards a missing
-- widget / ABI shift. Replaces the `pcall(function() return w:IsDown() end)`
-- thunk pattern at the five key-tick sites.
local function key_down(w)
    if not w then return false end
    local ok, v = pcall(w.IsDown, w)
    return (ok and v) and true or false
end

-- Queue dedup: never duplicate an order baseline/framework already queued.
local function queue_has_baseline(order_type, ability_h, target_h, unit_h, position)
    local q = Humanizer.GetOrderQueue()
    if not q then return false end
    local ab_idx = ability_h and Entity.GetIndex(ability_h) or 0
    local tg_idx = target_h  and Entity.GetIndex(target_h)  or 0
    local un_idx = unit_h    and Entity.GetIndex(unit_h)    or 0
    for i = 1, #q do
        local e = q[i]
        if e.orderType == order_type then
            local match_unit    = un_idx == 0 or (e.unit and Entity.GetIndex(e.unit) == un_idx)
            local match_ability = ab_idx == 0 or e.abilityIndex == ab_idx
            local match_target  = tg_idx == 0 or e.targetIndex  == tg_idx
            local match_pos     = true
            if position and e.position then
                local dx = (e.position.x or 0) - (position.x or 0)
                local dy = (e.position.y or 0) - (position.y or 0)
                if (dx * dx + dy * dy) > (250 * 250) then match_pos = false end
            end
            if match_unit and match_ability and match_target and match_pos then
                return true
            end
        end
    end
    return false
end

local function queue_snapshot()
    if not Humanizer or not Humanizer.GetOrderQueue then return 0, 0 end
    local q = Humanizer.GetOrderQueue()
    if not q then return 0, 0 end
    local me = state.self_npc
    if not me or not Entity.IsEntity(me) then return #q, 0 end
    local me_idx = Entity.GetIndex(me)
    local self_n = 0
    for i = 1, #q do
        local e = q[i]
        if e.unit and Entity.GetIndex(e.unit) == me_idx then self_n = self_n + 1 end
    end
    return #q, self_n
end

-- All issue helpers route through safe_issue: queue-dedup, then Order.Issue,
-- then schedule a cast_verify (cooldown/charge re-read = ground truth that the
-- engine actually accepted the cast, HERO_PROMPT lesson 58).
local function safe_issue(spec)
    if queue_has_baseline(spec.order_type, spec.ability, spec.target, spec.unit, spec.position) then
        state.skip_counter = state.skip_counter + 1
        tlog(3, "queue_dedup_skip", { intent = spec.intent, order_type = spec.order_type,
            target = spec.target and uname(spec.target) or "-" })
        return false
    end
    local cd_before, charges_before = 0, 0
    if spec.ability and Ability.GetCooldown then cd_before = Ability.GetCooldown(spec.ability) or 0 end
    if spec.ability and Ability.GetCurrentCharges then
        local okc, ch = pcall(Ability.GetCurrentCharges, spec.ability)
        if okc and type(ch) == "number" then charges_before = ch end
    end
    local mana_at_issue = (state.self_npc and NPC.GetMana) and NPC.GetMana(state.self_npc) or 0
    local mana_cost = spec.ability and Ability.GetManaCost and (Ability.GetManaCost(spec.ability) or 0) or 0
    local ok = Order.Issue(spec)
    if ok then
        tlog(1, "issued", { layer = spec.layer, intent = spec.intent, order = spec.order_type,
            target  = spec.target and uname(spec.target) or "-",
            ability = spec.ability and (Ability.GetName(spec.ability) or "?") or "-",
            cd_before = string.format("%.2f", cd_before),
            mana = string.format("%.0f", mana_at_issue), cost = string.format("%.0f", mana_cost) })
        if spec.ability then
            local cast_point = 0
            if Ability.GetCastPoint then
                local okcp, cp = pcall(Ability.GetCastPoint, spec.ability, true)
                if okcp and type(cp) == "number" then cast_point = cp end
            end
            local q_total_at_issue, q_self_at_issue = queue_snapshot()
            state.pending_cast_verify = state.pending_cast_verify or {}
            state.pending_cast_verify_counter = (state.pending_cast_verify_counter or 0) + 1
            state.pending_cast_verify[state.pending_cast_verify_counter] = {
                intent = spec.intent, ability = spec.ability, target = spec.target,
                cd_before = cd_before, charges_before = charges_before,
                t_check = now() + cast_point + 0.4, t_issued = now(),
                ability_name = Ability.GetName(spec.ability) or "?",
                cast_point = cast_point, attempt = 1,
                q_total_at_issue = q_total_at_issue, q_self_at_issue = q_self_at_issue,
            }
        end
    else
        tlog(3, "issue_rejected", { intent = spec.intent })
    end
    return ok
end

local function cast_verify_tick()
    if not state.pending_cast_verify then return end
    -- v0.5.37 PERF-07: tick-local comparisons against state.frame_t (sampled
    -- once at top of OnUpdateEx). Stamp at v.t_check = now_t + 1.0 below uses
    -- the same value; the next frame compares against frame_t so semantics
    -- match. cast_verify_tick is only ever called from OnUpdateEx.
    local now_t = state.frame_t
    for pcv_key, v in pairs(state.pending_cast_verify) do
        local intent = v.intent or "?"
        if now_t >= v.t_check then
            local actual_cd, actual_charges = 0, 0
            if v.ability and Ability.GetCooldown then actual_cd = Ability.GetCooldown(v.ability) or 0 end
            if v.ability and Ability.GetCurrentCharges then
                local okc, ch = pcall(Ability.GetCurrentCharges, v.ability)
                if okc and type(ch) == "number" then actual_charges = ch end
            end
            local cd_bumped = actual_cd > v.cd_before + 0.05
            local charge_consumed = (v.charges_before or 0) > 0 and actual_charges < v.charges_before
            local fired = cd_bumped or charge_consumed
            local tgt_state = "-"
            if v.target then
                tgt_state = (Entity.IsEntity(v.target) and Target.IsAlive(v.target)) and "alive" or "dead"
            end
            -- v0.5.7 E14 (covers C10/C11): demote the happy-path cast_verify
            -- (fired=y) to level 2 so the per-step verify lines from a single
            -- ether_wqr stop burying the archetype-pick decision events at
            -- level 1. The miss path (fired=n) STAYS at level 1: a step that
            -- didn't take cooldown is exactly the kind of correctness signal
            -- default logs need to surface. cast_verify_double_fail just below
            -- is untouched and remains at level 1 by design.
            local cv_level = fired and 2 or 1
            tlog(cv_level, "cast_verify", { intent = intent, ability = v.ability_name,
                fired = fired and "y" or "n", tgt = tgt_state, attempt = tostring(v.attempt or 1),
                cd_before = string.format("%.2f", v.cd_before),
                cd_after = string.format("%.2f", actual_cd),
                age_ms = string.format("%.0f", (now_t - v.t_issued) * 1000) })
            if not fired and (v.attempt or 1) < 2 then
                v.attempt = 2
                v.t_check = now_t + 1.0
            else
                if not fired then
                    -- v0.5.26 Item 3: if the matching pending_step was just
                    -- aborted via reason=no_land (HR/OW pause held the order),
                    -- the abort emit already explained the no-cast. Strip the
                    -- "#try" suffix to recover the abort-site key prefix.
                    local prefix = intent:gsub("#%d+$", "")
                    local aborted_t = state.recently_aborted_intents
                                      and state.recently_aborted_intents[prefix]
                    if aborted_t and (now_t - aborted_t) < 3.0 then
                        tlog(2, "cast_verify_suppressed", { intent = intent,
                            reason = "step_aborted_no_land",
                            dt = string.format("%.2f", now_t - aborted_t) })
                    else
                        local me = state.self_npc
                        tlog(1, "cast_verify_double_fail", { intent = intent, ability = v.ability_name,
                            tgt = tgt_state,
                            silenced = (me and NPC.IsSilenced and NPC.IsSilenced(me)) and "1" or "0",
                            stunned  = (me and NPC.IsStunned  and NPC.IsStunned(me))  and "1" or "0" })
                    end
                end
                state.pending_cast_verify[pcv_key] = nil
            end
        end
    end
end

local function issue_item_self(intent, layer, it)
    return safe_issue { hero = HERO_KEY, layer = layer, intent = intent,
        order_type = UO.DOTA_UNIT_ORDER_CAST_TARGET, unit = state.self_npc,
        ability = it, target = state.self_npc }
end
local function issue_item_target(intent, layer, it, target)
    return safe_issue { hero = HERO_KEY, layer = layer, intent = intent,
        order_type = UO.DOTA_UNIT_ORDER_CAST_TARGET, unit = state.self_npc,
        ability = it, target = target }
end
local function issue_item_position(intent, layer, it, pos)
    return safe_issue { hero = HERO_KEY, layer = layer, intent = intent,
        order_type = UO.DOTA_UNIT_ORDER_CAST_POSITION, unit = state.self_npc,
        ability = it, position = pos }
end
local function issue_item_no_target(intent, layer, it)
    return safe_issue { hero = HERO_KEY, layer = layer, intent = intent,
        order_type = UO.DOTA_UNIT_ORDER_CAST_NO_TARGET, unit = state.self_npc, ability = it }
end
local function issue_cast_notarget(intent, ab, layer)
    return safe_issue { hero = HERO_KEY, layer = layer or "agg", intent = intent,
        order_type = UO.DOTA_UNIT_ORDER_CAST_NO_TARGET, unit = state.self_npc, ability = ab }
end
-- Spell-cast helpers (Phase F): unit-target (R) and position-target (W / Q).
local function issue_cast_target(intent, ab, target, layer)
    return safe_issue { hero = HERO_KEY, layer = layer or "agg", intent = intent,
        order_type = UO.DOTA_UNIT_ORDER_CAST_TARGET, unit = state.self_npc, ability = ab, target = target }
end
local function issue_cast_position(intent, ab, pos, layer)
    -- v0.5.95.3 BUG-W-SELF / BUG-Q-CREEPS guard: a nil aim must DROP the cast --
    -- never reach Order.Issue (the v0.5.4 nil-pos concern) and never be coerced to
    -- a self-position. tf_w_aim / tf_q_aim now return nil when the enemy cluster
    -- evaporates and no r_target remains; starter w_aim / predict_lead_path
    -- likewise return nil for a dead target. Skip + log at level 1 so a demo can
    -- prove the bug path is hit (combo_aim_drop count) and that no self-cast fires.
    if pos == nil then
        tlog(1, "combo_aim_drop", { intent = intent,
            ability = ab and (Ability.GetName(ab) or "?") or "-" })
        return false
    end
    return safe_issue { hero = HERO_KEY, layer = layer or "agg", intent = intent,
        order_type = UO.DOTA_UNIT_ORDER_CAST_POSITION, unit = state.self_npc, ability = ab, position = pos }
end

------------------------------------------------------- save data + chains --
-- 7.41C core build is Aghs + Yasha&Kaya + Blink + Ethereal; Eul (item_cyclone)
-- is NOT core. Wind Waker (19s CD, 2.5s cyclone, strong dispel) tops the chain.
-- v0.5.52.1 (200-locals cleanup): bundled the 10 save-chain tables
-- into a single CH table. Each chain is now CH.<name> instead of
-- local <name>; saves 9 main-chunk local slots. Declarations stay
-- in their original positions so the chain-by-chain commentary still
-- reads top-to-bottom; only the storage form changed.
local CH = {}
CH.DEFAULT_SAVE_CHAIN = {
    "item_wind_waker", "item_cyclone", "item_lotus_orb", "item_manta",
    "item_glimmer_cape", "item_invis_sword", "item_silver_edge",
    "item_hurricane_pike", "item_force_staff",
    "item_black_king_bar",
}

-- Per-modifier AUTHORITATIVE overrides: bypass the generic kind/tether
-- filters so invis escapes (Glimmer / Shadow Blade / Silver Edge) and
-- cyclones fire vs gap-closers, which the lib kind table wrongly excludes
-- (v0.2.1: Glimmer was kind_mismatch'd vs PA blink, and invis was never
-- wired). Order is Lina's preference: instant dispel/invis first,
-- self-displacement last (homing close-gap skips Force/Pike anyway, lesson 5;
-- and Force/Pike push in Lina's facing so they self-refuse vs a faced melee
-- attacker, lesson 61).
CH.GAP_CLOSE_SAVES = {
    "item_wind_waker", "lina_flame_cloak", "item_glimmer_cape",
    "item_invis_sword", "item_silver_edge", "item_black_king_bar",
    -- v0.5.87: item_blink slots after the dispel/lock-break/immunity/full-dodge
    -- primaries (WW dispel, glimmer/invis lock-break, BKB, Eul full-dodge) but
    -- AHEAD of the 600u Force/Pike pushes -- Blink is the best PHYSICAL reposition
    -- (1200u, instant, disjoints, breaks lock). Its .fire self-gates on the
    -- blink-broken (recent-damage) rule and falls through to Force/Pike when
    -- broken, so this placement never strands the chain.
    "item_cyclone", "item_blink", "item_force_staff", "item_hurricane_pike",
    "lina_w_anti_gap",  -- v0.5.44 (DEFENSE_PLAN.md sec 2.1 + Q1): tail position; W fires only when all items above are on CD. High-viability targets: Bara Charge, Bara Nether Strike, Tusk Snowball, MK Primal Spring.
}
-- v0.5.147.x per-skill cast-poll save chains. SEPARATED per skill (user: a fast hook, a
-- slow hook, and a cog-trap want genuinely different saves; keeping them distinct leaves
-- room to tune each + benefits other heroes / future items). The lib owns the per-skill
-- THREAT DATA (category / severity / counter facts); the hero owns the per-skill save
-- ORDERING below. NO Glimmer (invis does not dodge a line) / NO BKB (does not stop a pull).
--
-- Pudge Meat Hook (line_projectile): INSTANT-FIRST. The demo put Pike/Force in a DEAD ZONE for
-- the hook -- when it is far enough that the 600u push would help, you can just WALK out (you
-- have time); when it is close enough that you cannot walk, the push is too short AND the
-- turn-then-push is too slow (Lina stunned mid-cast). So drop them: Blink (instant, no turn,
-- 1200u) breaks the line in the close case + fully dodges the pull; WW/Eul are the harm-negation
-- fallback (they only negate dmg+stun, the pull still lands). NO W (stun, not an escape).
CH.HOOK_INTERCEPT = {
    "item_blink", "item_wind_waker", "item_cyclone",
}
-- Clockwerk Hookshot (fast 4000-6000): AIRBORNE / INSTANT only. The demo proved Pike/Force
-- turn-then-push is too slow for the fast hook (the ~137deg turn-to-aim eats the lead and
-- Lina is stunned mid-cast); WW (instant, no turn) reliably negates the stun. Pike/Force are
-- DROPPED here -- they live under Power Cogs below.
CH.CLOCKWERK_HOOKSHOT = {
    "item_wind_waker", "item_cyclone", "item_blink",
}
-- Clockwerk Power Cogs (NO_TARGET trap, cogs_radius 215): WW/Eul EAT TIME safely (airborne
-- invuln waits out the cog zap + knockback; Eul does not move in air but buys the window),
-- Force/Pike PUSH OUT of the cog box. WW first (instant safe), then the displacement escape.
CH.CLOCKWERK_COGS = {
    "item_wind_waker", "item_force_staff", "item_hurricane_pike", "item_cyclone",
}
local LINA_SAVE_OVERRIDES = {}
for _, m in ipairs({
    "modifier_phantom_assassin_phantom_strike",
    "modifier_phantom_assassin_phantom_strike_target",  -- v0.2.2: the ACTUAL modifier that lands (log-confirmed)
    "modifier_spirit_breaker_charge_of_darkness",
    -- v0.5.136.1: modifier_slark_pounce removed -> resolves the COMPOSED close_gap
    -- chain (lib catalog drives selection; hero only injects W via CH.ABILITY_INJECTIONS).
    "modifier_tusk_snowball_movement",
    "modifier_queenofpain_blink",
    -- v0.5.126: Riki Blink Strike. Riki blinks behind Lina FROM INVISIBILITY,
    -- so OnUnitAnimation never fires (no visible cast) and there is no armed
    -- entry -- it is recognized REACTIVELY when the 0.4s slow debuff lands
    -- (see LINA_EXTRA_THREATS) and routed to the same close-gap escape chain
    -- to break the now-adjacent engage. LATE save by nature (fires after the
    -- strike connects); the escape still breaks the follow-up. Name VPK +
    -- modseen confirmed (modifier_riki_blinkstrike_slow).
    "modifier_riki_blinkstrike_slow",
}) do
    LINA_SAVE_OVERRIDES[m] = CH.GAP_CLOSE_SAVES
end
-- v0.2.2 FIX: also key the override by KV-authoritative ABILITY name.
-- resolve_save_order checks ANIM_SAVE_OVERRIDES[ability] FIRST, so the armed
-- -threat route (which passes entry.ability) gets the authoritative gap-close
-- chain even when the modifier name drifts (PA's modifier is ..._target, not
-- the bare name). This was the v0.2.1 bug: PA fell through to the lib chain
-- (ghost/blademail/blink) and invis (Shadow Blade / Silver Edge) was never
-- reached. Ability names are stable KV; modifier names drift (lesson 111 / 210).
for _, ab in ipairs({
    "phantom_assassin_phantom_strike",
    "spirit_breaker_charge_of_darkness",
    -- v0.5.136.1: slark_pounce removed (composed close_gap; see above)
    "tusk_snowball",
    "queenofpain_blink",
}) do
    state.ANIM_SAVE_OVERRIDES[ab] = CH.GAP_CLOSE_SAVES
end

-- v0.5.2: authoritative save chain for Sniper Assassinate (user note
-- 2026-05-29 + DEMO 3 data). Single-target magical ult; Ethereal-self is
-- DELIBERATELY ABSENT (it amplifies magical damage taken by +30%). The Lotus
-- HP gate (v0.5.2 C) bypasses lotus-worthy threats.
--
-- v0.5.39 BUG-2: chain reordered for the Lotus-defer punishment intent.
-- Lotus heads the chain (reflect = punishment-intent payoff); BKB second as
-- the magic-immune fallback when Lotus is unavailable.
-- v0.5.110.1 (user demo note 1: "pike does not counter assassinate"):
-- Force + Pike REMOVED. Assassinate's projectile CANNOT be disjointed
-- (Liquipedia), so displacement counters nothing -- the v0.5.39 "exits the
-- projectile lock cone" rationale was wrong mechanics, and the v0.5.110
-- demo showed Pike firing a wasted self-turnaway at cp_t=0.50 while the
-- real dodges (Eul/WW invulnerable airborne, fire-in-vain post-launch per
-- v0.5.107) sat behind it in the chain. Order now: Lotus reflect > BKB
-- immunity > Eul/WW full dodges > Glimmer (40% MR) > Aeon (lethal-damage
-- block backstop) > Flame Cloak (35% MR) deep tail. The lotus_defer_if_close
-- gate (grep `local function lotus_defer_if_close`) only commits to this chain
-- after the cooldown-deferral window closes, so the head Lotus slot fires
-- whenever the deferred-fire path armed under the assassinate cast point.
LINA_SAVE_OVERRIDES["modifier_sniper_assassinate"] = {
    "item_lotus_orb",
    "item_black_king_bar",
    -- v0.5.104 (user notes 3+4): Eul self-cast = 2.5s INVULNERABLE airborne,
    -- a clean Assassinate dodge (projectile never connects) on a cheaper CD
    -- than WW. Every other dodge-class chain (Doom / Chrono / BH / Ravage /
    -- the channels) already carried item_cyclone; this chain was the one
    -- omission -- the v0.5.102 demo fell through to BKB (projectile visibly
    -- lands, damage blocked) while Eul sat unused. Before WW so the heavier
    -- save stays the backstop.
    "item_cyclone",
    "item_wind_waker",
    "item_glimmer_cape",
    "lina_flame_cloak",
}
-- v0.5.39 BUG-3: Sniper Assassinate now routes via the lib's CAST_POINT_THREATS
-- table (cp ~2.0s, category=targeted_burst, max_dist=global). The pre-v0.5.39
-- runtime-add to LOTUS_WORTHY_INCOMING is deleted: the new arming branch in
-- handle_threat_on_self fires the save AT END of cast point via the chain head's
-- SAVE_ETA_TRIGGER, which is strictly better than the previous lotus-first
-- snap-fire at modifier-create. LINA_SAVE_OVERRIDES entry retained - consulted
-- by ResolveSaveOrder when the armed entry's category=targeted_burst routes
-- through the dispatcher.

-- v0.5.11 PE-04: hero-tuned authoritative chains for 5 high-frequency channel /
-- persistent threats (ported from Sniper S3 SNIPER_SAVE_OVERRIDES expansion).
-- Pre-port these threats fell through to lib category chains (channel_on_self /
-- drain / lockdown / trap), which apply uniformly without per-threat tuning;
-- the Sniper catalog showed that per-threat ordering closes mis-save gaps the
-- universal-kind chains cannot. ResolveSaveOrder returns is_authoritative=true
-- for any entry present in hero_save_overrides (lib/defense.lua Dispatcher:ResolveSaveOrder hero_override branch), so
-- the TD.SaveCounters (kind_mismatch) and TD.WillTetherBreak (tether_unreachable)
-- filters BYPASS for these chains -- chosen explicitly because user knows the
-- mechanics better than the kind heuristic (see Sniper v6.15.20 design note).
--
-- Modifier names verified against lib/threat_data.lua (lesson 111 / 210). Note:
-- Pudge's canonical key is modifier_pudge_dismember_pull, NOT _dismember --
-- lib/threat_data.lua line 158 / 329 / 933 are all _pull-suffixed, and the
-- _dismember alias was a Sniper-only legacy key from before the v6.15.x
-- normalization. Always use the lib-canonical key here.
--
-- Item substitutions vs Sniper: drop grenade_at_caster / grenade_self / take_aim
-- (hero-specific). Lina has no equivalent fast-stun interrupt for the caster, so
-- the chains lead with displacement / dispel / invuln saves she actually owns.
CH.PUDGE_DISMEMBER  = {
    -- v0.5.15 IMP-A9: WW > Eul > Force/Pike > Manta > BKB. Pudge Dismember is
    -- 200u tether, 0.5s cast point. WW 2.5s cyclone airborne + invuln dispels
    -- and breaks tether trivially. Eul self-cyclone also dispels/displaces and
    -- is the cheapest displacement save, so it fires before Force/Pike (which
    -- still clear the 200u leash via 600/425u self-push when safe_push_destination
    -- passes). Manta (status dispel) and BKB (Dismember is magical, BKB works,
    -- unlike Bane Grip below) as deeper fallbacks before the lib chain would.
    "item_wind_waker",
    "item_cyclone",
    "item_force_staff",
    "item_hurricane_pike",
    "item_manta",
    "item_black_king_bar",
}
CH.PRIMAL_PULVERIZE = {
    -- v0.5.121 (user correction of v0.5.120): Pike/Force are NOT wasted -- they
    -- are cast on PRIMAL BEAST (the caster), not self, to KEEP HIM AWAY (the
    -- Sniper/Drow/Lina pike idiom: distance-keep the threat). The log confirmed
    -- the fire was target=primal_beast (push him off). And per the wiki Pulverize
    -- "ends early if Primal Beast is moved too far" -- so Pike/Force-on-caster
    -- works BOTH pre-grab (target leaves cast range -> grab fizzles) AND
    -- mid-channel (move him too far -> channel breaks). My v0.5.120 removed them
    -- on the wrong premise that "the victim can't be force-moved" (true, but the
    -- save pushes the CASTER, the displacement_at_source counter). So: Pike/Force
    -- lead (keep-away, works both phases, keeps Lina active), WW/Eul self-cyclone
    -- next (airborne+untargetable escape if grabbed / pikes on CD; user's "WW as
    -- escape"). NO BKB (pierces spell immunity). (v0.5.122: dropped the dead
    -- item_aeon_disk tail -- Aeon is a PASSIVE, no .fire, the slot only logged
    -- no_entry; it auto-protects regardless.) Authoritative override (keeps both
    -- the keep-away and the escape; the composed axis had Pike but no WW fallback).
    "item_hurricane_pike",
    "item_force_staff",
    "item_wind_waker",
    "item_cyclone",
}
CH.MARS_ARENA = {
    -- v0.5.123 (demo S4 + Liquipedia): Mars Arena of Blood is a SOLID wall ring.
    -- Force/Pike CANNOT push the victim out (the wall stops forced movement at the
    -- boundary -- demo-confirmed Pike failed), and BKB does NOT escape (it blocks
    -- the spear damage but you stay trapped). The ONLY escapes are airborne
    -- (WW/Eul = invuln + untargetable, lifts you clear of the spear window) or a
    -- Blink past the wall. profile: blocks_forced_movement=true, pierces=false.
    -- So: WW, Eul, Blink. NO Force/Pike/BKB. Authoritative override.
    "item_wind_waker",
    "item_cyclone",
    "item_blink",
}
CH.PRIMAL_ONSLAUGHT = {
    -- v0.5.128.1 (demo: "WW was not used on Onslaught"; user: "WW is instant so
    -- it should be used by proximity like bara charge"): Onslaught is a line DASH
    -- that STUNS + knocks back on impact (KV stun 0.7/1/1.3/1.6, knockback_radius
    -- 190, charge_speed 1200), so a REACTIVE save is impossible (the knockback +
    -- modifier_stunned land together = Lina stunned before any chain casts; both
    -- logged threat_unrecognized). It is handled like Bara charge: ARM on the
    -- dash modifier and fire WW by PROXIMITY (armed_threats_tick eta gate) -- WW
    -- is an INSTANT cast, so firing when the charging Primal closes in lifts Lina
    -- airborne in time. Proximity also gates aim for free: if the dash brings him
    -- close the eta drops and fires; if he charges away the distance never drops.
    -- Same escape set as Mars Arena: WW/Eul are airborne + untargetable (no
    -- knockback/stun applies to a cycloned unit, regardless of position); Blink
    -- repositions clear. NO Force/Pike (push along Lina's facing, lesson 61 /
    -- pike/force keep-away -- for a line dash that is along the corridor,
    -- not out). NO BKB (physical). Authoritative via ANIM_SAVE_OVERRIDES.
    "item_wind_waker",
    "item_cyclone",
    "item_blink",
}
CH.TREANT_OVERGROWTH = {
    -- v0.5.123 (demo S7, user order "WW, BKB, Pike"): Overgrowth is an AoE root.
    -- All three work via DIFFERENT mechanisms, so order them exactly as the user
    -- specified: WW (strong dispel removes the root + airborne), BKB (basic-dispel-
    -- on-cast removes the root -- NOT its immunity, which Overgrowth pierces),
    -- Pike (forced movement relocates a rooted unit OUT of the 800 AoE -- root
    -- blocks self-move/blink but not being moved by another source). Force = Pike's
    -- same-role twin (force-out fallback when Pike is on CD).
    "item_wind_waker",
    "item_black_king_bar",
    "item_hurricane_pike",
    "item_force_staff",
}
CH.BANE_GRIP        = {
    -- WW > Manta > Eul > BKB (user spec). Bane Fiend Grip pierces magic immunity
    -- (Sniper note line 6459), so BKB is a desperate last-resort that does NOT
    -- end the grip itself -- only buys lockdown-state defense vs concurrent
    -- spells. WW first (airborne dispel), Manta second (status dispel pops the
    -- grip), Eul third (cyclone dispel), BKB last as the user spec'd backstop.
    "item_wind_waker",
    "item_manta",
    "item_cyclone",
    "item_black_king_bar",
}
CH.PUGNA_DRAIN      = {
    -- v0.5.132: W (lina_w_anti_gap) HEAD added per the W-interrupt design
    -- (Phase 1c). Pugna Life Drain is a magical CHANNEL (Liquipedia 2026-06-14:
    -- up to 10s, 0.25s ticks; does NOT disable Lina; cast range 700u, link
    -- breaks at 900u). Stunning Pugna interrupts the channel AND sets up a
    -- Laguna kill, so W is the best head (aim = catalog impact_pos=caster ->
    -- stuns Pugna). When W is on CD: Force > Pike-self break the tether by
    -- distance (700u cast + 600/425u self-push exceeds the 900u link-break),
    -- Manta status-dispel pops the link, WW as the heavy backstop. SaveCounters
    -- knows displacement_far / displacement_blink work; authoritative bypass
    -- skips that gate anyway so Lina commits to W-then-displacement.
    "lina_w_anti_gap",
    "item_force_staff",
    "item_hurricane_pike",
    "item_manta",
    "item_wind_waker",
}
CH.LEGION_DUEL      = {
    -- BKB > Manta > Eul > Aeon (user spec). Duel cannot be ended by displacement
    -- (no range limit per Sniper v6.15.16 note line 6601); goal is to survive
    -- the 5s lockdown. BKB grants magic immunity AND blocks the damage_return
    -- attack-only state from being usable against Lina's spells. Manta dispel
    -- breaks the duel attack-only modifier on Lina. Eul cyclones Lina OUT of
    -- attack range -- duel does not break but attack timing resets. Aeon Disk
    -- as the lethal backstop (no SAVE_FIRE entry; chain logs no_entry + skips
    -- harmlessly, matching the Assassinate chain convention).
    "item_black_king_bar",
    "item_manta",
    "item_cyclone",
}
CH.DISRUPTOR_KFR    = {
    -- v0.5.118 user spec: "the correct order is WW, BKB and Pike." Liquipedia
    -- (confirmed this session): Kinetic Field's barrier blocks OUTWARD forced
    -- movement -- "Force Staff will push units INTO it but will NOT normally
    -- push units out" -- so plain Pike/Force is UNRELIABLE; the only
    -- deterministic escape is magic immunity (a spell-immune unit crosses the
    -- field freely). Order: WW first (airborne carries Lina up + over the wall,
    -- strong-dispel), BKB second (magic-immune -> the reliable cross-out, the
    -- counter the old chain was missing entirely), Pike last-ditch (push usually
    -- fails vs the solid wall but fire-and-fail beats no save). Authoritative
    -- bypass keeps this chain from being culled by the displacement SaveCounters
    -- filter.
    "item_wind_waker",
    "item_black_king_bar",
    "item_hurricane_pike",
}

-- v0.5.132 W-interrupt defense (Phase 1): two NEW W-head chains for
-- interruptible AoE casts where (a) stunning/cancelling the caster stops the
-- threat AND (b) Lina is NOT self-disabled, so she is free to cast W.
-- Mechanics Liquipedia-verified 2026-06-14. W = point-AoE stun; it hits the
-- caster regardless of vision (predict_target_pos last-known pos) and the aim
-- resolves to the caster via the lib catalog (THREAT_ARRIVAL_TIMING
-- impact_pos="caster") -- the W_aim_at_caster_mods entries are the belt-and-
-- suspenders fallback, matching the WD Death Ward precedent (CH.WD_DEATH_WARD).
--
-- CM Freezing Field (Phase 1a): magical CHANNEL, up to 10s, 810u field radius
-- (explosions 195-785u). Stun/silence on CM ends the channel; does NOT disable
-- Lina. W HEAD interrupts (saves the whole team -- W still lands on CM's
-- last-known position when she channels from fog). When W is on CD: Blink
-- (1200u) leaves the 810u field, BKB magic-immunes the explosions, Force/Pike
-- push toward the edge, WW/Eul airborne-dodge a 2.5s slice of the ticks.
CH.CM_FREEZING_FIELD = {
    "lina_w_anti_gap",
    "item_blink",
    "item_black_king_bar",
    "item_force_staff",
    "item_hurricane_pike",
    "item_wind_waker",
    "item_cyclone",
}
-- SK Epicenter (Phase 1b): NOT a channel -- a 2.0s CAST POINT (wind-up) before
-- 12-20 magical pulses over 6s (radius 450 -> ~710). Liquipedia: a stun/silence
-- DURING the 2s cast point prevents it executing; once pulses begin nothing
-- stops them. SK is already cast-point-armed (CAST_POINT_THREATS cp_default
-- 2.0) so the armed tick fires the chain head when eta <= SAVE_ETA_TRIGGER(W)
-- 1.20 -> W lands ~1.9s, inside the 2.0s wind-up = cancels Epicenter before any
-- pulse (TIGHT; the demo is the gate for whether W lands in time). W HEAD; else
-- WW/Eul ride a 2.5s slice of the ~6s pulses, Blink leaves the growing radius,
-- Force/Pike partial, BKB magic-immunes the pulses.
CH.SK_EPICENTER = {
    "lina_w_anti_gap",
    "item_blink",
    "item_wind_waker",
    "item_cyclone",
    "item_force_staff",
    "item_hurricane_pike",
    "item_black_king_bar",
}
-- v0.5.133.1 (Phase 2 fix): a W-ONLY chain for the ally/team channel interrupt.
-- The single-target ally channels (Bane Grip etc.) already have item self-save
-- chains keyed on their real modifier (CH.BANE_GRIP = WW/Manta/...), and those
-- items are self-casts that CANNOT save an ally -- so dispatching the real mod
-- resolved to the wrong (item) chain and fell to no_effective. The ally
-- interrupt's only useful action is W on the caster, so it dispatches a
-- SYNTHETIC mod ("lina_ally_w_interrupt") that maps here; aim still targets the
-- passed caster via W_aim_at_caster_mods. NOT shared with the self-save chains
-- (those keep their items; W as a self head would no-op while Lina is disabled).
CH.ALLY_W_INTERRUPT = {
    "lina_w_anti_gap",
}

-- v0.5.17 Track 1: expose chain tables for the in-Brain test harness
-- (state.tests.*). The chain locals (CH.PUDGE_DISMEMBER, etc.) are
-- module-locals by design; this is the test-only read handle, NOT a
-- mutation point. Treat state.lina_chains as read-only at runtime.
state.lina_chains = {
    pudge_dismember = CH.PUDGE_DISMEMBER,
    bane_grip       = CH.BANE_GRIP,
    pugna_drain     = CH.PUGNA_DRAIN,
    legion_duel     = CH.LEGION_DUEL,
    disruptor_kfr   = CH.DISRUPTOR_KFR,
    wd_death_ward   = CH.WD_DEATH_WARD,    -- v0.5.47
    underlord_pit   = CH.UNDERLORD_PIT,    -- v0.5.47
    -- v0.5.71 Phase 4 slice 6 high-impact ult chains
    doom            = CH.DOOM,
    magnus_rp       = CH.MAGNUS_RP,
    fv_chrono       = CH.FV_CHRONO,
    enigma_bh       = CH.ENIGMA_BH,
    beastmaster_pr  = CH.BEASTMASTER_PR,
    tide_ravage     = CH.TIDE_RAVAGE,
    primal_onslaught = CH.PRIMAL_ONSLAUGHT,  -- v0.5.128
    cm_freezing_field = CH.CM_FREEZING_FIELD, -- v0.5.132
    sk_epicenter      = CH.SK_EPICENTER,      -- v0.5.132
    -- v0.5.147.x per-skill cast-poll chains (hooks + Power Cogs)
    pudge_hook         = CH.HOOK_INTERCEPT,
    clockwerk_hookshot = CH.CLOCKWERK_HOOKSHOT,
    clockwerk_cogs     = CH.CLOCKWERK_COGS,
}

-- v0.5.47 Phase 1: WD Death Ward + Underlord Pit of Malice chains. Both
-- threats were missing from LINA_SAVE_OVERRIDES so the lib's generic
-- category chains (channel_on_self / trap) ran with item slots Lina
-- doesn't fill (Sniper's grenade_self / grenade_at_caster heads). Adapted
-- from Sniper.lua L6568-6573 (WD) and L6600-6603 (Pit) for Lina's item set
-- and ability mix (no grenade; W as tail interrupter).
--
-- v0.5.47.1: WD Death Ward chain rebuilt with W as FRONT (was tail in
-- v0.5.47). User spec: "On cases where the skill is interrupted the best
-- option is to use the method that interrupt it. In this case our first
-- option should be W and itens afterwards". Death Ward is an 8s
-- interruptible channel (cast point is brief but the channel itself is
-- interrupt-vulnerable: stun the WD hero and the ward dies/stops). W's
-- 1.12s prep needs to start IMMEDIATELY when the channel begins so W
-- detonates at WD's position before WD finishes a meaningful amount of
-- the channel. Items follow as backup (Pike-on-WD pushes 425u + cancels
-- channel via forced-movement; Cyclone-on-WD bottles 2.5s; etc.).
-- W aim resolution is handled inside SAVE_FIRE.lina_w_anti_gap.fire
-- via the threat_caster param (chain walker passes it per lib/defense.lua
-- L566) which feeds predict_target_pos(WD, 1.12). WD is stationary while
-- channeling so predict returns WD's current position = aim on WD.
CH.WD_DEATH_WARD = {
    "lina_w_anti_gap",
    "item_hurricane_pike",
    "item_force_staff",
    "item_cyclone",
    "item_glimmer_cape",
    "item_wind_waker",
    "item_black_king_bar",
    "lina_flame_cloak",
}
-- Underlord Pit of Malice (400u radius ensare; 1.5-1.8s root per tick;
-- re-snares every 3.6s for 12s; undispellable basic). Forced-movement
-- saves break the ensnare (Force / Pike push Lina out of the 400u radius);
-- cyclone-self goes airborne (immune to ensare while flying); BKB does
-- NOT break ensare but lets Lina ignore the followup damage; W stuns
-- Underlord interrupting the channel of subsequent abilities. Same posture
-- as Disruptor Kinetic Field (CH.DISRUPTOR_KFR) but the pit's
-- per-tick re-snare means a single successful escape covers the rest of
-- the duration as long as Lina stays out.
CH.UNDERLORD_PIT = {
    "item_wind_waker",
    "item_cyclone",
    "item_force_staff",
    "item_hurricane_pike",
    "item_black_king_bar",
    "lina_w_anti_gap",
}

-- v0.5.71 Phase 4 slice 6: tuned chains for the 6 hard-disable ults the
-- audit (Explore agent post-v0.5.69) flagged as routed through the
-- generic CATEGORY_PATCHES.lockdown chain with no per-threat tuning.
-- "These are the threats that kill Lina; current chain is throw whatever
-- lockdown items have." Each entry below picks items by what actually
-- works for THAT ult (BKB-pierce vs BKB-blocked; reflectable vs not;
-- airborne dodge vs Aeon lethal-block). Authoritative-override bypass
-- means kind/tether filters are skipped (per lib/defense.lua
-- Dispatcher:ResolveSaveOrder hero_override branch).

-- Doom: 16s undispellable silence + DoT. Cast point 0.5s (cast_point_too_early
-- gate from v0.5.70 fires when chain walks early). Lotus REFLECTS Doom on
-- apply (single-target debuff). BKB grants magic immunity which dispels
-- Doom on apply AND prevents recast for the BKB duration. After Doom lands
-- Lina has no items / abilities -- saves MUST fire pre-cast or in-flight.
CH.DOOM = {
    "item_lotus_orb",        -- reflect Doom back on caster; primary save
    "item_black_king_bar",   -- magic immunity = Doom dispelled / blocked
    "item_wind_waker",       -- airborne 2.5s = Lina untargetable through cast resolution
    "item_cyclone",           -- same as WW (EUL true disable but still avoids Doom landing)
    "item_force_staff",      -- push 600u, may exit Doom's 600u cast range
    "item_hurricane_pike",   -- self-cast push 425u; enemy-cast disrupts Doom caster
    "item_glimmer_cape",     -- invis breaks Doom targeting if pre-cast
}

-- Magnus RP: PBAoE pull + 4s stun. Cast point 0.55s. BKB blocks both pull
-- AND stun (RP doesn't pierce BKB). Airborne (WW/Eul) dodges entirely. Not
-- reflectable. Force/Pike push out of pull radius if timing allows.
CH.MAGNUS_RP = {
    "item_black_king_bar",   -- blocks pull + stun
    "item_wind_waker",       -- airborne dodge (movable per Liquipedia, slice 3)
    "item_cyclone",           -- airborne dodge (full disable but untargetable)
    "item_force_staff",      -- escape pull radius
    "item_hurricane_pike",   -- same
    "item_glimmer_cape",     -- invis pre-cast breaks targeting
}

-- FV Chronosphere: AoE-at-ground stop-time 4-5s. Cast point 0.4s. BKB does
-- NOT help INSIDE Chrono (Lina still frozen; FV moves freely). Airborne
-- (WW/Eul) saves only if pre-cast / cast point. Aeon Disk DOES go off
-- inside Chrono on lethal damage. Lotus doesn't reflect.
CH.FV_CHRONO = {
    "item_wind_waker",       -- airborne pre-cast OR during; immune to Chrono freeze
    "item_cyclone",           -- airborne immune
    "item_force_staff",      -- escape sphere radius (425u) pre-cast
    "item_hurricane_pike",   -- same
}

-- Enigma Black Hole: PBAoE channel 4s, hard-disable. Cast point 0.45s.
-- BKB does NOT block BH (pierces). Airborne (WW/Eul) makes Lina immune to
-- the lift effect. Force/Pike push out of radius if pre-cast.
CH.ENIGMA_BH = {
    "item_wind_waker",       -- airborne immune to BH
    "item_cyclone",           -- same
    "item_force_staff",      -- push out of 400u BH radius pre-cast
    "item_hurricane_pike",   -- same
    "item_black_king_bar",   -- LAST resort (pierces BKB) -- in chain only for the magic damage component
}

-- Beastmaster Primal Roar: line skillshot, primary target 4s stun + cone
-- 2s slow. Cast point 0.4s. BKB blocks the stun. Airborne dodges.
CH.BEASTMASTER_PR = {
    "item_black_king_bar",   -- blocks stun
    "item_wind_waker",       -- airborne dodge
    "item_cyclone",           -- airborne dodge
    "item_force_staff",      -- escape line skillshot
    "item_hurricane_pike",   -- same
    "item_glimmer_cape",     -- invis pre-cast
}

-- Tide Ravage: PBAoE 4s stun. Cast point 0.55s. BKB blocks. Airborne
-- dodges. Lotus MAY reflect on apply (AoE debuff; reflect chance per-target
-- is unclear, treat as bonus not primary).
CH.TIDE_RAVAGE = {
    "item_black_king_bar",   -- blocks stun
    "item_wind_waker",       -- airborne dodge
    "item_cyclone",           -- airborne dodge
    "item_lotus_orb",        -- attempt reflect; not load-bearing
    "item_force_staff",      -- escape if Tide is in range
    "item_hurricane_pike",   -- same
    "item_glimmer_cape",     -- invis pre-cast
}

-- Modifier-keyed (self path, threat detected via OnModifierCreate).
LINA_SAVE_OVERRIDES["modifier_pudge_dismember_pull"]            = CH.PUDGE_DISMEMBER
LINA_SAVE_OVERRIDES["modifier_primal_beast_pulverize"]          = CH.PRIMAL_PULVERIZE  -- v0.5.121: Pike/Force keep-away (on the CASTER) + WW/Eul escape + Aeon; no BKB (pierces)
LINA_SAVE_OVERRIDES["modifier_mars_arena_of_blood"]             = CH.MARS_ARENA       -- v0.5.123: WW/Eul/Blink only (wall blocks Force/Pike AND BKB). base name = anim-path key (inert reactively; never lands on victim)
LINA_SAVE_OVERRIDES["modifier_mars_arena_of_blood_leash"]       = CH.MARS_ARENA       -- v0.5.124: the REAL trapped-state victim modifier (reactive path)
LINA_SAVE_OVERRIDES["modifier_mars_arena_of_blood_marker"]      = CH.MARS_ARENA       -- v0.5.124: the other real victim modifier (belt-and-suspenders)
LINA_SAVE_OVERRIDES["modifier_treant_overgrowth"]               = CH.TREANT_OVERGROWTH -- v0.5.123: WW, BKB, Pike (user order; all valid via dispel/dispel-on-cast/force-out)
-- v0.5.128.1: Primal Onslaught -> WW/Eul/Blink by PROXIMITY (armed like Bara/Tusk).
-- The armed tick resolves the chain via ANIM_SAVE_OVERRIDES[entry.ability] (KV-stable
-- ability key, same as bara_charge); the modifier-keyed override is the belt-and-
-- suspenders for the threat_mod path. Keyed on the DASH modifier (spans the charge,
-- the bara-analog), NOT the windup (which ends before the dash).
state.ANIM_SAVE_OVERRIDES["primal_beast_onslaught"]                         = CH.PRIMAL_ONSLAUGHT
LINA_SAVE_OVERRIDES["modifier_primal_beast_onslaught_movement_adjustable"]  = CH.PRIMAL_ONSLAUGHT
LINA_SAVE_OVERRIDES["modifier_bane_fiends_grip"]                = CH.BANE_GRIP
LINA_SAVE_OVERRIDES["modifier_pugna_life_drain"]                = CH.PUGNA_DRAIN
LINA_SAVE_OVERRIDES["modifier_legion_commander_duel"]           = CH.LEGION_DUEL
LINA_SAVE_OVERRIDES["modifier_disruptor_kinetic_field"]         = CH.DISRUPTOR_KFR  -- v0.5.118: REAL modifier name. v0.5.116.1 renamed the lib (_remnant -> _kinetic_field) but missed this override key (+ the eta resolver below + the anim override), so the override never matched and KF fell through to the axis (composed -> Pike, which the user flagged as the wrong counter). Now matches -> fires WW/BKB/Pike.
LINA_SAVE_OVERRIDES["modifier_witch_doctor_death_ward"]         = CH.WD_DEATH_WARD  -- v0.5.47
-- v0.5.147.x per-skill cast-poll routing (authoritative tier-2). The cast-poll tick dispatches
-- these threat_mods; the v0.5.40 lock dedups vs any later reactive landing. SEPARATED per skill
-- so each gets its proper save sequence (the lib data agrees: Pudge = line_projectile
-- displacement, Hookshot = close_gap airborne, Cogs = trap). The cog mod is cataloged in the
-- lib THREATS_ON_SELF so its reactive landing is recognized (no threat_unrecognized).
LINA_SAVE_OVERRIDES["modifier_pudge_meat_hook"]                 = CH.HOOK_INTERCEPT       -- hook -> instant-first (Blink/WW/Eul; Pike/Force dropped, dead zone)
LINA_SAVE_OVERRIDES["modifier_rattletrap_hookshot"]            = CH.CLOCKWERK_HOOKSHOT    -- fast hook -> WW/Eul/Blink (Pike too slow)
LINA_SAVE_OVERRIDES["modifier_rattletrap_cog_marker"]          = CH.CLOCKWERK_COGS        -- cog trap (primary landing) -> WW/Force/Pike/Eul
LINA_SAVE_OVERRIDES["modifier_rattletrap_cog_push"]            = CH.CLOCKWERK_COGS        -- cog contact knockback (sibling) -> same chain
LINA_SAVE_OVERRIDES["modifier_abyssal_underlord_pit_of_malice_ensare"] = CH.UNDERLORD_PIT  -- v0.5.47
-- v0.5.132 W-interrupt defense (Phase 1): W-head chains for two interruptible
-- AoE casts (CM Freezing Field channel; SK Epicenter 2s cast point). Pugna Life
-- Drain reuses the existing CH.PUGNA_DRAIN (W prepended above, L807).
LINA_SAVE_OVERRIDES["modifier_crystal_maiden_freezing_field"]   = CH.CM_FREEZING_FIELD
LINA_SAVE_OVERRIDES["modifier_sand_king_epicenter"]             = CH.SK_EPICENTER
-- v0.5.133.1 (Phase 2 fix): synthetic mod for the ally/team W-interrupt -> the
-- W-only chain. Real channel mods keep their own (self-save item) chains.
LINA_SAVE_OVERRIDES["lina_ally_w_interrupt"]                    = CH.ALLY_W_INTERRUPT
-- v0.5.71 Phase 4 slice 6 high-impact ult overrides:
LINA_SAVE_OVERRIDES["modifier_doom_bringer_doom"]                = CH.DOOM
LINA_SAVE_OVERRIDES["modifier_magnataur_reverse_polarity_stun"]  = CH.MAGNUS_RP
LINA_SAVE_OVERRIDES["modifier_faceless_void_chronosphere"]       = CH.FV_CHRONO
LINA_SAVE_OVERRIDES["modifier_enigma_black_hole"]                = CH.ENIGMA_BH
LINA_SAVE_OVERRIDES["modifier_beastmaster_primal_roar"]          = CH.BEASTMASTER_PR  -- v0.5.73: canonical name (was _stun in v0.5.71)
LINA_SAVE_OVERRIDES["modifier_tidehunter_ravage"]                = CH.TIDE_RAVAGE
-- v0.5.111.1 (demo: "Ghost scepter did not fire vs jugg ult"): Omnislash is
-- PHYSICAL attack-based, so Ghost-self (4s ethereal = attack-immune, and
-- Lina can still CAST while ethereal) is the strongest answer. In the demo
-- the threat resolved via the COMPOSED channel_on_self backbone (tier 3,
-- source=composed -- first wild sighting), which carries no Ghost, so it
-- could never fire and WW answered instead. Bespoke escape-hatch chain:
-- Ghost > Eul (2.5s invuln dodge) > WW (movable airborne) > Aeon
-- (lethal-damage backstop). BKB/Glimmer deliberately absent (the damage is
-- physical; magic resist is dead weight). Keyed on BOTH the modifier
-- (modcreate/armed path) and the ability name (the channel anim path that
-- fired in the demo resolves anim_save_overrides[ability] FIRST; ability
-- names are stable KV, lesson 111/210).
-- v0.5.113.1 (demo: "Ghost ok, ethereal blade no" -- Omni cast 2 walked
-- ghost/eul/ww not_ready then item_aeon_disk skipped with reason=no_entry):
-- (a) item_ethereal_blade_self ADDED after Ghost -- same ethereal effect,
-- and the standard build UPGRADES Ghost into E-blade, so a Lina carrying
-- only E-blade had NO ethereal answer (note: Ghost + E-blade share the
-- "ethereal" cooldown group, so the second slot only matters when Ghost is
-- not owned); (b) item_aeon_disk REMOVED -- Aeon is a PASSIVE (no .fire
-- entry exists; the slot could never fire and just logged no_entry).
CH.JUGG_OMNI = {
    "item_ghost", "item_ethereal_blade_self", "item_cyclone", "item_wind_waker",
}
LINA_SAVE_OVERRIDES["modifier_juggernaut_omni_slash"] = CH.JUGG_OMNI
state.ANIM_SAVE_OVERRIDES["juggernaut_omni_slash"]    = CH.JUGG_OMNI

----------------------------------------------- commit-attacker close-gap ---
-- v0.5.45 CA (DEFENSE_PLAN.md sec 4.2 commit-attacker track): port of
-- Sniper.lua state.is_committed_attacker (S3 L4318) + state.sample_velocities
-- attacker-latch (S3 L3921-3940). Sniper uses this OFFENSIVELY (gates D-peel
-- combo); Lina uses it DEFENSIVELY (synthesizes a virtual threat that routes
-- through v0.5.40 dispatcher to fire close-gap saves when a melee attacker
-- commits on Lina, even without a spell threat to react to).
--
-- Why we need this: pre-v0.5.45 the Lina defense chain only fires on SPELL
-- threats (Bara charge modifier, PA blink modifier, etc.). If an enemy hero
-- walks up and starts auto-attacking, brain does nothing. This is bad for
-- melee carries that close gap with auto-attacks (Slark post-pounce, Naga
-- post-Riptide, etc.) and bad for Sniper-like positional threats where the
-- attacker spends the spell window auto-attacking.
--
-- Detection: NPC.IsAttacking returns true only ~0.3s per ~1.4s attack cycle
-- (lib gap), so we latch via state.attacking_seen_t[caster_idx] = now and
-- v0.5.52.1 (200-locals cleanup): bundled 19 module-level constants
-- into single K table. Saves 18 main-chunk local slots.
local K = {}

-- consider attacker "committed" for K.LINA_COMMITTED_ATTACK_WINDOW_S after the
-- last latch. Proximity gate at K.LINA_ATTACK_ENGAGE_RADIUS = 700u (matches
-- Sniper). Kiting-away check via Target.IsKitingUs excludes heroes moving
-- away from us.
--
-- Synthesis: when a committed attacker is detected and the per-caster re-arm
-- latch (K.LINA_COMMITTED_ATTACK_WINDOW_S = 1.6s) has cleared, call
-- defense_dispatcher:Dispatch directly with threat_mod="lina_committed_attacker"
-- threat_caster=<attacker hero> category_hint="close_gap". The dispatcher
-- lock keyed (state.self_npc, "lina_committed_attacker", caster_idx) keeps
-- one save per attacker per window. Chain table CH.COMMITTED_ATTACKER_SAVES
-- is slim per user Q (slim chain recommended): displacement + escape + W
-- tail; no BKB/Lotus/Aeon/FC since attackers are mostly physical not magical
-- so magic immune / reflect / magic barrier are not useful.
K.LINA_COMMITTED_ATTACK_WINDOW_S = 1.6  -- Sniper L319 parity
K.LINA_ATTACK_ENGAGE_RADIUS      = 700  -- MELEE commit radius (Sniper parity; covers Lina's 670 attack range)
-- v0.5.104 (user: "we have to be able to defend ourselves from distance,
-- there are some dangerous heroes that can kill lina easily from far"): a
-- RANGED attacker gets a wider engage radius -- Sniper-class harassers and
-- ranged carries auto-attack from 700-1100u, which the melee-tuned 700
-- never armed on. The per-attacker limit is picked in
-- is_committed_attacker_on_self via state.attacker_is_ranged; the latch +
-- scan enumerations widen to this radius (melee beyond 700 still rejected
-- by the per-attacker gate).
K.LINA_ATTACK_ENGAGE_RADIUS_RANGED = 1100
K.LINA_COMMITTED_ATTACKER_RETREAT_BUFFER = 200  -- attacker further than 700+200=900 = released
K.LINA_ENIGMA_BH_RADIUS = 420  -- v0.5.133: Liquipedia 2026-06-14, Black Hole inner effect (pull+disable) radius; Phase 2 team-save counts allies inside this
-- v0.5.113.1 introduced this as a 0.17s blanket against charge-acceleration
-- model error. v0.5.114 (user: "instead of using a fixed value look for
-- bara acceleration ramp on liquipedia ... with this we can do a precise
-- calc"): the model error is now integrated away EXACTLY -- the lib ramp
-- model (TD.RampTravel / RampImpactT / ChargeRampKinematics) uses the
-- Liquipedia-verified mechanic (linear wind-up from 25 percent of the
-- per-level max bonus over windup_time=1.5s from charge start, then
-- constant; per-level accel from live KV; remaining wind-up from the
-- armed_t stamp). What remains here is the small ORDER-LATENCY pad
-- (decision-to-cast ~1-2 frames + issue lag); it biases the plan slightly
-- early, which the predict-aim absorbs by centering the AoE on the
-- predicted point. Tune from w_defensive_fire d_det: with the v0.5.114.1
-- earliest-castable intercept, healthy d_det for a CHARGE is ~550-650
-- (stunned near max W range); for Tusk's arrival window ~200-330.
-- v0.5.114.3/.4 (user recheck + Liquipedia rule): the W plan total is the
-- LIQUIPEDIA cast-animation figure 1.12 (cast point 0.45 + backswing 0.67
-- per liquipedia.net/dota2game/Lina) -- the number the user validated
-- empirically across v0.5.49-v0.5.50 and re-confirmed from the page.
-- state.w_lead() returns the 0.95 EFFECT lead (0.45 cast point + 0.5
-- effect delay); this margin covers the rest.
-- v0.5.114.7 (user: "Still hitting lina, but this is the effect of lina
-- not facing the charge. Add the max turn to the constant"): the margin
-- is now the SUM of two Liquipedia-grounded worst cases:
--   0.170  animation/issue envelope (Liquipedia 1.12 - the 0.95 effect lead)
-- + 0.175  MAX TURN: Lina turn rate 0.6, 180-degree turn = 0.175s per
--          liquipedia.net/dota2game/Turn_Rate (fetched 2026-06-12)
-- = 0.345  -> plan = 0.95 + 0.345 = ~1.30 = the user formula
--          "1.12 + turning time" at its worst case.
-- A CONSTANT max-turn (not the per-fire computed term) cannot poison the
-- aim clamp: facing-Bara fires bias the aim ~0.175 x speed (~120u) toward
-- Lina, well inside the 250 AoE; back-turned fires land dead center. The
-- per-fire deg(FindRotationAngle)/400 term stays BANNED (v0.5.114.6: the
-- v0.5.50.7 demo + the v0.5.114.4 self-cast bug). Do NOT shrink either
-- component, and do NOT re-add a per-fire turn term, without a demo
-- proving it.
K.W_INTERCEPT_MARGIN_S = 0.345
-- v0.5.151: committed-catch prediction margin. The single-target committed_catch
-- aim leads the attacker by w_lead + THIS, not by + K.W_INTERCEPT_MARGIN_S above:
-- the 0.345 bakes in a 0.175 max-180-degree-turn term specific to the Bara CHARGE
-- intercept, which over-leads a near-Lina committed catch (the prediction landed
-- ~1.295s ahead instead of the intended ~1.12). 0.17 = the animation envelope
-- only, so the horizon is ~1.12 and the {cur,pred} band is narrower (cover-both
-- catches more kiters). The CLUSTER path keeps K.W_INTERCEPT_MARGIN_S unchanged.
K.W_COMMITTED_LEAD_MARGIN_S = 0.17
-- v0.5.175 offense cover-both margin (units). w_aim passes W_AOE - this to
-- BestAoeCenter so a 2nd enemy is committed only when it sits >= this far INSIDE
-- the real 250 AoE -> a GUARANTEED double over the 0.95s lead, not a rim gamble.
-- Double threshold = ~2*(250 - 25) = ~450u apart; past it W single-targets the
-- priority. The real W still casts the full 250 AoE, so this only gates the
-- cover-both COMMIT; the lib midpoint placement makes the committed center robust.
K.W_COVER_MARGIN = 25
-- v0.5.111.1 lethality horizon in HITS (user demo note: "ww fired when
-- lethal but too close to lethal ... it was about the calculation based on
-- hits"). The old inline 4.25 made lethal flip only when ~4 sustained
-- autos would kill = saves fired nearly dead. 7 hits (~8s at 1.7 BAT with
-- mid-game IAS) flips lethal while Lina still has room to survive the
-- save's cast + travel. Weak harassers stay non-lethal (their hits_to_kill
-- is far above 7), so the v0.5.110.1 W-only conservation is intact. Tune
-- from the committed_attacker_armed hits= field.
K.LINA_LETHAL_HITS = 7

-- v0.5.156 FC TTK gate (FLAME_CLOAK_TTK_PLAN.md). Tunables for the offense-pillar
-- time-to-kill simulation that replaces the flip-test on the 1-2 enemy starter
-- path. All demo-tuned; bounded risk = FC fired/held a hair off on a 1-2 kill.
K.FC_TTK_BASE_REACTION  = 0.8   -- short window for the BKB case (no W-stun lockout) + curated-escape floor (later)
K.FC_TTK_ACCEL_ABS      = 1.5   -- min seconds saved to count as "meaningfully accelerates" (binds with ACCEL_FRAC via max)
K.FC_TTK_ACCEL_FRAC     = 0.25  -- and >= this fraction of ttk_off saved (the larger of the two is the threshold)
K.FC_TTK_DT             = 0.1   -- sim step (s)
K.FC_TTK_HORIZON        = 12.0  -- sim horizon (s) = the GENERIC non-escape window. A committed equal-speed target cannot
                                -- outrun a chasing Lina (net separation ~0), so the kill stays reliable for ~the whole
                                -- fight; the W-stun was the WRONG bound (it assumed the target teleports away at stun-end).
                                -- Curated per-hero INSTANT escapes (blink/Force/Eul/save) collapse the window later (phased).
K.FC_DURATION           = 7.0   -- Flame Cloak buff duration (KV flame_cloak_duration)
K.LINA_BASE_ATTACK_TIME = 1.7   -- Lina base attack time (Liquipedia; no GetBaseAttackTime API).
                                -- The GetAttackSpeed->interval conversion is the design's flagged
                                -- risk; the fc_offense_ttk diagnostic logs the derived interval so
                                -- a demo confirms/tunes it.

-- v0.5.158 FC defense reserve (FLAME_CLOAK_TF_ARBITER_PLAN.md, Phase A1). FC's
-- +35% magic resistance = x0.65 incoming magic; the reserve holds/fires FC vs an
-- uncovered lethal-survivable MAGIC threat. All demo-tuned.
K.FC_DEF_MR_MULT          = 0.65  -- FC incoming-magic multiplier (Tier-A ceiling D < HP/0.65)
K.FC_DEF_TIER_B_FLOOR     = 0.6   -- Tier-B: 0.6*HP <= D < HP (FC saves >= 21% HP)
K.FC_DEF_PROACTIVE_HP     = 0.35  -- v0.5.180: proactive (gank) FC band fires only when Lina HP fraction below this (was 0.50, too eager mid-gank)
K.FC_DEF_PROACTIVE_RADIUS = 1200  -- proactive band enemy-scan radius (u)
K.FC_DEF_PROACTIVE_COUNT  = 2     -- proactive band: >= this many enemy heroes near
K.FC_DEF_PRESSURE_DMG_WINDOW = 2.0   -- v0.5.158.5: a band-only proactive FC fires only under real pressure (damage within this window OR a committed attacker), not bare proximity
K.FC_TURN             = 0.8   -- v0.5.159 A2: commit FC offense if allies_eff >= K_FC_TURN * enemies_eff (FC swings ~35%, so a modest deficit is still turnable)
K.FC_TURN_VALUE_RELAX = 0.15  -- v0.5.165 D2: each +1.0 of weighted flip value W above 1 lowers the turn factor by this x K.FC_TURN (FC turns a more-behind fight for a high-value flip)
K.FC_TURN_MIN         = 0.5   -- v0.5.165 D2: hard floor on the value-modulated turn factor (never green-light a hopeless fight)
K.FC_MACRO_MIN_ENEMIES = 3    -- v0.5.159: macro_turnable only gates a TEAMFIGHT (>= this many enemies near); fewer = a pick, turnable by the TTK + bailout (a solo Lina bursting 1-2 must NOT read as "outnumbered")
K.STACK_OPENER_MAX    = 3     -- v0.5.160 A3.2: cold-open fires FC standalone at a TF onset when Fiery Soul stacks <= this (the 0->7 jump is the value)
K.FC_AOE_FLIP_RADIUS  = 250   -- v0.5.160 A3.1: the W (Light Strike Array) AoE radius -- only enemies the W+Q burst hits can be flip-counted
K.FC_FLIP_VALUE       = 0.8   -- v0.5.169 D4.4 TUNED 1.0->0.8: TF offense fires when weighted flip value W >= this. 0.8 fires on a core (of~1.1-1.6) / a 2-hard-support flip (~0.8) / a lone mid; holds a lone hard-support (~0.4). Per design 8.2 + the demo-confirmed hero_value of values.
K.HV_LIVE_LO          = 0.6   -- v0.5.164 D1: hero_value live-multiplier clamp floor (mirrors lib/hero_value LO)
K.HV_LIVE_HI          = 1.6   -- v0.5.164 D1: hero_value live-multiplier clamp ceil  (mirrors lib/hero_value HI)
K.HV_AIM_DIST_EPS     = 150  -- v0.5.166 D3: aim tie-break band; burst targets within this many units of the nearest are a tie, broken by HeroValue (kill the more valuable). Demo-tuned.
K.JUGG_OMNI_DODGE_DELAY   = 0.4  -- v0.5.160.2 Note-1: delay the WW/Eul (untargetable) dodge vs Jugg Omnislash this long past cast-detection so his cast COMMITS first (dodging during the ~0.3s cast point cancels+refunds the ult); the mid-ult dodge then whiffs the rest of the strikes (ends-early on no target) = Jugg loses the ult
K.JUGG_OMNI_MIN_HP_ACCEPT = 450  -- v0.5.160.2 Note-1: only accept the first strike + defer when Lina has at least this much HP; below it, dodge at cast to SURVIVE (defense first) even though Jugg keeps the ult
K.FC_MACRO_RADIUS     = 1500  -- v0.5.159 A2: fight-area radius for the eff-strength scan + the dest risk score
K.FC_DEST_RISK_MAX    = 60    -- v0.5.159 A2: AdvanceRiskScore at the commit pos must be < this (lib doc: >60 = abort)
K.FC_ALLY_NEAR_RADIUS = 1200  -- v0.5.159 A2: dest_safe ally-support scan radius
K.FC_ALLY_NEAR_COUNT  = 1     -- v0.5.159 A2: dest_safe needs >= this many allied heroes near (excl. Lina)
K.FC_BAILOUT_SAVES = {        -- v0.5.159 A2: ready non-FC escape/survive items that insure an offense commit (inventory-gated; design sec 5 set + Pike, == Force as a 600u displacement)
    "item_blink", "item_cyclone", "item_wind_waker", "item_black_king_bar",
    "item_glimmer_cape", "item_force_staff", "item_hurricane_pike", "item_aeon_disk",
}

-- v0.5.16x Phase B: Flame Cloak escape (mobility / survival tier, design 6.1). FC flies Lina
-- out of a lethal gank when the safest spot is terrain-locked + no ready Blink reaches it.
K.FC_ESCAPE_HP_FLOOR      = 0.50  -- focused-below HP fraction that counts as lethal-ish
K.FC_ESCAPE_SAFER_MARGIN  = 20    -- risk-score delta (walkable - overall) to justify flying (~one visible enemy of danger)
K.FC_ESCAPE_RADIUS        = 700   -- SafestSpotNear sample ring
K.FC_ESCAPE_GANK_ETA      = 2.0   -- GankImminent look-ahead seconds (min_count uses the lib default 2)

-- v0.5.16x Phase C: Flame Cloak CHASE (kill tier, design 6.2). FC = unobstructed movement (no speed,
-- Liquipedia); chase is a terrain CUTOFF of a fleeing kill target the offense already committed to.
K.FC_CHASE_COMMIT_WINDOW = 3.0   -- R-recency (s) that counts as "offense committing to this target"
K.FC_CHASE_KILL_REACH    = 1200  -- out-of-reach radius (R 750 + a fly-reach term); demo-tune
K.FC_CHASE_TOWER_RANGE   = 700   -- enemy tower attack range (structure range not queryable)
K.FC_CHASE_ETA_MARGIN    = 0.5   -- catch must beat escape by this many seconds
K.FC_CHASE_RISK_MAX      = 50    -- AdvanceRiskScore at the intercept must be below this (start under DEST_RISK_MAX 60)
K.FC_CHASE_RADIUS        = 700   -- SafestSpotNear/AdvanceRiskScore engage radius reuse
K.FC_CHASE_MS_FALLBACK   = 300   -- base MS if NPC.GetMovementSpeed reads nil
K.FC_CHASE_CUTOFF_RATIO  = 1.3   -- v0.5.163 C2: walk path must be >= this x the straight FC line to be a cutoff
K.FC_CHASE_CUTOFF_MIN    = 250   -- v0.5.163 C2: AND the walk must exceed the straight line by >= this many units
K.FC_CHASE_FLEE_MARGIN   = 20    -- v0.5.163.1: target counts as fleeing when its 0.3s-predicted pos is >= this many units FARTHER from Lina (moving away). ctx.kiting_us proved structurally false in the demo.
K.FC_CHASE_FLEE_LOOKAHEAD = 600  -- v0.5.163.4: extrapolate the flee direction this far to BuildPath the target's escape route (does IT wind around terrain Lina can fly straight over) -- the real cutoff value

-- v0.5.110.1 LETHAL-ONLY ITEM RULE (user demo feedback on v0.5.110: "all
-- attacks are using items, this way it is impossible for me to commit
-- attack to an enemy"). The v0.5.110 full-backbone composition is
-- REVERTED here: inheriting the whole close_gap backbone meant something
-- was ALWAYS ready, so every enemy auto-attack commit drained an item
-- (demo: 23 of 25 saves were committed burns -- Pike x7, Ghost x6, WW x5,
-- W x5), and the inherited Ghost (4s ethereal = Lina DISARMED) + WW
-- self-cyclones actively blocked the user's own attacks mid-fight.
-- NEW RULE (supersedes both the spec sec 5 widening AND the v0.5.101
-- ranged-harasser cyclone design): a NON-LETHAL committed attacker, melee
-- or ranged, draws W ONLY -- no items, no self-incapacitation; W's
-- predicted-catch gate (v0.5.105) already no-ops it when the attacker
-- would not be in the AoE (so ranged harass usually draws NOTHING, which
-- is the point). Items are reserved for LETHAL attackers via the proven
-- v0.5.105 displacement-first base literal. Hand-curated literals are
-- DELIBERATE: committed chains must not silently inherit future backbone
-- items (that inheritance is exactly what regressed). Composition remains
-- the tier-3 path for real SPELL threats, where Ghost et al. stay
-- reachable. scan_and_arm routes lethal -> base, non-lethal -> W-only
-- (see the v0.5.110.1 routing comment there).
-- v0.5.110.2 (T3 demo fail: Mars lethal=y walked Force/Pike/Glimmer/W all
-- not_ready -> no_effective_save_for_threat -> Lina DIED with Eul in the
-- inventory): the self-save cyclones are RESTORED for LETHAL committed
-- attackers (they were in this chain v0.5.45-v0.5.100; v0.5.101 removed
-- them for melee/lethal, which the user overrules for the LETHAL case --
-- "we did implement a rule to save self for this"). Eul-self = 2.5s
-- INVULNERABLE full disable, WW-self = 2.5s movable airborne; vs an
-- attacker that can kill Lina the lockout beats staying active. Eul
-- before WW (v0.5.104 convention: cheaper CD, WW = heavier backstop).
-- Non-lethal chains stay W-only (the v0.5.110.1 lethal-only item rule
-- is unchanged).
-- v0.5.111.1 (demo: "Ghost scepter did not fire vs ... lethal AA"): Ghost
-- HEADS the lethal chain. Committed attackers are auto-attackers, i.e.
-- PHYSICAL: Ghost-self = 4s full attack immunity on the cheapest CD in the
-- kit (22s), and ethereal only disarms ATTACKS, so Lina keeps casting
-- W/Q/R while immune (a counter-window, not a lockout). The v0.5.110.1
-- worry about Ghost disarming Lina mid-fight applies to NON-lethal harass,
-- which stays W-only; at lethal, survival outranks attack uptime.
CH.COMMITTED_ATTACKER_SAVES = {  -- LETHAL committed (melee or ranged)
    -- v0.5.113.1: item_ethereal_blade_self after Ghost, same rationale as
    -- CH.JUGG_OMNI (the Ghost -> E-blade upgrade path left E-blade-only
    -- builds without the ethereal save; shared "ethereal" CD group).
    "item_ghost", "item_ethereal_blade_self", "item_force_staff",
    "item_hurricane_pike", "item_cyclone", "item_wind_waker",
    "item_glimmer_cape", "lina_w_anti_gap",
}
CH.COMMITTED_ATTACKER_RANGED_SAVES = {  -- non-lethal ranged: W only
    "lina_w_anti_gap",
}
-- v0.5.105 (retained rationale): a NON-LETHAL MELEE attacker glued to
-- Lina is W's BEST defensive case -- the attacker is locked in place
-- attacking, so the self-aimed AoE catches it at detonation; the 1.6-2.2s
-- stun stops the damage, banks a Fiery Soul stack and opens a free
-- reposition/counter. W costs mana + 8s CD vs 20s+ on the items, which is
-- why the W-only rule is affordable.
CH.COMMITTED_ATTACKER_MELEE_SAVES = {  -- non-lethal melee: W only
    "lina_w_anti_gap",
}
LINA_SAVE_OVERRIDES["lina_committed_attacker"] = CH.COMMITTED_ATTACKER_SAVES
LINA_SAVE_OVERRIDES["lina_committed_attacker_ranged"] = CH.COMMITTED_ATTACKER_RANGED_SAVES
LINA_SAVE_OVERRIDES["lina_committed_attacker_melee"] = CH.COMMITTED_ATTACKER_MELEE_SAVES

-- State table init (per-tick attacker latches + per-caster re-arm latches).
-- Declared here adjacent to the helpers so the file stays grep-coherent;
-- could be hoisted to the L175-230 state.* block if maintenance prefers.
state.attacking_seen_t              = state.attacking_seen_t or {}
state.committed_attacker_armed_t    = state.committed_attacker_armed_t or {}
state.lethal_committed_until        = state.lethal_committed_until or 0  -- v0.5.110.2 offensive cyclone reserve window
-- v0.5.46 Problem A diag throttle (~5Hz) + last-scan stamp counter.
state.commit_attacker_diag_t        = state.commit_attacker_diag_t or 0
state.attacker_latch_last_stamped   = state.attacker_latch_last_stamped or 0
-- v0.5.47.2 W .fire allowlists.
--
-- W_skip_too_late_mods: empty (v0.5.46.3+); legacy belt left as a no-op
-- extension point.
state.W_skip_too_late_mods          = state.W_skip_too_late_mods or {}
-- W_aim_at_caster_mods: per-mod aim policy. Default for ALL other mods
-- is aim at Lina origin (state.self_npc position); the W AoE catches
-- the caster on arrival at Lina (Bara stops at Lina; Tusk snowball
-- arrives at Lina; PA blink lands at Lina; committed melee attackers
-- stay at Lina). Mods in this allowlist instead aim W at the threat
-- CASTER's current position so W stuns the caster mid-channel (channel
-- interrupt). Per user spec v0.5.47.2: "Tusk W is completely wrong,
-- need a full review. W was casted on a completly wrong position. It
-- should be casted on self in the right timing" -- the v0.5.46.3
-- predict-aim default was wrong; reverted to self origin for everything
-- except interruptible channels.
state.W_aim_at_caster_mods          = state.W_aim_at_caster_mods or {
    modifier_witch_doctor_death_ward = true,
    -- v0.5.132 W-interrupt defense (Phase 1): aim W at the caster for these
    -- interruptible casts. NOTE: the lib catalog (THREAT_ARRIVAL_TIMING
    -- impact_pos="caster") already resolves the caster aim for all three, so
    -- these are the belt-and-suspenders fallback (matching the WD precedent).
    modifier_pugna_life_drain              = true,
    modifier_crystal_maiden_freezing_field = true,
    modifier_sand_king_epicenter           = true,
    -- v0.5.133 (Phase 2): aim W at the caster for the ally/team channel
    -- interrupts. Bane/Enigma are in the impact_pos="caster" catalog already;
    -- pudge_dismember_pull / shackles / sinister_gaze are NOT, so the allowlist
    -- guarantees aim=caster_origin for them.
    modifier_bane_fiends_grip              = true,
    modifier_pudge_dismember_pull          = true,
    modifier_shadow_shaman_shackles        = true,
    modifier_lich_sinister_gaze            = true,
    modifier_enigma_black_hole             = true,
    -- v0.5.133.1: the synthetic ally-interrupt mod carries the caster aim (the
    -- dispatch passes threat_caster; this makes aim_via=caster_origin).
    lina_ally_w_interrupt                  = true,
}

-- v0.5.132.1: curated caster-side channel modifiers that the modifier-create
-- path (handle_caster_channel_interrupt) routes to the W interrupt when they
-- land on an enemy hero. This is the demo fix for CM Freezing Field: the anim
-- channel_start path bails on its target_self facing gate for a self-PBAoE
-- channel, so the modifier-create (which fires regardless of facing/anim, and
-- lands on the CM hero per modseen) is the reliable trigger. v0.5.132.2: WD
-- Death Ward is ALSO caught here -- its modifier lands on the WARD unit (a
-- visible summon), and handle_caster_channel_interrupt resolves the channeler
-- via Modifier.GetCaster, so W interrupts WD even when he channels from
-- invisibility (the visible ward's create event reaches us). The chain +
-- caster aim come from LINA_SAVE_OVERRIDES + the THREAT_ARRIVAL_TIMING
-- impact_pos="caster" catalog, exactly as on_channel_start consumes them. The
-- defense_dispatcher lock + Dedup coalesce this with the anim path (single-spend).
state.LINA_CASTER_CHANNEL_W_INTERRUPT = state.LINA_CASTER_CHANNEL_W_INTERRUPT or {
    modifier_crystal_maiden_freezing_field = true,
    modifier_witch_doctor_death_ward       = true,
}

-- v0.5.133 (Phase 2): curated victim-side modifiers for single-target ally
-- channels. When one lands on an ALLY hero, handle_ally_channel_interrupt
-- resolves the enemy caster (Modifier.GetCaster) and W-interrupts to free the
-- ally. All four are lib-catalogued (THREATS_ON_SELF / ABILITY_TO_THREAT) and
-- land on the VICTIM (for Pudge the victim modifier is _pull, not the base).
state.LINA_ALLY_CHANNEL_INTERRUPT = state.LINA_ALLY_CHANNEL_INTERRUPT or {
    modifier_bane_fiends_grip       = true,
    modifier_pudge_dismember_pull   = true,
    modifier_shadow_shaman_shackles = true,
    modifier_lich_sinister_gaze     = true,
    -- v0.5.133.2 (user request): Storm Spirit Electric Vortex. NOTE: NOT a
    -- channel -- Liquipedia 2026-06-14 confirms stunning SS does NOT cancel the
    -- pull (the debuff persists independently), so W does NOT free the ally.
    -- Added on a PEEL/PUNISH rationale: SS dives the ally (Ball Lightning ->
    -- vortex), so W-stunning SS interrupts his follow-up burst + sets up a kill
    -- on the diving SS. Same dispatch path (W aimed at SS via the synthetic mod).
    modifier_storm_spirit_electric_vortex_pull = true,
}

-- v0.5.112 (#1 W-lead unification): ONE source of truth for the defensive
-- W timing geometry. Returns (lead_s, aoe_r): lead = live W cast point
-- (Ability.GetCastPoint, fallback 0.45) + KV light_strike_array_delay_time
-- (fallback 0.5) -- the same formula state.cyclone_combo_timing derived in
-- v0.5.100.
-- v0.5.114.4 LIQUIPEDIA-GROUNDED (user rule: always check Liquipedia
-- before committing any mechanic; liquipedia.net/dota2game/Lina,
-- 2026-06-12): Light Strike Array cast ANIMATION = 0.45 + 0.67 (point +
-- backswing, total 1.12; alternate backswing 0.43), effect delay = 0.5,
-- effect radius = 250, stun 1.2/1.6/2/2.4. This helper returns the
-- EFFECT lead (0.45 + 0.5 = 0.95, when the stun lands relative to cast
-- start); the PLANS add K.W_INTERCEPT_MARGIN_S (0.17) on top, which
-- lands every plan exactly on the Liquipedia animation total 1.12 (+
-- per-fire turn) -- the figure the user validated empirically across
-- v0.5.49-v0.5.50 and re-confirmed from the page. AoE fallback = 250
-- per Liquipedia (the old 225 literal undersold the true radius).
state.w_lead = function()
    local w = ability("lina_light_strike_array")
    local cp = 0.45
    if w and Ability.GetCastPoint then
        local ok, v = pcall(Ability.GetCastPoint, w, true)
        if ok and type(v) == "number" and v > 0 then cp = v end
    end
    local delay = 0.5
    local aoe   = 250
    if w and state.item_kv then
        delay = state.item_kv(w, "light_strike_array_delay_time", 0.5)
        aoe   = state.item_kv(w, "light_strike_array_aoe", 250)
    end
    return cp + delay, aoe
end

-- v0.5.151: pure cover-both placement for the SINGLE-TARGET committed catch.
-- The defensive committed-attacker W (lina_committed_attacker[_ranged|_melee])
-- used to aim at one predicted point ~1s ahead; a kiter who changed direction
-- ended up dist(cur,pred) from that point and the 250-AoE missed ("W way off
-- Slark"). This aims a 250-AoE that spans BOTH his current and predicted
-- positions, so the stun lands whether he continues, stops, or reverses; it
-- skips when the band is too wide for one AoE. Returns (aim, kind, reason):
--   "catch": aim a {x,y,z} midpoint that covers both, outside Lina's self-AoE
--            and inside W cast range.
--   "self":  the covering midpoint sits inside Lina's self-centered AoE, so the
--            caller leaves committed_catch_pos nil and the self_origin path
--            self-casts W (the glued-attacker case, unchanged).
--   "skip":  reason "kiter_band_too_wide" (cur..pred span > 2*aoe; no single AoE
--            covers it) or "no_catch" (covering aim beyond cast range).
-- Pure: reads only p.x/p.y, returns a plain table; unit-tested offline + in-brain.
local function committed_catch_aim(cur, pred, lina, aoe, range)
    if not (cur and pred and lina) then return nil, "skip", "no_pos" end
    local bdx = (pred.x or 0) - (cur.x or 0)
    local bdy = (pred.y or 0) - (cur.y or 0)
    if (bdx * bdx + bdy * bdy) > (2 * aoe) * (2 * aoe) then
        return nil, "skip", "kiter_band_too_wide"
    end
    local mx = ((cur.x or 0) + (pred.x or 0)) * 0.5
    local my = ((cur.y or 0) + (pred.y or 0)) * 0.5
    local ldx = mx - (lina.x or 0)
    local ldy = my - (lina.y or 0)
    local d_lina2 = ldx * ldx + ldy * ldy
    if d_lina2 <= aoe * aoe then
        return nil, "self", nil
    elseif d_lina2 <= range * range then
        return { x = mx, y = my, z = lina.z or 0 }, "catch", nil
    else
        return nil, "skip", "no_catch"
    end
end
state.committed_catch_aim = committed_catch_aim

-- v0.5.115.1 (user: "lina is starting the casting too late"): the ONE
-- segment-coverage intercept criterion, shared by BOTH the armed-peek
-- dispatch gate and the lina_w_anti_gap.fire gate, so the dispatcher can
-- never again hold the cast back while the .fire math wants to fire (the
-- v0.5.55.2 peek gate was a stale twin with 1.12/225 literals enforcing
-- the OLD arrival window = dispatch only at ~840u). Returns
-- (castable, aim_d, near, far, range, d_now) or nil when the catalog /
-- positions / kinematics are unavailable (callers fall through to their
-- legacy behavior). The placement math is the v0.5.115 user geometry:
-- the skill is placeable anywhere in [0, max range] and covers 500u of
-- diameter, so bound Bara's detonation-time position (far at T_MIN =
-- facing, near at T_MAX = back-turned worst case) and cover the band:
-- far <= 2*aoe -> aim = far/2 (covers Lina herself through the far
-- extreme: any timing caught); else aim = (near+far)/2 (max-range
-- intercept). castable = aim within live cast range - 50u no-walk inset.
state.w_charge_intercept = function(caster, threat_mod)
    local me = state.self_npc
    if not (me and caster) then return nil end
    local entry = TD.THREAT_ARRIVAL_TIMING and TD.THREAT_ARRIVAL_TIMING[threat_mod]
    if not entry then return nil end
    local cpos = Entity.GetAbsOrigin(caster)
    local lpos = Entity.GetAbsOrigin(me)
    if not (cpos and lpos) then return nil end
    local ddx = (cpos.x or 0) - (lpos.x or 0)
    local ddy = (cpos.y or 0) - (lpos.y or 0)
    local d_now = math.sqrt(ddx * ddx + ddy * ddy)
    local lead, aoe = state.w_lead()
    local kl, ka, kr = TD.ChargeRampKinematics(entry, caster, state.item_kv,
        state.bara_charge_elapsed and state.bara_charge_elapsed(caster))
    if not (kl and (kl > 0 or (ka or 0) > 0)) then return nil end
    local far  = math.max(0, d_now - TD.RampTravel(kl, ka, kr, lead))
    local near = math.max(0, d_now - TD.RampTravel(kl, ka, kr, lead + K.W_INTERCEPT_MARGIN_S))
    local aim
    if far <= 2 * aoe then aim = far / 2
    else aim = (near + far) / 2 end
    local range = FALLBACK_RANGES.W
    local wab = ability("lina_light_strike_array")
    if wab and Ability.GetCastRange then
        local okr, rr = pcall(Ability.GetCastRange, wab)
        if okr and type(rr) == "number" and rr > 0 then range = rr end
    end
    range = range - 50  -- no-walk inset
    return (aim <= range), aim, near, far, range, d_now
end

-- Per-tick: stamp attacking_seen_t for any visible enemy hero NPC.IsAttacking
-- right now. Cheap O(N) scan over heroes in 3200u. API-guarded (NPC.IsAttacking
-- absent on some framework builds; degrades to silent no-op which means the
-- classifier falls back to current-tick IsAttacking only, i.e. firing only
-- during the ~0.3s swing window per attack cycle).
state.sample_attacker_latches = function()
    local me = state.self_npc
    if not (me and Entity.IsEntity and Entity.IsEntity(me)) then return end
    -- v0.5.82 perf: gate on the commit-attacker toggle like scan_and_arm does,
    -- and narrow the enumeration radius. The latches this writes are consumed
    -- ONLY by is_committed_attacker_on_self / scan_and_arm, both of which
    -- early-return when the toggle is off -- so the (widest-in-the-tick) 3200u
    -- enumeration was pure waste while disabled. And is_committed_attacker_on_self
    -- rejects anything beyond K.LINA_ATTACK_ENGAGE_RADIUS (700), so heroes
    -- stamped past 700 were dead latches. Both changes are behaviour-neutral
    -- (the feature's accept window is unchanged). This is the highest-value
    -- hot-path win from the v0.5.82 optimization pass.
    if not (state.menu and state.menu.enable_commit_attacker
            and state.menu.enable_commit_attacker:Get()) then return end
    if not (Entity.GetHeroesInRadius and Enum and Enum.TeamType) then return end
    -- v0.5.104: enumerate at the RANGED radius (1100) so distant ranged
    -- attackers get latched; melee past 700 stays a dead latch the
    -- classifier's per-attacker limit rejects (bounded waste, ~few entries).
    local ok, list = pcall(Entity.GetHeroesInRadius, me,
                           K.LINA_ATTACK_ENGAGE_RADIUS_RANGED, Enum.TeamType.TEAM_ENEMY)
    if not ok or type(list) ~= "table" then return end
    local t = state.frame_t or now()  -- v0.5.105 PERF ride-along: reuse the tick clock (sampled at OnUpdateEx top)
    -- v0.5.46 Problem A diag: count stamps per scan; surfaced in the
    -- aggregate commit_attacker_diag tlog so the v0.5.45.1 debug-hostile
    -- "silent classifier" no longer hides which gate is filtering PA.
    local stamped = 0
    for i = 1, #list do
        local h = list[i]
        if h and Entity.IsEntity(h) and Target.IsAlive and Target.IsAlive(h)
           and NPC.IsAttacking and NPC.IsAttacking(h) then
            local ok2, idx = pcall(Entity.GetIndex, h)
            if ok2 and idx then
                state.attacking_seen_t[idx] = t
                stamped = stamped + 1
            end
        end
    end
    state.attacker_latch_last_stamped = stamped
end

-- Classifier: returns true iff h is currently committing attacks on Lina
-- (close + attacking-now-or-recently + not kiting away).
state.is_committed_attacker_on_self = function(h)
    local me = state.self_npc
    if not (me and h and Entity.IsEntity(h) and Target.IsAlive and Target.IsAlive(h)) then
        return false
    end
    local d = dist_to(h) or math.huge
    -- v0.5.104: per-attacker engage limit -- ranged attackers commit from
    -- their own attack distance (up to 1100), melee keeps the 700 commit
    -- radius. state.attacker_is_ranged resolves at call time (defined below).
    local limit = state.attacker_is_ranged(h) and K.LINA_ATTACK_ENGAGE_RADIUS_RANGED
                  or K.LINA_ATTACK_ENGAGE_RADIUS
    if d > limit then return false end
    -- Kiting check: hero moving AWAY is not committing. Target.IsKitingUs
    -- may be absent (older Target lib); treat absence as not-kiting (the
    -- proximity + attack check is then the sole gate, more aggressive
    -- but conservative-on-classification-error since IsKitingUs nil =
    -- "we don't know, assume not kiting").
    if Target.IsKitingUs and Target.IsKitingUs(h, me) then return false end
    if NPC.IsAttacking and NPC.IsAttacking(h) then return true end
    local ok, idx = pcall(Entity.GetIndex, h)
    if not (ok and idx and state.attacking_seen_t) then return false end
    local seen = state.attacking_seen_t[idx]
    if not seen then return false end
    return ((state.frame_t or now()) - seen) < K.LINA_COMMITTED_ATTACK_WINDOW_S  -- v0.5.105 PERF ride-along
end

-- v0.5.101 Note 2 classifiers. attacker_is_ranged: base attack range alone
-- separates melee (150-250) from ranged (350+) in Dota; unreadable API ->
-- false (conservative: melee chain, no cyclone spend). attacker_can_kill_
-- self: rough sustained-autos lethality -- avg hit ((NPC.GetTrueDamage +
-- NPC.GetTrueMaximumDamage) / 2, the canonical pair per the stubs;
-- NPC.GetAttackDamage does NOT exist) x ~4.25 hits (5s horizon at 1.7 BAT
-- with mid-game IAS; demo-tunable) vs Lina's CURRENT armor-adjusted HP
-- (Target.EffectiveHpVs physical; raw Entity.GetHealth fallback per the
-- Entity-not-NPC HP API rule). Unreadable damage -> lethal=true
-- (conservative: treat as dangerous, no cyclone spend).
state.attacker_is_ranged = function(h)
    if not (h and NPC.GetAttackRange) then return false end
    local ok, r = pcall(NPC.GetAttackRange, h)
    return (ok and type(r) == "number" and r > 250) or false
end
-- v0.5.111.1: the lethality horizon is now an explicit HITS threshold
-- (K.LINA_LETHAL_HITS; was an inline 4.25 multiplier) and the function
-- returns (lethal, hits_to_kill) so the committed_attacker_armed tlog can
-- report the live number for demo tuning. Unreadable APIs keep the
-- conservative default: lethal=true (hits 0 = treat as killing now).
state.attacker_can_kill_self = function(h)
    local me = state.self_npc
    if not (me and h) then return true, 0 end
    local avg
    if NPC.GetTrueDamage and NPC.GetTrueMaximumDamage then
        local ok1, dmin = pcall(NPC.GetTrueDamage, h)
        local ok2, dmax = pcall(NPC.GetTrueMaximumDamage, h)
        if ok1 and ok2 and type(dmin) == "number" and type(dmax) == "number" and dmax > 0 then
            avg = (dmin + dmax) / 2
        end
    end
    if not avg or avg <= 0 then return true, 0 end
    local eff
    if Target.EffectiveHpVs and Enum.DamageTypes and Enum.DamageTypes.DAMAGE_TYPE_PHYSICAL then
        local ok, v = pcall(Target.EffectiveHpVs, me, h, Enum.DamageTypes.DAMAGE_TYPE_PHYSICAL)
        if ok and type(v) == "number" then eff = v end
    end
    if not eff or eff == math.huge then
        eff = (Entity.GetHealth and Entity.GetHealth(me)) or 0
    end
    local hits = eff / avg
    return hits <= K.LINA_LETHAL_HITS, hits
end

-- v0.5.103 (demo notes 3+4): shared ready-threat scan, extracted from
-- lina_starter_tick's v0.5.21 IMP-A6 block (same body, same 5Hz memo via
-- state.ww_threatened_t / ww_threatened_cached, same 1100u radius =
-- Hex/Doom/Finger/Assassinate cast ranges + buffer). TRUE when any enemy
-- hero within 1100u has a ready ability that maps into ABILITY_TO_THREAT.
-- Consumers: (a) the starter's ww_threatened gate (offensive WW spend,
-- unchanged behaviour), (b) the v0.5.103 committed-attacker cyclone
-- reserve gate below (defensive WW/Eul spend). Gate 11 doctrine: the
-- cyclones are DODGE items first; never spend them on auto-attack defense
-- while a dodge-class skill could arrive.
state.enemy_ready_threat_nearby = function()
    if (now() - (state.ww_threatened_t or 0)) < 0.2 then
        return state.ww_threatened_cached or false
    end
    local found = false
    local me = state.self_npc
    local enemies = me and Entity.GetHeroesInRadius(me, 1100, Enum.TeamType.TEAM_ENEMY) or nil
    if enemies then
        for i = 1, #enemies do
            local e = enemies[i]
            if e and Target.IsAlive(e) and Target.NotIllusion(e) then
                for slot = 0, 5 do
                    local ok_a, ab = pcall(NPC.GetAbilityByIndex, e, slot)
                    if ok_a and ab and Ability.GetLevel(ab) > 0 and Ability.IsReady(ab) then
                        local ok_n, ab_name = pcall(Ability.GetName, ab)
                        if ok_n and ab_name and ABILITY_TO_THREAT[ab_name] then
                            found = true
                            break
                        end
                    end
                end
            end
            if found then break end
        end
    end
    state.ww_threatened_t = now()
    state.ww_threatened_cached = found
    return found
end

-- v0.5.101 Note 2 situational cyclone aim vs the committed RANGED non-lethal
-- harasser (user decision at slice start): cyclone the TARGET when Lina is
-- FREE (disable the harasser ~2.5s), cyclone SELF when MID-KILL-COMBO (just
-- break the attack lock; she resets). The mid-combo signal is
-- state.combo_active_until (stamped by fire_steps to span the whole step
-- chain). Returns the unit to TARGET-cast the cyclone on, or nil = self-cast
-- (the existing SAVE_FIRE behaviour). Magic-immune target (BKB blocks a
-- targeted Eul/WW) or out of live cast range -> nil. NOTE: a targeted
-- cyclone pops Linkens; acceptable vs a harasser (the pop also breaks the
-- lock) -- revisit if demos disagree. Only the lina_committed_attacker_ranged
-- synthetic mod activates this; every real threat mod self-casts as before.
state.ca_cyclone_target = function(threat_mod, threat_caster, item_name, fallback_range)
    if threat_mod ~= "lina_committed_attacker_ranged" then return nil end
    if not (threat_caster and Entity.IsEntity(threat_caster)) then return nil end
    if (state.combo_active_until or 0) > now() then return nil end
    if NPC.HasState and NPC.HasState(threat_caster, MS.MODIFIER_STATE_MAGIC_IMMUNE) then return nil end
    local it = NPCLib.item(state.self_npc, item_name)
    if not it then return nil end
    local rng = fallback_range or 575
    if Ability.GetCastRange then
        local ok, v = pcall(Ability.GetCastRange, it)
        if ok and type(v) == "number" and v > 0 then rng = v end
    end
    local d = dist_to(threat_caster) or math.huge
    if d > rng then return nil end
    return threat_caster
end

-- Per-tick scan: for each enemy hero in K.LINA_ATTACK_ENGAGE_RADIUS, if
-- is_committed_attacker_on_self AND the per-caster re-arm latch is clear,
-- call defense_dispatcher:Dispatch directly. The dispatcher's per-(target,
-- canonical_mod, caster) lock keeps one save per attacker per window; the
-- re-arm latch (K.LINA_COMMITTED_ATTACK_WINDOW_S) prevents spam if the
-- dispatcher releases the lock before the attacker stops committing.
state.scan_and_arm_committed_attackers = function()
    -- v0.5.46.1 Problem Aaa: v0.5.46 placed the diag emit AFTER the
    -- menu / self_npc / API / pcall gates, so all the silent early-
    -- return paths v0.5.46 was supposed to surface are STILL invisible
    -- (the v0.5.46 demo log had zero commit_attacker_diag emits across
    -- the entire run). Hoist a throttled (~5Hz) diag emit ABOVE every
    -- early return with an `exit` reason so the next test reveals which
    -- gate is filtering. Reasons emitted: menu_off / no_self / no_api /
    -- no_dispatcher / pcall_fail / list_nil / scanned.
    local t = state.frame_t or now()  -- v0.5.105 PERF ride-along: reuse the tick clock
    local emit_diag = (t - (state.commit_attacker_diag_t or 0)) >= 0.20
    local function diag_exit(reason)
        if emit_diag then
            state.commit_attacker_diag_t = t
            tlog(3, "commit_attacker_diag", { exit = reason })
        end
    end
    if not (state.menu and state.menu.enable_commit_attacker
            and state.menu.enable_commit_attacker:Get()) then
        diag_exit("menu_off")
        return
    end
    local me = state.self_npc
    if not (me and Entity.IsEntity and Entity.IsEntity(me)) then
        diag_exit("no_self")
        return
    end
    if not (Entity.GetHeroesInRadius and Enum and Enum.TeamType) then
        diag_exit("no_api")
        return
    end
    if not defense_dispatcher then
        diag_exit("no_dispatcher")
        return
    end
    -- v0.5.104: scan at the RANGED radius; melee beyond 700 is rejected by
    -- the per-attacker limit inside is_committed_attacker_on_self.
    local ok, list = pcall(Entity.GetHeroesInRadius, me, K.LINA_ATTACK_ENGAGE_RADIUS_RANGED,
                           Enum.TeamType.TEAM_ENEMY)
    if not ok then
        diag_exit("pcall_fail")
        return
    end
    if type(list) ~= "table" then
        diag_exit("list_nil")
        return
    end
    -- v0.5.46 Problem A diag (kept for in-scan aggregate + per-enemy
    -- detail): v0.5.45.1 Test 5 produced zero committed_attacker_armed
    -- despite PA attacking. Throttle vars (emit_diag / state.commit_
    -- attacker_diag_t) are reused from the v0.5.46.1 hoisted block
    -- above so the exit-reason and the scanned aggregate share one
    -- throttle window (no double-fire per tick).
    local diag_in_rad     = 0
    local diag_attacking  = 0
    local diag_kiting     = 0
    local diag_committed  = 0
    local diag_armed      = 0
    local diag_latched    = 0
    for i = 1, #list do
        local h = list[i]
        if h and Entity.IsEntity(h) and Target.IsAlive and Target.IsAlive(h) then
            diag_in_rad = diag_in_rad + 1
            local attacking_now = (NPC.IsAttacking and NPC.IsAttacking(h)) and true or false
            local kiting        = (Target.IsKitingUs and Target.IsKitingUs(h, me)) and true or false
            if attacking_now then diag_attacking = diag_attacking + 1 end
            if kiting        then diag_kiting    = diag_kiting    + 1 end
            local committed = state.is_committed_attacker_on_self(h)
            if committed then diag_committed = diag_committed + 1 end
            if emit_diag then
                local d_diag = dist_to(h) or math.huge
                local ok_d, idx_d = pcall(Entity.GetIndex, h)
                local seen_t = (ok_d and idx_d and state.attacking_seen_t[idx_d]) or 0
                local seen_age = seen_t > 0 and (t - seen_t) or -1
                tlog(3, "commit_attacker_diag_h", {
                    h         = uname(h),
                    dist      = string.format("%.0f", d_diag),
                    attacking = attacking_now and "y" or "n",
                    kiting    = kiting and "y" or "n",
                    seen_age  = string.format("%.2f", seen_age),
                    committed = committed and "y" or "n",
                })
            end
            -- v0.5.108.2 double-save guard: skip the committed-attacker
            -- dispatch when this caster ALREADY has an active armed spell-
            -- threat entry (instant-blink / charge / channel / cast-point).
            -- A PA Phantom Strike double-fired W (committed_attacker_melee)
            -- + Pike (instant_blink:phantom_strike) because the two systems
            -- use DIFFERENT threat_mods, so the dispatcher per-(target, mod,
            -- caster) lock did not dedup them (demo: W @30.9 + Pike @31.1 on
            -- one blink). The committed-attacker system is the FALLBACK for
            -- plain auto-attackers with NO spell threat (v0.5.45 intent); when
            -- the armed path is already tracking this caster, let it own the
            -- save. After a gap-closer's displacement save the caster is
            -- pushed out of the 700u melee gate anyway, so the reverse order
            -- (blink fires+clears before the committed scan) self-resolves.
            local caster_armed = false
            if committed then
                for _, _e in pairs(state.armed_threats) do
                    if _e and _e.caster == h then caster_armed = true; break end
                end
            end
            if committed and caster_armed then
                if emit_diag then tlog(3, "committed_skip_armed", { h = uname(h) }) end
            elseif committed then
                local ok2, idx = pcall(Entity.GetIndex, h)
                if ok2 and idx then
                    local last_arm = state.committed_attacker_armed_t[idx] or 0
                    if (t - last_arm) >= K.LINA_COMMITTED_ATTACK_WINDOW_S then
                        diag_armed = diag_armed + 1
                        local d     = dist_to(h) or K.LINA_ATTACK_ENGAGE_RADIUS
                        local speed = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(h)) or 300
                        -- v0.5.101 Note 2: classify the attacker. RANGED AND
                        -- non-lethal -> the cyclone-headed chain (lock-break);
                        -- melee OR lethal -> displacement-only (NO WW/Eul).
                        local ranged = state.attacker_is_ranged(h)
                        local lethal, lethal_hits = state.attacker_can_kill_self(h)
                        -- v0.5.103 (demo notes 3+4): cyclone RESERVE gate.
                        -- The v0.5.102 demo spent WW (452.6s) + Eul x6 on
                        -- auto-attack defense; when Assassinate came the
                        -- dodge chain had to fall through to BKB (projectile
                        -- visibly connects) instead of a clean WW dodge. The
                        -- cyclones are DODGE items first: while a threat is
                        -- ARMED or any enemy in 1100u has a READY catalogued
                        -- threat ability (Assassinate/Hex/Doom/...), the
                        -- harasser gets the displacement chain instead.
                        local reserved = false
                        if ranged and not lethal then
                            reserved = (next(state.armed_threats) ~= nil)
                                       or state.enemy_ready_threat_nearby()
                        end
                        -- v0.5.110.1 lethal-gated routing (replaces the
                        -- v0.5.105 three-way; user demo note: "all attacks
                        -- are using items, impossible to commit an attack").
                        -- LETHAL (melee or ranged) -> the displacement-first
                        -- item base chain; NON-LETHAL -> the W-only chains,
                        -- so harass never draws an item and never
                        -- self-incapacitates (the v0.5.110 demo burned Ghost
                        -- x6 / WW x5 on commits, disarming Lina mid-fight).
                        -- `reserved` no longer affects routing: it existed
                        -- (v0.5.103) to keep cyclones in hand, and the
                        -- non-lethal chains now carry no cyclones at all; it
                        -- stays in the tlog as a diagnostic. NOTE the old
                        -- reserved-ranged path routed non-lethal harassers
                        -- into the BASE chain -- that was the sniper Pike/
                        -- Ghost drain in the v0.5.110 demo.
                        local ca_mod
                        if lethal then
                            ca_mod = "lina_committed_attacker"
                            -- v0.5.110.2: stamp the lethal-committed window so
                            -- the OFFENSIVE ladder reserves the cyclones for
                            -- the save chain (grep cyclones_reserved).
                            state.lethal_committed_until = t + 2.5
                        elseif ranged then
                            ca_mod = "lina_committed_attacker_ranged"
                        else
                            ca_mod = "lina_committed_attacker_melee"
                        end
                        state.committed_attacker_armed_t[idx] = t
                        tlog(1, "committed_attacker_armed", {
                            caster   = uname(h),
                            dist     = string.format("%.0f", d),
                            mvspeed  = string.format("%.0f", speed),
                            ranged   = ranged and "y" or "n",
                            lethal   = lethal and "y" or "n",
                            hits     = string.format("%.1f", lethal_hits or -1),  -- v0.5.111.1 hits-to-kill (tune K.LINA_LETHAL_HITS from this)
                            reserved = reserved and "y" or "n",
                        })
                        local intent = "committed_attacker_" .. tostring(idx)
                        defense_dispatcher:Dispatch(
                            intent,                            -- intent
                            ca_mod,                            -- threat_mod (synthetic, per class)
                            h,                                 -- threat_caster
                            me,                                -- target_unit
                            nil,                               -- fire_thunk (use chain walker)
                            "close_gap",                       -- category_hint
                            nil,                               -- ability_name
                            nil,                               -- armed_entry
                            record_save,                       -- on_save_fired
                            { fs_shard_window = fs_shard_window_active() }  -- ctx
                        )
                    else
                        diag_latched = diag_latched + 1
                        if emit_diag then
                            tlog(3, "commit_attacker_diag_latched", {
                                h         = uname(h),
                                latch_age = string.format("%.2f", t - last_arm),
                                window    = string.format("%.2f", K.LINA_COMMITTED_ATTACK_WINDOW_S),
                            })
                        end
                    end
                end
            end
        end
    end
    if emit_diag then
        state.commit_attacker_diag_t = t
        tlog(3, "commit_attacker_diag", {
            exit      = "scanned",
            in_rad    = tostring(diag_in_rad),
            attacking = tostring(diag_attacking),
            kiting    = tostring(diag_kiting),
            committed = tostring(diag_committed),
            armed     = tostring(diag_armed),
            latched   = tostring(diag_latched),
            stamped   = tostring(state.attacker_latch_last_stamped or 0),
        })
    end
end

-- Ability-keyed (anim route -- pre-cast detection via OnPrepareUnitOrders /
-- spell-cast probe). v0.2.2 lesson: modifier names drift across patches but KV
-- ability names are stable; the anim route detects by KV ability name and
-- short-circuits BEFORE the modifier applies, so we MUST also key the override
-- there or the anim-detected pre-cast falls through to the lib chain. Each
-- value shares the SAME chain table reference as LINA_SAVE_OVERRIDES (no data
-- duplication; lesson 210). legion_commander_duel kept here even though Sniper
-- omits it from ANIM_SAVE_OVERRIDES (S3 line 6627) -- the cost of an unused
-- entry is zero, and if a future lib release adds duel to ABILITY_TO_THREAT
-- the chain is already wired.
state.ANIM_SAVE_OVERRIDES["pudge_dismember"]         = CH.PUDGE_DISMEMBER
state.ANIM_SAVE_OVERRIDES["bane_fiends_grip"]        = CH.BANE_GRIP
state.ANIM_SAVE_OVERRIDES["pugna_life_drain"]        = CH.PUGNA_DRAIN
state.ANIM_SAVE_OVERRIDES["legion_commander_duel"]   = CH.LEGION_DUEL
state.ANIM_SAVE_OVERRIDES["disruptor_kinetic_field"] = CH.DISRUPTOR_KFR
-- v0.5.132 W-interrupt (Phase 1): ability-name keys (KV-stable) for the
-- anim/cast-start route. SK Epicenter's cast-point arming already routes via
-- LINA_SAVE_OVERRIDES; these are the belt-and-suspenders anim keys. (Pugna's
-- pugna_life_drain anim key already exists above -> CH.PUGNA_DRAIN, now W-head.)
state.ANIM_SAVE_OVERRIDES["crystal_maiden_freezing_field"] = CH.CM_FREEZING_FIELD
state.ANIM_SAVE_OVERRIDES["sandking_epicenter"]            = CH.SK_EPICENTER

-- v0.5.2: Hero-side threat entries the lib does not cover. The self path
-- (OnModifierCreate is_self branch, ~line 2860) gates on THREATS_ON_SELF; if a
-- threat is missing there (lib gap), the save chain never fires. This table
-- fills those gaps without editing the lib. Shape mirrors lib THREATS_ON_SELF:
--   { role = "<descriptive>", save = "save" | "informational" }
local LINA_EXTRA_THREATS = {
    -- Sniper Assassinate: single-target magical ult, 355/485/615 base + talents
    -- up to ~750+ at lvl 25. DEMO 3 (v0.5.1) caught it as `threat_unrecognized`
    -- five times. Wire it so the modifier-create path fires the save chain.
    -- v0.5.3: explicit `category` field. lib's TD.CategoryOf does not know about
    -- LINA_EXTRA_THREATS so it returns "reactive" (the default) - which makes the
    -- ally branch drop the threat (no ally chain for reactive). The ally branch
    -- now reads LINA_EXTRA_THREATS[mod].category first, then TD.CategoryOf.
    modifier_sniper_assassinate = { role = "burst", save = "save", category = "targeted_burst" },
    -- v0.5.124 (demo S4 fix): Mars Arena of Blood applies its trapped-state to the
    -- VICTIM under the suffixed names modifier_mars_arena_of_blood_leash / _marker
    -- (runtime-confirmed via modseen; the base modifier_mars_arena_of_blood never
    -- lands on Lina). Both were logging threat_unrecognized -> no save fired (the
    -- "Pike still fired" in the demo was actually Mars SPEAR, which is correct).
    -- Recognize both so the reactive path dispatches; LINA_SAVE_OVERRIDES routes
    -- them to CH.MARS_ARENA (WW/Eul/Blink). category=trap (Kinetic Field class).
    modifier_mars_arena_of_blood_leash  = { role = "trapped", save = "save", category = "trap" },
    modifier_mars_arena_of_blood_marker = { role = "trapped", save = "save", category = "trap" },
    -- v0.5.126 (queued Riki fix): Blink Strike teleports Riki BEHIND Lina from
    -- invisibility, so there is no anim to detect (the activity-code path cannot
    -- work) and no armed entry. The only on-Lina signal is the 0.4s slow debuff
    -- modifier_riki_blinkstrike_slow (VPK + modseen confirmed; previously logged
    -- threat_unrecognized -> no save). Recognize it here so the reactive path
    -- (handle_threat_on_self) dispatches; LINA_SAVE_OVERRIDES routes it to
    -- CH.GAP_CLOSE_SAVES (the same escape chain as PA/Bara/Slark/Tusk/QoP).
    -- LATE save (fires after the strike lands) -- accepted per the design.
    modifier_riki_blinkstrike_slow = { role = "close_gap", save = "save", category = "close_gap" },
    -- v0.5.147.x: Pudge Meat Hook lands on the victim as modifier_pudge_meat_hook but was
    -- logging threat_unrecognized (no self chain). Recognize it -> reactive backup save
    -- (the cast-poll tick is the PRE-impact primary; this + the v0.5.40 lock = single-spend).
    -- LINA_SAVE_OVERRIDES routes it to the DISPLACEMENT-FIRST CH.HOOK_INTERCEPT.
    modifier_pudge_meat_hook = { role = "close_gap", save = "save", category = "close_gap" },
}

-- v0.5.24 PERF-11: hoisted from OnModifierCreate is_self branch. These two
-- catalog tables are pure constants (no per-call state), so allocating them
-- on every self-modifier event was wasted work. Now module-level upvalues.
--
-- v0.5.7 E5 (A1/C9): the lib lists these target-debuffs as self-threats
-- because most heroes have no armed path. Lina DOES, so the cast-start
-- debuff would burn WW immediately and then armed_threats_tick fires
-- ~0.5s later with no_effective_save. Defer to the armed path which
-- fires at correct ETA.
local LINA_DEFER_TO_ARMED = {
    modifier_tusk_snowball_target = "tusk_snowball",
    modifier_spirit_breaker_charge_of_darkness_vision = "bara_charge",
    -- v0.5.9 E3 (A4/A7/A8/C4): PA Phantom Strike target-debuff lands when
    -- the blink resolves; route to the existing instant_blink armed entry
    -- (anim arm at on_gap_close, the INSTANT_BLINK_THREATS branch that
    -- stamps state.armed_threats['instant_blink:' .. ability]) so the save
    -- fires at the correct ETA instead of burning on debuff-create. NOTE: Marci/Slark/
    -- Primal Beast/Nyx Vendetta/Riki Blink Strike are intentionally NOT
    -- added here - they have no armed entry today and adding them would
    -- orphan the threat. v0.5.10 follow-up: add modifier-create or
    -- anim armers for those heroes first, then extend this table.
    modifier_phantom_assassin_phantom_strike_target = "instant_blink:phantom_assassin_phantom_strike",
}

-- v0.5.10 (E4 retry, canonical names): instant-disable allowlist. These
-- threats have NO meaningful pre-impact window to wait for (instant cast
-- + instant effect, OR sub-tick delay like Lion Finger's 0.25s). Saves
-- must fire on detection -- proximity / ETA gates do not apply. This
-- table is an audit-trail declaration of intent (the threat_on_self
-- branch already fires immediately for everything not in
-- LINA_DEFER_TO_ARMED); the tlog gives a greppable marker so a future
-- regression that accidentally adds one of these to DEFER_TO_ARMED is
-- visible. Canonical modifier names verified against lib/threat_data.lua
-- THREATS_ON_SELF + CATEGORY_OVERRIDES (v0.5.7 E6 / v0.5.9 E4 lesson:
-- guessed names fail silently).
-- v0.5.39 BUG-3: modifier_doom_bringer_doom REMOVED from this table.
-- Doom migrated from instant-fire (instant_disable_ack tlog + immediate
-- try_save_self at modifier-create) to cast-point-armed (CAST_POINT_THREATS
-- entry in lib/threat_data.lua). The new arming branch in handle_threat_on_self
-- waits cp~0.5s before firing the save, so BKB / Lotus reflect / WW land at
-- proper impact-imminent moment rather than burning at-cast-start.
-- modifier_lion_finger_of_death also covered by CAST_POINT_THREATS but is
-- LOTUS_WORTHY (routes through handle_lotus_first's CAST_POINT branch first);
-- its INSTANT_DISABLE entry stays as the documentation marker for the
-- catch-up path.
local LINA_INSTANT_DISABLE_MODS = {
    modifier_lion_voodoo                    = true,  -- Lion Hex (1.5-2.5s, instant)
    modifier_lion_finger_of_death           = true,  -- Finger (575+ pure, 0.25s sub-tick delay)
    modifier_disruptor_static_storm_thinker = true,  -- Static Storm (channel; mid-channel debuff)
}

-- v0.5.27 RPR-01 redo: curated per-modifier denylist of threats BKB ACTUALLY
-- blocks. When Lina has `modifier_black_king_bar_immune` AND the incoming
-- threat_mod is in this set, try_save_self bails at entry: the engine's BKB
-- already absorbs the threat, so firing a chain item on top would double-spend
-- (B3 user-observed: UCZone native auto-cast BKB plus brain-fired WW for the
-- same Tusk Snowball).
--
-- Per-modifier granularity DELIBERATELY avoids the v0.5.22 RPR-01 trap. RPR-01
-- bailed on the categories {lockdown, targeted_burst, targeted_disable,
-- hard_disable} which included BKB-PIERCING threats: Doom (modifier_doom_bringer_doom),
-- Duel (modifier_legion_commander_duel), Finger (modifier_lion_finger_of_death),
-- Pugna Drain (modifier_pugna_life_drain), Berserkers Call (modifier_axe_berserkers_call).
-- v0.5.23 reverted RPR-01 because the brain refused to save against those
-- BKB-piercing threats while BKB was up, and Lina died inside her own immunity.
-- The v0.5.27 redo keeps the v0.5.23 invariant intact: BKB-piercing threats
-- are NEVER in this table; only explicit modifiers known to be BKB-blocked
-- per Liquipedia's BKB-pierce table and the lib's COUNTER_LAYERS
-- magic_immune annotations.
--
-- Modifier names: VPK binary-grep verified against pak01_009.vpk (2026-06-01,
-- lesson 13) where present; snowball entries cross-verified against this
-- file's own armed_threats["tusk_snowball"].threat_mod (stamped in callbacks.OnModifierCreate on modifier_tusk_snowball_movement) and the lib
-- catalog. modifier_zuus_lightning_bolt is included per the user task spec;
-- if Zeus's instant nuke doesn't actually create that modifier name, the
-- entry is dead code (no risk -- threat_mod just never matches).
local LINA_BKB_TRULY_BLOCKED_MODS = {
    modifier_lion_voodoo                 = true,  -- Lion Hex: polymorph, BKB blocks
    modifier_shadow_shaman_voodoo        = true,  -- Shadow Shaman Hex: polymorph, BKB blocks
    modifier_zuus_lightning_bolt         = true,  -- Zeus Lightning Bolt nuke (may not land as a named mod; dead-safe)
    modifier_lina_laguna_blade           = true,  -- Lina R w/o Aghs Shard: magical damage, BKB blocks
    modifier_tusk_snowball_target        = true,  -- Tusk Snowball target tag (per wiki: "cannot be cast on spell immune")
    modifier_tusk_snowball_movement      = true,  -- Tusk Snowball rolling phase (key the armed chain uses; see the modifier_tusk_snowball_movement branch in callbacks.OnModifierCreate)
}

-- Per-modifier patches merged into the lib RECOMMENDED_SAVES (sparse).
local LINA_THREAT_PATCHES = {}

-- Per-category chain priority overrides. Keyed to the LIB category names
-- (TD.CategoryOf output): Lina's conceptual instant_lethal/magical_burst map
-- onto targeted_burst + lockdown; physical_burst onto physical_chase.
-- lina_flame_cloak + item_ethereal_blade_self are hero-specific SAVE_FIRE keys.
local LINA_CATEGORY_PATCHES = {
    close_gap = {
        prepend = { "item_wind_waker", "lina_flame_cloak", "item_glimmer_cape",
                    "item_invis_sword", "item_silver_edge", "item_black_king_bar",
                    "item_force_staff", "item_hurricane_pike" },
        append  = { "item_cyclone" },
    },
    channel_on_self = {
        prepend = { "item_wind_waker", "item_black_king_bar" },
    },
    targeted_burst = {
        prepend = { "lina_flame_cloak", "item_black_king_bar",
                    "item_glimmer_cape", "item_lotus_orb" },
    },
    lockdown = {
        prepend = { "item_wind_waker", "item_black_king_bar", "item_lotus_orb" },
    },
    physical_chase = {
        prepend = { "item_ethereal_blade_self", "item_black_king_bar", "item_glimmer_cape" },
    },
}

-- v0.5.110 chain composition (CHAIN_COMPOSITION_DESIGN.md): the generic
-- tier-3 declaration. ResolveSaveOrder composes the RAW lib
-- TD.CATEGORY_CHAINS backbone for a categorized threat with these
-- injections/exclusions and marks the result authoritative, ahead of the
-- LINA_CATEGORY_PATCHES-patched chains above (which stay as the tier-4/5
-- fallback for categories without a lib backbone, and for any hero not
-- registering composition). This is what finally routes the v0.5.109 item
-- builders: a category-routed threat now walks the full lib item backbone
-- (Ghost in close_gap, Pipe in targeted_burst) plus Lina's abilities at
-- their declared anchors. Bundled into CH per the 200-locals rule
-- (v0.5.45.1). MUST stay static after load: the lib memoizes composed
-- chains per category.
CH.ABILITY_INJECTIONS = {
    -- W anti-gap heads the gap-close response: vs a homing gap-closer the
    -- self-aimed AoE stun is the cheapest counter (8s CD, ~130 mana vs
    -- 20s+ item CDs); the v0.5.105 predicted-catch gate inside its .fire
    -- no-ops the slot whenever the attacker would not be in the AoE.
    { save = "lina_w_anti_gap",  categories = { "close_gap" },
      anchor = "head" },
    -- FC = 35 magic resist + spell amp: a deep MR tail vs magic burst,
    -- lockdown, and delayed_aoe magical zones (v0.5.158.3: e.g. Skywrath
    -- Mystic Flare -- FC mitigates the zone as a last-resort when the
    -- displacement that would dodge it is down). Never ahead of the real
    -- saves (tail anchor); the .fire only fires for magical threats.
    { save = "lina_flame_cloak", categories = { "targeted_burst", "lockdown", "delayed_aoe" },
      anchor = "tail" },
}
CH.EXCLUSIONS = {
    -- Ether-self AMPLIFIES magic damage taken: never vs magic burst.
    -- (No-op while the burst backbone lacks the item; declared so the
    -- backbone-enrichment follow-up can never regress this.)
    targeted_burst = { item_ethereal_blade_self = true },
}

local function _apply_category_patch(base, patch)
    if not patch then return base end
    local out = {}
    if patch.prepend then
        for i = 1, #patch.prepend do out[#out + 1] = patch.prepend[i] end
    end
    for i = 1, #base do
        out[#out + 1] = base[i]
        if patch.insert_after and patch.insert and base[i] == patch.insert_after then
            for j = 1, #patch.insert do out[#out + 1] = patch.insert[j] end
        end
    end
    if patch.append then
        for i = 1, #patch.append do out[#out + 1] = patch.append[i] end
    end
    return out
end

local CATEGORY_CHAINS = {}
do
    for cat, lib_chain in pairs(TD.CATEGORY_CHAINS or {}) do
        CATEGORY_CHAINS[cat] = _apply_category_patch(lib_chain, LINA_CATEGORY_PATCHES[cat])
    end
end

local PATCHED_RECOMMENDED_SAVES = {}
do
    local seen = {}
    for mod in pairs(TD.RECOMMENDED_SAVES or {}) do seen[mod] = true end
    for mod in pairs(LINA_THREAT_PATCHES)        do seen[mod] = true end
    for mod in pairs(seen) do
        local base  = (TD.RECOMMENDED_SAVES and TD.RECOMMENDED_SAVES[mod]) or {}
        PATCHED_RECOMMENDED_SAVES[mod] = _apply_category_patch(base, LINA_THREAT_PATCHES[mod])
    end
end

-- v0.5.21 IMP-A8: expected-damage table for the Lotus chain-walked gate.
-- Conservative best-of-level magical-damage estimates per threat modifier
-- (NOT mitigation-aware; we want a slight over-fire bias so Lotus reflects
-- rather than skips on the edge case). Used by SAVE_FIRE.item_lotus_orb.fire
-- below: Lotus fires when expected_damage >= 30% of Lina's current HP OR
-- when the threat is in LOTUS_WORTHY_INCOMING. Threats absent from this
-- table fall back to the legacy 0.85 HP-fraction gate so unknown threats
-- do not regress.
-- All modifier names VPK-verified (pak01_009.vpk binary grep, 2026-06-01).
-- modifier_lina_light_strike_array does NOT exist in the VPK (Light Strike
-- Array's stun is a generic stun modifier, not a named debuff); excluded.
-- Damage = 0 entries are intentional DISABLE markers (Voodoo is hex with no
-- reflectable damage; Doom DoT is too slow to be worth a 14s Lotus CD).
local LINA_EXPECTED_DAMAGE = {
    modifier_lion_finger_of_death  = 575,
    modifier_lina_laguna_blade     = 750,
    modifier_sniper_assassinate    = 600,
    modifier_lion_voodoo           = 0,    -- disable (hex, no reflectable dmg)
    modifier_doom_bringer_doom     = 0,    -- disable (slow DoT, Lotus poor pick)
    -- v0.5.168 D4.2 (magic-D expansion, design 8.3): high-magnitude MAGICAL nukes
    -- that previously fell to the coarse fc_severity_D fallback in the FC defense
    -- grade. Keys are the canonical threat_data THREAT_PROFILE modifier names (what
    -- the threat system emits); values are conservative best-of-level magical damage
    -- from Liquipedia (patch 7.41d). school=magical ONLY belongs here (FC's 35% MR
    -- softens magical): Tinker Laser is PURE -> excluded; Skywrath Arcane Bolt /
    -- Pugna Nether Blast / Invoker nukes are NOT in THREAT_PROFILE -> a catalog entry
    -- would be dead (never looked up by fc_defense_claim). Zeus Thundergods Wrath was
    -- REMOVED v0.5.168.3: modseen shows the instant ult lands NO debuff modifier, so a
    -- modifier-keyed entry can never match (its detection routes to bkb/pipe, not FC).
    modifier_zuus_lightning_bolt                = 380,   -- Zeus W, 140/220/300/380 L1-4, single-target magical (FC-graded, demo-confirmed src=catalog)
    -- v0.5.179 (bridge #4 Round 3, pointwise): was 1600 (base L3 only). Liquipedia
    -- (7.41d): base 800/1200/1600 L1-3 + the L25 talent "+400 Mystic Flare damage" ->
    -- 2000 worst case, UNDIVIDED on a solo target. The base-only 1600 under-graded a
    -- maxed Skywrath as `none` at full HP (1600 < 0.6*HP=1668), so FC held the channel
    -- as the last-resort save and Lina ate it raw (demo: hp 2781->803, ~1978 == the
    -- talented total). 2000 lands in Tier-B at full HP -> FC fires. Aghs Scepter casts
    -- a 2nd instance on ANOTHER hero (not stackable on solo Lina); the Shard does not
    -- touch Mystic Flare. Damage is divided among heroes in the zone -> solo = worst case.
    modifier_skywrath_mystic_flare_aura_effect  = 2000,  -- Skywrath ult zone, base 800/1200/1600 L1-3 + L25 talent +400 = 2000 solo worst case
    modifier_skywrath_mage_mystic_flare_thinker = 2000,  -- same Mystic Flare zone (thinker key variant)
    modifier_leshrac_split_earth                = 280,   -- Leshrac Q, 115/170/225/280 L1-4 magical (stun + damage)
    -- v0.5.168.2 D4.2 batch-2 (Liquipedia 7.41d). Clean single-burst magical nukes only.
    -- Chain Frost (bouncing, no clean per-hero value) + Mortimer Kisses (spread glob
    -- bombardment, conflicting per-glob sources) stay DEFERRED (niche + no clean D).
    -- v0.5.178.3 DECISION (FC-grade-magical-nukes review, bridge #4): the two entries
    -- below are INERT BY DESIGN, not pending. Both are primary_harm="disable" AoE STUNS
    -- (THREAT_PROFILE save="bkb_or_blink" / "eul_or_bkb"), so the threat system routes
    -- them to the ITEM-save chain, NOT the FC magical-D reserve (fc_defense_claim never
    -- grades them; fc_defense_d never fires). CORRECT + FINAL: FC's 35% MR cuts only the
    -- DAMAGE, never the stun, so a dodge/immunity item is strictly better. Kept as a
    -- damage reference only -- do NOT wire Ravage/Avalanche into FC.
    modifier_tidehunter_ravage                  = 400,   -- Tide ult, 200/300/400 L1-3 magical PBAoE (base; +100 talent). ITEM-save routed (AoE stun); inert here.
    modifier_tiny_avalanche_stun                = 360,   -- Tiny Q, 90/180/270/360 L1-4 magical; KEY=_stun. ITEM-save routed (AoE stun); inert here.
}

-- Save-cast closures. Universal item self-casts plus the two Lina-specific
-- ones (Flame Cloak ability, Ethereal Blade self-cast). Aeon is passive
-- auto-trigger, so it has NO fire entry (the chain skips it; the brain only
-- logs the proc). Force/Pike self-push gate on safe_push_destination (E10).
-- v0.5.108: the 12 defensive ITEM save bodies now live in lib/item_saves.lua
-- (hero-agnostic). SAVE_CFG bundles the cast primitives + the hero-policy
-- hooks (thin wrappers over existing state.* aliases). The two Lina ABILITY
-- saves (lina_flame_cloak, lina_w_anti_gap) stay as the literal below; the
-- item entries are merged in from ItemSaves.build after it. The lotus_gate
-- closure ports the v0.5.107 item_lotus_orb damage gate verbatim. See
-- Lina/ITEM_SAVES_LIFT_DESIGN.md.
local SAVE_CFG = {
    self_npc        = function() return state.self_npc end,
    item            = function(n) return NPCLib.item(state.self_npc, n) end,
    issue_self      = function(intent, it) return issue_item_self(intent, "def", it) end,
    issue_target    = function(intent, it, t) return issue_item_target(intent, "def", it, t) end,
    issue_position  = function(intent, it, p) return issue_item_position(intent, "def", it, p) end,
    issue_no_target = function(intent, it) return issue_item_no_target(intent, "def", it) end,
    tlog            = tlog,
    uname           = uname,
    dist_to         = function(u) return dist_to(u) end,
    -- policy hooks (thin wrappers over existing state.* aliases)
    armed_cp_t            = function() return state.cur_armed_cp_t end,
    armed_threat_mod      = function() return state.cur_armed_threat_mod end,
    cyclone_target        = function(mod, caster, item, range) return state.ca_cyclone_target(mod, caster, item, range) end,
    queue_post_move       = function(short, dist, caster, mod, movable) return state.queue_safe_post_move(short, dist, caster, mod, movable) end,
    self_push             = function(intent, it, name, range, caster) return state.try_self_push(intent, it, name, range, caster) end,
    pike_enemy_range      = function() return state.pike_enemy_range() end,
    pike_after_target_fire = function(caster)
        if not state.pike_primed then
            state.pike_reissue = { caster = caster, t = now(), self_cast = false }
        end
    end,
    compute_safe_dest     = function(caster, dist) return state.compute_safe_dest(caster, dist) end,
    recent_damage         = function(s)
        if Damage and Damage.GetRecentDamage then
            local ok, d = pcall(Damage.GetRecentDamage, state.self_npc, s)
            if ok and type(d) == "number" then return d end
        end
        return 0
    end,
    lotus_gate            = function(threat_mod)
        -- v0.5.116.2: the per-threat damage-throttle (v0.5.107 / IMP-A8: only fire
        -- Lotus at >=30% HP damage or for LOTUS_WORTHY_INCOMING) is DROPPED. It was
        -- a pre-axis heuristic to compensate for not knowing which threats Lotus
        -- actually counters. The threat-counter axis now decides that: the
        -- dispatcher only resolves item_lotus_orb into the chain when reflect_target
        -- genuinely counters the threat (axis SaveCounters filter) or a hand-override
        -- placed it there deliberately. So when this gate is reached, Lotus IS the
        -- resolved counter -> FIRE it. Reflecting a dangerous threat (Rupture, Lasso,
        -- Finger, Doom) back at the caster beats conserving the 14s CD. The BKB
        -- threat_fully_blocked veto + item-ready checks still apply upstream.
        -- (Supersedes the v0.5.116.1 reflectable-disable patch; this covers it.)
        return true
    end,
}

-- HERO-SPECIFIC ABILITY saves (not items). Kept as a literal; item entries
-- merged in below.
local SAVE_FIRE = {
    -- HERO-SPECIFIC: Flame Cloak (Aghs Scepter ability; gate GetLevel>0).
    lina_flame_cloak = {
        short = "flame_cloak",
        -- v0.5.40 B1 / GAP-2: defensive FC fire during the 5s post-R Aghs-Shard
        -- window (modifier_lina_laguna_super_charged) DOWNGRADES Fiery Soul
        -- from up-to-12 stacks back to 7 because FC sets FS to 7 outright
        -- (LIQUIPEDIA_REF Fiery Soul section). The chain dispatcher already
        -- demotes lina_flame_cloak to chain tail when ctx.fs_shard_window is
        -- set (Dispatcher:ResolveSaveOrder, lib/defense.lua); guard the fire
        -- itself too so any direct SAVE_FIRE caller (test harness, future
        -- bypass path) cannot strip stacks during the shard window. Returning
        -- false makes the chain walker skip FC and try the next save.
        -- Reuses state.compute_fs_state (single source of truth for cap +
        -- shard window, see compute_fs_state near L2581) so any future change
        -- to the 5.0s window length or has_shard detection lands here too.
        --
        -- v0.5.40.1 HOTFIX: per user spec defensive FC is now reserved for
        -- low-HP emergencies only (HP < 30%). FC sets FS to 7 outright and
        -- costs a 25s CD; spending it as a routine displacement save against
        -- a healthy Lina is wasted CD that should have gone to the kill
        -- combo's pre-amp. At HP < 30% the 7s magic resistance + spell amp
        -- amounts to a meaningful clutch save. Returning false makes the
        -- chain walker advance past FC to the next chain entry.
        fire  = function(intent, threat_caster, threat_mod)
            -- v0.5.158.1: skip if Lina cannot cast right now (stunned/hexed/silenced/
            -- invulnerable/airborne) -- else the engine silently drops the cast
            -- (cast_verify fired=n; the v0.5.158 demo fired FC during not_self_alive).
            if state.lina_self_alive_ok and not state.lina_self_alive_ok() then return false end
            -- v0.5.158 A1: defensive FC fires on the threat/HP/item-aware reserve
            -- claim (Tier-A) instead of the old <30% HP panic. state.fc_defense_tick
            -- is the primary proactive fire; this save-chain entry is the reactive
            -- belt-and-suspenders (the single-spend lock dedups vs the tick).
            local claim = state.fc_defense_claim and state.fc_defense_claim(nil, threat_mod, true)
            -- v0.5.158.2: fire FC on Tier-A (lethal-survivable) OR Tier-B (heavy) as the
            -- reactive LAST-RESORT -- the save chain only reaches FC after every better
            -- save is not_ready. v0.5.158.1 demo: vs Sniper Assassinate with Lotus/BKB/
            -- Eul/WW/Glimmer all on CD the chain fell to FC but A1 held it on claim=B and
            -- Lina ate the nuke unsaved. Tier-B is the moderate tier (design 4.4: fires
            -- over a HOLD); fc_defense_claim's matched coverage already drops the claim to
            -- none when a better item is ready, so FC fires only when it is the last option.
            if claim ~= "A" and claim ~= "B" then
                tlog(2, "fc_defensive_skip_claim", { claim = tostring(claim) })
                return false
            end
            local fs_state = state.compute_fs_state and state.compute_fs_state(state.self_npc)
            if fs_state and fs_state.shard_window then
                tlog(2, "fc_defensive_skip_shard", { reason = "fs_shard_window", stacks = fs_state.stacks, cap = fs_state.cap })
                return false
            end
            local fc = ability("lina_flame_cloak")
            if not fc or not (Ability.GetLevel(fc) > 0) or not Ability.IsReady(fc) then return false end
            if NPC.IsChannellingAbility and NPC.IsChannellingAbility(state.self_npc) then return false end
            return issue_cast_notarget(intent, fc, "def")
        end,
    },
    -- HERO-SPECIFIC: W (light_strike_array) anti-gap arrival stun.
    -- v0.5.44 (DEFENSE_PLAN.md sec 2.1): W has 1.1s prep (0.6 cast point +
    -- 0.5 delay) + 225 AoE + 1.6s stun. Workflow audit D1 surfaced 4 high-
    -- viability targets (Bara Charge, Bara Nether Strike, Tusk Snowball,
    -- MK Primal Spring) and 2 medium (Storm BL landing, Ember Remnant
    -- arrival). All 4 high-viability cases land AT Lina position, so aim
    -- is always state.self_npc origin (simplest correct policy; predicted-
    -- landing variant deferred to v0.5.4X+ if evidence emerges). Spec'd
    -- as chain TAIL of CH.GAP_CLOSE_SAVES per Q1: items fire first, W only
    -- when WW/Force/Pike/Glimmer all on CD. Mana floor enforces +450
    -- r_reserve so defensive W cannot starve the kill combo. Silenced
    -- check via ABILITY_SAVES = { lina_w_anti_gap = true } (chain walker
    -- gates this entry on self_can_cast_abilities, which checks
    -- NPC.IsSilenced + MODIFIER_STATE_MUTED). Opt-in via Defense menu
    -- toggle state.menu.enable_w_anti_gap (default true). Returns true
    -- on successful cast (lock stays held by dispatcher per v0.5.40 A6
    -- single-spend invariant); false otherwise drops chain walker to the
    -- next entry (which is empty for tail position; chain ends with
    -- no_effective_save_for_threat if W also skipped).
    lina_w_anti_gap = {
        short           = "w_stun",
        -- v0.5.55: prep_time / active_duration / catch_radius removed
        -- from SAVE_FIRE data. W's precision timing now lives INSIDE
        -- lina_w_anti_gap.fire body (constants W_LEAD=1.12,
        -- W_AOE_RADIUS=225 inlined there), matching Sniper's pattern
        -- where each save's .fire owns its own range/timing math
        -- instead of leaking it into chain-walker data.
        -- v0.5.47.1: .fire signature now consumes threat_caster + threat_mod
        -- which the chain walker passes (lib/defense.lua L566:
        -- fire_entry.fire(issue_intent, threat_caster, threat_mod)). The
        -- v0.5.46.3 predict-aim relied on state.cur_armed_caster which is
        -- only set in armed_post_fire; non-armed dispatch paths (channel
        -- start, cast point, proactive) saw nil and fell back to Lina
        -- origin which missed the actual caster (v0.5.47 demo log: WD
        -- Death Ward fired with aim=self_origin instead of WD position).
        -- Using the .fire param directly works for ALL dispatch paths.
        -- state.cur_armed_caster stays as a fallback for any caller that
        -- passes nil (e.g., a test harness that bypasses the chain walker).
        fire  = function(intent, threat_caster, threat_mod)
            local me = state.self_npc
            if not me then return false end
            if state.menu and state.menu.enable_w_anti_gap
               and not state.menu.enable_w_anti_gap:Get() then
                return false
            end
            local w = ability("lina_light_strike_array")
            if not w or not (Ability.GetLevel(w) > 0) or not Ability.IsReady(w) then
                return false
            end
            if NPC.IsChannellingAbility and NPC.IsChannellingAbility(me) then
                -- Don't auto-W while Lina is channelling her OWN cast (TP scroll /
                -- channeled item): the W would cancel it. v0.5.137.4: this now LOGS
                -- (was silent). The v0.5.137.2 caster-interrupt BYPASS was reverted
                -- -- the confirming demo proved NPC.IsChannellingAbility(me) is FALSE
                -- for a Life-Drain VICTIM (chan=n), so this gate never blocks an
                -- interrupt; the real Pugna bail was the menu toggle being off, not
                -- this gate, and the bypass was speculative. Keep it LOGGED so a
                -- future silent-bail hunt is a one-line grep, not three demos
                -- (check the menu toggle/config before deep debugging).
                tlog(2, "w_defensive_skip_channelling", {
                    intent = tostring(intent or ""),
                    mod    = tostring(threat_mod or "-"),
                })
                return false
            end
            local intent_s = tostring(intent or "")
            -- v0.5.46.2 user spec ("Even if PA blink is too fast it still
            -- better use W to run or fight. No reason to not do."): W is
            -- useful even when it can't stun the threat caster on arrival,
            -- because the 1.6s AoE catches whoever stays at Lina's pre-cast
            -- position 1.1s post-cast. For PA blink, AM blink, Slark pounce,
            -- Nyx vendetta, etc. the caster lands at Lina and stays committed
            -- to attacks; W catches them mid-attack and breaks the attack-
            -- speed chain, buying Lina 1.6s to TP / run / counter. The
            -- v0.5.45 intent-pattern (10 sub-1.1s arrivals) + 100u-melee
            -- gates + the v0.5.46 broad too-late belt were over-conservative;
            -- they treated "W can't stun the threat itself" as "W is wasted"
            -- but the opposite is true for the typical commit case. Removed
            -- v0.5.45 gates entirely; narrowed v0.5.46 belt to a small
            -- allowlist of mods that PHYSICALLY CARRY Lina away from her
            -- pre-cast position (W cast at Lina's old spot misses both Lina
            -- and the caster). Tusk snowball is the canonical case. Future
            -- candidates: Magnus Skewer + Tiny Toss + similar pulls/throws.
            -- Carry-Lina belt: skip W only when the threat's mod is in the
            -- (currently empty) allowlist AND the cur_armed_eta stash from
            -- armed_post_fire indicates we're firing too late to catch the
            -- caster's snowball endpoint. v0.5.47.1: also consult the
            -- threat_mod param so chain walker callers without an armed
            -- entry (channel start, cast point, etc) can also gate.
            local cur_mod = state.cur_armed_threat_mod or threat_mod
            if state.cur_armed_eta and state.cur_armed_eta < 1.0
               and cur_mod
               and state.W_skip_too_late_mods
               and state.W_skip_too_late_mods[cur_mod] then
                tlog(3, "w_defensive_skip_too_late_carry", {
                    intent  = intent_s,
                    cur_eta = string.format("%.2f", state.cur_armed_eta),
                    mod     = tostring(cur_mod),
                })
                return false
            end
            -- v0.5.113 (#4): skip when the threat caster is ALREADY hard-
            -- disabled past W's detonation -- the stun would overlap the
            -- live disable and waste most of its duration. Later dispatch
            -- attempts re-evaluate, so W fires as the disable runs out,
            -- exactly when the threat resumes. Self-resolving for armed
            -- homing threats too: a charge broken BY the disable clears its
            -- armed row via OnModifierDestroy (no wasted W), one that
            -- persists re-evaluates post-stun. Enum/API-guarded: anything
            -- unreadable keeps the legacy fire path.
            local _dis = threat_caster or state.cur_armed_caster
            if _dis and NPC.GetStatesDuration and MS
               and MS.MODIFIER_STATE_STUNNED and MS.MODIFIER_STATE_HEXED then
                local okd, durs = pcall(NPC.GetStatesDuration, _dis, {
                    [MS.MODIFIER_STATE_STUNNED] = true,
                    [MS.MODIFIER_STATE_HEXED]   = true,
                })
                if okd and type(durs) == "table" then
                    local rem = math.max(durs[MS.MODIFIER_STATE_STUNNED] or 0,
                                         durs[MS.MODIFIER_STATE_HEXED] or 0)
                    if rem > (state.w_lead()) then
                        tlog(3, "w_defensive_skip_already_disabled", {
                            intent = intent_s,
                            rem    = string.format("%.2f", rem),
                        })
                        return false
                    end
                end
            end
            local w_cost     = (Ability.GetManaCost and Ability.GetManaCost(w)) or 130
            -- v0.5.50.1: r_reserve only if R is leveled. At Lina lvl 1-5
            -- (pre-R) the 450 reserve has nothing to preserve and blocks
            -- defensive W -- v0.5.50 demo log showed w_defensive_skip_mana
            -- mana=435 need=550 at low-level Lina, repeatedly. Gate the
            -- reserve on Ability.GetLevel(R) > 0.
            local r_ab       = ability("lina_laguna_blade")
            local r_reserve  = (r_ab and Ability.GetLevel(r_ab) > 0) and 450 or 0
            local mana       = (NPC.GetMana and NPC.GetMana(me)) or 0
            if mana < (w_cost + r_reserve) then
                tlog(3, "w_defensive_skip_mana", {
                    mana      = string.format("%.0f", mana),
                    need      = string.format("%.0f", w_cost + r_reserve),
                    r_reserve = string.format("%.0f", r_reserve),
                })
                return false
            end

            -- v0.5.55: W timing window check. With the v0.5.51 chain-
            -- walker catalog gate gone, W's .fire body now owns the
            -- impact_t window decision (this used to live in
            -- armed_chain_peek). For homing_charge / homing_carry
            -- catalog mods, fire ONLY when impact_t in [W_LEAD,
            -- W_LEAD + W_AOE_RADIUS/eff_speed] (the v0.5.49 / v0.5.50.8
            -- geometric window: caster stunned before impact AND still
            -- within AoE at detonation). Out-of-window -> return false;
            -- the chain walker continues past W (no save fires this
            -- tick) and re-evaluates next tick.
            -- For channel_at_caster (WD) + cast_point_targeted (Lion)
            -- mods: no timing gate (window [0, inf] matches v0.5.51
            -- behavior). For non-catalog threats (Bara Nether Strike,
            -- etc.): no timing gate, legacy fire path.
            -- v0.5.115: segment-coverage aim handoff from the charge gate
            -- to the predict-aim below (one placement, computed once).
            local charge_aim_d, charge_seg
            local _w_caster_for_gate = threat_caster or state.cur_armed_caster
            if state.compute_arrival_time and threat_mod and _w_caster_for_gate then
                local _g_impact_t, _, _g_cat_entry, _g_speed =
                    state.compute_arrival_time(threat_mod, _w_caster_for_gate, me)
                if _g_impact_t and _g_cat_entry then
                    local _g_kind = _g_cat_entry.kind or ""
                    if _g_kind == "homing_charge" then
                        -- v0.5.115 SEGMENT-COVERAGE INTERCEPT (user
                        -- geometry: placeable 0..max range, 250 radius =
                        -- 500u diameter; history: v0.5.114.1 far
                        -- intercept, v0.5.114.5 no too_late, v0.5.114.6
                        -- no per-fire turn). v0.5.115.1: the math moved
                        -- into state.w_charge_intercept so this gate and
                        -- the armed-peek DISPATCH gate share the ONE
                        -- criterion (the peek's stale 1.12/225 twin was
                        -- holding the cast back until ~840u = "starting
                        -- the casting too late").
                        local castable, _g_aim, _g_near, _g_far, _g_range =
                            state.w_charge_intercept(_w_caster_for_gate, threat_mod)
                        if castable ~= nil then
                            if not castable then
                                -- only too_early exists (the far-intercept
                                -- wait); near charges always produce a
                                -- castable covering aim (no too_late,
                                -- v0.5.114.5).
                                tlog(3, "w_defensive_skip_window", {
                                    near   = string.format("%.0f", _g_near or -1),
                                    far    = string.format("%.0f", _g_far or -1),
                                    aim    = string.format("%.0f", _g_aim or -1),
                                    range  = string.format("%.0f", _g_range or -1),
                                    reason = "too_early",
                                    kind   = _g_kind,
                                    mod    = tostring(threat_mod),
                                })
                                return false
                            end
                            charge_aim_d = _g_aim
                            charge_seg   = string.format("%.0f-%.0f",
                                                         _g_near or 0, _g_far or 0)
                        end
                        -- helper nil: legacy fall-through (fire; the aim
                        -- block below has its own fallback computation).
                    elseif _g_kind == "homing_carry" then
                        -- carry-Lina (Tusk): the snowball must be met AT
                        -- Lina (it picks her up; there is no far-point
                        -- intercept), so the v0.5.112/113.1 arrival
                        -- window stays: live geometry + latency pad.
                        local W_LEAD, W_AOE_RADIUS = state.w_lead()
                        local W_PLAN = W_LEAD + K.W_INTERCEPT_MARGIN_S
                        local _g_upper = (_g_speed and _g_speed > 0)
                            and (W_PLAN + W_AOE_RADIUS / _g_speed)
                            or (W_PLAN + 0.20)
                        if _g_impact_t < W_LEAD or _g_impact_t > _g_upper then
                            tlog(3, "w_defensive_skip_window", {
                                impact_t = string.format("%.2f", _g_impact_t),
                                lower    = string.format("%.2f", W_LEAD),
                                upper    = string.format("%.2f", _g_upper),
                                speed    = string.format("%.0f", _g_speed or 0),
                                kind     = _g_kind,
                                mod      = tostring(threat_mod),
                            })
                            return false
                        end
                    elseif _g_kind == "leap" then
                        -- v0.5.142: a fast leap (Huskar Life Break ~0.46s max at
                        -- range 550 / speed 1200, Kez grapple, Slark pounce) often
                        -- arrives in LESS than W's ~0.95s cast-to-detonation lead,
                        -- so W lands AFTER the leap connects -- it stuns the caster
                        -- post-landing but can't prevent the hit/slow (v0.5.140
                        -- demo: Huskar _slow landed 3x, W stunned him late). When W
                        -- cannot intercept in time (impact_t < W_LEAD), the caster
                        -- is NOT combo-killable, AND an airborne self-save (WW/Eul)
                        -- is ready to take over, STEP ASIDE so the chain falls to
                        -- that airborne save (next in the airborne-first close_gap
                        -- backbone), which fires instantly by proximity. The guards
                        -- keep this never-worse: a killable caster KEEPS W (late
                        -- stun still feeds the v0.5.137 capitalize kill), and with
                        -- no airborne save ready W also stays (late stun beats no
                        -- save). Doubles as the WW-dodge TEST vehicle -- the brain
                        -- times the airborne save where a manual cast cannot
                        -- (v0.5.141 demo: manual WW too tight for the leap window).
                        -- If the demo shows the airborne save does NOT dodge Life
                        -- Break, revert this + go displacement-first for leaps
                        -- (Force/Pike/Blink = the Liquipedia-documented nullifiers:
                        -- disable / force-move / distance-cancel Huskar).
                        local W_LEAD = state.w_lead()
                        if _g_impact_t < W_LEAD then
                            local killable = state.combo_can_kill
                                and _w_caster_for_gate
                                and state.combo_can_kill(_w_caster_for_gate)
                            local _ww   = NPCLib.item and NPCLib.item(me, "item_wind_waker")
                            local _eul  = NPCLib.item and NPCLib.item(me, "item_cyclone")
                            -- v0.5.149: Blink is also a defer-target -- a 1200u blink fully
                            -- exits the leap's landing AoE (the Liquipedia "distance-cancel"
                            -- nullifier). Without it, when WW/Eul were both on CD (e.g. spent
                            -- on a Techies minefield) W fired the stun and Lina ATE the Blast
                            -- Off (demo: threat_unrecognized modifier_stunned x3). Now W steps
                            -- aside so the chain reaches item_blink (3rd in close_gap).
                            local _blink = NPCLib.item and NPCLib.item(me, "item_blink")
                            local dodge_ready =
                                (_ww   and Ability.IsReady and Ability.IsReady(_ww))
                                or (_eul  and Ability.IsReady and Ability.IsReady(_eul))
                                or (_blink and Ability.IsReady and Ability.IsReady(_blink))
                                or false
                            if (not killable) and dodge_ready then
                                tlog(2, "w_defensive_skip_window", {
                                    impact_t = string.format("%.2f", _g_impact_t),
                                    lower    = string.format("%.2f", W_LEAD),
                                    kind     = _g_kind,
                                    reason   = "leap_defer_airborne",
                                    mod      = tostring(threat_mod),
                                })
                                return false
                            end
                        end
                    end
                    -- channel_at_caster / cast_point_targeted: fall
                    -- through to fire (no timing constraint).
                end
                -- impact_t nil / cat_entry nil = no catalog entry; fall
                -- through to fire (legacy behavior for unmapped mods).
            end

            -- v0.5.105 (user-gated layer-2 W smart-chain review; scenario
            -- matrix in changelog v0.5.105): predicted-catch gate for the
            -- committed-attacker synthetic mods. W aims SELF (user rule:
            -- "smart chain of action and on herself") and detonates ~0.95s
            -- after issue (0.45 cast point + 0.5 delay) with a 225u AoE --
            -- it only has value when THE ATTACKER will be inside that circle
            -- at detonation. A melee attacker glued to Lina passes
            -- trivially; an approaching melee passes exactly when its
            -- arrival aligns with the detonation; a ranged attacker poking
            -- from 300-1100u NEVER passes (the v0.5.102 demo wasted w_stun
            -- x2 on a distant Sniper -- the "random W on self" complaint).
            -- Prediction via state.predict_target_pos (smoothed velocity);
            -- falls back to the attacker's current position. Real threat
            -- mods are untouched (the catalog/armed paths above own their
            -- own timing); the committed mods have no catalog entry so they
            -- reach here un-gated otherwise.
            local committed_catch_pos, committed_cluster_n  -- v0.5.112 (#2) / v0.5.113 (#3)
            if threat_mod == "lina_committed_attacker"
               or threat_mod == "lina_committed_attacker_ranged"
               or threat_mod == "lina_committed_attacker_melee" then
                local att = threat_caster or state.cur_armed_caster
                local lina_pos = Entity.GetAbsOrigin(me)
                local att_pos
                local w_lead_s, w_aoe = state.w_lead()  -- v0.5.112 (#1): was 0.95 / 225 literals
                -- v0.5.151: the CLUSTER path below keeps the Bara-margin horizon
                -- (w_plan_s = w_lead + K.W_INTERCEPT_MARGIN_S 0.345) for its pts[1]
                -- / centroid, byte-identical. The SINGLE-TARGET catch uses
                -- catch_plan_s (~1.12) instead: the 0.345 over-leads a near-Lina
                -- committed catch (see K.W_COMMITTED_LEAD_MARGIN_S).
                local w_plan_s     = w_lead_s + K.W_INTERCEPT_MARGIN_S        -- cluster (unchanged)
                local catch_plan_s = w_lead_s + K.W_COMMITTED_LEAD_MARGIN_S   -- single-target (~1.12)
                local w_range = FALLBACK_RANGES.W  -- v0.5.113: hoisted (catch + cluster both read it)
                if Ability.GetCastRange then
                    local okr, r = pcall(Ability.GetCastRange, w)
                    if okr and type(r) == "number" and r > 0 then w_range = r end
                end
                if att and Entity.IsEntity(att) then
                    att_pos = (state.predict_target_pos and state.predict_target_pos(att, w_plan_s))
                              or Entity.GetAbsOrigin(att)
                end
                if not (att_pos and lina_pos) then return false end
                -- v0.5.151 cover-both single-target placement: aim a 250-AoE that
                -- spans the attacker's CURRENT and PREDICTED positions so the stun
                -- lands whether he continues, stops, or reverses; skip when the band
                -- is too wide for one AoE (the "W way off Slark" whiff). "self"
                -- leaves committed_catch_pos nil so the self_origin path self-casts W
                -- (the glued attacker, unchanged). The cluster block below still runs
                -- on "catch"/"self" (it can override with a centroid), exactly as
                -- before; "skip" returns false here, mirroring the old out-of-range
                -- no_catch return. Preserves the v0.5.112 value case (stationary
                -- attacker: cur == pred so the midpoint == cur).
                local cur = Entity.GetAbsOrigin(att)
                local pred_catch = (state.predict_target_pos
                                    and state.predict_target_pos(att, catch_plan_s)) or cur
                local c_aim, c_kind, c_reason =
                    state.committed_catch_aim(cur, pred_catch, lina_pos, w_aoe, w_range)
                if c_kind == "skip" then
                    local cdx = (cur and (cur.x or 0) or 0) - (lina_pos.x or 0)
                    local cdy = (cur and (cur.y or 0) or 0) - (lina_pos.y or 0)
                    tlog(2, "w_defensive_skip_no_catch", {
                        intent = intent_s,
                        mod    = tostring(threat_mod),
                        reason = c_reason,
                        d_cur  = string.format("%.0f", math.sqrt(cdx * cdx + cdy * cdy)),
                        range  = string.format("%.0f", w_range),
                    })
                    return false
                elseif c_kind == "catch" then
                    committed_catch_pos = c_aim
                end
                -- c_kind == "self": committed_catch_pos stays nil (self-cast).
                -- v0.5.113 (#3, the v0.5.34 max-stun doctrine applied to
                -- defense): with 2+ committed attackers whose PREDICTED
                -- positions fit ONE AoE, aim the centroid instead of the
                -- single dispatch caster -- one W, multiple stuns. Runs
                -- only on committed W dispatches (rare); enumeration is
                -- capped at the ranged engage radius. The centroid must
                -- cover EVERY clustered prediction with a 40u rim margin
                -- AND sit inside W's cast range, else the single-target
                -- aim above stands unchanged.
                local okh, near = pcall(Entity.GetHeroesInRadius, me,
                                        K.LINA_ATTACK_ENGAGE_RADIUS_RANGED,
                                        Enum.TeamType.TEAM_ENEMY)
                if okh and near and #near > 1 then
                    local pts, n = { att_pos }, 1
                    for i = 1, #near do
                        local h = near[i]
                        if h and h ~= att and state.is_committed_attacker_on_self(h) then
                            local p = (state.predict_target_pos and state.predict_target_pos(h, w_plan_s))
                                      or (Entity.GetAbsOrigin and Entity.GetAbsOrigin(h))
                            if p then n = n + 1; pts[n] = p end
                        end
                    end
                    if n >= 2 then
                        local cx, cy = 0, 0
                        for i = 1, n do
                            cx = cx + (pts[i].x or 0)
                            cy = cy + (pts[i].y or 0)
                        end
                        cx, cy = cx / n, cy / n
                        local fit, rim = true, w_aoe - 40
                        for i = 1, n do
                            local ddx = (pts[i].x or 0) - cx
                            local ddy = (pts[i].y or 0) - cy
                            if (ddx * ddx + ddy * ddy) > rim * rim then
                                fit = false
                                break
                            end
                        end
                        local cdx = cx - (lina_pos.x or 0)
                        local cdy = cy - (lina_pos.y or 0)
                        if fit and (cdx * cdx + cdy * cdy) <= w_range * w_range then
                            committed_catch_pos = { x = cx, y = cy, z = lina_pos.z or 0 }
                            committed_cluster_n = n
                        end
                    end
                end
            end

            -- v0.5.46.3 predict-aim: W has 1.12s prep (0.6 cast point +
            -- 0.5 delay + ~0.02 cast animation). Aiming at Lina's CURRENT
            -- position misses fast Bara (Bara still en-route at fire+1.12),
            -- misses Tusk snowball (snowball carries Lina away from old
            -- spot), misses any non-stationary committed caster. Aim at
            -- the threat caster's predicted position W_LEAD seconds ahead
            -- via state.predict_target_pos (smoothed velocity from
            -- Geometry.PredictPos sampled in OnUpdateEx). This single change
            -- handles homing-to-Lina (Bara stops AT Lina, predicted pos =
            -- Lina origin), carry-Lina (Tusk snowball endpoint past Lina),
            -- and chase-Lina (any moving committed attacker) uniformly.
            -- Falls back to Lina origin if caster handle is missing
            -- (proactive Dispatch with no armed entry, dead caster, etc.).
            -- v0.5.48 Phase 2 aim resolution: per-mod policy from catalog
            -- (lib/threat_data.lua THREAT_ARRIVAL_TIMING.impact_pos). The
            -- catalog encodes "self" (defender position) vs "caster"
            -- (caster position; channel-interrupt). For mods NOT in the
            -- catalog, fall back to v0.5.47.2 W_aim_at_caster_mods
            -- allowlist + Lina-origin default.
            -- Tlog aim field: catalog_self / catalog_caster / self_origin /
            -- caster_origin / self_origin_fallback.
            local pos
            local caster = threat_caster or state.cur_armed_caster
            local aim_via
            -- v0.5.112 (#2): the committed catch block above resolved an
            -- at-attacker aim (predicted position inside cast range but
            -- outside the self-centered AoE). Committed mods have no
            -- catalog entry, so the catalog block below leaves this pos
            -- untouched. Re-wrapped in Vector() so issue_cast_position
            -- always gets userdata (the v0.5.50.5 lesson).
            if committed_catch_pos then
                pos     = Vector(committed_catch_pos.x or 0,
                                 committed_catch_pos.y or 0,
                                 committed_catch_pos.z or 0)
                aim_via = committed_cluster_n and "committed_cluster"
                          or "committed_catch"  -- v0.5.113 (#3) / v0.5.112 (#2)
            end
            -- v0.5.50.8: predict-aim block RESTORED from v0.5.50.6 to
            -- pair with the wide geometric upper. With aim-at-self
            -- (plain catalog_self), upper-bound fires put the caster
            -- at 225u from Lina at detonation = AT the AoE edge; the
            -- 1-2 frame position lag + caster collision radius makes
            -- the edge catch fragile (this was the v0.5.50.3 visual-
            -- miss concern that motivated the 0.10s tightening, and
            -- the v0.5.50.7 demo showed the same fragility once the
            -- upper widened back to the geometric bound).
            -- Predict-aim centers the AoE on the caster's predicted
            -- position at detonation, so the caster is at the AoE
            -- CENTER for every in-window fire:
            --   d_at_det = max(0, d_now - eff_speed * W_LEAD)
            --   aim      = lina + unit(lina -> caster) * d_at_det
            -- eff_speed is the 4th return of compute_arrival_time (the
            -- avg-during-prep speed from the v0.5.50 ramp model), so
            -- the prediction is self-consistent with the gate's
            -- impact_t computation. max(0, ...) caps at Lina because
            -- homing_charge stops at the target. With the wide window
            -- + predict-aim combined, the catch is robust to speed-
            -- model drift, frame-rate variation, and order-issue lag.
            local d_now_dbg, d_at_det_dbg, eff_speed_dbg
            if state.compute_arrival_time and threat_mod and caster then
                local _, impact_pos, cat_entry, eff_speed =
                    state.compute_arrival_time(threat_mod, caster, me)
                if impact_pos then
                    pos     = impact_pos
                    aim_via = (cat_entry and cat_entry.impact_pos == "caster")
                              and "catalog_caster" or "catalog_self"
                    if cat_entry and cat_entry.kind == "homing_charge"
                       and eff_speed and eff_speed > 0
                       and Entity.IsEntity(caster)
                       and Entity.GetAbsOrigin then
                        local cur_pos  = Entity.GetAbsOrigin(caster)
                        local lina_pos = Entity.GetAbsOrigin(me)
                        if cur_pos and lina_pos then
                            local dx = (cur_pos.x or 0) - (lina_pos.x or 0)
                            local dy = (cur_pos.y or 0) - (lina_pos.y or 0)
                            local d_now = math.sqrt(dx * dx + dy * dy)
                            if d_now > 0 then
                                -- v0.5.114 precise ramp intercept (user:
                                -- "instead of a fixed value ... check the
                                -- real values for bara"): travel during
                                -- the W lead is the EXACT time-integrated
                                -- ramp (TD.RampTravel over the remaining
                                -- wind-up from the armed_t stamp, accel
                                -- from per-level KV) instead of avg-speed
                                -- x lead. K.W_INTERCEPT_MARGIN_S survives
                                -- only as the small order-latency pad
                                -- (0.10); the model error it used to
                                -- blanket is now integrated away.
                                local W_LEAD = state.w_lead() + K.W_INTERCEPT_MARGIN_S
                                local d_at_det
                                if charge_aim_d then
                                    -- v0.5.115: the gate computed the
                                    -- segment-coverage placement; gate and
                                    -- aim MUST share the one placement.
                                    d_at_det = charge_aim_d
                                else
                                    -- fallback (gate did not run: no
                                    -- catalog/kinematics): the v0.5.114.6
                                    -- no-turn predict-aim.
                                    local _ck_l, _ck_a, _ck_r = TD.ChargeRampKinematics(
                                        cat_entry, caster, state.item_kv,
                                        state.bara_charge_elapsed and state.bara_charge_elapsed(caster))
                                    local bara_travel = TD.RampTravel(_ck_l, _ck_a, _ck_r, W_LEAD)
                                    if not (bara_travel and bara_travel > 0) then
                                        bara_travel = eff_speed * W_LEAD
                                    end
                                    d_at_det = math.max(0, d_now - bara_travel)
                                end
                                local unit_x = dx / d_now
                                local unit_y = dy / d_now
                                pos = Vector(
                                    (lina_pos.x or 0) + unit_x * d_at_det,
                                    (lina_pos.y or 0) + unit_y * d_at_det,
                                    lina_pos.z or 0
                                )
                                aim_via       = "catalog_predict"
                                d_now_dbg     = d_now
                                d_at_det_dbg  = d_at_det
                                eff_speed_dbg = eff_speed
                            end
                        end
                    end
                end
            end
            -- v0.5.47.2 legacy fallback for mods not in catalog yet.
            if not pos then
                if threat_mod and state.W_aim_at_caster_mods
                   and state.W_aim_at_caster_mods[threat_mod]
                   and caster and Entity.IsEntity(caster) and Target.IsAlive
                   and Target.IsAlive(caster) then
                    pos     = Entity.GetAbsOrigin and Entity.GetAbsOrigin(caster)
                    aim_via = "caster_origin"
                end
            end
            if not pos then
                pos     = Entity.GetAbsOrigin and Entity.GetAbsOrigin(me)
                aim_via = caster and "self_origin" or "self_origin_fallback"
            end
            if not pos then return false end
            tlog(2, "w_defensive_fire", {
                intent = tostring(intent),
                mana   = string.format("%.0f", mana),
                w_cost = string.format("%.0f", w_cost),
                aim    = aim_via,
                mod    = tostring(threat_mod or "-"),
                -- v0.5.50.8 predict-aim debug fields: present only when
                -- the catalog_predict branch ran (homing_charge with
                -- ramped speed). Lets the demo log verify the math:
                --   d_now  = caster's current distance from Lina
                --   d_det  = predicted caster distance at W detonation
                --   speed  = avg-during-prep speed (ramp model)
                cluster = committed_cluster_n and tostring(committed_cluster_n) or nil,  -- v0.5.113 (#3)
                seg    = charge_seg,  -- v0.5.115: covered detonation band (near-far)
                d_now  = d_now_dbg    and string.format("%.0f", d_now_dbg)    or nil,
                d_det  = d_at_det_dbg and string.format("%.0f", d_at_det_dbg) or nil,
                speed  = eff_speed_dbg and string.format("%.0f", eff_speed_dbg) or nil,
            })
            -- v0.5.137 W-capitalize: if this defensive W stuns a GAP-CLOSER
            -- (close_gap category) or a COMMITTED attacker, stamp the window so
            -- state.w_capitalize_tick can commit the combo on the stunned caster
            -- IF it is killable. NOT for zones/channels/ally-interrupts (those
            -- aim W at a caster we are not setting up to dive-kill). `caster` is
            -- the stunned threat caster (the aim target); state.frame_t is live
            -- (dispatch runs inside OnUpdateEx).
            do
                local is_gap = threat_mod and TD.CategoryOf
                               and TD.CategoryOf(threat_mod) == "close_gap"
                local is_committed = type(intent) == "string"
                               and intent:find("committed_attacker", 1, true) ~= nil
                if (is_gap or is_committed) and caster and Entity.IsEntity(caster) then
                    state.w_capitalize_t      = state.frame_t
                    state.w_capitalize_target = caster
                end
            end
            return issue_cast_position(intent, w, pos, "def")
        end,
    },
}

-- v0.5.108: merge the hero-agnostic item save bodies onto the ability literal.
for _name, _entry in pairs(ItemSaves.build(SAVE_CFG)) do
    SAVE_FIRE[_name] = _entry
end

-- v0.5.17 Track 1: expose SAVE_FIRE map for the in-Brain test harness so a
-- test can call SAVE_FIRE[item].fire(intent) directly and assert the return
-- value (e.g. G4 same-active-mod guards returning false). Read-only handle;
-- mutating it at runtime would break the SAVE_FIRE chain dispatcher.
state.lina_save_fire = SAVE_FIRE

-- v0.5.11 PE-03 (Sniper S29 port @ Sniper.lua L5990-6028): Pike fresh-item
-- first-cast work-around. State slots are lazily declared here (rather than in
-- the canonical state.* declarations block near top-of-module) to keep the port self-contained for the v0.5.12
-- back-out path -- flipping the whole block off restores v0.5.10 behaviour
-- without touching the canonical state declarations. The tick is invoked from
-- callbacks.OnUpdateEx (see armed_threats_tick neighbours) once per frame.
state.pike_primed     = false   -- positive-proof flag: cooldown observed > 0
state.pike_prime_done = false   -- one-shot guard on the throwaway PRIME cast
state.pike_reissue    = nil     -- {caster, t, self_cast} stamped by SAVE_FIRE.item_hurricane_pike.fire
-- v0.5.58 Phase 5 slice 2: generalized from state.pending_pike_self.
-- {caster, away_pt, deadline, intent, item_name} armed by ANY self-push
-- save's turn-then-fire harness (Pike + Force) and consumed by
-- state.pending_self_push_tick once facing is within 30deg of away_pt.
state.pending_self_push = nil
-- v0.5.62 Phase 5 slice 3 fix: armed by state.queue_safe_post_move when EUL
-- or WW casts. Carries dest + modifier_name + deadline_restore + observed
-- and issued latches. Consumed by state.pending_post_airborne_move_tick
-- which waits for the airborne modifier to appear then disappear, then
-- issues the move. Native HR/OW stays paused for the whole pending lifetime
-- so the baseline orbwalker cannot preempt the post-airborne MOVE order.
state.pending_post_airborne_move = nil
-- GREP: PIKE_PRIME_TICK_DEF (call site lives in callbacks.OnUpdateEx).
state.pike_prime_tick = function()
    local me = state.self_npc
    if not me or not Entity.IsEntity(me) then return end
    local pike = NPCLib.item(me, "item_hurricane_pike")
    if not pike then return end
    -- Positive proof Pike has fired at least once: cooldown is now > 0.
    if not state.pike_primed and Ability.GetCooldown
       and (Ability.GetCooldown(pike) or 0) > 0 then
        state.pike_primed = true
    end
    if state.pike_primed then
        state.pike_reissue = nil
        return
    end
    -- DOUBLE-ISSUE: a real save fired an un-primed Pike -> re-issue once.
    local ri = state.pike_reissue
    if ri then
        state.pike_reissue = nil
        if (now() - (ri.t or 0)) <= 0.4
           and ri.caster and Entity.IsEntity(ri.caster)
           and Target.IsAlive(ri.caster)
           and NPCLib.item_ready(state.self_npc, "item_hurricane_pike") then
            local ok
            if ri.self_cast then
                ok = issue_item_self("pike_reissue", "def", pike)
            else
                ok = issue_item_target("pike_reissue", "def", pike, ri.caster)
            end
            if ok then
                tlog(1, "pike_reissue", { caster = uname(ri.caster), self_cast = ri.self_cast and "y" or "n" })
            end
        end
        return
    end
    -- PRIME: one throwaway Pike-on-self when un-primed and genuinely safe.
    if state.pike_prime_done then return end
    if not NPCLib.item_ready(state.self_npc, "item_hurricane_pike") then return end
    if state.count_engaged_enemies and state.count_engaged_enemies() > 0 then return end
    if (now() - (state.combo_press_t or 0)) < 3.0 then return end
    if issue_item_self("pike_prime", "def", pike) then
        state.pike_prime_done = true
        tlog(1, "pike_prime", {})
    end
end

-- v0.5.75 lib-first lift (bucket B + C + D): the 5 self-displacement
-- save helpers below moved to lib/escape.lua. Lina-side bodies become
-- 3-5 line aliases that pass state.self_npc as `me` and state.escape_cfg
-- as the callback bundle. Pattern mirrors v0.5.74's
-- state.compute_arrival_time alias over ThreatData.ComputeArrivalTime.
-- Sniper.lua intentionally untouched in v0.5.75 (his pike_self_reposition
-- duplicate at ~5790-5910 can opt in later by installing his own cfg).
--
-- cfg shape: see lib/escape.lua EscapeCfg annotation. The Pike-specific
-- pike_reissue stamp lives in on_self_cast so the lib has no idea Pike
-- exists beyond the "item_hurricane_pike" string used as a tlog short
-- name selector.
state.escape_cfg = {
    safe_issue      = safe_issue,
    issue_item_self = issue_item_self,
    tlog            = tlog,
    now             = now,
    uname           = uname,
    hero_key        = HERO_KEY,
    layer           = "def",
    item_get        = NPCLib.item,
    item_ready      = NPCLib.item_ready,
    on_self_cast    = function(item_name, me)
        if item_name == "item_hurricane_pike" and not state.pike_primed then
            state.pike_reissue = { caster = me, t = now(), self_cast = true }
        end
    end,
}

-- v0.5.75 alias over Escape.ComputeSafeDest (lifted from Lina v0.5.60).
state.compute_safe_dest = function(threat_caster, push_dist)
    -- v0.5.130: push away from where the threat is HEADING, not where it IS.
    -- For a charging threat, away-from-current = toward its landing (the v0.5.129
    -- WW lesson). predict_target_pos (smoothed velocity) -> the lib pushes away
    -- from the predicted point; a stationary threat predicts ~current = no-op.
    -- ~0.5s lead is enough to predict a fast charge PAST Lina (flipping the
    -- escape to the far side); tunable. Reaches Blink (1200u) here + Force/Pike
    -- via state.try_self_push below. (predict_target_pos is a state.* field
    -- resolved at call time, so the later definition is fine.)
    local tp = threat_caster and state.predict_target_pos
               and state.predict_target_pos(threat_caster, 0.5) or nil
    return Escape.ComputeSafeDest(state.self_npc, threat_caster, push_dist, tp)
end

-- v0.5.75 alias over Escape.TrySelfPush (lifted from Lina v0.5.58).
-- Lib returns (pending|nil, ok). When pending is non-nil, the lib armed
-- a turn-then-fire and Lina stashes it for pending_self_push_tick. nil
-- means either immediate cast OR no safe dest; caller's `ok` decides
-- whether the chain falls through to the next save.
state.try_self_push = function(intent, item, item_name, push_dist, threat_caster)
    -- v0.5.130: same predict-aware push as state.compute_safe_dest (Force/Pike).
    -- The turn-then-fire harness aims Lina at the safe dir before pushing, so a
    -- corrected (away-from-where-the-threat-is-heading) dir is what she pushes to.
    local tp = threat_caster and state.predict_target_pos
               and state.predict_target_pos(threat_caster, 0.5) or nil
    local pending, ok = Escape.TrySelfPush(state.self_npc, intent, item,
                                            item_name, push_dist,
                                            threat_caster, state.escape_cfg, tp)
    if pending then state.pending_self_push = pending end
    return ok
end

-- v0.5.75 alias over Escape.QueueSafePostMove (lifted from Lina v0.5.60,
-- rewritten v0.5.62 + v0.5.63 + v0.5.64). EUL / WW only; the lib body
-- documents the 3-version evolution + the moves_during_airborne switch
-- (WW=true per Liquipedia 300 MS movable, EUL=false per Liquipedia full
-- disable).
state.queue_safe_post_move = function(intent, push_dist, threat_caster,
                                       modifier_name, moves_during_airborne)
    local pending = Escape.QueueSafePostMove(state.self_npc, intent, push_dist,
                                              threat_caster, modifier_name,
                                              moves_during_airborne,
                                              state.escape_cfg)
    if pending then state.pending_post_airborne_move = pending end
    return pending ~= nil
end

-- v0.5.75 alias over Escape.PostAirborneMoveTick (lifted from Lina v0.5.63).
-- Lib returns the (possibly nil) updated pending; Lina stashes back.
state.pending_post_airborne_move_tick = function()
    state.pending_post_airborne_move = Escape.PostAirborneMoveTick(
        state.self_npc, state.pending_post_airborne_move, state.escape_cfg)
end

-- v0.5.75 alias over Escape.SelfPushTick (lifted from Lina v0.5.58).
state.pending_self_push_tick = function()
    state.pending_self_push = Escape.SelfPushTick(
        state.self_npc, state.pending_self_push, state.escape_cfg)
end

-- v0.5.76 Pike-advance pick: decision-support primitive for offensive Pike
-- self-cast toward a target. Returns (landing, risk_score, breakdown) so
-- callers (combo system, HUD probe, future auto-engage) can fire / skip
-- based on a threshold. Lib does the geometry + risk math (visible enemies
-- proximity + fog probable-position via Hero.GetLastMaphackPos /
-- GetLastVisibleTime). Pike push is 600u along facing-toward-target.
--
-- Suggested threshold (caller-chosen, no auto-fire wired yet):
--   score <= 30  safe-to-advance      (0-1 distant visible enemies)
--   30 < score <= 60  risky-but-survivable
--   score > 60  abort                 (multiple close enemies or fog stack)
state.pike_advance_pick = function(target)
    return Escape.ComputeAdvanceDest(state.self_npc, target, 600, {
        engage_radius = 800,
        max_ms        = 700,
        now           = now,
    })
end

-- v0.5.77 fog-aware shared primitives. lib/escape.lua extracted FogSnapshot
-- as the underlying enemy-state scan; these 5 aliases expose it + 4
-- consumers (PossibleGankers/GankImminent, MissingFromMap, InitiatorAccount-
-- edFor, SafestSpotNear). No auto-action wired in Lina -- pure decision
-- support for combo / HUD / future slices.
--
-- Pattern is identical to state.pike_advance_pick (v0.5.76): pass
-- state.self_npc + opts bundle, return lib result verbatim. Threshold
-- defaults match the user-picked v0.5.77 design (2 enemies arrivable in 4s
-- for gank, 5s for missing-from-map).
local _fog_opts = { max_ms = 700, now = now }

state.fog_snapshot = function()
    return Escape.FogSnapshot(state.self_npc, _fog_opts)
end

-- Caller may pass an explicit pos (Vector) or omit for "at Lina's current
-- position". Returns the full PossibleGankers result (gankers list +
-- summary). Sorted by eta_seconds ascending; summary has count + soonest.
state.possible_gankers = function(pos, eta_s)
    local me = state.self_npc
    local p = pos or (me and Entity.GetAbsOrigin(me)) or nil
    if not p then return { gankers = {}, summary = { count = 0 } } end
    return Escape.PossibleGankers(me, p, eta_s or 4.0, _fog_opts)
end

-- Convenience predicate. Defaults: 4s window, 2 enemies (the user-picked
-- "common 2-man gank" signal). Returns (bool, ganker_list).
state.gank_imminent_self = function(eta_s, min_count)
    local me = state.self_npc
    local p = me and Entity.GetAbsOrigin(me) or nil
    if not p then return false, {} end
    return Escape.GankImminent(me, p, eta_s or 4.0, min_count or 2, _fog_opts)
end

-- Rotation tracker. Returns list of {entity, age, last_pos} for enemies
-- off-minimap >= min_age_s seconds. Default 5s. Sorted longest-missing first.
state.missing_from_map = function(min_age_s)
    return Escape.MissingFromMap(state.self_npc, min_age_s or 5.0, _fog_opts)
end

-- Initiator-accounted-for predicate. Pass list of npc_dota_hero_* names;
-- returns {accounted, missing, visible, unmatched}. Caller decides what
-- counts as an initiator (typical: Magnus, Tide, Enigma, Earthshaker).
state.initiators_accounted_for = function(names)
    return Escape.InitiatorAccountedFor(state.self_npc, names or {}, _fog_opts)
end

-- Safest-spot grid picker. Samples 8 cardinal+diagonal points at `radius`
-- plus current pos; returns (best_pos, best_score). Default radius 800u.
-- One FogSnapshot shared across all 9 scores internally.
state.safest_spot_near = function(radius)
    return Escape.SafestSpotNear(state.self_npc, radius or 800, {
        engage_radius = 800, max_ms = 700, now = now,
    })
end

-- v0.5.92 offensive Blink-in helpers (design: Lina/BLINK_IN_DESIGN.md).
local _blink_in_opts = { max_ms = 700, now = now }

-- v0.5.95.1 crash-fix: cast_range_of is a module-local defined ~1600 lines below
-- this block, so calling it here resolved as a nil global and crashed the tick
-- (Lina.lua:2282, the TF blink-in path -- blink_in_tf_in_range runs BEFORE the
-- toggle gate, so it broke TF even with the toggles OFF). Mirror cast_range_of
-- inline: ability (line 343) + Ability.GetCastRange + FALLBACK_RANGES (line 201)
-- are all in scope here. state.* so it adds no module-local (the 200-local limit).
state.blink_w_range = function()
    local a = ability("lina_light_strike_array")
    if a and Ability.GetCastRange then
        local ok, r = pcall(Ability.GetCastRange, a)
        if ok and type(r) == "number" and r > 0 then return r end
    end
    return FALLBACK_RANGES.W
end

-- Thin alias over the lib landing-picker: 1200u blink reach, W range as engage.
state.blink_in_pick = function(aim_pos)
    local w_range = state.blink_w_range()
    return Escape.BlinkInLanding(state.self_npc, aim_pos, 1200, w_range, _blink_in_opts)
end

-- Cast Blink Dagger at a ground position on the AGGRESSIVE layer (reuses the
-- same issue path the escape-Blink uses at issue_item_position).
state.issue_blink_to = function(pos, intent)
    local me = state.self_npc
    local it = me and NPCLib.item(me, "item_blink")
    if not (it and pos) then return false end
    return issue_item_position(intent, "agg", it, pos)
end

-- Any non-Blink escape item ready (initiate mode needs an out, since the
-- offensive blink leaves Blink on cooldown).
state.has_exit_item = function(me)
    for _, name in ipairs({ "item_force_staff", "item_hurricane_pike",
                            "item_cyclone", "item_wind_waker" }) do
        if NPCLib.item_ready(me, name) then return true end
    end
    return false
end

-- Lina HP fraction 0..1 (verified Entity.* accessors; degrades to 1.0).
state.blink_in_hp_frac = function(me)
    if not (me and Entity.IsAlive and Entity.IsAlive(me)
            and Entity.GetHealth and Entity.GetMaxHealth) then return 1.0 end
    local h, m = Entity.GetHealth(me), Entity.GetMaxHealth(me)
    if not (h and m and m > 0) then return 1.0 end
    return h / m
end

state.blink_in_skip = function(reason)
    tlog(2, "blink_in_skip", { reason = reason })
end

-- Range predicate for TF cluster blink-in: true when the cluster center is
-- already within W range (no blink needed).
state.blink_in_tf_in_range = function(center)
    local me = state.self_npc
    local mp = me and Entity.GetAbsOrigin(me)
    if not (mp and center) then return true end       -- no info -> treat as in range (skip blink)
    local w_range = state.blink_w_range()
    local dx, dy = center.x - mp.x, center.y - mp.y
    return (dx * dx + dy * dy) <= (w_range * w_range)
end

-- Shared offensive blink-in gate. aim_pos = target pos (starter) or cluster
-- center (TF). kill_confirmed = a kill is locked on the aim. cluster_n = hero
-- count at the aim (1 for single-target). Returns true if a blink was issued
-- (caller must then `return` for the tick; next tick the in-range ladder fires).
state.try_blink_in = function(ctx, aim_pos, name, kill_confirmed, cluster_n)
    local m  = state.menu
    local me = state.self_npc
    if not (m and me and aim_pos) then return false end
    local kill_on     = m.blink_in_kill and m.blink_in_kill:Get()
    local initiate_on = m.blink_in_initiate and m.blink_in_initiate:Get()
    if not (kill_on or initiate_on) then return false end       -- feature off

    -- anti-spam latch: do not re-issue within 0.3s (Blink CD covers longer gaps).
    if (now() - (state.blink_in_fired_t or 0)) < 0.3 then return false end

    -- base gates
    if not NPCLib.item_ready(me, "item_blink") then state.blink_in_skip("not_ready"); return false end
    if Damage and Damage.GetRecentDamage then
        local ok, dmg = pcall(Damage.GetRecentDamage, me, 3.0)
        if ok and type(dmg) == "number" and dmg > 0 then state.blink_in_skip("broken"); return false end
    end
    -- v0.5.95 reserve the dagger for the engine's defensive dodge: do NOT blink
    -- offensively while a threat is incoming (an armed homing threat, or a forming
    -- gank). If the engine wants the dagger to escape, leave it for the engine
    -- (the user's "do not fight the engine" direction). The v0.5.94 capitalize
    -- path handles the case where the engine DID blink.
    if next(state.armed_threats) ~= nil
       or (state.gank_imminent_self and state.gank_imminent_self()) then
        state.blink_in_skip("reserve_defense"); return false
    end
    -- v0.5.95 crash-fix: compute the W+Q+R mana cost inline. ability_mana is a
    -- module-local defined ~2000 lines below, so calling it here resolved as a
    -- nil global and crashed in v0.5.92 (Lina.lua:2308). `ability` (line 343) +
    -- the canonical ability names + Ability.GetManaCost ARE in scope here.
    local function _amana(n)
        local a = ability(n)
        return (a and Ability.GetManaCost and (Ability.GetManaCost(a) or 0)) or 0
    end
    local cost_wqr = _amana("lina_light_strike_array")
                     + _amana("lina_dragon_slave") + _amana("lina_laguna_blade")
    if (ctx.mana or 0) < cost_wqr then state.blink_in_skip("no_mana"); return false end

    local landing, risk, reachable = state.blink_in_pick(aim_pos)
    if not (landing and reachable) then state.blink_in_skip("unreachable"); return false end

    -- mode select: kill-commit takes priority when a kill is confirmed.
    local mode, risk_cap
    if kill_on and kill_confirmed then
        mode     = "kill"
        risk_cap = 60  -- v0.5.172: blink_in_kill_risk hardcoded 60
    elseif initiate_on then
        mode     = "initiate"
        risk_cap = 30  -- v0.5.172: blink_in_initiate_risk hardcoded 30
        -- v0.5.97 fix #7 (wire the dead gate; best practice = hit the most targets):
        -- blink-INITIATE (no confirmed kill) requires a >=2-hero cluster, so the brain
        -- commits the dagger + WQR onto a multi-hero pile, never a lone target. The
        -- pre-v0.5.97 gate `(cluster_n or 1) < 2 and ~= 1` was DEAD (true only for
        -- cluster_n==0, which never reaches here). KILL mode never enters this initiate
        -- branch, so single-target kill commits still blink. The TF site passes the real
        -- enemy_cluster_center count; the starter site passes 1 -> starter-initiate is
        -- kill-only (no lone-target initiate overcommit).
        if (cluster_n or 1) < 2 then
            state.blink_in_skip("cluster_small"); return false
        end
        if not state.has_exit_item(me) then state.blink_in_skip("no_exit"); return false end
        local hp_floor = 40  -- v0.5.172: blink_in_initiate_hp hardcoded 40
        if state.blink_in_hp_frac(me) * 100 < hp_floor then state.blink_in_skip("hp_floor"); return false end
    else
        return false                                            -- kill mode off and no kill
    end
    if risk > risk_cap then state.blink_in_skip("fog_risk"); return false end

    local intent = "blink_in_" .. mode .. "_" .. (name or "t")
    local ok = state.issue_blink_to(landing, intent)
    if ok then
        state.blink_in_fired_t = now()
        state.brain_blinked_t  = now()   -- v0.5.95: tag so the v0.5.94 engine-blink
                                         -- detector does NOT treat our own blink as
                                         -- an engine blink (the brain-cast has its
                                         -- own next-tick combo; no double-fire).
        tlog(1, "blink_in_fire", {
            mode = mode, aim = name or "?",
            x = string.format("%.0f", landing.x),
            y = string.format("%.0f", landing.y),
            risk = string.format("%.0f", risk),
            kill = kill_confirmed and "y" or "n",
        })
    end
    return ok
end

-- v0.5.75 dead-code deletion: state.danger_at_pos + state.safe_push_destination
-- (the older permissive shape pre-dating the lib/escape extraction at v0.5.57)
-- removed. Only call sites were each other; Force / Pike self-cast switched to
-- state.try_self_push (lib's Escape.PickDir + ComputeSafeDest path) in v0.5.58.
-- Lib has Escape.DangerAtPos + Escape.SafePushDestination for any caller that
-- needs them.

-- Hurricane Pike enemy cast range (live KV; 425 in 7.41C). Gates the
-- enemy-target Pike escape (the Sniper-style facing-independent push).
state.pike_enemy_range = function()
    local me = state.self_npc
    local pike = me and NPC.GetItem and NPC.GetItem(me, "item_hurricane_pike", true)
    if pike and Ability.GetLevelSpecialValueFor then
        local ok, v = pcall(Ability.GetLevelSpecialValueFor, pike, "cast_range_enemy")
        if ok and type(v) == "number" and v > 0 then return v end
    end
    return 425
end

local function save_is_ready(save_name)
    if save_name == "lina_flame_cloak" then return ability_ready("lina_flame_cloak") end
    if save_name == "lina_w_anti_gap" then return ability_ready("lina_light_strike_array") end  -- v0.5.44 W anti-gap
    if save_name == "item_ethereal_blade_self" then
        return NPCLib.item_ready(state.self_npc, "item_ethereal_blade")
    end
    return NPCLib.item_ready(state.self_npc, save_name)
end

-- Ability-based saves fail silently while Lina is muted/silenced; the chain
-- must fall through to item-based saves (HERO_PROMPT lesson, Sniper v6.15.41).
local ABILITY_SAVES = { lina_flame_cloak = true, lina_w_anti_gap = true }  -- v0.5.44 W anti-gap
local function self_can_cast_abilities()
    local me = state.self_npc
    if not me then return false end
    if NPC.IsSilenced and NPC.IsSilenced(me) then return false end
    if MS and MS.MODIFIER_STATE_MUTED and NPC.HasState then
        local ok, muted = pcall(NPC.HasState, me, MS.MODIFIER_STATE_MUTED)
        if ok and muted then return false end
    end
    return true
end

-- v0.5.0: resolve_save_order moved into lib/defense.lua (Dispatcher:ResolveSaveOrder).
-- Hero-side data tables (CH.DEFAULT_SAVE_CHAIN, LINA_SAVE_OVERRIDES,
-- PATCHED_RECOMMENDED_SAVES, CATEGORY_CHAINS, state.ANIM_SAVE_OVERRIDES) are
-- passed to Defense.New below. See Lina/LIB_DEFENSE_EXTRACTION.md.

--------------------------------------------------- Layer 2 firing dispatch --
K.LAYER2_REACTION_WINDOW = 0.1   -- min spacing between any two save dispatches
-- v0.5.39 P1-M2: dropped SAVE_CAST_PROTECT_S + state.save_cast_protect_until_t.
-- The planned DR5 OnPrepareUnitOrders consumer was never wired up (framework
-- triggerCallBack=false bypassed it), so the constant + write were orphans.
K.BLINK_ARRIVE_DIST_U    = 350   -- instant-blink "arrived" threshold
K.BLINK_SETTLE_S         = 0.1   -- settle before firing on an arrived blink
K.BLINK_ARRIVE_TIMEOUT_S = 2.0   -- drop a never-arrived instant-blink entry
local SELF_DISPLACEMENT_SAVES = { item_force_staff = true, item_hurricane_pike = true }

local function defense_enabled()
    -- v0.5.7 E11 (B6/B7): dropped `if state.panic_override then return true end`.
    -- panic_override was a Sniper-port carry-over that is never written for Lina,
    -- so the branch was unreachable. v0.5.36 (MAINT-04): the companion
    -- state.panic_counter + state.force_counter slots referenced here were
    -- already removed in v0.5.14 (BL-A3 / E6); see the state declarations near
    -- L127 for the removal note. Menu m.panic_key bind is intentionally left in
    -- place; actually wiring panic is C7's domain, deferred to a later release.
    if not state.menu then return true end
    if state.menu.enable and not state.menu.enable:Get() then return false end
    if state.menu.auto_defense and not state.menu.auto_defense:Get() then return false end
    return true
end

-- v0.5.0: the chain dispatcher captures Lina's data + closures + throttle state
-- and runs the generic save-walk algorithm (lib/defense.lua). Everything
-- below is a thin adapter so call-site code (try_save_self, layer2_can_fire,
-- mark_layer2_fired) keeps its old shape. record_save stays hero-side and is
-- passed per-call as the on_save_fired callback; it owns throttle bookkeeping
-- (calls mark_layer2_fired -> dispatcher:MarkFired) so the lib does not
-- double-write. Construction is valid here: all referenced locals
-- (state.ANIM_SAVE_OVERRIDES @117, LINA_SAVE_OVERRIDES @362,
-- PATCHED_RECOMMENDED_SAVES, CATEGORY_CHAINS, CH.DEFAULT_SAVE_CHAIN, SAVE_FIRE,
-- ABILITY_SAVES, SELF_DISPLACEMENT_SAVES, save_is_ready,
-- self_can_cast_abilities, defense_enabled, K.LAYER2_REACTION_WINDOW) are
-- declared above this line. See Lina/LIB_DEFENSE_EXTRACTION.md.
-- v0.5.7 E12 (B8): merge LINA_EXTRA_THREATS into the lib's THREATS_ON_SELF
-- before handing it to the dispatcher. The lib's homing flag lookup in
-- lib/defense.lua Dispatcher:TrySaveSelf only sees the cfg.threats_on_self table, so hero-side
-- entries (Sniper Assassinate today, future gap-fills tomorrow) were invisible
-- to that probe. Currently latent (no LINA_EXTRA_THREATS row sets homing=true)
-- but a future homing entry would silently break WW/Eul/Pike-self gating. The
-- combined table is built locally here, so LINA_EXTRA_THREATS does not need to
-- be threaded as a separate cfg key.
local combined_threats_on_self = {}
for k, v in pairs(THREATS_ON_SELF) do combined_threats_on_self[k] = v end
for k, v in pairs(LINA_EXTRA_THREATS) do combined_threats_on_self[k] = v end

-- v0.5.40 TIER 0: per-canonical-mod ETA resolver catalog. The dispatcher
-- (lib/defense.lua resolve_ttl) calls one of these per dispatch to compute the
-- save-lock TTL = clamp(eta, 0, 6s) + cfg.lock_buffer_s (0.3s, floor 0.4s).
-- Resolvers are PURE: nil-tolerant on all 5 args (caster, target, armed_entry,
-- ability_handle, now_t), no state.* mutation, no order issuance, no tlog.
-- The lib pcall-wraps every call, so a stray throw degrades to the catalog
-- fallback path (cfg.fallback_lock_ttl_s = 2.0s) without crashing dispatch.
--
-- K.PERSISTENT_LOCK_CAP_S is the persistent-class cap. v0.5.42 fix: the v0.5.40
-- math had the 0.1s margin term with the wrong sign, yielding TTL = 1.9 + 0.3
-- = 2.2s which EXCEEDS the 2.1s tick interval and blocked every other
-- re-fire with dispatch_blocked. Correct derivation: cap = PERSISTENT_
-- THREAT_TICK_INTERVAL (2.1s @L1739) - 0.1s safety margin BEFORE next tick
-- - cfg.lock_buffer_s (0.3s) = 1.7s, so resulting post-buffer lock TTL is
-- exactly 2.0s, leaving 0.1s headroom before the next 2.1s tick.
-- Mirrored as a local here (not a forward-reference to L1739) so the table
-- literal stays self-contained.
K.PERSISTENT_LOCK_CAP_S = 1.7  -- v0.5.42: = K.PERSISTENT_THREAT_TICK_INTERVAL - 0.1 - lock_buffer_s

-- v0.5.74 lib-first lift: factory helpers + generic ETA resolver moved to
-- lib/defense.lua (Defense.EtaResolvers.{CastPoint,Remaining,DistSpeed,Line}
-- + Defense.MakeGenericEtaResolver). _lina_eta_dist moved to inline use of
-- the lib equivalent. compute_arrival_time lifted to lib/threat_data.lua
-- as ThreatData.ComputeArrivalTime. The Lina-only Layer-1 FC offensive
-- synthetic resolver stays here because it is a hero-specific single-spend
-- invariant (offensive FC fire blocks a subsequent defensive FC fire within
-- ~2.2s; not a pattern shared with other heroes).
local EtaR = Defense.EtaResolvers
local function _lina_eta_fc_offensive(_c, _t, _a, _ab, _now_t) return 1.9 end

-- The 30 per-mod + 4 synthetic FC resolvers, keyed by canonical mod string.
-- The dispatcher canonicalizes the threat_mod via cfg.canonicalize_mod
-- (= TD.CanonicalMod) BEFORE the lookup, so alias mods (e.g. _pull suffix)
-- only need one entry on the canonical side; both are listed here for
-- belt-and-braces in case the alias table grows later.
local LINA_ETA_RESOLVERS = {
    -- (1)-(9) cast_point class (Defense.EtaResolvers.CastPoint)
    modifier_sniper_assassinate                = EtaR.CastPoint(2.0),
    modifier_lion_finger_of_death              = EtaR.CastPoint(0.6),
    modifier_lina_laguna_blade                 = EtaR.CastPoint(0.45),
    modifier_ice_blast                         = EtaR.CastPoint(0.5),
    modifier_ancient_apparition_ice_blast      = EtaR.CastPoint(0.5),
    modifier_obsidian_destroyer_sanity_eclipse = EtaR.CastPoint(1.7),
    modifier_tinker_laser                      = EtaR.CastPoint(0.45),
    modifier_zuus_thundergods_wrath            = EtaR.CastPoint(0.6),
    modifier_doom_bringer_doom                 = EtaR.CastPoint(0.5),
    -- (10) hard_disable voodoo (floor 0.5s per catalog)
    modifier_lion_voodoo          = EtaR.Remaining("modifier_lion_voodoo",          nil, 0.5),
    modifier_shadow_shaman_voodoo = EtaR.Remaining("modifier_shadow_shaman_voodoo", nil, 0.5),
    -- (11) static storm thinker channel (cap 1.9s) -- ad-hoc channel-time
    -- resolver, kept inline because lib/defense doesn't have a
    -- Ability.GetChannelTime factory yet (queued cleanup if a second hero
    -- needs the same pattern).
    modifier_disruptor_static_storm_thinker = function(_c, _t, armed, ab, now_t)
        if ab and Ability.GetChannelTime then
            local ok, total = pcall(Ability.GetChannelTime, ab)
            if ok and type(total) == "number" and total > 0 then
                local started = (armed and armed.channel_start_t) or now_t or 0
                local rem = total - ((now_t or 0) - started)
                if rem > K.PERSISTENT_LOCK_CAP_S then rem = K.PERSISTENT_LOCK_CAP_S end
                if rem < 0.1 then rem = 0.1 end
                return rem
            end
        end
        return K.PERSISTENT_LOCK_CAP_S
    end,
    -- (12)-(16) channel_on_self / pugna / wd (Defense.EtaResolvers.Remaining)
    modifier_legion_commander_duel = EtaR.Remaining("modifier_legion_commander_duel", K.PERSISTENT_LOCK_CAP_S),
    modifier_pudge_dismember_pull  = EtaR.Remaining("modifier_pudge_dismember_pull",  nil),
    modifier_pudge_dismember       = EtaR.Remaining("modifier_pudge_dismember",       nil),
    modifier_bane_fiends_grip      = EtaR.Remaining("modifier_bane_fiends_grip",      nil),
    modifier_pugna_life_drain      = EtaR.Remaining("modifier_pugna_life_drain",      K.PERSISTENT_LOCK_CAP_S),
    modifier_witch_doctor_death_ward = function(_c, _t, _armed, ab, _now_t)
        -- Same Ability.GetChannelTime pattern as static_storm_thinker above.
        if ab and Ability.GetChannelTime then
            local ok, total = pcall(Ability.GetChannelTime, ab)
            if ok and type(total) == "number" and total > 0 then
                if total > K.PERSISTENT_LOCK_CAP_S then total = K.PERSISTENT_LOCK_CAP_S end
                if total < 0.1 then total = 0.1 end
                return total
            end
        end
        return K.PERSISTENT_LOCK_CAP_S
    end,
    -- (17)-(18) armed_chain gap-closers (default speed 600u/s)
    modifier_spirit_breaker_charge_of_darkness = EtaR.DistSpeed(600, nil),
    modifier_tusk_snowball_movement            = EtaR.DistSpeed(600, nil),
    -- (19)-(20) instant_blink (cap K.BLINK_ARRIVE_TIMEOUT_S = 2.0s)
    modifier_phantom_assassin_phantom_strike_target = EtaR.DistSpeed(1500, K.BLINK_ARRIVE_TIMEOUT_S),
    modifier_queenofpain_blink                      = EtaR.DistSpeed(1500, K.BLINK_ARRIVE_TIMEOUT_S),
    -- (21) slark pounce (default speed 900u/s)
    modifier_slark_pounce = EtaR.DistSpeed(900, nil),
    -- (22)-(24) line_projectile
    modifier_pudge_meat_hook = EtaR.Line(1450, 0.8),
    modifier_mirana_arrow    = EtaR.Line(900,  1.0),
    modifier_sven_storm_bolt = EtaR.Line(1100, 0.8),
    -- (25)-(26) cast_point semantics for pre-impact window
    modifier_earthshaker_fissure_stun = EtaR.CastPoint(0.46),
    modifier_magnataur_skewer         = EtaR.CastPoint(0.3),
    -- (27)-(30) persistent / delayed_aoe / buffs
    modifier_lina_light_strike_array = function(_c, _t, _armed, _ab, _now_t) return 0.5 end,
    modifier_naga_siren_ensnare       = EtaR.Remaining("modifier_naga_siren_ensnare",       K.PERSISTENT_LOCK_CAP_S),
    modifier_bane_nightmare           = EtaR.Remaining("modifier_bane_nightmare",           K.PERSISTENT_LOCK_CAP_S),
    modifier_doom_bringer_doom_debuff = EtaR.Remaining("modifier_doom_bringer_doom_debuff", K.PERSISTENT_LOCK_CAP_S),
    modifier_disruptor_kinetic_field = function(_c, target, _armed, _ab, _now_t)  -- v0.5.118: real name (was stale _remnant)
        -- Custom: uses 2.6s fallback when GetModifierRemaining returns 0
        -- (the Kinetic Field thinker often outlives the modifier read window
        -- by a tick; 2.6s matches the v6 lifetime). Kept inline because the
        -- generic Remaining factory floors at 0.1s rather than substituting
        -- a default.
        local rem = 0
        if target and Entity.IsEntity and Entity.IsEntity(target) and NPC.GetModifierRemaining then
            local ok, v = pcall(NPC.GetModifierRemaining, target, "modifier_disruptor_kinetic_field")
            if ok and type(v) == "number" then rem = v end
        end
        if rem <= 0 then rem = 2.6 end
        if rem > K.PERSISTENT_LOCK_CAP_S then rem = K.PERSISTENT_LOCK_CAP_S end
        if rem < 0.1 then rem = 0.1 end
        return rem
    end,
    -- (S1)-(S4) Layer-1 FC offensive synthetic keys (single-spend lock domain)
    lina_fc_offensive_pre_combo      = _lina_eta_fc_offensive,
    lina_fc_offensive_pre_tf_opener  = _lina_eta_fc_offensive,
    lina_fc_offensive_pre_tf_burst   = _lina_eta_fc_offensive,
    lina_fc_offensive_pre_tf_sustain = _lina_eta_fc_offensive,
    lina_fc_arbiter_defense          = _lina_eta_fc_offensive,  -- v0.5.158 A1: defensive FC reserve (1.9s lock TTL)
}

-- v0.5.46.3: drop `local` keyword so this assigns the forward-declared
-- upvalue at top-of-file (see comment near L31). Without this fix,
-- functions defined earlier (commit-attacker scan, etc.) referenced
-- a nil global.
defense_dispatcher = Defense.New {
    anim_save_overrides     = state.ANIM_SAVE_OVERRIDES,
    hero_save_overrides     = LINA_SAVE_OVERRIDES,
    patched_recommended     = PATCHED_RECOMMENDED_SAVES,
    category_chains         = CATEGORY_CHAINS,
    -- v0.5.110 chain composition: generic tier-3 declaration (see
    -- CH.ABILITY_INJECTIONS / CH.EXCLUSIONS near LINA_CATEGORY_PATCHES).
    -- Static after load; the lib memoizes composed chains per category.
    ability_injections      = CH.ABILITY_INJECTIONS,
    exclusions              = CH.EXCLUSIONS,
    default_chain           = CH.DEFAULT_SAVE_CHAIN,
    save_fire               = SAVE_FIRE,
    ability_saves           = ABILITY_SAVES,
    self_displacement_saves = SELF_DISPLACEMENT_SAVES,
    save_is_ready           = save_is_ready,
    self_can_cast_abilities = self_can_cast_abilities,
    TD                      = TD,
    threats_on_self         = combined_threats_on_self,
    reaction_window         = K.LAYER2_REACTION_WINDOW,
    reserve_skip_floor      = state.RESERVE_SKIP_FLOOR,  -- v0.5.39 P3-LOW-magic
    concurrent_penalty      = state.CONCURRENT_PENALTY,  -- v0.5.39 P3-LOW-magic
    throttle_state          = state,
    armed_threats           = state.armed_threats,
    now                     = now,
    tlog                    = tlog,
    -- v0.5.83: lets ResolveSaveOrder skip building its level-3 diagnostic
    -- kv-table at default verbosity (the per-armed-threat alloc the optimization
    -- pass flagged). v_level is the live verbosity accessor; optional on the lib
    -- side so a hero that does not register it keeps the always-build behaviour.
    tlog_level              = v_level,
    dist_to                 = dist_to,
    defense_enabled         = defense_enabled,
    -- v0.5.40 TIER 0: dispatcher lock primitives. canonicalize_mod folds
    -- alias mods (e.g. _pull suffix variants) to a single key so the
    -- (target, canonical_mod, caster) lock tuple buckets correctly across
    -- routing branches. eta_resolver supplies the per-mod TTL math; the
    -- lib clamps the result to [0, 6s] and adds lock_buffer_s. entity_index
    -- + ability_handle let the lib build the lock tuple + look up ability
    -- handles for cast_point / channel-time resolvers without leaking
    -- state.self_npc into the lib. See LINA_ETA_RESOLVERS construction
    -- above for the catalog.
    canonicalize_mod        = TD.CanonicalMod,
    eta_resolver            = LINA_ETA_RESOLVERS,
    -- v0.5.72 Phase 4 slice 7 (audit rec #3): generic fallback resolver
    -- for mods not in LINA_ETA_RESOLVERS. v0.5.74 lib-first lift: the body
    -- moved to Defense.MakeGenericEtaResolver(TD); registration is now a
    -- factory call binding TD via closure. Per-mod LINA_ETA_RESOLVERS
    -- entries still win (cfg.eta_resolver checked first); this only covers
    -- the ~14 catalog mods from Phase 4 slices without hand-tuned entries.
    eta_resolver_default    = Defense.MakeGenericEtaResolver(TD),
    lock_buffer_s           = 0.3,
    fallback_lock_ttl_s     = 2.0,
    -- v0.5.127 CD-aware lock release (general re-engage structure; user spec
    -- "not tied to such a long time"). Reports whether a fired save's
    -- item/ability is on COOLDOWN (= it actually spent). The lib releases a
    -- held in-flight lock on a re-engage once the chosen save is confirmed
    -- spent, so the chain advances to the NEXT ready save (e.g. Pike spent ->
    -- WW on a Primal re-grab) instead of staying locked for the whole TTL.
    -- Benefits EVERY re-engaging threat, not just Primal. Name map mirrors
    -- save_is_ready; uses GetCooldown>0 (NOT IsReady, which also reads false on
    -- mana / ownership). Unowned/unleveled -> handle nil / cd 0 -> false, so the
    -- lib falls through to its give-up backstop. lock_cd_coalesce_s /
    -- lock_cd_giveup_s left at lib defaults (0.30 / 0.60).
    item_on_cd              = function(save_short)
        if not save_short or save_short == "thunk" then return false end
        local me = state.self_npc
        if not me then return false end
        local handle
        if save_short == "lina_flame_cloak" then
            handle = ability("lina_flame_cloak")
        elseif save_short == "lina_w_anti_gap" then
            handle = ability("lina_light_strike_array")
        elseif save_short == "item_ethereal_blade_self" then
            handle = NPCLib.item(me, "item_ethereal_blade")
        elseif save_short:sub(1, 5) == "item_" then
            handle = NPCLib.item(me, save_short)
        else
            handle = ability(save_short)
        end
        if not handle then return false end
        local ok, cd = pcall(Ability.GetCooldown, handle)
        return (ok and type(cd) == "number" and cd > 0) and true or false
    end,
    -- v0.5.40.1 HOTFIX: self_npc closure was missing from v0.5.40 cfg, so
    -- lib's TrySaveSelf compat wrapper resolved target_unit=nil -> lock_key
    -- returned nil -> lock_key_unresolvable tlog -> unlocked v0.5.39 path.
    -- Every legacy try_save_self caller (armed_threats_tick homing branch
    -- for Bara/Tusk/PA, cast_point_threat branch for Sniper/Lion, lotus_first
    -- fall-through) silently bypassed the lock domain in v0.5.40.0. Closes
    -- the demo regression: Bara WW+Pike, Sniper Assassinate+D, Lion R double-
    -- fires were all unlocked because of this one missing line.
    self_npc                = function() return state.self_npc end,
    entity_index            = function(ent)
        if not ent then return nil end
        if Entity.IsEntity and not Entity.IsEntity(ent) then return nil end
        local ok, idx = pcall(Entity.GetIndex, ent)
        if ok and type(idx) == "number" then return idx end
        return nil
    end,
    ability_handle          = function(ability_name)
        if not ability_name or not state.self_npc then return nil end
        local ok, h = pcall(NPC.GetAbility, state.self_npc, ability_name)
        if ok then return h end
        return nil
    end,
    -- v0.5.55: removed threat_catalog + compute_arrival_time cfg
    -- registrations -- the v0.5.53 lib-side per-save catalog gate
    -- that consumed them is gone. W's .fire body now uses
    -- state.compute_arrival_time directly (not through cfg). The
    -- catalog data + helper stay reachable on the hero side; only
    -- the cfg plumbing into lib is removed.
    -- v0.5.70 Phase 4 slice 5: REINTRODUCED for the new chain-walker
    -- skip branches (cast_point_too_early + low_severity_high_hp).
    -- The defer / skip gates only activate for saves listed in
    -- high_cd_saves so unrelated chain decisions stay byte-equivalent
    -- to v0.5.69. Catalog source of truth is THREAT_ARRIVAL_TIMING
    -- (40 entries after slices 1-4); compute_arrival_time returns
    -- impact_t = cast_point + travel + post_cast_delay.
    -- v0.5.99.1 REVERT of the v0.5.96 forward-ref "fix": compute_arrival_time is
    -- intentionally NOT registered here, so the lib's cast_point_too_early defer
    -- branch (gated on `c.compute_arrival_time`) stays disabled. v0.5.96 wrapped it
    -- in a call-time closure so that branch finally ran -- but the v0.5.99 demo proved
    -- it is BROKEN for cast-point threats: compute_arrival_time returns the FULL
    -- catalog cast_point (Sniper Assassinate impact_t=2.00), not the LIVE remaining
    -- time, so impact_t is CONSTANT and always > the 0.50 threshold -> the high-CD save
    -- (Lotus/BKB/WW/Glimmer) deferred EVERY tick and NEVER fired; Lina ate the
    -- Assassinate (no_effective_save_for_threat looped to cast_point_threat_timeout,
    -- Lotus issued 0 times). The branch had been dead via the nil capture since v0.5.70
    -- (28 versions), so leaving it dead restores the proven immediate-fire behaviour.
    -- The defer is only a CD-saving OPTIMISATION; re-enabling it correctly needs the
    -- LIVE cp_remaining plumbed into the gate (the armed tick has it as
    -- entry.cast_point - elapsed; pass it via ctx.impact_t and have run_chain_walk
    -- prefer ctx.impact_t over compute_arrival_time) -- a separate, demo-gated slice.
    -- (self_hp_fraction below is a real closure; its low_severity_high_hp branch is
    -- unaffected.)
    -- Lina HP fraction for the severity skip. Per
    -- UCZone HP API: HP lives on Entity, not NPC.
    self_hp_fraction = function()
        local me = state.self_npc
        if not me or not Entity.IsAlive(me) then return nil end
        local hp_ok, hp     = pcall(Entity.GetHealth, me)
        local hpm_ok, hpmax = pcall(Entity.GetMaxHealth, me)
        if not (hp_ok and hpm_ok and hp and hpmax and hpmax > 0) then return nil end
        return hp / hpmax
    end,
    -- High-CD save set for the v0.5.70 defer/skip gates. Saves listed
    -- here get the cast_point_too_early + low_severity_high_hp checks
    -- before fire. Others (Force, Pike, W, FC, Manta, Shadow Blade,
    -- Silver Edge, Ghost Scepter) skip the gates entirely -- their
    -- CDs are short enough that burning early isn't a meaningful loss.
    high_cd_saves = {
        item_lotus_orb       = true,  -- 14s CD, reflect
        item_black_king_bar  = true,  -- 60s CD (depleting), magic-immune
        item_aeon_disk       = true,  -- 90+s CD, time-stop on lethal
        item_pipe            = true,  -- 60s CD, magic-shield + ally aura (v0.5.110: real items.json key; the old item_pipe_of_insight name matched nothing)
        item_glimmer_cape    = true,  -- 25s CD, invis + magic-resist
        item_wind_waker      = true,  -- 30s CD, self-cyclone movable
        item_cyclone         = true,  -- 23s CD, self-cyclone immunity
    },
    -- v0.5.70 tuning. cast_point_defer_threshold = how late to wait
    -- before firing a high-CD save (0.5s = save fires when impact is
    -- 0.5s away). severity_skip_hp_threshold = HP fraction above which
    -- low-severity threats don't warrant burning a high-CD save.
    cast_point_defer_threshold   = 0.5,
    severity_skip_hp_threshold   = 0.75,
    -- v0.5.98 BKB-bypass fix: centralized "this self-defense is wasted" veto.
    -- The lib calls this at the top of Dispatcher:Dispatch (the SINGLE self-save
    -- chokepoint -- TrySaveSelf routes through Dispatch), so EVERY route (the ~8
    -- direct defense_dispatcher:Dispatch sites AND try_save_self) honors it, not
    -- just the hero's try_save_self wrapper. Returns true iff the threat is one the
    -- ACTIVE BKB fully absorbs (curated LINA_BKB_TRULY_BLOCKED_MODS) AND Lina has
    -- modifier_black_king_bar_immune. Checks raw + canonical mod so an alias-suffixed
    -- sibling still matches (the try_save_self guard keyed on raw only). Sniper does
    -- not register this -> the lib veto is a no-op for it (byte-unaffected).
    threat_fully_blocked = function(threat_mod, target_unit)
        local me = target_unit or state.self_npc
        if not (me and threat_mod and NPC.HasModifier
                and NPC.HasModifier(me, "modifier_black_king_bar_immune")) then
            return false
        end
        if LINA_BKB_TRULY_BLOCKED_MODS[threat_mod] then return true end
        local cm = (TD and TD.CanonicalMod) and TD.CanonicalMod(threat_mod) or nil
        return (cm ~= nil and LINA_BKB_TRULY_BLOCKED_MODS[cm] == true) or false
    end,
    -- v0.5.41 GAP-3-GENERIC: hero-supplied chain rewriter (was hardcoded
    -- inside lib/defense.lua ResolveSaveOrder pre-v0.5.41). Demotes
    -- lina_flame_cloak to chain tail under ctx.fs_shard_window so a
    -- shard-amped FS spend isn't pre-empted by a FC burn. Builds a NEW
    -- chain table so cfg override / category / default tables stay
    -- untouched. nil hook in cfg = lib passes resolved chain through.
    post_pick_filter = function(picked, ctx, threat_mod, authoritative)
        if not (ctx and ctx.fs_shard_window and picked) then
            return picked, authoritative
        end
        local has_fc = false
        for i = 1, #picked do
            if picked[i] == "lina_flame_cloak" then has_fc = true break end
        end
        if not has_fc then return picked, authoritative end
        local demoted = {}
        for i = 1, #picked do
            if picked[i] ~= "lina_flame_cloak" then
                demoted[#demoted + 1] = picked[i]
            end
        end
        demoted[#demoted + 1] = "lina_flame_cloak"
        tlog(3, "resolve_save_order_fc_demote", { mod = threat_mod, head = demoted[1] or "-", reason = "fs_shard_window" })
        return demoted, authoritative
    end,
}

local function layer2_can_fire()       return defense_dispatcher:CanFire() end
local function mark_layer2_fired(c)    return defense_dispatcher:MarkFired(c) end

-- v0.5.40 B2 (GAP-3): single-source-of-truth predicate for "are we inside the
-- 5s post-R Aghs Shard window where Fiery Soul cap is raised from 7 to 12".
-- Every defense Dispatch / DispatchAlly / TrySaveSelf call site reads this and
-- passes it on ctx.fs_shard_window so lib/defense.lua ResolveSaveOrder can
-- demote lina_flame_cloak (which sets FS to a flat 7) to chain tail during the
-- window -- preventing a defensive FC fire from costing up to 5 FS stacks.
-- Mirrors the (NPCLib.has_shard + last_r_cast_t + 5.0s) shape used by
-- compute_fs_state (grep `shard_window = true`) so the offensive and defensive
-- sides cannot disagree on the window boundary. Defined here, BEFORE the
-- first Dispatch call site in try_save_self below.
-- v0.5.47.3: dropped `local` keyword so this assigns the forward-declared
-- upvalue near top-of-file (see comment near L35). Functions defined earlier
-- (scan_and_arm_committed_attackers L797) reference fs_shard_window_active
-- inside their Dispatch call; without the forward declaration the reference
-- captured a nil global and crashed at runtime.
function fs_shard_window_active()
    local me = state.self_npc
    return me ~= nil
       and NPCLib.has_shard(me)
       and state.last_r_cast_t ~= nil
       and (now() - state.last_r_cast_t) <= 5.0
end
state.fs_shard_window_active = fs_shard_window_active  -- harness/test handle

-- v0.5.47.3: dropped `local` keyword so this assigns the forward-declared
-- upvalue near top-of-file. Same upvalue-capture rationale as
-- fs_shard_window_active above; scan_and_arm_committed_attackers passes
-- record_save as the on_save_fired callback in its Dispatch call so the
-- forward declaration must already exist at L797 function-creation time.
function record_save(intent, item_name, threat_mod, threat_caster)
    state.last_save_intent = item_name .. ":" .. intent
    state.l2_counter = state.l2_counter + 1
    if not intent:find("^save_ally") then
        state.last_save_kind          = item_name
        state.last_save_threat_mod    = threat_mod
        -- v0.5.39 P1-M2: state.save_cast_protect_until_t write removed (no reader).
        -- v0.5.15 OBS-04: snapshot HP at fire so postmortem can distinguish
        -- "fired at 30% to a 1500 hit" from "fired at 95% and got chunked".
        state.last_save_hp     = (Entity.GetHealth    and Entity.GetHealth(state.self_npc))    or 0
        state.last_save_hp_max = (Entity.GetMaxHealth and Entity.GetMaxHealth(state.self_npc)) or 1
    end
    local category = threat_mod and TD.CategoryOf and TD.CategoryOf(threat_mod) or "-"
    tlog(1, "layer2_save", { item = item_name, intent = intent, category = category })
    mark_layer2_fired(threat_caster)
end

-- v0.5.0: try_save_self collapses to a one-liner over the dispatcher; the
-- hero-side save_counters / displacement_will_break_tether helpers were
-- in-lined into the dispatcher (lib/defense.lua) and are no longer needed
-- here. record_save is passed as on_save_fired so the throttle update flows
-- through the existing record_save -> mark_layer2_fired -> dispatcher:MarkFired
-- chain (no double-write).
--
-- v0.5.23 REVERT: the v0.5.22 BKB-immune chain bail was dangerously wrong.
-- LINA_BKB_BLOCKED_CATEGORIES = {targeted_burst, targeted_disable, lockdown,
-- hard_disable} included threats that PIERCE BKB:
--   - modifier_legion_commander_duel (Duel - pure damage, ignores immunity)
--   - modifier_doom_bringer_doom (pure damage + silence; silence pierces BKB)
--   - modifier_lion_finger_of_death (pure damage, pierces BKB)
--   - modifier_pugna_life_drain (pure damage channel)
--   - modifier_axe_berserkers_call (physical disable, ignores BKB)
-- While BKB was up, the brain refused to fire Force/Pike/Lotus/dispel for
-- these threats and Lina died. Reverted to pre-v0.5.22 contract: try_save_self
-- is a thin pass-through to the dispatcher; the v0.5.16 per-item same-active-
-- mod guards in SAVE_FIRE handle the "BKB already absorbs the magic side"
-- wasted-fire case at the right granularity (per-item, per-modifier).
--
-- v0.5.27 RPR-01 REDO: per-modifier denylist now in LINA_BKB_TRULY_BLOCKED_MODS
-- (grep `local LINA_BKB_TRULY_BLOCKED_MODS = {`). When Lina has modifier_black_king_bar_immune AND threat_mod is in
-- the curated set, bail at entry with save_chain_skip. Per-modifier scope
-- avoids the v0.5.22 category-whitelist trap (BKB-piercing threats stay out
-- of the table by construction).
-- v0.5.39 M1 (Option A): optional armed_entry trailing param. Armed-fire path
-- (armed_threats_tick L1528) passes the live entry so Dispatcher:CountConcurrent-
-- Excluding self-excludes by entry-handle identity (mirrors armed_chain_peek).
-- All other call sites pass nothing (default nil = count-all behaviour preserved).
local function try_save_self(intent, threat_mod, threat_caster, category_hint, ability_name, armed_entry)
    -- v0.5.37 MAINT-05: BKB-truly-blocks-threat is an UNBYPASSABLE entry guard
    -- (firing a chain save against a threat BKB already absorbs is wasted item
    -- charges + cooldowns, regardless of panic intent). Evaluate BEFORE the
    -- panic bypass below so a panicked user does not burn Force/Pike against
    -- e.g. modifier_axe_berserkers_call while BKB is up.
    if threat_mod and LINA_BKB_TRULY_BLOCKED_MODS[threat_mod]
       and state.self_npc and NPC.HasModifier
       and NPC.HasModifier(state.self_npc, "modifier_black_king_bar_immune") then
        tlog(1, "save_chain_skip", { intent = intent, mod = threat_mod,
            reason = "bkb_truly_blocks_threat" })
        return false
    end
    -- v0.5.37 MAINT-05 / v0.5.40 A5-HERO: panic-key one-shot bypass.
    --
    -- The panic contract has TWO gates to bypass on the panic frame:
    --   (1) Dispatcher CanFire / K.LAYER2_REACTION_WINDOW throttle (last_save_t)
    --   (2) Dispatcher per-(target, canonical_mod, caster) lock added in
    --       v0.5.40 to dedupe simultaneous routes against the same threat
    --       (e.g. Bara WW-on-anim + Pike-on-armed-tick).
    -- v0.5.37 only had (1) and addressed it by snapshot/zero/restore of
    -- state.last_save_t around the dispatcher call. v0.5.40 adds the lock,
    -- so a genuine user-driven panic on the same target+mod as a prior
    -- routine save would be silently dropped by dispatch_blocked unless
    -- the lock is also released. The lib exposes Dispatcher:ForceNextDispatch
    -- as a single-shot lock bypass (one-call-only; lock re-acquires on the
    -- next successful fire). It does NOT touch CanFire -- the throttle
    -- snapshot/restore wrapper below is still required for gate (1).
    --
    -- Snapshot semantics: on a successful dispatch, record_save ->
    -- mark_layer2_fired -> dispatcher:MarkFired re-stamps last_save_t and we
    -- clear panic_override_until below so the bypass is genuinely one-shot.
    -- On a failed dispatch we restore last_save_t so unrelated future
    -- throttle math is unaffected.
    --
    -- Reserve-skip / not_ready / homing-no-displacement / kind-mismatch
    -- chain-walk filters are intentionally NOT bypassed: they protect
    -- against firing a save that physically cannot help (channel-self,
    -- dead-self, magic-immune target, unready item), which is the
    -- 'unbypassable' set the panic contract names.
    local _panic_active = state.panic_override_until and state.panic_override_until > now()
    local _saved_last_t = nil
    if _panic_active then
        _saved_last_t = state.last_save_t
        state.last_save_t = 0
        -- v0.5.40 A5-HERO: drop the dispatcher lock for the upcoming
        -- Dispatch call. Canonicalize the threat_mod so the unlocked tuple
        -- matches whatever the dispatcher will write on a successful fire.
        -- TD.CanonicalMod returns nil for nil/non-string input; the lib
        -- treats an unresolvable lock_key as a no-op (lock not in play),
        -- so passing nil is harmless when the threat is unkeyed.
        local _canon_mod = (TD and TD.CanonicalMod) and TD.CanonicalMod(threat_mod) or threat_mod
        defense_dispatcher:ForceNextDispatch(state.self_npc, _canon_mod, threat_caster)
        tlog(1, "panic_bypass_active", { intent = intent,
            mod = tostring(threat_mod or "-"),
            ttl = string.format("%.2f", state.panic_override_until - now()) })
    end
    local fired = defense_dispatcher:TrySaveSelf(intent, threat_mod, threat_caster,
                                                 category_hint, ability_name, record_save,
                                                 armed_entry,  -- v0.5.39 M1 (Option A)
                                                 { fs_shard_window = fs_shard_window_active() })  -- v0.5.40 B2 GAP-3
    if _panic_active then
        if fired then
            state.panic_override_until = 0  -- one-shot consumed
            tlog(1, "panic_bypass_consumed", { intent = intent })
        else
            -- Dispatch failed (no eligible save in the chain). Restore the
            -- pre-bypass throttle marker so we do not inadvertently re-open
            -- a window for some unrelated future caller in the same tick.
            -- Note: the ForceNextDispatch lock-drop is itself one-shot at
            -- the lib level and harmless to leave consumed on failure --
            -- if the next panic frame fires, it will re-call ForceNext.
            state.last_save_t = _saved_last_t
        end
    end
    return fired
end

-- v0.5.39 P3-M05-test: expose try_save_self to the in-Brain test harness so the
-- MAINT-05 panic-bypass test can invoke the dispatch path end-to-end without
-- needing access to the file-local. Mirrors the state.lina_save_fire /
-- state.lina_chains read-only handles already exposed for G4 / A9 tests.
state.lina_try_save_self = try_save_self

-- Lotus-first for reflectable targeted ults; falls through to the chain.
-- v0.5.4: forward threat_mod / threat_caster / ability_name to the fallback
-- try_save_self so ResolveSaveOrder consults LINA_SAVE_OVERRIDES (e.g.
-- modifier_sniper_assassinate, Lion Finger of Death) instead of short-
-- circuiting onto CH.DEFAULT_SAVE_CHAIN when Lotus is unavailable. category_hint
-- is left nil here: the lotus-worthy path is modifier-keyed and the dispatcher
-- derives category from threat_mod via TD.CategoryOf.
local function try_save_lotus_first(intent, threat_mod, threat_caster, ability_name)
    -- v0.5.21 OBS-11: per-subsystem toggle. When disabled, skip the
    -- Lotus-first branch entirely. Caller (callbacks.OnModifierCreate) has
    -- already stamped dedup, so the normal save ladder still owns the
    -- threat via the broader auto_defense path on subsequent events.
    if state.menu and state.menu.enable_lotus_first
       and not state.menu.enable_lotus_first:Get() then
        return false
    end
    if not layer2_can_fire() then return false end
    if NPCLib.item_ready(state.self_npc, "item_lotus_orb") then
        -- v0.5.40 A3-1: route the Lotus self-cast through Dispatch so the
        -- fire acquires the per-(target,mod,caster) lock that blocks the
        -- try_save_self fall-through (and any concurrent armed-fire path)
        -- from double-firing for the same threat. fire_thunk wraps the
        -- direct issue_item_self + record_save so the dispatcher only owns
        -- the lock / bookkeeping; the legacy item-issue shape is preserved
        -- verbatim. ability_name="item_lotus_orb" so ResolveSaveOrder can
        -- see the head save for lock-TTL math.
        local fire_thunk = function(_intent, _mod, _caster)
            if issue_item_self(intent .. "_lotus", "def", NPCLib.item(state.self_npc, "item_lotus_orb")) then
                record_save(intent, "lotus", threat_mod, threat_caster)
                return true
            end
            return false
        end
        if defense_dispatcher:Dispatch(intent, threat_mod, threat_caster,
                                       state.self_npc, fire_thunk,
                                       nil, "item_lotus_orb", nil, nil,
                                       { fs_shard_window = fs_shard_window_active() }) then  -- v0.5.40 B2 GAP-3
            return true
        end
    end
    return try_save_self(intent, threat_mod, threat_caster, nil, ability_name)
end

-- v0.5.6 (E2): per-save eta_trigger overrides. Self-displacement saves
-- (WW / Eul / Pike-self) DISPLACE Lina at cast resolution -- firing 0.8s early
-- just exposes her during the cyclone. Fire near impact (0.20-0.25s) so the
-- cyclone lifts her in the threat's last moment. Pike-enemy / Force still
-- need the 0.8s lead (push-arc + threat-caster travel). Glimmer / BKB / Lotus
-- are instant, no urgency -- kept defensive at 0.30-0.50s.
-- Keyed by save_name (matches SAVE_FIRE keys; grep `local SAVE_FIRE = {`) so resolve_save_order
-- output drops straight into this table. Colocated with armed_threats_tick
-- (its only consumer) rather than next to SAVE_FIRE; declared as a file-local
-- so the dispatcher closure above doesn't need to be re-threaded.
local SAVE_ETA_TRIGGER = {
    item_wind_waker         = 0.45,  -- v0.5.22 PT-02 follow: 0.25 -> 0.45. v0.5.21 demo testing showed WW firing on Tusk snowball but landing AFTER impact (engine apply latency + cyclone airborne ramp). 0.45s urgency-fire threshold gives the cyclone ~0.2s extra headroom so airborne lands before snowball does.
    item_cyclone            = 0.45,  -- v0.5.22 PT-02 follow: matched item_wind_waker (same dispel + airborne mechanics).
    item_hurricane_pike     = 0.25,  -- self-cast branch; enemy-cast branch falls back to entry default below
    item_glimmer_cape       = 0.40,
    item_black_king_bar     = 0.30,
    item_lotus_orb          = 0.50,
    lina_flame_cloak        = 0.40,
    item_invis_sword        = 0.40,
    item_silver_edge        = 0.40,
    item_force_staff        = 0.60,
    lina_w_anti_gap         = 1.20,  -- v0.5.44: W has 1.1s prep (0.6 cast point + 0.5 delay) + 0.1s safety margin. Gates the chain walker to consider W only for threats with eta >= 1.2s. PA blink (0.25s), AM blink (0.15s), Slark Pounce (0.75s) all auto-skip.
}

-- v0.5.9 (E2, covers A1/A5/C2/C3/C8/C9/F2): per-save PROXIMITY fire gate.
-- Codifies the user design principle "fire the save when the threat is almost
-- hitting" in pure spatial terms. SAVE_ETA_TRIGGER (above) is a time gate that
-- depends on entry.eta_speed accuracy; SAVE_FIRE_DISTANCE is the spatial
-- equivalent and is consulted FIRST in the reserve-aware chain peek below.
-- If the chosen save has a distance entry AND the caster has closed inside it,
-- fire with via=save_dist. Otherwise the v0.5.6 SAVE_ETA_TRIGGER path runs as
-- fallback, then the 0.35s eta_critical (above) stays as last-resort safety
-- tail (distance gates can starve if chain head is reserved and concurrent
-- threats pile up). Pike-on-enemy keeps its canonical 425u pike_enemy_range
-- gate and bypasses SAVE_FIRE_DISTANCE per the C8 Pike-special branch (same
-- special-case as the v0.5.6 SAVE_ETA_TRIGGER Pike branch). Self-displacement
-- saves (Pike-self / Force-self) carry a hard 250u floor so we never push
-- Lina INTO the impact zone of a threat that already crossed her.
-- Keyed by save_name (matches SAVE_FIRE / SAVE_ETA_TRIGGER). Values in DOTA
-- units; see per-entry rationale in v0.5.9 release notes.
local SAVE_FIRE_DISTANCE = {
    item_wind_waker         = 500,  -- v0.5.135.1: 300 -> 500. WW is INSTANT (fire by proximity, no lead math -- instant saves fire by proximity). 300u was the binding gate ONLY for Bara: eta_speed 600 puts the SAVE_ETA_TRIGGER(0.45) eta-gate at 270u < 300u, so WW fired at ~296u = too close vs the real ~690 ramped charge speed (3 late fires). Tusk/Primal (eta_speed 1200) fire via the eta-gate at ~540u and are UNCHANGED (540 > 500). 500u gives Bara ~0.7s real lead (parity with Pike/Force's 500u). (was v0.5.15 PT-01 150 -> 300.)
    item_cyclone            = 500,  -- v0.5.135.1: matched item_wind_waker (same instant-airborne fire-by-proximity; Eul's). (was v0.5.15 PT-01 300.)
    item_hurricane_pike     = 500,   -- v0.5.21 PT-02: 360 -> 500. self-cast Pike pushes 425u; 360u gave too tight a margin between threat-impact and displacement-resolution. 500u lets the save fire while the threat is still ~half the push distance away.
    item_force_staff        = 500,   -- v0.5.21 PT-02: 360 -> 500. Same rationale (600u push; 500u trigger leaves clean headroom).
    item_glimmer_cape       = 270,
    item_black_king_bar     = 270,   -- v0.5.21 PT-03: 180 -> 270. Parity with Glimmer (270u). BKB takes ~50ms server-side to apply immunity, so 180u meant the threat impact often landed before the buff registered. 270u still tighter than displacement saves.
    item_lotus_orb          = 1100,  -- sanity gate; lotus_worthy_first cast-anim path is the primary trigger
    lina_flame_cloak        = 240,
    item_invis_sword        = 240,
    item_silver_edge        = 240,
    item_ethereal_blade_self = 480,
    -- v0.5.55.1 hotfix: SAVE_FIRE_DISTANCE[lina_w_anti_gap] REMOVED
    -- (was 1200). v0.5.55 demo log L601: armed_chain_peek fired W
    -- via save_dist at d=1193 (fixed eta_speed=600 gave eta=1.99,
    -- but real impact_t=2.36 at actual speed 506 was WAY out of W's
    -- [1.12, 1.56] window). W's .fire body correctly skipped via
    -- w_defensive_skip_window, but armed_post_fire had already
    -- consumed the armed_threats[bara_charge] entry, leaving the
    -- brain unable to re-attempt as Bara closed. W eventually fired
    -- LATE via the committed_attacker path (after Bara hit Lina and
    -- started auto-attacks). Without this distance entry, the chain
    -- peek falls through to SAVE_ETA_TRIGGER[lina_w_anti_gap]=1.20
    -- so armed_chain_peek fires W at eta=1.20 (d~720 for eta_speed
    -- 600); at that distance W's catalog impact_t (~1.42 for speed
    -- 506) is squarely inside W's window and W actually fires. The
    -- v0.5.46.3 rationale for 1200 (compensating for missing
    -- timing precision) is obsolete -- W's .fire body's impact_t
    -- window check (v0.5.55 Step 4) gives the precision the
    -- distance gate was trying to fake.
}
-- v0.5.9 (E2): self-displacement saves refuse to fire below this radius --
-- pushing Lina 600u in facing when the threat already crossed inside would
-- shove her into the impact zone. Only consulted on the self-cast branch.
K.SAVE_FIRE_DISTANCE_SELF_PUSH_FLOOR = 250

-- v0.5.55: state.W_FALLBACK_BLOCK_* + state.w_fallback_item_just_fired
-- (v0.5.54.1 W skip-after-item helper) removed -- no consumer left
-- after the v0.5.54.1 check was deleted from armed_chain_peek. The
-- Sniper-style refactor replaces this cooldown-based heuristic with
-- the defer-for-Pike check inside armed_threats_tick (added in step 5).

-- v0.5.38 MAINT-11.2: chain-peek helper extracted from armed_threats_tick.
-- Behaviour-neutral. Walks the resolved save order, mirrors the dispatcher's
-- reserve / concurrent-penalty gate (RESERVE_SKIP_FLOOR / CONCURRENT_PENALTY
-- kept identical to defense_dispatcher; mirror invariant unchanged), and
-- returns (should_fire, fire_reason, eta_trigger_eff). The save_dist branch
-- mutates entry._fire_dist_eff / entry._fire_save_eff in-place so caller
-- scratch state is identical to the inlined version.
local function armed_chain_peek(entry, d, eta_trigger_eff)
    -- v0.5.7 (E13): the peek must mirror TrySaveSelf's full gate or we wait
    -- on the wrong save's eta_trigger. v0.5.39 M1+P3: peek and dispatch share
    -- one source of truth via Dispatcher:CountConcurrentExcluding (count) and
    -- state.RESERVE_SKIP_FLOOR / state.CONCURRENT_PENALTY (thresholds); these
    -- locals just alias the state.* values for readability. Affects Tusk/Bara/PA.
    local RESERVE_SKIP_FLOOR    = state.RESERVE_SKIP_FLOOR
    local CONCURRENT_PENALTY    = state.CONCURRENT_PENALTY
    local chain = defense_dispatcher:ResolveSaveOrder(entry.threat_mod, "close_gap", entry.ability)
    -- v0.5.39 M1 (Option A): delegate concurrent-other count to the dispatcher.
    -- Single source of truth (entry-handle identity per v0.5.14 BL-A5/BL-B7).
    -- The armed-fire path threads `entry` into try_save_self -> Dispatcher:Try-
    -- SaveSelf -> Dispatcher:CountConcurrentExcluding(entry), so peek+dispatch
    -- agree on n=0 for the typical single-armed case (previously they drifted:
    -- peek excluded by entry-handle, dispatch by (caster_idx, threat_mod)).
    local concurrent_other = defense_dispatcher:CountConcurrentExcluding(entry)
    for i = 1, #chain do
        local sn = chain[i]
        local ready = save_is_ready(sn)
        local reserved = false
        if ready then
            local penalty = (TD.SaveReservePenalty and TD.SaveReservePenalty(sn, entry.threat_mod)) or 0
            if concurrent_other >= 1 then penalty = penalty + CONCURRENT_PENALTY end
            reserved = penalty < RESERVE_SKIP_FLOOR
        end
        if ready and not reserved then
            -- v0.5.55: removed the v0.5.51 per-save catalog gate +
            -- v0.5.54.1 W skip-after-item check + v0.5.47.2 W-specific
            -- live-eta fallback. Chain walker returns to its pre-
            -- v0.5.51 shape (Sniper-style): pure distance +
            -- eta_trigger fall-through. Per-save timing (W's
            -- impact_t window, predict-aim, etc.) lives inside each
            -- save's .fire body now; see lina_w_anti_gap.fire below
            -- for the W-specific catalog timing.
            --
            -- v0.5.55.2: W-specific catalog gate (scoped, not the
            -- v0.5.51 generic per-save pattern). Per user spec:
            -- "use the ETA > time to cast and if this is the case we
            -- can cast to stun bara as soon as he hits lina". Fixed
            -- SAVE_FIRE_DISTANCE / SAVE_ETA_TRIGGER values don't
            -- track real speed (eta = d/600 misses fast and slow
            -- Bara). The catalog impact_t IS the real ETA. Fire W
            -- when impact_t in [W_LEAD, W_LEAD + W_AOE_RADIUS/speed]
            -- = W detonates at or just before Bara arrives. Outside:
            -- skip, block legacy gates from firing W via
            -- eta_trigger_eff = -1 sentinel.
            if sn == "lina_w_anti_gap" and state.compute_arrival_time
               and entry.threat_mod and entry.caster then
                local _w_impact_t, _, _w_cat_entry, _w_speed =
                    state.compute_arrival_time(entry.threat_mod, entry.caster, state.self_npc)
                if _w_impact_t and _w_cat_entry then
                    local _w_kind = _w_cat_entry.kind or ""
                    if _w_kind == "homing_charge" then
                        -- v0.5.115.1 (user: "lina is starting the casting
                        -- too late"): this peek gate was a STALE TWIN of
                        -- the .fire timing -- it still enforced the OLD
                        -- arrival window with 1.12/225 literals, so the
                        -- chain was not even DISPATCHED until Bara was
                        -- ~840u out (the v0.5.115 demo log: every fire at
                        -- via=w_catalog_eta dist~841-849), capping every
                        -- cast start regardless of what the segment gate
                        -- inside .fire wanted. It now shares the ONE
                        -- criterion with the .fire body
                        -- (state.w_charge_intercept): dispatch the moment
                        -- the covering aim becomes castable, which starts
                        -- the cast from ~1300u+ on far charges (the
                        -- max-range intercept finally reachable) and
                        -- immediately on near ones.
                        local castable, _w_aim, _w_near, _w_far, _w_range =
                            state.w_charge_intercept(entry.caster, entry.threat_mod)
                        if castable ~= nil then
                            tlog(3, "w_catalog_eta_gate", {
                                d        = string.format("%.0f", d),
                                aim      = string.format("%.0f", _w_aim or -1),
                                near     = string.format("%.0f", _w_near or -1),
                                far      = string.format("%.0f", _w_far or -1),
                                range    = string.format("%.0f", _w_range or -1),
                                castable = castable and "y" or "n",
                                kind     = _w_kind,
                            })
                            if castable then
                                entry._fire_save_eff = sn
                                return true, "w_catalog_eta", eta_trigger_eff
                            end
                            -- Not yet castable (too_early): block the
                            -- legacy gates from firing W via the -1
                            -- sentinel; re-evaluated next tick.
                            return false, nil, -1
                        end
                        -- helper nil (positions/kinematics unavailable):
                        -- fall through to the legacy gates.
                    elseif _w_kind == "homing_carry" then
                        -- Tusk arrival window (the snowball must be met
                        -- AT Lina). v0.5.115.1: live geometry via
                        -- state.w_lead() + the intercept margin (was the
                        -- same stale 1.12/225 literals).
                        local W_LEAD, W_AOE_RADIUS = state.w_lead()
                        local _w_lower = W_LEAD
                        local _w_upper = (_w_speed and _w_speed > 0)
                            and (W_LEAD + K.W_INTERCEPT_MARGIN_S + W_AOE_RADIUS / _w_speed)
                            or (W_LEAD + K.W_INTERCEPT_MARGIN_S + 0.20)
                        local _w_in_window = _w_impact_t >= _w_lower and _w_impact_t <= _w_upper
                        tlog(3, "w_catalog_eta_gate", {
                            d         = string.format("%.0f", d),
                            speed     = string.format("%.0f", _w_speed or 0),
                            impact_t  = string.format("%.2f", _w_impact_t),
                            lower     = string.format("%.2f", _w_lower),
                            upper     = string.format("%.2f", _w_upper),
                            in_window = _w_in_window and "y" or "n",
                            kind      = _w_kind,
                        })
                        if _w_in_window then
                            entry._fire_save_eff = sn
                            return true, "w_catalog_eta", eta_trigger_eff
                        end
                        return false, nil, -1
                    end
                end
                -- impact_t nil OR non-homing kind: fall through to
                -- legacy gates (W can still fire as last-resort
                -- fallback for non-catalog threats).
            end

            -- v0.5.10: PROXIMITY GATE. Spatial distance is
            -- concrete; cast-point times vary with talents/items.
            -- Pike enemy-cast path bypasses (its own
            -- pike_enemy_range gate inside SAVE_FIRE.fire);
            -- self-displacement saves additionally refuse below
            -- K.SAVE_FIRE_DISTANCE_SELF_PUSH_FLOOR so we never push
            -- Lina INTO the impact zone of a threat that already
            -- crossed her position.
            local is_pike_enemy_cast = (sn == "item_hurricane_pike"
                and entry.caster and Target.IsAlive(entry.caster)
                and not (NPC.HasState and NPC.HasState(entry.caster, MS.MODIFIER_STATE_MAGIC_IMMUNE))
                and dist_to(entry.caster) <= state.pike_enemy_range())
            local dov = SAVE_FIRE_DISTANCE[sn]
            local is_self_push = (sn == "item_force_staff" or sn == "item_hurricane_pike")
            local under_floor = is_self_push and d < K.SAVE_FIRE_DISTANCE_SELF_PUSH_FLOOR
            if dov and not is_pike_enemy_cast and not under_floor and d <= dov then
                entry._fire_dist_eff = dov
                entry._fire_save_eff = sn
                return true, "save_dist", eta_trigger_eff
            end
            -- Fallback: v0.5.6 SAVE_ETA_TRIGGER time-gate.
            local ov = SAVE_ETA_TRIGGER[sn]
            if ov then
                if is_pike_enemy_cast then
                    -- enemy-cast path: keep the 0.8s lead from entry default
                else
                    eta_trigger_eff = ov
                end
            end
            return false, nil, eta_trigger_eff
        end
    end
    return false, nil, eta_trigger_eff
end

-- v0.5.135 close-gap redesign (Slice 2A): catalog-driven gap-closer armer.
-- Unifies the 3 hardcoded modifier-create arms (Bara / Tusk / Primal) into one
-- helper. The validated trio keeps EXACT values via LINA_ARM_TUNED (byte-
-- equivalent: same key, ability, threat_mod, eta_speed/eta_trigger, Bara's
-- armed_t ramp anchor, tlog name, modcreate_counter bump, same-caster overwrite
-- guard, and the candidacy-before-IsEnemyHero ordering that keeps the per-event
-- cost off non-gap-closer modifiers). Additional travel gap-closers (Slice 2B)
-- arm off the lib TD.THREAT_ARRIVAL_TIMING catalog with per-kind defaults. The
-- fixed trio keys are preserved so OnModifierDestroy's fixed-key clears
-- (bara_charge / tusk_snowball) + its generic threat_mod sweep keep working.
local LINA_ARM_TUNED = {
    modifier_spirit_breaker_charge_of_darkness = {
        key = "bara_charge", ability = "spirit_breaker_charge_of_darkness",
        eta_speed = 600, eta_trigger = 0.8, ramp = true,  -- ramp -> stamp armed_t (v0.5.114 ramp clock)
        tlog = "bara_charge_armed",
    },
    modifier_tusk_snowball_movement = {
        key = "tusk_snowball", ability = "tusk_snowball",
        eta_speed = 1200, eta_trigger = 0.5,
        tlog = "tusk_snowball_armed",
    },
    -- v0.5.128.1: Primal Onslaught is a line DASH that STUNS on impact (reactive
    -- save impossible) -> ARM on the dash modifier + fire WW by PROXIMITY (instant
    -- cast lifts Lina airborne in time). NOT in TD.THREAT_ARRIVAL_TIMING, so the
    -- tuned entry supplies its params directly. Resolves via
    -- ANIM_SAVE_OVERRIDES["primal_beast_onslaught"] -> CH.PRIMAL_ONSLAUGHT.
    modifier_primal_beast_onslaught_movement_adjustable = {
        key = "primal_onslaught", ability = "primal_beast_onslaught",
        eta_speed = 1200, eta_trigger = 0.4,
        tlog = "primal_onslaught_armed",
    },
    -- v0.5.136.1 realignment: Slark moved OUT of here into the lib
    -- TD.THREAT_ARRIVAL_TIMING catalog (kind=leap). It now arms via the helper's
    -- catalog path (LINA_ARM_KIND_DEFAULT[leap] supplies eta_trigger 0.4 + timeout
    -- 1.5) and resolves the composed close_gap chain (its hero override dropped).
    -- LINA_ARM_TUNED keeps ONLY the genuine hand-tuned exceptions (Bara ramp/0.8,
    -- Tusk 0.5, Primal 0.4); generic gap-closers are one lib-catalog line.
}
-- Per-KIND defaults for catalogued travel gap-closers WITHOUT a tuned entry
-- (Slice 2B additions). eta_speed falls back to the catalog speed_fallback.
-- instant_blink is deliberately ABSENT: those arm via the on_gap_close anim
-- path (state.armed_threats["instant_blink:<ability>"]), not modifier-create.
local LINA_ARM_KIND_DEFAULT = {
    homing_charge = { eta_trigger = 0.5 },
    homing_carry  = { eta_trigger = 0.5 },
    leap          = { eta_trigger = 0.4, timeout = 1.5 },  -- v0.5.136: anim-armed leaps self-clear (no OnModifierDestroy)
}

-- ARM a tuned/catalogued travel gap-closer at modifier-create. Returns true if
-- it armed (or a same-caster entry already exists), false if the modifier is not
-- an arm trigger (or the caster is not an enemy hero). Candidacy (tuned/catalog
-- travel-kind) is resolved BEFORE the IsEnemyHero call so non-gap-closer
-- modifiers exit on two cheap table lookups -- matching the pre-refactor cost.
-- The fire happens later by proximity/eta in armed_threats_tick.
state.try_arm_catalog_gap_closer = function(npc, mod_name)
    local key, ability, eta_speed, eta_trigger, ramp, tlog_name, kind, timeout
    local tuned = LINA_ARM_TUNED[mod_name]
    if tuned then
        key, ability    = tuned.key, tuned.ability
        eta_speed       = tuned.eta_speed
        eta_trigger     = tuned.eta_trigger
        ramp, tlog_name = tuned.ramp, tuned.tlog
        timeout         = tuned.timeout
    else
        local cat = TD.THREAT_ARRIVAL_TIMING and TD.THREAT_ARRIVAL_TIMING[mod_name]
        kind = cat and cat.kind
        local kd = kind and LINA_ARM_KIND_DEFAULT[kind]
        if not kd then return false end  -- not a travel gap-closer we pre-arm
        key         = "gapclose:" .. mod_name
        ability     = nil  -- catalog-armed: no anim override -> dispatch via close_gap
        eta_speed   = cat.speed_fallback or 600
        eta_trigger = kd.eta_trigger
        ramp        = false
        timeout     = kd.timeout
    end
    if not (Target.IsEnemyHero and Target.IsEnemyHero(npc, state.self_npc)) then
        return false
    end
    local existing = state.armed_threats[key]
    if existing and existing.caster == npc then return true end  -- same-caster: keep
    if tlog_name then
        tlog(1, tlog_name, { caster = uname(npc) })
    else
        tlog(1, "gap_closer_armed", { key = key, kind = kind or "?", caster = uname(npc) })
    end
    state.modcreate_counter = state.modcreate_counter + 1
    state.armed_threats[key] = {
        caster = npc, ability = ability, threat_mod = mod_name,
        armed_t = ramp and now() or nil,
        -- v0.5.136 Slice 2B: leaps (anim-armed, no OnModifierDestroy clear) carry
        -- a timeout so a pounce-elsewhere entry self-clears (armed_threats_tick).
        t = timeout and now() or nil, timeout = timeout,
        eta_speed = eta_speed, eta_trigger = eta_trigger, fired = false,
    }
    return true
end

-- v0.5.38 MAINT-11.2: post-fire effect helper extracted from
-- armed_threats_tick. Behaviour-neutral. Side-effect ordering preserved:
-- entry.fired stamp, slot nil, armed_threat_fire tlog (kvargs character-
-- identical), try_save_self call, Dedup.threat_mark_responded (AFTER
-- try_save_self returns, mirroring the inlined order), scratch clear.
-- Void return: the inlined original never inspected try_save_self's
-- return value, so promoting it to a bool would be a behaviour delta.
local function armed_post_fire(key, entry, eta, d, fire_reason)
    -- v0.5.97 fix #6: do NOT consume the armed row or stamp Dedup until a save
    -- ACTUALLY fires. The pre-v0.5.97 order set entry.fired + nil'd the slot + marked
    -- the 2s Dedup lock UNCONDITIONALLY, so a chain that fired nothing (W out-of-window
    -- / mana / items on CD / dispatch_blocked) consumed the threat with no save AND no
    -- re-attempt -> the threat landed unsaved. The consume + Dedup are now gated on the
    -- try_save_self result below; on a no-fire the row survives for the next tick to
    -- re-evaluate. Throttle re-attempts to ~10Hz (avoid per-tick chain-walk + log spam)
    -- and give up after 4s (drop WITHOUT Dedup so a fresh observation can re-arm) to
    -- bound entry types that lack their own GC (e.g. instant-blink). Homing /
    -- cast-point entries normally GC earlier (OnModifierDestroy / cp-timeout); 4s is a
    -- conservative backstop that never drops a legit entry (all impact well within it).
    if entry._last_attempt_t and (now() - entry._last_attempt_t) < 0.1 then return end
    entry._first_attempt_t = entry._first_attempt_t or now()
    entry._last_attempt_t  = now()
    if (now() - entry._first_attempt_t) > 4.0 then
        state.armed_threats[key] = nil
        tlog(2, "armed_threat_give_up", { key = key, via = fire_reason })
        return
    end
    -- v0.5.46 Problem B belt: stash threat eta for SAVE_FIRE.lina_w_anti_gap.fire
    -- to consult below. W skips if cur_armed_eta < 1.0s AND the threat mod is
    -- in the v0.5.46.2 carry-Lina allowlist (state.W_skip_too_late_mods).
    -- cast_point entries pass eta=0 here as a sentinel (real timing lives in
    -- entry._cp_t), so stash nil for those to avoid a false skip. Cleared at
    -- function end so non-armed call sites of W's .fire (proactive Dispatch,
    -- etc.) see nil and fall through. v0.5.46.2: also stash threat_mod so the
    -- W belt can gate against the carry-Lina allowlist (Tusk snowball etc).
    state.cur_armed_eta        = (not entry.cast_point_threat) and eta or nil
    -- v0.5.107 (user rule, "skill used in vain"): stash cp_remaining for the
    -- WW/Eul post-launch gate inside their SAVE_FIRE bodies. Cast-point
    -- entries only; nil for homing/blink so the gate is inert elsewhere.
    state.cur_armed_cp_t       = entry.cast_point_threat and entry._cp_t or nil
    state.cur_armed_threat_mod = entry.threat_mod
    -- v0.5.46.3: stash threat caster handle so SAVE_FIRE.lina_w_anti_gap.fire
    -- can aim W at the caster's predicted position W_LEAD seconds ahead
    -- (Geometry.PredictPos uses smoothed velocity samples; matches the
    -- caster's actual movement during charge / snowball / etc). Cleared
    -- at function exit alongside cur_armed_eta + cur_armed_threat_mod.
    state.cur_armed_caster     = entry.caster
    -- v0.5.6 (E2): eta_t shows the per-save effective trigger
    -- actually used this tick (entry default 0.8s when no
    -- override hit, or blink_arrived/eta_critical paths).
    -- v0.5.9 (E5): fire_dist + save_eff record which SAVE_FIRE_DISTANCE
    -- entry triggered the via='save_dist' path (single-event-per-fire,
    -- no separate save_dist_choice event to avoid double-logging).
    -- Negative fire_dist sentinel keeps non-save_dist greps distinguishable;
    -- save_eff '-' fallback marks paths where no save-specific distance
    -- gate was consulted (blink_arrived / eta_critical / eta_trigger).
    -- v0.5.39 BUG-3: cp_t field added to armed_threat_fire tlog. For
    -- cast-point-armed entries it records cp_remaining at fire time (the
    -- value computed by armed_threats_tick's cast_point branch); for
    -- legacy homing/blink entries the field stays at -1 sentinel.
    tlog(1, "armed_threat_fire", { key = key, eta = string.format("%.2f", eta),
        dist = string.format("%.0f", d), via = fire_reason,
        eta_t = string.format("%.2f", entry._eta_trigger_eff or (entry.eta_trigger or 0.8)),
        fire_dist = string.format("%.0f", entry._fire_dist_eff or -1),
        save_eff = (entry._fire_save_eff or "-"),
        cp_t = string.format("%.2f", entry._cp_t or -1) })
    -- v0.5.39 M1 (Option A): pass `entry` as armed_entry so Dispatcher:CountConcurrent-
    -- Excluding self-excludes by entry-handle identity (matches armed_chain_peek).
    -- v0.5.39 BUG-3: cast-point entries route through the dispatcher with their
    -- own category (targeted_burst / hard_disable / delayed_aoe) so
    -- LINA_SAVE_OVERRIDES (e.g. Sniper Assassinate BKB-first chain) wins over
    -- the close_gap default. Homing/blink entries keep close_gap.
    local fired
    if entry.cast_point_threat then
        fired = try_save_self("armed_" .. key, entry.threat_mod, entry.caster, entry.category, entry.ability, entry)
    else
        fired = try_save_self("armed_" .. key, entry.threat_mod, entry.caster, "close_gap", entry.ability, entry)
    end
    -- v0.5.97 fix #6: commit (consume row + mark the 2s Dedup lock) ONLY on a real
    -- fire. On a no-fire the row + cur_armed_* are left for the next tick's re-attempt.
    if fired then
        entry.fired = true
        state.armed_threats[key] = nil
        Dedup.threat_mark_responded(state.responded_threats, entry.caster, entry.threat_mod)
    end
    -- v0.5.9 (E5): clear audit scratch so a re-armed entry (after
    -- Dedup window expiry) does not inherit stale SAVE_FIRE_DISTANCE
    -- bookkeeping from the previous fire.
    entry._fire_dist_eff = nil
    entry._fire_save_eff = nil
    entry._cp_t = nil
    -- v0.5.46 Problem B belt: drop the eta stash so subsequent W .fire
    -- calls outside the armed path (proactive Dispatch, etc.) see nil
    -- and skip the too-late check. Same-tick chain re-entry not a
    -- concern here -- the lock domain (v0.5.40) gates re-entry until
    -- the in-flight save resolves. v0.5.46.2: also drop threat_mod stash.
    state.cur_armed_eta        = nil
    state.cur_armed_threat_mod = nil
    state.cur_armed_caster     = nil  -- v0.5.46.3
    state.cur_armed_cp_t       = nil  -- v0.5.107
end

-- Armed homing / instant-blink threats: fire on arrival (instant-blink) or at
-- ETA (Bara charge / Tusk snowball). Wind Waker is the top Lina save and is
-- range-agnostic self-cast, so no Pike-range staging (unlike Sniper).
local function armed_threats_tick()
    if not next(state.armed_threats) then return end
    if not state.self_npc then return end
    for key, entry in pairs(state.armed_threats) do
        if not entry.caster or not Entity.IsEntity(entry.caster) or not Target.IsAlive(entry.caster) then
            tlog(2, "armed_threat_invalidated", { key = key })
            state.armed_threats[key] = nil
        elseif entry.lotus_pending and not entry.fired then
            -- v0.5.39 BUG-2: lotus-deferral branch. Poll Lotus readiness; fire
            -- the moment it readies, otherwise demote at deadline. Side-effect
            -- order: entry.fired stamp -> slot nil -> tlog -> try_save_self ->
            -- Dedup.threat_mark_responded (mirrors armed_post_fire ordering).
            -- v0.5.97 fix #6: same consume-before-confirm gate as armed_post_fire.
            -- Fire only while Lotus is ready AND before the deadline; commit (row
            -- consume + Dedup) only on a real Dispatch fire; throttle the retry so a
            -- ready-Lotus-but-Dispatch-blocked entry does not spam. The deadline branch
            -- is the give-up (demote to the standard chain), so the re-attempt is bounded.
            local past_deadline = now() > (entry.deadline_t or 0)
            if NPCLib.item_ready(state.self_npc, "item_lotus_orb") and not past_deadline then
                if not (entry._last_attempt_t and (now() - entry._last_attempt_t) < 0.1) then
                    entry._last_attempt_t = now()
                    tlog(1, "lotus_defer_fired", { key = key, mod = entry.threat_mod })
                    -- v0.5.40 A3-2: route armed lotus-defer fire through Dispatch so the
                    -- Lotus chain-head walk shares the v0.5.40 lock domain with the
                    -- castpt/line/anim paths. armed_entry=entry threads the live row
                    -- through to CountConcurrentExcluding (matches armed_chain_peek).
                    local fired = defense_dispatcher:Dispatch("lotus_defer_" .. entry.threat_mod,
                                                entry.threat_mod, entry.caster,
                                                state.self_npc, nil,
                                                nil, nil, entry, record_save,
                                                { fs_shard_window = fs_shard_window_active() })  -- v0.5.40 B2 GAP-3
                    if fired then
                        entry.fired = true
                        state.armed_threats[key] = nil
                        Dedup.threat_mark_responded(state.responded_threats, entry.caster, entry.threat_mod)
                    end
                end
            elseif past_deadline then
                state.armed_threats[key] = nil
                tlog(1, "lotus_defer_demoted", { key = key, mod = entry.threat_mod, reason = "deadline" })
                -- Fall through to the standard chain (Lotus is still down; chain
                -- head will skip and the BKB/Force/Pike tail picks up).
                if not Dedup.threat_already_responded(state.responded_threats, entry.caster, entry.threat_mod) then
                    if try_save_self("lotus_defer_demoted_" .. entry.threat_mod,
                                     entry.threat_mod, entry.caster, nil, nil) then
                        Dedup.threat_mark_responded(state.responded_threats, entry.caster, entry.threat_mod)
                    end
                end
            end
        elseif not entry.fired then
            local d = dist_to(entry.caster)
            if entry.cast_point_threat then
                -- v0.5.39 BUG-3: cast-point-armed branch. arm_t + cast_point
                -- were stamped at arm time (handle_lotus_first /
                -- handle_threat_on_self / on_hard_disable). cp_remaining
                -- shrinks each tick; fire when (a) chain-head save has a
                -- SAVE_FIRE_DISTANCE entry and we've closed inside it, OR
                -- (b) cp_remaining hits the chain-head's SAVE_ETA_TRIGGER.
                -- Distance gate aborts when caster walks out of max_dist.
                -- Panic timeout (cp + 0.3s) GCs stuck entries.
                local now_t = now()
                local cp_remaining = (entry.cast_point or 0) - (now_t - (entry.arm_t or now_t))
                -- v0.5.107: the during-cast marker (the threat modifier on
                -- Lina, e.g. the Assassinate crosshair) is present while
                -- casting AND while the projectile flies, destroyed on
                -- cancel/impact. Past cast end with the marker GONE = the
                -- cast was cancelled or has already impacted -> GC now, so
                -- no save fires on a dead threat. Anim-armed instants whose
                -- marker never existed also exit here at cast end (their
                -- impact already happened).
                local cp_marker = state.self_npc and entry.threat_mod
                    and NPC.HasModifier(state.self_npc, entry.threat_mod)
                if entry.max_dist and d > entry.max_dist then
                    tlog(2, "cast_point_threat_abort_dist", { key = key,
                        dist = string.format("%.0f", d),
                        max_dist = tostring(entry.max_dist) })
                    state.armed_threats[key] = nil
                elseif cp_remaining < 0 and not cp_marker then
                    tlog(2, "cast_point_cast_gone", { key = key,
                        cp_t = string.format("%.2f", cp_remaining) })
                    state.armed_threats[key] = nil
                elseif cp_remaining < -1.5 then
                    -- v0.5.107: grace widened -0.3 -> -1.5 for the in-flight
                    -- window -- WW/Eul now fire POST-launch ("in vain" rule)
                    -- and a max-range Assassinate flies ~1.2s. Cancelled
                    -- casts are bounded by the marker-gone GC above, so the
                    -- wider grace only extends LIVE in-flight rows.
                    tlog(2, "cast_point_threat_timeout", { key = key,
                        cp = string.format("%.2f", entry.cast_point or 0) })
                    state.armed_threats[key] = nil
                else
                    local chain = defense_dispatcher:ResolveSaveOrder(
                        entry.threat_mod, entry.category, entry.ability)
                    local head = chain and chain[1] or nil
                    local eta_trigger_eff = (head and SAVE_ETA_TRIGGER[head]) or 0.35
                    local should_fire, fire_reason = false, nil
                    local prox = head and SAVE_FIRE_DISTANCE[head]
                    if prox and d <= prox then
                        should_fire, fire_reason = true, "cp_save_dist"
                        entry._fire_dist_eff = prox
                        entry._fire_save_eff = head
                    elseif cp_remaining <= eta_trigger_eff then
                        should_fire, fire_reason = true, "cp_eta_trigger"
                        entry._eta_trigger_eff = eta_trigger_eff
                    end
                    if should_fire and Dedup.threat_already_responded(state.responded_threats, entry.caster, entry.threat_mod) then
                        entry.fired = true
                        should_fire = false
                        state.armed_threats[key] = nil
                        tlog(2, "armed_threat_skip_responded", { key = key })
                    end
                    if should_fire then
                        entry._cp_t = cp_remaining
                        -- eta arg is 0 for cp entries - the cp_t field in
                        -- the armed_threat_fire tlog carries the meaningful
                        -- timing signal. via=cp_save_dist / cp_eta_trigger
                        -- distinguishes the path from homing eta_trigger.
                        armed_post_fire(key, entry, 0, d, fire_reason)
                    end
                end
            elseif entry.timeout and entry.t and (now() - entry.t) > entry.timeout then
                -- v0.5.136 Slice 2B: anim-armed leaps (Slark Pounce) have no
                -- OnModifierDestroy signal, so they self-clear on a timeout if the
                -- pounce went elsewhere (stale-entry wrong-fire guard, v0.5.42).
                tlog(2, "armed_threat_leap_expired", { key = key })
                state.armed_threats[key] = nil
            elseif entry.instant_blink and entry.t and (now() - entry.t) > K.BLINK_ARRIVE_TIMEOUT_S then
                tlog(2, "armed_threat_blink_expired", { key = key })
                state.armed_threats[key] = nil
            else
                local eta = d / (entry.eta_speed and entry.eta_speed > 0 and entry.eta_speed or 600)
                local should_fire, fire_reason = false, nil
                if entry.instant_blink then
                    if d <= K.BLINK_ARRIVE_DIST_U then
                        if not entry.arrived_at then
                            entry.arrived_at = now()
                        elseif (now() - entry.arrived_at) >= K.BLINK_SETTLE_S then
                            should_fire, fire_reason = true, "blink_arrived"
                        end
                    end
                elseif eta <= 0.35 then
                    should_fire, fire_reason = true, "eta_critical"
                else
                    -- v0.5.55 defer-for-Pike (Sniper pattern, Sniper.lua:8220).
                    -- If Pike is ready AND the threat caster will close to
                    -- Pike's 425u range within the next ~0.15s of travel,
                    -- DEFER the brain's chain so AutoDisabler.lua's Pike
                    -- fires first. Without this, the brain chain walker
                    -- reaches W at impact_t in [1.12, 1.48] (d ~ 700) BEFORE
                    -- Bara closes to Pike's range (d <= 425), so W fires,
                    -- then AD Pike fires later = double save. With the
                    -- defer, the brain waits until either: (a) Pike has
                    -- fired (cooldown going up, Pike no longer "ready"), or
                    -- (b) Bara walked past Pike's range without Pike firing
                    -- (Pike on CD or some other gate); in (b), brain chain
                    -- walker resumes and fires its fall-through save (W).
                    local _pike_ready  = NPCLib.item_ready(state.self_npc, "item_hurricane_pike")
                    local _pike_range  = state.pike_enemy_range and state.pike_enemy_range() or 425
                    local _spd         = (entry.eta_speed and entry.eta_speed > 0) and entry.eta_speed or 600
                    local _will_enter_pike_soon = _pike_ready
                        and (d - _pike_range) > 0
                        and (d - _pike_range) < (_spd * 0.15)
                    if _will_enter_pike_soon then
                        tlog(3, "armed_threat_defer_for_pike", {
                            key         = key,
                            dist        = string.format("%.0f", d),
                            eta         = string.format("%.2f", eta),
                            pike_range  = string.format("%.0f", _pike_range),
                        })
                        -- should_fire stays false; no chain walk this tick.
                    else
                        -- v0.5.6 (E2): peek the chain to find the FIRST eligible
                        -- save and use its per-save eta_trigger override. Data-
                        -- driven: the table is keyed by save_name, not by modifier.
                        -- eta_critical (0.35) above still wins below this gate.
                        -- v0.5.38 MAINT-11.2: chain-walk extracted to armed_chain_peek
                        -- (behaviour-neutral). entry._fire_dist_eff / _fire_save_eff
                        -- mutations happen inside the helper on the save_dist branch.
                        local eta_trigger_eff = entry.eta_trigger or 0.8
                        should_fire, fire_reason, eta_trigger_eff = armed_chain_peek(entry, d, eta_trigger_eff)
                        -- v0.5.10: only fall through to time-gate if proximity gate
                        -- did not fire above (preserves save_dist precedence; without
                        -- this guard, eta_trigger would overwrite fire_reason).
                        if not should_fire and eta <= eta_trigger_eff then
                            should_fire, fire_reason = true, "eta_trigger"
                            entry._eta_trigger_eff = eta_trigger_eff
                        end
                    end
                end
                if should_fire and Dedup.threat_already_responded(state.responded_threats, entry.caster, entry.threat_mod) then
                    entry.fired = true
                    should_fire = false
                    state.armed_threats[key] = nil
                    tlog(2, "armed_threat_skip_responded", { key = key })
                end
                if should_fire then
                    -- v0.5.38 MAINT-11.2: post-fire bookkeeping extracted to
                    -- armed_post_fire (behaviour-neutral). Side-effect order
                    -- preserved: fired stamp -> slot nil -> tlog -> try_save_self
                    -- -> Dedup.threat_mark_responded -> scratch clear.
                    armed_post_fire(key, entry, eta, d, fire_reason)
                end
            end
        end
    end
end

-- E11: re-fire saves during persistent threats Lina can still ACT through
-- (Legion Duel restricts targeting not casting; Static Storm silences
-- abilities but items still fire). Full-disable grips (Bane / Pudge) are NOT
-- listed -- Lina is helpless during them, so re-fire is pointless.
K.PERSISTENT_THREAT_TICK_INTERVAL = 2.1
local PERSISTENT_THREATS = {
    modifier_legion_commander_duel          = true,
    modifier_disruptor_static_storm_thinker = true,
    -- v0.5.137.1: Pugna Life Drain. The drain modifier lands on the VICTIM
    -- (Lina), so the tick's HasModifier(me) gate matches. Re-walks CH.PUGNA_DRAIN
    -- (W-head interrupt) every 2.1s while draining, so the W interrupt fires the
    -- instant W comes off CD mid-channel (the v0.5.137 demo found the drain
    -- un-interrupted when W was on CD at channel-start + never re-dispatched). Its
    -- lock-TTL resolver was ALREADY capped at PERSISTENT_LOCK_CAP_S -- the re-walk
    -- was wired on the resolver side, only the membership here was missing.
    modifier_pugna_life_drain               = true,
}
-- v0.5.137.1: expose for the in-brain regression test (state.tests.W02_*),
-- mirroring state.lina_chains. Read-only in the test.
state.lina_persistent_threats = PERSISTENT_THREATS
local function persistent_threats_tick()
    local me = state.self_npc
    if not me or not Entity.IsAlive(me) then return end
    if not defense_enabled() then return end
    -- v0.5.21 OBS-11: per-subsystem toggle. Skip the re-fire loop entirely
    -- when disabled so a misbehaving Duel / Static Storm tick path can be
    -- silenced without touching the rest of the defense layer.
    if state.menu and state.menu.enable_persistent_refire
       and not state.menu.enable_persistent_refire:Get() then
        return
    end
    state.last_persistent_tick_t = state.last_persistent_tick_t or {}
    -- v0.5.37 PERF-07: state.frame_t sampled at top of OnUpdateEx. The stamp
    -- below (state.last_persistent_tick_t[mod_name] = now_t) feeds the same
    -- tick-local interval gate next frame, so frame_t vs now() is equivalent.
    local now_t = state.frame_t
    -- v0.5.141: W-ready RISING EDGE off-grid re-fire. The 2.1s grid
    -- (K.PERSISTENT_THREAT_TICK_INTERVAL) was the ONLY gate on the W-interrupt
    -- re-fire, so when W came off CD mid-channel it could sit ready up to ~2.1s
    -- before the next grid re-walk fired it (v0.5.140 demo, Pugna: ticks at
    -- 28700/28791/28884 all w_stun not_ready, fired only on tick #4 -- "took more
    -- time than usual to use W again, not as soon it came out from CD"). Detect W
    -- transitioning not-ready -> ready and dispatch THAT frame, off-grid. Only the
    -- rising edge triggers (then W is on its ~6.7s CD so w_ready is false again)
    -- -> fires at most once per W CD cycle, no spam, no redundant tail-save burn (W
    -- heads the persistent W-interrupt chain, e.g. CH.PUGNA_DRAIN). The grid still
    -- paces the rest of the chain. Edge is CONSUMED after one dispatch so two
    -- simultaneous persistent threats cannot double-dispatch on the same frame.
    -- The lock cap (PERSISTENT_LOCK_CAP_S 1.7s < 2.1s grid) is unchanged: an
    -- edge-fired W goes on CD, so the next grid re-walk (lock long expired) finds
    -- it not_ready -- no double-fire.
    local _wab = ability("lina_light_strike_array")
    local w_ready = (_wab and Ability.GetLevel(_wab) > 0 and Ability.IsReady(_wab)) and true or false
    local w_edge = w_ready and not state.persistent_w_was_ready
    state.persistent_w_was_ready = w_ready
    for mod_name in pairs(PERSISTENT_THREATS) do
        if NPC.HasModifier(me, mod_name) then
            local last_t = state.last_persistent_tick_t[mod_name] or 0
            local do_grid = (now_t - last_t) >= K.PERSISTENT_THREAT_TICK_INTERVAL
            if do_grid or w_edge then
                local via = do_grid and "grid" or "edge"
                if not do_grid then w_edge = false end  -- consume the W-ready edge
                state.last_persistent_tick_t[mod_name] = now_t
                local mod = NPC.GetModifier(me, mod_name)
                local caster = mod and Modifier.GetCaster(mod)
                if caster and Entity.IsEntity(caster) and Target.IsAlive(caster) and layer2_can_fire() then
                    -- v0.5.40 A3-4: preserve the deliberate Dedup clear
                    -- (belt-and-suspenders; v0.5.40 resolver-side lock-TTL
                    -- cap of ~2.2s for persistent classes is what actually
                    -- permits the re-fire each K.PERSISTENT_THREAT_TICK_INTERVAL
                    -- =2.1s -- the lock has expired by the time we re-enter
                    -- this branch, so no ForceNextDispatch needed).
                    state.responded_threats[tostring(Entity.GetIndex(caster)) .. ":" .. mod_name] = nil
                    tlog(1, "persistent_threat_tick", { mod = mod_name, caster = uname(caster), via = via })
                    defense_dispatcher:Dispatch("persistent_" .. mod_name,
                                                mod_name, caster,
                                                state.self_npc, nil,
                                                nil, nil, nil,
                                                record_save,
                                                { fs_shard_window = fs_shard_window_active() })  -- v0.5.40 B2 GAP-3
                end
            end
        else
            state.last_persistent_tick_t[mod_name] = nil
        end
    end
end

-- E5 (REWORKED v0.2.7): ally-save is THREAT-REACTIVE, not an HP poll. The
-- v0.2.4 HP-threshold scan was wrong (spammed Lotus on low-HP allies, never
-- fired Glimmer). This mirrors the self-save model: when a recognized threat
-- lands on an ally hero (driven from OnModifierCreate, same as the self path),
-- walk an ally-CASTABLE chain and fire the right item ON the ally. Self-cast
-- saves (Wind Waker / BKB / Flame Cloak) cannot help an ally, so they are
-- absent. Opt-in / off by default. Trigger = the threat, NOT the ally's HP.
local ALLY_SAVE_FIRE = {
    item_glimmer_cape   = { short = "ally_glimmer", fire = function(intent, ally) return issue_item_target(intent, "def", NPCLib.item(state.self_npc, "item_glimmer_cape"),   ally) end },
    item_lotus_orb      = { short = "ally_lotus",   fire = function(intent, ally) return issue_item_target(intent, "def", NPCLib.item(state.self_npc, "item_lotus_orb"),      ally) end },
    item_force_staff    = { short = "ally_force",   fire = function(intent, ally) return issue_item_target(intent, "def", NPCLib.item(state.self_npc, "item_force_staff"),    ally) end },
    item_hurricane_pike = { short = "ally_pike",    fire = function(intent, ally) return issue_item_target(intent, "def", NPCLib.item(state.self_npc, "item_hurricane_pike"), ally) end },
}

-- Ally chains keyed to lib categories (TD.CategoryOf). Glimmer-first for
-- gap-close / right-click (invis breaks the target lock); Lotus-first for
-- disable / burst (dispel + reflect); Force for channels (push the ally out).
local ALLY_CHAIN_BY_CATEGORY = {
    close_gap       = { "item_glimmer_cape", "item_force_staff", "item_lotus_orb" },
    physical_chase  = { "item_glimmer_cape", "item_force_staff", "item_lotus_orb" },
    lockdown        = { "item_lotus_orb", "item_glimmer_cape", "item_force_staff" },
    targeted_burst  = { "item_lotus_orb", "item_glimmer_cape" },
    channel_on_self = { "item_force_staff", "item_lotus_orb", "item_hurricane_pike" },
    -- v0.5.2 A.2: drain (Lion Mana Drain etc.) - Force-on-ally pushes them out
    -- of the tether range. Diagnostic showed modifier_lion_mana_drain reaching
    -- the ally branch with category=drain but no ally chain.
    drain           = { "item_force_staff" },
}
local ALLY_DEFAULT_CHAIN = { "item_glimmer_cape", "item_lotus_orb", "item_force_staff" }
-- Cast ranges (items.json 7.41C).
local ALLY_SAVE_RANGE = {
    item_glimmer_cape = 800, item_lotus_orb = 900,
    item_force_staff  = 800, item_hurricane_pike = 425,
}

-- "Actually endangered" gate (user directive 2026-05-28): a landed threat
-- alone is not enough to spend an ally-save; the ally must be in real danger.
-- Endangered if low HP (a follow-up can kill) OR being collapsed on (>= 2
-- enemy heroes inside the focus radius, lethal even at high HP). The THREAT is
-- still the trigger; HP is one danger factor, not the trigger.
K.ALLY_DANGER_HP_FRAC = 0.65  -- v0.5.21 PT-07: 0.55 -> 0.65. 0.55 missed the danger-window where Glimmer/Force/Lotus would still have prevented a kill. 0.65 widens the trigger without spamming saves on healthy allies.
K.ALLY_FOCUS_RADIUS   = 1100  -- v0.5.21 PT-07: 700 -> 1100. 700u was tighter than most threat cast ranges (Lion Hex 800, Lina R 700, AA Ice Blast 1000+). The danger is the THREAT range, not adjacent combat distance.
K.ALLY_FOCUS_COUNT    = 2
local function ally_is_endangered(ally)
    local hp    = Entity.GetHealth(ally) or 0
    local hpmax = Entity.GetMaxHealth(ally) or 1
    local hp_frac = (hpmax > 0) and (hp / hpmax) or 1
    if hp_frac < K.ALLY_DANGER_HP_FRAC then return true end
    local ally_pos = NPCLib.origin(ally)
    if ally_pos then
        local foes = Heroes.InRadius(ally_pos, K.ALLY_FOCUS_RADIUS,
            Entity.GetTeamNum(ally), Enum.TeamType.TEAM_ENEMY)
        if foes then
            local n = 0
            for i = 1, #foes do
                local e = foes[i]
                if e and Target.IsAlive(e) and Target.NotIllusion(e) then n = n + 1 end
            end
            if n >= K.ALLY_FOCUS_COUNT then return true end
        end
    end
    return false
end

-- A recognized enemy threat (threat_mod) just landed on `ally`. Walk the
-- category chain and fire the first ready, in-range ally-castable item ON the
-- ally. First-success-wins (no combo, lesson 3); the reaction window keeps it
-- from stacking with a self-save.
local function try_save_ally(ally, threat_mod, threat_caster)
    if not (state.menu and state.menu.ally_save and state.menu.ally_save:Get()) then return false end
    if not (ally and Entity.IsEntity(ally) and Target.IsAlive(ally)) then return false end
    if not layer2_can_fire() then return false end  -- v0.5.40 A4-HERO: belt-and-suspenders; DispatchAlly thunk branch re-checks CanFire
    if not ally_is_endangered(ally) then
        tlog(3, "ally_save_skip", { ally = uname(ally), reason = "not_endangered" })
        return false
    end

    local category = (threat_mod and TD.CategoryOf and TD.CategoryOf(threat_mod)) or nil
    local chain = (category and ALLY_CHAIN_BY_CATEGORY[category]) or ALLY_DEFAULT_CHAIN

    -- v0.5.40 A4-HERO: wrap the bespoke ally chain walk in a fire_thunk so
    -- DispatchAlly owns the (ally_idx, canonical_mod, caster_idx) lock and a
    -- second ally-save attempt against the same threat is blocked by the
    -- ally lock domain. The generic chain-walk inside the lib does not
    -- implement the SAVE_FIRE_DISTANCE caster->ally gate or the ally Lotus
    -- filter (entry.fire encapsulates the ally Lotus check), so the walk
    -- body stays in the thunk byte-equivalent to v0.5.39. The thunk owns the
    -- record_save call (the lib does not invoke on_save_fired on the thunk
    -- branch); tlog event names (ally_save_chain_skip / ally_save_fire) and
    -- chain priority order are preserved so log greps survive.
    local fire_thunk = function(_intent, _mod, _caster)
        for _, save_name in ipairs(chain) do
            local entry = ALLY_SAVE_FIRE[save_name]
            if entry and save_is_ready(save_name) and dist_to(ally) <= (ALLY_SAVE_RANGE[save_name] or 800) then
                -- v0.5.9 E6 (C6): minimal ally-side proximity firing gate. Reuse
                -- the SAVE_FIRE_DISTANCE table that the self-save armed_threats_tick
                -- closure already consults so semantics stay consistent across
                -- self/ally ("fire when the threat is almost hitting"). Gate is
                -- caster->ally (NOT Lina->ally; ALLY_SAVE_RANGE above already covers
                -- Lina's reach). One-shot check at modifier-create; per-tick
                -- re-eval for ally targets is deferred to the v0.5.10 ally-armed
                -- tick architecture. If SAVE_FIRE_DISTANCE is absent (older save
                -- with no entry) the gate is a no-op and the existing time-based
                -- SAVE_ETA_TRIGGER + 0.35s eta_critical safety net keep firing.
                -- v0.5.36 MAINT-08: removed cargo-cult rawget(_G) fallback - never assigned to _G
                local sfd = SAVE_FIRE_DISTANCE
                local dov = sfd and sfd[save_name] or nil
                if dov and threat_caster and Entity.IsEntity(threat_caster) and Entity.IsAlive(threat_caster) then
                    local cpos = Entity.GetAbsOrigin(threat_caster)
                    local apos = Entity.GetAbsOrigin(ally)
                    if cpos and apos and (cpos - apos):Length2D() > dov then
                        tlog(3, "ally_save_chain_skip", { save = entry.short, reason = "fire_dist_gate",
                            dov = dov, d2a = (cpos - apos):Length2D() })
                        goto continue_ally_chain
                    end
                end
                do
                    local intent = "save_" .. entry.short
                    if entry.fire(intent, ally) then
                        record_save(intent, entry.short, threat_mod, nil)
                        tlog(1, "ally_save_fire", { ally = uname(ally), item = entry.short,
                            threat = threat_mod or "-", category = category or "-" })
                        return true
                    end
                    tlog(3, "ally_save_chain_skip", { save = entry.short, reason = "fire_returned_false" })
                end
            end
            ::continue_ally_chain::
        end
        return false
    end

    -- v0.5.40 A4-HERO: DispatchAlly args (positional):
    --   intent         = "save_ally"  umbrella; per-item intent built in thunk
    --   threat_mod     = threat_mod   lib canonicalizes for lock key
    --   threat_caster  = threat_caster
    --   ally_unit      = ally         target leg of (ally_idx, canon_mod, caster_idx) lock
    --   fire_thunk     = fire_thunk   signals thunk branch; bespoke walk above
    --   ally_chain     = nil          thunk uses captured local chain; override unused
    --   category_hint  = category     passed for resolver/tlog context
    --   ability_name   = nil          ally branch is modifier-keyed, no anim path
    --   armed_entry    = nil          no armed_threats entry on ally path
    --   on_save_fired  = nil          thunk calls record_save directly; lib does
    --                                  not invoke on_save_fired on thunk branch
    --   ctx            = nil
    return defense_dispatcher:DispatchAlly(
        "save_ally", threat_mod, threat_caster, ally,
        fire_thunk, nil, category, nil, nil, nil,
        { fs_shard_window = fs_shard_window_active() })  -- v0.5.40 B2 GAP-3
end

-- v0.5.171: K.PRE_FACE_* constants removed with the pre_face_tick feature (menu-simplification).

local function self_alive_ok()
    local me = state.self_npc
    if not me or not Entity.IsAlive(me) then return false end
    if NPC.HasState(me, MS.MODIFIER_STATE_STUNNED)    then return false end
    if NPC.HasState(me, MS.MODIFIER_STATE_HEXED)      then return false end
    if NPC.HasState(me, MS.MODIFIER_STATE_SILENCED)   then return false end
    if NPC.HasState(me, MS.MODIFIER_STATE_NIGHTMARED) then return false end
    if NPC.HasState(me, MS.MODIFIER_STATE_TAUNTED)    then return false end
    if MS.MODIFIER_STATE_COMMAND_RESTRICTED ~= nil
       and NPC.HasState(me, MS.MODIFIER_STATE_COMMAND_RESTRICTED) then return false end
    if NPC.HasState(me, MS.MODIFIER_STATE_INVULNERABLE) then return false end
    if NPC.HasState(me, MS.MODIFIER_STATE_OUT_OF_GAME)  then return false end
    return true
end
-- v0.5.158.1: exposed for the FC defensive fire (SAVE_FIRE.lina_flame_cloak.fire +
-- state.fc_defense_tick) to gate on "can Lina cast an ability right now". A cast
-- issued while STUNNED/HEXED/SILENCED/INVULNERABLE (e.g. airborne in her own
-- Eul/WW) is silently dropped by the engine -- the v0.5.158 demo issued FC during
-- not_self_alive and it never cast (cast_verify fired=n).
state.lina_self_alive_ok = self_alive_ok

-- v0.5.171: enemy_has_ready_target_threat removed with the pre_face_tick feature (its only caller).

-- v0.5.171: pre_face_tick (the preface_enable feature) cut in menu-simplification. It was default OFF, so removing it preserves behavior; the caller, state, and K.PRE_FACE_* are removed too.

-- v0.5.147.x hooks the cast-poll save watches (Pudge Meat Hook + Clockwerk Hookshot).
-- mod = canonical victim modifier (the v0.5.40 lock key + LINA_SAVE_OVERRIDES key);
-- range = cast reach; cone (deg) = facing gate; prox = close-range proximity fallback.
-- First-pass values, tunable from demo.
local HOOK_CAST_POLL = {
    pudge_meat_hook     = { mod = "modifier_pudge_meat_hook",     range = 1500, cone = 25, prox = 600 },
    rattletrap_hookshot = { mod = "modifier_rattletrap_hookshot", range = 3000, cone = 25, prox = 600 },
    -- Power Cogs is NO_TARGET (no facing cone). range = prox makes hook_gate_pass proximity-only
    -- (dist <= prox passes; dist > range=prox returns false before the cone branch). prox 250 ~=
    -- cogs_radius 215 + margin (KV rattletrap_power_cogs; tune from the demo dist=). mod =
    -- _cog_marker (the trap marker that lands on the victim, DEMO-confirmed; the VPK grep missed
    -- it but the runtime log is ground truth) so the cast-poll dedups vs the reactive landing.
    rattletrap_power_cogs = { mod = "modifier_rattletrap_cog_marker", range = 250, cone = 360, prox = 250 },
    -- v0.5.149: the "un-keyable stun" cast-poll entries (Dragon Tail / Storm Bolt / Lightning Bolt /
    -- Slardar Crush) were REVERTED 2026-06-16. The demo proved those threats have REAL victim modifiers
    -- already cataloged + handled by the existing composed chains (so the cast-poll was redundant = the
    -- overlap the user flagged; the stale "un-keyable" VPK list missed the real modifiers -- the runtime
    -- log is ground truth, the cog lesson again). Cast-poll watches hooks + cogs ONLY.
}

-- v0.5.147.x hook cast-poll gate (PURE; offline-tested via HK01 + standalone lua).
-- Fire if within the hook's cast range AND (caster facing within cone_deg of Lina
-- OR within the close-range prox fallback). angle_deg = deg(|FindRotationAngle|),
-- may be nil if unreadable (cone then fails; prox can still pass).
function state.hook_gate_pass(dist, angle_deg, range, cone_deg, prox)
    if not dist or dist > range then return false end
    if dist <= prox then return true end
    return angle_deg ~= nil and angle_deg <= cone_deg
end

-- v0.5.147.x hook cast-poll SAVE (Demo-1 confirmed H-A: Pudge Hook / Clockwerk Hookshot
-- emit NO OnUnitAnimation + no OnLinearProjectileCreate; the reactive landing is too late).
-- Poll enemies' HOOK_CAST_POLL abilities for Ability.IsInAbilityPhase (validated enemy-side),
-- gate (facing-cone OR close-range prox, re-checked each tick; Cogs is prox-only), and dispatch
-- the per-skill chain pre-impact via the dispatcher (LINA_SAVE_OVERRIDES[cfg.mod] -> CH.HOOK_
-- INTERCEPT / CH.CLOCKWERK_HOOKSHOT / CH.CLOCKWERK_COGS). Per-cast latch (state.hook_cast_
-- dispatched, GC'd when the cast ends) = at most one dispatch per hook; the v0.5.40 lock dedups
-- vs any later reactive landing -> single save. ~16Hz throttle, 3000u scan.
local function cast_poll_save_tick()
    if state.menu and state.menu.hook_cast_poll and not state.menu.hook_cast_poll:Get() then return end
    if not defense_enabled() then return end
    if not self_alive_ok() then return end
    local now_t = state.frame_t or now()
    if (now_t - (state.cast_poll_t or 0)) < 0.06 then return end
    state.cast_poll_t = now_t
    local me = state.self_npc
    local me_pos = me and NPCLib.origin(me)
    if not me_pos then return end
    local enemies = NPCs.InRadius(me_pos, 3000,
        Entity.GetTeamNum(me), Enum.TeamType.TEAM_ENEMY, true, true)
    if not enemies then return end
    local dispatched = state.hook_cast_dispatched or {}
    local active = {}
    for _, e in ipairs(enemies) do
        if Target.IsValid(e) and Target.IsAlive(e)
           and Target.IsEnemyHero(e, me) and Target.NotIllusion(e) then
            for slot = 0, 5 do
                local ok_a, a = pcall(NPC.GetAbilityByIndex, e, slot)
                if ok_a and a and Ability.GetLevel(a) > 0 then
                    local ok_n, nm = pcall(Ability.GetName, a)
                    local cfg = ok_n and nm and HOOK_CAST_POLL[nm]
                    if cfg then
                        local ok_p, inphase = pcall(Ability.IsInAbilityPhase, a)
                        if ok_p and inphase then
                            local key = Entity.GetIndex(e) .. ":" .. nm
                            active[key] = true
                            if not dispatched[key] then
                                local d = dist_to(e)
                                local ang
                                local ok_r, r = pcall(NPC.FindRotationAngle, e, me_pos)
                                if ok_r and r then ang = math.deg(math.abs(r)) end
                                if state.hook_gate_pass(d, ang, cfg.range, cfg.cone, cfg.prox) then
                                    dispatched[key] = true
                                    local via = (d and d <= cfg.prox) and "prox" or "cone"
                                    tlog(1, "hook_cast_poll_fire", {
                                        enemy   = uname(e),
                                        ability = nm,
                                        mod     = cfg.mod,
                                        dist    = string.format("%.0f", d or -1),
                                        angle   = ang and string.format("%.0f", ang) or "?",
                                        via     = via,
                                    })
                                    defense_dispatcher:Dispatch(
                                        "hook_cast_poll_" .. nm,           -- intent
                                        cfg.mod,                           -- threat_mod
                                        e,                                 -- threat_caster
                                        me,                                -- target_unit
                                        nil,                               -- fire_thunk (chain walker)
                                        "close_gap",                       -- category_hint
                                        nil,                               -- ability_name
                                        nil,                               -- armed_entry
                                        record_save,                       -- on_save_fired
                                        { fs_shard_window = fs_shard_window_active() }  -- ctx
                                    )
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    for k in pairs(dispatched) do
        if not active[k] then dispatched[k] = nil end
    end
    state.hook_cast_dispatched = dispatched
end

-- Anim subscribers: route the lib's role events (fired by the per-enemy
-- RegisterMap catalog below, wired in v0.2.5) to the Layer-2 dispatchers.
-- OnModifierCreate detection still runs in parallel and dedups any overlap.
local INSTANT_BLINK_THREATS = {
    phantom_assassin_phantom_strike = true,
    queenofpain_blink               = true,
}
-- v0.5.3: defensive enemy-caster guard. v0.5.2 demo showed
-- `hard_disable_lina_laguna_blade` firing Lotus on self when OUR Lina cast
-- Laguna at an enemy - meaning `ev.target_self` was unreliable (the particle
-- subscription path appears to set it true regardless of which side cast it).
-- Belt-and-suspenders: also require the caster to be a recognized enemy hero.
-- Catches self-casts (ev.caster == self_npc), ally casts, neutral / creep
-- casts. Cheap: one Target.IsEnemyHero call.
local function is_threat_caster(ev)
    return ev and ev.caster and Entity.IsEntity(ev.caster)
           and Target.IsEnemyHero and Target.IsEnemyHero(ev.caster, state.self_npc)
end
-- v0.5.19 (anim handler dedup CHECK at entry): v0.5.18 added dedup STAMPING
-- after the save fired, but the engine emits multiple OnUnitAnimation events
-- per cast for some abilities (Lion Hex showed 2x hard_disable_lion_voodoo
-- fires per single cast). A stamp without an entry check still permits the
-- 2nd / 3rd invocation to fire another save. Each handler now bails up-front
-- if the threat is already marked responded for the same caster.
local function on_gap_close(ev)
    if not ev.target_self then return end
    if not is_threat_caster(ev) then return end
    local threat = ABILITY_TO_THREAT[ev.ability_name or ""]
    if threat and Dedup.threat_already_responded(state.responded_threats, ev.caster, threat) then
        tlog(3, "anim_dedup_skip", { mod = threat, path = "gap_close", ability = ev.ability_name or "?" })
        return
    end
    if not Dedup.anim_throttled(state.anim_log_dedup, ev.caster, ev.ability_name) then
        tlog(1, "anim_gap_close_on_me", { caster = uname(ev.caster), ability = ev.ability_name or "?" })
    end
    if INSTANT_BLINK_THREATS[ev.ability_name or ""] and ev.caster and Entity.IsEntity(ev.caster) then
        local key = "instant_blink:" .. (ev.ability_name or "?")
        if not state.armed_threats[key] then
            -- v0.5.99 lead-(b) fix: ABILITY_TO_THREAT has no entry for some
            -- INSTANT_BLINK_THREATS abilities (queenofpain_blink = nil, "mobility
            -- only"), so `threat` is nil there and the row stored threat_mod=nil ->
            -- an unresolvable dispatch lock key (no dedup) + nil in diagnostics. Fall
            -- back to a synthetic collision-free mod ("instant_blink_<ability>") so the
            -- lock key resolves + logs are clean. The save still resolves via
            -- category_hint="close_gap" (armed_post_fire); LINA_SAVE_OVERRIDES + the
            -- v0.5.98 BKB veto simply don't match the synthetic (correct: a mobility
            -- blink is neither overridden nor BKB-blocked).
            local tmod = threat or ("instant_blink_" .. (ev.ability_name or "unk"))
            tlog(1, "instant_blink_armed", { caster = uname(ev.caster), ability = ev.ability_name or "?" })
            Dedup.threat_clear_responded(state.responded_threats, ev.caster, tmod)
            state.armed_threats[key] = { caster = ev.caster, threat_mod = tmod,
                ability = ev.ability_name, eta_speed = 1500, eta_trigger = 0.4,
                fired = false, instant_blink = true, t = now() }
        end
        return
    end
    -- v0.5.136 Slice 2B: traveling gap-closers (leap / charge) ARM + fire by
    -- PROXIMITY (the Bara pattern) instead of dispatching the save at cast -- an
    -- instant airborne save fired at cast is too early (the "fire by proximity"
    -- rule). try_arm_catalog_gap_closer arms iff the threat is registered
    -- (LINA_ARM_TUNED, e.g. Slark) or catalogued as a travel kind; it returns
    -- false for non-traveling close-gappers, which fall through to the immediate
    -- reactive dispatch below. (The charge trio already arm via OnModifierCreate,
    -- so an anim hit here is a dedup'd no-op via the same-caster key guard.)
    if threat and state.try_arm_catalog_gap_closer(ev.caster, threat) then
        return
    end
    -- v0.5.25 RPR-03: stamp dedup AFTER try_save_self success. The
    -- pre-v0.5.25 stamp-before-call would leave the threat dedup-locked
    -- for THREAT_WINDOW=2s (lib/dedup.lua:49) when try_save_self bailed
    -- early, silently swallowing the next observation in that window.
    -- The v0.5.19 entry-side dedup CHECK above still prevents dual-fire
    -- across multi-anim events per cast.
    -- v0.5.40 A3-5 (+v0.5.41 DEDUP-CLEANUP): route gap-close anim through
    -- Dispatch with category_hint="close_gap". Closes the bara WW+Pike
    -- double-fire from the v0.5.39 demo: this anim path and the
    -- armed_threats_tick homing branch share the per-(self_npc,
    -- canonical_mod, bara) lock key. v0.5.41: Dispatcher lock is sole gate;
    -- belt-and-suspenders Dedup.threat_mark_responded post-stamp removed.
    defense_dispatcher:Dispatch("gap_close_" .. (ev.ability_name or "unk"),
                                threat, ev.caster,
                                state.self_npc, nil,
                                "close_gap", ev.ability_name, nil,
                                record_save,
                                { fs_shard_window = fs_shard_window_active() })  -- v0.5.40 B2 GAP-3
end
local function on_hard_disable(ev)
    if not ev.target_self then return end
    if not is_threat_caster(ev) then return end
    -- v0.5.39 BUG-3: cast-point arming via the anim path. PRIMARY entry -
    -- anim fires at cast-start (true pre-cast window), whereas
    -- OnModifierCreate fires after the modifier lands (catch-up only).
    -- If ev.ability_name maps to a CAST_POINT_THREATS entry, ARM and bail;
    -- armed_threats_tick will fire the save at end-of-cast-point via the
    -- chain-head SAVE_ETA_TRIGGER. Doom's anim path lands here too (was
    -- previously fall-through to the standard hard_disable try_save_self;
    -- the cast-point arming gives BKB / Lotus a proper impact-aligned
    -- fire moment instead of burning at cast-start).
    local cp_lookup = CAST_POINT_BY_ABILITY[ev.ability_name or ""]
    if cp_lookup and ev.caster and Entity.IsEntity(ev.caster) then
        local caster_idx = Entity.GetIndex(ev.caster)
        local arm_key = "castpt:" .. cp_lookup.mod .. ":" .. tostring(caster_idx)
        if not state.armed_threats[arm_key] then
            local cp_eff = resolve_live_cast_point(ev.caster, cp_lookup.entry.ability,
                                                   cp_lookup.entry.cp_default)
            state.armed_threats[arm_key] = {
                caster = ev.caster, threat_mod = cp_lookup.mod,
                ability = cp_lookup.entry.ability,
                cast_point = cp_eff,
                arm_t = now(),
                max_dist = cp_lookup.entry.max_dist,
                category = cp_lookup.entry.category,
                cast_point_threat = true, fired = false,
            }
            tlog(1, "cast_point_threat_armed", { mod = cp_lookup.mod,
                caster = uname(ev.caster), cp = string.format("%.2f", cp_eff),
                cat = cp_lookup.entry.category, path = "anim_hard_disable" })
            state.modcreate_counter = state.modcreate_counter + 1
        end
        -- v0.5.25 RPR-03 pattern: defer dedup stamp to post-fire
        -- (armed_post_fire stamps via Dedup.threat_mark_responded after
        -- try_save_self succeeds). Returning here skips the legacy
        -- try_save_self path.
        return
    end
    local threat = ABILITY_TO_THREAT[ev.ability_name or ""]
    if threat and Dedup.threat_already_responded(state.responded_threats, ev.caster, threat) then
        tlog(3, "anim_dedup_skip", { mod = threat, path = "hard_disable", ability = ev.ability_name or "?" })
        return
    end
    -- v0.5.40 A3-6 (+v0.5.41 DEDUP-CLEANUP): route hard-disable anim
    -- through Dispatch with category_hint="lockdown". Cast-point-armed
    -- branch above this site is the primary entry; this legacy fall-
    -- through services threats not in CAST_POINT_BY_ABILITY. v0.5.41:
    -- Dispatcher lock is sole gate; belt-and-suspenders Dedup post-stamp
    -- removed (v0.5.25 RPR-03 stamp-after-success obsolete here).
    defense_dispatcher:Dispatch("hard_disable_" .. (ev.ability_name or "unk"),
                                threat, ev.caster,
                                state.self_npc, nil,
                                "lockdown", ev.ability_name, nil,
                                record_save,
                                { fs_shard_window = fs_shard_window_active() })  -- v0.5.40 B2 GAP-3
end
local function on_channel_start(ev)
    if not ev.target_self then return end
    if not is_threat_caster(ev) then return end
    local threat = ABILITY_TO_THREAT[ev.ability_name or ""]
    if threat and Dedup.threat_already_responded(state.responded_threats, ev.caster, threat) then
        tlog(3, "anim_dedup_skip", { mod = threat, path = "channel_start", ability = ev.ability_name or "?" })
        return
    end
    -- v0.5.160.2 Note-1: Jugg Omnislash -- defer the untargetable (WW/Eul) dodge to
    -- mid-ult so his cast COMMITS first (dodging in the ~0.3s cast point refunds the
    -- ult). Ghost/E-blade (targetable, attack-immune) do not cancel the cast -> fire
    -- now. A low-HP Lina that cannot safely eat the first strike dodges at cast to
    -- survive. The defer tick fires the SAME chain Dispatch mid-ult.
    if ev.ability_name == "juggernaut_omni_slash" then
        local defer_on = true  -- v0.5.170: jugg_omni_defer hardcoded ON (menu-simplification)
        local immediate_ready = (state.lina_save_ready and
            (state.lina_save_ready("item_ghost") or state.lina_save_ready("item_ethereal_blade"))) or false
        local me = state.self_npc
        local cur_hp = (me and Entity.GetHealth and Entity.GetHealth(me)) or 0
        if defer_on and state.jugg_omni_should_defer(immediate_ready, cur_hp) then
            defense_dispatcher:ArmDodgeDefer({ caster = ev.caster,
                -- v0.5.160.4: the RUNTIME modifier is modifier_juggernaut_omnislash (one
                -- word, modseen ground truth) -- NOT ..._omni_slash. The ability name is
                -- juggernaut_omni_slash and the chain override key keeps that form, but the
                -- tick re-validates "still omnislashing" via NPC.HasModifier on THIS name.
                watch_modifier = "modifier_juggernaut_omnislash",
                fire_at = now() + K.JUGG_OMNI_DODGE_DELAY, min_hp = K.JUGG_OMNI_MIN_HP_ACCEPT })
            tlog(1, "jugg_omni_defer_arm", { hp = string.format("%.0f", cur_hp),
                delay = string.format("%.2f", K.JUGG_OMNI_DODGE_DELAY) })
            return   -- the defer tick fires WW/Eul mid-ult
        end
        -- else fall through to immediate Dispatch (Ghost/E-blade ready, low HP, toggle off)
    end
    -- v0.5.40 A3-7 (+v0.5.41 DEDUP-CLEANUP): route channel-on-self anim
    -- through Dispatch with category_hint="channel_on_self". v0.5.41:
    -- Dispatcher lock is sole gate; belt-and-suspenders Dedup post-stamp
    -- removed (v0.5.25 RPR-03 stamp-after-success obsolete here).
    defense_dispatcher:Dispatch("channel_" .. (ev.ability_name or "unk"),
                                threat, ev.caster,
                                state.self_npc, nil,
                                "channel_on_self", ev.ability_name, nil,
                                record_save,
                                { fs_shard_window = fs_shard_window_active() })  -- v0.5.40 B2 GAP-3
end

-- v0.5.160.3 Note-1 (Jugg Omnislash mid-ult dodge). The general decision + defer
-- state machine were LIFTED to lib/defense.lua (Defense.ShouldDeferDodge +
-- Dispatcher:ArmDodgeDefer / :DodgeDeferTick) so any hero benefits; these are the
-- thin Lina wrappers -- the chain, the omni modifier name, and the K tunables stay
-- hero-local. PURE decision (FCDEF11 + offline lib test): defer the untargetable
-- WW/Eul dodge iff no immediate save (Ghost/E-blade, attack-immune but TARGETABLE ->
-- does not cancel the cast) is ready AND Lina has the HP to eat the first strike.
-- Dodging during Jugg's ~0.3s cast point cancels + REFUNDS his ult; deferring past
-- it lets the ult commit, then the dodge whiffs the rest = Jugg loses the ult.
state.jugg_omni_should_defer = function(immediate_ready, cur_hp)
    return Defense.ShouldDeferDodge(immediate_ready, cur_hp, K.JUGG_OMNI_MIN_HP_ACCEPT)
end

-- Thin wrapper over the lib defer tick: passes Lina's self + clock + the dispatch
-- closure (which runs Lina's CH.JUGG_OMNI chain). The lib owns the pending state, the
-- mid-ult / hp-bail timing, and the re-validation (Jugg still slashing, Lina alive).
state.jugg_omni_defer_tick = function()
    defense_dispatcher:DodgeDeferTick({
        me = state.self_npc, now = now(),
        dispatch = function(caster, via, hp)
            defense_dispatcher:Dispatch("channel_juggernaut_omni_slash",
                "modifier_juggernaut_omni_slash", caster, state.self_npc, nil,
                "channel_on_self", "juggernaut_omni_slash", nil,
                record_save, { fs_shard_window = fs_shard_window_active() })
            tlog(1, "jugg_omni_defer_fire", { via = via, hp = string.format("%.0f", hp) })
        end,
    })
end

------------------------------------------------- Layer 1 offense foundation --
-- Per-tick offense context + kill-math + engagement count, consumed by the step
-- builders, dispatchers, HOLD/TAP detection, throttles and auto-R below.
-- Adaptive model is HOLD-only (COMBO_PATTERN.md).
local DT = Enum.DamageTypes

-- Live cast range of an ability/item handle (KV-accurate; avoids hardcodes).
local function cast_range_of(ab, fallback)
    if ab and Ability.GetCastRange then
        local ok, r = pcall(Ability.GetCastRange, ab)
        if ok and type(r) == "number" and r > 0 then return r end
    end
    return fallback or 0
end

-- v0.5.39 BUG-3: live cast point on a (caster, ability_name) pair. Mirrors
-- cast_range_of's pcall-guarded shape (Ability.GetCastPoint(handle, true)
-- includes talents / Scepter / Aghs-shard modifiers per Sniper.lua line ~475's
-- r_cast_point() pattern). Returns the data-table default when NPC.GetAbility
-- or Ability.GetCastPoint is unavailable, or the ability slot is empty. Used
-- by the cast-point arming branches in handle_lotus_first /
-- handle_threat_on_self / on_hard_disable; the resolved cast_point is stamped
-- on the armed_threats entry so armed_threats_tick can compute cp_remaining
-- from a stable value (the live cast point can't drift mid-cast).
-- v0.5.99.3: drops `local` to target the forward-declared upvalue (see ~L86).
resolve_live_cast_point = function(caster, ability_name, default)
    if not caster or not ability_name then return default or 0 end
    if not NPC.GetAbility or not Ability.GetCastPoint then return default or 0 end
    local ok_ab, ab = pcall(NPC.GetAbility, caster, ability_name)
    if not ok_ab or not ab then return default or 0 end
    local ok_cp, cp = pcall(Ability.GetCastPoint, ab, true)
    if ok_cp and type(cp) == "number" and cp > 0 then return cp end
    return default or 0
end

-- Laguna Blade instant impact damage at current level (KV "damage" =
-- 380/565/750, hardcoded fallback). Laguna is a single instant nuke: there is
-- NO "Slow Burn" DoT. v0.5.91 removed the old impact*0.64 burn credit, which
-- was hardcoded (not KV-backed) and inflated every R kill predicate ~64%.
-- Returns the instant impact only.
local function lina_r_damage()
    local r = ability(A.R)
    if not r or Ability.GetLevel(r) <= 0 then return 0, 0 end
    local impact = 0
    if Ability.GetLevelSpecialValueFor then
        local ok, v = pcall(Ability.GetLevelSpecialValueFor, r, "damage")
        if ok and type(v) == "number" and v > 0 then impact = v end
    end
    if impact == 0 then impact = ({ 380, 565, 750 })[Ability.GetLevel(r)] or 380 end
    return impact
end

-- v0.5.85: per-level magical nuke damage for Q (Dragon Slave) and W (Light
-- Strike Array), KV keys + fallbacks verified against lib/ability_data.lua
-- (dragon_slave_damage {65,125,185,245}, light_strike_array_damage
-- {80,120,160,200}; both damage_type=magical). Feeds the combo-kill predicate
-- so the brain accounts for the full W+Q+R burst, not R alone.
local function lina_q_damage()
    local q = ability(A.Q)
    if not q or Ability.GetLevel(q) <= 0 then return 0 end
    if Ability.GetLevelSpecialValueFor then
        local ok, v = pcall(Ability.GetLevelSpecialValueFor, q, "dragon_slave_damage")
        if ok and type(v) == "number" and v > 0 then return v end
    end
    return ({ 65, 125, 185, 245 })[Ability.GetLevel(q)] or 0
end
local function lina_w_damage()
    local w = ability(A.W)
    if not w or Ability.GetLevel(w) <= 0 then return 0 end
    if Ability.GetLevelSpecialValueFor then
        local ok, v = pcall(Ability.GetLevelSpecialValueFor, w, "light_strike_array_damage")
        if ok and type(v) == "number" and v > 0 then return v end
    end
    return ({ 80, 120, 160, 200 })[Ability.GetLevel(w)] or 0
end

-- Effective magical HP to kill `target`: current MR + barriers (via
-- Target.EffectiveHpVs) plus the HP it regens during R's 0.55s press-to-damage.
local function lina_eff_hp_magical(target)
    if not target or not Target.IsAlive(target) then return math.huge end
    local eff = (Target.EffectiveHpVs and Target.EffectiveHpVs(target, state.self_npc, DT.DAMAGE_TYPE_MAGICAL))
                or math.huge
    if NPC.CalculateHealthRegen then
        local ok, rgn = pcall(NPC.CalculateHealthRegen, target)
        if ok and type(rgn) == "number" then eff = eff + rgn * 0.55 end
    end
    return eff
end

-- v0.5.137: expose the (target-independent) combo damage helpers + the
-- target-specific eff-HP helper on state.* so state.combo_can_kill reads them
-- indirectly and the in-brain test (state.tests.W01_combo_can_kill) can inject
-- controlled numbers (the v0.5.17 lesson-14 mockability pattern). Production
-- behavior is identical -- the aliases ARE the locals.
state.lina_r_damage       = lina_r_damage
state.lina_q_damage       = lina_q_damage
state.lina_w_damage       = lina_w_damage
state.lina_eff_hp_magical = lina_eff_hp_magical

-- v0.5.150: ability-readiness hooks for the kill predicate, mockable like the
-- damage helpers (the in-brain W01 test stubs them). "Ready" = leveled + off CD
-- + castable (Ability.IsReady). The v0.5.149 offense study found combo_can_kill
-- credited R/Q while ON COOLDOWN, so w_capitalize committed a non-securing combo
-- and the leap-defer kept W (no dodge) when it could not actually finish.
-- NOTE: Ability.IsReady is used TRUTHY everywhere in this codebase (ready_from
-- L365, the leap-defer dodge_ready, L4606's `... and true or false`); it is NOT
-- guaranteed to return the literal boolean `true`. So coerce truthy->true rather
-- than comparing `== true` (which would be stuck-false if IsReady returns a
-- truthy non-boolean). Mirrors ready_from: leveled + off CD + castable.
local function lina_r_ready()
    local r = ability(A.R)
    return (r ~= nil and Ability.GetLevel(r) > 0 and Ability.IsReady(r)) and true or false
end
local function lina_q_ready()
    local q = ability(A.Q)
    return (q ~= nil and Ability.GetLevel(q) > 0 and Ability.IsReady(q)) and true or false
end
state.lina_r_ready = lina_r_ready
state.lina_q_ready = lina_q_ready

-- v0.5.153: Flame Cloak +35% OUTGOING spell amp (Liquipedia 7.41d). Credited in
-- the kill predicates ONLY while the buff is on Lina (active-only choice). Sibling
-- of ETHER_MAGIC_AMP (which lives by the ether-confirm region); declared HERE so
-- combo_can_kill (just below) AND build_layer1_ctx can both see it. FC is an
-- OUTGOING multiplier on Lina; Ethereal is a target resist-reduction (modeled
-- x1.40), so the two stack MULTIPLICATIVELY (raw x1.35 x1.40). lina_fc_active is
-- the mockable seam the in-brain W01 test stubs (mirrors lina_r_ready).
local FC_SPELL_AMP = 0.35
local function lina_fc_active()
    local me = state.self_npc
    return (me and NPC.HasModifier and NPC.HasModifier(me, "modifier_lina_flame_cloak")) and true or false
end
state.lina_fc_active = lina_fc_active

-- v0.5.137 W-capitalize kill gate (consumed by state.w_capitalize_tick). Can the
-- brain SECURE a kill on `target` RIGHT NOW? The defensive W (Light Strike Array)
-- has ALREADY dealt its damage + stun, so credit only the REMAINING burst Q
-- (Dragon Slave) + R (Laguna) -- NOT W again -- against the target's CURRENT
-- magical eff-HP (which already reflects the W hit; lina_eff_hp_magical reads
-- live HP). Conservative form mirrors r_alone_kill (eff_hp * 1.05 <= burst):
-- commit the dive only when the burst CLEARLY kills, never on a maybe (the
-- user's "only when the probability to kill is high" rule). Autos are NOT
-- credited (unreliable: range / disarm / turn). nil/dead target -> false (dead
-- yields eff_hp = math.huge from lina_eff_hp_magical, so math.huge*1.05 > burst).
state.combo_can_kill = function(target)
    if not target then return false end
    -- v0.5.152: cannot-kill targets (Shallow Grave / False Promise / WK Reincarnation
    -- ready) have no securable kill, so w_capitalize + the leap-defer must not commit.
    if Target.IsUnkillableNow and Target.IsUnkillableNow(target) then return false end
    -- v0.5.150: credit only the spells Lina can ACTUALLY cast right now (off CD +
    -- castable). A spell on cooldown contributes 0 to the burst, so the predicate
    -- reflects a kill she can secure, not one the damage math alone implies.
    local burst = 0
    if (state.lina_r_ready and state.lina_r_ready()) and state.lina_r_damage then
        burst = burst + (state.lina_r_damage() or 0)
    end
    if (state.lina_q_ready and state.lina_q_ready()) and state.lina_q_damage then
        burst = burst + (state.lina_q_damage() or 0)
    end
    if burst <= 0 then return false end
    -- v0.5.153: while Flame Cloak is up, Lina's spell damage is +35% (active-only).
    if state.lina_fc_active and state.lina_fc_active() then burst = burst * (1 + FC_SPELL_AMP) end
    local eff_hp = (state.lina_eff_hp_magical and state.lina_eff_hp_magical(target)) or math.huge
    return eff_hp * 1.05 <= burst
end

-- v0.5.155 FC arbiter, OFFENSE pillar (work-queue #6, Lina/FLAME_CLOAK_ARBITER_DESIGN.md).
-- The count of kills Flame Cloak's x(1+FC_SPELL_AMP) outgoing amp FLIPS on a committed
-- burst: the bare burst does NOT kill but the amped burst clearly does (1.05 headroom,
-- the r_alone_kill convention). The primary target uses the full combo_total (W+Q+R);
-- AoE members (enemies_in_aoe, may be nil for single-target) use q+w only since R hits
-- only the primary. Returns the flip COUNT: 0 = do not spend FC offensively (the bare
-- combo already kills, or the target is un-killable even amped); >=1 = FC rescues that
-- many kills. Phase 1 gates the existing FC openers on count >= 1 (primary-only); the
-- per-tick arbiter + the AoE/multi-target magnitude land in later phases.
-- v0.5.164 D1: the flip predicate is factored out so the unweighted COUNT
-- (fc_offense_value, the existing contract) and the value-weighted SUM
-- (fc_offense_value_w, Phase D) cannot diverge. on_hit(unit) is called once per
-- enemy FC's x(1+FC_SPELL_AMP) amp flips from a non-kill into a kill.
local function fc_for_each_flip(ctx, target, enemies_in_aoe, on_hit)
    if not (ctx and target) then return end
    local amp = 1 + FC_SPELL_AMP
    local combo_total = ctx.combo_total or 0
    local eff_p = (state.lina_eff_hp_magical and state.lina_eff_hp_magical(target)) or math.huge
    if combo_total > 0 and eff_p > combo_total and eff_p * 1.05 <= combo_total * amp then
        on_hit(target)
    end
    local aoe_burst = (ctx.q_dmg or 0) + (ctx.w_dmg or 0)
    if aoe_burst > 0 and enemies_in_aoe then
        for i = 1, #enemies_in_aoe do
            local u = enemies_in_aoe[i]
            if u and u ~= target then
                local eff_u = (state.lina_eff_hp_magical and state.lina_eff_hp_magical(u)) or math.huge
                if eff_u > aoe_burst and eff_u * 1.05 <= aoe_burst * amp then
                    on_hit(u)
                end
            end
        end
    end
end

state.fc_offense_value = function(ctx, target, enemies_in_aoe)
    local count = 0
    fc_for_each_flip(ctx, target, enemies_in_aoe, function() count = count + 1 end)
    return count
end

-- v0.5.164 D1: value-weighted flip score. W = sum of HeroValue.of over exactly
-- the flipped set fc_offense_value counts. peers = the AoE cluster (the primary
-- normalizes against the same set; nil peers -> base only, mult 1.0).
state.fc_offense_value_w = function(ctx, target, enemies_in_aoe)
    local w = 0
    fc_for_each_flip(ctx, target, enemies_in_aoe, function(u)
        w = w + (HeroValue.of(u, enemies_in_aoe) or 0)
    end)
    return w
end

-- v0.5.164 D1: exposed so in-brain tests can stub of() and the FC sites value-weight.
state.hero_value = HeroValue

-- v0.5.16x Phase D4 (design 8.1): the unified fc_arbiter decision line. ONE level-1
-- tlog per FC fire/hold, consolidating the scattered lina_flame_cloak_offensive
-- (fire) + fc_commit_eval/fc_commit_skip (commit hold) diagnostics into a single
-- grep-able record so a default-verbosity demo is the read-out surface for the
-- section-8.2 tuning sweep. fc_arbiter_fields is the PURE formatter (record ->
-- normalized kv): numbers fixed-width, fired y/n, bailout y/n/na (3-state, na =
-- no commit eval on this line), absent numerics na, claim defaults none. Exposed
-- on state for the in-brain FCAR01 test. (claim is carried by the formatter but
-- populated by the defense pillar's fc_arbiter_defense line; the offense fire/hold
-- lines default it to none in D4.1 -- the offense tuning knobs do not read it.)
local function _fcar_num(v, fmt) if type(v) == "number" then return string.format(fmt, v) else return "na" end end
local function _fcar_yn3(v) if v == true then return "y" elseif v == false then return "n" else return "na" end end
state.fc_arbiter_fields = function(r)
    r = r or {}
    return {
        tier    = r.tier or "?",
        reason  = r.reason or "?",
        fired   = r.fired and "y" or "n",
        W       = _fcar_num(r.W, "%.2f"),
        count   = _fcar_num(r.count, "%.0f"),
        cluster = _fcar_num(r.cluster, "%.0f"),
        keff    = _fcar_num(r.keff, "%.2f"),
        ae      = _fcar_num(r.ae, "%.2f"),
        ee      = _fcar_num(r.ee, "%.2f"),
        bailout = _fcar_yn3(r.bailout),
        claim   = r.claim or "none",
        stacks  = _fcar_num(r.stacks, "%.0f"),
    }
end
-- v0.5.168.4 D4.3 cleanup: emit the fc_arbiter line in a STABLE canonical column order
-- (design 8.1) so the tuning read-out scans cleanly (tlog's pairs() order jittered the
-- fields line-to-line). fc_arbiter_line is the pure ordered serializer (FCAR01-tested).
local FCAR_ORDER = { "tier", "reason", "fired", "W", "count", "cluster", "keff", "ae", "ee", "bailout", "claim", "stacks" }
state.fc_arbiter_line = function(f)
    local parts = { "fc_arbiter" }
    for i = 1, #FCAR_ORDER do local k = FCAR_ORDER[i]; parts[#parts + 1] = k .. "=" .. tostring(f[k]) end
    return table.concat(parts, " | ")
end
state.fc_arbiter_log = function(r) tlog(1, state.fc_arbiter_line(state.fc_arbiter_fields(r))) end

-- v0.5.170: hero_value_eval_log (the fc_value_debug observability probe) cut in
-- menu-simplification. It was a pure tuning log, no behavior depended on it.

-- v0.5.160 A3.2: the stack-aware cold-open predicate. Low Fiery Soul stacks at a
-- TF onset justify FC on their OWN (no kill-flip): the 0->7 jump is instant max
-- attack speed + the +35% amp landing across the whole opener. The TF-onset gating
-- (the fc_tf_opener_fired re-arm latch) + the commit gate live at the call site;
-- this is just the stack check. fs_at_cap is guarded by the opener chain.
state.fc_cold_open = function(ctx)
    return (ctx and (ctx.fiery_soul_stacks or 0) <= K.STACK_OPENER_MAX) or false
end

-- v0.5.36 MAINT-13: single source of truth for the Fiery Soul stack/cap
-- snapshot. build_layer1_ctx and the tf_q_poke pre-ctx branch both need
-- {stacks, cap, at_cap, shard_window} and used to duplicate the lookup -
-- the tf branch hardcoded base=7 / shard=12 and so silently ignored the
-- v0.5.21 PT-13 KV-read (fiery_soul_max_stacks). Now both sites call this
-- helper; build_layer1_ctx maps the struct onto ctx fields (same external
-- contract: ctx.fiery_soul_stacks / ctx.fs_cap / ctx.fs_at_cap /
-- ctx.fs_shard_window are still written), the tf branch reads stacks/cap
-- locally. KV fallback to 7 + diag tlog preserved; shard window stays +5
-- on top of base cap (12 - 7 differential).
local function compute_fs_state(me)
    local stacks = 0
    if me and NPC.GetModifier then
        local fs_mod = NPC.GetModifier(me, "modifier_lina_fiery_soul")
        if fs_mod and Modifier and Modifier.GetStackCount then
            local n = Modifier.GetStackCount(fs_mod)
            if type(n) == "number" then stacks = n end
        end
    end
    -- v0.5.37 PERF-08: cache the fiery_soul_max_stacks KV read keyed on
    -- the live E ability level. The KV is a per-level constant, so we
    -- only need to re-pcall on level-up; Ability.GetLevel is O(1) and
    -- replaces the per-call pcall + GetLevelSpecialValueFor pair. Same
    -- fallback semantics: 7 if e_ab is nil, the API is missing, or the
    -- KV read returns a non-positive number. The level=0 case (E not yet
    -- learned) never caches, so the very first level-1 cast picks up the
    -- real KV instead of latching the placeholder.
    local fs_cap_base = 7
    local e_ab = ability(A.E)
    local e_level = (e_ab and Ability.GetLevel and Ability.GetLevel(e_ab)) or 0
    if e_ab and Ability.GetLevelSpecialValueFor and e_level > 0 then
        if state.fs_cap_e_level_cached == e_level and state.fs_cap_base_cached then
            fs_cap_base = state.fs_cap_base_cached
        else
            local ok, v = pcall(Ability.GetLevelSpecialValueFor, e_ab, "fiery_soul_max_stacks")
            if ok and type(v) == "number" and v > 0 then
                fs_cap_base = v
                state.fs_cap_base_cached    = v
                state.fs_cap_e_level_cached = e_level
            else
                tlog(3, "fs_cap_kv_unverified", { ok = ok, v = v, fallback = 7 })
            end
        end
    else
        tlog(3, "fs_cap_kv_unverified", { ab_present = e_ab ~= nil, api_present = Ability.GetLevelSpecialValueFor ~= nil, e_level = e_level, fallback = 7 })
    end
    local cap          = fs_cap_base
    local shard_window = false
    if me and NPCLib.has_shard(me) and state.last_r_cast_t
       and (now() - state.last_r_cast_t) <= 5.0 then
        cap          = fs_cap_base + 5
        shard_window = true
    end
    return {
        stacks       = stacks,
        cap          = cap,
        at_cap       = stacks >= cap,
        shard_window = shard_window,
    }
end
state.compute_fs_state = compute_fs_state

-- Per-tick offense context. Built once, passed to every archetype predicate.
-- v0.5.37 PERF-08: reuses state.scratch_ctx instead of allocating a new
-- ~25-field table every call (1-2x per starter tick). schedule_step does a
-- shallow `for k,v in pairs(ctx) do snap[k] = v end` BEFORE the next tick
-- rebuilds, so the snapshot copy persists across the scratch reuse.
-- CAVEAT: lina_starter_tick can call build_layer1_ctx twice per tick
-- (offense target, then r_finisher_tgt swap) before either ctx is
-- snapshotted by fire_steps -> schedule_step. The second call would
-- clobber the first's fields, so the swap-case caller passes a fresh
-- `out` table to break the aliasing. The non-swap path (~97% of ticks)
-- still hits the scratch fast path.
local function build_layer1_ctx(target, out)
    local ctx = out
    if ctx == nil then
        ctx = state.scratch_ctx
        for k in pairs(ctx) do ctx[k] = nil end
    end
    local me = state.self_npc
    ctx.me     = me
    ctx.target = target
    ctx.d     = dist_to(target)
    ctx.t_pos = target and Entity.GetAbsOrigin(target) or nil
    ctx.mana  = (me and NPC.GetMana) and (NPC.GetMana(me) or 0) or 0

    -- v0.5.83: resolve each ability handle ONCE and derive readiness off the
    -- handle (ready_from) instead of re-resolving by name via ability_ready.
    -- Cuts NPC.GetAbility calls in this per-frame ctx-builder from 8 to 4
    -- (q/w/r/fc were each fetched twice). Identical level/ready results.
    local q, w, r, fc = ability(A.Q), ability(A.W), ability(A.R), ability(A.FC)
    ctx.ready_q = ready_from(q)
    ctx.ready_w = ready_from(w)
    ctx.ready_r = ready_from(r)
    ctx.flame_cloak_ready = ready_from(fc)
    -- v0.5.33 FC-A-05: don't re-fire FC during its 7s active window (cooldown
    -- is 25s, so a re-fire would waste the next 18s of CD for zero gain). The
    -- buff modifier name is per LIQUIPEDIA_REF L485; if the live KV string
    -- differs, this guard is no-op (HasModifier returns false) and the 25s
    -- engine cooldown prevents the actual double-fire anyway.
    ctx.flame_cloak_active = (NPC.HasModifier and NPC.HasModifier(me, "modifier_lina_flame_cloak")) or false
    -- v0.5.33 FC-A-06: FC interrupts own channels (TP, channel items). The
    -- offensive auto-fire MUST refuse during a channel - mirrors the
    -- SAVE_FIRE.lina_flame_cloak.fire IsChannellingAbility guard.
    ctx.is_channelling = (NPC.IsChannellingAbility and NPC.IsChannellingAbility(me)) or false
    -- v0.5.34 task E: catch the "cast accepted but modifier not yet applied"
    -- race. When the user manually presses D the same tick the brain dispatches
    -- (D is bound to FC at the Dota engine level - brain gets no signal), the
    -- modifier-create event lands 1-2 ticks after the cast, so NPC.HasModifier
    -- still returns false at the brain's gate check. The engine has already
    -- bumped FC's cooldown though. Probe BOTH the post-application modifier
    -- AND the live cooldown / cast phase so any of three signals blocks the
    -- duplicate dispatch. Replaces ctx.flame_cloak_active at both gate sites.
    do
        local fc_h = fc   -- v0.5.83: reuse the handle captured above (was a 2nd ability(A.FC))
        local fc_cd = (fc_h and Ability.GetCooldown and (Ability.GetCooldown(fc_h) or 0)) or 0
        local fc_phase = (fc_h and Ability.IsInAbilityPhase and Ability.IsInAbilityPhase(fc_h)) or false
        ctx.flame_cloak_in_flight = ctx.flame_cloak_active or (fc_cd > 0) or fc_phase
    end

    ctx.ether       = NPCLib.item(me, "item_ethereal_blade")
    ctx.ether_owned = ctx.ether ~= nil
    ctx.ether_ready = NPCLib.item_ready(me, "item_ethereal_blade")
    ctx.eul         = NPCLib.item(me, "item_cyclone")
    ctx.eul_owned   = ctx.eul ~= nil
    ctx.eul_ready   = NPCLib.item_ready(me, "item_cyclone")

    -- v0.5.4: NPC.GetModifierStackCount is not a UCZone API; use the documented
    -- two-step NPC.GetModifier + Modifier.GetStackCount lookup so the gate on
    -- ctx.fiery_soul_stacks > 0 is actually live (was silently frozen at 0).
    -- v0.5.5: Fiery Soul cap-aware. Base cap = 7; with Aghs Shard, the
    -- lina_laguna_super_charged buff raises the cap to 12 for 5s after every R
    -- cast (LIQUIPEDIA_REF Fiery Soul section). Extra stacks past cap do not
    -- help; the post-R window is time-limited, so the brain should pivot to
    -- ELIMINATION (commit kills faster) instead of stack-building.
    -- v0.5.21 PT-13: base cap read from KV (fiery_soul_max_stacks); fallback 7.
    -- v0.5.36 MAINT-13: stack/cap snapshot now produced by compute_fs_state
    -- so the tf_q_poke pre-ctx branch can share the exact same logic.
    local fs_state        = compute_fs_state(me)
    ctx.fiery_soul_stacks = fs_state.stacks
    ctx.fs_cap            = fs_state.cap
    ctx.fs_shard_window   = fs_state.shard_window
    ctx.fs_at_cap         = fs_state.at_cap

    -- v0.5.91 kill-calc fix: ALL R kill predicates use the INSTANT Laguna impact.
    -- The prior r_total = impact + 0.64*impact credited a 4s "Slow Burn" DoT
    -- (hardcoded, NOT KV-backed; Laguna is a single instant nuke) as if it were
    -- burst, inflating every R kill check ~64%. That made r_finisher fire R-alone
    -- on targets it could not one-shot (demo: Puck ate the solo R and survived)
    -- instead of leading with the W stun. r_impact is the instant value.
    local impact         = lina_r_damage()
    ctx.r_dmg            = impact
    ctx.r_impact         = impact
    ctx.r_total          = impact   -- no longer DoT-inflated; kept for readers
    ctx.eff_hp_magical   = lina_eff_hp_magical(target)
    -- v0.5.153: Flame Cloak +35% outgoing spell amp, credited ACTIVE-ONLY (the
    -- buff is on Lina right now). Raw r_impact / combo_total stay RAW (display +
    -- non-kill readers); the *_eff fields are the FC-amped burst the kill
    -- predicates compare against. Off-buff mult = 1.0 -> identical to v0.5.152.
    -- FC (outgoing) and Ethereal (target resist-reduction) stack multiplicatively.
    ctx.fc_amp_mult      = ctx.flame_cloak_active and (1 + FC_SPELL_AMP) or 1.0
    ctx.r_impact_eff     = impact * ctx.fc_amp_mult
    -- r_alone_kill requires 5% headroom (user-picked margin over exact): commit
    -- solo R only when the instant hit clearly kills, else fall to W-stun-Q-R.
    ctx.r_alone_kill     = impact > 0 and (ctx.eff_hp_magical * 1.05 <= ctx.r_impact_eff)
    -- v0.5.85: full W+Q+R magical burst. The kill model was R-only
    -- (r_alone_kill / wqr_undershoots), so the brain under-credited the combo:
    -- Dragon Slave + Light Strike Array add real magic damage that lands inside
    -- the same commit. All three are magical, so they compare against the same
    -- eff_hp_magical. combo_kill = the bare W+Q+R combo kills (no ethereal amp);
    -- the ether kill-confirm below amplifies combo_total_eff instead of r_total.
    ctx.q_dmg            = lina_q_damage()
    ctx.w_dmg            = lina_w_damage()
    ctx.combo_total      = ctx.r_impact + ctx.q_dmg + ctx.w_dmg
    ctx.combo_total_eff  = ctx.combo_total * ctx.fc_amp_mult
    ctx.combo_kill       = ctx.eff_hp_magical <= ctx.combo_total_eff

    ctx.r_range = cast_range_of(r, FALLBACK_RANGES.R)
    ctx.w_range = cast_range_of(w, FALLBACK_RANGES.W)
    ctx.q_range = cast_range_of(q, FALLBACK_RANGES.Q)
    ctx.in_r_range     = ctx.d <= ctx.r_range
    ctx.in_w_range     = ctx.d <= ctx.w_range
    ctx.in_q_range     = ctx.d <= ctx.q_range
    ctx.in_ether_range = ctx.d <= cast_range_of(ctx.ether, FALLBACK_RANGES.ETHEREAL)
    ctx.in_eul_range   = ctx.d <= cast_range_of(ctx.eul, FALLBACK_RANGES.EUL)

    ctx.atk_range    = (me and NPC.GetAttackRange) and (NPC.GetAttackRange(me) or 600) or 600
    ctx.kiting_us    = (target and Target.IsKitingUs and Target.IsKitingUs(target, me)) or false
    ctx.magic_immune = (target and NPC.HasState and NPC.HasState(target, MS.MODIFIER_STATE_MAGIC_IMMUNE)) or false
    ctx.linkens      = (target and Target.HasReadyLinkens and Target.HasReadyLinkens(target)) or false
    ctx.lotus        = (target and Target.HasReadyLotus and Target.HasReadyLotus(target)) or false
    return ctx
end
state.build_layer1_ctx = build_layer1_ctx

-- Alive real enemy heroes within the classify radius (Starter 1-2 vs TF 3+).
state.count_engaged_enemies = function()
    local me = state.self_npc
    if not me then return 0 end
    local list = Entity.GetHeroesInRadius(me, state.COMBO_CLASSIFY_RADIUS, Enum.TeamType.TEAM_ENEMY)
    if not list then return 0 end
    local n = 0
    for i = 1, #list do
        local e = list[i]
        if e and Target.IsAlive(e) and Target.NotIllusion(e) then n = n + 1 end
    end
    return n
end

----------------------------------------------- Layer 1 offense dispatch ------
-- Phase F increment 2-3 (v0.3.0): step scheduler + builders + the three
-- dispatchers + auto-R + R-abort. HOLD-only adaptive model (TAP stubbed). All
-- multi-step combos use delay_s deltas via pending_steps_tick (no same-tick
-- queue chains, COMBO_PATTERN L133). See COMBO_PATTERN.md for the archetypes.

-- Target-position prediction (v0.3.6: smoothed velocity via Geometry.PredictPos,
-- fed by SampleVelocities in OnUpdateEx; steadier than the old instantaneous
-- lead_target_pos, and guards blink/stationary/CC).
state.predict_target_pos = function(target, lead_s)
    return Geometry.PredictPos(target, lead_s)
        or (target and Entity.IsEntity(target) and Entity.GetAbsOrigin(target)) or nil
end
-- v0.5.47 Phase 1 (port of Sniper.lua L2466-2472 state.item_kv):
-- generic reusable wrapper for Ability.GetLevelSpecialValueFor with a
-- fallback. Used to read live KV special values off an ability or item
-- handle so Lina's numeric model tracks Valve's tuning instead of rotting
-- on hardcoded constants. A returned 0 counts as unresolved (legitimate
-- 0 values are vanishingly rare for the KV keys we read). Migration plan:
-- replace inline pcall(Ability.GetLevelSpecialValueFor, ...) call sites
-- with state.item_kv across subsequent releases (v0.5.48+).
state.item_kv = function(handle, key, fallback)
    if handle and Ability.GetLevelSpecialValueFor then
        local v = Ability.GetLevelSpecialValueFor(handle, key)
        if v and v ~= 0 then return v end
    end
    return fallback
end

-- v0.5.48 Phase 2: per-mod arrival-time computation. Consumes
-- ThreatData.THREAT_ARRIVAL_TIMING catalog (lib/threat_data.lua) to
-- derive (impact_t, impact_pos) for a threat. impact_t = "seconds from
-- now until the threat actually lands on target". impact_pos = position
-- where defensive AoE saves should be aimed (target origin for arrival-
-- at-target threats; caster origin for channel-interrupt threats).
--
-- Returns nil for any threat without a catalog entry; callers MUST fall
-- back to legacy logic (v0.5.47.x stamped eta_speed + W_aim_at_caster_
-- mods allowlist). Catalog seeded with Bara / Tusk / PA / WD / Lion /
-- Sniper Assassinate / Lina Laguna; future expansion in v0.5.48+.
--
-- Why catalog over stamped: user spec from v0.5.47.2 demo discussion --
-- "We have to calculate W usage correctly when the skills is about to
-- hit lina, get the right information from liquipedia. The skill takes
-- 1.12s to land. For skills that charge, they have a charge timing and
-- this should be on threat data." The catalog encodes the liquipedia-
-- confirmed timing data per-mod; the compute helper reads live KV via
-- state.item_kv when the entry asks for it.
-- v0.5.74 lib-first lift: body moved to ThreatData.ComputeArrivalTime
-- (lib/threat_data.lua). state.* alias retained for the 3 in-tree call
-- sites (W .fire body, armed_chain_peek W gate, W gate's hp/speed read).
-- state.item_kv passed as the kv_lookup callback so the kv_or_fallback
-- speed_source (Tusk Snowball only today) keeps working.
-- v0.5.114: seconds since the Bara charge began (the bara_charge armed
-- entry is created on modifier create = charge start and carries armed_t).
-- nil when no live charge from this caster -- the lib then assumes the
-- full wind-up remains (the safe, fires-earlier direction).
state.bara_charge_elapsed = function(caster)
    local e = state.armed_threats and state.armed_threats.bara_charge
    if e and e.armed_t and (not caster or e.caster == caster) then
        return now() - e.armed_t
    end
    return nil
end

state.compute_arrival_time = function(threat_mod, caster, target, modifier_handle)
    -- v0.5.114: thread the ramp clock for the precise charge model.
    local opts
    if threat_mod == "modifier_spirit_breaker_charge_of_darkness" then
        local el = state.bara_charge_elapsed(caster)
        if el then opts = { elapsed_s = el } end
    end
    return TD.ComputeArrivalTime(threat_mod, caster, target, modifier_handle, state.item_kv, opts)
end

-- v0.5.55: state.compute_save_fire_window + state.compute_w_fire_window
-- removed -- no consumer left after the v0.5.51 chain-walker catalog
-- gate was deleted. The math lives in Defense.ComputeSaveFireWindow
-- (lib/defense.lua) which W's .fire body calls directly with literal
-- save_entry parameters.

-- Q (Dragon Slave) is a traveling line wave (KV dragon_slave_speed = 1200 u/s,
-- cast point 0.35). The wave reaches a target at distance d at cast_point +
-- d/speed seconds, so the lead must be distance-aware (a fixed lead undershoots
-- moving targets at range). Aim the predicted position; the line auto-extends.
state.predict_lead_path = function(target)
    local q = ability(A.Q)
    local cp, speed = 0.35, 1200
    if q and Ability.GetCastPoint then
        local ok, v = pcall(Ability.GetCastPoint, q, true)
        if ok and type(v) == "number" then cp = v end
    end
    if q and Ability.GetLevelSpecialValueFor then
        local ok, v = pcall(Ability.GetLevelSpecialValueFor, q, "dragon_slave_speed")
        if ok and type(v) == "number" and v > 0 then speed = v end
    end
    local d = dist_to(target)
    if d == math.huge then d = 0 end
    return state.predict_target_pos(target, cp + d / speed)
end
state.predict_cyclone_exit = function(target) -- cyclone holds them in place
    return (target and Entity.IsEntity(target) and Entity.GetAbsOrigin(target)) or nil
end

-- W (Light Strike Array) aim: max-coverage AoE center anchored on `target` (it
-- is always caught) that also catches a 2nd nearby enemy when possible - "one,
-- ideally two" for the extra Fiery Soul stack + AoE damage. Predicted positions
-- at W's 0.95s press-to-stun (cast 0.45 + delay 0.5); AoE 250 (KV). Magic-immune
-- enemies are excluded (W can't affect them). Falls back to the single-target
-- predicted position.
local W_AOE, W_LEAD = 250, 0.95
-- Q (Dragon Slave) line params for the TF line-aim (KV: width 275->200 so
-- half ~110; length 1075; representative lead = cast 0.35 + ~half-length travel
-- at 1200 u/s).
local Q_HALF_WIDTH, Q_LENGTH, Q_LINE_LEAD = 110, 1075, 0.8
-- v0.5.79 feature C / v0.5.154: Ethereal Blade magic-damage amplification used
-- by the ether_wqr kill-confirm. Ether Blast reduces the target's magic
-- resistance by 30% (Liquipedia 7.41d; nerfed from 40% in 7.40), and since Dota
-- magic resistance stacks multiplicatively a -30% reduction is exactly a x1.30
-- multiplier on magic damage taken -> amp = 0.30. The IMP-A10 gate's "-30 MR
-- amp" comments already tracked this; only the constant was stale at 0.40.
-- The kill-confirm multiplies combo_total_eff by (1 + this) and compares to
-- eff_hp_magical (which already bakes in the target's base resistance, so the
-- x1.30 Ethereal factor is exact). Tunable here if the live value changes; the
-- toggle (default ON) and the wqr fall-through bound any error to "engage
-- without ethereal".
-- v0.5.153 sibling: FC_SPELL_AMP (defined up by the readiness hooks) credits
-- Flame Cloak's +35% OUTGOING amp; it stacks multiplicatively with this.
local ETHER_MAGIC_AMP = 0.30

-- v0.5.80 feature D: power-spike save chips for the live Diagnostics HUD.
-- The at-a-glance "am I safe right now" set: high-impact defensive saves +
-- the displacement chain heads. Only items Lina actually owns render (compact
-- line); each shows "rdy" or remaining cooldown in seconds. Menu-label HUD
-- (1Hz refresh), NOT an OnDraw overlay.
local POWER_SPIKE_SAVES = {
    { name = "item_black_king_bar", short = "BKB" },
    { name = "item_lotus_orb",      short = "Lotus" },
    { name = "item_aeon_disk",      short = "Aeon" },
    { name = "item_ethereal_blade", short = "Ether" },
    { name = "item_wind_waker",     short = "WW" },
    { name = "item_cyclone",        short = "Eul" },
    { name = "item_glimmer_cape",   short = "Glimmer" },
    { name = "item_hurricane_pike", short = "Pike" },
    { name = "item_force_staff",    short = "Force" },
}

-- Alive, non-illusion, non-magic-immune enemy heroes within `radius` of a point.
-- Shared by w_aim and the teamfight cluster / Q-poke aim - only enemies W/Q can
-- actually affect (magic-immune takes no stun/damage and gives no Fiery Soul).
local function aoe_enemy_units(center, radius)
    local me = state.self_npc
    if not center or not me then return {} end
    local near = Heroes.InRadius(center, radius, Entity.GetTeamNum(me), Enum.TeamType.TEAM_ENEMY)
    local units = {}
    if near then
        for i = 1, #near do
            local e = near[i]
            if e and Target.IsAlive(e) and Target.NotIllusion(e)
               and not (NPC.HasState and NPC.HasState(e, MS.MODIFIER_STATE_MAGIC_IMMUNE)) then
                units[#units + 1] = e
            end
        end
    end
    return units
end

state.w_aim = function(target)
    local me = state.self_npc
    local tp = target and Entity.IsEntity(target) and Entity.GetAbsOrigin(target)
    if not tp or not me then return state.predict_target_pos(target, W_LEAD) end
    local units = aoe_enemy_units(tp, 2 * W_AOE)
    if #units == 0 then units = { target } end
    -- v0.5.175: pass W_AOE - K.W_COVER_MARGIN so the cover-both center commits a 2nd
    -- enemy only when it sits MARGIN inside the real 250 AoE = a GUARANTEED double
    -- over the 0.95s lead (the lib's midpoint placement puts each at <= radius-margin).
    -- Past ~2*(250-25)=~450u apart the far enemy is dropped and W single-targets the
    -- priority. The real W still casts the full 250 AoE, so a committed pair has >=
    -- MARGIN to spare. Fixes the v<=0.5.174 rim placement that dropped a catchable
    -- 2nd enemy at the boundary (demo: d=482 -> covered=1).
    local c, n = Geometry.BestAoeCenter(units, W_AOE - K.W_COVER_MARGIN, W_LEAD, target)
    -- Throttled cover-both diagnostic (level 2 -> shows at demo verbosity >= 2; zero
    -- cost at default play). sep = nearest 2nd enemy's current distance to the target.
    if v_level() >= 2 and (now() - (state.w_aim_diag_t or 0)) >= 0.2 then
        state.w_aim_diag_t = now()
        local sep
        for i = 1, #units do
            local u = units[i]
            if u ~= target and Entity.IsEntity(u) then
                local up = Entity.GetAbsOrigin(u)
                local dcur = (up and tp) and up:Distance2D(tp) or nil
                if dcur and (not sep or dcur < sep) then sep = dcur end
            end
        end
        tlog(2, "w_aim", { units = string.format("%d", #units),
            covered = string.format("%d", n or 0),
            sep = sep and string.format("%.0f", sep) or "na" })
    end
    return c or state.predict_target_pos(target, W_LEAD)
end

-- TF aim, LIVE - mirrors starter w_aim so the placement is re-clustered and
-- re-predicted on EVERY (re)issue (v0.4.6 made steps a sequential re-issue chain;
-- a frozen dispatch-time placement goes stale as the pile moves). r_target (or
-- nil for sustain) is the must_cover anchor so the W stun + R snipe coincide;
-- falls back to the live cluster center, then to the r_target position. If the
-- r_target dies, BestAoeCenter drops the anchor and centers on the live pile -
-- this is the same "survive the R target's death" intent the captured-Vector
-- version had, but tracking the CURRENT pile instead of a stale point.
state.tf_w_aim = function(r_target)
    local me = state.self_npc
    if not me then return nil end
    local center = state.enemy_cluster_center(me)
    if not center then
        -- v0.5.95.3 BUG-W-SELF fix: when the cluster evaporates mid-re-issue
        -- (scatter / BKB / invuln / the v0.5.24 per-tick memo returning nil for a
        -- frame) prefer the live r_target's position (still a valid enemy aim);
        -- if it too is gone, return NIL to DROP the cast. The pre-v0.5.95.3 code
        -- returned NPCLib.origin(me) claiming "self origin lets the range gate
        -- abort" -- WRONG: there is no brain-side range gate and a self-aim at
        -- distance 0 is ALWAYS in engine range, so W fired on Lina herself. nil is
        -- now caught by the CAST_POSITION nil-pos guard in issue_cast_position
        -- (emits combo_aim_drop); the step retries next frame and aborts via its
        -- no_land window if the cluster never returns.
        return (r_target and Entity.IsEntity(r_target) and Entity.GetAbsOrigin(r_target)) or nil
    end
    local units = aoe_enemy_units(center, 2 * W_AOE)
    if #units == 0 then return center end
    -- v0.5.2: NO must_cover (user clarification 2026-05-29: R locks to the
    -- finisher, W + Q hit the densest cluster). Previously passed r_target as
    -- must_cover, which forced BestAoeCenter to keep the snipe inside W_AOE -
    -- when the 2-group was >500u from the lowest-eff-HP target (DEMO 3:
    -- cluster=1 logs), W collapsed onto the solo snipe. Decoupling W matches
    -- v0.4.9's same fix for Q. Risk: W may not stun the snipe when cluster is
    -- far from finisher; acceptable because R is press-to-damage (0.55s, no
    -- stun dependency).
    return Geometry.BestAoeCenter(units, W_AOE, W_LEAD, nil) or center
end
state.tf_q_aim = function(r_target)
    local me = state.self_npc
    if not me then return nil end
    local me_pos = NPCLib.origin(me)
    local center = state.enemy_cluster_center(me)
    if not center then
        -- v0.5.95.3 BUG-Q-CREEPS fix: see tf_w_aim. The me_pos (self) fallback
        -- made Dragon Slave fire a degenerate zero-direction line from Lina that
        -- raked nearby creeps. Prefer the live r_target enemy position; else NIL
        -- to DROP (caught by the issue_cast_position nil-pos guard -> combo_aim_drop).
        return (r_target and Entity.IsEntity(r_target) and Entity.GetAbsOrigin(r_target)) or nil
    end
    if not me_pos then return center end
    local units = aoe_enemy_units(center, 2 * W_AOE)
    if #units == 0 then return center end
    -- NO must_cover: Q is the damage/slow/stacks line and must hit the MOST
    -- enemies; passing r_target would force the line through the snipe (geometry.md
    -- on_line constraint) and lock Q onto the main target. W (anchored on r_target)
    -- is the stun and R is the snipe; Q maximizes coverage independently.
    return Geometry.BestLineAim(units, me_pos, Q_HALF_WIDTH, Q_LENGTH, Q_LINE_LEAD, nil) or center
end

-- Live mana cost of an ability / item (KV-accurate, Scepter/level aware).
local function ability_mana(name)
    local a = ability(name)
    return (a and Ability.GetManaCost and (Ability.GetManaCost(a) or 0)) or 0
end
local function item_mana(itname)
    local it = NPCLib.item(state.self_npc, itname)
    return (it and Ability.GetManaCost and (Ability.GetManaCost(it) or 0)) or 0
end

-- R should not be wasted on a target that will eat it: live re-check at fire.
-- v0.5.35 task Nyx-carapace: iterates the lib SPELL_DEFLECT_MODIFIERS set
-- against the target's active modifiers. Returns true if ANY deflect modifier
-- is active. Called from r_target_blocked (starter R archetypes) and from
-- build_lina_tf_steps.r_ok (TF R). For now the set holds only Carapace; new
-- entries land in lib/threat_data.lua's SPELL_DEFLECT_MODIFIERS after VPK
-- verification per lesson 13.
local function target_has_spell_deflect(t)
    if not (t and NPC.HasModifier) then return false end
    for mod, _ in pairs(SPELL_DEFLECT_MODIFIERS) do
        if NPC.HasModifier(t, mod) then return true end
    end
    return false
end

local function r_target_blocked(c)
    local t = c.target
    if not (t and Entity.IsEntity(t) and Target.IsAlive(t)) then return true end
    if NPC.HasState(t, MS.MODIFIER_STATE_MAGIC_IMMUNE) then return true end
    if Target.HasReadyLinkens and Target.HasReadyLinkens(t) then return true end
    if Target.HasReadyLotus and Target.HasReadyLotus(t) then return true end
    -- v0.5.35 task Nyx-carapace: refuse R against any active spell-deflect
    -- modifier (Nyx Spiked Carapace = 100% spell damage reflect for 4s).
    if target_has_spell_deflect(t) then return true end
    -- v0.5.152: refuse R on a target that cannot be killed right now (Dazzle Shallow
    -- Grave / Oracle False Promise / WK Reincarnation ready) -- the kill will not stick.
    if Target.IsUnkillableNow and Target.IsUnkillableNow(t) then return true end
    return false
end

-- ============================ FC TTK offense gate (v0.5.156) ============================
-- Work-queue #6, FC value-arbiter OFFENSE pillar. Replaces the flip-test
-- (state.fc_offense_value) on the 1-2 enemy STARTER path with a time-to-kill
-- simulation: with FC, can Lina kill this target (instant W+Q+R burst, then
-- Fiery-Soul autos + one W/Q re-cast, minus regen) before it escapes / pops a
-- save, and does FC SECURE or meaningfully ACCELERATE that kill? Spec:
-- Lina/FLAME_CLOAK_TTK_DESIGN.md. TF (3+) keeps state.fc_offense_value (the AoE
-- flip) at the tf_opener + tf_burst sites. Defined HERE (after target_has_spell_
-- deflect + r_target_blocked, before the openers) so those locals resolve at
-- DEFINITION time -- the v0.5.92/95.1 forward-reference lesson.

-- Lina's avg NOMINAL auto damage (pre-mitigation). (GetTrueDamage +
-- GetTrueMaximumDamage)/2 is the canonical pair (NPC.GetAttackDamage does not
-- exist; the attacker_can_kill_self precedent). Mockable seam.
state.lina_auto_avg = function()
    local me = state.self_npc
    if not (me and NPC.GetTrueDamage and NPC.GetTrueMaximumDamage) then return 0 end
    local ok1, dmin = pcall(NPC.GetTrueDamage, me)
    local ok2, dmax = pcall(NPC.GetTrueMaximumDamage, me)
    if ok1 and ok2 and type(dmin) == "number" and type(dmax) == "number" and dmax > 0 then
        return (dmin + dmax) / 2
    end
    return 0
end

-- Pure: attack interval (s) at a Fiery Soul stack count, from the FS-free base
-- multiplier + per-stack multiplier. as = base + stacks*per_mult, capped at the
-- 700-AS multiplier (7.0); interval = BAT/as, clamped [0.1, BAT]. Used by both the
-- starting-interval seam and the dynamic sim (which re-calls it as stacks climb).
local function fs_interval(base_as, per_mult, stacks)
    local as = math.min((base_as or 1.0) + (stacks or 0) * (per_mult or 0), 7.0)
    if as <= 0 then return K.LINA_BASE_ATTACK_TIME end
    return math.min(math.max(K.LINA_BASE_ATTACK_TIME / as, 0.1), K.LINA_BASE_ATTACK_TIME)
end

-- Strip the live Fiery Soul stacks out of NPC.GetAttackSpeed to a FS-free base
-- multiplier (base + items) + the per-stack multiplier + the live stack count.
-- Returns (base_as, per_mult, cur). The single seam touching the live AS / stack
-- APIs (v0.5.156.1 contract: GetAttackSpeed = IAS multiplier (100+bonus)/100
-- INCLUDING current FS; a FS stack is `per` AS POINTS, KV {8,16,24,32}, = per/100
-- on the multiplier). fs_interval re-adds the SCENARIO stacks on top. Unreadable
-- AS -> base 1.0 / per_mult 0 (base BAT cadence).
state.lina_fs_model = function()
    local me = state.self_npc
    local as
    if me and NPC.GetAttackSpeed then
        local ok, v = pcall(NPC.GetAttackSpeed, me)
        if ok and type(v) == "number" and v > 0 then as = v end
    end
    local fs  = state.compute_fs_state and state.compute_fs_state(me)
    local cur = (fs and fs.stacks) or 0
    local e   = ability(A.E)
    local per = (e and Ability.GetLevel(e) > 0
                 and state.item_kv(e, "fiery_soul_attack_speed_bonus", 0)) or 0
    local per_mult = per / 100
    if not as then return 1.0, per_mult, cur end                -- AS unreadable -> base cadence
    return math.max(as - cur * per_mult, 0.1), per_mult, cur    -- FS-free base (base + items)
end

-- Starting attack interval for the scenario (v0.5.156.2 stack-aware; kept as a
-- convenience + for the fc_offense_ttk i_off/i_fc display). no-FC starts at
-- min(cur+3, 7) stacks (the WQR combo's own +3, one per spell cast); FC sets 7.
-- The sim (fc_ttk_sim) climbs from here as W/Q re-casts add stacks (v0.5.156.3).
-- CAVEAT: if FC is ALREADY active at eval (cur is FC's 7 -- e.g. a manual pre-cast),
-- the no-FC counterfactual collapses to 7 (pre-FC stacks unknowable); the gate
-- decides with FC NOT active, so cur is the natural pre-combo count there.
state.lina_attack_interval = function(with_fc)
    local base_as, per_mult, cur = state.lina_fs_model()
    local stacks = with_fc and 7 or math.min(cur + 3, 7)
    return fs_interval(base_as, per_mult, stacks)
end

-- True if the target is magic-immune via BKB (canonical modifier, VPK-verified).
-- The sim zeroes magical damage during BKB (autos still land) + the window
-- collapses to base_reaction (the W stun won't land). Mockable seam.
state.lina_target_has_bkb = function(target)
    return (target and NPC.HasModifier
            and NPC.HasModifier(target, "modifier_black_king_bar_immune")) and true or false
end

-- PURE time-to-kill simulation (NO API calls -> offline-verifiable; FCTTK01 tests
-- it directly with hand-built inputs). Drains the target's RAW HP: t=0 instant
-- W+Q+R magical burst, then Fiery-Soul autos (physical) + one W and one Q re-cast
-- (magical) at their base CDs, minus passive regen each step.
-- DYNAMIC Fiery Soul stacks (v0.5.156.3): the auto cadence starts at stacks_off
-- (no FC = min(cur+3,7), the combo's own +3) or stacks_fc (FC = 7), and EACH W/Q
-- re-cast grants +1 stack (cap 7) -> the interval is recomputed from base_as +
-- stacks*per_mult. So without FC the autos speed up as the recasts land (FC starts
-- capped at 7, so its cadence is constant). This is what lets us value FC at any
-- stack state (incl. mid-combo), not just a fixed snapshot.
-- Magical packet = nominal * magic_mult * (FC amp while t < FC_DURATION); bkb zeroes
-- ALL magical (autos still land). Returns TTK seconds (0 if burst one-shots) or huge.
state.fc_ttk_sim = function(inputs, with_fc)
    if not inputs then return math.huge end
    local amp      = with_fc and (1 + FC_SPELL_AMP) or 1
    local mm       = inputs.bkb and 0 or (inputs.magic_mult or 1)
    local pm       = inputs.phys_mult or 1
    local base_as  = inputs.base_as or 1.0
    local per_mult = inputs.per_mult or 0
    local stacks   = with_fc and (inputs.stacks_fc or 7) or (inputs.stacks_off or 0)
    local interval = fs_interval(base_as, per_mult, stacks)
    local hp = inputs.hp or math.huge
    -- t=0 burst (within the FC window -> amped when with_fc)
    hp = hp - (inputs.burst or 0) * mm * amp
    if hp <= 0 then return 0 end
    local next_auto = interval        -- first auto one interval in (she casts through the open)
    local w_done, q_done = false, false
    local t = K.FC_TTK_DT
    while t <= K.FC_TTK_HORIZON + 1e-9 do
        while next_auto <= t + 1e-9 do
            hp = hp - (inputs.auto_avg or 0) * pm
            next_auto = next_auto + interval
        end
        if (not w_done) and t + 1e-9 >= (inputs.w_recast_t or math.huge) then
            local a = ((inputs.w_recast_t or math.huge) < K.FC_DURATION) and amp or 1
            hp = hp - (inputs.w_dmg or 0) * mm * a
            stacks = math.min(stacks + 1, 7)              -- the re-cast grants a Fiery Soul stack
            interval = fs_interval(base_as, per_mult, stacks)
            w_done = true
        end
        if (not q_done) and t + 1e-9 >= (inputs.q_recast_t or math.huge) then
            local a = ((inputs.q_recast_t or math.huge) < K.FC_DURATION) and amp or 1
            hp = hp - (inputs.q_dmg or 0) * mm * a
            stacks = math.min(stacks + 1, 7)
            interval = fs_interval(base_as, per_mult, stacks)
            q_done = true
        end
        if hp <= 0 then return t end
        hp = hp + (inputs.regen or 0) * K.FC_TTK_DT   -- passive regen over this dt
        t = t + K.FC_TTK_DT
    end
    return math.huge
end

-- Gather the raw, item-aware sim inputs ONCE (so fc_offense_ttk runs the pure sim
-- twice without re-reading APIs). All numeric reads pcall-guarded with conservative
-- fallbacks. nil if target gone. burst/w_dmg/q_dmg are NOMINAL magical (ctx already
-- summed them); the sim applies the resist mult + FC amp. W/Q re-cast at their BASE
-- cooldown from t=0 (they fire in the burst), KV arrays keyed on live level.
state.fc_ttk_inputs = function(ctx, target)
    if not (ctx and target and Entity.IsEntity(target) and Target.IsAlive(target)) then return nil end
    local hp = (Entity.GetHealth and Entity.GetHealth(target)) or math.huge
    -- magical fraction-through: GetMagicalArmorDamageMultiplier (e.g. 0.75 = 25% MR);
    -- fallback (1 - GetMagicalResist); fallback 1.0 (full damage = slight over-fire, accepted).
    local mm = 1.0
    if NPC.GetMagicalArmorDamageMultiplier then
        local ok, v = pcall(NPC.GetMagicalArmorDamageMultiplier, target)
        if ok and type(v) == "number" and v > 0 then mm = v
        elseif NPC.GetMagicalResist then
            local ok2, r = pcall(NPC.GetMagicalResist, target)
            if ok2 and type(r) == "number" then mm = math.max(0, 1 - r) end
        end
    end
    local pm = 1.0
    if NPC.GetArmorDamageMultiplier then
        local ok, v = pcall(NPC.GetArmorDamageMultiplier, target)
        if ok and type(v) == "number" and v > 0 then pm = v end
    end
    local regen = 0
    if NPC.CalculateHealthRegen then
        local ok, v = pcall(NPC.CalculateHealthRegen, target)
        if ok and type(v) == "number" and v > 0 then regen = v end
    end
    -- W/Q base cooldown (s) per live level (KV light_strike_array {13,11,9,7},
    -- dragon_slave {11,10,9,8}); not leveled -> never re-casts (math.huge).
    local w_ab, q_ab = ability(A.W), ability(A.Q)
    local w_lvl = (w_ab and Ability.GetLevel(w_ab)) or 0
    local q_lvl = (q_ab and Ability.GetLevel(q_ab)) or 0
    -- Fiery Soul attack-speed model + the per-scenario starting stacks: no-FC the
    -- WQR combo grants +3 (min(cur+3,7)); FC sets 7. The sim climbs from there.
    local base_as, per_mult, cur = state.lina_fs_model()
    local stacks_off = math.min(cur + 3, 7)
    return {
        hp           = hp,
        magic_mult   = mm,
        phys_mult    = pm,
        regen        = regen,
        burst        = ctx.combo_total or 0,   -- nominal W+Q+R magical
        w_dmg        = ctx.w_dmg or 0,
        q_dmg        = ctx.q_dmg or 0,
        auto_avg     = state.lina_auto_avg(),
        base_as      = base_as,
        per_mult     = per_mult,
        stacks_off   = stacks_off,
        stacks_fc    = 7,
        interval_off = fs_interval(base_as, per_mult, stacks_off),  -- starting cadence (log/display)
        interval_fc  = fs_interval(base_as, per_mult, 7),
        w_recast_t   = ({13, 11, 9, 7})[w_lvl] or math.huge,
        q_recast_t   = ({11, 10, 9, 8})[q_lvl] or math.huge,
        bkb          = state.lina_target_has_bkb(target),
    }
end

-- Convenience wrapper named in the design (gather + sim). fc_offense_ttk gathers
-- once + sims twice for efficiency; this is the one-shot form for callers/tests.
state.fc_ttk = function(ctx, target, with_fc)
    return state.fc_ttk_sim(state.fc_ttk_inputs(ctx, target), with_fc)
end

-- Escape/negate window: how long the target stays reliably killable. v0.5.157
-- RATIONALIZED: a committed equal-speed target CANNOT outrun a chasing Lina (net
-- separation ~0 -> no finite walk-out escape), so the GENERIC window = the sim
-- horizon (the kill stays reliable for ~the whole fight). The old W-stun+reaction
-- (~3.2s) modeled the wrong thing (target teleporting away at stun-end) and almost
-- never fired. BKB is the exception: the W stun won't land (magic immune) AND FC's
-- spell amp does nothing, so use the short base_reaction window -> FC refuses vs
-- BKB. Mockable seam (FCTTK02 mocks it). PHASED: curated per-hero INSTANT escapes
-- (ready blink/Force/Eul/save) will return W_stun+reaction or shorter here later.
state.fc_offense_window = function(inputs)
    if inputs and inputs.bkb then return K.FC_TTK_BASE_REACTION end
    return K.FC_TTK_HORIZON
end

-- The OFFENSE-pillar FC trigger for the 1-2 enemy starter path (replaces the
-- starter want_fc's fc_offense_value flip-gate). Fires FC iff it SECURES (the
-- kill misses the window without FC) or meaningfully ACCELERATES it. Refuses on
-- un-killable / spell-deflect / ready Lotus, or when FC can't secure even amped.
-- Folds the removed v0.5.155.1 fc_offense_gate diagnostic into one fc_offense_ttk
-- log (ttk_off / ttk_fc / window / decision + the derived interval for AS tuning).
state.fc_offense_ttk = function(ctx, target)
    if not (ctx and target) then return false end
    if (Target.IsUnkillableNow and Target.IsUnkillableNow(target))
       or target_has_spell_deflect(target)
       or (Target.HasReadyLotus and Target.HasReadyLotus(target)) then
        tlog(1, "fc_offense_ttk", { target = uname(target), decision = "refuse_unkillable" })
        return false
    end
    local inputs = state.fc_ttk_inputs(ctx, target)
    if not inputs then return false end
    local window  = state.fc_offense_window(inputs)
    local ttk_off = state.fc_ttk_sim(inputs, false)
    local ttk_fc  = state.fc_ttk_sim(inputs, true)
    local decision
    if ttk_fc > window then
        decision = "refuse_no_secure"
    elseif ttk_off > window then
        decision = "secure"
    elseif (ttk_off - ttk_fc) >= math.max(K.FC_TTK_ACCEL_ABS, K.FC_TTK_ACCEL_FRAC * ttk_off) then
        decision = "accelerate"
    else
        decision = "hold"
    end
    tlog(1, "fc_offense_ttk", {
        target   = uname(target),
        decision = decision,
        ttk_off  = (ttk_off == math.huge) and "inf" or string.format("%.2f", ttk_off),
        ttk_fc   = (ttk_fc  == math.huge) and "inf" or string.format("%.2f", ttk_fc),
        window   = string.format("%.2f", window),
        bkb      = inputs.bkb and "y" or "n",
        fc_ready = (ctx and ctx.flame_cloak_ready) and "y" or "n",
        i_off    = string.format("%.2f", inputs.interval_off or 0),
        i_fc     = string.format("%.2f", inputs.interval_fc or 0),
        auto     = string.format("%.0f", inputs.auto_avg or 0),
        regen    = string.format("%.1f", inputs.regen or 0),
        hp       = string.format("%.0f", inputs.hp or 0),
        burst    = string.format("%.0f", inputs.burst or 0),
        mm       = string.format("%.2f", inputs.magic_mult or 0),
        pm       = string.format("%.2f", inputs.phys_mult or 0),
        fs       = string.format("%d", (state.compute_fs_state and state.compute_fs_state(state.self_npc) or {}).stacks or 0),
        s_off    = string.format("%d", inputs.stacks_off or 0),
    })
    return decision == "secure" or decision == "accelerate"
end

-- ===================== FC defense reserve (v0.5.158, Phase A1) =====================
-- FLAME_CLOAK_TF_ARBITER_DESIGN.md Phase A1. FC's +35% MR softens MAGICAL damage
-- only, so a non-magical threat raises NO FC defense claim. Hybrid detection:
-- reactive (the largest armed MAGICAL threat) + a cheap proactive band (Lina low +
-- focused). Matched item-coverage releases the claim. The grader is PURE
-- (offline-testable); the claim wrapper gathers live inputs. state.* indirection
-- lets SAVE_FIRE / the openers (defined earlier) call these at runtime.

-- Severity-derived incoming D when LINA_EXPECTED_DAMAGE has no entry (v0.5.72
-- pattern). D is incoming-to-Lina, so it scales off Lina's max HP.
local function fc_severity_D(sev, hpmax)
    if sev == "lethal" then return hpmax end
    if sev == "high"   then return 0.70 * hpmax end
    if sev == "medium" then return 0.45 * hpmax end
    if sev == "low"    then return 0.15 * hpmax end
    return 0
end

-- Mockable: is a defensive item owned + off cooldown (for matched coverage).
state.lina_save_ready = function(name)
    return (state.self_npc and NPCLib.item_ready
            and NPCLib.item_ready(state.self_npc, name)) and true or false
end

-- PURE grade + matched coverage (offline-testable; FCDEF01/02). D = incoming magic
-- damage; hp/hpmax = Lina. pierces=true means the threat pierces spell immunity
-- (BKB does NOT cover it). sustained=true = a multi-source focus (only BKB covers);
-- false = a single burst (any dodge/immunity/block covers). save_ready(name) is the
-- item-readiness predicate (injected so tests mock it). Returns "A" / "B" / "none".
state.fc_defense_grade = function(hp, hpmax, D, pierces, sustained, save_ready, last_resort)
    if not (hp and hpmax and D) or hp <= 0 or hpmax <= 0 or D <= 0 then return "none" end
    local tier
    if hp <= D and D < hp / K.FC_DEF_MR_MULT then
        tier = "A"
    elseif (K.FC_DEF_TIER_B_FLOOR * hp) <= D and D < hp then
        tier = "B"
    elseif last_resort and D >= (K.FC_DEF_TIER_B_FLOOR * hp) then
        -- v0.5.158.4: LAST-RESORT (the save chain reached FC = nothing else is
        -- available). Fire FC to MITIGATE a heavy/lethal+ magical hit even when FC
        -- alone cannot fully save (35% MR still cuts it; a zone DoT like Mystic Flare
        -- is reduced every tick). The strict "unsurvivable -> none" ceiling is only
        -- for proactive use (do not pre-burn FC on a hit it cannot survive).
        tier = "B"
    else
        return "none"   -- poke (D < 0.6*HP), or proactive and D >= HP/0.65 unsurvivable
    end
    save_ready = save_ready or function() return false end
    local bkb = (not pierces) and save_ready("item_black_king_bar")
    if sustained then
        if bkb then return "none" end   -- only BKB covers a sustained focus
    else
        if bkb
           or save_ready("item_cyclone")     -- Eul
           or save_ready("item_wind_waker")  -- WW
           or save_ready("item_sphere")      -- Linkens
           or save_ready("item_lotus_orb")   -- Lotus
        then return "none" end
    end
    return tier
end

-- Live wrapper: gather hp / incoming-magic-D / pierce / the proactive band, then
-- grade with state.lina_save_ready. ctx is unused today (kept for signature
-- symmetry with the offense gate + future use). Returns "A" / "B" / "none".
state.fc_defense_claim = function(ctx, threat_mod, last_resort)
    local me = state.self_npc
    if not (me and Entity.IsAlive and Entity.IsAlive(me)) then return "none" end
    local hp    = (Entity.GetHealth and Entity.GetHealth(me)) or 0
    local hpmax = (Entity.GetMaxHealth and Entity.GetMaxHealth(me)) or 1
    if hp <= 0 or hpmax <= 0 then return "none" end

    -- (1) reactive: the largest armed MAGICAL threat (FC's MR softens it).
    local D, pierces = 0, false
    local D_mod, D_src                       -- v0.5.168.1 D4.2: which mod drove D + catalog|fallback (diag)
    for _key, e in pairs(state.armed_threats) do
        local mod = e and e.threat_mod
        local p   = mod and TD.THREAT_PROFILE[TD.CanonicalMod(mod)]
        if p and p.school == "magical" then
            local d = LINA_EXPECTED_DAMAGE[mod]
                      or fc_severity_D(TD.SeverityOf(mod), hpmax)
            if d > D then
                D = d; pierces = p.pierces_spell_immunity and true or false
                D_mod, D_src = mod, (LINA_EXPECTED_DAMAGE[mod] and "catalog" or "fallback")
            end
        end
    end

    -- (1b) v0.5.158.3: also grade the threat currently being dispatched (the FC .fire's
    -- 3rd arg) -- a reactive magical threat (e.g. a delayed_aoe zone like Skywrath
    -- Mystic Flare) is NOT in armed_threats, so without this the reserve never sees it.
    -- FC then fires as the chain's last-resort tail for it (the delayed_aoe injection).
    if threat_mod then
        local p = TD.THREAT_PROFILE[TD.CanonicalMod(threat_mod)]
        if p and p.school == "magical" then
            local d = LINA_EXPECTED_DAMAGE[threat_mod]
                      or fc_severity_D(TD.SeverityOf(threat_mod), hpmax)
            if d > D then
                D = d; pierces = p.pierces_spell_immunity and true or false
                D_mod, D_src = threat_mod, (LINA_EXPECTED_DAMAGE[threat_mod] and "catalog" or "fallback")
            end
        end
    end

    -- (2) proactive band (sustained / multi-source focus): Lina low + >= N enemies
    -- near. A1 uses the nearby-enemy count as the design-sanctioned "magical dealer"
    -- fallback. Treated as lethal-incoming (Tier-A band) when it triggers.
    local armed_D = D    -- v0.5.158.5: magical armed/threat_mod D BEFORE the band -> source (a real armed magical threat fires now; a band-only A requires pressure)
    local sustained = false
    if (hp / hpmax) < K.FC_DEF_PROACTIVE_HP then
        local me_pos = NPCLib.origin(me)
        local near = me_pos and Heroes.InRadius(me_pos, K.FC_DEF_PROACTIVE_RADIUS,
                        Entity.GetTeamNum(me), Enum.TeamType.TEAM_ENEMY)
        local n = 0
        if near then
            for i = 1, #near do
                local h = near[i]
                if h and Target.IsAlive(h) and Target.NotIllusion(h) then n = n + 1 end
            end
        end
        if n >= K.FC_DEF_PROACTIVE_COUNT then
            sustained = true
            if D < hp then D = hp end   -- lethal-incoming pressure
        end
    end

    local result = state.fc_defense_grade(hp, hpmax, D, pierces, sustained, state.lina_save_ready, last_resort)
    -- v0.5.158.4 diag: on the reactive (.fire) path, log D / HP / result so a demo
    -- shows exactly why FC fired or held for a dispatched threat (e.g. Mystic Flare).
    if threat_mod then
        tlog(2, "fc_claim_dbg", {
            mod    = threat_mod,
            d      = string.format("%.0f", D),
            hp     = string.format("%.0f", hp),
            hpmax  = string.format("%.0f", hpmax),
            result = result,
            lr     = last_resort and "y" or "n",
        })
    end
    -- v0.5.168.1 D4.2 diag: which magical threat drove the FC-defense D, and whether
    -- the precise value came from LINA_EXPECTED_DAMAGE (catalog) or the coarse
    -- fc_severity_D (fallback). armed_D = the pre-proactive-band magical value (the
    -- catalog/fallback number). Throttled; level 2 (shows at demo verbosity >= 3).
    -- This is the read-out that confirms a magic-D catalog entry is actually used.
    if D_mod and (now() - (state.fc_def_d_log_t or 0)) >= 1.0 then
        tlog(2, "fc_defense_d", {
            mod = D_mod, d = string.format("%.0f", armed_D), src = D_src,
            hp = string.format("%.0f", hp), grade = result,
        })
        state.fc_def_d_log_t = now()
    end
    -- v0.5.158.5: source = what drives a firing-tier claim. "armed" = a real
    -- armed/dispatched magical threat at least Tier-B heavy on its own (fire now);
    -- "proactive" = only the proximity band (the tick requires real pressure to
    -- fire). The result VALUE is unchanged; this is an additive 2nd return.
    local source = nil
    if armed_D >= (K.FC_DEF_TIER_B_FLOOR * hp) then source = "armed"
    elseif sustained then source = "proactive" end
    return result, source
end

-- PURE (in-brain FCESC01): fly iff the safest spot is terrain-locked AND meaningfully safer
-- than the best walkable spot. info = Escape.SafestSpotNear's 3rd return.
state.fc_escape_worth_flying = function(best_score, info, margin)
    if not info then return false end
    return info.locked and ((info.walkable_score - best_score) >= (margin or 0))
end

-- Strict fallback (design D4): a ready Blink that reaches the dest pre-empts FC-escape. Returns
-- false (Blink does NOT cover -> FC may fire) when Blink is on CD, out of 1200 range, or
-- damage-broken (the item_saves blink builder skips on recent damage within 3s).
state.fc_escape_blink_covers = function(dest)
    local me = state.self_npc
    if not (me and dest) then return false end
    if not (state.lina_save_ready and state.lina_save_ready("item_blink")) then return false end
    local me_pos = NPCLib.origin(me)
    if not me_pos then return false end
    local dx, dy = me_pos.x - dest.x, me_pos.y - dest.y
    if (dx * dx + dy * dy) > (1200 * 1200) then return false end
    if Damage and Damage.GetRecentDamage then
        local ok, d = pcall(Damage.GetRecentDamage, me, 3.0)
        if ok and (d or 0) > 0 then return false end   -- blink damage-broken -> does not cover
    end
    return true
end

-- v0.5.16x Phase B (design 6.1): mobility claim. FC flies Lina out of a lethal gank when the
-- safest spot is terrain-locked (a walk cannot reach it) AND no ready movement save reaches it.
-- A DIFFERENT axis from fc_defense_claim (fires even vs PHYSICAL -- the flying, not the MR, is
-- the value). Returns (best_pos, info) | nil. Reuses fc_severity_D + LINA_EXPECTED_DAMAGE (the
-- module-locals fc_defense_claim uses; in scope here).
state.fc_escape_claim = function(ctx)
    -- v0.5.161.1: a 3rd return `diag` (additive; callers reading <= 2 values are unaffected)
    -- carries the sub-signal breakdown so fc_escape_tick can log a live fc_escape_eval.
    local diag = { lethal = false, worth_fly = false, blink_covers = false }
    local me = state.self_npc
    if not (me and Entity.IsAlive and Entity.IsAlive(me)) then return nil, nil, diag end
    local hp    = (Entity.GetHealth and Entity.GetHealth(me)) or 0
    local hpmax = (Entity.GetMaxHealth and Entity.GetMaxHealth(me)) or 1
    if hp <= 0 or hpmax <= 0 then return nil, nil, diag end
    diag.hp_frac = hp / hpmax
    -- (1) lethal-ish: gank imminent OR focused below the floor OR an armed lethal threat.
    local me_pos = NPCLib.origin(me)
    local lethal = false
    if me_pos and Escape.GankImminent and Escape.GankImminent(me, me_pos, K.FC_ESCAPE_GANK_ETA) then
        lethal = true; diag.gank = true
    elseif (hp / hpmax) < K.FC_ESCAPE_HP_FLOOR then
        lethal = true; diag.low_hp = true
    else
        for _k, e in pairs(state.armed_threats) do
            local mod = e and e.threat_mod
            if mod then
                local d = LINA_EXPECTED_DAMAGE[mod] or fc_severity_D(TD.SeverityOf(mod), hpmax)
                if d >= hp then lethal = true; diag.armed = true; break end
            end
        end
    end
    diag.lethal = lethal
    if not lethal then return nil, nil, diag end
    -- (2) terrain-locked-safer (design D1): best-overall is locked + margin-safer than walkable.
    local best_pos, best_score, info = Escape.SafestSpotNear(me, K.FC_ESCAPE_RADIUS)
    if info then
        diag.locked = info.locked and true or false
        diag.best_score, diag.walk_score = best_score, info.walkable_score
    end
    diag.worth_fly = state.fc_escape_worth_flying(best_score, info, K.FC_ESCAPE_SAFER_MARGIN) and true or false
    if not diag.worth_fly then return nil, nil, diag end
    -- (3) strict fallback (design D4): defer to a ready Blink that reaches the spot.
    diag.blink_covers = state.fc_escape_blink_covers(best_pos) and true or false
    if diag.blink_covers then return nil, nil, diag end
    return best_pos, info, diag
end

-- v0.5.158.5: real-pressure predicate for the PROACTIVE FC fire -- recent damage
-- (FC's MR is mitigating an in-progress hit) OR a committed attacker on self
-- (someone is diving Lina). Bare proximity to idle/kiting enemies is NOT pressure
-- (the v0.5.158.4 demo burned FC at <50% HP near 2 non-attacking enemies, armed=0).
-- The Tier-A claim still reserves FC from offense regardless; this only gates FIRE.
state.fc_under_pressure = function()
    local me = state.self_npc
    if not me then return false end
    if Damage and Damage.GetRecentDamage then
        local ok, d = pcall(Damage.GetRecentDamage, me, K.FC_DEF_PRESSURE_DMG_WINDOW)
        if ok and (d or 0) > 0 then return true end
    end
    local me_pos = NPCLib.origin(me)
    if me_pos then
        local near = Heroes.InRadius(me_pos, K.FC_DEF_PROACTIVE_RADIUS,
                        Entity.GetTeamNum(me), Enum.TeamType.TEAM_ENEMY)
        if near then
            for i = 1, #near do
                local h = near[i]
                if h and Target.IsAlive(h) and Target.NotIllusion(h)
                   and state.is_committed_attacker_on_self(h) then
                    return true
                end
            end
        end
    end
    return false
end

-- Per-tick proactive defensive FC. On a Tier-A reserve claim (uncovered lethal-
-- survivable magic), cast FC for its +35% MR via the dispatcher (single-spend lock
-- shared with offensive FC -> no double-cast). Replaces the <30% panic. Guards:
-- the fc_offensive_use menu, the 1.5s order-resolve throttle, FC ready + not
-- channelling, the fs_shard_window (never downgrade the 12-stack window), and mana.
state.fc_defense_tick = function()
    local me = state.self_npc
    if not me then return end
    if not self_alive_ok() then return end  -- v0.5.158.1: cannot cast FC while stunned/hexed/silenced/invulnerable (airborne) -> the engine drops the order
    if not (state.menu and state.menu.fc_offensive_use and state.menu.fc_offensive_use:Get()) then return end
    local claim, source = state.fc_defense_claim(nil)
    if claim ~= "A" then return end
    -- v0.5.158.5: a band-only (proactive) Tier-A fires FC ONLY under real pressure
    -- (recent damage OR a committed attacker). An armed/dispatched magical threat
    -- (source=="armed") still pre-fires. Bare proximity to idle enemies does not.
    if source ~= "armed" and not state.fc_under_pressure() then
        if (now() - (state.fc_def_skip_log_t or 0)) >= 1.0 then  -- v0.5.160 item-4: throttle (was per-tick spam at verbosity>=2)
            tlog(2, "fc_arbiter_defense_skip", { reason = "no_pressure" })
            state.fc_def_skip_log_t = now()
        end
        return
    end
    -- v0.5.160 A1-6: a PROACTIVE (band-only) Tier-A claim stands down when a
    -- full-negate save is ready -- WW/Eul (airborne dodge) or BKB. FC is the
    -- reserve for when those are DOWN; the reactive last-resort chain still fires
    -- FC if the dodge cannot cover. The source=="armed" path (a real armed magical
    -- nuke, e.g. Assassinate when low) is unchanged -- it pre-fires FC's MR as
    -- designed (A1-1, demo-validated). Fixes "FC used instead of WW".
    if source == "proactive" then
        local sr = state.lina_save_ready
        if sr and (sr("item_wind_waker") or sr("item_cyclone")
                   or sr("item_black_king_bar")) then
            if (now() - (state.fc_def_skip_log_t or 0)) >= 1.0 then  -- v0.5.160 item-4: throttle
                tlog(2, "fc_arbiter_defense_skip", { reason = "dodge_ready" })
                state.fc_def_skip_log_t = now()
            end
            return
        end
    end
    if (now() - (state.last_fc_dispatch_t or 0)) < 1.5 then return end
    local fc = ability("lina_flame_cloak")
    if not (fc and Ability.GetLevel(fc) > 0 and Ability.IsReady(fc)) then return end
    if NPC.IsChannellingAbility and NPC.IsChannellingAbility(me) then return end
    if not state.fc_def_probed then  -- v0.5.158.1 one-shot: confirm scepter/level/cd if FC still fails to cast
        tlog(1, "fc_defense_probe", {
            scepter = NPCLib.item(me, "item_ultimate_scepter") and "y" or "n",
            level   = tostring(Ability.GetLevel(fc) or -1),
            cd      = string.format("%.2f", (Ability.GetCooldown and Ability.GetCooldown(fc)) or -1),
            ready   = Ability.IsReady(fc) and "y" or "n",
        })
        state.fc_def_probed = true
    end
    local fs = state.compute_fs_state and state.compute_fs_state(me)
    if fs and fs.shard_window then return end
    local mana = (NPC.GetMana and NPC.GetMana(me)) or 0
    if mana < (ability_mana(A.FC) or 50) then return end
    tlog(1, "fc_arbiter_defense", { tier = "A", reason = "reserve_fire" })
    defense_dispatcher:Dispatch(
        "lina_fc_arbiter_defense",
        "lina_fc_arbiter_defense",
        me, me,
        function(intent, _mod, _caster)
            return issue_cast_notarget(intent, fc, "def")
        end,
        nil, "lina_flame_cloak", nil, nil,
        { fs_shard_window = (fs and fs.shard_window) or false })
    state.last_fc_dispatch_t = now()
end

-- v0.5.16x Phase B (design 6.1): per-tick FC ESCAPE. On a mobility claim (lethal gank +
-- terrain-locked safest spot + no ready Blink), cast FC for its FLYING and arm a flee move.
-- Mirrors fc_defense_tick's guards + the SHARED single-spend lock (last_fc_dispatch_t + the
-- dispatcher) so it never double-casts with the defensive paths. Survival OVERRIDES the FS
-- shard-window demotion (living > stacks): no shard guard, and fs_shard_window=false to the
-- dispatcher so FC is not demoted to chain tail.
state.fc_escape_tick = function()
    local me = state.self_npc
    state.fc_escape_active_cache = { t = now(), active = false }
    if not me then return end
    if not self_alive_ok() then return end
    -- v0.5.170: fc_escape hardcoded ON (menu-simplification); always evaluate the escape claim.
    local best_pos, info, diag = state.fc_escape_claim(nil)
    -- v0.5.161.1 Phase B diag: while a lethal-ish trigger is live, log the discriminator so a
    -- low-HP Lina near terrain shows the claim computing even when it correctly holds (throttled
    -- ~1s; verbosity >= 2). Lets the live path be validated without staging the full fire.
    if diag and diag.lethal and (now() - (state.fc_escape_eval_log_t or 0)) >= 1.0 then
        tlog(2, "fc_escape_eval", {
            gank = diag.gank and "y" or "n", low_hp = diag.low_hp and "y" or "n",
            armed = diag.armed and "y" or "n",
            hp = diag.hp_frac and string.format("%.2f", diag.hp_frac) or "?",
            locked = diag.locked and "y" or "n",
            best = diag.best_score and string.format("%.0f", diag.best_score) or "?",
            walk = diag.walk_score and string.format("%.0f", diag.walk_score) or "?",
            worth_fly = diag.worth_fly and "y" or "n",
            blink = diag.blink_covers and "y" or "n",
            fire = best_pos and "y" or "n",
        })
        state.fc_escape_eval_log_t = now()
    end
    if not best_pos then return end
    state.fc_escape_active_cache = { t = now(), active = true }   -- veto offense even if the spend throttles
    -- Coordinate with the defensive FC: if FC is ALREADY up (cast by fc_defense_tick or any path
    -- this window), do NOT recast -- arm the flee-move on top of the same buff so a defensive FC
    -- ALSO flees Lina across terrain. Without this the A1 proactive band (low HP + 2 enemies = a
    -- gank) casts FC first and shadows the escape (demo: 4 fire=y, 0 actual flee). Arm once.
    if NPC.HasModifier and NPC.HasModifier(me, "modifier_lina_flame_cloak") then
        if not state.pending_post_airborne_move then
            tlog(1, "fc_escape_ride", {
                x = string.format("%.0f", best_pos.x), y = string.format("%.0f", best_pos.y),
                locked = (info and info.locked) and "y" or "n",
            })
            state.arm_fc_escape_move(best_pos)
        end
        return
    end
    if (now() - (state.last_fc_dispatch_t or 0)) < 1.5 then return end
    local fc = ability("lina_flame_cloak")
    if not (fc and Ability.GetLevel(fc) > 0 and Ability.IsReady(fc)) then return end
    if NPC.IsChannellingAbility and NPC.IsChannellingAbility(me) then return end
    local mana = (NPC.GetMana and NPC.GetMana(me)) or 0
    if mana < (ability_mana(A.FC) or 50) then return end
    tlog(1, "fc_escape", {
        x = string.format("%.0f", best_pos.x), y = string.format("%.0f", best_pos.y),
        locked = (info and info.locked) and "y" or "n",
    })
    defense_dispatcher:Dispatch(
        "lina_fc_escape",
        "lina_fc_escape",
        me, me,
        function(intent, _mod, _caster)
            local ok = issue_cast_notarget(intent, fc, "def")
            if ok then state.arm_fc_escape_move(best_pos) end
            return ok
        end,
        nil, "lina_flame_cloak", nil, nil,
        { fs_shard_window = false })   -- survival overrides the shard demotion
    state.last_fc_dispatch_t = now()
end

-- Arm the FC-escape flee move on the existing post-airborne move slot + tick (the tick issues
-- MOVE once the FC modifier lands, then reissues with a SafestSpotNear recompute while FC is
-- up). FC is movable-throughout (WW-like): moves_during_airborne=true. Only if the slot is free
-- (do not clobber a WW/Eul post-move).
state.arm_fc_escape_move = function(dest)
    if state.pending_post_airborne_move then return end   -- slot busy -> skip
    state.pending_post_airborne_move = {
        dest = dest,
        modifier_name = "modifier_lina_flame_cloak",
        moves_during_airborne = true,
        deadline = now() + K.FC_DURATION,
        intent = "fc_escape",
        observed_airborne = false, last_reissue_t = 0, reissue_seq = 0,
        recompute_dest = function() return (Escape.SafestSpotNear(state.self_npc, K.FC_ESCAPE_RADIUS)) end,
    }
end

-- Cheap cached read for the offense veto (avoids re-running SafestSpotNear at each opener site).
state.fc_escape_active = function(_ctx)
    local c = state.fc_escape_active_cache
    return (c and c.active and (now() - c.t) < 0.25) and true or false
end

-- v0.5.163 C2: is the offense pillar demonstrably committing to `target`? Offense-recent (ANY W/Q/R combo
-- step stamped last_offense_target, R-independent) OR an FC opener fired this engagement, AND the A2 commit
-- gate. The whole non-autonomous boundary (extend, never initiate).
state.fc_chase_committing = function(ctx, target)
    if not target then return false end
    -- v0.5.163 C2: broad offense commitment (any W/Q/R step stamped last_offense_target), not R-only.
    local offense_recent = (state.last_offense_target == target)
        and ((now() - (state.last_offense_dispatch_t or 0)) < K.FC_CHASE_COMMIT_WINDOW)
    if not (offense_recent or state.fc_tf_opener_fired) then return false end
    return state.fc_offense_commit_ok and state.fc_offense_commit_ok(ctx, target) or false
end

-- Lina's live base move speed for catch-ETA (FC adds no speed; falls back to a constant).
state.fc_chase_move_speed = function()
    local me = state.self_npc
    local ms = me and NPC.GetMovementSpeed and NPC.GetMovementSpeed(me)
    return (ms and ms > 1) and ms or K.FC_CHASE_MS_FALLBACK
end

-- Gather enemy tower circles for the protection set. Towers.GetAll() is uczone v2.0 (newly documented +
-- uncertain) -> guarded: nil/empty/error -> {} (fog + out-of-reach carry escape-ETA without towers).
state.fc_chase_protection_circles = function()
    local me = state.self_npc
    if not (me and Towers and Towers.GetAll) then return {} end
    local ok, all = pcall(Towers.GetAll)
    if not (ok and type(all) == "table") then return {} end
    local my_team = Entity.GetTeamNum and Entity.GetTeamNum(me)
    local out = {}
    for _, tw in pairs(all) do
        if tw and Entity.IsAlive and Entity.IsAlive(tw)
           and (not my_team or (Entity.GetTeamNum(tw) ~= my_team)) then
            local p = Entity.GetAbsOrigin and Entity.GetAbsOrigin(tw)
            if p then out[#out + 1] = { pos = p, range = K.FC_CHASE_TOWER_RANGE } end
        end
    end
    return out
end

-- v0.5.163 C2: guarded straight-line cutoff lock. The OLD discriminator (IsTraversableFromTo) tests path
-- CONNECTIVITY (~always true) -> locked=n all demo. Measure the real cutoff: the WALK (BuildPath, trees
-- counted via ignoreTrees=false) vs the straight FC line. Falls back to the old connectivity check only if
-- BuildPath is unavailable. All pcall-guarded.
state.fc_chase_cutoff_locked = function(me_pos, intercept)
    if not (me_pos and intercept and GridNav) then return false, { src = "noargs" } end
    if GridNav.BuildPath then
        local ok, path = pcall(GridNav.BuildPath, me_pos, intercept, false)   -- ignoreTrees=false -> trees block
        if ok and type(path) == "table" and #path >= 2 then
            local r = Escape.CutoffLock(me_pos, intercept, path,
                { ratio = K.FC_CHASE_CUTOFF_RATIO, min_gain = K.FC_CHASE_CUTOFF_MIN })
            return r.locked, { src = "bp", walk = r.walk, straight = r.straight, ratio = r.ratio, n = #path }
        end
        -- v0.5.163.2 instrument: BuildPath present but unusable (errored / < 2 points) -> note it, then fall back
        if GridNav.IsTraversableFromTo then
            local okC, conn = pcall(GridNav.IsTraversableFromTo, me_pos, intercept)
            if okC then return (conn == false),
                { src = "bp_bad", ok = ok and "y" or "n", n = (type(path) == "table" and #path or -1) } end
        end
        return false, { src = "bp_bad_nofb", ok = ok and "y" or "n" }
    end
    if GridNav.IsTraversableFromTo then   -- fallback only when BuildPath is missing
        local okC, conn = pcall(GridNav.IsTraversableFromTo, me_pos, intercept)
        if okC then return (conn == false), { src = "noBP_conn" } end
    end
    return false, { src = "none" }
end

-- v0.5.163.4: does the TARGET take a winding route (around trees/cliffs) that Lina can shortcut by flying
-- straight? Extrapolate the flee direction K.FC_CHASE_FLEE_LOOKAHEAD ahead and check if the target's
-- BuildPath route there winds vs the straight line. This is the real FC cutoff value (the OLD lock checked
-- whether LINA's path was blocked, ~never true when following a runner). Returns (locked, info).
state.fc_chase_target_winding = function(cur, vel)
    if not (cur and vel) then return false, { src = "noargs" } end
    local sp = math.sqrt(vel.x * vel.x + vel.y * vel.y)
    if sp < 1e-3 then return false, { src = "still" } end
    local ux, uy = vel.x / sp, vel.y / sp
    -- v0.5.163.7: the linear flee point can overshoot into unreachable terrain (BuildPath -> bp_bad, no
    -- winding measure). Try decreasing lookaheads until one lands on the navmesh (src="bp") so we measure
    -- the target's real winding to a REACHABLE point. fp is a Vector (v0.5.163.6) so fp:Distance2D works.
    for i = 1, 3 do
        local d = K.FC_CHASE_FLEE_LOOKAHEAD * (i == 1 and 1.0 or (i == 2 and 0.6 or 0.35))
        local fp = Vector(cur.x + ux * d, cur.y + uy * d, cur.z or 0)
        local locked, info = state.fc_chase_cutoff_locked(cur, fp)
        if type(info) == "table" and info.src == "bp" then
            info.flee_point = fp
            return locked, info
        end
    end
    return false, { src = "unreachable" }
end

-- v0.5.163 C2 (design 6.2): the chase claim. Returns (intercept, info, diag) | nil. Fires only on a
-- FLEEING + FINISHABLE kill the offense is committing to (D1), that is winnable (catch-ETA + margin <=
-- escape-ETA), where the straight FC flight is a real terrain/tree cutoff over the walk, and the intercept
-- risk is bounded. PURE sub-signals exposed via diag (FCCH02).
state.fc_chase_claim = function(ctx, target)
    local diag = { committing = false, finishable = false, fleeing = false, winnable = false, terrain_locked = false }
    local me = state.self_npc
    if not (me and target and Entity.IsAlive and Entity.IsAlive(target)) then return nil, nil, diag end
    diag.committing = state.fc_chase_committing(ctx, target) and true or false
    if not diag.committing then return nil, nil, diag end
    -- finishable: a kill we can close (R-killable / combo-killable). Cheap ctx check first.
    diag.finishable = (ctx and (ctx.combo_kill
                       or (ctx.eff_hp_magical and ctx.r_impact_eff and ctx.eff_hp_magical <= ctx.r_impact_eff)))
                      and true or false
    if not diag.finishable then return nil, nil, diag end
    local me_pos = NPCLib.origin(me)
    local tp = state.predict_target_pos(target, 0.3)
    local cur = Entity.GetAbsOrigin(target)
    if not (me_pos and tp and cur) then return nil, nil, diag end
    -- v0.5.163.1 fleeing = the runner is moving AWAY from Lina over the lead (predicted pos farther than
    -- current). ctx.kiting_us (attack-kiting) was structurally false in the v0.5.163 demo, so derive it
    -- from the actual motion the claim already computes.
    local cdx, cdy = cur.x - me_pos.x, cur.y - me_pos.y
    local tdx, tdy = tp.x - me_pos.x, tp.y - me_pos.y
    local d_cur = math.sqrt(cdx * cdx + cdy * cdy)
    local d_tp  = math.sqrt(tdx * tdx + tdy * tdy)
    diag.fleeing = (d_tp > d_cur + K.FC_CHASE_FLEE_MARGIN)
    if not diag.fleeing then return nil, nil, diag end
    local vel = { x = (tp.x - cur.x) / 0.3, y = (tp.y - cur.y) / 0.3 }
    -- the cutoff value: is the TARGET winding around terrain Lina can fly straight over? (sets cut.flee_point + walk)
    diag.terrain_locked, diag.cutoff = state.fc_chase_target_winding(cur, vel)
    if not (diag.terrain_locked and diag.cutoff and diag.cutoff.flee_point) then return nil, nil, diag end
    local fp = diag.cutoff.flee_point
    -- v0.5.163.5 winnable = Lina flies the straight chord to the cutoff point BEFORE the target winds there.
    -- FC adds no speed, so the win is purely the shorter PATH: catch = Lina straight to fp; escape = the
    -- target's winding route (cut.walk) to fp. (The old ChaseWindow modelled a STRAIGHT-line escape, so it
    -- read not-winnable for a target actually winding ~2300u -- the v0.5.163.4 demo.)
    local lina_sp = state.fc_chase_move_speed(); if lina_sp < 1 then lina_sp = K.FC_CHASE_MS_FALLBACK end
    local tgt_sp = (NPC.GetMovementSpeed and NPC.GetMovementSpeed(target)) or 0
    if tgt_sp < 1 then tgt_sp = K.FC_CHASE_MS_FALLBACK end
    local fdx, fdy = fp.x - me_pos.x, fp.y - me_pos.y
    diag.catch_eta  = math.sqrt(fdx * fdx + fdy * fdy) / lina_sp
    diag.escape_eta = (diag.cutoff.walk or 0) / tgt_sp
    diag.winnable = (diag.catch_eta + K.FC_CHASE_ETA_MARGIN) <= diag.escape_eta
    if not diag.winnable then return nil, nil, diag end
    diag.risk = Escape.AdvanceRiskScore(me, fp, { engage_radius = K.FC_CHASE_RADIUS })
    if diag.risk >= K.FC_CHASE_RISK_MAX then return nil, nil, diag end
    return fp, diag.cutoff, diag
end

-- v0.5.163 C2: per-tick FC CHASE = cast FC only. The brain recognizes a winnable terrain/tree cutoff on a
-- fleeing finishable kill the offense is committing to, and casts FC (unobstructed movement) at that
-- instant. The PLAYER steers the cutoff. No move-drive (FC adds no speed; driving it fought the combo +
-- manual control in the v0.5.162 demo). Survival (escape) always preempts.
state.fc_chase_tick = function()
    local me = state.self_npc
    if not me then return end
    if not self_alive_ok() then return end
    -- v0.5.170: fc_chase hardcoded ON (menu-simplification); always evaluate the chase cutoff.
    if state.fc_escape_active and state.fc_escape_active(nil) then return end                 -- escape > chase
    if NPC.HasModifier and NPC.HasModifier(me, "modifier_lina_flame_cloak") then return end   -- already up: player has the path
    local target = state.last_offense_target
    if not (target and Entity.IsEntity and Entity.IsEntity(target)) then
        target = state.pick_offense_target and state.pick_offense_target() or nil
    end
    if not target then return end
    -- cheap commit-evidence gate before the expensive ctx build
    local offense_recent = (state.last_offense_target == target)
        and ((now() - (state.last_offense_dispatch_t or 0)) < K.FC_CHASE_COMMIT_WINDOW)
    if not (offense_recent or state.fc_tf_opener_fired) then return end
    local ctx = state.build_layer1_ctx and state.build_layer1_ctx(target) or nil
    local intercept, w, diag = state.fc_chase_claim(ctx, target)
    if diag and diag.committing and (now() - (state.fc_chase_eval_log_t or 0)) >= 1.0 then
        tlog(2, "fc_chase_eval", {
            fleeing = diag.fleeing and "y" or "n", fin = diag.finishable and "y" or "n",
            winnable = diag.winnable and "y" or "n", locked = diag.terrain_locked and "y" or "n",
            catch = diag.catch_eta and string.format("%.2f", diag.catch_eta) or "?",
            escape = diag.escape_eta and (diag.escape_eta == math.huge and "inf"
                     or string.format("%.2f", diag.escape_eta)) or "?",
            risk = diag.risk and string.format("%.0f", diag.risk) or "?",
            fire = intercept and "y" or "n",
            cut = diag.cutoff and diag.cutoff.src or "?",
            walk = diag.cutoff and diag.cutoff.walk and string.format("%.0f", diag.cutoff.walk) or "?",
            strt = diag.cutoff and diag.cutoff.straight and string.format("%.0f", diag.cutoff.straight) or "?",
        })
        state.fc_chase_eval_log_t = now()
    end
    if not intercept then return end
    -- cast FC only; the player steers the cutoff (FC = unobstructed movement, no speed)
    if (now() - (state.last_fc_dispatch_t or 0)) < 1.5 then return end
    local fc = ability("lina_flame_cloak")
    if not (fc and Ability.GetLevel(fc) > 0 and Ability.IsReady(fc)) then return end
    if NPC.IsChannellingAbility and NPC.IsChannellingAbility(me) then return end
    local mana = (NPC.GetMana and NPC.GetMana(me)) or 0
    if mana < (ability_mana(A.FC) or 50) then return end
    tlog(1, "fc_chase", { x = string.format("%.0f", intercept.x), y = string.format("%.0f", intercept.y) })
    defense_dispatcher:Dispatch("lina_fc_chase", "lina_fc_chase", me, me,
        function(intent, _mod, _caster) return issue_cast_notarget(intent, fc, "def") end,
        nil, "lina_flame_cloak", nil, nil, { fs_shard_window = false })
    state.last_fc_dispatch_t = now()
end

-- ============================ A2: the unified offense-commit gate ============
-- FLAME_CLOAK_TF_ARBITER_DESIGN.md section 5. FC fires for OFFENSE (opener / amp /
-- flip / TTK) only when the fight is turnable AND the commit is insured. Items 1-2
-- of the gate (offense_value present, defense_claim != A) are already enforced by
-- the openers; these helpers are items 3-4. All inputs reuse existing primitives.

-- bailout_ready: >= 1 READY non-FC escape/survive item (inventory-gated via
-- state.lina_save_ready = NPCLib.item_ready). Insures an FC offense commit.
state.fc_bailout_ready = function()
    local me = state.self_npc
    if not me then return false end
    local set = K.FC_BAILOUT_SAVES
    for i = 1, #set do
        if state.lina_save_ready(set[i]) then return true end
    end
    return false
end

-- macro_turnable: allies_eff_strength >= K_FC_TURN * enemies_eff_strength in the
-- fight area. eff_strength = sum of HP-fraction over alive non-illusion heroes
-- (cheap "bodies x health" proxy). Centered on Lina (a body in the fight). No
-- enemies near -> trivially turnable.
-- v0.5.165 D2: the value-modulated turn factor. A high weighted flip value W lowers
-- the required ally:enemy strength ratio (FC turns a more-behind fight for a juicy
-- flip), floored at K.FC_TURN_MIN. W nil / <= 1 -> the plain K.FC_TURN (additive: no
-- change for the cold-open path, the 1-2 TTK starter, the chase, or any pre-D caller).
state.fc_turn_factor = function(W)
    if type(W) == "number" and W > 1 then
        return math.max(K.FC_TURN_MIN, K.FC_TURN * (1 - K.FC_TURN_VALUE_RELAX * (W - 1)))
    end
    return K.FC_TURN
end

state.fc_macro_turnable = function(W)
    local me = state.self_npc
    if not me then return false end
    local me_pos = NPCLib.origin(me)
    if not me_pos then return false end
    local team = Entity.GetTeamNum(me)
    local function eff(list)
        local s, n = 0, 0
        if list then
            for i = 1, #list do
                local h = list[i]
                if h and Target.IsAlive(h) and Target.NotIllusion(h) then
                    local hp  = (Entity.GetHealth and Entity.GetHealth(h)) or 0
                    local hpm = (Entity.GetMaxHealth and Entity.GetMaxHealth(h)) or 1
                    if hpm > 0 then s = s + (hp / hpm); n = n + 1 end
                end
            end
        end
        return s, n
    end
    local ae      = eff(Heroes.InRadius(me_pos, K.FC_MACRO_RADIUS, team, Enum.TeamType.TEAM_FRIEND))
    local ee, en  = eff(Heroes.InRadius(me_pos, K.FC_MACRO_RADIUS, team, Enum.TeamType.TEAM_ENEMY))
    -- v0.5.159: macro_turnable is a TEAMFIGHT gate. A pick (< MIN_ENEMIES enemies)
    -- is turnable by construction -- the TTK proves the kill + bailout/dest_safe
    -- insure survival; team body-count is the wrong question for a solo pick.
    if en < K.FC_MACRO_MIN_ENEMIES then return true, ae, ee end
    if ee <= 0 then return true, ae, ee end
    return (ae >= (state.fc_turn_factor(W) * ee)), ae, ee
end

-- v0.5.160.1 A2-2: favorable = allies_eff >= enemies_eff (even-or-ahead) in the
-- fight area. A FAVORABLE teamfight commits FC offense WITHOUT the bailout/dest_safe
-- insure -- secure the fastest TF (user). A turnable-but-behind fight
-- (K.FC_TURN*ee <= ae < ee) still requires the insure. Mirrors fc_macro_turnable's
-- eff scan (bodies x health-fraction); ee<=0 (no enemies) -> trivially favorable.
state.fc_macro_favorable = function()
    local me = state.self_npc
    if not me then return false end
    local me_pos = NPCLib.origin(me)
    if not me_pos then return false end
    local team = Entity.GetTeamNum(me)
    local function eff(list)
        local s = 0
        if list then
            for i = 1, #list do
                local h = list[i]
                if h and Target.IsAlive(h) and Target.NotIllusion(h) then
                    local hp  = (Entity.GetHealth and Entity.GetHealth(h)) or 0
                    local hpm = (Entity.GetMaxHealth and Entity.GetMaxHealth(h)) or 1
                    if hpm > 0 then s = s + (hp / hpm) end
                end
            end
        end
        return s
    end
    local ae = eff(Heroes.InRadius(me_pos, K.FC_MACRO_RADIUS, team, Enum.TeamType.TEAM_FRIEND))
    local ee = eff(Heroes.InRadius(me_pos, K.FC_MACRO_RADIUS, team, Enum.TeamType.TEAM_ENEMY))
    if ee <= 0 then return true end
    return ae >= ee
end

-- dest_safe: the commit spot is not over-exposed -- no fog-gank looming AND the
-- AdvanceRiskScore is below the abort threshold AND >= 1 ally is near.
state.fc_dest_safe = function()
    local me = state.self_npc
    if not me then return false end
    if state.gank_imminent_self and state.gank_imminent_self() then return false end
    local me_pos = NPCLib.origin(me)
    if not me_pos then return false end
    if Escape and Escape.AdvanceRiskScore then
        local score = Escape.AdvanceRiskScore(me, me_pos,
            { engage_radius = K.FC_MACRO_RADIUS, max_ms = 700, now = now })
        if (score or math.huge) >= K.FC_DEST_RISK_MAX then return false end
    end
    local team = Entity.GetTeamNum(me)
    local allies = Heroes.InRadius(me_pos, K.FC_ALLY_NEAR_RADIUS, team, Enum.TeamType.TEAM_FRIEND)
    local n = 0
    if allies then
        for i = 1, #allies do
            local h = allies[i]
            if h and h ~= me and Target.IsAlive(h) and Target.NotIllusion(h) then n = n + 1 end
        end
    end
    return n >= K.FC_ALLY_NEAR_COUNT
end

-- enemies within the fight area (alive, non-illusion). Used to scope the commit
-- gate to TEAMFIGHTS -- a pick (< MIN_ENEMIES) is the shipped TTK's + player's call.
state.fc_enemies_near = function()
    local me = state.self_npc
    if not me then return 0 end
    local me_pos = NPCLib.origin(me)
    if not me_pos then return 0 end
    local near = Heroes.InRadius(me_pos, K.FC_MACRO_RADIUS, Entity.GetTeamNum(me), Enum.TeamType.TEAM_ENEMY)
    local n = 0
    if near then
        for i = 1, #near do
            local h = near[i]
            if h and Target.IsAlive(h) and Target.NotIllusion(h) then n = n + 1 end
        end
    end
    return n
end

-- offense_commit_ok = (TEAMFIGHT) macro_turnable AND (dest_safe OR bailout_ready).
-- v0.5.159: the gate is a TEAMFIGHT mechanism. A pick (< MIN_ENEMIES enemies) is the
-- shipped TTK's + the player's call -> the gate is a NO-OP for 1-2 (gating the 1-2
-- offense with a defensive insure would invade the attack system). The menu
-- sub-toggle (default ON) isolates the gate for demo: OFF -> returns true (pre-A2).
-- Logs WHY it vetoes (unturnable vs uninsured) so a demo shows the reason.
state.fc_offense_commit_ok = function(ctx, target, W)
    -- v0.5.170: fc_commit_gate hardcoded ON (menu-simplification); the A2 commit gate always evaluates.
    local en_near = state.fc_enemies_near()
    if en_near < K.FC_MACRO_MIN_ENEMIES then
        state.fc_commit_last = { reason = "pick" }; return true  -- pick: TTK/player owns it, A2 stays out
    end
    local turnable, ae, ee = state.fc_macro_turnable(W)
    local keff = state.fc_turn_factor(W)
    -- v0.5.16x D4 (design 8.1): resolve the commit decision + stash the eval on EVERY
    -- path so the unified fc_arbiter FIRE line (the offense sites, same tick) echoes
    -- keff/ae/ee/bailout without recomputing and is never stale. Replaces the old
    -- fc_commit_eval + the two fc_commit_skip probes: a VETO emits the unified HOLD
    -- line itself (throttled, level 1). Boolean decision logic is byte-identical to
    -- A2 (turnable) / A2-2 (favorable -> no insure) / D2 (W-modulated turn factor).
    local ok, reason, insured
    if not turnable then
        ok, reason, insured = false, "unturnable", false
    elseif state.fc_macro_favorable() then
        ok, reason, insured = true, "favorable", true
    elseif state.fc_dest_safe() then
        ok, reason, insured = true, "insured_dest", true
    elseif state.fc_bailout_ready() then
        ok, reason, insured = true, "insured_bailout", true
    else
        ok, reason, insured = false, "uninsured_exposed", false
    end
    state.fc_commit_last = { W = W, ae = ae, ee = ee, keff = keff, insured = insured, reason = reason }
    if not ok and (now() - (state.fc_arbiter_hold_log_t or 0)) >= 1.0 then
        state.fc_arbiter_log({ tier = "hold", reason = reason, W = W,
            keff = keff, ae = ae, ee = ee, bailout = insured, fired = false })
        state.fc_arbiter_hold_log_t = now()
    end
    return ok
end

-- Fire one step now. kind: ut (R) / pt (W,Q) / nt (Flame Cloak) / item_target
-- (Ethereal, Eul). Sets the R-cast-protect state when R is the cast.
local function offense_fire_one(kind, ability_key, arg, intent, combo_name)
    local ok = false
    if kind == "ut" then
        ok = issue_cast_target(intent, ability(ability_key), arg)
        if ok and ability_key == A.R then
            state.last_r_target          = arg
            state.last_r_combo_name       = combo_name
            state.last_r_dispatch_t       = now()
            -- v0.5.5: Fiery Soul stack-aware. last_r_cast_t is the Aghs Shard
            -- cap-window cursor (lina_laguna_super_charged, +5 cap for 5s post-R)
            -- consumed by build_layer1_ctx (ctx.fs_cap / fs_shard_window /
            -- fs_at_cap). Stamped alongside last_r_dispatch_t but never cleared
            -- (r_abort_tick clears last_r_dispatch_t; the cap window must keep
            -- ticking against the wall clock independent of abort-protect).
            state.last_r_cast_t          = now()
        end
    elseif kind == "pt" then
        ok = issue_cast_position(intent, ability(ability_key), arg)
    elseif kind == "nt" then
        ok = issue_cast_notarget(intent, ability(ability_key), "agg")
    elseif kind == "item_target" then
        local it = NPCLib.item(state.self_npc, ability_key)
        if it and arg then ok = issue_item_target(intent, "agg", it, arg) end
    elseif kind == "item_self" then
        local it = NPCLib.item(state.self_npc, ability_key)
        if it then ok = issue_item_self(intent, "agg", it) end
    end
    return ok
end

local function resolve_step_delay(step, ctx)
    local d = step.delay_s
    if type(d) == "function" then d = d(ctx) end
    return d or 0
end

-- Schedule a step for delayed execution. Snapshots ctx; arg_fn / cond_fn are
-- re-evaluated at fire time against LIVE target_pos + eff_hp_magical.
local function schedule_step(combo_name, step, ctx, delay)
    -- v0.5.163 C2: broad chase-commit stamp. Every offense combo step flows through here carrying the
    -- committed hero in ctx.target; stamp it (R-independent) so fc_chase_committing fires with R on CD too.
    if ctx.target and Entity.IsEntity and Entity.IsEntity(ctx.target)
       and Target.IsAlive and Target.IsAlive(ctx.target) then
        state.last_offense_target     = ctx.target
        state.last_offense_dispatch_t = now()
    end
    local snap = {}
    for k, v in pairs(ctx) do snap[k] = v end
    state.pending_steps[#state.pending_steps + 1] = {
        fire_at = now() + delay, combo_name = combo_name, short = step.short,
        ability_key = step.ability, kind = step.kind, arg_fn = step.arg,
        cond_fn = step.cond, target = ctx.target, ctx_snapshot = snap,
        independent_pos = step.independent_pos,  -- pt step aimed at a fixed pos (e.g. TF cluster), not the unit
        -- v0.5.34 task E: optional per-step retry/abort overrides. max_tries
        -- caps re-issue attempts (default state.STEP_REISSUE_ATTEMPTS); abort_after
        -- caps the no-land deadline (default state.STEP_REISSUE_DEADLINE).
        max_tries = step.max_tries, abort_after = step.abort_after,
    }
end

-- Resolve the live ability/item handle for a step (for cooldown / phase checks).
local function step_handle(p)
    if p.kind == "item_target" or p.kind == "item_self" then
        return NPCLib.item(state.self_npc, p.ability_key)
    end
    return ability(p.ability_key)
end
-- Is any combo spell (Q/W/R) currently in its cast point? If so, do not re-issue
-- anything (a fresh order would restart / stomp the in-progress cast).
local function combo_spell_phasing()
    local function ph(key)
        local a = ability(key)
        return (a and Ability.IsInAbilityPhase and Ability.IsInAbilityPhase(a)) or false
    end
    return ph(A.Q) or ph(A.W) or ph(A.R)
end

-- v0.5.38 MAINT-11.1: per-step body extracted from pending_steps_tick into
-- pending_step_try_fire. The four locals that the v0.5.36 PERF-05 on_drop
-- closure mutated (kept / removed_any / i_kept_upto) plus the fire-branch
-- latch (acted) now live on a `scratch` table threaded through the helper,
-- so both on_drop and the helper can mutate the same shared state. Every
-- branch outcome (3 keep, 5 drop, 1 acted/phasing keep, 1 max_tries abort,
-- 1 no_land abort), every tlog payload, every comparison op, and every
-- side-effect ordering (on_drop BEFORE tlog; recently_aborted_intents stamp
-- BEFORE tlog on no_land) is preserved character-identical with v0.5.37.
-- v0.5.97 fix #5: an R step that never ISSUES (cond-skip or target-invalid drop)
-- must not leave the 3s hard R-lock armed. mark_layer1(...,true) arms that lock at
-- DISPATCH, before the delay_s=0.4 R step fires, so when the R aborts (target gains
-- BKB / Linkens / Lotus / Nyx Carapace / magic-immune / dies in the W->R gap) the
-- lock otherwise suppressed ALL TF / starter / auto-R re-entry for 3s with NO R
-- spent. Downgrade to the SEQ lock (last_layer1_was_r=false) so re-entry resumes as
-- the SEQ window expires (~1.2s from dispatch) instead of 3s. Acts ONLY on the R
-- step of the combo that armed the CURRENT lock (intent match), so a committed R
-- (which never reaches these drop branches) keeps the full 3s hard lock unchanged.
-- state.* + tlog are call-time safe here (no forward-ref).
local function release_hard_r_lock_on_abort(p)
    if p.short == "r" and state.last_layer1_was_r
       and state.last_layer1_intent == p.combo_name then
        state.last_layer1_was_r = false
        tlog(2, "hard_r_lock_released", { combo = tostring(p.combo_name), reason = "r_aborted" })
    end
end
local function pending_step_try_fire(p, env, scratch, i)
    local me      = env.me
    local now_t   = env.now_t
    local phasing = env.phasing
    -- A unit must be alive only for steps that actually target it: ut / R,
    -- item_target, and unit-tied pt steps. A pt step flagged independent_pos
    -- (TF cluster W/Q) is aimed at a captured Vector and survives the unit's
    -- death (it still nukes the pile).
    local needs_target = (p.kind == "ut" or p.kind == "item_target")
                         or (p.kind == "pt" and not p.independent_pos)
    local target_ok = p.target and Entity.IsEntity(p.target) and Target.IsAlive(p.target)
    if now_t < p.fire_at then
        scratch.i_kept_upto = i
        if scratch.removed_any then scratch.kept[#scratch.kept + 1] = p end           -- not eligible yet
    elseif needs_target and not target_ok then
        scratch.on_drop()
        -- v0.5.42: stamp recently_aborted_intents so cast_verify_tick's
        -- prefix lookup (L443) suppresses the noisy double_fail emit for the
        -- pcv entry that safe_issue already registered. Same key format as
        -- the v0.5.26 no_land stamp below.
        state.recently_aborted_intents[(p.combo_name or "?") .. "_" .. (p.short or "s")] = now_t
        tlog(2, "scheduled_step_aborted", { combo = p.combo_name, step = p.short, reason = "target_invalid" })
        release_hard_r_lock_on_abort(p)   -- v0.5.97 fix #5: aborted R must not hold the 3s lock
    elseif not self_alive_ok() then
        scratch.on_drop()
        -- v0.5.42: same stamp as target_invalid branch above; cast_verify
        -- suppression on self-not-ok abort.
        state.recently_aborted_intents[(p.combo_name or "?") .. "_" .. (p.short or "s")] = now_t
        tlog(2, "scheduled_step_aborted", { combo = p.combo_name, step = p.short, reason = "self_not_ok" })
    else
        local live = p.ctx_snapshot
        live.me = me
        if target_ok then
            live.target = p.target
            live.t_pos  = Entity.GetAbsOrigin(p.target)
            if Target.EffectiveHpVs then
                local e = Target.EffectiveHpVs(p.target, me, DT.DAMAGE_TYPE_MAGICAL)
                if e and e > 0 then live.eff_hp_magical = e end
            end
        end
        if p.cond_fn and not p.cond_fn(live) then
            scratch.on_drop()
            -- v0.5.42: stamp recently_aborted_intents on cond-skip too. This
            -- is the path that handles r_kill_steal's MAGIC_IMMUNE / Linkens
            -- / Lotus / dead target bail; pre-v0.5.42 the pcv entry
            -- registered by safe_issue would survive and cast_verify_tick
            -- would later emit a spurious double_fail. Same key format as
            -- target_invalid / self_not_ok / no_land branches.
            state.recently_aborted_intents[(p.combo_name or "?") .. "_" .. (p.short or "s")] = now_t
            tlog(3, "scheduled_step", { combo = p.combo_name, step = p.short, ok = "skip" })  -- drop
            release_hard_r_lock_on_abort(p)   -- v0.5.97 fix #5: cond-aborted R must not hold the 3s lock
        else
            local h  = step_handle(p)
            local cd = (h and Ability.GetCooldown and (Ability.GetCooldown(h) or 0)) or 0
            -- v0.5.4: snapshot the baseline cd on first inspection (handles
            -- the case where schedule_step ran while the SAME NPCLib.item
            -- handle was already on cd from a self-save: Ether / Cyclone /
            -- Wind Waker all share handles between offense and defense).
            -- Landed is now cd-delta vs baseline, not raw cd, so a save
            -- firing the shared item between schedule and re-issue no longer
            -- masquerades as the offensive step landing.
            if not p.cd_at_schedule then p.cd_at_schedule = cd end
            if (p.tries or 0) > 0 and cd > (p.cd_at_schedule or 0) + 0.05 then
                -- landed: the cast completed (ability cd jumped above baseline)
                scratch.on_drop()
                tlog(3, "scheduled_step", { combo = p.combo_name, step = p.short, ok = "landed",
                    tries = tostring(p.tries) })                                   -- drop
            elseif scratch.acted or phasing then
                scratch.i_kept_upto = i
                if scratch.removed_any then scratch.kept[#scratch.kept + 1] = p end   -- serialize / wait for the in-flight cast
            else
                p.first_t   = p.first_t or now_t
                local age   = now_t - p.first_t
                local tries = p.tries or 0
                -- v0.5.7 E9 (F5 no_land diagnostic): probe why a step is sitting
                -- in the retry tail. Three suspects: ability never came off cd,
                -- the engine paused (native HR repause), or retry-spacing ate
                -- the deadline. cd / ready / paused are live; cd_at_schedule +
                -- age + tries give the retry-spacing picture. paused uses the
                -- literal "Lina" hero-menu name because LINA_MENU is declared
                -- ~570 lines below this site (v0.5.6 E4 was rejected for
                -- exactly that scope trap; E2 forward-decl move is not in this
                -- patch). cd_last / ready_last / paused_last are stashed on p
                -- so the no_land abort can replay the last probe values.
                local ready  = (cd <= 0)
                local paused = Native.IsPaused and Native.IsPaused("Lina") or false
                p.cd_last     = cd
                p.ready_last  = ready
                p.paused_last = paused
                tlog(2, "step_cd_probe", { combo = p.combo_name, step = p.short, kind = p.kind,
                    cd = string.format("%.2f", cd),
                    cd_at_schedule = string.format("%.2f", p.cd_at_schedule or 0),
                    age = string.format("%.2f", age), tries = tostring(tries),
                    ready = ready and "y" or "n",
                    paused = paused and "y" or "n",
                    phasing = phasing and "y" or "n" })
                -- v0.5.34 task E: honor per-step max_tries override
                -- (defaults to global STEP_REISSUE_ATTEMPTS). FC sets
                -- max_tries=1 so a silently-dropped order can't waste 3
                -- retries in the cast_verify pipeline.
                local tries_cap = p.max_tries or state.STEP_REISSUE_ATTEMPTS
                if tries == 0
                   or (tries < tries_cap and age >= tries * state.STEP_REISSUE_SPACING) then
                    local arg    = p.arg_fn and p.arg_fn(live) or nil
                    local intent = p.combo_name .. "_" .. (p.short or "s") .. "#" .. (tries + 1)
                    local ok = offense_fire_one(p.kind, p.ability_key, arg, intent, p.combo_name)
                    if tries == 0 then
                        -- v0.5.7 E9: tries==0 -> 1 transition is the only place
                        -- we can ground-truth what handle / ability_key the
                        -- step is gating on; everything after is just delta.
                        tlog(2, "step_issue_baseline", { combo = p.combo_name, step = p.short,
                            cd0 = string.format("%.2f", p.cd_at_schedule or 0),
                            ability = tostring(p.ability_key) })
                    end
                    p.tries = tries + 1
                    scratch.acted = true
                    tlog(3, "scheduled_step", { combo = p.combo_name, step = p.short, kind = p.kind,
                        try = tostring(p.tries), ok = ok and "y" or "n" })
                    scratch.i_kept_upto = i
                    if scratch.removed_any then scratch.kept[#scratch.kept + 1] = p end
                elseif age > (p.abort_after or state.STEP_REISSUE_DEADLINE) then
                    -- v0.5.7 E9: expand no_land payload with the last probe
                    -- snapshot so a single abort line answers "did cd ever
                    -- clear, was HR paused, what was the schedule baseline".
                    -- v0.5.26 Item 3: stamp recently_aborted_intents so the
                    -- matching cast_verify can suppress its noisy double_fail
                    -- emit (the order never actually issued; HR/OW pause held
                    -- it). Key prefix mirrors the intent format used by schedule_step.
                    scratch.on_drop()
                    state.recently_aborted_intents[(p.combo_name or "?") .. "_" .. (p.short or "s")] = now_t
                    tlog(2, "scheduled_step_aborted", { combo = p.combo_name, step = p.short,
                        reason = "no_land", tries = tostring(tries),
                        cd_last = string.format("%.2f", p.cd_last or cd),
                        cd_at_schedule = string.format("%.2f", p.cd_at_schedule or 0),
                        ready_last = (p.ready_last and "y" or "n"),
                        paused_last = (p.paused_last and "y" or "n"),
                        age = string.format("%.2f", age),
                        ability_key = tostring(p.ability_key) })                   -- give up, drop
                else
                    scratch.i_kept_upto = i
                    if scratch.removed_any then scratch.kept[#scratch.kept + 1] = p end -- waiting for re-issue spacing
                end
            end
        end
    end
end

-- v0.4.5: each deferred step is RE-ISSUED (bounded + spaced) until it actually
-- lands, to out-persist the native Orb Walker ATTACK flood that cancels casts.
-- Serialized: at most one step (re-)issues per tick (earliest eligible), and
-- never while a combo spell is mid-cast, so retries never stomp each other.
-- Each attempt uses a unique intent (lib/order dedups identical ids for 2.5s).
state.pending_steps_tick = function()
    local steps = state.pending_steps
    local n_steps = #steps
    if n_steps == 0 then return end
    local me = state.self_npc
    if not me then return end
    -- v0.5.37 PERF-07: read the per-frame now() sample stashed by OnUpdateEx.
    -- pending_steps_tick is only called from OnUpdateEx (line 5121). now_t
    -- gates fire_at, p.first_t, retry-spacing age, and abort_after deadline;
    -- the recently_aborted_intents stamp (line 2478) uses the same tick value.
    local now_t   = state.frame_t
    local phasing = combo_spell_phasing()
    -- v0.5.38 MAINT-11.1: per-step body lives in pending_step_try_fire (just
    -- above). The four locals that v0.5.36 PERF-05's on_drop closure mutated
    -- (kept / removed_any / i_kept_upto) plus the fire-branch latch (acted)
    -- are now wrapped in `scratch` so the helper can mutate the same shared
    -- state. on_drop is also stashed on scratch (it still closes over the
    -- table so its kept-backfill semantics are identical: lazy-allocate kept,
    -- copy steps[1..i_kept_upto] on the FIRST drop, set the removed_any
    -- latch). env carries the per-tick read-only inputs.
    local scratch = {
        kept        = nil,
        removed_any = false,
        i_kept_upto = 0,
        acted       = false,
        steps       = steps,
    }
    scratch.on_drop = function()
        if not scratch.removed_any then
            scratch.removed_any = true
            scratch.kept = {}
            for j = 1, scratch.i_kept_upto do
                scratch.kept[j] = scratch.steps[j]
            end
        end
    end
    local env = { me = me, now_t = now_t, phasing = phasing }
    for i = 1, n_steps do
        pending_step_try_fire(steps[i], env, scratch, i)
    end
    if scratch.removed_any then state.pending_steps = scratch.kept end
end

-- Schedule the whole step list. v0.4.6: ALL steps (including delay 0) go through
-- pending_steps so EVERY cast gets the bounded-spaced re-issue (the flood cancels
-- the lead step and single-cast combos like r_finisher too). pending_steps_tick
-- serializes them (phasing / acted guards) and honors each step's fire_at as a
-- start floor, so this is a clean sequential chain: each step fires the instant
-- the prior lands. Conds are re-checked LIVE at fire time inside pending_steps_tick.
state.fire_steps = function(name, steps, ctx)
    local max_delay = 0
    for i = 1, #steps do
        local step = steps[i]
        local delay = resolve_step_delay(step, ctx)
        if delay > max_delay then max_delay = delay end
        schedule_step(name, step, ctx, delay)
        tlog(3, "step_fire", { combo = name, step = step.short or ("s" .. i), ok = "scheduled",
            delay = string.format("%.2f", delay) })
    end
    -- Keep Hit & Run paused until the final cast lands: latest step delay + a
    -- cast tail (R's 0.55s cast point + margin). update_hitrun_pause also holds
    -- the pause while #pending_steps > 0, so it spans the full sequential combo.
    state.combo_active_until = math.max(state.combo_active_until or 0, now() + max_delay + 0.7)
end

-- Throttle: hard 3.0s lock after an R commit; light 0.4s lock otherwise.
local function layer1_in_lock()
    local win = state.last_layer1_was_r and state.LAYER1_COMMIT_WINDOW_R or state.LAYER1_COMMIT_WINDOW_SEQ
    return (state.last_layer1_t and (now() - state.last_layer1_t) < win) or false
end
local function mark_layer1(name, is_r)
    state.last_layer1_t       = now()
    state.last_layer1_was_r   = is_r and true or false
    state.last_layer1_intent  = name
    state.l1_counter          = state.l1_counter + 1
end

-- Master "Enable Lina brain" gate (same toggle defense_enabled honours). The
-- offense entry points (combo dispatch + auto-R) must respect it too, else the
-- master OFF switch silently leaves offense firing.
local function offense_enabled()
    local m = state.menu
    if not m then return true end
    if m.enable and not m.enable:Get() then return false end
    return true
end

-- Offense target: enemy actively attacking Lina (within 600u) first, else the
-- nearest real enemy hero in the classify radius.
-- v0.5.36 PERF-12: per-tick memo of GetHeroesInRadius(me, COMBO_CLASSIFY_RADIUS,
-- TEAM_ENEMY). pick_offense_target and pick_r_finisher_target both call this on
-- the same starter tick with identical args; one shared list saves a native
-- query per tick. Cache keyed on now() with 1ms epsilon (Dota tick ~33ms so the
-- cache never bleeds), mirrors enemy_cluster_center's cluster_cache pattern.
-- Note: enemy_cluster_center keeps its own cache - leaving it untouched.
local function get_enemies_in_classify_radius(me)
    if not me then return nil end
    local frame_t = now()
    if state.tick_enemy_list_t and (frame_t - state.tick_enemy_list_t) < 0.001 then
        return state.tick_enemy_list_cached
    end
    local list = Entity.GetHeroesInRadius(me, state.COMBO_CLASSIFY_RADIUS, Enum.TeamType.TEAM_ENEMY)
    state.tick_enemy_list_t = frame_t
    state.tick_enemy_list_cached = list
    return list
end

-- v0.5.166 D3: aim tie-break predicate. Should a candidate at distance hd / value v
-- replace the current best (cur_d / cur_v)? aim off -> strictly closer (the original
-- pick_offense_target behavior, byte-identical). aim on -> closer beyond the epsilon
-- band, OR within the band with a higher HeroValue (kill the more valuable enemy).
state.fc_aim_prefer = function(hd, v, cur_d, cur_v, aim)
    if not cur_d then return true end
    if not aim then return hd < cur_d end
    if hd < cur_d - K.HV_AIM_DIST_EPS then return true end
    if hd > cur_d + K.HV_AIM_DIST_EPS then return false end
    return (v or 0) > (cur_v or 0)
end

local function pick_offense_target()
    local me = state.self_npc
    if not me then return nil end
    local list = get_enemies_in_classify_radius(me)  -- v0.5.36 PERF-12: shared per-tick cache
    if not list then return nil end
    -- v0.5.152: prefer a KILLABLE target. Track the best killable (attacking-else-
    -- nearest) AND a fallback that includes cannot-kill targets (Shallow Grave /
    -- False Promise / WK Reincarnation ready), so Lina switches off an unkillable
    -- enemy when a killable one exists, but still harasses/W's it if ALL are
    -- unkillable (never idle; R-commit is gated separately by r_target_blocked).
    -- v0.5.166 D3: when fc_aim_bias is on, the KILLABLE tier breaks near-equidistant
    -- ties by HeroValue (and prefers the higher-value attacker); aim off -> the
    -- original attacking-else-nearest, byte-identical. The fallback (all-unkillable
    -- harass) tier stays first/nearest. Never overrides the killable/castable filters.
    local aim = true  -- v0.5.170: fc_aim_bias hardcoded ON (menu-simplification)
    local function hv_of(h) return (aim and state.hero_value and state.hero_value.of(h, list)) or 0 end
    local attacking, attacking_v, nearest, best_d, nearest_v   -- killable-only (aim-aware)
    local pure_attacking, pure_nearest, pure_best_d            -- killable aim-OFF pick (for the fc_aim_flip diag)
    local fb_attacking, fb_nearest, fb_best_d                   -- fallback (incl unkillable)
    for i = 1, #list do
        local h = list[i]
        -- Skip magic-immune: Lina's entire kit (Q/W/R) is magical, so a BKB'd
        -- target is untouchable - never pick it as a burst target.
        if h and Target.IsAlive(h) and Target.NotIllusion(h) and Target.NotClone(h)
           and not NPC.HasState(h, MS.MODIFIER_STATE_MAGIC_IMMUNE) then
            local hd  = dist_to(h)
            local atk = (NPC.IsAttacking and NPC.IsAttacking(h) and hd <= 600) and true or false
            if not fb_attacking and atk then fb_attacking = h end
            if not fb_best_d or hd < fb_best_d then fb_best_d, fb_nearest = hd, h end
            if not (Target.IsUnkillableNow and Target.IsUnkillableNow(h)) then
                local v = hv_of(h)
                if atk and (not attacking or (aim and v > (attacking_v or 0))) then attacking, attacking_v = h, v end
                if state.fc_aim_prefer(hd, v, best_d, nearest_v, aim) then best_d, nearest, nearest_v = hd, h, v end
                if atk and not pure_attacking then pure_attacking = h end                      -- aim-OFF pick (diag)
                if not pure_best_d or hd < pure_best_d then pure_best_d, pure_nearest = hd, h end
            end
        end
    end
    local chosen = attacking or nearest or fb_attacking or fb_nearest
    -- v0.5.166.1 D3 diag: log only when the value tie-break actually flipped the killable
    -- pick vs the strictly-nearest (aim-OFF) choice, so a staged near-tie demo is readable.
    if aim then
        local pure_chosen = pure_attacking or pure_nearest or fb_attacking or fb_nearest
        if chosen and pure_chosen and chosen ~= pure_chosen
           and (now() - (state.fc_aim_flip_log_t or 0)) >= 1.0 then
            tlog(2, "fc_aim_flip", {
                chose = uname(chosen),      chose_v = string.format("%.2f", hv_of(chosen)),
                over  = uname(pure_chosen), over_v  = string.format("%.2f", hv_of(pure_chosen)),
            })
            state.fc_aim_flip_log_t = now()
        end
    end
    return chosen
end
-- v0.5.16x Phase C (Deviation D1): expose the offense-target selector so fc_chase_tick can acquire a
-- fleeing kill target on the FC-opener-fired-without-R commit path (last_r_target nil before R lands).
state.pick_offense_target = pick_offense_target

-- v0.5.15 IMP-A2: r_finisher target is NOT necessarily the offense target.
-- pick_offense_target prefers attackers/nearest; the finisher wants the lowest
-- eff-HP magical enemy that R can actually land on (in current R range, not
-- BKB'd). Scans COMBO_CLASSIFY_RADIUS (1500u), filters by live R cast-range
-- (cast_range_of(A.R, FALLBACK_RANGES.R), accounts for Aether/Talents), returns nil if none
-- killable+reachable. Caller rebuilds layer1 ctx for this target when it
-- differs from the dispatcher's pick.
local function pick_r_finisher_target()
    local me = state.self_npc
    if not me then return nil end
    local list = get_enemies_in_classify_radius(me)  -- v0.5.36 PERF-12: shared per-tick cache
    if not list then return nil end
    local rng = cast_range_of(ability(A.R), FALLBACK_RANGES.R)
    local best, best_eff
    for i = 1, #list do
        local h = list[i]
        if h and Target.IsAlive(h) and Target.NotIllusion(h) and Target.NotClone(h)
           and not NPC.HasState(h, MS.MODIFIER_STATE_MAGIC_IMMUNE)
           and not (Target.IsUnkillableNow and Target.IsUnkillableNow(h))  -- v0.5.152: a finisher cannot finish an unkillable target
           and dist_to(h) <= rng then
            local eff = lina_eff_hp_magical(h)
            if not best_eff or eff < best_eff then best_eff, best = eff, h end
        end
    end
    return best
end

-- Anti-grief (#6): is an ally hero already committing on this target? Cycloning
-- (Eul/WW) a target an ally is attacking makes it INVULNERABLE and saves it from
-- the ally's kill. Heuristic: an alive ally within 600u of the target that is
-- mid-attack. Used to refuse the cyclone setups (fall to bare WQR instead).
K.ALLY_COMMIT_RADIUS = 600
local function ally_committing_on(target)
    if not (target and Entity.IsEntity(target)) then return false end
    local tp = Entity.GetAbsOrigin(target)
    local me = state.self_npc
    if not tp or not me then return false end
    local allies = Heroes.InRadius(tp, K.ALLY_COMMIT_RADIUS, Entity.GetTeamNum(me), Enum.TeamType.TEAM_FRIEND)
    if not allies then return false end
    for i = 1, #allies do
        local a = allies[i]
        if a and a ~= me and Target.IsAlive(a) and NPC.IsAttacking and NPC.IsAttacking(a) then
            return true
        end
    end
    return false
end

-- v0.5.26 Item 1: TF ally-focus target-scoring. Variant of ally_committing_on
-- that COUNTS attackers (within the wider K.ALLY_FOCUS_RADIUS=1100) instead of
-- returning on first match. tf_r_value_target subtracts a bonus from the
-- candidate score when count >= K.ALLY_FOCUS_COUNT so team focus nudges the R
-- picker toward already-pressured targets. Mirrors Sniper.lua score_ally_focus
-- / ally_focus+30 (Sniper.lua:1609 / 1979 / 5077).
local function count_allies_attacking(target, me)
    if not (target and Entity.IsEntity(target)) then return 0 end
    local tp = Entity.GetAbsOrigin(target)
    if not tp or not me then return 0 end
    local allies = Heroes.InRadius(tp, K.ALLY_FOCUS_RADIUS, Entity.GetTeamNum(me), Enum.TeamType.TEAM_FRIEND)
    if not allies then return 0 end
    local n = 0
    for i = 1, #allies do
        local a = allies[i]
        if a and a ~= me and Target.IsAlive(a) and NPC.IsAttacking and NPC.IsAttacking(a) then
            n = n + 1
        end
    end
    return n
end

-------------------------------------------------------------- step builders --
state.build_lina_ether_wqr_steps = function(ctx)
    return {
        { ability = "item_ethereal_blade", kind = "item_target", short = "ether",
          arg = function(c) return c.target end, delay_s = 0 },
        { ability = A.W, kind = "pt", short = "w",
          arg = function(c) return state.w_aim(c.target) end, delay_s = 0.3 },
        { ability = A.Q, kind = "pt", short = "q",
          arg = function(c) return state.predict_lead_path(c.target) end, delay_s = 0.5 },
        { ability = A.R, kind = "ut", short = "r",
          arg = function(c) return c.target end, delay_s = 1.0,
          cond = function(c) return not r_target_blocked(c) end },
    }
end
-- Cyclone setup (Eul OR Wind Waker; both cyclone an enemy, invuln then fall).
-- Cyclone -> W timed so the stun DETONATES as the target LANDS (re-stun on
-- landing) -> R once targetable again -> Q. cyclone_item is "item_cyclone" or
-- "item_wind_waker".
--
-- v0.5.100 Note 1 timing model (KV-driven, no hardcodes; mirrors how
-- predict_lead_path reads dragon_slave_speed): the cyclone holds the target
-- airborne + UNTARGETABLE for cyclone_duration (KV, 2.5 on both items). W's
-- press-to-stun lead = live W cast point (0.45) + light_strike_array_delay_time
-- (KV, 0.5) ~= 0.95. The old W delay_s=2.0 detonated at ~2.95, about 0.45s
-- AFTER the landing, with the target already free and walking out of the AoE.
-- Lina is free to act during the cyclone and W is a POSITION cast at the hold
-- point (predict_cyclone_exit), so W is cast EARLY at
-- cyc_dur - w_lead + bias (~1.7). The land bias (0.15s) absorbs the cyclone
-- step's own cast latency (turn + order resolve shift the airborne window
-- later than dispatch t0): detonating EARLY hits an INVULNERABLE target =
-- total miss, while detonating slightly late still catches the just-landed
-- target inside the 250u AoE (at 350ms it moves under 60u in that window).
-- R waits for the target to be TARGETABLE again (cyc_dur + 0.05; R's own
-- 0.45 cast point + step re-issue add natural margin), Q trails at
-- cyc_dur + 0.2. Tune the bias from demo: cyclone_combo_timing tlog `issued`
-- time vs the cyclone-modifier expire on the target.
state.cyclone_combo_timing = function(cyclone_item)
    local land_bias = 0.15
    local cyc = NPCLib.item(state.self_npc, cyclone_item)
    local cyc_dur = state.item_kv(cyc, "cyclone_duration", 2.5)
    local w = ability(A.W)
    local cp = 0.45
    if w and Ability.GetCastPoint then
        local ok, v = pcall(Ability.GetCastPoint, w, true)
        if ok and type(v) == "number" and v > 0 then cp = v end
    end
    local w_lead  = cp + state.item_kv(w, "light_strike_array_delay_time", 0.5)
    local w_delay = math.max(0.1, cyc_dur - w_lead + land_bias)
    return w_delay, cyc_dur + 0.05, cyc_dur + 0.2, cyc_dur, w_lead
end
state.build_lina_cyclone_wrq_steps = function(ctx, cyclone_item)
    local short = (cyclone_item == "item_wind_waker") and "ww" or "eul"
    local w_delay, r_delay, q_delay, cyc_dur, w_lead = state.cyclone_combo_timing(cyclone_item)
    tlog(2, "cyclone_combo_timing", { item = short,
        cyc_dur = string.format("%.2f", cyc_dur),
        w_lead  = string.format("%.2f", w_lead),
        w = string.format("%.2f", w_delay),
        r = string.format("%.2f", r_delay),
        q = string.format("%.2f", q_delay) })
    return {
        { ability = cyclone_item, kind = "item_target", short = short,
          arg = function(c) return c.target end, delay_s = 0 },
        { ability = A.W, kind = "pt", short = "w",
          arg = function(c) return state.predict_cyclone_exit(c.target) end, delay_s = w_delay },
        { ability = A.R, kind = "ut", short = "r",
          arg = function(c) return c.target end, delay_s = r_delay,
          cond = function(c) return not r_target_blocked(c) end },
        { ability = A.Q, kind = "pt", short = "q",
          arg = function(c) return state.predict_lead_path(c.target) end, delay_s = q_delay },
    }
end
state.build_lina_wqr_steps = function(ctx)
    return {
        { ability = A.W, kind = "pt", short = "w",
          arg = function(c) return state.w_aim(c.target) end, delay_s = 0 },
        { ability = A.Q, kind = "pt", short = "q",
          arg = function(c) return state.predict_lead_path(c.target) end, delay_s = 0.1 },
        { ability = A.R, kind = "ut", short = "r",
          arg = function(c) return c.target end, delay_s = 0.4,
          cond = function(c) return not r_target_blocked(c) end },
    }
end
state.build_lina_r_finisher_steps = function(ctx)
    return {
        { ability = A.R, kind = "ut", short = "r",
          arg = function(c) return c.target end, delay_s = 0,
          cond = function(c) return not r_target_blocked(c) end },
    }
end
state.build_lina_r_first_rwq_steps = function(ctx)
    return {
        { ability = A.R, kind = "ut", short = "r",
          arg = function(c) return c.target end, delay_s = 0,
          cond = function(c) return not r_target_blocked(c) end },
        { ability = A.W, kind = "pt", short = "w",
          arg = function(c) return state.w_aim(c.target) end, delay_s = 0.5 },
        { ability = A.Q, kind = "pt", short = "q",
          arg = function(c) return state.predict_lead_path(c.target) end, delay_s = 0.7 },
    }
end
-- v0.5.34 task starter-cap (mirrors v0.5.26 IMP-A4 TF pattern in the tf_sustain block; grep `IMP-A4`): at
-- fs_at_cap the caller may supply positive-cap target overrides so the brain
-- keeps firing W and Q instead of going silent. w_cluster_target (Vector,
-- optional) re-points W at the densest cluster centroid (max-stun midpoint)
-- and is independent_pos so the step doesn't follow the engagement target.
-- q_priority_target (unit handle, optional) re-points Q at the lowest-eff-HP
-- enemy in Q range (priority kill / finish). When both are nil the builder
-- falls back to the pre-v0.5.34 single-target engagement aim - off-cap ticks
-- and disabled-cap-aware ticks behave exactly as before.
state.build_lina_sustain_qw_steps = function(ctx, q_priority_target, w_cluster_target)
    local steps = {}
    local mana_left = ctx.mana
    -- v0.5.35 task Q6 (sustain-QW mana floor from v0.5.33 audit): reserve R's
    -- mana cost so the sustain builder doesn't drain mana below R-viability.
    -- Off-cap and at-cap sustain both honor the reserve. Burst archetypes use
    -- cost_wqr (W+Q+R) for their gates so they're unaffected. Toggle
    -- v0.5.171: sustain_r_reserve hardcoded ON (menu-simplification). Sustain dispatches
    -- always reserve R mana (the old default); the disable toggle is gone.
    local sustain_reserve_on = true
    local r_reserve = sustain_reserve_on and (ability_mana(A.R) or 0) or 0
    if ctx.ready_w and ctx.in_w_range and mana_left >= ability_mana(A.W) + r_reserve then
        local w_indep = w_cluster_target ~= nil
        steps[#steps + 1] = { ability = A.W, kind = "pt", short = "w",
            arg = function(c)
                if w_cluster_target then return w_cluster_target end
                return state.w_aim(c.target)
            end,
            delay_s = 0, independent_pos = w_indep }
        mana_left = mana_left - ability_mana(A.W)
    end
    if ctx.ready_q and ctx.in_q_range and mana_left >= ability_mana(A.Q) + r_reserve then
        local q_indep = q_priority_target ~= nil
        steps[#steps + 1] = { ability = A.Q, kind = "pt", short = "q",
            arg = function(c)
                if q_priority_target and Entity.IsEntity(q_priority_target)
                   and Target.IsAlive(q_priority_target) then
                    return Entity.GetAbsOrigin(q_priority_target)
                end
                return state.predict_lead_path(c.target)
            end,
            delay_s = (#steps > 0) and 0.1 or 0,  -- 0 if W was out of range / skipped
            independent_pos = q_indep }
    end
    return steps
end
state.build_lina_flame_cloak_steps = function(ctx)
    return {
        -- v0.5.34 task E: cap retries at 1 fire + 0.5s landing-confirmation
        -- window. If FC's first order is silently dropped by the engine (race
        -- with a user manual cast, or any other reason the engine refuses the
        -- order without bumping CD), abort after 0.5s instead of the global
        -- 1.5s STEP_REISSUE_DEADLINE. FC is a precondition co-cast: if it
        -- didn't land on attempt 1 the burst archetype has already moved past
        -- it and there's no value in spamming retries. Caps the v0.5.33 lockup
        -- (~1.5s of cast_verify_double_fail noise) at 0.5s.
        { ability = A.FC, kind = "nt", short = "flame_cloak",
          arg = function() return nil end, delay_s = 0,
          cond = function(c) return c.flame_cloak_ready end,
          max_tries = 1, abort_after = 0.5 },
    }
end

------------------------------------------------------------- dispatchers ----
-- v0.5.7 (E8, covers A8/B2/C2): annotate every dispatch-decision tlog with the
-- cap-aware Fiery Soul state (fs / fs_cap / at_cap / fs_window) added in v0.5.5
-- plus the decision-relevant gate state (rq/rw/rr ready, ether/eul/ww readiness,
-- ww_threatened, force). Without these fields the post-E1 suppression behavior
-- cannot be confirmed from logs and refusal reasons stay implicit in the if-
-- elseif ladder ordering. Helper is hung off `state` so both the starter and
-- the teamfight tick can call it; tf_q_poke (which logs BEFORE build_layer1_ctx
-- runs) reads fiery_soul_stacks inline via the documented NPC.GetModifier +
-- Modifier.GetStackCount path (v0.5.4 lesson) and synthesises a partial ctx.
state.build_archetype_log_fields = function(ctx, force, extras)
    ctx = ctx or {}
    local f = {
        fs        = string.format("%d", ctx.fiery_soul_stacks or 0),
        fs_cap    = string.format("%d", ctx.fs_cap or 7),
        at_cap    = ctx.fs_at_cap and "1" or "0",
        fs_window = ctx.fs_shard_window and "1" or "0",
        rq        = ctx.ready_q and "1" or "0",
        rw        = ctx.ready_w and "1" or "0",
        rr        = ctx.ready_r and "1" or "0",
        ether_ok  = ctx.ether_ready and "1" or "0",
        eul_ok    = ctx.eul_ready   and "1" or "0",
        force     = force and "1" or "0",
    }
    if extras then
        for k, v in pairs(extras) do f[k] = v end
    end
    return f
end

-- HOLD with 1-2 enemies. Per-tick archetype ladder (COMBO_PATTERN.md).
state.lina_starter_tick = function(force)
    if not self_alive_ok() then return end
    -- v0.5.5 (Fiery Soul stack-awareness): when stacks are at cap (7 base, or 12
    -- during the 5s post-R Shard window), suppress stack-building archetypes
    -- (sustain_qw here, tf_sustain in TF) in favour of finishers / burst. Cap
    -- state is computed in build_layer1_ctx; this toggle (Brain > Core, default
    -- ON) only changes the dispatch gate.
    local cap_aware = true  -- v0.5.171: fs_cap_aware hardcoded ON (menu-simplification)
    local in_lock = layer1_in_lock()
    if in_lock and state.last_layer1_was_r then return end  -- hard R lock
    local r_finish_only = in_lock                            -- light lock: only the finisher

    local target = pick_offense_target()
    if not target then tlog(3, "lina_starter", { decision = "idle", reason = "no_target" }); return end

    local ctx = build_layer1_ctx(target)
    local fast = (target and NPC.GetMoveSpeed and (NPC.GetMoveSpeed(target) or 0) >= 290) or false
    local target_fleeing_fast = ctx.kiting_us and fast and (ctx.eff_hp_magical <= ctx.r_impact_eff)

    -- v0.5.95 brain-cast blink-in (re-enabled, crash-fixed): when the target is
    -- OUT of W range and the Blink Dagger is READY (= the engine did NOT use it),
    -- blink to W-range; next tick the in-range ladder fires the burst. try_blink_in
    -- reserves the dagger if a threat is incoming (leaves it for the engine's
    -- dodge), and tags brain_blinked_t so v0.5.94 capitalize does not double-fire.
    -- If the engine DID blink (dagger on CD), this is skipped and capitalize covers
    -- it instead. Only when out of range (in-range combos are unchanged).
    if not ctx.in_w_range then
        local kill_confirmed = ctx.combo_kill or ctx.r_alone_kill
        if state.try_blink_in(ctx, ctx.t_pos or Entity.GetAbsOrigin(target),
                              uname(target), kill_confirmed, 1) then
            return
        end
    end

    -- Wind Waker dual role: it is both a cyclone SETUP source and Lina's top
    -- defensive SAVE. Reserve 175 mana for it on combos that do NOT spend it
    -- (Gate 11: never die with a usable save); the WW-cyclone combo spends it,
    -- so it carries no buffer. Also refuse the WW-cyclone setup while a
    -- gap-close threat is armed (keep WW for the save).
    local ww_item    = NPCLib.item(state.self_npc, "item_wind_waker")
    local ww_ready   = NPCLib.item_ready(state.self_npc, "item_wind_waker")
    local in_ww_range = ctx.d <= cast_range_of(ww_item, FALLBACK_RANGES.WW)
    -- v0.5.4 (Bug B6 / Gate 11): armed_threats only covers HOMING threats
    -- (Bara charge, Tusk snowball, PA blink) - TARGETED instant-cast hard-
    -- disables (Lion Hex, Doom, Lion Finger) land via OnModifierCreate
    -- without arming, so the homing-only gate let ww_wrq spend WW offensively
    -- while a Hex/Doom/Finger landed moments later with no WW left for the
    -- save chain. Extend the gate with a recent-threat-mark window scanned
    -- off state.responded_threats (stamped by both the threat_on_self and
    -- enemy_buff_* branches in OnModifierCreate); 1.5s covers the cast point
    -- of every targeted hard-disable Lina cares about.
    -- v0.5.37 PERF-06: replaced O(N) scan of state.responded_threats with the
    -- O(1) Dedup.last_mark_t() global recency cursor. Dedup.gc bounds the table
    -- to a 5s window but it still grows to dozens of entries mid-fight, and this
    -- runs every ~33ms in the starter. The cursor is stamped inside
    -- Dedup.threat_mark_responded so it tracks the same write events the old
    -- scan iterated. Window unchanged at 1.5s.
    local _last_mark = Dedup.last_mark_t()
    local ww_recent_threat = (_last_mark ~= nil) and ((now() - _last_mark) < 1.5)
    -- v0.5.21 IMP-A6: armed_threats only fires once a homing projectile is in
    -- flight, and responded_threats only stamps AFTER a cast lands. A Lion at
    -- 800u with Hex off-cooldown is a QUEUED WW spend the homing-only / post-
    -- cast gates both miss, so ww_wrq can burn the save offensively moments
    -- before the Hex lands with no WW left. Scan enemy heroes within ~1100u
    -- (Hex/Doom/Finger cast ranges ~700-900u + buffer); if any has a slot in
    -- ABILITY_TO_THREAT off-cooldown and ready, hold WW. Pattern mirrors
    -- Sniper.lua L7377-7388 enemy_has_ready_target_threat (pcall-wrapped
    -- GetAbilityByIndex / GetLevel / IsReady / GetName).
    -- v0.5.24 PERF-02: 5Hz throttle. Hex/Doom/Finger CDs are 12-100s so a 0.2s
    -- sample is invisible; saves ~60 pcalls/tick (5 enemies x 6 slots x 2)
    -- while the combo_key is held. Cached bool feeds ww_threatened below.
    -- v0.5.103: scan body extracted to state.enemy_ready_threat_nearby (same
    -- 5Hz memo, same 1100u radius, same ABILITY_TO_THREAT ready check) so the
    -- committed-attacker cyclone reserve gate shares it. Behaviour-identical.
    local ww_ready_threat_in_range = state.enemy_ready_threat_nearby()
    local ww_threatened = (next(state.armed_threats) ~= nil) or ww_recent_threat or ww_ready_threat_in_range
    -- #7: only spend WW offensively when Lina is healthy (it is her top save).
    local me_hp    = (Entity.GetHealth and Entity.GetHealth(state.self_npc)) or 0
    local me_hpmax = (Entity.GetMaxHealth and Entity.GetMaxHealth(state.self_npc)) or 1
    local ww_healthy = (me_hpmax > 0) and (me_hp / me_hpmax) > 0.5
    -- #6: do not cyclone a target an ally is already attacking (it would
    -- invuln-save the enemy from the ally's kill); fall to bare WQR instead.
    local cyclone_safe = not ally_committing_on(target)
    -- Reserve WW's save mana only when WW is actually castable now; on cooldown
    -- it cannot save, so the reserve would needlessly suppress the burst.
    local save_buffer = (ww_ready and 175) or 0
    local combo_mana  = ability_mana(A.W) + ability_mana(A.Q) + ability_mana(A.R)
    local cost_ether = item_mana("item_ethereal_blade") + combo_mana + save_buffer
    local cost_eul   = item_mana("item_cyclone")        + combo_mana + save_buffer
    local cost_ww    = item_mana("item_wind_waker")     + combo_mana  -- WW is the setup; no buffer
    local cost_wqr   = combo_mana + save_buffer

    -- Dynamic per-setup-item burst. HOLD = commit (Lina is an INITIATOR), so the
    -- burst gates on RANGE + kit + mana, NOT on the enemy attacking Lina (the
    -- old `committed` gate was Sniper reactive-kiter semantics; v0.3.1 demo
    -- showed it stuck on sustain_qw, committed=0 vs a non-attacking Crystal
    -- Maiden). Setup priority: Ethereal (fast, -30 MR amp) > Eul cyclone (lock)
    -- > Wind Waker cyclone (lock, but SPENDS the top save -> last + threat
    -- guard) > bare WQR. force_key overrides fleeing. r_finisher / r_first_rwq
    -- bracket the burst. (v0.3.4: dropped the r_ok_range gate - it only blocked
    -- r_finisher while wqr fired R anyway; hold = commit R when it kills.)
    local archetype, steps
    -- v0.5.21 IMP-A10: ether_wqr setup-necessity gate. Ethereal costs ~150
    -- mana on top of WQR and has a 4s lockout once consumed; spending it on a
    -- naked-resist target that bare WQR would already kill is pure waste of a
    -- finisher amp we may need next fight. Necessity = (a) target carries
    -- notable magic resist (>= 25%) so the -30 MR amp lands meaningful extra
    -- damage, OR (b) bare WQR does not kill (impact+burn under-shoots
    -- eff_hp_magical), in which case the amp is doing the kill work. If the
    -- canonical API NPC.GetMagicalResist is missing on this build, we fall
    -- back to ether_needed=true (preserve prior behaviour, no silent no-op).
    --
    -- v0.5.28 task-9 diagnostic: task-5 C4 testing showed `archetype=wqr` for
    -- Anti-Mage (high-MR target) when spec called for `ether_wqr`. The API
    -- exists per types/uczone_discovered_stubs.lua:119 (returns number), and
    -- the L2717 short-circuit means we ARE reaching the body (otherwise the
    -- fallback ether_needed=true would have stuck and we'd see ether_wqr).
    -- So the API returns a number below 0.25 for AM somehow. Instrument:
    -- emit once per unique enemy hero per session at level 1 with raw return
    -- value + type + decision context, so the next test session surfaces the
    -- actual contract. Used to drive the v0.5.29 fix (correct API name,
    -- threshold bump per RPR-04, or fallback-on-zero handling).
    local ether_needed = true
    if ctx.ether_ready and NPC.GetMagicalResist then
        local ok, mr = pcall(NPC.GetMagicalResist, target)
        local mr_val = (ok and type(mr) == "number") and mr or nil
        local mr_significant  = (mr_val ~= nil) and (mr_val >= 0.25) or false
        -- v0.5.96 fix: despite the name this compared eff_hp vs R-ALONE (r_impact),
        -- not the W+Q+R combo it gates -- so on a low-MR target that R alone cannot
        -- one-shot but the bare WQR combo WOULD kill, it set ether_needed and burned
        -- Ethereal (4s lockout, ~150 mana) on a kill the un-amplified combo already
        -- secures (contra the v0.5.21 IMP-A10 intent). combo_kill (eff_hp <=
        -- combo_total, set unconditionally above) is the correct predicate.
        local wqr_undershoots = not ctx.combo_kill
        if mr_val ~= nil then
            ether_needed = mr_significant or wqr_undershoots
        end
        -- v0.5.86 cleanup: removed the one-shot imp_a10_mr_probe diagnostic +
        -- its state.imp_a10_probed_once latch. The NPC.GetMagicalResist contract
        -- is known/stable; the probe was dead weight in the ether gate.
    end
    -- v0.5.79 feature C + v0.5.85: Ethereal+R kill-confirm. ether_wqr spends
    -- Ethereal (4s lockout) + the full W/Q/R combo, and Ethereal amplifies ALL
    -- magic damage on the target -- so the confirm measures the amplified FULL
    -- COMBO (combo_total = R + Q + W), not R alone (the v0.5.79 R-only form was
    -- too strict and suppressed legit W+Q+R kills). On failure the ladder falls
    -- through to eul/ww/wqr -- Lina STILL engages but preserves the ethereal
    -- finisher for a confirmed kill. Toggle (default ON) gates the whole check;
    -- a tlog records each suppression for demo tuning.
    local ether_kill_ok = true
    local kill_confirm_on = true  -- v0.5.171: ether_kill_confirm hardcoded ON (menu-simplification)
    if kill_confirm_on and ctx.ether_ready then
        -- v0.5.153: combo_total_eff already folds the FC x1.35 (active-only), so
        -- this stacks FC x Ether multiplicatively; FC off -> combo_total_eff ==
        -- combo_total -> unchanged from v0.5.152.
        local amplified = (ctx.combo_total_eff or ctx.combo_total or 0) * (1 + ETHER_MAGIC_AMP)
        ether_kill_ok = (ctx.eff_hp_magical or math.huge) <= amplified
        if not ether_kill_ok then
            tlog(2, "ether_kill_confirm_skip", {
                eff_hp      = string.format("%.0f", ctx.eff_hp_magical or 0),
                combo_total = string.format("%.0f", ctx.combo_total or 0),
                fc_mult     = string.format("%.2f", ctx.fc_amp_mult or 1.0),
                amplified   = string.format("%.0f", amplified),
                amp         = string.format("%.2f", ETHER_MAGIC_AMP),
            })
        end
    end
    -- v0.5.100 Note 1b: hoisted setup gates (shared by the ladder branches +
    -- the ladder-miss diag below; the expressions are unchanged from the old
    -- inline forms) + the fleeing preference. The cyclone combo is IDEAL on a
    -- FLEEING target: the 2.5s hold lets Lina catch up and the landing
    -- re-stun keeps it dead-center for R+Q. So when the target is moving
    -- away (framework Target.IsKitingUs signal, already in ctx.kiting_us)
    -- and a cyclone item passes its gates, eul_wrq/ww_wrq are preferred
    -- ABOVE ether_wqr - ether has no lock, so a fleeing target walks out of
    -- the un-locked W/Q while the amp goes to waste. Non-fleeing ladder
    -- order is unchanged.
    -- v0.5.110.2 offensive cyclone reserve (demo death: the eul_wrq combo
    -- burned Eul on the lethal Mars at t=250.2; when the lethal arm needed
    -- a save the chain found nothing and Lina died). Cyclones are
    -- DODGE/SAVE items first (the v0.5.103 rule, now enforced on the
    -- OFFENSIVE ladder too): while a LETHAL committed attacker window is
    -- live (state.lethal_committed_until, stamped in scan_and_arm) or any
    -- armed threat row exists, eul_wrq/ww_wrq are off the table and the
    -- ladder falls through to ether_wqr/wqr with the cyclone kept in hand
    -- for the defensive chain.
    local cyclones_reserved = (next(state.armed_threats) ~= nil)
        or ((state.frame_t or 0) < (state.lethal_committed_until or 0))
    if cyclones_reserved and (ctx.eul_ready or ww_ready)
       and (state.frame_t or 0) - (state.cyclone_reserve_diag_t or 0) > 1.0 then
        state.cyclone_reserve_diag_t = state.frame_t or 0
        tlog(2, "cyclone_offense_reserved", {
            armed  = next(state.armed_threats) and "y" or "n",
            lethal = ((state.frame_t or 0) < (state.lethal_committed_until or 0)) and "y" or "n",
        })
    end
    local eul_ok   = (ctx.eul_ready and ctx.in_eul_range and cyclone_safe and not cyclones_reserved and ctx.ready_r and ctx.ready_w and ctx.mana >= cost_eul) or false
    local ww_ok    = (ww_ready and in_ww_range and not ww_threatened and ww_healthy and cyclone_safe and not cyclones_reserved and ctx.ready_r and ctx.ready_w and ctx.mana >= cost_ww) or false
    local ether_ok = (ctx.ether_ready and ctx.in_ether_range and ctx.in_w_range and ctx.ready_r and ctx.ready_w and ctx.mana >= cost_ether and ether_needed and ether_kill_ok) or false
    local target_is_fleeing = ctx.kiting_us or false
    -- v0.5.15 IMP-A2: pick_offense_target prefers attackers/nearest, but the
    -- finisher wants the lowest-eff-HP killable-in-R-range enemy (which may be
    -- a different hero entirely). Rebuild layer1 ctx only on a target swap;
    -- then gate on the swapped ctx so r_alone_kill / in_r_range / block-check
    -- all reflect the actual R target.
    local r_finisher_tgt = pick_r_finisher_target()
    -- v0.5.37 PERF-08: scratch-ctx aliasing fix. The default build path
    -- writes into state.scratch_ctx, so a second build_layer1_ctx call
    -- (the rare r_finisher-target swap, per the bridge ~3% of ticks)
    -- would clobber the first ctx BEFORE fire_steps -> schedule_step
    -- snapshots either one. Pass a fresh `{}` for the swap case so r_ctx
    -- and ctx point at distinct tables; the non-swap branch keeps r_ctx
    -- aliased to ctx (= scratch) as before.
    local r_ctx = (r_finisher_tgt and r_finisher_tgt ~= target) and build_layer1_ctx(r_finisher_tgt, {}) or ctx
    if r_finisher_tgt and r_ctx.r_alone_kill and r_ctx.ready_r and r_ctx.in_r_range and not r_target_blocked(r_ctx) then
        archetype, steps = "r_finisher", state.build_lina_r_finisher_steps(r_ctx)
    elseif r_finish_only then
        tlog(3, "lina_starter", { decision = "throttled", lock = "seq" }); return
    elseif target_is_fleeing and (eul_ok or ww_ok) then
        -- v0.5.100 Note 1b: fleeing target -> the cyclone lock beats the
        -- ether amp (Eul preferred over WW when both pass; WW is the save).
        archetype = eul_ok and "eul_wrq" or "ww_wrq"
        steps = state.build_lina_cyclone_wrq_steps(ctx, eul_ok and "item_cyclone" or "item_wind_waker")
        tlog(2, "cyclone_flee_pref", { archetype = archetype, target = uname(target) })
    elseif ether_ok then
        archetype, steps = "ether_wqr", state.build_lina_ether_wqr_steps(ctx)
    elseif eul_ok then
        archetype, steps = "eul_wrq", state.build_lina_cyclone_wrq_steps(ctx, "item_cyclone")
    elseif ww_ok then
        archetype, steps = "ww_wrq", state.build_lina_cyclone_wrq_steps(ctx, "item_wind_waker")
    elseif ctx.ready_w and ctx.ready_r and ctx.in_w_range and ctx.mana >= cost_wqr and not (target_fleeing_fast and not force) then
        archetype, steps = "wqr", state.build_lina_wqr_steps(ctx)
    elseif ctx.ready_r and ctx.in_r_range and target_fleeing_fast and not r_target_blocked(ctx) then
        archetype, steps = "r_first_rwq", state.build_lina_r_first_rwq_steps(ctx)
    else
        -- v0.5.15 OBS-03 (ladder-miss diag): every higher-tier gate failed,
        -- log per-tier ok bits so the trace explains WHY we landed on sustain.
        tlog(3, "lina_starter_ladder_miss", {
            ether_ok = ether_ok and "y" or "n",
            eul_ok   = eul_ok and "y" or "n",
            ww_ok    = ww_ok and "y" or "n",
            wqr_ok   = (ctx.ready_w and ctx.ready_r and ctx.in_w_range and ctx.mana >= cost_wqr and not (target_fleeing_fast and not force)) and "y" or "n",
            fleeing  = target_is_fleeing and "y" or "n",
        })
        -- v0.5.34 task starter-cap: REPLACES the v0.5.7 (B1/C1) hard-return
        -- suppression. The original comment ("let the dispatcher fall through to
        -- higher-tier archetypes / auto-R kill-steal") didn't hold: this branch
        -- only runs AFTER every higher-tier gate already missed (see the
        -- lina_starter_ladder_miss tlog above), so there's nothing to fall
        -- through to - the brain just went silent. In the v0.5.33 demo this
        -- produced 1179 silent starter ticks (99% of resolved starter outcomes).
        -- New behaviour mirrors v0.5.26 IMP-A4 (TF positive cap): at fs_at_cap
        -- with the cap_aware toggle ON, re-aim W at the densest enemy cluster
        -- centroid (max-stun midpoint) and Q at the lowest-eff-HP enemy in Q
        -- range (priority kill / finish). Both helpers were already on hand:
        -- state.enemy_cluster_center (v0.5.24 PERF-03 memoised) and
        -- state.pick_q_priority_kill (v0.5.26 Item 2). When cap_aware is OFF
        -- or fs_at_cap is false, q_priority/w_cluster stay nil and the
        -- builder falls back to the pre-v0.5.34 single-target engagement aim.
        local q_priority_at_cap, w_cluster_at_cap = nil, nil
        if cap_aware and ctx.fs_at_cap then
            q_priority_at_cap = state.pick_q_priority_kill(state.self_npc, Q_LENGTH)
            local center, _ = state.enemy_cluster_center(state.self_npc)
            if center then w_cluster_at_cap = center end
        end
        archetype = (q_priority_at_cap or w_cluster_at_cap) and "sustain_qw_cap" or "sustain_qw"
        steps = state.build_lina_sustain_qw_steps(ctx, q_priority_at_cap, w_cluster_at_cap)
    end

    if not steps or #steps == 0 then
        -- v0.5.15 OBS-03 (skip diag): builder returned empty (no affordable /
        -- in-range W or Q), surface the gate state so the trace is not silent.
        tlog(2, "lina_starter_skip", {
            reason = "no_steps_built",
            archetype = archetype,
            ctx_w = ctx.ready_w and "y" or "n",
            ctx_q = ctx.ready_q and "y" or "n",
            ctx_r = ctx.ready_r and "y" or "n",
            mana  = string.format("%.0f", ctx.mana or 0),
            in_w  = ctx.in_w_range and "y" or "n",
            in_r  = ctx.in_r_range and "y" or "n",
        })
        return
    end
    -- #8: tell the user WHY it is only poking - the burst is ready (W+R+mana)
    -- but the target is outside W's 700u; step closer to fire WQR. v0.5.34
    -- task starter-cap: also fire the hint for the new sustain_qw_cap label.
    if (archetype == "sustain_qw" or archetype == "sustain_qw_cap")
       and ctx.ready_w and ctx.ready_r and ctx.mana >= cost_wqr and not ctx.in_w_range then
        tlog(2, "lina_starter_hint", { reason = "out_of_w_range",
            d = string.format("%.0f", ctx.d), w_range = string.format("%.0f", ctx.w_range) })
    end
    local is_r = (archetype == "r_finisher" or archetype == "ether_wqr"
                  or archetype == "eul_wrq" or archetype == "ww_wrq"
                  or archetype == "wqr" or archetype == "r_first_rwq")
    tlog(1, "lina_starter", { archetype = archetype, target = uname(target),
        d = string.format("%.0f", ctx.d),
        r_kill = ctx.r_alone_kill and "1" or "0", mana = string.format("%.0f", ctx.mana) })
    -- v0.5.33 task-15: Flame Cloak offensive pre-amp. When the dispatcher
    -- resolved to a burst archetype (ether_wqr / eul_wrq / ww_wrq / wqr /
    -- r_first_rwq), fire FC first via a SEPARATE state.fire_steps call so
    -- pending_steps_tick serializes FC->burst in the same tick chain. FC is
    -- instant-cast (KV AbilityCastPoint=0) so the +35% spell amp lands
    -- before W on the next tick. Skip r_finisher (R alone kills, FC waste)
    -- and sustain_qw (no commit). Skip during fs_shard_window (FC sets
    -- stacks to 7 base cap, would downgrade the 12 shard cap). Skip when
    -- already buffed (flame_cloak_active) or channelling. 1.5s throttle
    -- against order-resolve race per FC-B-04.
    local is_burst_arch = (archetype == "ether_wqr" or archetype == "eul_wrq"
                           or archetype == "ww_wrq" or archetype == "wqr"
                           or archetype == "r_first_rwq")
    local fc_menu_on = state.menu and state.menu.fc_offensive_use
                       and state.menu.fc_offensive_use:Get()
    local fc_throttled = (now() - (state.last_fc_dispatch_t or 0)) < 1.5
    local fc_cost = ctx.flame_cloak_ready and ability_mana(A.FC) or 0
    local want_fc = fc_menu_on and is_burst_arch
                    and state.fc_offense_ttk(ctx, target)  -- v0.5.156: TTK gate (1-2 starter path: secures or accelerates the kill)
                    and (state.fc_defense_claim(ctx) ~= "A")  -- v0.5.158 A1: stand down when FC is the lethal-magic lifeline
                    and (not state.fc_escape_active(ctx))  -- v0.5.16x Phase B: stand down while FC is the escape lifeline
                    and state.fc_offense_commit_ok(ctx, target)  -- v0.5.159 A2: turnable + insured commit (sec 5)
                    and ctx.flame_cloak_ready
                    and not ctx.flame_cloak_in_flight  -- v0.5.34 task E (was flame_cloak_active)
                    and not ctx.is_channelling
                    and not ctx.fs_at_cap
                    and not ctx.fs_shard_window
                    and not fc_throttled
                    and ctx.mana >= (fc_cost + cost_wqr)
    if want_fc then
        -- v0.5.36: one-shot fc_status_probe so future cast_verify_double_fail
        -- FC mysteries (cf demo lockup L30442-30735) can be diagnosed from a
        -- default-level log. Captures Aghs Scepter ownership + FC handle/level/cd
        -- + ctx readiness on the first dispatch of any session, then latches.
        if not state.fc_status_probed then
            tlog(1, "fc_status_probe", {
                ability_level = tostring(Ability.GetLevel(ability(A.FC)) or -1),
                scepter_owned = NPCLib.item(state.self_npc, "item_ultimate_scepter") and "y" or "n",
                fc_handle_valid = (ability(A.FC) ~= nil) and "y" or "n",
                fc_cd = string.format("%.2f", (Ability.GetCooldown and ability(A.FC) and Ability.GetCooldown(ability(A.FC)) or -1)),
                flame_cloak_ready = ctx.flame_cloak_ready and "y" or "n",
                flame_cloak_active = ctx.flame_cloak_active and "y" or "n",
                flame_cloak_in_flight = ctx.flame_cloak_in_flight and "y" or "n",
            })
            state.fc_status_probed = true
        end
        local _ce = state.fc_commit_last or {}
        state.fc_arbiter_log({  -- v0.5.16x D4: unified decision line (was lina_flame_cloak_offensive)
            tier = "kill", reason = "ttk",
            keff = _ce.keff, ae = _ce.ae, ee = _ce.ee, bailout = _ce.insured,
            stacks = ctx.fiery_soul_stacks or 0, fired = true,
        })
        -- v0.5.40 A6-1: route Layer-1 offensive FC through dispatcher with a
        -- synthetic mod key so offensive + defensive FC fires share the same
        -- lock domain (single-spend invariant). caster == target == self_npc.
        -- All upstream gates (want_fc) already passed; thunk fires and returns
        -- true unconditionally (state.fire_steps has no return value, so the
        -- explicit return true keeps the dispatcher lock HELD per v0.5.40
        -- verifier finding). Lock TTL = 1.9 + 0.3 = 2.2s (eta_resolver by A0).
        local _a6_fired = defense_dispatcher:Dispatch(
            "lina_fc_offensive_pre_combo",
            "lina_fc_offensive_pre_combo",
            state.self_npc,
            state.self_npc,
            function(_intent, _mod, _caster)
                state.fire_steps("starter_flame_cloak_pre_" .. archetype,
                    state.build_lina_flame_cloak_steps(ctx), ctx)
                return true
            end,
            nil, "lina_flame_cloak", nil, nil,
            { fs_shard_window = fs_shard_window_active() })  -- v0.5.40 B2 GAP-3 (offensive gate above already vetoed in-window; redundant but uniform)
        state.last_fc_dispatch_t = now()
        -- DO NOT mark_layer1 for FC per FC-C-05: FC is a precondition
        -- co-cast, not an archetype. The burst archetype below owns the
        -- lock window via its own mark_layer1 call.
    end
    state.fire_steps("starter_" .. archetype, steps, ctx)
    mark_layer1("starter_" .. archetype, is_r)
end

-- Teamfight targeting is DECOUPLED (pro Lina play, web-researched 2026-05-28):
-- W/Q hit the densest enemy CLUSTER (AoE stun + nuke on the pile), R snipes the
-- highest-VALUE target (lowest effective magical HP = the squishy backliner R
-- one-shots), NOT the frontline tank. The old most-allied-attackers focus
-- picked the tank and put W/Q/R all on it.

-- Densest W-AoE (250u) enemy cluster: returns (center Vector, count).
state.enemy_cluster_center = function(me)
    -- v0.5.24 PERF-03: per-tick memo. Called 1-3x per TF tick (tf_w_aim,
    -- tf_q_aim, lina_teamfight_tick); each call ran GetHeroesInRadius + O(N^2).
    -- Cache keyed on now() with 1ms epsilon so all calls within the same
    -- frame share one result. Dota tick is ~33ms so the cache never bleeds.
    local frame_t = now()
    if state.cluster_cache_t and (frame_t - state.cluster_cache_t) < 0.001 then
        return state.cluster_cache_center, state.cluster_cache_n or 0
    end
    local list = Entity.GetHeroesInRadius(me, state.COMBO_CLASSIFY_RADIUS, Enum.TeamType.TEAM_ENEMY)
    if not list then
        state.cluster_cache_t, state.cluster_cache_center, state.cluster_cache_n = frame_t, nil, 0
        return nil, 0
    end
    local pts, ents = {}, {}
    for i = 1, #list do
        local e = list[i]
        -- Only count enemies W can actually affect: magic-immune enemies take
        -- no stun/damage and give no Fiery Soul stack, so they must not pull
        -- the cluster center toward themselves.
        if e and Target.IsAlive(e) and Target.NotIllusion(e)
           and not NPC.HasState(e, MS.MODIFIER_STATE_MAGIC_IMMUNE) then
            local p = Entity.GetAbsOrigin(e)
            if p then pts[#pts + 1] = p; ents[#ents + 1] = e end
        end
    end
    if #pts == 0 then
        state.cluster_cache_t, state.cluster_cache_center, state.cluster_cache_n = frame_t, nil, 0
        return nil, 0
    end
    -- v0.5.178 D3b cluster value-bias: per-anchor neighbour COUNT + summed HeroValue,
    -- then a value tie-break. Each enemy's value is precomputed once (peer-relative
    -- over the live list), guarded so a missing hero_value lib degrades to pure
    -- density. best = max count, EXACT-count ties broken by higher summed value (never
    -- trades stun-count for value); pure = first max count (the geometric pick).
    -- VectorCenter centroid + count are built from the winning anchor exactly as before.
    local hv = state.hero_value
    local vals = {}
    for i = 1, #ents do vals[i] = (hv and hv.of and hv.of(ents[i], list)) or 0 end
    local counts, sums = {}, {}
    for i = 1, #pts do
        local pi = pts[i]
        local n, sv = 0, 0
        for j = 1, #pts do
            if pi:Distance2D(pts[j]) <= 250 then n = n + 1; sv = sv + vals[j] end
        end
        counts[i], sums[i] = n, sv
    end
    local best_idx, pure_idx
    if hv and hv.best_cluster then best_idx, pure_idx = hv.best_cluster(counts, sums) end
    if not best_idx then          -- lib absent: inline first-max-count (pre-3b behaviour)
        best_idx = 1
        for i = 2, #counts do if counts[i] > counts[best_idx] then best_idx = i end end
        pure_idx = best_idx
    end
    -- fc_cluster_flip diag (mirror of fc_aim_flip): only when value changed the pick
    -- vs the first-found densest. D3b DEMO-CONFIRMED v0.5.178.1: the always-on probe
    -- logged tied=3 chose=antimage (value 0.93) on real 3-way ties; reverted here to
    -- the lean flip-only form (the override path itself is offline-proven via best_cluster).
    if best_idx ~= pure_idx and (frame_t - (state.fc_cluster_flip_log_t or 0)) >= 1.0 then
        state.fc_cluster_flip_log_t = frame_t
        tlog(2, "fc_cluster_flip", {
            chose = uname(ents[best_idx]), chose_n = string.format("%d", counts[best_idx]),
            chose_v = string.format("%.2f", sums[best_idx]),
            over = uname(ents[pure_idx]), over_n = string.format("%d", counts[pure_idx]),
            over_v = string.format("%.2f", sums[pure_idx]),
        })
    end
    local best_anchor = pts[best_idx]
    local best_n = counts[best_idx]
    local best_members = {}
    for j = 1, #pts do
        if best_anchor:Distance2D(pts[j]) <= 250 then best_members[#best_members + 1] = pts[j] end
    end
    local center = (VectorCenter and VectorCenter(best_members)) or best_anchor
    state.cluster_cache_t = frame_t
    state.cluster_cache_center = center
    state.cluster_cache_n = best_n or 0
    return center, best_n or 0
end

-- Best TF R target: lowest effective-magical-HP enemy within R range of Lina
-- that R can hit (not magic-immune / Linkens / Lotus).
-- v0.5.21 IMP-A7: relaxed from "within cluster_radius of center" to "within
-- r_range of me" so an isolated low-eff-HP target up to the full R cast range
-- is eligible (the old gate refused to snipe anyone outside the 250u W cluster
-- even when R was off cooldown and the target was a one-shot). cluster_radius
-- is now only a tie-break weight: score = eff_hp + 0.1 * dist_from_cluster,
-- so cluster-local targets still win when eff-HP is similar and the W stun +
-- R snipe stay coincident (#3) for the common case.
state.tf_r_value_target = function(me, center, cluster_radius, r_range)
    if not center then return nil end
    -- v0.5.21 IMP-A7: query from `me` with r_range so the candidate set is
    -- everyone R can actually reach, not just the W cluster slice.
    local me_pos = NPCLib.origin(me)
    if not me_pos then return nil end
    local list = Heroes.InRadius(me_pos, r_range, Entity.GetTeamNum(me), Enum.TeamType.TEAM_ENEMY)
    if not list then return nil end
    -- v0.5.29 task-6-A diag: throttle the picked-target summary to 1Hz so the
    -- default log stays clean during sustained combo holds.
    local emit_pick_summary = (now() - (state.tf_r_pick_diag_t or 0)) > 1.0
    local best, best_score
    local best_eff, best_d_cluster, best_allies, best_bonus
    local n_candidates = 0
    for i = 1, #list do
        local e = list[i]
        if e and Target.IsAlive(e) and Target.NotIllusion(e) and Target.NotClone(e)
           and not NPC.HasState(e, MS.MODIFIER_STATE_MAGIC_IMMUNE)
           and not (Target.HasReadyLinkens and Target.HasReadyLinkens(e))
           and not (Target.HasReadyLotus and Target.HasReadyLotus(e))
           and dist_to(e) <= r_range then
            n_candidates = n_candidates + 1
            local eff = lina_eff_hp_magical(e)
            -- v0.5.21 IMP-A7: light cluster-locality tie-break. 0.1 * dist
            -- means a target 100u further from cluster center costs ~10 eff_hp,
            -- so a clearly squishier outlier still beats a cluster-local fatty
            -- while ~equal-HP candidates inside the pile win.
            local ep = NPCLib.origin(e)
            local d_cluster = (ep and ep:Distance2D(center)) or 0
            local score = eff + 0.1 * d_cluster
            -- v0.5.26 Item 1: TF ally-focus. If K.ALLY_FOCUS_COUNT (>=2) allies
            -- are attacking this candidate, subtract 200 eff_hp from the score
            -- so team focus tips the R picker. 200 is a meaningful nudge on
            -- Lina's eff_hp scale (0-2000+) without overriding a clearly
            -- squishier outlier (>200 eff_hp gap survives the bonus).
            local allies_atk = count_allies_attacking(e, me)
            local ally_bonus = 0
            if allies_atk >= K.ALLY_FOCUS_COUNT then
                score = score - 200
                ally_bonus = -200
            end
            -- v0.5.29 task-6-A diag: per-candidate at level 3 (gated by
            -- TLOG3_ENABLED so default verbosity skips the kv-table alloc).
            -- Pairs with the level-1 tf_r_value_pick summary below: at v=3
            -- you see every candidate's score components, at v=1 you see
            -- the picked target + its components only.
            if TLOG3_ENABLED then
                tlog(3, "tf_r_value_candidate", {
                    candidate        = uname(e),
                    eff_hp           = string.format("%.0f", eff),
                    d_cluster        = string.format("%.0f", d_cluster),
                    allies_attacking = tostring(allies_atk),
                    ally_bonus       = tostring(ally_bonus),
                    score            = string.format("%.0f", score),
                })
            end
            if not best_score or score < best_score then
                best_score, best = score, e
                best_eff, best_d_cluster, best_allies, best_bonus =
                    eff, d_cluster, allies_atk, ally_bonus
            end
        end
    end
    -- v0.5.29 task-6-A diag: throttled picked-target summary at level 1 so
    -- the default log surfaces the ally-focus contribution to the winning
    -- candidate without needing v=3. Pairs with tf_r_value_candidate above.
    if best and emit_pick_summary then
        state.tf_r_pick_diag_t = now()
        tlog(1, "tf_r_value_pick", {
            picked           = uname(best),
            n_candidates     = tostring(n_candidates),
            eff_hp           = string.format("%.0f", best_eff),
            d_cluster        = string.format("%.0f", best_d_cluster),
            allies_attacking = tostring(best_allies),
            ally_bonus       = tostring(best_bonus),
            score            = string.format("%.0f", best_score),
        })
    end
    return best
end

-- W (circle max-coverage) -> Q (line max-crossings) -> R@value.
-- W/Q are independent_pos: each step re-computes its aim at issue time via
-- tf_w_aim / tf_q_aim, so the placement survives the R target's death (the
-- live cluster is tracked, not a captured Vector).
-- v0.5.36: doc-comment rewrite. Prior text claimed "q_aim defaults to w_center
-- if the caller passes nil", but tf_q_aim's only argument is r_target (no
-- w_center param) and falls back to self origin when the cluster is gone.
-- Current contract: tf_q_aim / tf_w_aim re-cluster live on every issue; both
-- take r_target as a must_cover hint (nil for sustain). R is the snipe target.
-- v0.5.26 Item 2: lowest-eff-HP enemy in Q range. Used by the tf_sustain
-- cap branch to point Q at the priority kill instead of the cluster center
-- when fs_at_cap (stacks no longer marginal -> spend Q on the closer).
-- Q is AOE so Linkens/Lotus don't block; magic-immune still filters out.
state.pick_q_priority_kill = function(me, q_range)
    local me_pos = NPCLib.origin(me)
    if not me_pos then return nil end
    local list = Heroes.InRadius(me_pos, q_range, Entity.GetTeamNum(me), Enum.TeamType.TEAM_ENEMY)
    if not list then return nil end
    local best, best_eff
    for i = 1, #list do
        local e = list[i]
        if e and Target.IsAlive(e) and Target.NotIllusion(e) and Target.NotClone(e)
           and not NPC.HasState(e, MS.MODIFIER_STATE_MAGIC_IMMUNE) then
            local eff = lina_eff_hp_magical(e)
            if not best_eff or eff < best_eff then
                best, best_eff = e, eff
            end
        end
    end
    return best
end

-- v0.5.26 Item 2: q_priority_target (optional) is a unit handle. When set,
-- Q's arg returns that unit's position directly (priority kill at fs_at_cap),
-- bypassing the cluster-line tf_q_aim geometry. When nil, Q falls back to
-- the cluster-line aim. W and R unchanged.
state.build_lina_tf_steps = function(r_target, q_priority_target)
    -- v0.5.39 P1-DRY-R-DEFLECT: r_ok delegates entirely to r_target_blocked
    -- (file-local, defined above) so the starter and TF gates share a single
    -- source of truth for IsEntity / IsAlive / magic-immune / Linkens / Lotus
    -- / SPELL_DEFLECT_MODIFIERS. Logically identical to the previous inline
    -- check; pre-v0.5.39 the deflect iteration was duplicated here.
    local function r_ok() return not r_target_blocked({ target = r_target }) end
    return {
        { ability = A.W, kind = "pt", short = "w", independent_pos = true,
          arg = function() return state.tf_w_aim(r_target) end, delay_s = 0,
          cond = function(c) return c.ready_w and c.mana >= ability_mana(A.W) end },
        { ability = A.Q, kind = "pt", short = "q", independent_pos = true,
          arg = function()
              if q_priority_target and Entity.IsEntity(q_priority_target)
                 and Target.IsAlive(q_priority_target) then
                  return Entity.GetAbsOrigin(q_priority_target)
              end
              return state.tf_q_aim(r_target)
          end, delay_s = 0.1,
          cond = function(c) return c.ready_q and c.mana >= ability_mana(A.Q) end },
        { ability = A.R, kind = "ut", short = "r",
          arg = function() return r_target end, delay_s = 0.4, cond = r_ok },
    }
end

-- HOLD with 3+ enemies. W/Q ALWAYS hit the densest enemy cluster (max Fiery
-- Soul stacks per enemy + AoE stun + Slow Burn DoT); R snipes the cluster-LOCAL
-- lowest-eff-HP target so the W stun and the R snipe coincide (#3/#4). tf_r and
-- tf_burst are merged: the burst always W+Q's the pile, so an R-alone kill also
-- racks the pile. Isolated low targets -> the always-on auto-R kill-steal.
-- v0.5.7 (E7 / C3): Lesson 33 - every TF early-return now emits a level-2
-- `lina_teamfight_skip` tlog with the refusal reason + minimal ctx so a default
-- log can answer "why didn't TF fire here?" without a re-run at higher verbosity.
-- The three success paths (tf_q_poke / tf_burst / tf_sustain) keep their existing
-- level-1 `lina_teamfight` archetype logs untouched.
state.lina_teamfight_tick = function(force)
    if not self_alive_ok() then
        tlog(2, "lina_teamfight_skip", { reason = "not_self_alive" }); return
    end
    local in_lock = layer1_in_lock()
    if in_lock and state.last_layer1_was_r then
        tlog(2, "lina_teamfight_skip", { reason = "hard_r_lock" }); return  -- hard R lock
    end
    local me = state.self_npc
    -- v0.5.15 IMP-A4 (cap_aware in TF): mirror the starter's read so the TF
    -- branch can honor fs_at_cap (widen r_worth to force burst, suppress sustain).
    local cap_aware = true  -- v0.5.171: fs_cap_aware hardcoded ON (menu-simplification)

    local cluster_center, cluster_n = state.enemy_cluster_center(me)  -- non-immune only
    if not cluster_center then
        tlog(2, "lina_teamfight_skip", { reason = "no_cluster" }); return
    end
    local me_pos = NPCLib.origin(me)
    local w_range = cast_range_of(ability(A.W), FALLBACK_RANGES.W)
    local cluster_in_range = me_pos and me_pos:Distance2D(cluster_center) <= w_range
    if not cluster_in_range then
        -- W (700) cannot reach the pile, but Q (1075) might still poke it for
        -- Fiery Soul stacks + Slow Burn chip. One throttled Q at the line-aim.
        local q_range = cast_range_of(ability(A.Q), FALLBACK_RANGES.Q)
        local mana    = (NPC.GetMana and NPC.GetMana(me)) or 0
        local q_in_range = me_pos and me_pos:Distance2D(cluster_center) <= q_range
        -- v0.5.95.2 TF blink-in (FIXED placement): the cluster is OUT of W range
        -- here, so THIS is where a brain-cast blink must gap-close it. The v0.5.92
        -- block was wrongly placed AFTER this early-return, so it only ran when
        -- already in range and never blinked an out-of-range cluster in. Try to
        -- blink; if it fires, return (next tick we are in W range -> tf_burst),
        -- else fall through to the Q poke. try_blink_in self-gates on toggle /
        -- dagger-ready / reserve-for-defense, so this is a no-op when OFF.
        do
            local r_range_b = cast_range_of(ability(A.R), FALLBACK_RANGES.R)
            local kc = state.tf_r_value_target(me, cluster_center, 250, r_range_b) ~= nil
            if state.try_blink_in({ mana = mana }, cluster_center, "cluster", kc, cluster_n or 1) then
                return
            end
        end
        if not layer1_in_lock() and ability_ready(A.Q) and q_in_range
           and mana >= ability_mana(A.Q) then
            -- v0.5.21 IMP-A5: tf_q_poke is purely stack-feeding (Q at distant
            -- cluster, no W follow-up); at Fiery Soul cap it has zero marginal
            -- value (stacks discarded, mana wasted). ctx is not built yet on
            -- this branch, so fs_at_cap is computed via the same helper that
            -- build_layer1_ctx uses (v0.5.36 MAINT-13). Previously this site
            -- duplicated the lookup with hardcoded base=7 / shard=12 and so
            -- silently bypassed the v0.5.21 PT-13 KV-read for
            -- fiery_soul_max_stacks. compute_fs_state honours the KV + shard
            -- window + diag tlog.
            local fs_state_local = state.compute_fs_state(me)
            if cap_aware and fs_state_local.at_cap then
                tlog(2, "lina_teamfight_skip", { reason = "tf_q_poke_suppressed_fs_at_cap" })
                return
            end
            tlog(1, "lina_teamfight", { archetype = "tf_q_poke", cluster = string.format("%d", cluster_n) })
            state.fire_steps("tf_tf_q_poke", {
                { ability = A.Q, kind = "pt", short = "q", independent_pos = true,
                  arg = function() return state.tf_q_aim(nil) end, delay_s = 0 },
            }, {})
            mark_layer1("tf_tf_q_poke", false)
        else
            tlog(2, "lina_teamfight_skip", { reason = "q_poke_unaffordable",
                cluster   = string.format("%d", cluster_n),
                q_ready   = ability_ready(A.Q) and "y" or "n",
                q_in_rng  = q_in_range and "y" or "n",
                mana_ok   = (mana >= ability_mana(A.Q)) and "y" or "n",
                in_lock   = layer1_in_lock() and "y" or "n" })
        end
        return  -- step in for the W stun; the Q poke (if any) already fired
    end

    local r_range  = cast_range_of(ability(A.R), FALLBACK_RANGES.R)
    local r_target = state.tf_r_value_target(me, cluster_center, 250, r_range)  -- cluster-local snipe

    local ctx = build_layer1_ctx(r_target or pick_offense_target())
    if not ctx.target then
        tlog(2, "lina_teamfight_skip", { reason = "no_targetable_target",
            cluster = string.format("%d", cluster_n) }); return  -- only magic-immune enemies present
    end

    -- v0.5.39 BUG-1: TF-opener FC pre-amp. The v0.5.33 tf_burst site requires
    -- r_worth (kill-budget), which is false at T=0 of an engagement (backliner
    -- full-HP). FC never preceded the engage. Fire FC here at fight start when
    -- the player is committing: cluster_n >= 3, W+R ready, FC ready, mana
    -- covers FC+W+Q+R. Per-engagement latch prevents double-fire inside one
    -- fight. Existing tf_burst FC block is gated with "not fc_tf_opener_fired"
    -- so the second FC commit waits for a new engagement (>=4s TF tick gap).
    local FC_OPENER_REARM_GAP_S = 4.0
    -- v0.5.40.3: FC is a KILL-ACCELERATION tool when Aghs is owned. The
    -- +35% spell amp + +35% magic resistance + uninterrupted movement for
    -- 7s lets Lina burst down targets faster, which in turn refreshes FS
    -- stacks through W/Q kills. Per user spec: use FC to eliminate targets
    -- as fast as possible, especially in teamfights. Therefore:
    --   - v0.5.39 BUG-1 `cluster_n >= 3` requirement DROPPED. FC pre-amps
    --     burst even on single targets - the spell amp matters for a 1v1
    --     ult-kill as much as for a 1v3 cleanup. With combo intent held,
    --     any enemy in TF tick range is a kill candidate.
    --   - v0.5.40 B3 GAP-5 FS-marginal floor (fs_stacks <= 4) DROPPED. The
    --     +35% spell amp value dominates the marginal FS-stack gain. At
    --     FS=6 firing FC gains 1 stack but enables a damage burst that
    --     kills a target, which then yields a fresh stack via W/Q kill
    --     credit - net positive even if direct FC stack gain is small.
    --   - `ctx.fs_at_cap` retained: when already at cap (7 base or 12
    --     shard) FC's set-FS-to-7 is non-additive and would DOWNGRADE the
    --     shard cap; ctx.fs_shard_window catches that branch separately.
    -- Other gates unchanged: ready_w + ready_r + mana cover + flame_cloak
    -- handle + per-engagement latch + 1.5s fc_throttle.
    local last_tf_tick = state.last_tf_tick_t or 0
    local engagement_new = (now() - last_tf_tick) >= FC_OPENER_REARM_GAP_S
    state.last_tf_tick_t = now()
    if engagement_new then state.fc_tf_opener_fired = false end

    local fc_menu_on    = state.menu and state.menu.fc_offensive_use
                          and state.menu.fc_offensive_use:Get()
    local fc_throttled  = (now() - (state.last_fc_dispatch_t or 0)) < 1.5
    local fc_cost       = ctx.flame_cloak_ready and ability_mana(A.FC) or 0
    local opener_cost   = fc_cost + ability_mana(A.W) + ability_mana(A.Q)
                          + ability_mana(A.R)
    local fc_aoe       = cluster_center and aoe_enemy_units(cluster_center, K.FC_AOE_FLIP_RADIUS) or nil  -- v0.5.160 A3.1
    local fc_flip      = state.fc_offense_value(ctx, ctx.target, fc_aoe)  -- v0.5.160 A3.1: AoE flip-count (cluster fed, was nil)
    local fc_vw_on     = true  -- v0.5.170: fc_value_weight hardcoded ON (menu-simplification)
    local fc_flip_w    = nil
    local fc_flip_ok
    if fc_vw_on then
        fc_flip_w  = state.fc_offense_value_w(ctx, ctx.target, fc_aoe)  -- v0.5.164 D1: weighted flip value
        fc_flip_ok = fc_flip_w >= K.FC_FLIP_VALUE
    else
        fc_flip_ok = fc_flip >= 1                                        -- toggle off: binary pre-D behavior
    end
    local fc_cold_open = state.fc_cold_open(ctx)                          -- v0.5.160 A3.2: low-stacks cold-open
    local want_fc_open = fc_menu_on
                          and (fc_flip_ok or fc_cold_open)                -- v0.5.164 D1: weighted flip (or binary if toggle off) OR stack cold-open
                          and (state.fc_defense_claim(ctx) ~= "A")  -- v0.5.158 A1: survival outranks the kill
                          and (not state.fc_escape_active(ctx))  -- v0.5.16x Phase B: survival outranks the kill
                          and state.fc_offense_commit_ok(ctx, ctx.target, fc_flip_w)  -- v0.5.159 A2 + v0.5.165 D2: turnable (W-modulated) + insured commit
                          and not state.fc_tf_opener_fired
                          and ctx.ready_w and ctx.ready_r
                          and ctx.flame_cloak_ready
                          and not ctx.flame_cloak_in_flight
                          and not ctx.is_channelling
                          and not ctx.fs_at_cap
                          and not ctx.fs_shard_window
                          and not fc_throttled
                          and ctx.mana >= opener_cost
    if want_fc_open then
        -- v0.5.41 FC-PROBE-COVERAGE: probe parity with tf_burst site below
        -- (L4339 pre-v0.5.41 numbering) and the starter site. v0.5.39 BUG-1's
        -- pre_tf_opener insertion bypassed both: when the opener wins the
        -- per-engagement latch (state.fc_tf_opener_fired = true), tf_burst's
        -- want_fc gate fails and its probe never fires. Restores v0.5.36
        -- intent that whichever FC dispatch fires first owns the diagnostic.
        if not state.fc_status_probed then
            tlog(1, "fc_status_probe", {
                ability_level = tostring(Ability.GetLevel(ability(A.FC)) or -1),
                scepter_owned = NPCLib.item(state.self_npc, "item_ultimate_scepter") and "y" or "n",
                fc_handle_valid = (ability(A.FC) ~= nil) and "y" or "n",
                fc_cd = string.format("%.2f", (Ability.GetCooldown and ability(A.FC) and Ability.GetCooldown(ability(A.FC)) or -1)),
                flame_cloak_ready = ctx.flame_cloak_ready and "y" or "n",
                flame_cloak_active = ctx.flame_cloak_active and "y" or "n",
                flame_cloak_in_flight = ctx.flame_cloak_in_flight and "y" or "n",
            })
            state.fc_status_probed = true
        end
        local _ce = state.fc_commit_last or {}
        state.fc_arbiter_log({  -- v0.5.16x D4: unified decision line (was lina_flame_cloak_offensive)
            tier = "kill",
            reason = fc_flip_ok and "opener" or "cold_open",  -- v0.5.168.5: label the GATE that fired (weighted flip-threshold vs stack cold-open), not the raw count
            W = fc_flip_w, count = fc_flip, cluster = cluster_n,
            keff = _ce.keff, ae = _ce.ae, ee = _ce.ee, bailout = _ce.insured,
            stacks = ctx.fiery_soul_stacks or 0, fired = true,
        })
        -- v0.5.40 A6-2: route TF opener FC through dispatcher (synthetic mod).
        -- Gates above (want_fc_open) already passed; thunk fires + returns true
        -- (state.fire_steps returns nil, explicit return true keeps lock HELD).
        local _a6_fired = defense_dispatcher:Dispatch(
            "lina_fc_offensive_pre_tf_opener",
            "lina_fc_offensive_pre_tf_opener",
            state.self_npc,
            state.self_npc,
            function(_intent, _mod, _caster)
                state.fire_steps("tf_flame_cloak_pre_opener",
                    state.build_lina_flame_cloak_steps(ctx), ctx)
                return true
            end,
            nil, "lina_flame_cloak", nil, nil,
            { fs_shard_window = fs_shard_window_active() })  -- v0.5.40 B2 GAP-3 (offensive gate above already vetoed in-window; redundant but uniform)
        state.last_fc_dispatch_t = now()
        state.fc_tf_opener_fired = true
    end

    -- v0.5.7 (E10 / B10, Gate 11): Eul (item_cyclone) is a save in the v0.5.x
    -- close_gap chain too, not only WW. When WW is on cooldown and Eul is the
    -- only remaining save, the old `ww_ready and 175 or 0` buffer dropped to 0
    -- and the TF burst could spend Lina to OOM, leaving Eul un-castable for the
    -- save chain. Reserve 175 if WW is ready (covers an Eul gap when both are
    -- ready), else 100 if Eul is ready, else 0 (nothing to reserve for).
    local save_buffer = (NPCLib.item_ready(me, "item_wind_waker") and 175)
                     or (NPCLib.item_ready(me, "item_cyclone") and 100)
                     or 0
    local cost_wqr = ability_mana(A.W) + ability_mana(A.Q) + ability_mana(A.R) + save_buffer

    -- #5 (R-economy): commit R in the TF burst only when the snipe is
    -- convertible NOW - R-alone kills it, OR R's impact damage covers the
    -- snipe's effective magical HP (kill-budget). At full HP (fight open) hold
    -- R: tf_sustain W+Q's the pile (stacks + disable + chunk), and the
    -- always-on auto-R kill-steal fires R the moment a target actually drops
    -- to a killable state.
    -- v0.5.21 IMP-A3: replace the % max-HP heuristic with a kill-budget read.
    -- The old (rt_hp / rt_max) <= 0.60 test ignored MR / barriers / regen, so
    -- it falsely greenlit R against a high-MR target at 50% HP (no kill) and
    -- gated out R against a chunked squishy at 65% HP whose eff-HP was well
    -- under R's impact. lina_r_damage() returns (impact, burn); use impact
    -- only here (matches the auto-R kill-steal stance: a heal/dispel cancels
    -- the 4s burn, so do not bank on it for the burst commit gate).
    local r_worth = false
    if r_target then
        if ctx.r_alone_kill then
            r_worth = true
        else
            local r_impact = lina_r_damage()
            local eff_hp   = lina_eff_hp_magical(r_target)
            -- v0.5.153: FC outgoing amp is target-independent; ctx.fc_amp_mult is 1.0
            -- when FC is off (unchanged from v0.5.152).
            r_worth = (r_impact * ctx.fc_amp_mult >= eff_hp)
        end
        -- v0.5.15 IMP-A4 (cap_aware in TF): at fs cap, a clean r_alone_kill is
        -- the conversion path, never let the 60% HP fallback gate it out.
        if cap_aware and ctx.fs_at_cap and ctx.r_alone_kill then
            r_worth = true
        end
    end

    -- W/Q placement is computed LIVE inside the step arg_fns (tf_w_aim / tf_q_aim,
    -- re-clustered on each (re)issue) - consistent with starter's live w_aim. See
    -- build_lina_tf_steps. cluster_center above is still used for the range gate +
    -- the r_target snipe selection.

    -- v0.5.95.2: the TF brain-cast blink-in MOVED UP into the not-cluster_in_range
    -- branch (a blink must gap-close a cluster that is OUT of W range; by this point
    -- we are already in W range, so a blink dispatch here only ever no-op'd).
    -- state.blink_in_tf_in_range is now unused (left dormant).

    -- tf_burst: W+Q on the cluster + R on the cluster-local snipe. Fires through
    -- the light (seq) lock; the R commit then hard-locks re-entry for 3s.
    -- tf_burst stays allowed to break in (higher-priority escalation over sustain).
    if ctx.ready_w and ctx.ready_r and r_target and r_worth and ctx.mana >= cost_wqr then
        tlog(1, "lina_teamfight", { archetype = "tf_burst", cluster = string.format("%d", cluster_n),
            r_target = uname(r_target), r_kill = ctx.r_alone_kill and "1" or "0" })
        -- v0.5.33 task-15 FC-C-06: TF burst gets the FC pre-amp too. Same
        -- predicate shape as the starter site - skipped during fs_shard_window,
        -- when already buffed, channelling, or throttled. tf_sustain and
        -- tf_q_poke don't get FC (no R commit -> 25s CD not worth).
        local fc_menu_on = state.menu and state.menu.fc_offensive_use
                           and state.menu.fc_offensive_use:Get()
        local fc_throttled = (now() - (state.last_fc_dispatch_t or 0)) < 1.5
        local fc_cost = ctx.flame_cloak_ready and ability_mana(A.FC) or 0
        -- v0.5.39 BUG-1: gate-out via fc_tf_opener_fired so the pre-r_worth
        -- opener-site FC owns the first FC commit in an engagement and this
        -- burst-site FC only re-fires after the per-engagement latch clears
        -- (>=4s TF-tick gap), avoiding double-spend on a 25s CD ability.
        local fc_aoe = cluster_center and aoe_enemy_units(cluster_center, K.FC_AOE_FLIP_RADIUS) or nil  -- v0.5.160 A3.1
        local fc_vw_on   = true  -- v0.5.170: fc_value_weight hardcoded ON (menu-simplification)
        local fc_burst_w = nil
        local fc_flip_ok
        if fc_vw_on then
            fc_burst_w = state.fc_offense_value_w(ctx, r_target, fc_aoe)  -- v0.5.164 D1: weighted flip value
            fc_flip_ok = fc_burst_w >= K.FC_FLIP_VALUE
        else
            fc_flip_ok = state.fc_offense_value(ctx, r_target, fc_aoe) >= 1  -- toggle off: binary pre-D
        end
        local want_fc = fc_menu_on
                        and fc_flip_ok                                            -- v0.5.164 D1: weighted flip threshold (cluster fed, or binary if toggle off)
                        and (state.fc_defense_claim(ctx) ~= "A")  -- v0.5.158 A1: survival outranks the kill
                        and (not state.fc_escape_active(ctx))  -- v0.5.16x Phase B: survival outranks the kill
                        and state.fc_offense_commit_ok(ctx, r_target, fc_burst_w)  -- v0.5.159 A2 + v0.5.165 D2: turnable (W-modulated) + insured commit
                        and not state.fc_tf_opener_fired
                        and ctx.flame_cloak_ready
                        and not ctx.flame_cloak_in_flight  -- v0.5.34 task E (was flame_cloak_active)
                        and not ctx.is_channelling
                        and not ctx.fs_at_cap
                        and not ctx.fs_shard_window
                        and not fc_throttled
                        and ctx.mana >= (fc_cost + cost_wqr)
        if want_fc then
            -- v0.5.36: see starter-site fc_status_probe comment. Same latch,
            -- so whichever FC dispatch site fires first owns the diagnostic.
            if not state.fc_status_probed then
                tlog(1, "fc_status_probe", {
                    ability_level = tostring(Ability.GetLevel(ability(A.FC)) or -1),
                    scepter_owned = NPCLib.item(state.self_npc, "item_ultimate_scepter") and "y" or "n",
                    fc_handle_valid = (ability(A.FC) ~= nil) and "y" or "n",
                    fc_cd = string.format("%.2f", (Ability.GetCooldown and ability(A.FC) and Ability.GetCooldown(ability(A.FC)) or -1)),
                    flame_cloak_ready = ctx.flame_cloak_ready and "y" or "n",
                    flame_cloak_active = ctx.flame_cloak_active and "y" or "n",
                    flame_cloak_in_flight = ctx.flame_cloak_in_flight and "y" or "n",
                })
                state.fc_status_probed = true
            end
            local _ce = state.fc_commit_last or {}
            state.fc_arbiter_log({  -- v0.5.16x D4: unified decision line (was lina_flame_cloak_offensive)
                tier = "kill", reason = "burst",
                W = fc_burst_w, count = state.fc_offense_value(ctx, r_target, fc_aoe),
                cluster = cluster_n,
                keff = _ce.keff, ae = _ce.ae, ee = _ce.ee, bailout = _ce.insured,
                stacks = ctx.fiery_soul_stacks or 0, fired = true,
            })
            -- v0.5.40 A6-3: route TF burst FC through dispatcher (synthetic mod).
            -- Gates above (want_fc) already passed; thunk fires + returns true
            -- (state.fire_steps returns nil, explicit return true keeps lock HELD).
            local _a6_fired = defense_dispatcher:Dispatch(
                "lina_fc_offensive_pre_tf_burst",
                "lina_fc_offensive_pre_tf_burst",
                state.self_npc,
                state.self_npc,
                function(_intent, _mod, _caster)
                    state.fire_steps("tf_flame_cloak_pre_burst",
                        state.build_lina_flame_cloak_steps(ctx), ctx)
                    return true
                end,
                nil, "lina_flame_cloak", nil, nil,
                { fs_shard_window = fs_shard_window_active() })  -- v0.5.40 B2 GAP-3 (offensive gate above already vetoed in-window; redundant but uniform)
            state.last_fc_dispatch_t = now()
        end
        state.fire_steps("tf_tf_burst", state.build_lina_tf_steps(r_target), ctx)
        mark_layer1("tf_tf_burst", true)
    elseif in_lock then
        tlog(2, "lina_teamfight_skip", { reason = "seq_lock_suppress_sustain",
            cluster = string.format("%d", cluster_n) }); return  -- seq lock: suppress sustain re-dispatch
    elseif #state.pending_steps > 0 then
        -- v0.5.7 E4 (A2/B3): LAYER1_COMMIT_WINDOW_SEQ=0.4s is shorter than the
        -- longest scheduled step delay (tf R-step 0.4s, ether_wqr R-step 1.0s,
        -- cyclone combos up to 3.0s), so the wall-time in_lock above lets
        -- tf_sustain re-fire while its OWN prior W/Q/R steps are still pending /
        -- in retry (demo: 3x dispatch in <1s). Gate sustain re-dispatch on the
        -- precise pending-steps predicate: only after the prior combo's steps
        -- have all landed or aborted. tf_burst (above) and r_finisher remain
        -- allowed to break in as higher-priority escalations.
        return
    elseif ctx.ready_w or ctx.ready_q then
        -- v0.5.19 (IMP-A4 partial revert): v0.5.15 suppressed tf_sustain entirely
        -- at Fiery Soul cap, which dropped W (max-targets AOE stun) and Q (highest
        -- priority nuke) in teamfights. User-confirmed expected behaviour: W and
        -- Q still fire at cap - W for stun coverage, Q for priority kill - even
        -- though stacks no longer marginal. Only the r_worth cap_aware widen at
        -- in the r_worth cap_aware widen block stays in place (lets r_alone_kill convert at cap).
        -- tf_sustain: W/Q the pile for stacks + disable (R not ready / no snipe).
        --
        -- v0.5.26 Item 2 (IMP-A4 positive cap): at fs_at_cap, point Q at the
        -- lowest-eff-HP enemy in Q range (priority kill) instead of the cluster
        -- center. W stays cluster-anchored for max-targets stun coverage.
        local q_priority = nil
        if cap_aware and ctx.fs_at_cap then
            q_priority = state.pick_q_priority_kill(me, Q_LENGTH)
            if q_priority then
                tlog(2, "lina_teamfight_q_cap_priority", { target = uname(q_priority) })
            end
        end
        tlog(1, "lina_teamfight", { archetype = "tf_sustain", cluster = string.format("%d", cluster_n) })
        -- v0.5.170: fc_offensive_sustain_use cut (menu-simplification). The optional
        -- TF-sustain FC pre-amp (default OFF, never promoted) is removed; tf_sustain
        -- fires W/Q with no pre-amp FC, exactly as it did with the toggle off.
        state.fire_steps("tf_tf_sustain", state.build_lina_tf_steps(nil, q_priority), ctx)
        mark_layer1("tf_tf_sustain", false)
    else
        tlog(2, "lina_teamfight_skip", { reason = "tf_focus_no_ws",
            cluster = string.format("%d", cluster_n),
            ready_w = ctx.ready_w and "y" or "n",
            ready_q = ctx.ready_q and "y" or "n",
            ready_r = ctx.ready_r and "y" or "n",
            mana    = string.format("%.0f", ctx.mana or 0) })
    end
    -- else tf_focus: autos, nothing for the brain to issue
end

-- TAP path is intentionally disabled for Lina (no 750u-R / fog-init use case).
state.lina_heavy_starter_tick = function(force)
    tlog(3, "lina_heavy_starter", { decision = "refuse", reason = "tap_path_disabled_in_v0.3.0" })
end

-- Auto-R kill-steal (no combo key). Fires when R alone (+ Slow Burn) kills a
-- visible enemy in range, R ready, not in commit lock, not immune/Linkens.
state.lina_r_kill_steal_tick = function()
    if not (state.menu and state.menu.auto_r and state.menu.auto_r:Get()) then return end
    if not offense_enabled() then return end
    if not self_alive_ok() then return end
    if state.last_r_target then return end          -- an R is already in flight
    if layer1_in_lock() and state.last_layer1_was_r then return end
    if not ability_ready(A.R) then return end
    -- v0.5.24 PERF-04: 3Hz throttle on the scan. Cheap gates above still drop
    -- idle frames at full tick rate; this only paces the GetHeroesInRadius +
    -- per-enemy lina_eff_hp_magical loop when R is actually off-CD.
    if (now() - (state.last_r_steal_t or 0)) < 0.33 then return end
    state.last_r_steal_t = now()
    local me, r = state.self_npc, ability(A.R)
    local rng = cast_range_of(r, FALLBACK_RANGES.R)
    local list = Entity.GetHeroesInRadius(me, rng, Enum.TeamType.TEAM_ENEMY)
    if not list then return end
    -- IMPACT-ONLY for auto-fire: do NOT spend R on a target that only dies to
    -- the 4s Slow Burn DoT (a heal/dispel cancels it). The committed combo
    -- r_finisher still uses impact + burn (r_alone_kill) since the user opted
    -- in by holding the key.
    local impact = lina_r_damage()
    -- v0.5.15 IMP-A1 (best-of-loop): scan ALL eligible enemies, fire on the
    -- lowest-eff-HP one. Prior code returned on the first match, which on a
    -- multi-target cluster could blow R on a near-full target while a 1-HP
    -- squishy stood next to it. Gates unchanged (alive, not illusion/clone,
    -- not magic-immune, no ready Linkens/Lotus, eff_hp <= impact, in range).
    local best, best_eff = nil, math.huge
    for i = 1, #list do
        local e = list[i]
        if e and Target.IsAlive(e) and Target.NotIllusion(e) and Target.NotClone(e)
           and not NPC.HasState(e, MS.MODIFIER_STATE_MAGIC_IMMUNE)
           and not (Target.HasReadyLinkens and Target.HasReadyLinkens(e))
           and not (Target.HasReadyLotus and Target.HasReadyLotus(e))
           and not target_has_spell_deflect(e)
           and not (Target.IsUnkillableNow and Target.IsUnkillableNow(e)) then
            local eff = lina_eff_hp_magical(e)
            if eff <= impact and dist_to(e) <= rng and eff < best_eff then
                best, best_eff = e, eff
            end
        end
    end
    if best then
        tlog(1, "r_kill_steal", { decision = "fire", target = uname(best),
            r_dmg = string.format("%.0f", impact), tgt_hp = string.format("%.0f", best_eff) })
        -- v0.4.8: route through fire_steps so the kill-steal R gets the
        -- SAME flood protection as combos (bounded-spaced re-issue + Hit &
        -- Run pause). offense_fire_one sets last_r_target etc.; mark_layer1
        -- hard-locks re-dispatch for 3s. The cond re-verifies the target is
        -- still killable + in range on each (re)issue (don't waste R if it
        -- healed / went immune / left range mid-retry).
        local tgt = best
        state.fire_steps("r_kill_steal", {
            { ability = A.R, kind = "ut", short = "r", delay_s = 0,
              arg  = function() return tgt end,
              cond = function()
                  return tgt and Entity.IsEntity(tgt) and Target.IsAlive(tgt)
                     and not NPC.HasState(tgt, MS.MODIFIER_STATE_MAGIC_IMMUNE)
                     and not (Target.HasReadyLinkens and Target.HasReadyLinkens(tgt))
                     and not (Target.HasReadyLotus and Target.HasReadyLotus(tgt))
                     and not target_has_spell_deflect(tgt)
                     and not (Target.IsUnkillableNow and Target.IsUnkillableNow(tgt))
                     and dist_to(tgt) <= rng and lina_eff_hp_magical(tgt) <= impact
              end },
        }, { target = tgt })
        mark_layer1("r_kill_steal", true)
    end
end

-- Monitor an in-flight R; STOP it (refunds mana, no CD) if the target becomes
-- unhittable mid-cast or Lina is CC'd. Cleared on cast completion.
state.r_abort_tick = function()
    if not state.last_r_target then return end
    local r = ability(A.R)
    if not r then return end
    if not Ability.IsInAbilityPhase(r) then
        if state.last_r_dispatch_t > 0 and (now() - state.last_r_dispatch_t) > (0.3 + 0.6) then
            state.last_r_target = nil; state.last_r_combo_name = nil; state.last_r_dispatch_t = 0
        end
        return
    end
    local t = state.last_r_target
    -- v0.5.4: Entity.IsEntity passes for non-NPC types, so a recycled-index
    -- edge case could reach NPC.HasState on a stale handle. Add Entity.IsNPC
    -- to the guard so the NPC.HasState calls below are always type-safe.
    if not (t and Entity.IsEntity(t) and Entity.IsNPC(t)) then return end
    local abort, reason = false, nil
    if not Target.IsAlive(t) then abort, reason = true, "target_dead"
    elseif NPC.HasState(t, MS.MODIFIER_STATE_MAGIC_IMMUNE) then abort, reason = true, "bkb"
    elseif NPC.HasState(t, MS.MODIFIER_STATE_INVULNERABLE) then abort, reason = true, "invuln"
    elseif NPC.HasState(t, MS.MODIFIER_STATE_OUT_OF_GAME) then abort, reason = true, "out_of_game"
    elseif Target.HasReadyLinkens and Target.HasReadyLinkens(t) then abort, reason = true, "linkens"
    elseif Target.HasReadyLotus and Target.HasReadyLotus(t) then abort, reason = true, "lotus"
    elseif target_has_spell_deflect(t) then abort, reason = true, "spell_deflect"
    elseif Target.IsUnkillableNow and Target.IsUnkillableNow(t) then abort, reason = true, "unkillable"
    elseif not self_alive_ok() then abort, reason = true, "self_cc"
    end
    if abort then
        safe_issue { hero = HERO_KEY, layer = "agg", intent = "r_abort_" .. (reason or "x"),
            order_type = UO.DOTA_UNIT_ORDER_STOP, unit = state.self_npc }
        state.abort_counter = (state.abort_counter or 0) + 1
        tlog(1, "r_abort", { target = uname(t), reason = reason })
        -- v0.5.42: stamp recently_aborted_intents so cast_verify_tick's prefix
        -- lookup suppresses the spurious double_fail emit for the in-flight
        -- R cast that we just STOPped. Key format mirrors the pcv intent
        -- "<combo>_r#N" -> stripped to "<combo>_r". Must stamp BEFORE nil'ing
        -- state.last_r_combo_name below.
        if state.last_r_combo_name then
            state.recently_aborted_intents[state.last_r_combo_name .. "_r"] = now()
        end
        state.last_r_target = nil; state.last_r_combo_name = nil; state.last_r_dispatch_t = 0
    end
end

-- Native auto-combat pause (lib/native). The framework's built-in Hit & Run
-- (MOVE flood from 3_hit_n_run.lua) and Orb Walker (ATTACK flood via api_extend)
-- run alongside the brain and cancel multi-step combo casts. OnPrepareUnitOrders
-- can't veto them (script orders, triggerCallBack=false), so we pause their
-- framework menu switches for the combo's duration via lib/native. Hit & Run HAS
-- an Enabled switch (works); Orb Walker has none (ow_en=n) - its ATTACK flood is
-- out-persisted by the per-frame cast re-issue in pending_steps_tick instead.
-- v0.5.7 E2: LINA_MENU moved to top-of-module (~line 86) for early-file closure
-- capture (no_land probe, hitrun toggles); duplicate decl removed here.
local function set_native_hitrun(paused)
    if paused then
        local ok, save_probe = Native.PauseHitRun(LINA_MENU)
        -- v0.5.32: PauseHitRun can now return (false, "override_off") when
        -- user has per-hero hr_override=false. The brain's pause cycle is a
        -- net harm in that config (forces override=true flicker that triggers
        -- framework-side state latch breaking mouse-follow even after restore).
        -- Emit a one-shot info tlog so the user sees the brain stepped back.
        if (not ok) and save_probe == "override_off" then
            if not state.native_hr_skip_logged then
                state.native_hr_skip_logged = true
                tlog(1, "native_hitrun_skip", {
                    reason = "user_override_off",
                    note = "user runs global HR config; brain pause cycle skipped to preserve mouse-follow",
                })
            end
            return
        end
        if ok then  -- only on the first paused-transition
            if not state.native_hr_logged then
                local r = Native.Resolve(LINA_MENU)
                -- v0.5.31 task-10: add hr_ki to surface kiting-widget RESOLVED
                -- state (presence). Native.Resolve already exposes it but the
                -- existing tlog dropped the field, contributing to two rounds
                -- of misread heartbeat data.
                tlog(1, "native_hr_resolved", { hr_en = r.hr_en and "y" or "n",
                    hr_ov = r.hr_ov and "y" or "n",
                    hr_ki = r.hr_ki and "y" or "n",
                    ow_en = r.ow_en and "y" or "n",
                    ow_ov = r.ow_ov and "y" or "n" })
                state.native_hr_logged = true
            end
            tlog(1, "native_hitrun", { state = "paused" })
            -- v0.5.31 task-10 probe: dump the saved snapshot captured at this
            -- pause-entry. Lets us disambiguate H1 (snapshot already poisoned
            -- at capture-time) from H2 (nil-resolve silent skip) from H3
            -- (framework rewrites between cycles). tostring() preserves
            -- distinction between nil / true / false / other.
            if save_probe then
                tlog(1, "native_hitrun_save", {
                    saved_hr_override = tostring(save_probe.saved_hr_override),
                    saved_hr_enabled  = tostring(save_probe.saved_hr_enabled),
                    saved_hr_kiting   = tostring(save_probe.saved_hr_kiting),
                    saved_ow_override = tostring(save_probe.saved_ow_override),
                    saved_ow_enabled  = tostring(save_probe.saved_ow_enabled),
                })
            end
        end
    else
        local ok, restore_probe = Native.RestoreHitRun(LINA_MENU)
        if ok then
            tlog(1, "native_hitrun", { state = "restored" })
            -- v0.5.31 task-10 probe: dump the live readback of all HR widgets
            -- AFTER the restore wsets. hr_ki_pre = saved value the brain just
            -- wrote, hr_ki_post = what the widget actually reads now. If
            -- pre != post, the framework re-wrote between the brain's wset
            -- and the readback (H3). If pre=nil, RestoreHitRun silently
            -- skipped the write (H2). If pre=post=true, the saved snapshot
            -- was already poisoned (H1).
            if restore_probe then
                tlog(1, "native_hitrun_restore_probe", {
                    hr_en_pre  = tostring(restore_probe.hr_en_pre),
                    hr_en_post = tostring(restore_probe.hr_en_post),
                    hr_ov_pre  = tostring(restore_probe.hr_ov_pre),
                    hr_ov_post = tostring(restore_probe.hr_ov_post),
                    hr_ki_pre  = tostring(restore_probe.hr_ki_pre),
                    hr_ki_post = tostring(restore_probe.hr_ki_post),
                    ow_ov_post = tostring(restore_probe.ow_ov_post),
                })
            end
        end
    end
end

-- v0.5.6 (E1): narrow native HR pause to true cast-windows so HR can kite
-- between steps. v0.4.3 / v0.4.5 protection is preserved: combo_spell_phasing()
-- covers cast points, pending_step_imminent(0.15) covers the schedule->cast-point
-- window where the OW flood would otherwise stomp the first issue. The 150ms
-- imminent window straddles both the schedule->first-issue and
-- first-issue->cast-point-start gaps that the v0.4.3 / v0.4.5 OW-flood lesson
-- identified. combo_active_until is no longer consulted here (the field stays
-- for fire_steps log / abort use); combo_hold_active is also dropped because
-- between cast-windows we want HR to kite-step Lina. The strict fallback toggle
-- (m.pause_hitrun_strict, default OFF) restores the v0.5.5 wide-pause behaviour
-- for quick A/B if E1 regresses anything in the field.
-- v0.5.7 (E3, covers A3/B5/F4): bound pending_step_imminent on BOTH sides of
-- the lead-in window. The v0.5.6 predicate only checked fire_at <= horizon,
-- so any step that had missed its initial fire_at (i.e. every step sitting in
-- a STEP_REISSUE_SPACING gap or in the post-first-issue waiting window)
-- collapsed to "true" for its entire <= STEP_REISSUE_DEADLINE lifetime. That
-- defeats the v0.5.6 E1 narrow-pause invariant: native Hit & Run stayed
-- paused across the whole pending-steps tail rather than just the ~150ms
-- lead-in around each cast, and F4 ("Hit & Run does not always restore")
-- reproduced anytime a step slipped past first issue. Mid-flight casts are
-- still covered by combo_spell_phasing() on the other disjunct of
-- update_hitrun_pause -- this predicate only needs to capture the brief
-- "about to fire" moment for each step.
--
-- Imminent now means: a fresh step (tries==0) whose fire_at lies inside
-- [now, now+window]; OR a retried step (tries>0) whose NEXT re-issue slot
-- (first_t + tries*STEP_REISSUE_SPACING) lies inside [now, now+window].
-- Steps in the middle of a retry-spacing gap, and in-flight steps whose
-- re-issue is further out than window_s, return false here -- HR is free to
-- kite between cast windows the way v0.5.6 E1 intended.
-- v0.5.171: pending_step_imminent removed (menu-simplification). Its only caller was the
-- narrow-pause branch of update_hitrun_pause, which is gone now that wide-pause is hardcoded ON.
-- v0.5.171.1: native Hit & Run pause is OFF (user call -- it did not work in practice). With
-- some per-hero configs (e.g. hr_override=false) the brain's pause cycle is a net harm: it
-- flickers override=true and breaks mouse-follow even after restore, and the old post-combo
-- re-assert watchdog never reliably fixed the stuck-auto-attack symptom. So the brain no
-- longer pauses native HR at all -- the framework's Hit & Run / Orb Walker run normally.
-- If an older build left HR latched paused, restore it once; otherwise leave it alone.
local function update_hitrun_pause()
    if Native.IsPaused and Native.IsPaused(LINA_MENU) then
        set_native_hitrun(false)
    end
end

-- v0.5.83: hoisted out of combo_key_tick so the per-frame tick allocates no
-- closure. Forces a clean release of the combo-hold latches on toggle-off:
-- otherwise combo_hold_active stays latched, update_hitrun_pause keeps native
-- Hit & Run paused indefinitely, and combo_key_was_down=true blocks the next
-- press-edge from firing on re-enable (the v0.5.4 fix).
local function combo_force_release()
    state.combo_hold_active      = false
    state.combo_hold_active_mode = nil
    state.combo_key_was_down     = false
end

-- TAP/HOLD classifier. Reads the combo key each tick; press<0.18s = TAP (stub),
-- longer = HOLD routed to starter (1-2) / teamfight (3+), latched on hold-start.
state.combo_key_tick = function()
    local m = state.menu
    if not m or not m.combo_key then return end
    if not offense_enabled() then combo_force_release(); return end
    if m.enable_offense and not m.enable_offense:Get() then combo_force_release(); return end
    -- v0.5.83: key_down() reads IsDown without allocating a pcall-closure per frame.
    local down = key_down(m.combo_key)
    local force_down = key_down(m.force_key)
    local was = state.combo_key_was_down

    if down and not was then
        state.combo_press_t          = now()
        state.combo_hold_active      = false
        state.combo_hold_active_mode = nil
    elseif down and was then
        local held = now() - (state.combo_press_t or now())
        if held >= state.COMBO_TAP_MAX_S then
            if not state.combo_hold_active then
                local enemies = state.count_engaged_enemies()
                state.combo_hold_active      = true
                state.combo_hold_active_mode = (enemies >= 3) and "tf" or "starter"
                tlog(1, "combo_classify", { enemies = string.format("%d", enemies),
                    mode = state.combo_hold_active_mode })
                -- v0.5.156.4 combo-to-kill timer: stamp the combo-press time + FC state
                -- so OnNpcDying can log the REAL elapsed time to the target's death (to
                -- validate the TTK model against a stopwatch). One stamp per hold.
                state.combo_timer_t0       = state.combo_press_t or now()
                state.combo_timer_fc_start = (state.lina_fc_active and state.lina_fc_active()) and true or false
            end
            if state.combo_hold_active_mode == "tf" then
                state.lina_teamfight_tick(force_down)
            else
                state.lina_starter_tick(force_down)
            end
        end
    elseif was and not down then
        -- HOLD release: let the in-flight combo RUN TO COMPLETION (Lina's combos
        -- must be fast + uninterrupted). We no longer drop pending_steps on
        -- release - the deferred steps re-check their conds (r_target_blocked etc.)
        -- and r_abort_tick stops a doomed R. Hit & Run stays paused for the full
        -- combo via update_hitrun_pause (combo_active_until tail) and is restored
        -- once the combo finishes. Releasing simply stops NEW dispatches.
        local held = now() - (state.combo_press_t or now())
        if held < state.COMBO_TAP_MAX_S and not state.combo_hold_active then
            state.lina_heavy_starter_tick(force_down)   -- TAP: stubbed
        end
        state.combo_hold_active      = false
        state.combo_hold_active_mode = nil
    end
    state.combo_key_was_down = down
end

-- v0.5.94 engine-blink CAPITALIZE: for a short window after the engine blinks
-- Lina, run the combo dispatch as if engaged (the engine repositioned us; the
-- brain bursts). Default OFF. The brain does NOT cast blink (that fights the
-- engine + crashed in v0.5.92); it seizes the engine's blink. Gated so a
-- defensive/escape blink does not become a suicide commit: HP floor + not-into-a-
-- gank. The dispatch idles on its own if there is no target in range / no mana
-- (a blink AWAY from enemies capitalizes on nothing). Defined here (right after
-- combo_key_tick) so offense_enabled / self_alive_ok / count_engaged_enemies /
-- lina_*_tick are all already in scope (the v0.5.92 forward-reference lesson).
state.blink_capitalize_tick = function()
    local m = state.menu
    if not (m and m.blink_capitalize and m.blink_capitalize:Get()) then return end
    if not state.blink_seen_t then return end
    if (state.frame_t - state.blink_seen_t) >= 1.0 then return end   -- 1.0s window
    if state.combo_hold_active then return end          -- user already comboing
    if not offense_enabled() then return end
    local me = state.self_npc
    if not (me and self_alive_ok()) then return end
    local hp_floor = 35  -- v0.5.172: blink_capitalize_hp hardcoded 35
    if state.blink_in_hp_frac(me) * 100 < hp_floor then
        tlog(2, "blink_capitalize_skip", { reason = "hp_floor" }); return
    end
    if state.gank_imminent_self and state.gank_imminent_self() then
        tlog(2, "blink_capitalize_skip", { reason = "gank" }); return
    end
    local enemies = state.count_engaged_enemies()
    tlog(1, "blink_capitalize", {
        enemies = string.format("%d", enemies),
        hp      = string.format("%.2f", state.blink_in_hp_frac(me)),
    })
    if enemies >= 3 then state.lina_teamfight_tick(false) else state.lina_starter_tick(false) end
end

-- v0.5.137 W-CAPITALIZE: the offensive completion of the defensive W stun. When
-- the W fired to stun a gap-closer / committed attacker (stamped in the W .fire),
-- seize a short window to COMMIT the combo on that stunned target -- but ONLY if
-- the brain can SECURE the kill (state.combo_can_kill). The W stun (1.2-2.4s)
-- outlasts the 1.2s window, so the target is still locked down. Mirrors
-- state.blink_capitalize_tick (same offense/HP/gank gates + the enemies>=3
-- teamfight-vs-starter dispatch) + adds the target/range/kill gates. Defined
-- here so offense_enabled / self_alive_ok / count_engaged_enemies / lina_*_tick
-- / dist_to / cast_range_of are all already in scope. Default ON. Target aim:
-- v1 relies on the combo's own nearest-enemy selection (the stunned gap-closer
-- is adjacent); a preference hook is the demo-gated follow-up if it mis-targets.
state.w_capitalize_tick = function()
    local m = state.menu
    if not (m and m.w_capitalize and m.w_capitalize:Get()) then return end
    if not state.w_capitalize_t then return end
    if (state.frame_t - state.w_capitalize_t) >= 1.2 then return end   -- 1.2s window
    local tgt = state.w_capitalize_target
    if not (tgt and Entity.IsEntity(tgt) and Target.IsAlive and Target.IsAlive(tgt)) then
        state.w_capitalize_target = nil
        tlog(2, "w_capitalize_skip", { reason = "target_gone" }); return
    end
    if state.combo_hold_active then return end          -- user already comboing
    if not offense_enabled() then return end
    local me = state.self_npc
    if not (me and self_alive_ok()) then return end
    local r_range = cast_range_of(ability(A.R), FALLBACK_RANGES.R)
    if dist_to(tgt) > r_range then
        tlog(2, "w_capitalize_skip", { reason = "out_of_range" }); return
    end
    if not state.combo_can_kill(tgt) then
        tlog(2, "w_capitalize_skip", { reason = "no_kill" }); return     -- W stays defensive
    end
    local hp_floor = 35  -- v0.5.172: w_capitalize_hp hardcoded 35
    if state.blink_in_hp_frac(me) * 100 < hp_floor then
        tlog(2, "w_capitalize_skip", { reason = "hp_floor" }); return
    end
    if state.gank_imminent_self and state.gank_imminent_self() then
        tlog(2, "w_capitalize_skip", { reason = "gank" }); return
    end
    local enemies = state.count_engaged_enemies()
    tlog(1, "w_capitalize", {
        target  = uname(tgt),
        enemies = string.format("%d", enemies),
        hp      = string.format("%.2f", state.blink_in_hp_frac(me)),
    })
    if enemies >= 3 then state.lina_teamfight_tick(false) else state.lina_starter_tick(false) end
end

-- v0.5.78 wave-clear: gather farmable units (lane creeps + neutrals) near Lina.
-- DEFENSIVE enumeration -- the hero brains have never enumerated creeps before,
-- so every engine call is pcall-guarded and degrades to "no creeps" instead of
-- crashing if a name/enum is wrong on this framework build.
--   * Enemy non-hero units = Entity.GetUnitsInRadius(TEAM_ENEMY) MINUS
--     Entity.GetHeroesInRadius(TEAM_ENEMY). Set-difference avoids needing an
--     unverified NPC.IsHero predicate.
--   * Neutrals = Entity.GetUnitsInRadius(TEAM_NEUTRAL), only if the enum value
--     exists on this build (guarded). If absent, lane clear still works.
--   * Skip dead / illusions (lib/target) and invulnerable units (towers pre-
--     expose, wards, etc. via the verified NPC.IsInvulnerable).
-- Returns a Farm-contract list: { {pos, hp, is_neutral, entity}, ... }.
-- One-shot probe tlog on first call dumps raw counts so the next demo confirms
-- exactly what the API returns on this build.
state.farm_probe_logged = false
state.farm_gather_creeps = function(radius)
    local me = state.self_npc
    local me_pos = me and Entity.GetAbsOrigin(me)
    if not (me and me_pos) then return {} end
    radius = radius or 1075
    local out, seen = {}, {}
    -- enemy hero set to subtract (verified API; Sniper uses it heavily)
    local hero_set, n_heroes = {}, 0
    local okh, heroes = pcall(Entity.GetHeroesInRadius, me, radius,
                              Enum.TeamType.TEAM_ENEMY)
    if okh and heroes then
        for i = 1, #heroes do hero_set[heroes[i]] = true; n_heroes = n_heroes + 1 end
    end
    local n_enemy_units, n_neutral_units = 0, 0
    local function consume(list, is_neutral)
        if not list then return end
        for i = 1, #list do
            local u = list[i]
            if u and not seen[u] and not hero_set[u] then
                seen[u] = true
                local alive = Target.IsAlive(u) and Target.NotIllusion(u)
                local invuln = NPC.IsInvulnerable and NPC.IsInvulnerable(u)
                if alive and not invuln then
                    local p = Entity.GetAbsOrigin(u)
                    if p then
                        local hp = (Entity.GetHealth and Entity.GetHealth(u)) or 0
                        out[#out + 1] = {
                            pos = p, hp = hp,
                            is_neutral = is_neutral and true or false,
                            entity = u,
                        }
                    end
                end
            end
        end
    end
    local oke, eunits = pcall(Entity.GetUnitsInRadius, me, radius,
                              Enum.TeamType.TEAM_ENEMY)
    if oke and eunits then n_enemy_units = #eunits; consume(eunits, false) end
    -- Neutrals: only if this build exposes the enum value.
    if Enum and Enum.TeamType and Enum.TeamType.TEAM_NEUTRAL ~= nil then
        local okn, nunits = pcall(Entity.GetUnitsInRadius, me, radius,
                                  Enum.TeamType.TEAM_NEUTRAL)
        if okn and nunits then n_neutral_units = #nunits; consume(nunits, true) end
    end
    if not state.farm_probe_logged then
        state.farm_probe_logged = true
        tlog(1, "farm_gather_probe", {
            radius = string.format("%.0f", radius),
            enemy_units = tostring(n_enemy_units),
            neutral_units = tostring(n_neutral_units),
            heroes_excluded = tostring(n_heroes),
            farmable = tostring(#out),
            neutral_enum = (Enum and Enum.TeamType and Enum.TeamType.TEAM_NEUTRAL ~= nil)
                           and "y" or "n",
        })
    end
    return out
end

-- v0.5.111 wave-clear hero-clip: enemy HEROES in radius as a bonus-unit
-- list for Farm.BestLineAim (same unit-list contract as farm_gather_creeps
-- above; guard style mirrors it; degrades to {} on any API miss).
state.farm_gather_enemy_heroes = function(radius)
    local me = state.self_npc
    if not me then return {} end
    local out = {}
    local okh, heroes = pcall(Entity.GetHeroesInRadius, me, radius or 1075,
                              Enum.TeamType.TEAM_ENEMY)
    if okh and heroes then
        for i = 1, #heroes do
            local h = heroes[i]
            if h and Target.IsAlive(h) and Target.NotIllusion(h)
               and not (NPC.IsInvulnerable and NPC.IsInvulnerable(h)) then
                local p = Entity.GetAbsOrigin(h)
                if p then
                    out[#out + 1] = {
                        pos = p,
                        hp = (Entity.GetHealth and Entity.GetHealth(h)) or 0,
                        entity = h,
                    }
                end
            end
        end
    end
    return out
end

-- v0.5.78 wave-clear HOLD handler. While the wave-clear key is held:
--   1. gather creeps within Q range,
--   2. Q (Dragon Slave) at the line aim hitting the most creeps, when
--      hit_count >= min_creeps AND mana gates pass,
--   3. (opt) W (Light Strike Array) on a dense camp when mana-rich.
-- Player owns movement (HOLD model); the brain only nukes what is already in
-- range. Gated on master enable + Q/W readiness + mana floor + R reserve.
-- Skipped while a combo is active (combo owns the spells) and while a save
-- chain is mid-flight.
state.last_wave_clear_t = 0
state.wave_clear_tick = function()
    local m = state.menu
    if not (m and m.wave_key) then return end
    if m.enable and not m.enable:Get() then return end
    -- combo takes priority over farm
    if state.combo_hold_active then return end
    local down = key_down(m.wave_key)   -- v0.5.83: no per-frame pcall-closure
    if not down then return end
    -- light throttle: re-evaluate ~5x/sec (Q CD + safe_issue dedup do the rest)
    local t = now()
    if (t - (state.last_wave_clear_t or 0)) < 0.2 then return end
    state.last_wave_clear_t = t

    -- v0.5.84: pause farm when a gank is inbound. A squishy, immobile Lina
    -- holding the wave-clear key while 2+ enemies rotate from fog gets picked.
    -- gank_imminent_self() (2 arrivable in 4s, fog-aware) gates the whole tick
    -- -- the first live consumer of the v0.5.77 fog suite. Throttled (5Hz, only
    -- while the key is held), so the FogSnapshot cost is bounded.
    -- v0.5.113.1 (demo: 59x wave_clear_gank_pause = the wave key was DEAD in
    -- any contested lane): the v0.5.84 gate counted VISIBLE enemies toward
    -- the 2-arrivable signal, so a plain lane standoff suppressed the user's
    -- explicit HOLD every tick. The signal the gate was built for ("a FOG
    -- gank") requires an UNSEEN arriver: pause only when the imminent set
    -- contains at least one visibility=fog ganker. Fully-visible pressure is
    -- the user's own information and their call -- the key is a deliberate
    -- HOLD.
    if state.gank_imminent_self then
        local imminent, gankers = state.gank_imminent_self()
        if imminent and type(gankers) == "table" then
            local fog = 0
            for i = 1, #gankers do
                if gankers[i] and gankers[i].visibility == "fog" then
                    fog = fog + 1
                end
            end
            if fog >= 1 then
                if TLOG3_ENABLED then
                    tlog(3, "wave_clear_gank_pause", {
                        fog   = tostring(fog),
                        total = tostring(#gankers),
                    })
                end
                return
            end
        end
    end

    local me = state.self_npc
    local me_pos = me and Entity.GetAbsOrigin(me)
    if not (me and me_pos) then return end

    local q_ready = ability_ready("lina_dragon_slave")
    local w_ready = ability_ready("lina_light_strike_array")  -- v0.5.172: wave_use_w hardcoded ON
    if not (q_ready or w_ready) then return end

    -- mana gates
    local mana    = (NPC.GetMana and NPC.GetMana(me)) or 0
    local maxmana = (NPC.GetMaxMana and NPC.GetMaxMana(me)) or 0
    local floor_frac = 0.30  -- v0.5.172: wave_mana_floor hardcoded 30%
    local reserve_r  = true  -- v0.5.172: wave_reserve_r hardcoded ON
    local r_cost = reserve_r and ability_mana("lina_laguna_blade") or 0
    if maxmana > 0 and (mana / maxmana) < floor_frac then return end

    local min_creeps = 3  -- v0.5.172: wave_min_creeps hardcoded 3
    local creeps = state.farm_gather_creeps(Q_LENGTH)
    if #creeps == 0 then return end

    local fired = false
    -- Q: best line aim
    if q_ready then
        local q_cost = ability_mana("lina_dragon_slave")
        if mana >= q_cost and (mana - q_cost) >= r_cost then
            -- v0.5.111 hero-clip (player report: "clear-wave Q is not aimed
            -- to hit creeps AND the player behind"): enemy heroes in Q range
            -- join the aim as weighted bonus targets, so among wave-clearing
            -- lines the one that also clips a hero wins (a hero outbids up
            -- to 3 creeps). min_hits keeps the pick inside the cast gate: a
            -- hero-heavy line below the creep threshold never displaces a
            -- qualifying line. CAST CONDITIONS UNCHANGED (still needs
            -- min_creeps creeps on the chosen line; the hero never
            -- substitutes for creeps).
            local bonus_heroes = state.farm_gather_enemy_heroes(Q_LENGTH)
            local aim, hit_n, _, hero_n = Farm.BestLineAim(
                me_pos, creeps, Q_LENGTH, Q_HALF_WIDTH,
                { bonus_units = bonus_heroes, bonus_weight = 3,
                  min_hits = min_creeps })
            if aim and Farm.WorthCasting(hit_n, min_creeps) then
                local q = ability("lina_dragon_slave")
                if q and issue_cast_position("wave_clear_q", q, aim, "agg") then
                    fired = true
                    tlog(1, "wave_clear_q", {
                        hits = tostring(hit_n),
                        heroes = tostring(hero_n or 0),
                        x = string.format("%.0f", aim.x),
                        y = string.format("%.0f", aim.y),
                        mana = string.format("%.0f", mana),
                    })
                end
            end
        end
    end
    -- W: dense camp, only when mana-rich after the (possible) Q spend.
    if w_ready then
        local q_cost = (q_ready and ability_mana("lina_dragon_slave")) or 0
        local w_cost = ability_mana("lina_light_strike_array")
        local spent  = fired and q_cost or 0
        if (mana - spent) >= w_cost and (mana - spent - w_cost) >= r_cost then
            -- v0.5.81 fix: gather a W-RANGE creep list (not the wider Q-range
            -- list) so BestPointAim's unit-centered result is within W's cast
            -- range by construction. Reusing the Q_LENGTH (1075) list let a
            -- camp 700-1075u away win, and issue_cast_position has no range gate
            -- so the engine WALKED Lina to it -- breaking the HOLD "only nukes
            -- what is already in range" contract.
            local w_range = cast_range_of(ability("lina_light_strike_array"),
                                          FALLBACK_RANGES.W)
            -- v0.5.82 perf: filter the already-gathered Q-range `creeps` list to
            -- W range instead of a second farm_gather_creeps engine sweep (which
            -- ran 2-3 GetUnitsInRadius/GetHeroesInRadius calls + a full per-unit
            -- predicate pass). creeps was gathered at Q_LENGTH (1075) >= w_range,
            -- so it is a strict superset; the squared-distance filter yields the
            -- identical in-W-range set the second gather would have.
            local w_r2 = w_range * w_range
            local w_creeps = {}
            for i = 1, #creeps do
                local c = creeps[i]
                local dx = c.pos.x - me_pos.x
                local dy = c.pos.y - me_pos.y
                if (dx * dx + dy * dy) <= w_r2 then
                    w_creeps[#w_creeps + 1] = c
                end
            end
            local center, w_hit = Farm.BestPointAim(w_creeps, W_AOE)
            -- dense = at least one more than the Q gate (a real pack, not a pair)
            if center and Farm.WorthCasting(w_hit, min_creeps + 1) then
                local w = ability("lina_light_strike_array")
                if w and issue_cast_position("wave_clear_w", w, center, "agg") then
                    tlog(1, "wave_clear_w", {
                        hits = tostring(w_hit),
                        x = string.format("%.0f", center.x),
                        y = string.format("%.0f", center.y),
                    })
                end
            end
        end
    end
end

-- v0.5.15 OBS-08: one-press forensic dump of the live brain state. Emits
-- multi-line tlog at level 1 (visible at default verbosity), one record per
-- logical group so the debug.log stays grep-friendly. fs stack count is read
-- fresh from the modifier (no state.ctx exists, ctx is a per-tick local).
state.dump_brain_state = function()
    local me = state.self_npc
    local fs = "na"
    if me then
        local m_fs = NPC.GetModifier(me, "modifier_lina_fiery_soul")
        if m_fs then
            local n = Modifier.GetStackCount(m_fs)
            if type(n) == "number" then fs = tostring(n) end
        end
    end
    -- v0.5.36 MAINT-06: expose modcreate/skip counters in the header dump so
    -- the OnModifierCreate hit-rate and queue-dedup skip-rate are visible
    -- alongside the l1/l2/abort counters they pair with.
    -- v0.5.37 MAINT-05: include panic_override_until in the header dump so a
    -- forensic snapshot taken mid-incident shows whether the panic bypass was
    -- armed when the dump fired. 'panic_ttl' is the remaining window in
    -- seconds (0.00 = disarmed / already consumed / expired).
    local _panic_ttl = math.max(0, (state.panic_override_until or 0) - now())
    tlog(1, "brain_dump_header", { t = string.format("%.2f", now()),
        l1 = tostring(state.l1_counter), l2 = tostring(state.l2_counter),
        abort = tostring(state.abort_counter),
        modcreate = tostring(state.modcreate_counter),
        skip = tostring(state.skip_counter), fs = fs,
        panic_ttl = string.format("%.2f", _panic_ttl) })
    tlog(1, "brain_dump_last_save", {
        t       = string.format("%.2f", state.last_save_t or 0),
        kind    = tostring(state.last_save_kind),
        threat  = tostring(state.last_save_threat_mod),
        intent  = tostring(state.last_save_intent),
        l1int   = tostring(state.last_layer1_intent) })
    local n_armed = 0
    for key, entry in pairs(state.armed_threats) do
        n_armed = n_armed + 1
        tlog(1, "brain_dump_armed", { key = tostring(key),
            threat   = tostring(entry.threat_mod),
            eta_spd  = tostring(entry.eta_speed),
            eta_trig = tostring(entry.eta_trigger) })
    end
    if n_armed == 0 then tlog(1, "brain_dump_armed", { count = "0" }) end
    -- v0.5.15 OBS-08 (verify-correction): pending_steps entry shape per
    -- schedule_step (local function) is {fire_at, combo_name, short, ability_key,
    -- kind, arg_fn, cond_fn, target, ctx_snapshot, independent_pos}. The
    -- author's draft used step.name / step.t_fire / step.tries which do not
    -- exist on the entry. Use the actual field names so the dump is forensic
    -- not 'nil nil nil'.
    local n_pend = #state.pending_steps
    for i, step in ipairs(state.pending_steps) do
        tlog(1, "brain_dump_pending", { i = tostring(i),
            combo   = tostring(step.combo_name),
            short   = tostring(step.short),
            fire_at = string.format("%.2f", step.fire_at or 0),
            kind    = tostring(step.kind),
            ability = tostring(step.ability_key) })
    end
    if n_pend == 0 then tlog(1, "brain_dump_pending", { count = "0" }) end
    local n_resp = 0
    for key, t in pairs(state.responded_threats) do
        n_resp = n_resp + 1
        tlog(1, "brain_dump_responded", { key = tostring(key),
            t = string.format("%.2f", t or 0) })
    end
    if n_resp == 0 then tlog(1, "brain_dump_responded", { count = "0" }) end
end

-- v0.5.15 OBS-08: rising-edge detector for m.dump_key. Mirrors combo_key_tick's
-- was-down latch so the dump fires exactly once per press, not once per tick.
state.dump_key_tick = function()
    local m = state.menu
    if not m or not m.dump_key then return end
    local down = key_down(m.dump_key)   -- v0.5.83: no per-frame pcall-closure
    if down and not state.dump_key_was_down then
        state.dump_brain_state()
    end
    state.dump_key_was_down = down
end

-- v0.5.37 MAINT-05: rising-edge detector for m.panic_key. Mirrors
-- state.dump_key_tick (same was-down latch + pcall around :IsDown()).
-- On press, arms a 2.0s panic window (state.panic_override_until) that
-- causes the next try_save_self call to bypass the layer2 reaction-window
-- throttle. One-shot: panic_override_until is cleared by try_save_self on
-- the first successful save dispatch, or self-expires after the window if
-- no save-eligible threat arrives in time. Emits one level-1 tlog per
-- press so log greps can correlate user panic intent with subsequent
-- save_chain_skip / save_fire rows.
state.panic_key_tick = function()
    local m = state.menu
    if not m or not m.panic_key then return end
    local down = key_down(m.panic_key)   -- v0.5.83: no per-frame pcall-closure
    if down and not state.panic_key_was_down then
        state.panic_override_until = now() + 2.0
        tlog(1, "panic_key_pressed", { window = "2.0",
            until_t = string.format("%.2f", state.panic_override_until) })
    end
    state.panic_key_was_down = down
end

----------------------------------------------------------- test harness ----
-- v0.5.17 Track 1: in-Brain unit test harness. Each test is a closure that
-- receives a cleanup table and returns {pass = bool, reason = string}. The
-- harness pcall-wraps the call so a bad mock cannot crash the brain. Mocks
-- are restored via a per-test LIFO cleanup stack: push restore fns inside
-- the test, harness pops them all on finish (even on assertion failure or
-- Lua error). See state.tests entries for the registration pattern.
--
-- Trigger: Diagnostics > "Run all brain tests" bind (KEY_NONE default; the
-- bind is opt-in - assign a key in the menu to enable). Rising-edge handler
-- mirrors state.dump_key_tick (OBS-08).
--
-- Output: one tlog row per test_run_begin / test_run_end + one test_summary
-- at session end, all at level 1 (visible at default verbosity=1). Grep
-- debug.log between test_session_begin and test_session_end for the result.

state.tests = {}
state.test_history = {}
state.test_key_was_down = false

state.test_assert = function(cond, msg)
    if cond then return { pass = true,  reason = msg or "ok"   } end
    return                       { pass = false, reason = msg or "fail" }
end

-- LIFO cleanup stack: tests push restore fns; harness pops them after the
-- test fn returns (or errors). Keeps mock unrolling deterministic.
local function _cu_new() return { stack = {} } end
local function _cu_push(cu, fn) cu.stack[#cu.stack + 1] = fn end
local function _cu_run(cu)
    for i = #cu.stack, 1, -1 do pcall(cu.stack[i]) end
end

state.run_test = function(name)
    local t = state.tests[name]
    if not t then
        tlog(1, "test_run_end", { name = name, pass = "n", reason = "test_not_registered" })
        return false
    end
    tlog(1, "test_run_begin", { name = name, desc = t.desc or "-" })
    local cu = _cu_new()
    local ok, result = pcall(function() return t.fn(cu) end)
    _cu_run(cu)
    if not ok then
        tlog(1, "test_run_end", { name = name, pass = "n",
            reason = "lua_error:" .. tostring(result):sub(1, 200) })
        state.test_history[#state.test_history + 1] = { name = name, pass = false, reason = tostring(result) }
        return false
    end
    if type(result) ~= "table" then
        tlog(1, "test_run_end", { name = name, pass = "n",
            reason = "non_table_result:" .. type(result) })
        state.test_history[#state.test_history + 1] = { name = name, pass = false, reason = "non_table" }
        return false
    end
    local pass = result.pass and true or false
    tlog(1, "test_run_end", { name = name, pass = pass and "y" or "n",
        reason = tostring(result.reason or "-") })
    state.test_history[#state.test_history + 1] = { name = name, pass = pass, reason = result.reason }
    return pass
end

state.run_all_tests = function()
    tlog(1, "test_session_begin", { t = string.format("%.2f", now()) })
    state.test_history = {}
    local names = {}
    for n in pairs(state.tests) do names[#names + 1] = n end
    table.sort(names)
    local passed, failed = 0, 0
    for _, n in ipairs(names) do
        local ok = state.run_test(n)
        if ok then passed = passed + 1 else failed = failed + 1 end
    end
    tlog(1, "test_summary", { passed = tostring(passed),
        failed = tostring(failed), total = tostring(#names) })
    tlog(1, "test_session_end", { t = string.format("%.2f", now()) })
end

-- Rising-edge handler for the test bind. Mirrors state.dump_key_tick.
state.test_key_tick = function()
    local m = state.menu
    if not m or not m.test_key then return end
    local down = key_down(m.test_key)   -- v0.5.83: no per-frame pcall-closure
    if down and not state.test_key_was_down then
        state.run_all_tests()
    end
    state.test_key_was_down = down
end

------------------ test registrations ------------------

-- T_A9_pudge_chain_order (zero-mock): regression guard for v0.5.15 IMP-A9.
-- The Pudge Dismember save chain was reordered from [WW, Force, Pike, Eul,
-- Manta, BKB] to [WW, Eul, Force, Pike, Manta, BKB] (Eul cheaper than
-- Force/Pike with same dispel). This test catches a future accidental
-- re-reorder. Reads state.lina_chains (the test-only expose; grep `state.lina_chains =`).
state.tests["A9_pudge_chain_order"] = {
    desc = "IMP-A9: CH.PUDGE_DISMEMBER is [WW,Eul,Force,Pike,Manta,BKB]",
    fn = function(_cu)
        local chain = state.lina_chains and state.lina_chains.pudge_dismember
        if type(chain) ~= "table" then
            return { pass = false, reason = "state.lina_chains.pudge_dismember not exposed" }
        end
        local expected = {
            "item_wind_waker", "item_cyclone", "item_force_staff",
            "item_hurricane_pike", "item_manta", "item_black_king_bar",
        }
        if #chain ~= #expected then
            return { pass = false, reason = "len mismatch: got " .. #chain .. " expected " .. #expected }
        end
        for i = 1, #expected do
            if chain[i] ~= expected[i] then
                return { pass = false,
                    reason = "pos " .. i .. ": got '" .. tostring(chain[i]) .. "' expected '" .. expected[i] .. "'" }
            end
        end
        return { pass = true, reason = "6/6 positions match" }
    end,
}

-- v0.5.82 quality: contract / no-throw smoke test for the v0.5.76-78 lib-alias
-- surface (fog + escape + farm). Drives each alias with state.self_npc = nil
-- and asserts the documented return shape WITHOUT erroring -- exactly the class
-- of nil-deref / shape-divergence the optimization workflow flagged. Mock-driven:
-- nils self_npc via the cleanup stack, restores after. Complements the offline
-- tools/run_tests.lua pure-lib tests by covering the Lina-side glue (aliases +
-- _fog_opts + arg passing).
state.tests["Q82_fog_escape_alias_contracts"] = {
    desc = "v0.5.82: fog/escape/farm aliases return correct shape + no-throw with self_npc=nil",
    fn = function(cu)
        local saved = state.self_npc
        _cu_push(cu, function() state.self_npc = saved end)
        state.self_npc = nil
        local snap = state.fog_snapshot and state.fog_snapshot()
        if type(snap) ~= "table" or type(snap.heroes) ~= "table" then
            return { pass = false, reason = "fog_snapshot shape" }
        end
        local pg = state.possible_gankers and state.possible_gankers()
        if type(pg) ~= "table" or type(pg.gankers) ~= "table"
           or type(pg.summary) ~= "table" or type(pg.summary.count) ~= "number" then
            return { pass = false, reason = "possible_gankers shape" }
        end
        if type(state.gank_imminent_self) ~= "function" then
            return { pass = false, reason = "gank_imminent_self missing" }
        end
        -- v0.5.89: do NOT write `local gi, glist = X and X()`. The `and`
        -- truncates the call to ONE value, so glist=nil and the shape check
        -- false-fails (the v0.5.49 multi-return lesson). Call directly.
        local gi, glist = state.gank_imminent_self()
        if type(gi) ~= "boolean" or type(glist) ~= "table" then
            return { pass = false, reason = "gank_imminent_self shape" }
        end
        local mm = state.missing_from_map and state.missing_from_map()
        if type(mm) ~= "table" then
            return { pass = false, reason = "missing_from_map shape" }
        end
        local ia = state.initiators_accounted_for and state.initiators_accounted_for({})
        if type(ia) ~= "table" or type(ia.accounted) ~= "table" then
            return { pass = false, reason = "initiators_accounted_for shape" }
        end
        local landing = state.pike_advance_pick and state.pike_advance_pick(nil)
        if landing ~= nil then
            return { pass = false, reason = "pike_advance_pick(nil) should be nil" }
        end
        if type(state.safest_spot_near) ~= "function" then
            return { pass = false, reason = "safest_spot_near missing" }
        end
        -- v0.5.89: same multi-return truncation guard as gank_imminent_self.
        local sp, sc = state.safest_spot_near()
        if sp ~= nil or type(sc) ~= "number" then
            return { pass = false, reason = "safest_spot_near shape" }
        end
        return { pass = true, reason = "7 aliases: correct shape, no throw" }
    end,
}

-- v0.5.16 Group 4 guard tests (parametrized over the 4 items). Each test
-- mocks NPC.HasModifier to return true ONLY for the canonical modifier and
-- tripwires NPCLib.item to record any call. The fire() closure should return
-- false WITHOUT touching NPCLib.item. If the guard regresses (or someone
-- removes it), NPCLib.item gets called and the test fails. The mock pattern
-- is tight: only two functions hooked, both restored via the cleanup stack.
local _G4_TESTS = {
    { key = "item_black_king_bar", mod = "modifier_black_king_bar_immune"  },
    { key = "item_cyclone",        mod = "modifier_eul_cyclone"            },
    { key = "item_wind_waker",     mod = "modifier_wind_waker"             },
    { key = "item_glimmer_cape",   mod = "modifier_item_glimmer_cape_fade" },
}
-- v0.5.39 P3-M05-test: MAINT-05 panic-bypass regression guard. Simulates the
-- rising-edge press on state.panic_key_tick (mocking m.panic_key:IsDown to
-- return true after a false baseline), then drives try_save_self past a stale
-- state.last_save_t. With a stubbed Dispatcher:TrySaveSelf return value of
-- true (representing a ready chain item that fired) we assert:
--   (a) state.panic_override_until > now() after the simulated press, and
--   (b) state.last_save_t is restored to 0 after a successful dispatch
--       (one-shot consumption verifies the bypass-restore branch).
-- Mocks: state.menu.panic_key (IsDown closure), defense_dispatcher.TrySaveSelf
-- (forced true). Restored via the per-test LIFO cleanup stack.
state.tests["M05_panic_bypass_fires"] = {
    desc = "MAINT-05: panic key press arms panic_override_until and try_save_self bypasses layer2 throttle",
    fn = function(cu)
        local tss = state.lina_try_save_self
        if type(tss) ~= "function" then
            return { pass = false, reason = "state.lina_try_save_self not exposed" }
        end
        if type(state.panic_key_tick) ~= "function" then
            return { pass = false, reason = "state.panic_key_tick not exposed" }
        end
        -- Snapshot state we mutate so the cleanup stack restores it.
        local saved_menu              = state.menu
        local saved_panic_was_down    = state.panic_key_was_down
        local saved_panic_until       = state.panic_override_until
        local saved_last_save_t       = state.last_save_t
        _cu_push(cu, function() state.menu                = saved_menu              end)
        _cu_push(cu, function() state.panic_key_was_down  = saved_panic_was_down    end)
        _cu_push(cu, function() state.panic_override_until = saved_panic_until      end)
        _cu_push(cu, function() state.last_save_t          = saved_last_save_t      end)
        -- Stub the menu binding so panic_key_tick's pcall(:IsDown) returns true.
        state.menu = { panic_key = { IsDown = function(_) return true end } }
        state.panic_key_was_down   = false
        state.panic_override_until = 0
        -- Mock the dispatcher's TrySaveSelf so the chain-walk is replaced by a
        -- forced success (representing a ready item firing through the bypass).
        local saved_TrySaveSelf = defense_dispatcher.TrySaveSelf
        local trysave_called    = false
        defense_dispatcher.TrySaveSelf = function(_self, _intent, _mod, _caster, _hint, _abil, on_save_fired)
            trysave_called = true
            -- Mimic dispatcher:MarkFired side-effect so the bypass-restore
            -- branch sees a successful fire (record_save normally re-stamps
            -- last_save_t via the on_save_fired callback chain).
            state.last_save_t = (state.frame_t and state.frame_t > 0) and state.frame_t or 0
            if on_save_fired then on_save_fired(_intent, "mock", _mod, _caster) end
            return true
        end
        _cu_push(cu, function() defense_dispatcher.TrySaveSelf = saved_TrySaveSelf end)
        -- (a) Drive the rising-edge press.
        state.panic_key_tick()
        if not (state.panic_override_until and state.panic_override_until > now()) then
            return { pass = false, reason = "panic_override_until not in future after press: "
                .. tostring(state.panic_override_until) .. " vs now=" .. tostring(now()) }
        end
        -- (b) Stale last_save_t snapshot; verifies the bypass-restore branch
        -- leaves state.last_save_t at 0 after a successful dispatch (one-shot
        -- consumption). The CanFire K.LAYER2_REACTION_WINDOW gate is mocked out
        -- by the TrySaveSelf stub so this test exercises the wrapper state
        -- machine (panic_override_until arm + clear), not the dispatcher gate.
        state.last_save_t = now()
        local ok, fired = pcall(tss, "test_m05", nil, nil, nil, nil)
        if not ok then
            return { pass = false, reason = "try_save_self raised: " .. tostring(fired):sub(1, 120) }
        end
        if not trysave_called then
            return { pass = false, reason = "defense_dispatcher:TrySaveSelf was not invoked (bypass did not reach dispatch)" }
        end
        if fired ~= true then
            return { pass = false, reason = "try_save_self returned " .. tostring(fired) .. " (expected true)" }
        end
        if state.panic_override_until ~= 0 then
            return { pass = false, reason = "panic_override_until not cleared post-fire (expected 0): "
                .. tostring(state.panic_override_until) }
        end
        return { pass = true, reason = "panic press armed window, try_save_self bypassed throttle and fired" }
    end,
}

-- v0.5.137 W-capitalize kill gate. state.combo_can_kill(target) decides whether
-- the brain can SECURE a kill on an arbitrary (W-stunned) target with the
-- REMAINING burst (Q + R; the defensive W already dealt its damage), using the
-- CONSERVATIVE r_alone_kill margin (eff_hp * 1.05 <= burst -- commit only when
-- it clearly kills). combo_can_kill reads the damage helpers via state.* so this
-- test injects controlled numbers (the v0.5.17 lesson-14 mockability pattern):
-- it mocks r/q/eff-HP to pin the verdict, and mocks W HUGE to prove W is NOT
-- credited (a future edit that wrongly adds state.lina_w_damage flips this red).
state.tests["FC01_offense_value_flip"] = {
    desc = "v0.5.155 FC offense pillar: fc_offense_value = count of kills FC's x(1+FC_SPELL_AMP) flips on the committed combo (primary-only)",
    fn = function(cu)
        if type(state.fc_offense_value) ~= "function" then
            return { pass = false, reason = "state.fc_offense_value not exposed" }
        end
        local s_eff = state.lina_eff_hp_magical
        _cu_push(cu, function() state.lina_eff_hp_magical = s_eff end)
        -- combo_total = 1000; FC amp 1.35 -> amped 1350. Flip band = (1000, 1350/1.05 = 1285.7].
        local cases = {
            { eff = 1100, want = 1, why = "bare 1000 misses, amped 1350 kills (1155<=1350)" },
            { eff = 1280, want = 1, why = "top of band (1344<=1350)" },
            { eff = 900,  want = 0, why = "bare combo already kills" },
            { eff = 1300, want = 0, why = "un-killable even amped (1365>1350)" },
        }
        for _, c in ipairs(cases) do
            state.lina_eff_hp_magical = function(_) return c.eff end
            local ctx = { combo_total = 1000, q_dmg = 0, w_dmg = 0 }
            local got = state.fc_offense_value(ctx, "T", nil)
            if got ~= c.want then
                return { pass = false, reason = ("eff=%d got=%d want=%d (%s)"):format(c.eff, got, c.want, c.why) }
            end
        end
        -- v0.5.160 A3.1: AoE-cluster path. aoe_burst = q+w = 400, amped 540, flip band (400, 514.3]; primary uses
        -- combo_total 1000 (band (1000,1285.7]). enemies_in_aoe={T,U1,U2}: T(primary)=1100 flips on combo (+1),
        -- U1=450 flips on aoe_burst (+1), U2=600 no flip (>540). Expect 2.
        local eff_map = { T = 1100, U1 = 450, U2 = 600 }
        state.lina_eff_hp_magical = function(u) return eff_map[u] or math.huge end
        local actx = { combo_total = 1000, q_dmg = 200, w_dmg = 200 }
        local agot = state.fc_offense_value(actx, "T", { "T", "U1", "U2" })
        if agot ~= 2 then
            return { pass = false, reason = ("AoE flip got=%d want=2 (primary T + U1)"):format(agot) }
        end
        if state.fc_offense_value(nil, "T", nil) ~= 0 then return { pass = false, reason = "nil ctx must be 0" } end
        if state.fc_offense_value({ combo_total = 1000 }, nil, nil) ~= 0 then return { pass = false, reason = "nil target must be 0" } end
        return { pass = true }
    end,
}
state.tests["FCVW01_offense_value_weighted"] = {
    desc = "v0.5.164 D1: fc_offense_value_w sums HeroValue.of over the SAME flip set fc_offense_value counts (shared predicate); weighted, not a raw count",
    fn = function(cu)
        if type(state.fc_offense_value_w) ~= "function" then
            return { pass = false, reason = "state.fc_offense_value_w not exposed" }
        end
        local s_eff = state.lina_eff_hp_magical
        local s_of  = state.hero_value and state.hero_value.of
        _cu_push(cu, function()
            state.lina_eff_hp_magical = s_eff
            if state.hero_value then state.hero_value.of = s_of end
        end)
        -- pin the same flip geometry as FC01: combo 1000 (band (1000,1285.7]),
        -- aoe_burst 400 (band (400,514.3]). eff: T=1100 (primary flips),
        -- U1=450 (aoe flips), U2=600 (no flip).
        local eff_map = { T = 1100, U1 = 450, U2 = 600 }
        state.lina_eff_hp_magical = function(u) return eff_map[u] or math.huge end
        -- value stub: T worth 1.0, U1 worth 0.4 -> W = 1.4 over the 2 flips.
        local val = { T = 1.0, U1 = 0.4, U2 = 0.9 }
        state.hero_value.of = function(u, _peers) return val[u] or 0 end
        local actx = { combo_total = 1000, q_dmg = 200, w_dmg = 200 }
        local w = state.fc_offense_value_w(actx, "T", { "T", "U1", "U2" })
        if math.abs(w - 1.4) > 1e-9 then
            return { pass = false, reason = ("weighted W got=%s want=1.4 (T 1.0 + U1 0.4)"):format(tostring(w)) }
        end
        -- count parity: the unweighted count over the same inputs is still 2.
        if state.fc_offense_value(actx, "T", { "T", "U1", "U2" }) ~= 2 then
            return { pass = false, reason = "shared predicate broke fc_offense_value count (want 2)" }
        end
        -- nil guards
        if state.fc_offense_value_w(nil, "T", nil) ~= 0 then return { pass = false, reason = "nil ctx -> 0" } end
        if state.fc_offense_value_w({ combo_total = 1000 }, nil, nil) ~= 0 then return { pass = false, reason = "nil target -> 0" } end
        return { pass = true }
    end,
}
state.tests["FCVW02_turn_factor"] = {
    desc = "v0.5.165 D2: fc_turn_factor lowers the turn factor as the weighted flip value W rises (W nil/<=1 -> K.FC_TURN; higher W -> lower; huge W -> floored at K.FC_TURN_MIN)",
    fn = function(_cu)
        if type(state.fc_turn_factor) ~= "function" then
            return { pass = false, reason = "state.fc_turn_factor not exposed" }
        end
        local base = K.FC_TURN
        if state.fc_turn_factor(nil) ~= base then return { pass = false, reason = "nil W must be base" } end
        if state.fc_turn_factor(1.0) ~= base then return { pass = false, reason = "W=1 must be base" } end
        if state.fc_turn_factor(0.4) ~= base then return { pass = false, reason = "W<1 must be base" } end
        local want2 = math.max(K.FC_TURN_MIN, base * (1 - K.FC_TURN_VALUE_RELAX * 1))
        if math.abs(state.fc_turn_factor(2.0) - want2) > 1e-9 then
            return { pass = false, reason = ("W=2 got=%s want=%s"):format(tostring(state.fc_turn_factor(2.0)), tostring(want2)) }
        end
        if state.fc_turn_factor(3.0) > state.fc_turn_factor(2.0) then
            return { pass = false, reason = "higher W must not raise the factor" }
        end
        if math.abs(state.fc_turn_factor(99.0) - K.FC_TURN_MIN) > 1e-9 then
            return { pass = false, reason = "huge W must floor at K.FC_TURN_MIN" }
        end
        return { pass = true }
    end,
}
state.tests["FCVW03_aim_prefer"] = {
    desc = "v0.5.166 D3: fc_aim_prefer -- aim off = strictly closer; aim on = closer beyond K.HV_AIM_DIST_EPS, or within the band the higher HeroValue wins; clearly-farther always loses",
    fn = function(_cu)
        if type(state.fc_aim_prefer) ~= "function" then
            return { pass = false, reason = "state.fc_aim_prefer not exposed" }
        end
        local eps = K.HV_AIM_DIST_EPS
        if not state.fc_aim_prefer(500, 0.4, nil, nil, true) then return { pass = false, reason = "nil cur must prefer" } end
        if not state.fc_aim_prefer(100, 0.1, 200, 9.9, false) then return { pass = false, reason = "aim off: closer must win" } end
        if state.fc_aim_prefer(200, 9.9, 100, 0.1, false) then return { pass = false, reason = "aim off: farther must lose even if higher value" } end
        if not state.fc_aim_prefer(100, 0.1, 100 + eps + 50, 9.9, true) then return { pass = false, reason = "aim on: clearly-closer must win" } end
        if state.fc_aim_prefer(100 + eps + 50, 9.9, 100, 0.1, true) then return { pass = false, reason = "aim on: clearly-farther must lose" } end
        if not state.fc_aim_prefer(100 + eps - 10, 0.9, 100, 0.4, true) then return { pass = false, reason = "aim on: in-band higher value must win" } end
        if state.fc_aim_prefer(100 + eps - 10, 0.3, 100, 0.4, true) then return { pass = false, reason = "aim on: in-band lower value must lose" } end
        return { pass = true }
    end,
}
state.tests["FCAR01_arbiter_fields"] = {
    desc = "v0.5.16x D4 (design 8.1): fc_arbiter_fields normalizes a decision record -> the unified kv line (numbers fixed-width, fired/bailout y/n, bailout 3-state na, absent numerics na, claim default none, nil record safe)",
    fn = function(_cu)
        if type(state.fc_arbiter_fields) ~= "function" then
            return { pass = false, reason = "state.fc_arbiter_fields not exposed" }
        end
        local f = state.fc_arbiter_fields({ tier = "kill", reason = "opener", fired = true,
            W = 1.4, count = 2, cluster = 3, keff = 0.5, ae = 2.1, ee = 3.0, bailout = true, claim = "B", stacks = 7 })
        local want = { tier = "kill", reason = "opener", fired = "y", W = "1.40", count = "2", cluster = "3",
                       keff = "0.50", ae = "2.10", ee = "3.00", bailout = "y", claim = "B", stacks = "7" }
        for k, v in pairs(want) do
            if f[k] ~= v then return { pass = false, reason = ("full.%s got=%s want=%s"):format(k, tostring(f[k]), v) } end
        end
        local s = state.fc_arbiter_fields({ tier = "hold", reason = "unturnable", fired = false })
        local sw = { fired = "n", W = "na", count = "na", cluster = "na", keff = "na", ae = "na", ee = "na", bailout = "na", claim = "none", stacks = "na" }
        for k, v in pairs(sw) do
            if s[k] ~= v then return { pass = false, reason = ("sparse.%s got=%s want=%s"):format(k, tostring(s[k]), v) } end
        end
        if state.fc_arbiter_fields({ bailout = false }).bailout ~= "n" then
            return { pass = false, reason = "bailout=false must be n (3-state)" }
        end
        if state.fc_arbiter_fields(nil).tier ~= "?" then
            return { pass = false, reason = "nil record must default tier ?" }
        end
        -- v0.5.168.4 D4.3: the ordered serializer (canonical field order, design 8.1)
        if type(state.fc_arbiter_line) ~= "function" then
            return { pass = false, reason = "state.fc_arbiter_line not exposed" }
        end
        local want_line = "fc_arbiter | tier=kill | reason=opener | fired=y | W=1.40 | count=2 | cluster=3 | keff=0.50 | ae=2.10 | ee=3.00 | bailout=y | claim=B | stacks=7"
        if state.fc_arbiter_line(f) ~= want_line then
            return { pass = false, reason = ("ordered line got=[%s]"):format(tostring(state.fc_arbiter_line(f))) }
        end
        return { pass = true }
    end,
}
state.tests["FCDEF10_cold_open"] = {
    desc = "v0.5.160 A3 fc_cold_open: Fiery Soul stacks <= STACK_OPENER_MAX -> standalone cold-open true; above -> false; nil ctx -> false",
    fn = function(_cu)
        if type(state.fc_cold_open) ~= "function" then
            return { pass = false, reason = "state.fc_cold_open not exposed" }
        end
        local cases = {
            { s = 0, want = true }, { s = 3, want = true }, { s = 4, want = false }, { s = 7, want = false },
        }
        for _, c in ipairs(cases) do
            local got = state.fc_cold_open({ fiery_soul_stacks = c.s })
            if got ~= c.want then
                return { pass = false, reason = ("stacks=%d got=%s want=%s"):format(c.s, tostring(got), tostring(c.want)) }
            end
        end
        if state.fc_cold_open(nil) ~= false then return { pass = false, reason = "nil ctx -> false" } end
        if state.fc_cold_open({}) ~= true then return { pass = false, reason = "missing stacks defaults 0 -> true" } end
        return { pass = true }
    end,
}
state.tests["FCDEF11_jugg_omni_defer"] = {
    desc = "v0.5.160.2 Note-1 jugg_omni_should_defer: defer iff no immediate save (Ghost/E-blade) AND HP >= K.JUGG_OMNI_MIN_HP_ACCEPT",
    fn = function(_cu)
        if type(state.jugg_omni_should_defer) ~= "function" then
            return { pass = false, reason = "state.jugg_omni_should_defer not exposed" }
        end
        local floor = K.JUGG_OMNI_MIN_HP_ACCEPT
        local cases = {
            { imm = true,  hp = 1000,      want = false, why = "Ghost/E-blade ready -> immediate, no defer" },
            { imm = false, hp = floor,     want = true,  why = "no immediate + HP at floor -> defer" },
            { imm = false, hp = floor + 1, want = true,  why = "no immediate + HP above floor -> defer" },
            { imm = false, hp = floor - 1, want = false, why = "no immediate + HP below floor -> survive at cast" },
            { imm = true,  hp = 10,        want = false, why = "immediate wins regardless of HP" },
        }
        for _, c in ipairs(cases) do
            local got = state.jugg_omni_should_defer(c.imm, c.hp)
            if got ~= c.want then
                return { pass = false, reason = ("imm=%s hp=%d got=%s want=%s (%s)"):format(tostring(c.imm), c.hp, tostring(got), tostring(c.want), c.why) }
            end
        end
        return { pass = true }
    end,
}
state.tests["FCESC01_worth_flying"] = {
    desc = "Phase B fc_escape_worth_flying: fly iff best-overall terrain-locked AND >= margin safer than walkable",
    fn = function(_cu)
        if type(state.fc_escape_worth_flying) ~= "function" then
            return { pass = false, reason = "state.fc_escape_worth_flying not exposed" }
        end
        local M = K.FC_ESCAPE_SAFER_MARGIN
        local cases = {
            { best = 10, info = { locked = true,  walkable_score = 10 + M },     want = true,  why = "locked + exactly margin safer" },
            { best = 10, info = { locked = true,  walkable_score = 10 + M - 1 }, want = false, why = "locked but under margin" },
            { best = 10, info = { locked = false, walkable_score = 10 + M + 5 }, want = false, why = "safer but walkable -> just walk" },
            { best = 10, info = nil,                                            want = false, why = "no info -> no fly" },
        }
        for _, c in ipairs(cases) do
            local got = state.fc_escape_worth_flying(c.best, c.info, M) and true or false
            if got ~= c.want then
                return { pass = false, reason = ("got=%s want=%s (%s)"):format(tostring(got), tostring(c.want), c.why) }
            end
        end
        return { pass = true }
    end,
}
state.tests["FCESC02_claim_gate"] = {
    desc = "Phase B fc_escape_claim: fires on lethal + locked-safer + no-blink; defers when blink covers / not lethal / walkable",
    fn = function(cu)
        if type(state.fc_escape_claim) ~= "function" then
            return { pass = false, reason = "state.fc_escape_claim not exposed" }
        end
        local s_ssn, s_gi = Escape.SafestSpotNear, Escape.GankImminent
        local s_hp, s_mhp = Entity.GetHealth, Entity.GetMaxHealth
        local s_bc, s_armed = state.fc_escape_blink_covers, state.armed_threats
        _cu_push(cu, function()
            Escape.SafestSpotNear, Escape.GankImminent = s_ssn, s_gi
            Entity.GetHealth, Entity.GetMaxHealth = s_hp, s_mhp
            state.fc_escape_blink_covers, state.armed_threats = s_bc, s_armed
        end)
        Entity.GetHealth    = function() return 1000 end
        Entity.GetMaxHealth = function() return 1000 end          -- full HP -> not low-HP lethal
        state.armed_threats = {}                                  -- no armed lethal threat
        local locked_info = { locked = true,  walkable_score = 1000 }
        local walk_info   = { locked = false, walkable_score = 1000 }
        Escape.SafestSpotNear = function() return { x = 700, y = 0, z = 0 }, 1, locked_info end

        -- gank + locked-safer + blink does NOT cover -> claim fires
        Escape.GankImminent = function() return true end
        state.fc_escape_blink_covers = function() return false end
        if state.fc_escape_claim(nil) == nil then return { pass = false, reason = "expected claim (gank+locked+no-blink)" } end

        -- blink covers -> defer
        state.fc_escape_blink_covers = function() return true end
        if state.fc_escape_claim(nil) ~= nil then return { pass = false, reason = "should defer when blink covers" } end

        -- not lethal (no gank, full HP, no armed) -> nil
        state.fc_escape_blink_covers = function() return false end
        Escape.GankImminent = function() return false end
        if state.fc_escape_claim(nil) ~= nil then return { pass = false, reason = "should be nil when not lethal" } end

        -- lethal but the safe spot is walkable -> nil (just walk)
        Escape.GankImminent = function() return true end
        Escape.SafestSpotNear = function() return { x = 0, y = 700, z = 0 }, 1, walk_info end
        if state.fc_escape_claim(nil) ~= nil then return { pass = false, reason = "should be nil when spot is walkable" } end

        return { pass = true }
    end,
}
state.tests["FCESC03_fire_arms_move_and_veto"] = {
    desc = "Phase B: arm_fc_escape_move sets the post-move slot (FC modifier + recompute_dest, slot-guarded); fc_escape_active reads the veto cache",
    fn = function(cu)
        if type(state.arm_fc_escape_move) ~= "function" or type(state.fc_escape_active) ~= "function" then
            return { pass = false, reason = "fc_escape fire path not exposed" }
        end
        local s_pending, s_cache = state.pending_post_airborne_move, state.fc_escape_active_cache
        _cu_push(cu, function()
            state.pending_post_airborne_move = s_pending
            state.fc_escape_active_cache = s_cache
        end)
        state.pending_post_airborne_move = nil
        state.arm_fc_escape_move({ x = 700, y = 0, z = 0 })
        local p = state.pending_post_airborne_move
        if not p then return { pass = false, reason = "pending not armed" } end
        if p.modifier_name ~= "modifier_lina_flame_cloak" then return { pass = false, reason = "wrong modifier" } end
        if not p.moves_during_airborne then return { pass = false, reason = "FC must be movable-throughout" } end
        if type(p.recompute_dest) ~= "function" then return { pass = false, reason = "recompute_dest missing" } end
        state.arm_fc_escape_move({ x = 0, y = 900, z = 0 })   -- slot busy -> must NOT clobber
        if state.pending_post_airborne_move.dest.x ~= 700 then return { pass = false, reason = "slot guard failed" } end
        state.fc_escape_active_cache = { t = now(), active = true }
        if not state.fc_escape_active(nil) then return { pass = false, reason = "veto cache not read" } end
        return { pass = true }
    end,
}
state.tests["FCESC04_rides_active_fc"] = {
    desc = "Phase B: FC already active (modifier up) + claim holds -> fc_escape_tick arms the flee-move WITHOUT recasting (coordinate with defensive FC)",
    fn = function(cu)
        if type(state.fc_escape_tick) ~= "function" then
            return { pass = false, reason = "fc_escape_tick not exposed" }
        end
        local s_claim, s_hasmod = state.fc_escape_claim, NPC.HasModifier
        local s_pending = state.pending_post_airborne_move
        _cu_push(cu, function()
            state.fc_escape_claim, NPC.HasModifier = s_claim, s_hasmod
            state.pending_post_airborne_move = s_pending
        end)
        state.fc_escape_claim = function() return { x = 700, y = 0, z = 0 }, { locked = true }, { lethal = true } end
        NPC.HasModifier = function(_u, m) return m == "modifier_lina_flame_cloak" end  -- FC already up
        state.pending_post_airborne_move = nil
        state.fc_escape_tick()
        local p = state.pending_post_airborne_move
        if not p then return { pass = false, reason = "flee-move not armed while FC already active (self_alive_ok?)" } end
        if p.intent ~= "fc_escape" or p.modifier_name ~= "modifier_lina_flame_cloak" then
            return { pass = false, reason = "wrong pending shape" }
        end
        if type(p.recompute_dest) ~= "function" then return { pass = false, reason = "recompute_dest missing" } end
        return { pass = true }
    end,
}
state.tests["FCCH01_committing"] = {
    desc = "Phase C2 fc_chase_committing: offense-recent (last_offense_target) OR fc_tf_opener_fired, AND fc_offense_commit_ok",
    fn = function(cu)
        if type(state.fc_chase_committing) ~= "function" then
            return { pass = false, reason = "fc_chase_committing not exposed" }
        end
        local s_ot, s_od, s_of, s_co = state.last_offense_target, state.last_offense_dispatch_t,
                                        state.fc_tf_opener_fired, state.fc_offense_commit_ok
        _cu_push(cu, function()
            state.last_offense_target, state.last_offense_dispatch_t = s_ot, s_od
            state.fc_tf_opener_fired, state.fc_offense_commit_ok = s_of, s_co
        end)
        local TGT = {}
        state.fc_offense_commit_ok = function() return true end
        -- offense-recent on TGT -> committing
        state.last_offense_target, state.last_offense_dispatch_t, state.fc_tf_opener_fired = TGT, now(), false
        if not state.fc_chase_committing(nil, TGT) then return { pass = false, reason = "offense-recent should commit" } end
        -- offense on a DIFFERENT target -> not committing (no opener)
        state.last_offense_target = {}
        if state.fc_chase_committing(nil, TGT) then return { pass = false, reason = "offense on other target must not commit" } end
        -- opener fired -> committing even without an offense stamp
        state.fc_tf_opener_fired = true
        if not state.fc_chase_committing(nil, TGT) then return { pass = false, reason = "opener-fired should commit" } end
        -- A2 gate false -> never commits
        state.fc_offense_commit_ok = function() return false end
        if state.fc_chase_committing(nil, TGT) then return { pass = false, reason = "A2 gate false must block" } end
        return { pass = true }
    end,
}
state.tests["FCCH02_claim_gate"] = {
    desc = "Phase C2 fc_chase_claim: committing + finishable + fleeing + target-winding + winnable(Lina chord < target wind) + risk-ok -> intercept; any gate off -> nil",
    fn = function(cu)
        if type(state.fc_chase_claim) ~= "function" then
            return { pass = false, reason = "fc_chase_claim not exposed" }
        end
        local s_commit, s_pred, s_ms = state.fc_chase_committing, state.predict_target_pos, state.fc_chase_move_speed
        local s_geo, s_wind, s_ars, s_alive = Entity.GetAbsOrigin, state.fc_chase_target_winding,
                                              Escape.AdvanceRiskScore, Entity.IsAlive
        local s_origin, s_gms = NPCLib.origin, NPC.GetMovementSpeed
        _cu_push(cu, function()
            state.fc_chase_committing, state.predict_target_pos, state.fc_chase_move_speed = s_commit, s_pred, s_ms
            Entity.GetAbsOrigin, state.fc_chase_target_winding = s_geo, s_wind
            Escape.AdvanceRiskScore, Entity.IsAlive = s_ars, s_alive
            NPCLib.origin, NPC.GetMovementSpeed = s_origin, s_gms
        end)
        local TGT = {}
        local CTX = { target = TGT, combo_kill = true }   -- finishable
        local WIND = function() return true, { flee_point = { x = 1200, y = 0, z = 0 }, walk = 3000, straight = 600 } end
        NPCLib.origin = function() return { x = 0, y = 0, z = 0 } end
        Entity.GetAbsOrigin = function() return { x = 400, y = 0, z = 0 } end   -- current target pos
        Entity.IsAlive = function() return true end
        NPC.GetMovementSpeed = function() return 300 end
        state.fc_chase_committing = function() return true end
        state.predict_target_pos = function() return { x = 440, y = 0, z = 0 } end   -- predicted FARTHER (440>400) -> fleeing
        state.fc_chase_move_speed = function() return 400 end
        -- target winds 3000u to a cutoff point 1200u from Lina: catch 1200/400=3.0 < escape 3000/300=10.0 -> winnable
        state.fc_chase_target_winding = WIND
        Escape.AdvanceRiskScore = function() return 10 end

        if not state.fc_chase_claim(CTX, TGT) then return { pass = false, reason = "expected a claim (all gates ok)" } end
        -- not committing -> nil
        state.fc_chase_committing = function() return false end
        if state.fc_chase_claim(CTX, TGT) ~= nil then return { pass = false, reason = "not committing must be nil" } end
        state.fc_chase_committing = function() return true end
        -- not finishable -> nil (returns before the predict)
        if state.fc_chase_claim({ target = TGT, combo_kill = false, eff_hp_magical = 9999, r_impact_eff = 100 }, TGT) ~= nil then
            return { pass = false, reason = "not finishable must be nil" } end
        -- not fleeing (predicted pos APPROACHES me) -> nil
        state.predict_target_pos = function() return { x = 360, y = 0, z = 0 } end
        if state.fc_chase_claim(CTX, TGT) ~= nil then return { pass = false, reason = "not fleeing must be nil" } end
        state.predict_target_pos = function() return { x = 440, y = 0, z = 0 } end
        -- not winding (no cutoff) -> nil
        state.fc_chase_target_winding = function() return false, { src = "x" } end
        if state.fc_chase_claim(CTX, TGT) ~= nil then return { pass = false, reason = "no cutoff must be nil" } end
        -- unwinnable: target barely winds (walk 800) vs Lina chord 1200 -> target arrives first -> nil
        state.fc_chase_target_winding = function() return true, { flee_point = { x = 1200, y = 0, z = 0 }, walk = 800, straight = 600 } end
        if state.fc_chase_claim(CTX, TGT) ~= nil then return { pass = false, reason = "unwinnable (Lina chord > target wind) must be nil" } end
        state.fc_chase_target_winding = WIND
        -- high risk -> nil
        Escape.AdvanceRiskScore = function() return 99 end
        if state.fc_chase_claim(CTX, TGT) ~= nil then return { pass = false, reason = "high risk must be nil" } end
        return { pass = true }
    end,
}
state.tests["FCCH03_cutoff_lock"] = {
    desc = "Phase C2 fc_chase_cutoff_locked: walk >> straight (BuildPath, trees counted) -> locked; straight walk -> not; BuildPath missing -> connectivity fallback",
    fn = function(cu)
        if type(state.fc_chase_cutoff_locked) ~= "function" then
            return { pass = false, reason = "fc_chase_cutoff_locked not exposed" }
        end
        local s_grid = GridNav
        _cu_push(cu, function() GridNav = s_grid end)
        local me = { x = 0, y = 0, z = 0 }
        local ip = { x = 1000, y = 0, z = 0 }
        GridNav = { BuildPath = function() return
            { { x = 0, y = 0 }, { x = 0, y = 900 }, { x = 1000, y = 900 }, { x = 1000, y = 0 } } end }  -- walk 2800
        if not state.fc_chase_cutoff_locked(me, ip) then return { pass = false, reason = "big detour should lock" } end
        GridNav = { BuildPath = function() return { { x = 0, y = 0 }, { x = 1000, y = 0 } } end }      -- walk 1000
        if state.fc_chase_cutoff_locked(me, ip) then return { pass = false, reason = "straight walk must not lock" } end
        GridNav = { IsTraversableFromTo = function() return false end }   -- fallback: no path -> lock
        if not state.fc_chase_cutoff_locked(me, ip) then return { pass = false, reason = "fallback no-path should lock" } end
        GridNav = { IsTraversableFromTo = function() return true end }    -- fallback: path exists -> no lock
        if state.fc_chase_cutoff_locked(me, ip) then return { pass = false, reason = "fallback path-exists must not lock" } end
        return { pass = true }
    end,
}
state.tests["FCTTK01_fc_ttk_sim"] = {
    desc = "v0.5.156.3 FC TTK sim: burst/autos/regen/FC-flip/BKB + DYNAMIC FS-stack climb on recasts",
    fn = function(_cu)
        if type(state.fc_ttk_sim) ~= "function" then
            return { pass = false, reason = "state.fc_ttk_sim not exposed" }
        end
        -- base_as 1.7 + per_mult 0 -> fs_interval = BAT/1.7 = 1.0s regardless of stacks
        -- (replicates the original fixed-1.0s cases). The dynamic cases set per_mult > 0.
        local base = { magic_mult = 1, phys_mult = 1, regen = 0, w_dmg = 0, q_dmg = 0,
            base_as = 1.7, per_mult = 0, stacks_off = 0, stacks_fc = 0,
            w_recast_t = math.huge, q_recast_t = math.huge, bkb = false }
        local function with(over)
            local o = {} for k, v in pairs(base) do o[k] = v end
            for k, v in pairs(over) do o[k] = v end return o
        end
        local function near(got, want)
            return (want == math.huge and got == math.huge)
                or (got ~= math.huge and math.abs(got - want) < 1e-6)
        end
        local cases = {
            { name = "burst_one_shot",   inp = with{ hp = 900,  burst = 1000, auto_avg = 0 },   fc = false, want = 0 },
            { name = "burst_plus_autos", inp = with{ hp = 1200, burst = 1000, auto_avg = 100 }, fc = false, want = 2.0 },
            { name = "regen_sustains",   inp = with{ hp = 1100, burst = 1000, auto_avg = 10, regen = 50 }, fc = false, want = math.huge },
            { name = "fc_flip_off",      inp = with{ hp = 1200, burst = 1000, auto_avg = 0 },   fc = false, want = math.huge },
            { name = "fc_flip_on",       inp = with{ hp = 1200, burst = 1000, auto_avg = 0 },   fc = true,  want = 0 },
            { name = "bkb_autos_only",   inp = with{ hp = 250,  burst = 1000, auto_avg = 100, bkb = true }, fc = false, want = 3.0 },
            -- DYNAMIC climb: per_mult 1.7 -> each +1 stack shortens the interval. autos
            -- 100/hit, hp 350. W recast t=1.5 -> 1 stack (interval 1.0->0.5), Q recast
            -- t=2.5 -> 2 stacks (->0.333); autos land t=1,2,2.5,3 -> kill at t=3.0.
            { name = "dynamic_recast_climb", inp = with{ hp = 350, burst = 0, auto_avg = 100,
                base_as = 1.7, per_mult = 1.7, stacks_off = 0, w_recast_t = 1.5, q_recast_t = 2.5 },
                fc = false, want = 3.0 },
            -- same but per_mult 0 (no climb): interval 1.0 throughout -> autos t=1,2,3,4 -> 4.0.
            { name = "no_climb_control", inp = with{ hp = 350, burst = 0, auto_avg = 100,
                base_as = 1.7, per_mult = 0, stacks_off = 0, w_recast_t = 1.5, q_recast_t = 2.5 },
                fc = false, want = 4.0 },
        }
        for _, c in ipairs(cases) do
            local got = state.fc_ttk_sim(c.inp, c.fc)
            if not near(got, c.want) then
                return { pass = false, reason = ("%s got=%s want=%s"):format(c.name, tostring(got), tostring(c.want)) }
            end
        end
        if state.fc_ttk_sim(nil, false) ~= math.huge then
            return { pass = false, reason = "nil inputs must be inf" }
        end
        return { pass = true }
    end,
}
state.tests["FCTTK02_fc_offense_ttk_trigger"] = {
    desc = "v0.5.157 FC TTK trigger: window=horizon; secure / accelerate / hold / refuse_no_secure / refuse_unkillable (mocks sim+inputs+window)",
    fn = function(cu)
        if type(state.fc_offense_ttk) ~= "function" then
            return { pass = false, reason = "state.fc_offense_ttk not exposed" }
        end
        local s_sim, s_in, s_win = state.fc_ttk_sim, state.fc_ttk_inputs, state.fc_offense_window
        local s_unk, s_lot = Target.IsUnkillableNow, Target.HasReadyLotus
        _cu_push(cu, function()
            state.fc_ttk_sim = s_sim; state.fc_ttk_inputs = s_in; state.fc_offense_window = s_win
            Target.IsUnkillableNow = s_unk; Target.HasReadyLotus = s_lot
        end)
        Target.IsUnkillableNow  = function() return false end
        Target.HasReadyLotus    = function() return false end
        state.fc_ttk_inputs     = function() return { bkb = false } end
        state.fc_offense_window = function() return 12.0 end  -- generic = horizon (deterministic for the test)
        local off_v, fc_v = 0, 0
        state.fc_ttk_sim = function(_inp, with_fc) return with_fc and fc_v or off_v end
        local tgt = { __fcttk = true }
        local cases = {
            { name = "secure",        off = math.huge, fc = 5.0,       want = true  },  -- bare misses horizon, FC kills
            { name = "refuse_no_sec", off = math.huge, fc = math.huge, want = false }, -- FC also misses horizon -> refuse
            { name = "accelerate",    off = 10.0,      fc = 5.0,       want = true  },  -- saved 5 >= max(1.5, 0.25*10=2.5)
            { name = "hold",          off = 4.0,       fc = 3.5,       want = false }, -- saved 0.5 < max(1.5, 1.0)
        }
        for _, c in ipairs(cases) do
            off_v, fc_v = c.off, c.fc
            local got = state.fc_offense_ttk({}, tgt) and true or false
            if got ~= c.want then
                return { pass = false, reason = ("%s off=%.2f fc=%.2f got=%s want=%s"):format(c.name, c.off, c.fc, tostring(got), tostring(c.want)) }
            end
        end
        Target.IsUnkillableNow = function() return true end
        off_v, fc_v = 5.0, 0.0
        if state.fc_offense_ttk({}, tgt) then
            return { pass = false, reason = "refuse_unkillable must not fire" }
        end
        return { pass = true }
    end,
}
state.tests["FCDEF01_grade_bands"] = {
    desc = "v0.5.158 FC defense grade: Tier-A lethal-survivable / Tier-B heavy / none (poke + unsurvivable + edges)",
    fn = function(_cu)
        if type(state.fc_defense_grade) ~= "function" then
            return { pass = false, reason = "state.fc_defense_grade not exposed" }
        end
        local none = function() return false end
        local cases = {
            { name = "A_lethal",   hp = 1000, D = 1200, want = "A" },
            { name = "B_heavy",    hp = 1000, D =  800, want = "B" },
            { name = "none_poke",  hp = 1000, D =  400, want = "none" },
            { name = "none_unsurv",hp = 1000, D = 1600, want = "none" },
            { name = "A_edge_hp",  hp = 1000, D = 1000, want = "A" },
            { name = "B_edge_flr", hp = 1000, D =  600, want = "B" },
        }
        for _, c in ipairs(cases) do
            local got = state.fc_defense_grade(c.hp, 1000, c.D, false, false, none)
            if got ~= c.want then
                return { pass = false, reason = ("%s D=%d got=%s want=%s"):format(c.name, c.D, got, c.want) }
            end
        end
        if state.fc_defense_grade(nil, nil, nil, false, false, none) ~= "none" then
            return { pass = false, reason = "nil inputs must be none" }
        end
        return { pass = true }
    end,
}
state.tests["FCDEF02_grade_coverage"] = {
    desc = "v0.5.158 FC defense matched coverage: BKB/Eul/etc release a burst-A; only BKB releases a sustained-A; pierce -> BKB no cover",
    fn = function(_cu)
        if type(state.fc_defense_grade) ~= "function" then
            return { pass = false, reason = "state.fc_defense_grade not exposed" }
        end
        local function ready(set) return function(n) return set[n] == true end end
        local cases = {
            { name = "burst_bkb",      pierce = false, sust = false, set = { item_black_king_bar = true }, want = "none" },
            { name = "burst_eul",      pierce = false, sust = false, set = { item_cyclone = true },        want = "none" },
            { name = "burst_linkens",  pierce = false, sust = false, set = { item_sphere = true },         want = "none" },
            { name = "burst_pierced",  pierce = true,  sust = false, set = { item_black_king_bar = true }, want = "A" },
            { name = "burst_none",     pierce = false, sust = false, set = {},                             want = "A" },
            { name = "sustain_eul",    pierce = false, sust = true,  set = { item_cyclone = true },        want = "A" },
            { name = "sustain_bkb",    pierce = false, sust = true,  set = { item_black_king_bar = true }, want = "none" },
        }
        for _, c in ipairs(cases) do
            local got = state.fc_defense_grade(1000, 1000, 1200, c.pierce, c.sust, ready(c.set))
            if got ~= c.want then
                return { pass = false, reason = ("%s got=%s want=%s"):format(c.name, got, c.want) }
            end
        end
        return { pass = true }
    end,
}
state.tests["FCDEF03_grade_last_resort"] = {
    desc = "v0.5.158.4 FC defense last-resort: an unsurvivable/heavy magical hit fires Tier-B when last_resort, none under the strict (proactive) ceiling",
    fn = function(_cu)
        if type(state.fc_defense_grade) ~= "function" then
            return { pass = false, reason = "state.fc_defense_grade not exposed" }
        end
        local none = function() return false end
        -- HP 1000: D=1600 is unsurvivable (>= HP/0.65=1538); D=800 heavy; D=400 poke.
        local cases = {
            { name = "unsurv_lastresort", D = 1600, lr = true,  want = "B" },
            { name = "unsurv_strict",     D = 1600, lr = false, want = "none" },
            { name = "poke_lastresort",   D = 400,  lr = true,  want = "none" },
            { name = "heavy_lastresort",  D = 800,  lr = true,  want = "B" },
        }
        for _, c in ipairs(cases) do
            local got = state.fc_defense_grade(1000, 1000, c.D, false, false, none, c.lr)
            if got ~= c.want then
                return { pass = false, reason = ("%s D=%d lr=%s got=%s want=%s"):format(c.name, c.D, tostring(c.lr), got, c.want) }
            end
        end
        return { pass = true }
    end,
}
state.tests["FCDEF04_claim_wrapper"] = {
    desc = "v0.5.158 FC defense LIVE claim wrapper (real grader, no spy): magical-only filter (e), pierce threading, armed-D severity fallback, proactive band <35%HP+>=2 enemies + count threshold (d), item-release wiring (b), Tier-A veto input (c), threat_mod last-resort path",
    fn = function(cu)
        if type(state.fc_defense_claim) ~= "function" then
            return { pass = false, reason = "state.fc_defense_claim not exposed" }
        end
        -- Save every seam the live wrapper reads; restore LIFO after the test.
        local s_self, s_armed, s_ready = state.self_npc, state.armed_threats, state.lina_save_ready
        local s_isal, s_ghp, s_gmhp, s_team = Entity.IsAlive, Entity.GetHealth, Entity.GetMaxHealth, Entity.GetTeamNum
        local s_orig, s_near = NPCLib.origin, Heroes.InRadius
        local s_tal, s_nill = Target.IsAlive, Target.NotIllusion
        local s_prof, s_canon, s_sev = TD.THREAT_PROFILE, TD.CanonicalMod, TD.SeverityOf
        _cu_push(cu, function()
            state.self_npc, state.armed_threats, state.lina_save_ready = s_self, s_armed, s_ready
            Entity.IsAlive, Entity.GetHealth, Entity.GetMaxHealth, Entity.GetTeamNum = s_isal, s_ghp, s_gmhp, s_team
            NPCLib.origin, Heroes.InRadius = s_orig, s_near
            Target.IsAlive, Target.NotIllusion = s_tal, s_nill
            TD.THREAT_PROFILE, TD.CanonicalMod, TD.SeverityOf = s_prof, s_canon, s_sev
        end)

        -- Fixed mocks. Synthetic mods (absent from the real LINA_EXPECTED_DAMAGE)
        -- force D through the severity fallback we control via TD.SeverityOf.
        local ME = {}
        state.self_npc     = ME
        Entity.IsAlive     = function() return true end
        Entity.GetTeamNum  = function() return 2 end
        NPCLib.origin      = function() return { x = 0, y = 0, z = 0 } end
        Target.IsAlive     = function() return true end
        Target.NotIllusion = function() return true end
        TD.CanonicalMod    = function(m) return m end
        TD.THREAT_PROFILE  = {
            mod_fcdef04_mag   = { school = "magical",  pierces_spell_immunity = false },
            mod_fcdef04_mag_p = { school = "magical",  pierces_spell_immunity = true  },
            mod_fcdef04_phys  = { school = "physical" },
        }
        TD.SeverityOf = function() return "lethal" end   -- fc_severity_D("lethal", hpmax) = hpmax

        -- Per-case controllable seams.
        local hp_cur, hp_max = 1000, 1000
        Entity.GetHealth    = function() return hp_cur end
        Entity.GetMaxHealth = function() return hp_max end
        local NONE = {}
        local function chk(name, mod, c, m, near_n, readyT, want, threat_mod, lr)
            hp_cur, hp_max = c, m
            state.armed_threats = mod and { only = { threat_mod = mod } } or {}
            Heroes.InRadius = function() local t = {}; for i = 1, (near_n or 0) do t[i] = {} end; return t end
            local r = readyT or NONE
            state.lina_save_ready = function(name2) return r[name2] == true end
            local got = state.fc_defense_claim(nil, threat_mod, lr)
            if got ~= want then
                return ("%s got=%s want=%s"):format(name, tostring(got), tostring(want))
            end
            return nil
        end

        local cases = {
            -- (e) physical armed threat (no band) -> none: magical-only filter zeroes D.
            { "e_physical_none",       "mod_fcdef04_phys",  1000, 1000, 0, NONE, "none" },
            -- magical uncovered lethal -> A: the value the offense veto reads (c) + the reserve trigger (a).
            { "c_magical_uncovered_A", "mod_fcdef04_mag",   1000, 1000, 0, NONE, "A" },
            -- (b) magical + ready BKB (no pierce) -> none.
            { "b_magical_bkb_none",    "mod_fcdef04_mag",   1000, 1000, 0, { item_black_king_bar = true }, "none" },
            -- (b) magical + ready Eul -> none (burst coverage).
            { "b_magical_eul_none",    "mod_fcdef04_mag",   1000, 1000, 0, { item_cyclone = true }, "none" },
            -- pierce threading: magical-pierce + ready BKB -> still A (BKB cannot cover a pierce).
            { "pierce_bkb_A",          "mod_fcdef04_mag_p", 1000, 1000, 0, { item_black_king_bar = true }, "A" },
            -- (d) proactive band (v0.5.180: HP gate FC_DEF_PROACTIVE_HP 0.50 -> 0.35):
            -- <35% HP + 2 enemies, no item -> A. 300/1000 = 30% < 35% triggers the band.
            { "d_band_A",              nil,                  300, 1000, 2, NONE, "A" },
            -- (d) band + BKB ready -> none (sustained focus -> only BKB releases).
            { "d_band_bkb_none",       nil,                  300, 1000, 2, { item_black_king_bar = true }, "none" },
            -- (d) band + Eul ready (not BKB) -> still A (Eul does not release a sustained focus).
            { "d_band_eul_A",          nil,                  300, 1000, 2, { item_cyclone = true }, "A" },
            -- (d) count threshold: <35% HP but only 1 enemy near -> no band -> none.
            { "d_count_1_none",        nil,                  300, 1000, 1, NONE, "none" },
            -- (d) v0.5.180 threshold guard: 40% HP + 2 enemies, no item -> none. 40% is ABOVE the
            -- new 0.35 gate (the old 0.50 would have fired A here), so the gank band now holds.
            { "d_band_above_thresh_none", nil,               400, 1000, 2, NONE, "none" },
        }
        for _, c in ipairs(cases) do
            local err = chk(c[1], c[2], c[3], c[4], c[5], c[6], c[7])
            if err then return { pass = false, reason = err } end
        end

        -- threat_mod (.fire reactive) path + last_resort: an unsurvivable magical hit
        -- (D = 1000 >= HP/0.65 = 923 at hp=600) fires Tier-B as last-resort, none under
        -- the strict (proactive, no-last_resort) ceiling.
        local e1 = chk("threatmod_lastresort_B", nil, 600, 1000, 0, NONE, "B",    "mod_fcdef04_mag", true)
        if e1 then return { pass = false, reason = e1 } end
        local e2 = chk("threatmod_strict_none",  nil, 600, 1000, 0, NONE, "none", "mod_fcdef04_mag", false)
        if e2 then return { pass = false, reason = e2 } end

        -- v0.5.158.5: the claim's 2nd return (source) drives the proactive fire gate.
        -- A band-only Tier-A -> "proactive" (tick requires pressure); an armed magical
        -- Tier-A -> "armed" (tick pre-fires). The result VALUE is unchanged either way.
        hp_cur, hp_max = 300, 1000   -- v0.5.180: 30% < the new 0.35 gate, so the band still triggers
        state.armed_threats = {}
        Heroes.InRadius = function() return { {}, {} } end
        state.lina_save_ready = function() return false end
        local rb, sb = state.fc_defense_claim(nil)
        if rb ~= "A" or sb ~= "proactive" then
            return { pass = false, reason = ("band source r=%s src=%s want A/proactive"):format(tostring(rb), tostring(sb)) }
        end
        hp_cur, hp_max = 1000, 1000
        state.armed_threats = { only = { threat_mod = "mod_fcdef04_mag" } }
        Heroes.InRadius = function() return {} end
        local ra, sa = state.fc_defense_claim(nil)
        if ra ~= "A" or sa ~= "armed" then
            return { pass = false, reason = ("armed source r=%s src=%s want A/armed"):format(tostring(ra), tostring(sa)) }
        end

        return { pass = true }
    end,
}
state.tests["FCDEF05_under_pressure"] = {
    desc = "v0.5.158.5 fc_under_pressure: recent damage OR a committed attacker on self -> true; idle/kiting proximity (no damage, none committed) -> false",
    fn = function(cu)
        if type(state.fc_under_pressure) ~= "function" then
            return { pass = false, reason = "state.fc_under_pressure not exposed" }
        end
        local s_self = state.self_npc
        local s_orig, s_near, s_team = NPCLib.origin, Heroes.InRadius, Entity.GetTeamNum
        local s_tal, s_nill = Target.IsAlive, Target.NotIllusion
        local s_comm = state.is_committed_attacker_on_self
        local has_dmg = (type(Damage) == "table")
        local s_dmg = has_dmg and Damage.GetRecentDamage
        _cu_push(cu, function()
            state.self_npc = s_self
            NPCLib.origin, Heroes.InRadius, Entity.GetTeamNum = s_orig, s_near, s_team
            Target.IsAlive, Target.NotIllusion = s_tal, s_nill
            state.is_committed_attacker_on_self = s_comm
            if has_dmg then Damage.GetRecentDamage = s_dmg end
        end)
        state.self_npc     = {}
        NPCLib.origin      = function() return { x = 0, y = 0, z = 0 } end
        Entity.GetTeamNum  = function() return 2 end
        Target.IsAlive     = function() return true end
        Target.NotIllusion = function() return true end
        local enemies, committed_set, recent_dmg = {}, {}, 0
        Heroes.InRadius = function() return enemies end
        state.is_committed_attacker_on_self = function(h) return committed_set[h] == true end
        if has_dmg then Damage.GetRecentDamage = function() return recent_dmg end end

        local H1, H2 = {}, {}
        -- idle/kiting proximity: 2 enemies near, none committed, no damage -> false
        enemies = { H1, H2 }; committed_set = {}; recent_dmg = 0
        if state.fc_under_pressure() ~= false then
            return { pass = false, reason = "idle proximity should be false" }
        end
        -- recent damage -> true (assertable only when the Damage lib is present)
        if has_dmg then
            recent_dmg = 50
            if state.fc_under_pressure() ~= true then
                return { pass = false, reason = "recent damage should be true" }
            end
            recent_dmg = 0
        end
        -- a committed attacker on self -> true
        committed_set = { [H1] = true }
        if state.fc_under_pressure() ~= true then
            return { pass = false, reason = "committed attacker should be true" }
        end
        -- nothing near, no damage -> false
        enemies = {}; committed_set = {}
        if state.fc_under_pressure() ~= false then
            return { pass = false, reason = "no enemies/no damage should be false" }
        end
        return { pass = true }
    end,
}
state.tests["FCDEF06_bailout_ready"] = {
    desc = "A2 fc_bailout_ready: true iff >=1 K.FC_BAILOUT_SAVES item is ready; non-bailout (Lotus) -> false",
    fn = function(cu)
        if type(state.fc_bailout_ready) ~= "function" then return { pass = false, reason = "fc_bailout_ready not exposed" } end
        local s_self, s_ready = state.self_npc, state.lina_save_ready
        _cu_push(cu, function() state.self_npc = s_self; state.lina_save_ready = s_ready end)
        state.self_npc = {}
        local ready_set = {}
        state.lina_save_ready = function(n) return ready_set[n] == true end
        ready_set = {}
        if state.fc_bailout_ready() ~= false then return { pass = false, reason = "none ready -> false" } end
        ready_set = { item_cyclone = true }
        if state.fc_bailout_ready() ~= true then return { pass = false, reason = "Eul ready -> true" } end
        ready_set = { item_lotus_orb = true }
        if state.fc_bailout_ready() ~= false then return { pass = false, reason = "Lotus is not a bailout -> false" } end
        return { pass = true }
    end,
}
state.tests["FCDEF07_macro_turnable"] = {
    desc = "A2 fc_macro_turnable: TEAMFIGHT-only -- >=3 enemies applies the ratio (lost -> false); a pick (<3 enemies) or no enemies -> turnable",
    fn = function(cu)
        if type(state.fc_macro_turnable) ~= "function" then return { pass = false, reason = "fc_macro_turnable not exposed" } end
        local s_self, s_orig, s_team, s_near = state.self_npc, NPCLib.origin, Entity.GetTeamNum, Heroes.InRadius
        local s_tal, s_nill, s_ghp, s_gmhp = Target.IsAlive, Target.NotIllusion, Entity.GetHealth, Entity.GetMaxHealth
        _cu_push(cu, function()
            state.self_npc = s_self; NPCLib.origin = s_orig; Entity.GetTeamNum = s_team; Heroes.InRadius = s_near
            Target.IsAlive = s_tal; Target.NotIllusion = s_nill; Entity.GetHealth = s_ghp; Entity.GetMaxHealth = s_gmhp
        end)
        state.self_npc = {}; NPCLib.origin = function() return { x = 0, y = 0, z = 0 } end; Entity.GetTeamNum = function() return 2 end
        Target.IsAlive = function() return true end; Target.NotIllusion = function() return true end
        Entity.GetHealth = function() return 1000 end; Entity.GetMaxHealth = function() return 1000 end  -- each hero eff = 1.0
        local friends, enemies = {}, {}
        Heroes.InRadius = function(_, _, _, tt) return (tt == Enum.TeamType.TEAM_FRIEND) and friends or enemies end
        friends = { {}, {}, {} }; enemies = { {}, {}, {} }   -- 3v3 teamfight: 3.0 >= 0.8*3.0 = 2.4 -> turnable
        if state.fc_macro_turnable() ~= true then return { pass = false, reason = "3v3 should be turnable" } end
        friends = { {} }; enemies = { {}, {}, {} }            -- 1v3 teamfight: 1.0 >= 2.4 false -> not turnable
        if state.fc_macro_turnable() ~= false then return { pass = false, reason = "1v3 should not be turnable" } end
        friends = { {} }; enemies = { {}, {} }               -- v0.5.159 fix: 1v2 is a PICK (<3 enemies) -> turnable (was wrongly false)
        if state.fc_macro_turnable() ~= true then return { pass = false, reason = "1v2 pick should be turnable" } end
        friends = { {}, {} }; enemies = {}                   -- no enemies -> trivially turnable
        if state.fc_macro_turnable() ~= true then return { pass = false, reason = "no enemies should be turnable" } end
        return { pass = true }
    end,
}
state.tests["FCDEF08_dest_safe"] = {
    desc = "A2 fc_dest_safe: gank imminent OR high AdvanceRiskScore OR no ally near -> false; safe+ally -> true",
    fn = function(cu)
        if type(state.fc_dest_safe) ~= "function" then return { pass = false, reason = "fc_dest_safe not exposed" } end
        local s_self, s_gank, s_orig, s_team, s_near = state.self_npc, state.gank_imminent_self, NPCLib.origin, Entity.GetTeamNum, Heroes.InRadius
        local s_tal, s_nill = Target.IsAlive, Target.NotIllusion
        local has_ars = (type(Escape) == "table" and type(Escape.AdvanceRiskScore) == "function")
        local s_ars = has_ars and Escape.AdvanceRiskScore
        _cu_push(cu, function()
            state.self_npc = s_self; state.gank_imminent_self = s_gank; NPCLib.origin = s_orig
            Entity.GetTeamNum = s_team; Heroes.InRadius = s_near; Target.IsAlive = s_tal; Target.NotIllusion = s_nill
            if has_ars then Escape.AdvanceRiskScore = s_ars end
        end)
        state.self_npc = {}; NPCLib.origin = function() return { x = 0, y = 0, z = 0 } end; Entity.GetTeamNum = function() return 2 end
        Target.IsAlive = function() return true end; Target.NotIllusion = function() return true end
        local gank, risk, allies = false, 10, { {} }
        state.gank_imminent_self = function() return gank end
        if has_ars then Escape.AdvanceRiskScore = function() return risk end end
        Heroes.InRadius = function() return allies end
        gank = false; risk = 10; allies = { {} }
        if state.fc_dest_safe() ~= true then return { pass = false, reason = "safe + ally -> true" } end
        gank = true
        if state.fc_dest_safe() ~= false then return { pass = false, reason = "gank imminent -> false" } end
        gank = false
        if has_ars then
            risk = 99
            if state.fc_dest_safe() ~= false then return { pass = false, reason = "high risk -> false" } end
            risk = 10
        end
        allies = {}
        if state.fc_dest_safe() ~= false then return { pass = false, reason = "no ally -> false" } end
        return { pass = true }
    end,
}
state.tests["FCDEF09_offense_commit_ok"] = {
    desc = "A2 fc_offense_commit_ok: TEAMFIGHT-scoped -- pick (<3 enemies) -> no-op true; else macro_turnable AND (favorable OR dest_safe OR bailout)",
    fn = function(cu)
        if type(state.fc_offense_commit_ok) ~= "function" then return { pass = false, reason = "fc_offense_commit_ok not exposed" } end
        local s_en, s_mt, s_fv, s_ds, s_br = state.fc_enemies_near, state.fc_macro_turnable, state.fc_macro_favorable, state.fc_dest_safe, state.fc_bailout_ready
        _cu_push(cu, function() state.fc_enemies_near = s_en; state.fc_macro_turnable = s_mt; state.fc_macro_favorable = s_fv; state.fc_dest_safe = s_ds; state.fc_bailout_ready = s_br end)
        local en, mt, fv, ds, br = 3, true, false, true, true
        state.fc_enemies_near    = function() return en end
        state.fc_macro_turnable  = function() return mt end
        state.fc_macro_favorable = function() return fv end
        state.fc_dest_safe       = function() return ds end
        state.fc_bailout_ready   = function() return br end
        en, mt, fv, ds, br = 3, true, false, true, false
        if state.fc_offense_commit_ok({}, "T") ~= true then return { pass = false, reason = "TF turnable+safe -> true" } end
        en, mt, fv, ds, br = 3, true, false, false, true
        if state.fc_offense_commit_ok({}, "T") ~= true then return { pass = false, reason = "TF turnable+bailout -> true" } end
        en, mt, fv, ds, br = 3, true, false, false, false
        if state.fc_offense_commit_ok({}, "T") ~= false then return { pass = false, reason = "TF turnable-but-behind uninsured -> false" } end
        en, mt, fv, ds, br = 3, true, true, false, false
        if state.fc_offense_commit_ok({}, "T") ~= true then return { pass = false, reason = "TF favorable -> no insure needed -> true" } end
        en, mt, fv, ds, br = 3, false, true, true, true
        if state.fc_offense_commit_ok({}, "T") ~= false then return { pass = false, reason = "TF unturnable -> false (favorable moot)" } end
        en, mt, fv, ds, br = 2, false, false, false, false
        if state.fc_offense_commit_ok({}, "T") ~= true then return { pass = false, reason = "pick (<3 enemies) -> no-op true" } end
        return { pass = true }
    end,
}
state.tests["W01_combo_can_kill"] = {
    desc = "v0.5.137: combo_can_kill = remaining Q+R burst kills target (conservative 1.05; W excluded; v0.5.150: R/Q on-CD not credited; v0.5.153: FC +35% amp active-only)",
    fn = function(cu)
        if type(state.combo_can_kill) ~= "function" then
            return { pass = false, reason = "state.combo_can_kill not exposed" }
        end
        local s_r, s_q, s_w, s_eff = state.lina_r_damage, state.lina_q_damage,
                                     state.lina_w_damage, state.lina_eff_hp_magical
        local s_rr, s_qr = state.lina_r_ready, state.lina_q_ready
        local s_fc = state.lina_fc_active
        _cu_push(cu, function()
            state.lina_r_damage = s_r; state.lina_q_damage = s_q
            state.lina_w_damage = s_w; state.lina_eff_hp_magical = s_eff
            state.lina_r_ready = s_rr; state.lina_q_ready = s_qr
            state.lina_fc_active = s_fc
        end)
        -- remaining burst = R 750 + Q 245 = 995; W mocked HUGE (must be ignored).
        -- v0.5.150: both spells stubbed READY so the damage-math cases below behave
        -- as before (the R-on-CD case at the end flips lina_r_ready to test the gate).
        state.lina_r_damage = function() return 750 end
        state.lina_q_damage = function() return 245 end
        state.lina_w_damage = function() return 99999 end
        state.lina_r_ready = function() return true end
        state.lina_q_ready = function() return true end
        state.lina_fc_active = function() return false end  -- v0.5.153: FC off by default (existing cases unchanged)
        local eff_ref = 0
        state.lina_eff_hp_magical = function() return eff_ref end
        local tgt = { __wcap_mock = true }
        -- clear kill: eff_hp 900 -> 900*1.05=945 <= 995
        eff_ref = 900
        if not state.combo_can_kill(tgt) then
            return { pass = false, reason = "should kill at eff_hp 900 (945<=995)" }
        end
        -- near-boundary kill: eff_hp 940 -> 987 <= 995
        eff_ref = 940
        if not state.combo_can_kill(tgt) then
            return { pass = false, reason = "should kill at eff_hp 940 (987<=995)" }
        end
        -- near-boundary NO kill: eff_hp 960 -> 1008 > 995. A lenient form
        -- (eff_hp <= burst*1.05) OR W-credited (burst ~100994) would wrongly fire.
        eff_ref = 960
        if state.combo_can_kill(tgt) then
            return { pass = false, reason = "must NOT kill at eff_hp 960 (1008>995): margin not conservative or W credited" }
        end
        -- clear no-kill: tanky
        eff_ref = 5000
        if state.combo_can_kill(tgt) then
            return { pass = false, reason = "must NOT kill a tanky target" }
        end
        -- nil target -> false
        if state.combo_can_kill(nil) then
            return { pass = false, reason = "nil target must be false" }
        end
        -- zero burst (R+Q unleveled) -> false even vs a frail target
        state.lina_r_damage = function() return 0 end
        state.lina_q_damage = function() return 0 end
        eff_ref = 50
        if state.combo_can_kill(tgt) then
            return { pass = false, reason = "zero burst must be false" }
        end
        -- v0.5.150: R on cooldown -> R NOT credited; remaining Q (245) cannot kill
        -- a 900-eff-HP target. Guards the study finding (combo_can_kill was
        -- cooldown-blind, over-crediting w_capitalize + the leap-defer).
        state.lina_r_damage = function() return 750 end   -- restore lethal damage
        state.lina_q_damage = function() return 245 end
        state.lina_r_ready = function() return false end
        eff_ref = 900
        if state.combo_can_kill(tgt) then
            return { pass = false, reason = "R on CD must not be credited (Q 245 cannot kill eff_hp 900)" }
        end
        state.lina_r_ready = function() return true end
        -- v0.5.152: an unkillable target (Shallow Grave / False Promise / WK
        -- Reincarnation) is never a securable kill, regardless of burst.
        eff_ref = 900   -- r 750 + q 245 = 995; 945 <= 995 would otherwise kill
        local s_unk = Target.IsUnkillableNow
        _cu_push(cu, function() Target.IsUnkillableNow = s_unk end)
        Target.IsUnkillableNow = function() return true end
        if state.combo_can_kill(tgt) then
            return { pass = false, reason = "unkillable target must never be a securable kill" }
        end
        Target.IsUnkillableNow = function() return false end
        if not state.combo_can_kill(tgt) then
            return { pass = false, reason = "killable target (unkillable stub off) must kill at 945<=995" }
        end
        -- v0.5.153: Flame Cloak +35% credited active-only. burst 995 vs eff_hp 1050
        -- -> 1102.5 > 995 (NO kill FC-off) but 1102.5 <= 1343.25 (kill FC-on).
        eff_ref = 1050
        if state.combo_can_kill(tgt) then
            return { pass = false, reason = "FC off: eff_hp 1050 (1102.5) must NOT be killable by raw 995" }
        end
        state.lina_fc_active = function() return true end
        if not state.combo_can_kill(tgt) then
            return { pass = false, reason = "FC on: eff_hp 1050 must be killable (1102.5<=1343.25)" }
        end
        state.lina_fc_active = function() return false end
        return { pass = true, reason = "kill/no-kill/1.05-margin/W-excluded/nil/zero-burst/R-on-CD/unkillable/FC-amp all correct" }
    end,
}

-- v0.5.137.1: regression guard for the Pugna mid-channel interrupt fix. The
-- v0.5.137 demo found Pugna Life Drain un-interrupted when W was on CD at
-- channel-start (every CH.PUGNA_DRAIN save not_ready -> no_effective_save) and
-- never re-dispatched as W came off CD mid-channel. Root cause:
-- modifier_pugna_life_drain was NOT in PERSISTENT_THREATS, so persistent_threats_tick
-- never re-walked it. Fix = add it (it lands on the victim, so the tick's
-- HasModifier(me) gate matches). This is a data-membership guard (mirrors A9);
-- the BEHAVIORAL validation is the demo (W on CD -> off CD -> persistent_threat_tick
-- fires the W interrupt). Also pins no-regression on the original two members.
state.tests["W02_pugna_persistent_rewalk"] = {
    desc = "v0.5.137.1: modifier_pugna_life_drain is a PERSISTENT threat (re-walked mid-channel)",
    fn = function(_cu)
        local set = state.lina_persistent_threats
        if type(set) ~= "table" then
            return { pass = false, reason = "state.lina_persistent_threats not exposed" }
        end
        if not set["modifier_pugna_life_drain"] then
            return { pass = false, reason = "modifier_pugna_life_drain missing from PERSISTENT_THREATS" }
        end
        if not set["modifier_legion_commander_duel"] then
            return { pass = false, reason = "regression: Duel dropped from PERSISTENT_THREATS" }
        end
        if not set["modifier_disruptor_static_storm_thinker"] then
            return { pass = false, reason = "regression: Static Storm dropped from PERSISTENT_THREATS" }
        end
        return { pass = true, reason = "pugna + duel + static-storm all persistent" }
    end,
}

-- v0.5.151: cover-both committed W-aim placement (pure; no game-API mocks). Guards
-- the "W way off Slark" fix: the single-target committed catch must aim a 250-AoE
-- that spans the attacker's current AND predicted positions (midpoint when the
-- band fits), self-cast a glued attacker, and skip an un-coverable / out-of-range
-- kiter instead of whiffing.
state.tests["W06_committed_catch_aim"] = {
    desc = "v0.5.151: committed_catch_aim covers cur+pred; glued->self; wide band / out-of-range -> skip",
    fn = function(_cu)
        local f = state.committed_catch_aim
        if type(f) ~= "function" then
            return { pass = false, reason = "committed_catch_aim missing" }
        end
        local AOE, RANGE = 250, 750
        local lina = { x = 0, y = 0, z = 0 }
        local function d(a, b)
            local dx = (a.x or 0) - (b.x or 0); local dy = (a.y or 0) - (b.y or 0)
            return math.sqrt(dx * dx + dy * dy)
        end
        -- in-band kiter (cur 400, pred 700; band 300 <= 500): catch covering both
        local cur, pred = { x = 400, y = 0 }, { x = 700, y = 0 }
        local aim, kind = f(cur, pred, lina, AOE, RANGE)
        if kind ~= "catch" then
            return { pass = false, reason = "in-band kiter must catch, got " .. tostring(kind) }
        end
        if d(aim, cur) > AOE or d(aim, pred) > AOE then
            return { pass = false, reason = "midpoint must cover both endpoints" }
        end
        -- value case: stationary attacker at 600u -> catch at ~600
        local a2, k2 = f({ x = 600, y = 0 }, { x = 600, y = 0 }, lina, AOE, RANGE)
        if k2 ~= "catch" or math.abs((a2 and a2.x or 0) - 600) > 0.5 then
            return { pass = false, reason = "stationary 600u must catch at 600" }
        end
        -- glued: cur==pred at 150u (inside self-AoE) -> self-cast
        local _, k3 = f({ x = 150, y = 0 }, { x = 150, y = 0 }, lina, AOE, RANGE)
        if k3 ~= "self" then
            return { pass = false, reason = "glued must self-cast, got " .. tostring(k3) }
        end
        -- too wide: cur 400, pred 1000 (band 600 > 500) -> skip kiter_band_too_wide
        local _, k4, r4 = f({ x = 400, y = 0 }, { x = 1000, y = 0 }, lina, AOE, RANGE)
        if k4 ~= "skip" or r4 ~= "kiter_band_too_wide" then
            return { pass = false, reason = "wide band must skip kiter_band_too_wide" }
        end
        -- out of range: cur==pred at 900u (> 750) -> skip no_catch
        local _, k5, r5 = f({ x = 900, y = 0 }, { x = 900, y = 0 }, lina, AOE, RANGE)
        if k5 ~= "skip" or r5 ~= "no_catch" then
            return { pass = false, reason = "out-of-range must skip no_catch" }
        end
        return { pass = true, reason = "catch/self/wide/out-of-range all correct" }
    end,
}

-- v0.5.147.x hook cast-poll gate predicate truth table (pure; no game-API mocks).
state.tests["HK01_hook_gate"] = {
    desc = "hook_gate_pass: range gate + proximity fallback + facing cone",
    fn = function(_cu)
        local g = state.hook_gate_pass
        if type(g) ~= "function" then
            return { pass = false, reason = "state.hook_gate_pass not exposed" }
        end
        -- {dist, angle_deg, expect, label} with range=1500, cone=25, prox=600
        local cases = {
            { 800, 10, true,  "in-cone within range" },
            { 800, 40, false, "out-of-cone beyond prox" },
            { 500, 90, true,  "within prox fires regardless of facing" },
            { 1600, 5, false, "beyond range" },
            { 1500, 25, true, "edge: at range + at cone" },
        }
        for _, c in ipairs(cases) do
            local got = g(c[1], c[2], 1500, 25, 600)
            if got ~= c[3] then
                return { pass = false, reason = c[4] .. " expected " .. tostring(c[3]) .. " got " .. tostring(got) }
            end
        end
        -- nil angle (unreadable facing) beyond prox -> cone cannot pass
        if g(800, nil, 1500, 25, 600) ~= false then
            return { pass = false, reason = "nil angle beyond prox should be false" }
        end
        return { pass = true, reason = "range/prox/cone/nil-angle/edge all correct" }
    end,
}

for _, it in ipairs(_G4_TESTS) do
    local item_key, mod_name = it.key, it.mod
    -- Test name is the item_key tail so alphabetical sort puts BKB first.
    local short_tail = item_key:gsub("^item_", "")
    state.tests["G4_" .. short_tail .. "_guard_short_circuits"] = {
        desc = "G4: SAVE_FIRE." .. item_key .. ".fire returns false when "
            .. mod_name .. " is active, without calling NPCLib.item",
        fn = function(cu)
            local sf = state.lina_save_fire and state.lina_save_fire[item_key]
            if not (sf and sf.fire) then
                return { pass = false, reason = "state.lina_save_fire." .. item_key .. " not exposed" }
            end
            -- Mock NPC.HasModifier: true only for the canonical mod.
            local saved_HasModifier = NPC.HasModifier
            NPC.HasModifier = function(_n, name) return name == mod_name end
            _cu_push(cu, function() NPC.HasModifier = saved_HasModifier end)
            -- Tripwire NPCLib.item: record any call.
            local saved_NPCLib_item = NPCLib.item
            local called_npclib_item = false
            NPCLib.item = function(...)
                called_npclib_item = true
                return saved_NPCLib_item(...)
            end
            _cu_push(cu, function() NPCLib.item = saved_NPCLib_item end)
            -- Direct call: fire("test").
            local ok, ret = pcall(sf.fire, "test")
            if not ok then
                return { pass = false, reason = "fire() raised: " .. tostring(ret):sub(1, 120) }
            end
            if ret ~= false then
                return { pass = false, reason = "fire() returned " .. tostring(ret) .. " (expected false)" }
            end
            if called_npclib_item then
                return { pass = false, reason = "NPCLib.item was called after guard (guard did not short-circuit)" }
            end
            return { pass = true, reason = "fire()==false, NPCLib.item never called" }
        end,
    }
end

----------------------------------------------- dodger chain-item override ---
-- v0.5.43 D1: items in the brain's defense chain that overlap the Umbrella
-- Dodger's "Защитные предметы" self-defense list at gui.json
-- General/Main/Dodger/Дополнительные функции 2.0/Предметы/Защитные предметы.
-- Pre-v0.5.43 the Dodger auto-fired these on threat detection BYPASSING the
-- brain entirely (confirmed in v0.5.42 Bara test debug.log: item_wind_waker /
-- item_cyclone modifiers appeared with caster=lina without any corresponding
-- brain `issued` tlog, breaking the dispatcher's single-spend invariant).
-- The disable+restore cycle scopes the override to one match so other heroes'
-- Dodger config is unaffected. Opt-in via menu (default ON).
-- NOTE: item_hurricane_pike is NOT in the Dodger list but may be auto-fired
-- by the Items Manager subsystem; tracked as v0.5.43 D2 follow-up.
-- v0.5.47.1: added item_ghost to the override list per user spec
-- "add ethereal blade and ghost scepter to the itens list to disable
-- on the dodger". item_ethereal_blade was already present (v0.5.43);
-- item_ghost is new. Ghost Scepter (item_ghost) self-cast applies the
-- ethereal state -- valuable as an escape vs melee carries (combo-
-- system synergy per user Note 3) so brain should own the cast moment,
-- not the framework Dodger.
local DODGER_CHAIN_ITEMS = {
    "item_cyclone", "item_ethereal_blade", "item_ghost",
    "item_glimmer_cape", "item_invis_sword", "item_lotus_orb",
    "item_silver_edge", "item_wind_waker",
    -- v0.5.90: the framework Dodger raced the brain's v0.5.87 escape-Blink. The
    -- v0.5.89 demo log showed 2_dodger.lua:6565 firing a position self-save on a
    -- PA Phantom Strike while the brain's blink_escape never fired. Add item_blink
    -- so the override zeros it too, IF the Dodger defensive-items list exposes a
    -- Blink entry. If it does not, the write is a harmless no-op and the new
    -- `failed=` field on dodger_chain_disabled names item_blink on the next demo
    -- (then Blink lives in a separate Dodger toggle and needs a different gate).
    "item_blink",
}
local DODGER_MENU_PATH = {
    "General", "Main", "Dodger",
    "Дополнительные функции 2.0", "Предметы", "Защитные предметы",
}

-- The framework's multi-select Menu API for checkbox-list widgets is not
-- documented in our source; try both common shapes (nested per-item handle
-- vs container with per-item Get/Set) and emit a diag tlog so we can iterate
-- if the actual API doesn't match either guess.
local function _dodger_container()
    if not (Menu and Menu.Find) then return nil end
    local p = DODGER_MENU_PATH
    local ok, h = pcall(Menu.Find, p[1], p[2], p[3], p[4], p[5], p[6])
    return ok and h or nil
end
local function _dodger_item_nested(item)
    if not (Menu and Menu.Find) then return nil end
    local p = DODGER_MENU_PATH
    local ok, h = pcall(Menu.Find, p[1], p[2], p[3], p[4], p[5], p[6], item)
    return ok and h or nil
end
local function _dodger_read(item)
    local h = _dodger_item_nested(item)
    if h and h.Get then
        local ok, v = pcall(h.Get, h)
        if ok and type(v) == "boolean" then return v, "nested" end
    end
    local c = _dodger_container()
    if c and c.Get then
        local ok, v = pcall(c.Get, c, item)
        if ok and type(v) == "boolean" then return v, "container" end
    end
    return nil, "unknown"
end
local function _dodger_write(item, value)
    local h = _dodger_item_nested(item)
    if h and h.Set then
        local ok = pcall(h.Set, h, value)
        if ok then return true, "nested" end
    end
    local c = _dodger_container()
    if c and c.Set then
        local ok = pcall(c.Set, c, item, value)
        if ok then return true, "container" end
    end
    return false, "unknown"
end

-- v0.5.99.2: per-level Menu.Find resolution probe for the Dodger defensive-items
-- override. The v0.5.99 demo showed dodger_chain_disabled set_ok=0 read_shape=unknown,
-- yet (a) the path strings md5-match gui.json, (b) the item keys (item_cyclone...) are
-- the real list keys, and (c) the IDENTICAL container Get/Set shape WORKS for the
-- Linkbreaker override (set_ok=5 read_shape=container). So Menu.Find simply does not
-- resolve the Dodger container -- a live-tree-structure / lazy-load difference, not an
-- encoding or API problem. This logs how deep the 6-component path resolves so the next
-- demo names the EXACT level it stops at. Read-only; one-shot (called only on set_ok=0).
local function dodger_path_probe()
    if not (Menu and Menu.Find) then tlog(1, "dodger_probe", { step = "no_menu_api" }); return end
    local p = DODGER_MENU_PATH
    local function find_n(n)
        if n == 1 then return pcall(Menu.Find, p[1]) end
        if n == 2 then return pcall(Menu.Find, p[1], p[2]) end
        if n == 3 then return pcall(Menu.Find, p[1], p[2], p[3]) end
        if n == 4 then return pcall(Menu.Find, p[1], p[2], p[3], p[4]) end
        if n == 5 then return pcall(Menu.Find, p[1], p[2], p[3], p[4], p[5]) end
        return pcall(Menu.Find, p[1], p[2], p[3], p[4], p[5], p[6])
    end
    for depth = 1, #p do
        local ok, h = find_n(depth)
        tlog(1, "dodger_probe", {
            depth    = tostring(depth),
            node     = tostring(p[depth]),
            resolved = (ok and h ~= nil) and "y" or "n",
            htype    = type(h),
        })
    end
    -- alt: some menu APIs do not treat a tab/section ("Предметы") as a navigable Find
    -- node, which would move the leaf up one level. Probe the 5-arg path that skips it.
    local ok5, h5 = pcall(Menu.Find, p[1], p[2], p[3], p[4], p[6])
    tlog(1, "dodger_probe_alt", {
        variant  = "skip_items_tab",
        resolved = (ok5 and h5 ~= nil) and "y" or "n",
        htype    = type(h5),
    })
end

local function dodger_chain_disable()
    if state.dodger_disabled then return end
    -- v0.5.125: DEFER-RETRY. The Dodger "Защитные предметы" list lives under the
    -- "Дополнительные функции 2.0" addon sub-panel, which is LAZY-LOADED: the path
    -- exists in saved gui.json but the live Menu tree has not instantiated it at
    -- GAME_IN_PROGRESS (probe: depth 1-3 resolve, depth 4 = nil). The pre-v0.5.125
    -- code latched dodger_disabled=true even on set_ok=0 -> one dead shot, never
    -- retried, so a later lazy-load (or the user opening the panel) was never
    -- caught. Now: latch ONLY on success; otherwise retry every 5s up to a cap so
    -- the override catches the node once it appears. If it never appears, give up
    -- quietly (it is a framework menu limitation -> manual uncheck is the fallback).
    local now_t = now()
    if state.dodger_retry_t and (now_t - state.dodger_retry_t) < 5.0 then return end
    state.dodger_retry_t = now_t
    state.dodger_retry_n = (state.dodger_retry_n or 0) + 1
    -- v0.5.177: retry cap trimmed 24 -> 2. The lazy Cyrillic submenu is a PROVEN
    -- Menu.Find dead-end (6 repros; the v0.5.176 vals probe logged read=x even with
    -- the items set ON, cloud-persisted, AND held by the hero), so the long retry
    -- only spammed the log. Two quick attempts, then give up quietly (manual uncheck
    -- is the fallback). Kept dormant in case a future framework build instantiates it.
    if state.dodger_retry_n > 2 then           -- ~10s of retries
        if not state.dodger_gaveup then
            state.dodger_gaveup = true
            tlog(1, "dodger_chain_giveup", { attempts = tostring(state.dodger_retry_n - 1),
                note = "lazy submenu never resolved; manual uncheck is the fallback" })
        end
        return
    end
    local saved, read_shape = {}, nil
    for _, item in ipairs(DODGER_CHAIN_ITEMS) do
        local v, shape = _dodger_read(item)
        saved[item] = v
        read_shape = read_shape or shape
    end
    -- v0.5.176 DIAGNOSTIC: per-item captured read value + hero-inventory presence,
    -- to settle dead-end vs config. With Eul/WW set ON + cloud-persisted, a reachable
    -- override must log cyclone=1.. / wind_waker=1.. here; all-x = still unreachable.
    -- read: 1=on, 0=off, x=unread(nil). have: h=held, -=not held, ?=hero unacquired.
    local me_d = state.self_npc
    local _vals = {}
    for _, item in ipairs(DODGER_CHAIN_ITEMS) do
        local v = saved[item]
        local r = (v == true) and "1" or ((v == false) and "0" or "x")
        local h = (not me_d) and "?" or ((NPCLib.item and NPCLib.item(me_d, item)) and "h" or "-")
        local nm = item:gsub("^item_", "")
        _vals[#_vals + 1] = nm .. "=" .. r .. h
    end
    local n_set, write_shape, failed = 0, nil, {}
    for _, item in ipairs(DODGER_CHAIN_ITEMS) do
        local ok, shape = _dodger_write(item, false)
        if ok then n_set = n_set + 1 else failed[#failed + 1] = item end
        write_shape = write_shape or shape
    end
    tlog(1, "dodger_chain_disabled", {
        items      = tostring(#DODGER_CHAIN_ITEMS),
        set_ok     = tostring(n_set),
        attempt    = tostring(state.dodger_retry_n),
        failed     = (#failed > 0) and table.concat(failed, ",") or "-",
        read_shape = tostring(read_shape or "nil"),
        write_shape = tostring(write_shape or "nil"),
        vals       = table.concat(_vals, ","),
    })
    if n_set > 0 then
        state.dodger_saved = saved
        state.dodger_disabled = true           -- SUCCESS: latch, stop retrying
    elseif not state.dodger_probed then
        -- first failure only: probe per-level to log WHERE the path breaks.
        state.dodger_probed = true
        dodger_path_probe()
    end
end

local function dodger_chain_restore()
    if not state.dodger_disabled then return end
    local saved = state.dodger_saved or {}
    -- Safety: if all captured values were false / nil (likely we reloaded
    -- mid-match and captured the already-disabled state), restore to the
    -- framework default (all true) instead of leaving everything disabled.
    local any_true = false
    for _, v in pairs(saved) do if v then any_true = true; break end end
    local default_to_true = (not any_true)
    local n_set = 0
    for _, item in ipairs(DODGER_CHAIN_ITEMS) do
        local v = default_to_true and true or saved[item]
        if v == nil then v = true end
        local ok = _dodger_write(item, v)
        if ok then n_set = n_set + 1 end
    end
    state.dodger_saved = nil
    state.dodger_disabled = false
    tlog(1, "dodger_chain_restored", {
        items           = tostring(#DODGER_CHAIN_ITEMS),
        set_ok          = tostring(n_set),
        default_to_true = default_to_true and "y" or "n",
    })
end

----------------------------------------------------- dodger BKB override ---
-- v0.5.102 Note 3: the framework Dodger auto-casts BKB via its own DEDICATED
-- panel, NOT the addon defensive-items list (BKB is absent from the
-- "Защитные предметы" multiselect, so the v0.5.43 override never covered it;
-- the v0.5.99.3 demo note: "BKB was not disabled on dodger"). gui.json:
-- Conditions/BKB Settings (Enemies to Use BKB = 1; Dont Use If You Have =
-- {item_aegis, skeleton_king_reincarnation} -- an item multiselect, wrong
-- knob for a neuter) + Specific Settings/BKB Settings (Min Enemies for Use
-- = 1, Enemies Search Radius = 800). NEUTER STRATEGY (slider writes only,
-- the multiselect is left alone): push BOTH enemy-count thresholds to 99
-- (the framework clamps to each slider's max) and shrink the search radius
-- to 1 (clamps to min) -> the auto-BKB trigger condition becomes
-- practically unreachable while the brain's own BKB save (chain head vs
-- Assassinate / Lion Finger, demo-proven in v0.5.99.3) owns the item.
-- Capture+neuter at GAME_IN_PROGRESS / restore at POST_GAME, match-scoped,
-- mirroring v0.5.43 Dodger / v0.5.45.1 Linkbreaker / v0.5.52 AutoDisabler.
-- KEY ADVANTAGE vs the broken items-list override: this path lives under
-- Dodger/Main (ASCII core tree) -- the v0.5.99.2 probe proved Menu.Find
-- resolves General/Main/Dodger (userdata); only the Cyrillic addon
-- sub-panel failed at depth 4. The doubled "BKB Settings/BKB Settings" in
-- gui.json may be a group/leaf serialization artifact, so resolution tries
-- BOTH the full 8-component path AND the 7-component single-"BKB Settings"
-- variant; a per-level probe fires once if NO write takes (same
-- diagnostic-by-construction as dodger_path_probe). Bundled into ONE
-- module-local table per the 200-locals rule.
local DODGER_BKB = {
    widgets = {
        { name = "enemies_to_use", neuter = 99, comps = { "General", "Main",
          "Dodger", "Main", "Conditions", "BKB Settings", "BKB Settings",
          "Enemies to Use BKB" } },
        { name = "min_enemies",    neuter = 99, comps = { "General", "Main",
          "Dodger", "Main", "Specific Settings", "BKB Settings", "BKB Settings",
          "Min Enemies for Use" } },
        { name = "search_radius",  neuter = 1,  comps = { "General", "Main",
          "Dodger", "Main", "Specific Settings", "BKB Settings", "BKB Settings",
          "Enemies Search Radius" } },
    },
}
DODGER_BKB.handle = function(w)
    -- v0.5.106: shape ladder. The v0.5.105 demo probe (both sessions, both
    -- widgets) broke at depth 5: "Specific Settings" is NOT a Find-navigable
    -- node in the live tree, while the sibling "Conditions" IS (set_ok=1 via
    -- dup8). Same class as the v0.5.99.2 finding that the Dodger addon's
    -- "Предметы" tab is not a Find node: section headers may serialize into
    -- gui.json paths without being navigable. New skip5_* shapes drop the
    -- section component. SAFE BY CONSTRUCTION: the Specific Settings leaf
    -- names (Min Enemies for Use / Enemies Search Radius) do not exist in
    -- the Conditions panel, so an accidental cross-panel match returns nil
    -- at the leaf and the shape is rejected.
    local c = w.comps
    if not (Menu and Menu.Find) then return nil, "no_menu_api" end
    local shapes = {
        { name = "dup8",         a = { c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8] } },
        { name = "single7",      a = { c[1], c[2], c[3], c[4], c[5], c[6], c[8] } },
        { name = "skip5_dup",    a = { c[1], c[2], c[3], c[4], c[6], c[7], c[8] } },
        { name = "skip5_single", a = { c[1], c[2], c[3], c[4], c[6], c[8] } },
    }
    for _, s in ipairs(shapes) do
        local a = s.a
        local ok, h
        if #a == 8 then
            ok, h = pcall(Menu.Find, a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8])
        elseif #a == 7 then
            ok, h = pcall(Menu.Find, a[1], a[2], a[3], a[4], a[5], a[6], a[7])
        else
            ok, h = pcall(Menu.Find, a[1], a[2], a[3], a[4], a[5], a[6])
        end
        if ok and h and h.Get and h.Set then return h, s.name end
    end
    return nil, "unresolved"
end
DODGER_BKB.probe = function(w)
    -- Read-only per-level resolution probe (one-shot, fires per FAILED
    -- widget): names the EXACT depth Menu.Find stops resolving at so the
    -- next demo pins the live tree shape. v0.5.103: takes the failing
    -- widget and walks ITS components -- the v0.5.102 demo had set_ok=1
    -- (Conditions path resolves, dup8) with BOTH Specific Settings widgets
    -- failing, and the probe never ran because it was gated on set_ok==0
    -- and hardcoded to the Conditions path (the one that works).
    if not (Menu and Menu.Find) then
        tlog(1, "dodger_bkb_probe", { step = "no_menu_api" }); return
    end
    local c = (w and w.comps) or DODGER_BKB.widgets[1].comps
    local function find_n(n)
        if n == 1 then return pcall(Menu.Find, c[1]) end
        if n == 2 then return pcall(Menu.Find, c[1], c[2]) end
        if n == 3 then return pcall(Menu.Find, c[1], c[2], c[3]) end
        if n == 4 then return pcall(Menu.Find, c[1], c[2], c[3], c[4]) end
        if n == 5 then return pcall(Menu.Find, c[1], c[2], c[3], c[4], c[5]) end
        if n == 6 then return pcall(Menu.Find, c[1], c[2], c[3], c[4], c[5], c[6]) end
        if n == 7 then return pcall(Menu.Find, c[1], c[2], c[3], c[4], c[5], c[6], c[7]) end
        return pcall(Menu.Find, c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8])
    end
    for depth = 1, #c do
        local ok, h = find_n(depth)
        tlog(1, "dodger_bkb_probe", {
            widget   = tostring((w and w.name) or "conditions"),
            depth    = tostring(depth),
            node     = tostring(c[depth]),
            resolved = (ok and h ~= nil) and "y" or "n",
            htype    = type(h),
        })
    end
end
DODGER_BKB.disable = function()
    if state.dodger_bkb_disabled then return end
    local saved, n_set, shape_seen, failed, failed_w = {}, 0, nil, {}, {}
    for _, w in ipairs(DODGER_BKB.widgets) do
        local h, shape = DODGER_BKB.handle(w)
        if h then
            local okg, v = pcall(h.Get, h)
            if okg and type(v) == "number" then saved[w.name] = v end
            local oks = pcall(h.Set, h, w.neuter)
            if oks then n_set = n_set + 1
            else failed[#failed + 1] = w.name; failed_w[#failed_w + 1] = w end
            shape_seen = shape_seen or shape
        else
            failed[#failed + 1] = w.name; failed_w[#failed_w + 1] = w
        end
    end
    state.dodger_bkb_saved = saved
    state.dodger_bkb_disabled = true
    -- v0.5.107: keep the failed-widget handles for the lazy-panel retry
    -- (the v0.5.106 demo proved NO shape resolves the Specific Settings
    -- widgets at game start -- skip5_* failed too -- so the panel is most
    -- likely built lazily; retry_tick re-attempts on a bounded budget).
    state.dodger_bkb_failed_w = failed_w
    state.dodger_bkb_retry_n  = 0
    state.dodger_bkb_retry_t  = state.frame_t or now()
    -- v0.5.176 DIAGNOSTIC: per-widget captured slider value (x = unread/unreachable).
    local _bvals = {}
    for _, w in ipairs(DODGER_BKB.widgets) do
        local sv = saved[w.name]
        _bvals[#_bvals + 1] = w.name .. "=" .. (sv ~= nil and tostring(sv) or "x")
    end
    tlog(1, "dodger_bkb_disabled", {
        widgets = tostring(#DODGER_BKB.widgets),
        set_ok  = tostring(n_set),
        failed  = (#failed > 0) and table.concat(failed, ",") or "-",
        shape   = tostring(shape_seen or "nil"),
        vals    = table.concat(_bvals, ","),
    })
    -- v0.5.103: probe EVERY failed widget (was: only on set_ok==0, and only
    -- the Conditions path -- which is the one that already resolves).
    -- Probe fires on the FIRST attempt only; retry_tick never probes.
    for _, w in ipairs(failed_w) do DODGER_BKB.probe(w) end
end
DODGER_BKB.retry_tick = function()
    -- v0.5.107: bounded re-attempt of the widgets that failed at match
    -- start -- every 15s, up to 4 tries, still-failed widgets only. A late
    -- success (panel built once the user opens the Dodger menu, or the
    -- framework lazily registers it) merges its captured value into
    -- dodger_bkb_saved so the POST_GAME restore covers it. No probe spam.
    local failed = state.dodger_bkb_failed_w
    if not (failed and #failed > 0) then return end
    if (state.dodger_bkb_retry_n or 0) >= 4 then return end
    local t = state.frame_t or now()
    if (t - (state.dodger_bkb_retry_t or 0)) < 15 then return end
    state.dodger_bkb_retry_t = t
    state.dodger_bkb_retry_n = (state.dodger_bkb_retry_n or 0) + 1
    local still, n_ok = {}, 0
    for _, w in ipairs(failed) do
        local h = DODGER_BKB.handle(w)
        local ok_set = false
        if h then
            local okg, v = pcall(h.Get, h)
            if okg and type(v) == "number" then
                state.dodger_bkb_saved = state.dodger_bkb_saved or {}
                state.dodger_bkb_saved[w.name] = v
            end
            ok_set = pcall(h.Set, h, w.neuter)
        end
        if ok_set then n_ok = n_ok + 1 else still[#still + 1] = w end
    end
    state.dodger_bkb_failed_w = still
    tlog(1, "dodger_bkb_retry", {
        try    = tostring(state.dodger_bkb_retry_n),
        set_ok = tostring(n_ok),
        remain = tostring(#still),
    })
end
DODGER_BKB.restore = function()
    if not state.dodger_bkb_disabled then return end
    local saved = state.dodger_bkb_saved or {}
    local n_set = 0
    for _, w in ipairs(DODGER_BKB.widgets) do
        local v = saved[w.name]
        if type(v) == "number" then
            local h = DODGER_BKB.handle(w)
            if h then
                local ok = pcall(h.Set, h, v)
                if ok then n_set = n_set + 1 end
            end
        end
    end
    state.dodger_bkb_saved = nil
    state.dodger_bkb_disabled = false
    state.dodger_bkb_failed_w = nil  -- v0.5.107: drop retry state with the match
    state.dodger_bkb_retry_n  = nil
    tlog(1, "dodger_bkb_restored", { set_ok = tostring(n_set) })
end

----------------------------------------------- linkbreaker chain-item override ---
-- v0.5.45.1 LB (DEFENSE_PLAN.md sec 4.X: Linkbreaker subsystem override).
-- v0.5.45 demo log showed Bara "double-fire" pattern: chain walker fired W
-- (Pike fire_returned_false in chain), then 33ms later framework SafeSend
-- pipeline cast Pike on Bara (caster=lina, no brain `issued` event). Same
-- pattern as v0.5.42 Eul/WW from Dodger but the source is the per-hero
-- Linkbreaker subsystem at Heroes/Hero List/Lina/Main Settings/Items
-- Settings/Linkbreaker Items in gui.json (L16888 in user's deployed gui).
-- That list has 5 chain-overlap items at true: item_cyclone /
-- item_ethereal_blade / item_force_staff / item_hurricane_pike /
-- item_wind_waker. Linkbreaker is a separate framework subsystem from
-- Dodger (the v0.5.43 override covers Dodger's Защитные предметы only).
-- This override mirrors the v0.5.43 pattern: capture+zero at GAME_IN_PROGRESS,
-- restore at POST_GAME, per-match scoping so other heroes' Linkbreaker
-- config is not permanently mutated.
-- v0.5.45.1 LB: bundle ALL Linkbreaker state + helpers into a single
-- module-level table to stay under Lua's 200-local-variables-per-function
-- limit (hit at v0.5.45 + commit-attacker + W-gate additions).
local LB = {
    items = {
        "item_cyclone", "item_ethereal_blade", "item_force_staff",
        "item_hurricane_pike", "item_wind_waker",
    },
    path = {
        "Heroes", "Hero List", "Lina", "Main Settings",
        "Items Settings", "Linkbreaker Items",
    },
}
LB.container = function()
    if not (Menu and Menu.Find) then return nil end
    local p = LB.path
    local ok, h = pcall(Menu.Find, p[1], p[2], p[3], p[4], p[5], p[6])
    return ok and h or nil
end
LB.item_nested = function(item)
    if not (Menu and Menu.Find) then return nil end
    local p = LB.path
    local ok, h = pcall(Menu.Find, p[1], p[2], p[3], p[4], p[5], p[6], item)
    return ok and h or nil
end
LB.read = function(item)
    local h = LB.item_nested(item)
    if h and h.Get then
        local ok, v = pcall(h.Get, h)
        if ok and type(v) == "boolean" then return v, "nested" end
    end
    local c = LB.container()
    if c and c.Get then
        local ok, v = pcall(c.Get, c, item)
        if ok and type(v) == "boolean" then return v, "container" end
    end
    return nil, "unknown"
end
LB.write = function(item, value)
    local h = LB.item_nested(item)
    if h and h.Set then
        local ok = pcall(h.Set, h, value)
        if ok then return true, "nested" end
    end
    local c = LB.container()
    if c and c.Set then
        local ok = pcall(c.Set, c, item, value)
        if ok then return true, "container" end
    end
    return false, "unknown"
end
LB.disable = function()
    if state.linkbreaker_disabled then return end
    local saved, read_shape = {}, nil
    for _, item in ipairs(LB.items) do
        local v, shape = LB.read(item)
        saved[item] = v
        read_shape = read_shape or shape
    end
    local n_set, write_shape = 0, nil
    for _, item in ipairs(LB.items) do
        local ok, shape = LB.write(item, false)
        if ok then n_set = n_set + 1 end
        write_shape = write_shape or shape
    end
    state.linkbreaker_saved = saved
    state.linkbreaker_disabled = true
    tlog(1, "linkbreaker_chain_disabled", {
        items       = tostring(#LB.items),
        set_ok      = tostring(n_set),
        read_shape  = tostring(read_shape or "nil"),
        write_shape = tostring(write_shape or "nil"),
    })
end
LB.restore = function()
    if not state.linkbreaker_disabled then return end
    local saved = state.linkbreaker_saved or {}
    local any_true = false
    for _, v in pairs(saved) do if v then any_true = true; break end end
    local default_to_true = (not any_true)
    local n_set = 0
    for _, item in ipairs(LB.items) do
        local v = default_to_true and true or saved[item]
        if v == nil then v = true end
        local ok = LB.write(item, v)
        if ok then n_set = n_set + 1 end
    end
    state.linkbreaker_saved = nil
    state.linkbreaker_disabled = false
    tlog(1, "linkbreaker_chain_restored", {
        items           = tostring(#LB.items),
        set_ok          = tostring(n_set),
        default_to_true = default_to_true and "y" or "n",
    })
end

----------------------------------------------- autodisabler override ---
-- v0.5.52 Phase 3 slice 2: AutoDisabler "Force Interrupt" subsystem
-- override. v0.5.51 demo log proved the conflict: brain's
-- catalog_eta_pike fired at impact_t=0.59 (d=441) but framework
-- AutoDisabler.lua had ALREADY cast Pike on Bara at d=569 and d=473
-- (modifier_spirit_breaker_charge_of_darkness is in Force Interrupt/
-- Versus list with item_hurricane_pike + item_force_staff in Force
-- Interrupt/Usage). The v0.5.43 Dodger + v0.5.45.1 Linkbreaker
-- overrides cover those framework subsystems but NOT AutoDisabler,
-- which is a third independent subsystem at General/Main/Auto Disabler
-- in gui.json. Same match-scoped capture+restore pattern. Items: Pike
-- + Force Staff (both Lina-brain-owned via SAVE_FIRE). BKB, Manta,
-- Ghost are NOT in any AutoDisabler list so no conflict.
--
-- v0.5.52: lives under state.AD (not module-local) because Lua's
-- 200-local-vars-per-function limit in the main chunk was already at
-- the ceiling pre-v0.5.52 (see memory rule from v0.5.45.1: "module-
-- level additions MUST bundle into state.* or named tables"). LB and
-- Dodger pre-date that constraint; new subsystems go on state.
state.AD = {
    items = { "item_hurricane_pike", "item_force_staff" },
    path = {
        "General", "Main", "Auto Disabler", "Main",
        "Force Interrupt", "Usage",
    },
}
state.AD.container = function()
    if not (Menu and Menu.Find) then return nil end
    local p = state.AD.path
    local ok, h = pcall(Menu.Find, p[1], p[2], p[3], p[4], p[5], p[6])
    return ok and h or nil
end
state.AD.item_nested = function(item)
    if not (Menu and Menu.Find) then return nil end
    local p = state.AD.path
    local ok, h = pcall(Menu.Find, p[1], p[2], p[3], p[4], p[5], p[6], item)
    return ok and h or nil
end
state.AD.read = function(item)
    local h = state.AD.item_nested(item)
    if h and h.Get then
        local ok, v = pcall(h.Get, h)
        if ok and type(v) == "boolean" then return v, "nested" end
    end
    local c = state.AD.container()
    if c and c.Get then
        local ok, v = pcall(c.Get, c, item)
        if ok and type(v) == "boolean" then return v, "container" end
    end
    return nil, "unknown"
end
state.AD.write = function(item, value)
    local h = state.AD.item_nested(item)
    if h and h.Set then
        local ok = pcall(h.Set, h, value)
        if ok then return true, "nested" end
    end
    local c = state.AD.container()
    if c and c.Set then
        local ok = pcall(c.Set, c, item, value)
        if ok then return true, "container" end
    end
    return false, "unknown"
end
state.AD.disable = function()
    if state.autodisabler_disabled then return end
    local saved, read_shape = {}, nil
    for _, item in ipairs(state.AD.items) do
        local v, shape = state.AD.read(item)
        saved[item] = v
        read_shape = read_shape or shape
    end
    local n_set, write_shape = 0, nil
    for _, item in ipairs(state.AD.items) do
        local ok, shape = state.AD.write(item, false)
        if ok then n_set = n_set + 1 end
        write_shape = write_shape or shape
    end
    state.autodisabler_saved = saved
    state.autodisabler_disabled = true
    tlog(1, "autodisabler_chain_disabled", {
        items       = tostring(#state.AD.items),
        set_ok      = tostring(n_set),
        read_shape  = tostring(read_shape or "nil"),
        write_shape = tostring(write_shape or "nil"),
    })
end
state.AD.restore = function()
    if not state.autodisabler_disabled then return end
    local saved = state.autodisabler_saved or {}
    local any_true = false
    for _, v in pairs(saved) do if v then any_true = true; break end end
    local default_to_true = (not any_true)
    local n_set = 0
    for _, item in ipairs(state.AD.items) do
        local v = default_to_true and true or saved[item]
        if v == nil then v = true end
        local ok = state.AD.write(item, v)
        if ok then n_set = n_set + 1 end
    end
    state.autodisabler_saved = nil
    state.autodisabler_disabled = false
    tlog(1, "autodisabler_chain_restored", {
        items           = tostring(#state.AD.items),
        set_ok          = tostring(n_set),
        default_to_true = default_to_true and "y" or "n",
    })
end

------------------------------------------------------------------ menu ------
local function setup_menu()
    local m = {}
    -- Menu.Find-then-Create so a script reload reuses the existing tabs
    -- instead of erroring on a duplicate Create.
    local function group(name)
        return Menu.Find("Heroes", "Hero List", "Lina", "Brain", name)
            or Menu.Create("Heroes", "Hero List", "Lina", "Brain", name)
    end
    local gCore = group("Core")
    local gDef  = group("Defense")
    local gDiag = group("Diagnostics")

    ---------------------------------------------------------------- Core --
    m.enable = gCore:Switch("Enable Lina brain", true)
    m.enable:ToolTip("Master toggle. When off the brain issues nothing; the "
        .. "native / baseline Lina runs alone.")
    -- Brain combo key is intentionally separate from the native Lina combo key
    -- (gui.json keycode 16) to reduce the native order flood (lesson 131).
    m.combo_key = gCore:Bind("Combo key", Enum.ButtonCode.KEY_MOUSE5)
    m.combo_key:ToolTip("HOLD = adaptive Starter (1-2 enemies) / Team Fight "
        .. "(3+) loop. TAP is stubbed for Lina (no 750u-R use case).")
    m.enable_offense = gCore:Switch("Enable offense", true)
    m.enable_offense:ToolTip("Master toggle for the HOLD-only adaptive combo "
        .. "(Starter / Team Fight) on the combo key. Off = combo key does "
        .. "nothing; defense and auto-R are unaffected by this toggle.")
    m.auto_r = gCore:Switch("Auto-R kill steal", true)
    m.auto_r:ToolTip("Fire Laguna automatically (no combo key) when R alone "
        .. "(plus Slow Burn) kills a visible enemy in range. Skips magic-immune "
        .. "and Linkens-protected targets.")
    -- v0.5.171 menu-simplification: pause_hitrun + pause_hitrun_strict (wide-pause)
    -- hardcoded ON in update_hitrun_pause(); the narrow-pause branch is removed.
    -- v0.5.171 menu-simplification: fs_cap_aware + sustain_r_reserve hardcoded ON in code.

    -- v0.5.33 FC-C-08: Flame Cloak offensive auto-fire toggle. FC is the
    -- Aghs-Scepter-granted instant (+35% spell amp / +35% magic res / 7s) we
    -- want to fire BEFORE the burst archetype so the amp applies to W/Q/R.
    -- Default ON. Toggle OFF for clean revert if mana-burn or unexpected
    -- combo timing surfaces in real games.
    m.fc_offensive_use = gCore:Switch("Flame Cloak: offensive amp", true)
    -- v0.5.170 menu-simplification: fc_commit_gate / jugg_omni_defer / fc_escape /
    -- fc_chase / fc_value_weight / fc_aim_bias are hardcoded ON in code below; the
    -- fc_value_debug probe is cut. Only fc_offensive_use remains as the FC control.
    m.fc_offensive_use:ToolTip("Aghs Scepter only. Before any burst combo "
        .. "(ether_wqr / eul_wrq / ww_wrq / wqr / r_first_rwq), fire Flame "
        .. "Cloak first so its +35% spell amp lifts W/Q/R damage. Triggers: "
        .. "(c) pre-R commit when stacks are below cap, OR (a) stack refresh "
        .. "in active fight when stacks<4. Skipped during fs_shard_window "
        .. "(would downgrade cap 12->7) and during r_finisher (R alone "
        .. "kills, FC is waste). Defensive save-chain use unaffected.")
    -- v0.5.137: W-capitalize -- after the defensive W stuns a gap-closer / committed attacker,
    -- commit the combo on that stunned target IF killable. Default ON (offensive completion of the W save).
    m.w_capitalize = gCore:Switch("W-capitalize", true)
    m.w_capitalize:ToolTip("After the defensive W stuns an incoming gap-closer "
        .. "or committed attacker, fire the W-Q-R combo to SECURE the kill -- "
        .. "but only when the remaining Q+R clearly kills it (else the W stays "
        .. "purely defensive). Gated on HP floor + not-into-a-gank. Default ON.")

    -- v0.5.170 menu-simplification: fc_offensive_sustain_use cut (niche opt-in,
    -- default OFF, never promoted); the tf_sustain pre-amp branch is removed in code.

    -- v0.5.171 menu-simplification: ether_kill_confirm hardcoded ON in code.

    gCore:Label("- Advanced -")
    m.force_key = gCore:Bind("Force-commit key (bypass commit check)", Enum.ButtonCode.KEY_NONE)
    m.force_key:ToolTip("Hold to force a combo even when the kill check refuses.")
    m.panic_key = gCore:Bind("Panic-save key (force next save)", Enum.ButtonCode.KEY_NONE)
    m.panic_key:ToolTip("Press to force the defense layer to fire its next "
        .. "save immediately.")
    -- v0.5.78 wave-clear (HOLD): mana-floor + creep-count gated lane/jungle farm
    -- (v0.5.86: comment corrected -- there is NO stack-TIMING logic; the
    -- min-creeps gate is "fire only on enough creeps", i.e. effective on already-
    -- stacked camps, not a pull/stack-window scheduler). Q (Dragon
    -- Slave) line nuke at the aim hitting the most creeps; optional W on a dense
    -- camp. Opt-in: KEY_NONE default so the bind does nothing until assigned.
    m.wave_key = gCore:Bind("Wave-clear key (HOLD)", Enum.ButtonCode.KEY_NONE)
    m.wave_key:ToolTip("HOLD to farm: fire Dragon Slave (Q) at the line aim "
        .. "hitting the most nearby creeps, plus Light Strike Array (W) on a "
        .. "dense camp when mana-rich. Player controls movement; the brain only "
        .. "nukes creeps already in range. Gated by min-creeps + mana floor + "
        .. "R reserve. KEY_NONE = off until you assign a key.")
    -- v0.5.172 menu-simplification: wave_min_creeps (3) / wave_mana_floor (30) / wave_reserve_r (ON) /
    -- wave_use_w (ON) hardcoded to defaults in the wave-clear code; the wave_key feature switch stays.

    -- v0.5.94: engine-blink CAPITALIZE -- the brain does not cast Blink; it seizes
    -- the engine's blink to fire a free-gap-close combo. Default OFF.
    m.blink_capitalize = gCore:Switch("Blink-capitalize (auto-combo on engine blink)", false)
    m.blink_capitalize:ToolTip("When the framework blinks Lina into range of a "
        .. "target, fire the W-Q-R combo (use the engine's blink as a free "
        .. "gap-close). Gated on HP floor + not-into-a-gank. Default OFF.")
    -- v0.5.172 menu-simplification: blink_capitalize_hp + w_capitalize_hp hardcoded to 35 in code.
    -- v0.5.95: brain-cast Blink-in (re-enabled FALLBACK) -- when the engine did NOT
    -- blink (dagger ready) + you hold combo on an out-of-range target, the brain
    -- blinks in itself, then combos. Reserves the dagger if a threat is incoming.
    -- Both default OFF.
    m.blink_in_kill = gCore:Switch("Blink-in kill-commit (brain-cast)", false)
    m.blink_in_kill:ToolTip("Brain casts Blink to secure a CONFIRMED kill on an "
        .. "out-of-range target, only when the engine did not blink. Default OFF.")
    m.blink_in_initiate = gCore:Switch("Blink-in initiate (brain-cast, no-kill)", false)
    m.blink_in_initiate:ToolTip("Brain casts Blink to engage without a guaranteed "
        .. "kill -- gated on exit item + HP + fog, and reserves the dagger if a "
        .. "threat is incoming. Default OFF.")
    -- v0.5.172 menu-simplification: blink_in_kill_risk (60) / blink_in_initiate_risk (30) /
    -- blink_in_initiate_hp (40) hardcoded to defaults in code.

    ------------------------------------------------------------- Defense --
    m.auto_defense = gDef:Switch("Enable auto-defense", true)
    m.auto_defense:ToolTip("Always-on save layer: Wind Waker / Flame Cloak / "
        .. "BKB / Glimmer / Lotus / Force / Pike on incoming threats.")
    m.ally_save = gDef:Switch("Enable ally-save (threat-reactive)", false)
    m.ally_save:ToolTip("Opt-in (support builds). When a recognized threat "
        .. "(gap-close, hard disable, targeted burst, channel) lands on an "
        .. "ally hero, fire an ally-castable save ON them: Glimmer to break a "
        .. "target lock, Lotus to dispel / reflect, Force to reposition. "
        .. "Threat-triggered, not an HP threshold. Off by default.")
    gDef:Label("- Subsystem switches -")
    -- v0.5.21 OBS-11: per-subsystem defense toggles. auto_defense (above) is
    -- the master switch; these three carve out individual layers so a
    -- misbehaving subsystem can be silenced without dropping the rest of
    -- the defense layer. Ally-save is omitted from this set on purpose -
    -- the existing m.ally_save opt-in above is the canonical ally control;
    -- adding a sibling switch would create two confusingly-named controls.
    m.enable_persistent_refire = gDef:Switch("Persistent re-fire (Duel/Static Storm)", true)
    m.enable_persistent_refire:ToolTip("Periodic re-fire of self-saves while "
        .. "a persistent lockdown modifier (LD Duel, Razor Static Storm) is "
        .. "on Lina. Disable to suppress the persistent_threats_tick re-fire "
        .. "loop without touching the rest of the defense layer.")
    m.enable_line_intercept = gDef:Switch("Line-projectile intercept (Pudge hook)", true)
    m.enable_line_intercept:ToolTip("OnLinearProjectileCreate intercept for "
        .. "line-traveling threats (Pudge Hook, Mirana Arrow, Magnus Skewer, "
        .. "Sven Storm Bolt, ES Fissure). Disable if the intercept fires on "
        .. "hooks you wanted to dodge manually.")
    m.hook_cast_poll = gDef:Switch("Hook cast-poll save", true)
    m.hook_cast_poll:ToolTip("Detect Pudge Hook / Clockwerk Hookshot AT CAST via an "
        .. "active-ability poll (the line-projectile + anim paths do NOT fire for "
        .. "hooks) and fire a displacement save (Force/Pike/Blink, WW/Eul fallback) "
        .. "before it lands. Facing-cone gated, with a close-range proximity fallback.")
    m.enable_lotus_first = gDef:Switch("Lotus-worthy ult reflect-first", true)
    m.enable_lotus_first:ToolTip("When a Lotus-reflectable threat lands "
        .. "(LC Duel, Doom, Hex, etc.), try Lotus Orb FIRST to reflect the "
        .. "cast before falling back through the normal save ladder. Disable "
        .. "to skip the Lotus-first branch and use the default save order.")
    -- v0.5.43 D1: override Umbrella Dodger's self-defense item list at match
    -- start so the brain becomes sole controller of the 7 chain items that
    -- overlap (Eul / Glimmer / Lotus / Shadow Blade / Silver Edge / Ether /
    -- Wind Waker). Restored at POST_GAME so other heroes are unaffected.
    -- See DODGER_CHAIN_ITEMS module-local + dodger_chain_disable/restore
    -- helpers earlier in this file. Off = Dodger and brain both fire and
    -- a double-fire pattern is observable (Bara WW+Pike v0.5.42 demo).
    -- v0.5.45 CA (DEFENSE_PLAN.md sec 4.2 commit-attacker track): port of
    -- Sniper's is_committed_attacker detection. Synthesizes a virtual
    -- threat when an enemy hero is auto-attacking Lina at melee range and
    -- routes through v0.5.40 dispatcher to fire close-gap saves (Force /
    -- Pike / WW / Eul / Glimmer / W tail). Off = brain only responds to
    -- SPELL threats; raw auto-attacks go ignored (pre-v0.5.45 behavior).
    m.enable_commit_attacker = gDef:Switch('Enable commit-attacker close-gap', true)
    m.enable_commit_attacker:ToolTip("Detect enemy heroes auto-attacking "
        .. "Lina at melee range (700u) and trigger close-gap saves (Force "
        .. "/ Pike / WW / Eul / Glimmer / W tail). Sniper-precedent port. "
        .. "Per-attacker 1.6s re-arm latch + Dispatcher lock prevent spam. "
        .. "Off = no defensive response to raw auto-attacks; chain only "
        .. "triggers on spell threats (pre-v0.5.45 behavior).")
    -- v0.5.44 (DEFENSE_PLAN.md sec 2.1 + Q1): W as anti-gap arrival stun,
    -- chain TAIL of close_gap chains. High-viability targets: Bara Charge,
    -- Bara Nether Strike, Tusk Snowball, MK Primal Spring. Mana floor
    -- enforces +450 r_reserve so defensive W cannot starve the kill combo.
    -- Off = W never fires defensively, chain falls through to no_effective_
    -- save_for_threat if all items also on CD.
    m.enable_w_anti_gap = gDef:Switch('Enable W anti-gap defensive', true)
    m.enable_w_anti_gap:ToolTip("Fire light_strike_array as a tertiary "
        .. "save when WW / Force / Pike / Glimmer are all on CD against a "
        .. "slow-arrival gap-closer (Bara, Tusk, MK Primal Spring). Mana "
        .. "floor reserves 450 for R combo so defensive W cannot starve "
        .. "the kill commit. Off = W stays offensive-only.")
    -- v0.5.45.1 LB: Linkbreaker subsystem override. The framework's per-hero
    -- Linkbreaker (gui.json Heroes/Hero List/Lina/Main Settings/Items Settings/
    -- Linkbreaker Items) auto-fires Pike/Force/Eul/Ether/WW on enemies which
    -- the brain's defense chain ALSO controls, causing double-fires (v0.5.45
    -- demo: Bara charge fired brain W + framework Pike together; W landed on
    -- empty position because Pike pushed Bara out of W's 225u AoE). Same
    -- match-scoped capture+restore pattern as v0.5.43 Dodger override.
    m.override_linkbreaker = gDef:Switch('Override Linkbreaker defense items', true)
    m.override_linkbreaker:ToolTip("On match start (GAME_IN_PROGRESS), "
        .. "capture and zero the 5 chain-overlap items in the per-hero "
        .. "Linkbreaker subsystem (Eul / Ether / Force / Pike / WW). "
        .. "Restored at POST_GAME so the change is scoped to one match. "
        .. "Off = Linkbreaker and brain both fire (causes the Bara double-"
        .. "fire pattern observed in v0.5.45 demo where W missed because "
        .. "framework Pike already pushed Bara out of W's AoE).")
    m.override_dodger = gDef:Switch('Override Dodger defense items', true)
    m.override_dodger:ToolTip("On match start (GAME_IN_PROGRESS), capture "
        .. "and zero the 7 self-defense items in the Umbrella Dodger that "
        .. "overlap the brain's chain (Eul/Glimmer/Lotus/Shadow Blade/Silver "
        .. "Edge/Ether/Wind Waker). Restored at POST_GAME so the change is "
        .. "scoped to one match. Off = Dodger and brain both fire (causes "
        .. "double-fires on Bara WW+Pike etc. observed in v0.5.42 demo).")
    -- v0.5.102 Note 3: BKB is NOT in the Dodger items list above -- it has
    -- its own dedicated Dodger panel (Conditions/BKB Settings + Specific
    -- Settings/BKB Settings), so the items override never reached it and
    -- the framework raced/mistimed the brain's BKB save.
    m.override_dodger_bkb = gDef:Switch('Override Dodger BKB auto-cast', true)
    m.override_dodger_bkb:ToolTip("On match start, neuter the Dodger's "
        .. "dedicated BKB panel (enemy-count thresholds to max, search "
        .. "radius to min) so the brain's BKB save owns the item. Restored "
        .. "at POST_GAME, scoped to one match. Off = framework auto-BKB "
        .. "races the brain's timing.")
    -- v0.5.86 cleanup: removed m.override_autodisabler. It was DEPRECATED /
    -- explicit no-op since v0.5.54 (the Pike-on-Bara conflict is handled at the
    -- data layer by dropping Pike's prep_time; state.AD.disable is gone from
    -- OnUpdateEx). The toggle was read nowhere functional -- pure menu clutter.
    -- v0.5.171 menu-simplification: preface_enable cut (niche, default OFF, never promoted); pre_face_tick removed in code.

    --------------------------------------------------------- Diagnostics --
    m.diag = gDiag:Slider("Log verbosity", 0, 3, 1)
    m.diag:ToolTip("0 = silent, 1 = decisions, 2 = + skips, 3 = full trace. "
        .. "Written to C:\\Umbrella\\debug.log.")
    gDiag:Label("- Brain status (live) -")
    m.lbl_self     = gDiag:Label("self: not acquired")
    -- v0.5.88: offensive combo-readiness chip (R-CD / mana% / FS / WQR-ready),
    -- the counterpart to the defensive saves chip below.
    m.lbl_combo    = gDiag:Label("combo: -")
    m.lbl_counters = gDiag:Label("counts: l1=0 l2=0")
    -- v0.5.80 feature D: live power-spike save readiness (owned items only).
    m.lbl_saves    = gDiag:Label("saves: -")
    -- v0.5.84: wire the dormant v0.5.77 fog suite to the live 1Hz HUD.
    -- gank   = enemies arrivable soon at Lina's pos (fog-aware, 2-in-4s signal).
    -- missing = enemies off-minimap >= 5s (rotation tracker), longest first.
    m.lbl_gank     = gDiag:Label("gank: -")
    m.lbl_missing  = gDiag:Label("missing: -")
    -- v0.5.15 OBS-08: one-press dump of armed_threats, pending_steps,
    -- responded_threats, last_save_*, fs stacks. Press fires one multi-line
    -- tlog burst at level 1 (always on at default verbosity). KEY_NONE so
    -- the bind is opt-in: assign a key in the menu to enable.
    m.dump_key = gDiag:Bind("Dump brain state (one-shot)",
                            Enum.ButtonCode.KEY_NONE)
    m.dump_key:ToolTip("Press to emit a forensic snapshot of armed threats, "
        .. "pending combo steps, responded threats, last save fields, and "
        .. "Fiery Soul stacks to C:\\Umbrella\\debug.log.")
    -- v0.5.17 Track 1: run-all-tests bind. Press fires the registered Lua
    -- test suite (state.tests) one rising-edge per press. Output: tlog
    -- test_session_begin / test_run_begin / test_run_end / test_summary /
    -- test_session_end rows at level 1 (visible at default verbosity).
    -- KEY_NONE so the bind is opt-in: assign a key in the menu to enable.
    m.test_key = gDiag:Bind("Run all brain tests (one-shot)",
                            Enum.ButtonCode.KEY_NONE)
    m.test_key:ToolTip("Press to run the in-Brain test suite (mock-driven, "
        .. "no Dota state needed). Grep C:\\Umbrella\\debug.log between "
        .. "test_session_begin and test_session_end for the results.")

    state.menu = m
end

-- Per-enemy animation->ability catalog (v0.2.5, deviation E/B5). Ported from
-- Sniper's register_anim_maps (generated by tools/gen_anim_maps.py plus the
-- hand-tweaks: instant_target for unit-target gap-closers, particle-signature
-- fallbacks). Hero-agnostic enemy data. OnUnitAnimation resolves the caster's
-- map and fires gap_close / hard_disable / channel_start / ult_burst role
-- events to the Layer-2 dispatchers, giving predictive detection (e.g. PA
-- via=blink_arrived) ahead of the OnModifierCreate path. AB* are the cast
-- activity slots. Re-run the generator after a patch; do not hand-edit blocks.
local GA = Enum.GameActivity
-- v0.5.52.1 (200-locals cleanup): bundled AB1-AB6 into AB[1]..AB[6]
-- table. Saves 5 main-chunk local slots. References [AB[1]]..[AB[6]]
-- become [AB[1]]..[AB[6]] (correct Lua: outer brackets = table-key
-- syntax, inner = AB table index). Hot-path cost is negligible (one
-- extra table indirection per Anim.RegisterMap startup lookup).
local AB = {
    GA and GA.ACT_DOTA_CAST_ABILITY_1 or 1500,
    GA and GA.ACT_DOTA_CAST_ABILITY_2 or 1501,
    GA and GA.ACT_DOTA_CAST_ABILITY_3 or 1502,
    GA and GA.ACT_DOTA_CAST_ABILITY_4 or 1503,
    GA and GA.ACT_DOTA_CAST_ABILITY_5 or 1504,
    GA and GA.ACT_DOTA_CAST_ABILITY_6 or 1505,
}

local function register_anim_maps()
    -- v6.15.206 (D18-followup initiative): the full register_anim_maps body
    -- was GENERATED by tools/gen_anim_maps.py from npc_heroes.json +
    -- npc_abilities.json. Roles seeded from prior hand-tuned maps + threat_data.
    -- v0.5.119 (2026-06-13): the cast-activity SLOTS are now KV-correct -- the
    -- old D18 slot-POSITION derivation was wrong for ~22% of entries (e.g.
    -- Bloodseeker Rupture: position AB[4] but KV AbilityCastAnimation is
    -- ACT_DOTA_CAST_ABILITY_6, demo-confirmed dead). All 34 mismatches were
    -- hand-corrected to KV; the generator was also fixed to prefer
    -- AbilityCastAnimation. **REGEN WARNING:** the generator does NOT emit the
    -- 57 instant_target + 22 range flags hand-maintained here -- a blind regen
    -- WIPES them (detection regression). MERGE, do not wholesale-replace; verify
    -- with tools/check_anim_activity_codes.py (expect 0 mismatches).
    -- abaddon (v6.15.270 zero-coverage final mop-up)
    -- v0.5.36: Aphotic Shield cast on ally explodes for AoE damage; anim catches
    -- the cast, Lina repositions if Abaddon's ally is near.
    Anim.RegisterMap("npc_dota_hero_abaddon", {
        [AB[2]] = { ability = "abaddon_aphotic_shield", role = "hard_disable" },
    })
    -- alchemist (v6.15.268 zero-coverage fill)
    -- Unstable Concoction Throw is UNIT_TARGET AOE -- Alchemist throws the
    -- charged concoction at the target. Cast point 0.2. instant_target
    -- since Alchemist selects target by reference.
    Anim.RegisterMap("npc_dota_hero_alchemist", {
        [AB[3]] = { ability = "alchemist_unstable_concoction_throw", role = "hard_disable", instant_target = true },
    })
    -- ancient_apparition (v6.15.263 zero-coverage fill)
    Anim.RegisterMap("npc_dota_hero_ancient_apparition", {
        [AB[1]] = { ability = "ancient_apparition_cold_feet", role = "hard_disable", instant_target = true },  -- unit-target, IGNORE_BACKSWING
        [AB[4]] = { ability = "ancient_apparition_ice_blast", role = "ult_burst" },  -- POINT-AOE delayed execute
    })
    -- antimage (v6.15.263 zero-coverage fill)
    Anim.RegisterMap("npc_dota_hero_antimage", {
        [AB[4]] = { ability = "antimage_mana_void", role = "ult_burst", instant_target = true },  -- unit-target AOE burst
    })
    -- arc_warden (v6.15.269 zero-coverage fill)
    -- Flux is UNIT_TARGET damage-when-isolated debuff. 0.3 cast; Arc
    -- doesn't aim (selects by reference). instant_target bypasses gate.
    Anim.RegisterMap("npc_dota_hero_arc_warden", {
        [AB[1]] = { ability = "arc_warden_flux", role = "hard_disable", instant_target = true },
    })
    -- bane
    Anim.RegisterMap("npc_dota_hero_bane", {
        [AB[3]] = { ability = "bane_nightmare", role = "hard_disable" },
        [AB[4]] = { ability = "bane_fiends_grip", role = "channel_start", instant_target = true },
    })
    -- batrider
    Anim.RegisterMap("npc_dota_hero_batrider", {
        [AB[4]] = { ability = "batrider_flaming_lasso", role = "hard_disable" },
    })
    -- beastmaster
    Anim.RegisterMap("npc_dota_hero_beastmaster", {
        [AB[4]] = { ability = "beastmaster_primal_roar", role = "hard_disable" },
    })
    -- bloodseeker
    Anim.RegisterMap("npc_dota_hero_bloodseeker", {
        [AB[6]] = { ability = "bloodseeker_rupture", role = "ult_burst", instant_target = true },  -- v0.5.118: KV AbilityCastAnimation=ACT_DOTA_CAST_ABILITY_6 (NOT slot-4 -- the generator's slot-derivation was wrong, so the anim never matched and v0.5.117 silently degraded to reactive). AB[6] + instant_target -> on_hard_disable fires Lotus at cast-START (Lotus reflects Rupture upon cast only, the 0.4s window)
    })
    -- bounty_hunter (v6.15.269 zero-coverage fill)
    -- Shuriken Toss is UNIT_TARGET 0.3 cast (bounces between visible
    -- targets). instant_target since BH doesn't aim.
    Anim.RegisterMap("npc_dota_hero_bounty_hunter", {
        [AB[1]] = { ability = "bounty_hunter_shuriken_toss", role = "hard_disable", instant_target = true },
    })
    -- brewmaster (v6.15.269 zero-coverage fill)
    -- Cinder Brew is POINT-AOE 0.2 cast slow+dot. Anim catches placement.
    Anim.RegisterMap("npc_dota_hero_brewmaster", {
        [AB[2]] = { ability = "brewmaster_cinder_brew", role = "hard_disable" },
    })
    -- broodmother (v6.15.268 zero-coverage fill)
    -- v0.5.36: Sticky Snare is POINT VECTOR_TARGETING CHANNELLED -- Brood places a
    -- web-snare that roots Lina if she walks through. anim catches the
    -- cast.
    Anim.RegisterMap("npc_dota_hero_broodmother", {
        [AB[4]] = { ability = "broodmother_sticky_snare", role = "hard_disable" },
    })
    -- bristleback (v6.15.266 zero-coverage fill)
    -- Hairball is a hidden POINT-AOE that fires a line of viscous goo (same
    -- mechanic as Viscous Nasal Goo Q, but auto-cast multi-target).
    Anim.RegisterMap("npc_dota_hero_bristleback", {
        [AB[4]] = { ability = "bristleback_hairball", role = "hard_disable" },
    })
    -- centaur (v6.15.270 zero-coverage final mop-up)
    -- v0.5.36: Double Edge is UNIT_TARGET AOE instant burst; no target-side modifier.
    -- Anim catches the cast. instant_target since Centaur selects target.
    Anim.RegisterMap("npc_dota_hero_centaur", {
        [AB[2]] = { ability = "centaur_double_edge", role = "hard_disable", instant_target = true },
    })
    -- chaos_knight
    Anim.RegisterMap("npc_dota_hero_chaos_knight", {
        [AB[1]] = { ability = "chaos_knight_chaos_bolt", role = "hard_disable" },
        [AB[2]] = { ability = "chaos_knight_reality_rift", role = "gap_close" },
    })
    -- chen (v6.15.270 zero-coverage final mop-up)
    -- Penitence is UNIT_TARGET slow + damage amp. 0.3 cast; Chen aims.
    Anim.RegisterMap("npc_dota_hero_chen", {
        [AB[1]] = { ability = "chen_penitence", role = "hard_disable" },
    })
    -- clinkz
    Anim.RegisterMap("npc_dota_hero_clinkz", {
        [AB[1]] = { ability = "clinkz_burning_barrage", role = "channel_start" },  -- (draft)
    })
    -- crystal_maiden
    Anim.RegisterMap("npc_dota_hero_crystal_maiden", {
        [AB[4]] = { ability = "crystal_maiden_freezing_field", role = "channel_start", instant_target = true },  -- v0.5.132.1: instant_target bypasses on_channel_start's target_self facing gate (a self-PBAoE channel never "aims" at Lina; the v0.5.132 demo showed CM FF logged modseen only and never dispatched). Belt-and-suspenders alongside the modifier-create path (handle_caster_channel_interrupt).
    })
    -- dark_seer (v6.15.268 zero-coverage fill)
    -- Vacuum is POINT-AOE pull. Anim catches the cast; chain dispatches
    -- BKB (blocks pull) or dispel-priority.
    Anim.RegisterMap("npc_dota_hero_dark_seer", {
        [AB[1]] = { ability = "dark_seer_vacuum", role = "hard_disable" },
    })
    -- dark_willow
    Anim.RegisterMap("npc_dota_hero_dark_willow", {
        [AB[1]] = { ability = "dark_willow_bramble_maze", role = "hard_disable" },
        [AB[3]] = { ability = "dark_willow_cursed_crown", role = "hard_disable" },
        [AB[5]] = { ability = "dark_willow_terrorize", role = "hard_disable" },
    })
    -- dawnbreaker
    Anim.RegisterMap("npc_dota_hero_dawnbreaker", {
        [AB[2]] = { ability = "dawnbreaker_celestial_hammer", role = "gap_close" },
        [AB[4]] = { ability = "dawnbreaker_solar_guardian", role = "channel_start" },  -- (draft)
    })
    -- death_prophet (v6.15.258 zero-coverage fill)
    Anim.RegisterMap("npc_dota_hero_death_prophet", {
        [AB[2]] = { ability = "death_prophet_silence", role = "hard_disable" },  -- AOE silence
    })
    -- disruptor
    Anim.RegisterMap("npc_dota_hero_disruptor", {
        [AB[4]] = { ability = "disruptor_static_storm", role = "hard_disable" },
    })
    -- doom_bringer (v6.15.265 zero-coverage fill)
    -- Infernal Blade is autocast UNIT_TARGET on Doom's attack target -- no
    -- aim, instant trigger; instant_target bypasses the facing gate.
    Anim.RegisterMap("npc_dota_hero_doom_bringer", {
        [AB[3]] = { ability = "doom_bringer_infernal_blade", role = "hard_disable", instant_target = true },
    })
    -- dragon_knight (v6.15.258 zero-coverage fill)
    Anim.RegisterMap("npc_dota_hero_dragon_knight", {
        [AB[2]] = { ability = "dragon_knight_dragon_tail", role = "hard_disable" },  -- single-target stun
    })
    -- drow_ranger
    Anim.RegisterMap("npc_dota_hero_drow_ranger", {
        [AB[3]] = { ability = "drow_ranger_multishot", role = "channel_start" },  -- (draft)
    })
    -- earth_spirit
    Anim.RegisterMap("npc_dota_hero_earth_spirit", {
        [AB[2]] = { ability = "earth_spirit_rolling_boulder", role = "hard_disable" },
    })
    -- earthshaker
    Anim.RegisterMap("npc_dota_hero_earthshaker", {
        [AB[4]] = { ability = "earthshaker_echo_slam", role = "hard_disable" },
    })
    -- elder_titan
    Anim.RegisterMap("npc_dota_hero_elder_titan", {
        [AB[1]] = { ability = "elder_titan_echo_stomp", role = "channel_start" },  -- (draft)
    })
    -- ember_spirit (v6.15.268 zero-coverage fill)
    -- Sleight of Fist is POINT-AOE 0-cast-point ROOT_DISABLES (Ember
    -- becomes untargetable while flickering through enemies). Anim
    -- catches the cast; chain dispatches BKB / displacement.
    Anim.RegisterMap("npc_dota_hero_ember_spirit", {
        [AB[2]] = { ability = "ember_spirit_sleight_of_fist", role = "hard_disable" },
    })
    -- enchantress (v6.15.270 zero-coverage final mop-up)
    -- Impetus is autocast attack-replacement (UNIT_TARGET AUTOCAST
    -- ATTACK) - more damage the further Sniper is from Enchantress.
    -- No specific modifier; anim catches the autocast trigger.
    Anim.RegisterMap("npc_dota_hero_enchantress", {
        [AB[4]] = { ability = "enchantress_impetus", role = "hard_disable", instant_target = true },
    })
    -- enigma
    Anim.RegisterMap("npc_dota_hero_enigma", {
        [AB[1]] = { ability = "enigma_malefice", role = "hard_disable" },
        [AB[4]] = { ability = "enigma_black_hole", role = "hard_disable" },
    })
    -- faceless_void
    Anim.RegisterMap("npc_dota_hero_faceless_void", {
        [AB[4]] = { ability = "faceless_void_chronosphere", role = "hard_disable" },
    })
    -- furion (Nature's Prophet) (v6.15.265 zero-coverage fill)
    Anim.RegisterMap("npc_dota_hero_furion", {
        [AB[1]] = { ability = "furion_sprout", role = "hard_disable", instant_target = true },  -- UNIT_TARGET, 0.35 cast
    })
    -- grimstroke
    Anim.RegisterMap("npc_dota_hero_grimstroke", {
        [AB[2]] = { ability = "grimstroke_ink_creature", role = "hard_disable" },
        [AB[4]] = { ability = "grimstroke_soul_chain", role = "channel_start", instant_target = true },
    })
    -- gyrocopter (v6.15.263 zero-coverage fill)
    Anim.RegisterMap("npc_dota_hero_gyrocopter", {
        [AB[2]] = { ability = "gyrocopter_homing_missile", role = "hard_disable", instant_target = true },  -- 0 cast, IGNORE_BACKSWING
        [AB[4]] = { ability = "gyrocopter_call_down", role = "hard_disable" },  -- POINT-AOE, 0.3 cast
    })
    -- hoodwink
    Anim.RegisterMap("npc_dota_hero_hoodwink", {
        [AB[2]] = { ability = "hoodwink_bushwhack", role = "hard_disable" },
    })
    -- huskar
    Anim.RegisterMap("npc_dota_hero_huskar", {
        [AB[4]] = { ability = "huskar_life_break", role = "gap_close" },
    })
    -- jakiro
    Anim.RegisterMap("npc_dota_hero_jakiro", {
        [AB[2]] = { ability = "jakiro_ice_path", role = "hard_disable" },
    })
    -- juggernaut (v6.15.266 zero-coverage fill)
    -- Omni Slash is UNIT_TARGET 4s channel, locks target + invuln + massive
    -- damage. Swift Slash is new 0.3s UNIT_TARGET gap-close (mini Omni).
    -- Both no-aim (caster selects target by reference) -> instant_target.
    Anim.RegisterMap("npc_dota_hero_juggernaut", {
        [AB[4]] = { ability = "juggernaut_swift_slash", role = "gap_close", instant_target = true },
        [AB[4]] = { ability = "juggernaut_omni_slash", role = "channel_start", instant_target = true },
    })
    -- keeper_of_the_light
    Anim.RegisterMap("npc_dota_hero_keeper_of_the_light", {
        [AB[1]] = { ability = "keeper_of_the_light_illuminate", role = "channel_start" },  -- (draft)
    })
    -- kunkka (v6.15.263 zero-coverage fill)
    Anim.RegisterMap("npc_dota_hero_kunkka", {
        [AB[1]] = { ability = "kunkka_torrent", role = "hard_disable" },  -- POINT-AOE, 0.4 cast, 1.5s warning
        [AB[3]] = { ability = "kunkka_x_marks_the_spot", role = "hard_disable", instant_target = true },  -- unit-target, IGNORE_BACKSWING
    })
    -- kez
    -- v6.15.256: Grappling Claw is unit-target (Kez selects target by
    -- reference, doesn't aim); apply instant_target so the anim path
    -- detects regardless of Kez's facing. KV confirms UNIT_TARGET +
    -- IGNORE_BACKSWING + ROOT_DISABLES with cast point 0 -- same class as
    -- PA Phantom Strike. The v6.15.250 PA fix sweep missed Kez. Raptor
    -- Dance stays gate-on (it's a self-cast AoE channel; the facing gate
    -- filters far-away casts that aren't targeting Sniper).
    Anim.RegisterMap("npc_dota_hero_kez", {
        [AB[2]] = { ability = "kez_grappling_claw", role = "gap_close", instant_target = true },
        [AB[4]] = { ability = "kez_raptor_dance", role = "hard_disable" },
    })
    -- leshrac
    Anim.RegisterMap("npc_dota_hero_leshrac", {
        [AB[1]] = { ability = "leshrac_split_earth", role = "hard_disable" },
    })
    -- lich
    Anim.RegisterMap("npc_dota_hero_lich", {
        [AB[3]] = { ability = "lich_sinister_gaze", role = "channel_start", instant_target = true },
        [AB[6]] = { ability = "lich_chain_frost", role = "ult_burst" },
    })
    -- life_stealer
    Anim.RegisterMap("npc_dota_hero_life_stealer", {
        [AB[3]] = { ability = "life_stealer_open_wounds", role = "hard_disable" },
    })
    -- lina
    Anim.RegisterMap("npc_dota_hero_lina", {
        [AB[2]] = { ability = "lina_light_strike_array", role = "hard_disable" },
        [AB[4]] = { ability = "lina_laguna_blade", role = "ult_burst" },
    })
    -- lion
    Anim.RegisterMap("npc_dota_hero_lion", {
        [AB[1]] = { ability = "lion_impale", role = "hard_disable" },
        [AB[2]] = { ability = "lion_voodoo", role = "hard_disable" },
        [AB[3]] = { ability = "lion_mana_drain", role = "channel_start" },
        [AB[4]] = { ability = "lion_finger_of_death", role = "ult_burst" },
    })
    -- lone_druid (v6.15.267 zero-coverage fill)
    -- Savage Roar is NO_TARGET fear AoE around the caster. Anim catches
    -- the cast; chain dispatches BKB / Eul to avoid fear movement.
    -- Bear Entangle (the main passive root) detection is reactive only --
    -- proc on attack, no anim.
    Anim.RegisterMap("npc_dota_hero_lone_druid", {
        [AB[3]] = { ability = "lone_druid_savage_roar", role = "hard_disable" },
    })
    -- lycan (v6.15.270 zero-coverage final mop-up)
    -- Howl is NO_TARGET team damage buff (enables enemy team to gank
    -- Sniper). Routed via ENEMY_BUFF_THREATS dispatcher; anim catches
    -- the cast for awareness.
    Anim.RegisterMap("npc_dota_hero_lycan", {
        [AB[2]] = { ability = "lycan_howl", role = "hard_disable" },
    })
    -- luna (v6.15.265 zero-coverage fill)
    -- Lucent Beam is UNIT_TARGET, no aim required (Luna selects target by
    -- reference). 0.4 cast point. instant_target bypasses the facing gate.
    Anim.RegisterMap("npc_dota_hero_luna", {
        [AB[1]] = { ability = "luna_lucent_beam", role = "hard_disable", instant_target = true },
    })
    -- magnataur
    Anim.RegisterMap("npc_dota_hero_magnataur", {
        [AB[3]] = { ability = "magnataur_skewer", role = "hard_disable" },
        [AB[4]] = { ability = "magnataur_reverse_polarity", role = "hard_disable" },
    })
    -- marci
    -- v6.15.256: Grapple is unit-target (Marci pulls herself to the
    -- selected target without aim). Same v6.15.250 pattern as PA / Kez --
    -- the facing gate would refuse the anim path because Marci doesn't
    -- face Sniper when grappling. instant_target=true bypasses the gate.
    Anim.RegisterMap("npc_dota_hero_marci", {
        [AB[5]] = { ability = "marci_grapple", role = "gap_close", instant_target = true },
    })
    -- medusa (v6.15.268 zero-coverage fill)
    -- Mystic Snake is UNIT_TARGET (bounces between enemies). Gorgon Grasp
    -- is POINT-AOE stun. Both aim-required; default facing gate.
    Anim.RegisterMap("npc_dota_hero_medusa", {
        [AB[2]] = { ability = "medusa_mystic_snake", role = "hard_disable" },
        [AB[3]] = { ability = "medusa_gorgon_grasp", role = "hard_disable" },
    })
    -- mars
    Anim.RegisterMap("npc_dota_hero_mars", {
        [AB[5]] = { ability = "mars_spear", role = "hard_disable" },
        [AB[4]] = { ability = "mars_gods_rebuke", role = "hard_disable" },
        [AB[1]] = { ability = "mars_arena_of_blood", role = "hard_disable" },
    })
    -- meepo (v6.15.266 zero-coverage fill)
    -- Earthbind = POINT-AOE delayed root projectile. Poof = UNIT_TARGET
    -- 1.5s channelled gap-close (Meepo teleports to target location).
    -- Poof anim is the warning that Meepos are converging on Sniper.
    Anim.RegisterMap("npc_dota_hero_meepo", {
        [AB[1]] = { ability = "meepo_earthbind", role = "hard_disable" },
        [AB[2]] = { ability = "meepo_poof", role = "gap_close" },
    })
    -- mirana
    Anim.RegisterMap("npc_dota_hero_mirana", {
        [AB[2]] = { ability = "mirana_arrow", role = "hard_disable" },
    })
    -- monkey_king (v6.15.266 zero-coverage fill)
    -- Wukong's Command is POINT-AOE ult that creates a 4s cage of clones
    -- attacking inside. Hard disable (cage prevents leaving via standard
    -- movement); delayed_aoe dispatches blink / Pike / Force out.
    Anim.RegisterMap("npc_dota_hero_monkey_king", {
        [AB[4]] = { ability = "monkey_king_wukongs_command", role = "hard_disable" },
    })
    -- morphling
    Anim.RegisterMap("npc_dota_hero_morphling", {
        [AB[2]] = { ability = "morphling_adaptive_strike_agi", role = "hard_disable" },
    })
    -- muerta
    Anim.RegisterMap("npc_dota_hero_muerta", {
        [AB[1]] = { ability = "muerta_dead_shot", role = "hard_disable" },
    })
    -- naga_siren
    Anim.RegisterMap("npc_dota_hero_naga_siren", {
        [AB[2]] = { ability = "naga_siren_ensnare", role = "hard_disable" },
        [AB[4]] = { ability = "naga_siren_song_of_the_siren", role = "hard_disable" },
    })
    -- necrolyte
    Anim.RegisterMap("npc_dota_hero_necrolyte", {
        [AB[4]] = { ability = "necrolyte_reapers_scythe", role = "ult_burst" },
    })
    -- nevermore (Shadow Fiend) (v6.15.263 zero-coverage fill)
    Anim.RegisterMap("npc_dota_hero_nevermore", {
        [AB[4]] = { ability = "nevermore_requiem_of_souls", role = "ult_burst" },  -- 1s windup, fear + radial damage
    })
    -- night_stalker (v6.15.258 zero-coverage fill)
    Anim.RegisterMap("npc_dota_hero_night_stalker", {
        [AB[1]] = { ability = "night_stalker_void", role = "hard_disable" },  -- 0.3 cast, full stun at night
    })
    -- nyx_assassin
    Anim.RegisterMap("npc_dota_hero_nyx_assassin", {
        [AB[1]] = { ability = "nyx_assassin_impale", role = "hard_disable" },
        [AB[6]] = { ability = "nyx_assassin_vendetta", role = "gap_close" },
    })
    -- obsidian_destroyer
    -- v6.15.250: Astral Imprisonment is unit-target (selects target by
    -- reference, doesn't aim); apply instant_target to allow anim-path
    -- detection regardless of OD's facing. Sanity Eclipse stays gate-on
    -- as a centred AoE -- the facing gate is a useful filter for far-away
    -- casts that aren't targeting Sniper.
    Anim.RegisterMap("npc_dota_hero_obsidian_destroyer", {
        [AB[2]] = { ability = "obsidian_destroyer_astral_imprisonment", role = "hard_disable", instant_target = true },
        [AB[4]] = { ability = "obsidian_destroyer_sanity_eclipse", role = "ult_burst" },
    })
    -- ogre_magi (v6.15.258 zero-coverage fill)
    Anim.RegisterMap("npc_dota_hero_ogre_magi", {
        [AB[1]] = { ability = "ogre_magi_fireblast", role = "hard_disable" },  -- 0.45 cast, 1.5-2.4s stun
    })
    -- omniknight (v6.15.270 zero-coverage final mop-up)
    -- Hammer of Purity is autocast UNIT_TARGET single-target nuke.
    -- instant_target since Omniknight selects target by reference.
    Anim.RegisterMap("npc_dota_hero_omniknight", {
        [AB[1]] = { ability = "omniknight_hammer_of_purity", role = "hard_disable", instant_target = true },
    })
    -- oracle
    Anim.RegisterMap("npc_dota_hero_oracle", {
        [AB[1]] = { ability = "oracle_fortunes_end", role = "channel_start", instant_target = true },
    })
    -- pangolier
    Anim.RegisterMap("npc_dota_hero_pangolier", {
        [AB[1]] = { ability = "pangolier_swashbuckle", role = "gap_close" },
        [AB[4]] = { ability = "pangolier_gyroshell", role = "gap_close" },
    })
    -- phantom_assassin
    -- v6.15.250: instant_target=true bypasses the lib/anim.lua facing gate.
    -- Phantom Strike is unit-target (selected by reference, not aim); PA
    -- does not face Sniper when blink-targeting him, so the v6.15.232
    -- math.deg facing gate was rejecting all PA blinks since that build.
    -- Pre-v6.15.232 the gate accidentally always-passed (radians bug) and
    -- PA detection worked; v6.15.232's correct math.deg fix exposed the
    -- latent issue. The modifier-path backup (OnModifierCreate at
    -- modifier_phantom_assassin_phantom_strike_target) doesn't catch PA
    -- either because that target-side modifier no longer exists in modern
    -- Dota, so the anim path is the only working detection.
    Anim.RegisterMap("npc_dota_hero_phantom_assassin", {
        [AB[2]] = { ability = "phantom_assassin_phantom_strike", role = "gap_close", instant_target = true },
    })
    -- phantom_lancer (v6.15.266 zero-coverage fill)
    -- Spirit Lance is UNIT_TARGET instant slow + damage. PL doesn't aim
    -- (target by reference); instant_target bypasses facing gate.
    Anim.RegisterMap("npc_dota_hero_phantom_lancer", {
        [AB[1]] = { ability = "phantom_lancer_spirit_lance", role = "hard_disable", instant_target = true },
    })
    -- phoenix (v6.15.269 zero-coverage fill)
    -- Sun Ray is POINT 0.01 cast line beam channelled DoT + slow. Phoenix
    -- aims the line; default facing gate. Anim catches the cast.
    Anim.RegisterMap("npc_dota_hero_phoenix", {
        [AB[3]] = { ability = "phoenix_sun_ray", role = "hard_disable" },
    })
    -- primal_beast
    -- v6.15.250: Pulverize is unit-target (channel that locks the target by
    -- reference); add instant_target so PB's facing doesn't gate the
    -- channel-start save. Onslaught is a line dash -- PB DOES aim it -- so
    -- the facing gate stays for that one.
    Anim.RegisterMap("npc_dota_hero_primal_beast", {
        [AB[2]] = { ability = "primal_beast_onslaught", role = "gap_close" },
        [AB[5]] = { ability = "primal_beast_pulverize", role = "channel_start", instant_target = true },
    })
    -- puck
    Anim.RegisterMap("npc_dota_hero_puck", {
        [AB[2]] = { ability = "puck_waning_rift", role = "hard_disable" },
        [AB[3]] = { ability = "puck_phase_shift", role = "channel_start" },  -- (draft)
        [AB[5]] = { ability = "puck_dream_coil", role = "hard_disable" },
    })
    -- pudge
    -- v6.15.250: Dismember is unit-target (Pudge selects Sniper by
    -- reference, doesn't aim); add instant_target so the channel-start
    -- save fires even when Pudge faces away. Meat Hook is a line skill-
    -- shot (Pudge DOES aim it) -- facing gate stays for that one.
    Anim.RegisterMap("npc_dota_hero_pudge", {
        [AB[1]] = { ability = "pudge_meat_hook", role = "gap_close", range = 1500 },  -- v0.5.147.2: hook_distance 1300 (+talent ~1500); without range the facing gate used DEFAULT_RANGE 1200 and silently rejected max-range hooks
        [AB[4]] = { ability = "pudge_dismember", role = "channel_start", instant_target = true },
    })
    -- pugna
    Anim.RegisterMap("npc_dota_hero_pugna", {
        [AB[4]] = { ability = "pugna_life_drain", role = "channel_start", instant_target = true },
    })
    -- rattletrap
    Anim.RegisterMap("npc_dota_hero_rattletrap", {
        [AB[4]] = { ability = "rattletrap_hookshot", role = "gap_close", range = 3000 },  -- v0.5.147.2: Hookshot cast range 2000-3000; DEFAULT_RANGE 1200 rejected it (the v0.5.147 demo blind spot)
    })
    -- riki (v6.15.267 added blink_strike + smoke_screen)
    -- Blink Strike is UNIT_TARGET 0.3 cast IGNORE_BACKSWING -- Riki blinks
    -- to target and attacks; no aim. Smoke Screen is POINT-AOE silence +
    -- miss chance (anim catches the placement).
    Anim.RegisterMap("npc_dota_hero_riki", {
        [AB[2]] = { ability = "riki_blink_strike", role = "gap_close", instant_target = true },
        [AB[1]] = { ability = "riki_smoke_screen", role = "hard_disable" },
        [AB[4]] = { ability = "riki_tricks_of_the_trade", role = "channel_start" },  -- (draft)
    })
    -- ringmaster
    Anim.RegisterMap("npc_dota_hero_ringmaster", {
        [AB[1]] = { ability = "ringmaster_tame_the_beasts", role = "channel_start" },  -- (draft)
        [AB[6]] = { ability = "ringmaster_impalement", role = "hard_disable" },
        [AB[5]] = { ability = "ringmaster_wheel", role = "hard_disable" },
    })
    -- rubick (v6.15.258 zero-coverage fill)
    Anim.RegisterMap("npc_dota_hero_rubick", {
        [AB[1]] = { ability = "rubick_telekinesis", role = "hard_disable" },  -- 0.1 cast, lift+land stun (IGNORE_BACKSWING)
    })
    -- sand_king
    Anim.RegisterMap("npc_dota_hero_sand_king", {
        [AB[1]] = { ability = "sandking_burrowstrike", role = "hard_disable" },
        [AB[4]] = { ability = "sandking_epicenter", role = "hard_disable", instant_target = true },  -- v0.5.132.3: Epicenter is a no-target self-cast (the AoE expands from SK), so on_hard_disable's target_self facing gate was false and the cast-point arming never ran -- the v0.5.132 demo showed modseen modifier_sand_king_epicenter but NO dispatch. instant_target bypasses the gate so on_hard_disable arms the cast-point entry (cp 2.0) and the armed tick fires W (eta<=1.20 -> lands ~1.9s, inside the 2s wind-up). Burrowstrike (above) stays gated -- it IS aimed.
    })
    -- shadow_demon
    Anim.RegisterMap("npc_dota_hero_shadow_demon", {
        [AB[1]] = { ability = "shadow_demon_disruption", role = "hard_disable" },
        [AB[5]] = { ability = "shadow_demon_demonic_purge", role = "hard_disable" },
    })
    -- shadow_shaman
    Anim.RegisterMap("npc_dota_hero_shadow_shaman", {
        [AB[2]] = { ability = "shadow_shaman_voodoo", role = "hard_disable" },
        [AB[3]] = { ability = "shadow_shaman_shackles", role = "channel_start", instant_target = true },
    })
    -- shredder (v6.15.269 zero-coverage fill)
    -- Chakram is POINT-AOE IGNORE_BACKSWING line slow + disarm. Anim
    -- catches the throw; default facing gate (Shredder aims the line).
    Anim.RegisterMap("npc_dota_hero_shredder", {
        [AB[4]] = { ability = "shredder_chakram", role = "hard_disable" },
    })
    -- silencer (v6.15.258 zero-coverage fill)
    Anim.RegisterMap("npc_dota_hero_silencer", {
        [AB[3]] = { ability = "silencer_last_word", role = "hard_disable" },  -- 0.3 cast, silence on cast or 4s timer
    })
    -- skywrath_mage
    Anim.RegisterMap("npc_dota_hero_skywrath_mage", {
        [AB[3]] = { ability = "skywrath_mage_ancient_seal", role = "hard_disable" },
        [AB[4]] = { ability = "skywrath_mage_mystic_flare", role = "hard_disable" },
    })
    -- slardar (v6.15.266 zero-coverage fill)
    -- Slithereen Crush is NO_TARGET AoE stun around Slardar. Amplify
    -- Damage is UNIT_TARGET armor-debuff setup, instant cast.
    Anim.RegisterMap("npc_dota_hero_slardar", {
        [AB[2]] = { ability = "slardar_slithereen_crush", role = "hard_disable" },
        [AB[4]] = { ability = "slardar_amplify_damage", role = "hard_disable", instant_target = true },
    })
    -- slark
    Anim.RegisterMap("npc_dota_hero_slark", {
        [AB[2]] = { ability = "slark_pounce", role = "gap_close", instant_target = true },  -- v0.5.136 Slice 2B: no_target pounce -> force target_self so on_gap_close detects + arms it
    })
    -- snapfire
    -- spectre (v6.15.265 zero-coverage fill)
    -- Spectral Dagger is POINT|UNIT_TARGET (Spectre aims a line that
    -- chases the target). 0.3 cast point. instant_target conservative
    -- since the cast resolves quickly.
    Anim.RegisterMap("npc_dota_hero_spectre", {
        [AB[1]] = { ability = "spectre_spectral_dagger", role = "hard_disable", instant_target = true },
    })
    -- snapfire (existing)
    Anim.RegisterMap("npc_dota_hero_snapfire", {
        [AB[1]] = { ability = "snapfire_scatterblast", role = "ult_burst" },
        [AB[4]] = { ability = "snapfire_mortimer_kisses", role = "hard_disable" },
    })
    -- spirit_breaker
    Anim.RegisterMap("npc_dota_hero_spirit_breaker", {
        [AB[1]] = { ability = "spirit_breaker_charge_of_darkness", role = "gap_close" },
        [AB[4]] = { ability = "spirit_breaker_nether_strike", role = "hard_disable" },
    })
    -- storm_spirit
    Anim.RegisterMap("npc_dota_hero_storm_spirit", {
        [AB[2]] = { ability = "storm_spirit_electric_vortex", role = "hard_disable" },
        [AB[4]] = { ability = "storm_spirit_ball_lightning", role = "gap_close" },
    })
    -- sven
    Anim.RegisterMap("npc_dota_hero_sven", {
        [AB[1]] = { ability = "sven_storm_bolt", role = "hard_disable" },
    })
    -- terrorblade (v6.15.263 zero-coverage fill)
    -- Sunder is unit-target instant HP swap. No Sniper-side modifier
    -- (instant burst); anim-path is the only detector. instant_target=true
    -- because TB selects Sniper by reference and doesn't aim.
    Anim.RegisterMap("npc_dota_hero_terrorblade", {
        [AB[4]] = { ability = "terrorblade_sunder", role = "ult_burst", instant_target = true },
    })
    -- tidehunter
    Anim.RegisterMap("npc_dota_hero_tidehunter", {
        [AB[4]] = { ability = "tidehunter_ravage", role = "hard_disable" },
    })
    -- tinker
    Anim.RegisterMap("npc_dota_hero_tinker", {
        [AB[4]] = { ability = "tinker_rearm", role = "channel_start" },  -- (draft)
    })
    -- tiny
    Anim.RegisterMap("npc_dota_hero_tiny", {
        [AB[2]] = { ability = "tiny_toss", role = "hard_disable" },
    })
    -- treant
    Anim.RegisterMap("npc_dota_hero_treant", {
        [AB[5]] = { ability = "treant_overgrowth", role = "hard_disable" },
    })
    -- troll_warlord (v6.15.268 zero-coverage fill)
    -- Whirling Axes Ranged is UNIT_TARGET POINT IGNORE_BACKSWING -- Troll
    -- throws axes that silence + damage. instant_target since Troll
    -- selects target by reference.
    Anim.RegisterMap("npc_dota_hero_troll_warlord", {
        [AB[3]] = { ability = "troll_warlord_whirling_axes_ranged", role = "hard_disable", instant_target = true },
    })
    -- tusk
    Anim.RegisterMap("npc_dota_hero_tusk", {
        [AB[1]] = { ability = "tusk_ice_shards", role = "hard_disable" },
        [AB[2]] = { ability = "tusk_snowball", role = "gap_close" },
    })
    -- vengefulspirit
    -- venomancer (v6.15.265 zero-coverage fill)
    -- Venomous Gale is POINT-AOE line with 0 cast point. Anim path fires
    -- the line_projectile dispatch (force/pike/grenade-self for perp).
    Anim.RegisterMap("npc_dota_hero_venomancer", {
        [AB[1]] = { ability = "venomancer_venomous_gale", role = "hard_disable" },
    })
    -- visage (v6.15.265 zero-coverage fill)
    -- Grave Chill is UNIT_TARGET slow+silence (Visage steals stats);
    -- Soul Assumption is UNIT_TARGET burst (high damage if Visage has
    -- charged souls). Both bypass facing gate via instant_target.
    Anim.RegisterMap("npc_dota_hero_visage", {
        [AB[3]] = { ability = "visage_grave_chill", role = "hard_disable", instant_target = true },
        [AB[2]] = { ability = "visage_soul_assumption", role = "ult_burst", instant_target = true },
    })
    -- vengefulspirit (existing)
    Anim.RegisterMap("npc_dota_hero_vengefulspirit", {
        [AB[4]] = { ability = "vengefulspirit_nether_swap", role = "hard_disable" },
    })
    -- void_spirit
    Anim.RegisterMap("npc_dota_hero_void_spirit", {
        [AB[1]] = { ability = "void_spirit_aether_remnant", role = "hard_disable" },
        [AB[2]] = { ability = "void_spirit_astral_step", role = "gap_close" },
    })
    -- warlock
    Anim.RegisterMap("npc_dota_hero_warlock", {
        [AB[3]] = { ability = "warlock_upheaval", role = "channel_start" },  -- (draft)
    })
    -- windrunner
    Anim.RegisterMap("npc_dota_hero_windrunner", {
        [AB[1]] = { ability = "windrunner_shackleshot", role = "hard_disable" },
        [AB[2]] = { ability = "windrunner_powershot", role = "channel_start" },  -- (draft)
    })
    -- winter_wyvern
    Anim.RegisterMap("npc_dota_hero_winter_wyvern", {
        [AB[4]] = { ability = "winter_wyvern_winters_curse", role = "hard_disable" },
    })
    -- witch_doctor
    Anim.RegisterMap("npc_dota_hero_witch_doctor", {
        [AB[4]] = { ability = "witch_doctor_death_ward", role = "channel_start", instant_target = true },  -- v0.5.132.1: facing-independent (the v0.5.132 demo showed WD fired only when facing Lina). v0.5.132.2: the invisible-channel case is now ALSO covered by the modifier-create path -- modifier_witch_doctor_death_ward lands on the visible ward unit, and handle_caster_channel_interrupt resolves the WD hero via Modifier.GetCaster (demo-gated: assumes the ward's create event reaches the brain).
    })
    -- zuus
    Anim.RegisterMap("npc_dota_hero_zuus", {
        [AB[2]] = { ability = "zuus_lightning_bolt", role = "ult_burst" },
        [AB[5]] = { ability = "zuus_thundergods_wrath", role = "ult_burst" },
    })

    -- Subscribe to role events
    Anim.Subscribe("gap_close",    on_gap_close)
    Anim.Subscribe("hard_disable", on_hard_disable)
    Anim.Subscribe("channel_start", on_channel_start)
    Anim.Subscribe("ult_burst",    on_hard_disable)  -- treat as hard-disable for save chain

    -- Particle signatures (backup detectors). Paths are conservative VPK
    -- guesses; verify in demo. v0.5.36: Lina's interest is fast/instant casts that
    -- skip OnUnitAnimation (Ball Lightning particle precedes the unit anim).
    Anim.RegisterParticle(
        "particles/units/heroes/hero_storm_spirit/storm_spirit_ball_lightning.vpcf",
        { ability = "storm_spirit_ball_lightning", role = "gap_close" })
    Anim.RegisterParticle(
        "particles/units/heroes/hero_spirit_breaker/spirit_breaker_charge_overhead.vpcf",
        { ability = "spirit_breaker_charge_of_darkness", role = "gap_close" })
    Anim.RegisterParticle(
        "particles/units/heroes/hero_lina/lina_spell_laguna_blade.vpcf",
        { ability = "lina_laguna_blade", role = "ult_burst" })
    Anim.RegisterParticle(
        "particles/units/heroes/hero_lion/lion_spell_finger_of_death.vpcf",
        { ability = "lion_finger_of_death", role = "ult_burst" })
    -- v6.15.241 (clue C2): substring-pattern fallbacks for channeled /
    -- instant AoE-disable ults -- caught at particle-create even when the
    -- cast anim is flaky and the modifier lands too late. Roles mirror the
    -- anim maps; the modifier route still dedups any double-fire. The
    -- substrings are stable ability tokens, tolerant of a particle-path
    -- rename. All five abilities resolve through ABILITY_TO_THREAT.
    Anim.RegisterParticlePattern("black_hole",
        { ability = "enigma_black_hole", role = "hard_disable" })
    Anim.RegisterParticlePattern("chronosphere",
        { ability = "faceless_void_chronosphere", role = "hard_disable" })
    Anim.RegisterParticlePattern("reverse_polarity",
        { ability = "magnataur_reverse_polarity", role = "hard_disable" })
    Anim.RegisterParticlePattern("freezing_field",
        { ability = "crystal_maiden_freezing_field", role = "channel_start" })
    Anim.RegisterParticlePattern("fiends_grip",
        { ability = "bane_fiends_grip", role = "channel_start" })
end

--------------------------------------------------------------- callbacks ----
-- Brain handlers. The lib .Wire calls (below) chain each library's own
-- bookkeeping handlers onto these (prior-first). All bodies are near-empty
-- in v0.1.0; Phase E populates defensive callbacks, Phase F the offensive.
local callbacks = {}

-- v0.5.12: PE-01 (Kinetic Field walk-into poll) REMOVED per user direction.
-- Lina has no grenade-equivalent push-out counter; KF entry is covered by
-- PE-04's LINA_SAVE_OVERRIDES entry for modifier_disruptor_kinetic_field
-- (v0.5.118 chain: WW > BKB > Pike) via the OnModifierCreate path. The
-- per-tick walk-into poll was a Sniper-specific optimisation (grenade pushes
-- Sniper OUT of the field) and is not the right defensive idiom for Lina's
-- displacement saves. If Lina ever needs the walk-into case (existing field
-- when Lina arrives, no modifier-create event on her), revisit with a
-- modifier-create-on-thinker registry instead of the per-tick scan.

function callbacks.OnUpdateEx()
    -- v0.5.37 PERF-07: sample now() once per frame and stash on state so the
    -- tick functions invoked below (cast_verify_tick / persistent_threats_tick /
    -- pre_face_tick / pending_steps_tick) can read state.frame_t for tick-local
    -- comparisons instead of each calling GlobalVars.GetCurTime() again. Set
    -- before the self_npc acquisition so the value is valid even on the first
    -- frame after acquisition (cast_verify_tick runs unconditionally below).
    state.frame_t = now()
    -- Acquire the local hero once and prove the gate by logging it. The outer
    -- gate wrap guarantees this body only runs when the local hero is Lina.
    if not state.self_npc then
        local h = Heroes.GetLocal()
        if h then
            state.self_npc = h
            tlog(1, "self_acquired", { name = uname(h) })
        end
    end
    -- v0.5.170: hero_value_eval_log (fc_value_debug probe) removed (menu-simplification)
    -- v0.5.15 OBS-01 (modseen POST_GAME dump): the PE-06 accumulator at ~3765
    -- grew state.seen_modifiers unbounded with no reader. Mirror Sniper.lua
    -- line 9269 (GameRules.GetGameState transition to POST_GAME, one-shot via
    -- state.seen_modifiers_dumped). Guard every chain node so a missing symbol
    -- degrades to silent no-op. Sort by count desc, cap at top 30. Lives
    -- OUTSIDE the self_npc gate so the dump still fires if Lina is dead when
    -- POST_GAME transitions.
    -- v0.5.43 D1: Dodger chain-item override (match-scoped). On transition
    -- into GAME_IN_PROGRESS capture+zero the 7 chain items in the Dodger's
    -- self-defense list; on POST_GAME restore. Opt-in via state.menu.
    -- override_dodger (default on). Idempotent via state.dodger_disabled
    -- latch. Lives OUTSIDE the self_npc gate so capture happens once the
    -- game state transitions even if Lina isn't acquired yet (the framework
    -- Dodger doesn't care; toggles are global widgets).
    if state.menu and state.menu.override_dodger
       and state.menu.override_dodger:Get()
       and GameRules and GameRules.GetGameState
       and Enum and Enum.GameState then
        local gs_d = GameRules.GetGameState()
        if gs_d == Enum.GameState.DOTA_GAMERULES_STATE_GAME_IN_PROGRESS
           and not state.dodger_disabled then
            dodger_chain_disable()
        elseif gs_d == Enum.GameState.DOTA_GAMERULES_STATE_POST_GAME
           and state.dodger_disabled then
            dodger_chain_restore()
        end
    end

    -- v0.5.102 Note 3: Dodger BKB-panel override. Same transition hook +
    -- idempotent latch pattern as the items override above; separate toggle
    -- so the owner can disable one without the other.
    if state.menu and state.menu.override_dodger_bkb
       and state.menu.override_dodger_bkb:Get()
       and GameRules and GameRules.GetGameState
       and Enum and Enum.GameState then
        local gs_b = GameRules.GetGameState()
        if gs_b == Enum.GameState.DOTA_GAMERULES_STATE_GAME_IN_PROGRESS then
            if not state.dodger_bkb_disabled then
                DODGER_BKB.disable()
            else
                -- v0.5.107: lazy-panel retry (self-gated: interval, budget,
                -- empty failed list all no-op).
                DODGER_BKB.retry_tick()
            end
        elseif gs_b == Enum.GameState.DOTA_GAMERULES_STATE_POST_GAME
           and state.dodger_bkb_disabled then
            DODGER_BKB.restore()
        end
    end

    -- v0.5.45.1 LB: Linkbreaker override. Same transition hook + idempotent
    -- latch pattern as the Dodger override above. Separate menu toggle so
    -- owner can disable one without the other.
    if state.menu and state.menu.override_linkbreaker
       and state.menu.override_linkbreaker:Get()
       and GameRules and GameRules.GetGameState
       and Enum and Enum.GameState then
        local gs_lb = GameRules.GetGameState()
        if gs_lb == Enum.GameState.DOTA_GAMERULES_STATE_GAME_IN_PROGRESS
           and not state.linkbreaker_disabled then
            LB.disable()
        elseif gs_lb == Enum.GameState.DOTA_GAMERULES_STATE_POST_GAME
           and state.linkbreaker_disabled then
            LB.restore()
        end
    end

    -- v0.5.54: AutoDisabler stays active. v0.5.52 disabled AD's Force
    -- Interrupt items (Pike + Force Staff) to prevent brain-vs-AD
    -- double-fire on Bara charge. Per user spec "AutoDisabler is a
    -- native script that is 100% verified and working. Best way to
    -- make our script is not to disable it but live with it. Instead
    -- of disabling we can just gate it. Disabling it might mean that
    -- we are giving up a wide range of disables that are already
    -- working, this means extra working for low to no profit". The
    -- new approach: brain stays out of AD's lane by dropping
    -- prep_time on AD-owned saves (Pike in v0.5.54). The v0.5.52
    -- hook that called state.AD.disable() is gone. Auto-restore once
    -- if a prior v0.5.52 game left the framework AutoDisabler menu
    -- items zeroed (idempotent via state.AD.restore's internal
    -- state.autodisabler_disabled guard).
    if state.AD and state.autodisabler_disabled then
        state.AD.restore()
    end

    if not state.seen_modifiers_dumped and state.seen_modifiers
       and GameRules and GameRules.GetGameState then
        local gs = GameRules.GetGameState()
        if Enum and Enum.GameState
           and gs == Enum.GameState.DOTA_GAMERULES_STATE_POST_GAME then
            state.seen_modifiers_dumped = true
            local rows = {}
            for k, v in pairs(state.seen_modifiers) do
                rows[#rows + 1] = {
                    mod = k, count = v.count or 0,
                    first_t = v.first_t or 0,
                    last_caster = v.last_caster or "-",
                }
            end
            table.sort(rows, function(a, b) return a.count > b.count end)
            local n = math.min(#rows, 30)
            tlog(1, "modseen_postgame_begin", { unique = #rows, dumped = n })
            for i = 1, n do
                local r = rows[i]
                tlog(1, "modseen_postgame", {
                    mod = r.mod, count = r.count,
                    first_t = string.format("%.1f", r.first_t),
                    last_caster = r.last_caster,
                })
            end
        end
    end
    if state.self_npc then
        -- v0.5.15 OBS-04: latch lowest HP seen since last respawn / heal-to-full.
        -- Cleared above 90% max as a stand-in for OnRespawn (not wired in scope);
        -- worst case a mid-fight top-up loses one death's nadir signal, but the
        -- watermark never reads falsely low.
        -- v0.5.24 PERF-14: 5Hz gate. hp_max changes on level / aura churn only,
        -- and the death postmortem signal does not need 60Hz resolution.
        if (now() - (state.last_nadir_t or 0)) >= 0.2 then
            state.last_nadir_t = now()
            local _hp_now = Entity.GetHealth and Entity.GetHealth(state.self_npc)
            if _hp_now then
                local _hp_max = (Entity.GetMaxHealth and Entity.GetMaxHealth(state.self_npc)) or 1
                if _hp_now > _hp_max * 0.9 then
                    state.hp_nadir = nil
                elseif not state.hp_nadir or _hp_now < state.hp_nadir then
                    state.hp_nadir = _hp_now
                end
            end
        end
        persistent_threats_tick()  -- re-fire saves during Duel / Static Storm (lesson 60)
        armed_threats_tick()       -- fire-on-arrival homing saves
        -- v0.5.45 CA (DEFENSE_PLAN.md sec 4.2 commit-attacker track): sample
        -- enemy NPC.IsAttacking latches, then scan attackers in 700u for
        -- commit-attacker detection and synthesize close-gap dispatches.
        -- Order: AFTER armed_threats_tick so spell-armed entries take priority,
        -- BEFORE pre_face_tick / Layer-1 offense so the close-gap save fires
        -- before the brain reissues attacks toward the attacker. The two
        -- helpers self-gate on menu toggle and the dispatcher lock keys
        -- (state.self_npc, "lina_committed_attacker", caster_idx) prevent
        -- per-tick spam; per-caster re-arm latch is the additional gate.
        state.sample_attacker_latches()
        state.scan_and_arm_committed_attackers()
        -- v0.5.13 PIKE-PRIME-01 / PIKE-PRIME-TICK-NEVER-CALLED: restore the PE-03
        -- fresh-Pike prime + double-issue per-frame driver. Dead code since v0.5.11
        -- because this call site was omitted during the Sniper S29 port, so
        -- state.pike_primed never flipped, the throwaway PRIME cast never gated,
        -- and pike_reissue stamps written by SAVE_FIRE.item_hurricane_pike.fire
        -- accumulated unconsumed (direct cause of user T2). Function is defined
        -- unconditionally at state.pike_prime_tick (no nil-guard needed); reads only
        -- state.pike_primed / state.pike_prime_done / state.pike_reissue /
        -- state.count_engaged_enemies so ordering vs armed_threats_tick /
        -- pre_face_tick is not load-bearing.
        -- GREP: PIKE_PRIME_TICK_DEF (target is `state.pike_prime_tick = function()`).
        state.pike_prime_tick()
        state.pending_self_push_tick()  -- v0.5.57 Phase 5 / v0.5.58 slice 2:
                                         -- fire Pike OR Force once the
                                         -- turn-then-fire harness reaches
                                         -- alignment (or timeout drops it)
        state.pending_post_airborne_move_tick()  -- v0.5.62 Phase 5 slice 3: fire EUL / WW post-move once
                                         -- the airborne modifier clears (or restore Native on timeout)
        -- v0.5.171: pre_face_tick() call removed (preface_enable feature cut in menu-simplification)
        cast_poll_save_tick()      -- v0.5.147.x hook cast-poll save (detect hook cast -> displacement save)
        -- Layer 1 offense (Phase F): latch -> scheduled steps -> R-abort ->
        -- auto-R kill-steal -> HOLD/TAP combo-key dispatch.
        Geometry.SampleVelocities(state.self_npc)  -- v0.3.6: feed the smoothed-prediction buffer
        state.pending_steps_tick() -- fire deferred combo steps at their delays
        state.r_abort_tick()       -- STOP a doomed R mid-cast (refund mana/CD)
        state.lina_r_kill_steal_tick()
        -- v0.5.94 engine-blink detection: a Blink Dagger CD jump (ready -> on-CD)
        -- means the engine/user blinked Lina (the brain no longer casts Blink),
        -- so stamp the time for blink_capitalize_tick to seize the reposition.
        do
            local _bd = NPCLib.item(state.self_npc, "item_blink")
            local _bd_cd = (_bd and Ability.GetCooldown and (Ability.GetCooldown(_bd) or 0)) or 0
            -- v0.5.95: exclude a BRAIN-cast blink (it stamps brain_blinked_t).
            -- Capitalize is for ENGINE blinks; the brain-cast has its own combo.
            local _brain = state.brain_blinked_t and (state.frame_t - state.brain_blinked_t) < 0.5
            -- v0.5.96 fix: blink_cd_prev was read as (x or 0), so the FIRST observed
            -- tick saw 0 (<=0.1) and, if the dagger was already on CD then (script
            -- reload / reconnect / spectate->play with the dagger down), spuriously
            -- stamped a blink_seen with NO ready->on-CD transition ever observed.
            -- Seed the baseline on first observation so a seen-edge needs two real
            -- samples (prev<=0.1 -> cur>0.5 observed across ticks).
            if state.blink_cd_prev == nil then
                state.blink_cd_prev = _bd_cd          -- first sample: seed only, never an edge
            else
                if state.blink_cd_prev <= 0.1 and _bd_cd > 0.5 and not _brain then
                    state.blink_seen_t = state.frame_t
                    tlog(2, "blink_seen", { cd = string.format("%.1f", _bd_cd) })
                end
                state.blink_cd_prev = _bd_cd
            end
        end
        state.fc_defense_tick()    -- v0.5.158 A1: proactive defensive FC reserve (Tier-A) before the offense dispatch
        state.fc_escape_tick()     -- v0.5.16x Phase B: proactive FC terrain-escape (mobility claim)
        state.fc_chase_tick()      -- v0.5.16x Phase C: FC terrain-cutoff chase (offense already committing)
        state.jugg_omni_defer_tick()  -- v0.5.160.2 Note-1: fire the deferred Jugg Omnislash dodge mid-ult
        state.combo_key_tick()     -- HOLD/TAP classify + starter/teamfight dispatch
        state.blink_capitalize_tick()  -- v0.5.94: seize engine blinks (auto-combo, default OFF)
        state.w_capitalize_tick()  -- v0.5.137: combo the W-stunned gap-closer/committed attacker if killable (default ON)
        state.wave_clear_tick()    -- v0.5.78: HOLD wave-clear (Q line + W dense camp), mana-floor + creep-count gated
        state.dump_key_tick()      -- v0.5.15 OBS-08: one-press brain state dump bind
        state.panic_key_tick()     -- v0.5.37 MAINT-05: one-press 2.0s panic throttle-bypass bind
        state.test_key_tick()      -- v0.5.17 Track 1: one-press run-all-tests bind
        update_hitrun_pause()      -- keep native Hit & Run paused for the FULL combo
        -- v0.5.8 E3 (lib_native_F2, log_timing_F1/F5, history_F5): once every 5s
        -- emit a heartbeat snapshot of the native HR state alongside a coarse
        -- "brain is driving" proxy (pending-step count + combo_hold_active). On the
        -- next re-test, any user-reported AA dead spell can be correlated against
        -- the heartbeat closest in time: if paused=y while no steps are pending
        -- and combo_hold_active=false, the wide-pause revert failed to restore.
        -- Cheap: a single tlog every 5s. wget-style live Get() values on the
        -- underlying widgets are not reachable from this scope (Native module's
        -- cache + wget are file-local); Native.Resolve presence + Native.IsPaused
        -- brain flag give us the actionable signal for the F2/F5 hypotheses.
        local _t_hb = now()
        if _t_hb - (state.last_hr_heartbeat or 0) >= 5.0 then
            state.last_hr_heartbeat = _t_hb
            local _r = Native.Resolve(LINA_MENU)
            -- v0.5.9 E7 (log_noise_low): demote from level 1 -> level 2 now that
            -- the v0.5.8 hostile-radius (HR) fix is confirmed stable in the wild.
            -- The heartbeat dominated the default-on log stream (one record every
            -- 5s, every game) once the actionable diagnostic value dropped to
            -- near-zero. It remains fully visible at log_verbosity=2 so we can
            -- re-enable it on demand for future HR regression hunts (Native.Resolve
            -- + Native.IsPaused snapshot is still the right F2/F5 correlation
            -- signal; only the default visibility changed). No behaviour change to
            -- the HR computation, the 5s cadence, or the payload schema.
            tlog(2, "hr_heartbeat", {
                hr_en   = _r.hr_en and "y" or "n",
                hr_ov   = _r.hr_ov and "y" or "n",
                ow_ov   = _r.ow_ov and "y" or "n",
                paused  = Native.IsPaused(LINA_MENU) and "y" or "n",
                pend    = string.format("%d", #state.pending_steps),
                hold    = state.combo_hold_active and "y" or "n",
            })
        end
        -- v0.5.14 E2 (BL-A1): bound the two caller-owned dedup tables. In a
        -- 60-min standard-mode match the OnEntityKilled prefix-GC path is
        -- unreachable for non-killed casters (mod expires naturally / unit
        -- leaves vision), so responded_threats + anim_log_dedup grew
        -- monotonically. Mirror the 5s heartbeat cadence and delegate to
        -- the canonical Dedup.gc(responded_tbl, anim_tbl, now_t) signature
        -- (lib/dedup.lua:126); the `or 0` makes the first tick a no-op
        -- without needing a separate state init.
        local _t_gc = now()
        if _t_gc - (state.last_dedup_gc_t or 0) >= 5.0 then
            state.last_dedup_gc_t = _t_gc
            Dedup.gc(state.responded_threats, state.anim_log_dedup, _t_gc)
        end
        -- v0.5.15 OBS-02: 1Hz live refresh of the Diagnostics labels (self HP +
        -- L1/L2 counters). UCZone menu Label live-update is :ForceLocalization
        -- (Sniper.lua:10548 ships this on lbl_l1/lbl_l2 in production). Other
        -- frameworks expose SetText/SetName/SetValue, so probe those under pcall
        -- as graceful fallback for any future ABI shift. All wrapped in pcall so
        -- an unsupported widget is a silent no-op rather than a runtime throw.
        -- v0.5.24 PERF-01/09/10: 1Hz refresh of the TLOG3_ENABLED gate so the
        -- hot-path wrappers (pre_face_tick, OnModifierCreate, OnLinearProjectileCreate)
        -- skip kv table allocation when verbosity < 3.
        if (now() - (state.last_tlog3_check_t or 0)) > 1.0 then
            state.last_tlog3_check_t = now()
            TLOG3_ENABLED = (v_level() >= 3)
        end
        state.last_lbl_t = state.last_lbl_t or 0
        local _t_lbl = now()
        if _t_lbl - state.last_lbl_t >= 1.0 and state.menu then
            state.last_lbl_t = _t_lbl
            -- v0.5.36 PERF-13: _lbl_set hoisted to module-level (see decl near
            -- uname); no per-tick closure allocation, cached-setter probe.
            local lbl_s = state.menu.lbl_self
            if lbl_s then
                local hp    = (Entity.GetHealth    and Entity.GetHealth(state.self_npc))    or 0
                local hpmax = (Entity.GetMaxHealth and Entity.GetMaxHealth(state.self_npc)) or 1
                _lbl_set(lbl_s, string.format("self: %s hp %d/%d", uname(state.self_npc), hp, hpmax))
            end
            -- v0.5.88: combo-readiness chip. Only already-computed values: R
            -- cooldown, mana %, Fiery Soul stacks, and whether a full W+Q+R is
            -- castable now (all ready + mana for the combo cost). The offensive
            -- readout the HUD lacked (it had defensive item CDs but nothing for
            -- 'is my R up + can I WQR').
            local lbl_cb = state.menu.lbl_combo
            if lbl_cb then
                local me = state.self_npc
                local txt = "combo: -"
                if me then
                    local r = ability(A.R)
                    local r_txt
                    if ability_ready(A.R) then
                        r_txt = "R:rdy"
                    else
                        local cd = (r and Ability.GetCooldown and (Ability.GetCooldown(r) or 0)) or 0
                        r_txt = "R:" .. string.format("%.0f", cd) .. "s"
                    end
                    local mana = (NPC.GetMana and NPC.GetMana(me)) or 0
                    local maxm = (NPC.GetMaxMana and NPC.GetMaxMana(me)) or 1
                    local mp   = (maxm > 0) and (mana / maxm * 100) or 0
                    local fs   = compute_fs_state(me)
                    local wqr  = (ability_ready(A.W) and ability_ready(A.Q) and ability_ready(A.R)
                                  and mana >= (ability_mana(A.W) + ability_mana(A.Q) + ability_mana(A.R)))
                                 and "y" or "n"
                    txt = string.format("combo: %s mana:%.0f%% FS:%d wqr:%s",
                                        r_txt, mp, (fs and fs.stacks) or 0, wqr)
                end
                _lbl_set(lbl_cb, txt)
            end
            -- v0.5.88: lbl_counters demoted to a dev readout (verbosity >= 2).
            -- It is a brain-internal sanity counter the player never acts on; at
            -- default verbosity it yields its slot's attention to the live
            -- combat chips (combo / saves / gank / missing).
            local lbl_c = state.menu.lbl_counters
            if lbl_c then
                if v_level() >= 2 then
                    _lbl_set(lbl_c, string.format("counts: l1=%d l2=%d",
                        state.l1_counter or 0, state.l2_counter or 0))
                else
                    _lbl_set(lbl_c, "counts: (verbosity >= 2)")
                end
            end
            -- v0.5.80 feature D: power-spike save chips. Owned items only;
            -- "rdy" or remaining CD per item. Same 1Hz cadence + pcall-safe
            -- _lbl_set as the lines above.
            local lbl_sv = state.menu.lbl_saves
            if lbl_sv then
                local me = state.self_npc
                local parts = {}
                if me then
                    for i = 1, #POWER_SPIKE_SAVES do
                        local s  = POWER_SPIKE_SAVES[i]
                        local it = NPCLib.item(me, s.name)
                        if it then
                            if NPCLib.item_ready(me, s.name) then
                                parts[#parts + 1] = s.short .. ":rdy"
                            else
                                local cd = (Ability.GetCooldown and Ability.GetCooldown(it)) or 0
                                parts[#parts + 1] = s.short .. ":"
                                    .. string.format("%.0f", cd) .. "s"
                            end
                        end
                    end
                end
                _lbl_set(lbl_sv, "saves: "
                    .. ((#parts > 0) and table.concat(parts, " ") or "none owned"))
            end
            -- v0.5.88 optimize: ONE shared FogSnapshot for both fog chips (was
            -- two Heroes.GetAll scans per 1Hz tick -- possible_gankers() and
            -- missing_from_map() each scanned independently). Compute once and
            -- pass via opts.snapshot to the lib consumers directly.
            local me_fog   = state.self_npc
            local snap     = (me_fog and state.fog_snapshot) and state.fog_snapshot() or nil
            local fog_opts = snap and { max_ms = 700, now = now, snapshot = snap } or nil
            -- v0.5.84: gank-inbound chip (fog-aware). count + soonest ETA / clear.
            local lbl_gk = state.menu.lbl_gank
            if lbl_gk then
                local txt = "gank: clear"
                if me_fog and snap then
                    local p = Entity.GetAbsOrigin(me_fog)
                    if p then
                        local pg = Escape.PossibleGankers(me_fog, p, 4.0, fog_opts)
                        local n = (pg and pg.summary and pg.summary.count) or 0
                        if n > 0 then
                            txt = string.format("gank: %d inbound", n)
                            local soon = pg.summary.soonest_eta
                            if type(soon) == "number" and soon < math.huge then
                                txt = txt .. string.format(" ~%.1fs", soon)
                            end
                        end
                    end
                end
                _lbl_set(lbl_gk, txt)
            end
            -- v0.5.84: missing-enemies chip (off-minimap >= 5s, longest first,
            -- top 3). Pure info, no false-positive action cost.
            local lbl_ms = state.menu.lbl_missing
            if lbl_ms then
                local txt = "missing: -"
                if me_fog and snap then
                    local mm = Escape.MissingFromMap(me_fog, 5.0, fog_opts)
                    if mm and #mm > 0 then
                        local names = {}
                        for i = 1, math.min(3, #mm) do
                            names[#names + 1] = uname(mm[i].entity)
                                .. " " .. string.format("%.0fs", mm[i].age or 0)
                        end
                        txt = "missing: " .. table.concat(names, ", ")
                    end
                end
                _lbl_set(lbl_ms, txt)
            end
        end
    end
    cast_verify_tick()  -- ground-truth verification of issued casts (lesson 58)
end

-- v0.5.14 E9 (BL-A2, BL-A7): dead callback stubs removed. The framework only
-- dispatches keys that are registered; an empty stub still registers the key
-- and creates the "unsafe-mode-gate trap" where a future maintainer adds a
-- guard at the top and assumes the gate runs. Default permissive behaviour
-- is identical to OnPrepareUnitOrders returning true, and OnEntityHurt had
-- no body at all. Removing the keys eliminates the trap.

-- v0.5.37 MAINT-11: extracted the six logical branches of
-- callbacks.OnModifierCreate into named local helpers. Each helper carries
-- its branch's original outer gate (negated to early-return false when the
-- gate misses) and the verbatim branch body. Helpers whose original branch
-- always exited the function via `return` (handle_lotus_first,
-- handle_threat_on_self) return true so the dispatcher knows to stop;
-- void-effect helpers return nothing. Behaviour-neutral refactor; every
-- tlog string, comparison, dedup-stamp call, and side-effect ordering is
-- preserved. The armed close-gap arming block below the dispatcher stays
-- inline (not part of the six-branch scope).
local function handle_enemy_buff_threat(npc, modifier, mod_name)
    -- Diagnostic + enemy-buff threats (Bristleback Quill, Sven God's Strength).
    if Target.IsEnemyHero and Target.IsEnemyHero(npc, state.self_npc) then
        local caster = Modifier.GetCaster(modifier)
        if TLOG3_ENABLED then
            tlog(3, "modseen", { unit = uname(npc), mod = mod_name,
                caster = caster and uname(caster) or "-" })
        end
        local buff_entry = ENEMY_BUFF_THREATS and ENEMY_BUFF_THREATS[mod_name]
        if buff_entry and buff_entry.role ~= "informational"
           and defense_enabled() and layer2_can_fire()
           and not Dedup.threat_already_responded(state.responded_threats, npc, mod_name) then
            if try_save_self("enemy_buff_" .. mod_name, mod_name, npc) then
                Dedup.threat_mark_responded(state.responded_threats, npc, mod_name)
            end
        end
    end
end

-- v0.5.132.1: caster-side channel-interrupt dispatch (the v0.5.132 demo fix for
-- CM Freezing Field). on_channel_start (the anim path) only fires when the
-- channel's cast animation is seen AND ev.target_self passes; a self-centered
-- PBAoE channel (CM Freezing Field) fails the facing-based target_self gate, so
-- the demo logged modseen only and never dispatched. The channel modifier DOES
-- land on the caster (modseen-confirmed), so dispatch the W interrupt directly
-- off the modifier-create when a curated caster-side channel modifier appears on
-- an enemy hero -- facing- and anim-independent. The defense_dispatcher lock +
-- Dedup coalesce this with the anim path (single-spend) for channels that ALSO
-- fire on_channel_start (e.g. WD). LIMIT: a channeler invisible/fogged at cast
-- emits no modifier-create to the brain, so it cannot be caught here either.
local function handle_caster_channel_interrupt(npc, modifier, mod_name)
    if not (state.LINA_CASTER_CHANNEL_W_INTERRUPT
            and state.LINA_CASTER_CHANNEL_W_INTERRUPT[mod_name]) then return end
    -- v0.5.132.2: resolve the CHANNELER hero. A self-applied channel (CM
    -- Freezing Field) puts the modifier on the caster hero -> npc IS the
    -- channeler. A summon-applied channel (WD Death Ward) puts the modifier on
    -- the WARD unit -> the hero comes from Modifier.GetCaster. Resolving the
    -- caster lets W interrupt WD even when he channels from INVISIBILITY: the
    -- ward is visible (it attacks Lina) so its modifier-create reaches us, and
    -- WD is rooted while channeling so his last-known position is accurate.
    local caster = npc
    if not (Target.IsEnemyHero and Target.IsEnemyHero(caster, state.self_npc)) then
        caster = Modifier.GetCaster and Modifier.GetCaster(modifier)
    end
    if not (caster and Entity.IsEntity and Entity.IsEntity(caster)
            and Target.IsEnemyHero and Target.IsEnemyHero(caster, state.self_npc)) then
        return
    end
    if not (defense_enabled() and layer2_can_fire()) then return end
    -- Dedup + dispatch keyed on the CASTER hero (not npc, which may be the
    -- ward) so a re-applied ward modifier does not double-dispatch.
    if Dedup.threat_already_responded(state.responded_threats, caster, mod_name) then return end
    -- Mirror on_channel_start's Dispatch: caster-side channel, category_hint
    -- channel_on_self, no anim-save key (arg7 nil) so ResolveSaveOrder matches
    -- LINA_SAVE_OVERRIDES[mod_name] (hero_override); aim resolves to the caster
    -- via the catalog impact_pos="caster" inside lina_w_anti_gap.fire.
    defense_dispatcher:Dispatch("channel_" .. mod_name,
                                mod_name, caster,
                                state.self_npc, nil,
                                "channel_on_self", nil, nil,
                                record_save,
                                { fs_shard_window = fs_shard_window_active() })
end

-- v0.5.133 (Phase 2): interrupt a channel locking a TEAMMATE / the team by
-- W-stunning the caster. Sibling of handle_caster_channel_interrupt (Phase 1,
-- self/AoE). PRIORITY (W_INTERRUPT_PHASE2_DESIGN.md sec 1): self-save > this >
-- combo -- gated on "no self-threat armed" (self-first) but NOT on mid-combo
-- (the interrupt PREEMPTS the combo, per user: these channels are a priority to
-- stop, even more so in a teamfight). Aim resolves to the caster via the
-- catalog impact_pos="caster" / W_aim_at_caster_mods.
local function ally_interrupt_w_ready(caster)
    -- Shared opportunistic gate. Self-first: any armed self-threat blocks the
    -- ally interrupt so Lina handles her own situation first.
    if not (defense_enabled() and layer2_can_fire()) then return false end
    if not ability_ready("lina_light_strike_array") then return false end
    if next(state.armed_threats) ~= nil then return false end
    if not (caster and Entity.IsEntity and Entity.IsEntity(caster)
            and Target.IsEnemyHero and Target.IsEnemyHero(caster, state.self_npc)) then
        return false
    end
    -- Caster within W live cast range (issue_cast_position has no range gate, so
    -- gate here to avoid walking Lina into the fight).
    local wr = cast_range_of(ability("lina_light_strike_array"), FALLBACK_RANGES.W)
    local d  = dist_to(caster)
    if not (d and d <= wr) then return false end
    return true
end

-- Count allied heroes within the Black Hole radius of Enigma. Returns
-- (n_allies_excluding_lina, lina_caught). Positional (no dependency on the
-- per-unit lift modifier name).
local function count_allies_in_bh(enigma)
    local me = state.self_npc
    if not (me and enigma and Entity.GetAbsOrigin and Heroes and Heroes.InRadius
            and Entity.GetTeamNum and Enum and Enum.TeamType) then return 0, false end
    local epos = Entity.GetAbsOrigin(enigma)
    if not epos then return 0, false end
    local ok, list = pcall(Heroes.InRadius, epos, K.LINA_ENIGMA_BH_RADIUS,
                           Entity.GetTeamNum(me), Enum.TeamType.TEAM_FRIEND)
    if not ok or type(list) ~= "table" then return 0, false end
    local n, lina_caught = 0, false
    for _, h in ipairs(list) do
        if h == me then
            lina_caught = true
        elseif Target.NotIllusion and Target.NotIllusion(h) then
            n = n + 1
        end
    end
    return n, lina_caught
end

local function handle_ally_channel_interrupt(npc, modifier, mod_name)
    -- Sub-case A: single-target ally channel (victim-side modifier on an ally).
    -- v0.5.133.1: dispatch the SYNTHETIC mod "lina_ally_w_interrupt" so the chain
    -- is W-only (CH.ALLY_W_INTERRUPT); the real mod's own chain is the item
    -- self-save (WW/Manta/...) which cannot save an ally. Aim still targets the
    -- caster (threat_caster passed + the synthetic mod is in W_aim_at_caster_mods
    -- -> aim_via=caster_origin).
    if state.LINA_ALLY_CHANNEL_INTERRUPT[mod_name] then
        if not (Target.IsAllyHero and Target.IsAllyHero(npc, state.self_npc)
                and Target.NotIllusion and Target.NotIllusion(npc)) then return end
        local caster = Modifier.GetCaster and Modifier.GetCaster(modifier)
        if not ally_interrupt_w_ready(caster) then return end
        if Dedup.threat_already_responded(state.responded_threats, caster, "lina_ally_w_interrupt") then return end
        tlog(1, "ally_channel_interrupt", { case = "single_target", mod = mod_name,
            ally = uname(npc), caster = uname(caster) })
        defense_dispatcher:Dispatch("ally_channel_" .. mod_name, "lina_ally_w_interrupt", caster,
                                    state.self_npc, nil, "channel_on_self", nil, nil,
                                    record_save, { fs_shard_window = fs_shard_window_active() })
        return
    end
    -- Sub-case B: Enigma Black Hole (positional team save). v0.5.133.1: the
    -- channel modifier modifier_enigma_black_hole lands on a THINKER, not the
    -- Enigma hero (the v0.5.133 demo saw no modseen for it), so trigger on the
    -- victim-side modifier_enigma_black_hole_pull (lands on each caught unit) and
    -- resolve Enigma via Modifier.GetCaster (the WD-ward pattern). W only if Lina
    -- is FREE and 2+ allies caught; Lina caught -> her CH.ENIGMA_BH self-escape
    -- owns it. The dispatcher lock collapses the per-victim re-triggers to one W.
    if mod_name == "modifier_enigma_black_hole_pull" then
        local enigma = Modifier.GetCaster and Modifier.GetCaster(modifier)
        if not ally_interrupt_w_ready(enigma) then return end
        local n_caught, lina_caught = count_allies_in_bh(enigma)
        if lina_caught then return end
        if n_caught < 2 then return end
        if Dedup.threat_already_responded(state.responded_threats, enigma, "lina_ally_w_interrupt") then return end
        tlog(1, "ally_channel_interrupt", { case = "enigma_bh", mod = mod_name,
            caught = tostring(n_caught), caster = uname(enigma) })
        defense_dispatcher:Dispatch("ally_channel_" .. mod_name, "lina_ally_w_interrupt", enigma,
                                    state.self_npc, nil, "channel_on_self", nil, nil,
                                    record_save, { fs_shard_window = fs_shard_window_active() })
        return
    end
end

local function handle_modseen_accumulator(npc, modifier, mod_name, is_self)
    -- v0.5.11 PE-06: incoming-threat catalog accumulator (port of Sniper S38
    -- state.seen_modifiers, Sniper.lua line ~9395 OnModifierCreate accumulator
    -- + line ~9269 POST_GAME dump in OnUpdateEx). Sniper's diagnostic angle
    -- watches modifiers landing ON enemies to grow the enemy-buff threat
    -- catalog; Lina's mirror watches modifiers landing on the SAVEABLE side
    -- (self + allies) so that any threat that hits us without a wired save
    -- chain shows up in the postmortem rollup instead of needing a manual
    -- grep over debug.log. Keyed on bare mod_name (single counter regardless
    -- of which ally was hit); first_t / count / last_caster_name fields match
    -- Sniper's schema. Lazy-init the table so existing v0.5.5-.10 saved state
    -- (state.lua reload path) does not need a migration. The companion
    -- POST_GAME dump (sorted by count desc) lives in OnUpdateEx and is
    -- shipped as a separate PE-06 sub-patch -- this hunk only owns the
    -- accumulator half.
    if (is_self or (Target.IsAllyHero and Target.IsAllyHero(npc, state.self_npc)
                    and Target.NotIllusion and Target.NotIllusion(npc))) then
        state.seen_modifiers = state.seen_modifiers or {}
        local caster_mc = Modifier.GetCaster(modifier)
        local caster_name = caster_mc and uname(caster_mc) or "-"
        local seen = state.seen_modifiers[mod_name]
        if seen then
            seen.count = seen.count + 1
            seen.last_caster = caster_name
        else
            state.seen_modifiers[mod_name] = {
                first_t = now(), count = 1, last_caster = caster_name,
            }
        end
    end
end

local function handle_ally_save(npc, modifier, mod_name, is_self)
    -- Ally-threat reactive save (v0.2.7): a recognized threat landed on an ally
    -- hero. If it is a serious, ally-saveable category, fire an ally-castable
    -- item ON them (Glimmer / Lotus / Force). Threat-triggered, not HP-based.
    -- Dedup is keyed on the ALLY so each ally's threat is handled once.
    if not is_self and Target.IsAllyHero and Target.IsAllyHero(npc, state.self_npc)
       and Target.NotIllusion(npc) and defense_enabled() then
        local entry = THREATS_ON_SELF and THREATS_ON_SELF[mod_name]
        -- v0.5.3: prefer hero-side category (LINA_EXTRA_THREATS) over lib's
        -- default. lib's TD.CategoryOf returns "reactive" for unknown mods
        -- (including hero-wired ones like sniper_assassinate); without this
        -- the ally branch silently drops them as reactive-no-chain.
        local extra = LINA_EXTRA_THREATS[mod_name]
        local category = (extra and extra.category)
                         or (TD.CategoryOf and TD.CategoryOf(mod_name))
                         or nil
        local dedup_hit = Dedup.threat_already_responded(state.responded_threats, npc, mod_name)
        -- v0.5.1 D3.1 diagnostic: the demo showed zero try_save_ally events.
        -- This logs every modifier that reaches the ally branch with the
        -- inner-gate values so we can see exactly where the drop happens
        -- (no entry / no category / no ally chain / dedup hit / toggle off).
        -- Level 3 so it stays out of default logs; flip Diagnostics verbosity
        -- to 3 to capture.
        tlog(3, "ally_branch_consider", {
            ally        = uname(npc),
            mod         = mod_name,
            entry_ok    = (entry and "y") or "n",
            save_kind   = (entry and entry.save) or "-",
            category    = category or "-",
            chain_ok    = (category and ALLY_CHAIN_BY_CATEGORY[category] and "y") or "n",
            ally_toggle = (state.menu and state.menu.ally_save and state.menu.ally_save:Get() and "y") or "n",
            dedup_hit   = dedup_hit and "y" or "n",
        })
        -- v0.5.2 A.1: ally branch gate fix. Previously required
        -- `entry and entry.save and entry.save ~= "informational"` - but
        -- THREATS_ON_SELF is the SELF-defense catalog and is missing serious
        -- threats that are caught by the anim path on Lina (e.g. Lion Finger of
        -- Death lives in ANIM_SAVE_OVERRIDES, not THREATS_ON_SELF). The ally
        -- branch can't piggyback on the anim path, so requiring the SELF entry
        -- silently dropped every serious threat that lands on an ally. Diagnosed
        -- via v0.5.1 `ally_branch_consider` (Lion Finger on CM: category=
        -- targeted_burst chain_ok=y entry_ok=n -> drop). Fix: drop the entry
        -- requirement. `category and ALLY_CHAIN_BY_CATEGORY[category]` already
        -- filters to known-serious chains (close_gap / physical_chase / lockdown
        -- / targeted_burst / channel_on_self / drain); reactive / aura mods stay
        -- skipped because they have no ally chain.
        if category and ALLY_CHAIN_BY_CATEGORY[category] and not dedup_hit then
            if try_save_ally(npc, mod_name, Modifier.GetCaster(modifier)) then
                Dedup.threat_mark_responded(state.responded_threats, npc, mod_name)
            end
        end
    end
end

-- v0.5.39 BUG-2: Lotus-defer arming helper. When a lotus-worthy ult lands
-- and Lotus is on cooldown but coming up SOON (within the cast-point window),
-- arm a deferred entry in state.armed_threats so the regular chain dispatch
-- skips this frame and armed_threats_tick fires Lotus the moment it becomes
-- ready (still inside the projectile travel window). Avoids burning BKB / WW
-- on a hit Lotus could have reflected ~0.3s later. Returns true when the
-- threat was armed for deferral (caller must short-circuit normal dispatch);
-- returns false to let the normal lotus-first / chain path run unchanged.
--
-- Defer window is min(threat cast point - 0.3s, 1.2s) computed at arm time
-- per user-approved Q3. CAST_POINT_THREATS is BUG-3's module-local catalog
-- (entry shape: { ability, cp_default, category, max_dist }); we read
-- cp_entry.cp_default for the cast point fallback.
-- armed_threats key prefix "lotus_pending:" is sibling to BUG-3's "castpt:*";
-- independent keyspaces, no collision.
K.LOTUS_DEFER_WINDOW_S = 1.2
local function lotus_defer_if_close(threat_mod, threat_caster)
    if not state.self_npc then return false end
    local lotus_item = NPCLib.item(state.self_npc, "item_lotus_orb")
    if not lotus_item then return false end
    if NPCLib.item_ready(state.self_npc, "item_lotus_orb") then
        return false  -- normal Lotus-first path will fire it this frame
    end
    local cd_remaining = (Ability.GetCooldown and Ability.GetCooldown(lotus_item)) or 999
    -- Q3 effective window: min(cp_default - 0.3s, 1.2s). CAST_POINT_THREATS is
    -- BUG-3's module-local; absent entry falls through to K.LOTUS_DEFER_WINDOW_S
    -- default for modifiers not in the cp catalog.
    local cp_entry = CAST_POINT_THREATS[threat_mod]
    local cp = cp_entry and cp_entry.cp_default or nil
    local cp_window = (cp and (cp - 0.3)) or K.LOTUS_DEFER_WINDOW_S
    local effective_window = math.min(cp_window, K.LOTUS_DEFER_WINDOW_S)
    if effective_window <= 0 then return false end
    if cd_remaining > effective_window then return false end
    local caster_idx = (threat_caster and Entity.GetIndex and Entity.GetIndex(threat_caster)) or 0
    local key = "lotus_pending:" .. threat_mod .. ":" .. caster_idx
    if state.armed_threats[key] then return true end
    local arm_t = now()
    state.armed_threats[key] = {
        caster        = threat_caster,
        threat_mod    = threat_mod,
        arm_t         = arm_t,
        deadline_t    = arm_t + cd_remaining + 0.10,
        lotus_pending = true,
        fired         = false,
    }
    tlog(1, "lotus_defer_armed", { mod = threat_mod,
        cd = string.format("%.2f", cd_remaining),
        win = string.format("%.2f", effective_window),
        deadline = string.format("%.2f", cd_remaining + 0.10) })
    return true
end

local function handle_lotus_first(npc, modifier, mod_name, is_self)
    -- Lotus-worthy incoming single-target ult: Lotus reflect first.
    if not (is_self and LOTUS_WORTHY_INCOMING and LOTUS_WORTHY_INCOMING[mod_name]) then
        return false
    end
    -- v0.5.19 dedup + v0.5.22/.23 toggle handling.
    -- Resolve the caster once for dedup + downstream calls.
    local caster_lw = Modifier.GetCaster(modifier)
    -- v0.5.39 BUG-3: cast-point arming for the LOTUS_WORTHY intersection
    -- (modifier_lina_laguna_blade, modifier_lion_finger_of_death). Runs
    -- BEFORE the lotus-first dispatch so the save fires at end-of-cast
    -- via the chain-head SAVE_ETA_TRIGGER rather than snap-firing Lotus
    -- at modifier-create. Lotus is still in the chain (LINA_SAVE_OVERRIDES
    -- targeted_burst chain leads with item_lotus_orb); the arming branch
    -- just gates WHEN the save fires. lina_laguna_blade self-mirror skip:
    -- if the caster is OUR Lina (Rubick spell-steal mirror, Morphling
    -- adaptive-strike echo), no save makes sense - our own cast resolved
    -- already. Fall through to the legacy lotus_first path in that case.
    local cp_entry_lw = CAST_POINT_THREATS[mod_name]
    local laguna_self_mirror = (mod_name == "modifier_lina_laguna_blade"
                                and caster_lw == state.self_npc)
    if cp_entry_lw and not laguna_self_mirror
       and caster_lw and Entity.IsEntity(caster_lw) then
        local caster_idx = Entity.GetIndex(caster_lw)
        local arm_key = "castpt:" .. mod_name .. ":" .. tostring(caster_idx)
        if not state.armed_threats[arm_key] then
            local cp_eff = resolve_live_cast_point(caster_lw, cp_entry_lw.ability,
                                                   cp_entry_lw.cp_default)
            state.armed_threats[arm_key] = {
                caster = caster_lw, threat_mod = mod_name,
                ability = cp_entry_lw.ability,
                cast_point = cp_eff,
                arm_t = now(),
                max_dist = cp_entry_lw.max_dist,
                category = cp_entry_lw.category,
                cast_point_threat = true, fired = false,
            }
            tlog(1, "cast_point_threat_armed", { mod = mod_name,
                caster = uname(caster_lw), cp = string.format("%.2f", cp_eff),
                cat = cp_entry_lw.category, path = "modcreate_lotus_first" })
            state.modcreate_counter = state.modcreate_counter + 1
        end
        -- v0.5.25 RPR-03 pattern: defer dedup stamp to armed_post_fire.
        return true
    end
    -- v0.5.19 cross-path dual-fire fix: bail if the anim path already
    -- responded (e.g. on_hard_disable fired hard_disable_lion_finger_of_death
    -- ~0.4s ago and stamped the dedup). Stays in place regardless of toggle.
    if caster_lw and Dedup.threat_already_responded(state.responded_threats, caster_lw, mod_name) then
        tlog(3, "lotus_worthy_dedup_skip", { mod = mod_name })
        return true
    end
    -- v0.5.39 BUG-2: defer-arm Lotus if it is on CD but coming back soon (inside
    -- the threat cast-point window). Returning true here signals the dispatcher
    -- to stop; the armed_threats_tick lotus_pending branch will fire Lotus the
    -- moment it readies and stamp dedup then. Note: BUG-3's CAST_POINT_THREATS
    -- arming runs BEFORE the dedup check above; for LOTUS_WORTHY ∩ CAST_POINT
    -- intersection (Laguna, Finger) BUG-3 wins and this branch is unreachable -
    -- intentional, castpt arming gives a more precise fire moment.
    if lotus_defer_if_close(mod_name, caster_lw) then
        return true
    end
    local lotus_first_enabled = not (state.menu and state.menu.enable_lotus_first
                                     and not state.menu.enable_lotus_first:Get())
    if lotus_first_enabled then
        tlog(1, "incoming_lotus_worthy_ult", { mod = mod_name })
        state.modcreate_counter = state.modcreate_counter + 1
        -- v0.5.23 (COR-01): pass threat_mod + caster + nil ability_name so
        -- ResolveSaveOrder consults LINA_SAVE_OVERRIDES on the Lotus-fallback
        -- path. Previously called with one argument; threat_mod/caster
        -- arrived nil and the dispatcher collapsed to CH.DEFAULT_SAVE_CHAIN,
        -- silently bypassing hero-tuned chains for Sniper Assassinate, Lina R.
        -- v0.5.25 RPR-03: stamp AFTER try_save_lotus_first success so a
        -- chain bail (no Lotus + all chain items on CD) doesn't leave the
        -- threat dedup-locked for 2s. The entry-side check earlier in
        -- callbacks.OnModifierCreate (Dedup.threat_was_responded short-circuit) still prevents dual-fire vs the anim path.
        if try_save_lotus_first("lotus_worthy_" .. mod_name, mod_name, caster_lw, nil)
           and caster_lw then
            Dedup.threat_mark_responded(state.responded_threats, caster_lw, mod_name)
        end
        return true
    end
    -- v0.5.23 (RPR-02): when lotus_first is OFF, route directly to
    -- try_save_self with full args. The v0.5.22 "fall through to the
    -- standard path" turned out to be a no-op: LOTUS_WORTHY_INCOMING
    -- entries (modifier_lina_laguna_blade, modifier_lion_finger_of_death)
    -- are NOT in THREATS_ON_SELF or LINA_EXTRA_THREATS, so the standard
    -- catalogued-threat lookup (THREATS_ON_SELF[mod_name] in callbacks.OnModifierCreate) missed and no save fired at all.
    -- Route to try_save_self directly with the modifier name so the
    -- LINA_SAVE_OVERRIDES chain is consulted.
    -- v0.5.25 RPR-03: stamp dedup AFTER success so a chain bail does
    -- not leave the threat dedup-locked for 2s.
    tlog(2, "lotus_first_toggle_off_routing_to_chain", { mod = mod_name })
    if try_save_self("lotus_worthy_disabled_" .. mod_name, mod_name, caster_lw, nil, nil)
       and caster_lw then
        Dedup.threat_mark_responded(state.responded_threats, caster_lw, mod_name)
    end
    return true
end

local function handle_unrecognized_harvest(npc, modifier, mod_name, is_self)
    -- Harvest unrecognized self-threats so real names can be wired (lesson 111).
    -- v0.5.2: also skip threats in LINA_EXTRA_THREATS - those are wired
    -- hero-side and should not appear as "unrecognized" in the harvest.
    -- v0.5.59: also skip LINA_DEFER_TO_ARMED entries. Those modifiers ARE
    -- recognized; they just route to an armed_threats entry instead of
    -- firing a save chain on modifier-create. Without this exclusion the
    -- v0.5.55 demo logged threat_unrecognized for
    -- modifier_spirit_breaker_charge_of_darkness_vision on every Bara
    -- charge, even though LINA_DEFER_TO_ARMED already mapped it to
    -- bara_charge. Adding new defer entries now silences the harvest log
    -- automatically.
    if is_self and not (THREATS_ON_SELF and THREATS_ON_SELF[mod_name])
       and not LINA_EXTRA_THREATS[mod_name]
       and not LINA_DEFER_TO_ARMED[mod_name] then
        local caster = Modifier.GetCaster(modifier)
        if caster and Entity.IsEntity(caster) and Target.IsEnemyHero
           and Target.IsEnemyHero(caster, state.self_npc)
           and not Dedup.anim_throttled(state.anim_log_dedup, caster, mod_name) then
            tlog(1, "threat_unrecognized", { mod = mod_name, caster = uname(caster) })
        end
    end
end

local function handle_threat_on_self(npc, modifier, mod_name, is_self)
    -- Catalogued threat landed on Lina. v0.5.2: also consult LINA_EXTRA_THREATS
    -- so threats the lib does not cover (e.g. modifier_sniper_assassinate -
    -- log-captured as threat_unrecognized in v0.5.1) reach try_save_self.
    if not is_self then return false end
    -- v0.5.24 PERF-11: LINA_DEFER_TO_ARMED + LINA_INSTANT_DISABLE_MODS
    -- hoisted to module-level (near LINA_EXTRA_THREATS) so they are no
    -- longer reallocated on every self-modifier event.
    local armed_key = LINA_DEFER_TO_ARMED[mod_name]
    if armed_key and state.armed_threats[armed_key]
       and not state.armed_threats[armed_key].fired then
        local defer_caster = Modifier.GetCaster(modifier)
        Dedup.threat_mark_responded(state.responded_threats, defer_caster, mod_name)
        tlog(1, "threat_deferred_to_armed", { mod = mod_name, armed_key = armed_key })
        return true
    end
    -- v0.5.39 BUG-3: cast-point arming (modifier-create catch-up entry).
    -- The anim path (on_hard_disable) is the PRIMARY arming site; if anim
    -- missed or the threat has no anim mapping (e.g. Sniper Assassinate is
    -- not in ABILITY_TO_THREAT), the modifier-create entry still arms so
    -- armed_threats_tick can fire the save within the residual window.
    -- lina_laguna_blade self-mirror skip mirrors handle_lotus_first's
    -- guard: if OUR Lina is the caster (Rubick mirror, etc.), no save
    -- makes sense - fall through so the legacy try_save_self path runs
    -- (which will no-op for self-cast via the dispatcher's own guards).
    local cp_entry_ts = CAST_POINT_THREATS[mod_name]
    local cp_caster = cp_entry_ts and Modifier.GetCaster(modifier) or nil
    local laguna_self_mirror_ts = (mod_name == "modifier_lina_laguna_blade"
                                   and cp_caster == state.self_npc)
    if cp_entry_ts and not laguna_self_mirror_ts
       and cp_caster and Entity.IsEntity(cp_caster) then
        local caster_idx = Entity.GetIndex(cp_caster)
        local arm_key2 = "castpt:" .. mod_name .. ":" .. tostring(caster_idx)
        if not state.armed_threats[arm_key2] then
            local cp_eff = resolve_live_cast_point(cp_caster, cp_entry_ts.ability,
                                                   cp_entry_ts.cp_default)
            state.armed_threats[arm_key2] = {
                caster = cp_caster, threat_mod = mod_name,
                ability = cp_entry_ts.ability,
                cast_point = cp_eff,
                arm_t = now(),
                max_dist = cp_entry_ts.max_dist,
                category = cp_entry_ts.category,
                cast_point_threat = true, fired = false,
            }
            tlog(1, "cast_point_threat_armed", { mod = mod_name,
                caster = uname(cp_caster), cp = string.format("%.2f", cp_eff),
                cat = cp_entry_ts.category, path = "modcreate_threat_on_self" })
            state.modcreate_counter = state.modcreate_counter + 1
        end
        -- v0.5.25 RPR-03 pattern: defer dedup stamp to armed_post_fire.
        return true
    end
    if LINA_INSTANT_DISABLE_MODS[mod_name] then
        tlog(2, "instant_disable_ack", { mod = mod_name })
    end
    local entry = (THREATS_ON_SELF and THREATS_ON_SELF[mod_name])
                  or LINA_EXTRA_THREATS[mod_name]
    if entry then
        tlog(1, "threat_on_self", { mod = mod_name, role = entry.role, save = entry.save })
        state.modcreate_counter = state.modcreate_counter + 1
        local caster = Modifier.GetCaster(modifier)
        if Dedup.threat_already_responded(state.responded_threats, caster, mod_name) then
            tlog(3, "threat_response_dedup", { mod = mod_name })
            return true
        end
        -- v0.5.25 RPR-03: split the stamp by save type.
        -- - Informational entries (kiting slows, Berserkers Call taunt,
        --   Phoenix Sun Ray, etc. - see lib/threat_data.lua) don't
        --   dispatch a save; stamp at entry to suppress re-emit on
        --   modifier reapply within THREAT_WINDOW.
        -- - Real save entries: stamp ONLY after try_save_self success,
        --   so a bail (no chain item ready, future per-mod denylist
        --   guards) doesn't leave the threat dedup-locked for 2s.
        if entry.save and entry.save ~= "informational" then
            -- v0.5.40 A3-8 (+v0.5.41 DEDUP-CLEANUP): route legacy modifier-
            -- create fall-through through Dispatch. category_hint and
            -- ability_name nil -- ResolveSaveOrder derives the category
            -- from threat_mod via TD.CategoryOf, matching the v0.5.39
            -- try_save_self("threat_..", mod_name, caster) shape exactly.
            -- Closes the Sniper Assassinate + 'D' second-save double-fire
            -- from the v0.5.39 demo: this site and the lotus_pending /
            -- castpt arming sites share the per-(self_npc, canonical_mod,
            -- sniper) lock key. v0.5.41: Dispatcher lock is sole gate;
            -- belt-and-suspenders Dedup post-stamp removed. The else-
            -- branch below (informational threats) KEEPS its stamp -- it
            -- doesn't dispatch, so the stamp is its only dedup.
            defense_dispatcher:Dispatch("threat_" .. mod_name,
                                        mod_name, caster,
                                        state.self_npc, nil,
                                        nil, nil, nil,
                                        record_save,
                                        { fs_shard_window = fs_shard_window_active() })  -- v0.5.40 B2 GAP-3
        else
            Dedup.threat_mark_responded(state.responded_threats, caster, mod_name)
        end
    end
    return true
end

function callbacks.OnModifierCreate(npc, modifier)
    if not state.self_npc or not modifier then return end
    local mod_name = Modifier.GetName(modifier)
    if not mod_name then return end
    local is_self = (npc == state.self_npc)

    handle_enemy_buff_threat(npc, modifier, mod_name)
    handle_caster_channel_interrupt(npc, modifier, mod_name)  -- v0.5.132.1
    handle_ally_channel_interrupt(npc, modifier, mod_name)    -- v0.5.133 Phase 2
    handle_modseen_accumulator(npc, modifier, mod_name, is_self)
    handle_ally_save(npc, modifier, mod_name, is_self)
    if handle_lotus_first(npc, modifier, mod_name, is_self) then return end
    handle_unrecognized_harvest(npc, modifier, mod_name, is_self)
    if handle_threat_on_self(npc, modifier, mod_name, is_self) then return end

    -- v0.5.135 close-gap redesign (Slice 2A): catalog-driven gap-closer arming,
    -- replacing the 3 hardcoded if/elseif arms. Behaviour-preserving for the
    -- validated trio (LINA_ARM_TUNED -> same keys / eta / armed_t / tlogs);
    -- extends to other travel gap-closers via TD.THREAT_ARRIVAL_TIMING in Slice
    -- 2B. FIRE happens near impact by proximity/eta in armed_threats_tick.
    state.try_arm_catalog_gap_closer(npc, mod_name)
end

-- v0.5.36 MAINT-07: removed empty OnUnitAnimation stub (E9 cleanup leftover
-- from v0.5.14). Framework dispatches to keys present on the callbacks table;
-- absent keys are simply not invoked.
--
-- v0.5.42: OnModifierDestroy RESTORED (v0.5.36 MAINT-07 had deleted it as
-- empty stub; never replaced when the homing-armed-entry pattern needed it).
-- Clears bara_charge / tusk_snowball armed entries when the homing modifier
-- is destroyed without armed_post_fire firing (bug-hunt finding: stale
-- entries persist on a still-alive caster and wrongly fire WW/Pike on a
-- later same-caster walkup within 480u for Bara / 600u for Tusk, since the
-- arm-site guards at L6675/L6688 refuse to overwrite a same-caster entry).
-- Mirrors Sniper.lua L9644-9658.
function callbacks.OnModifierDestroy(npc, modifier)
    if not state.self_npc or not modifier then return end
    local mod_name = Modifier.GetName(modifier)
    if not mod_name then return end
    -- v0.5.99: nothing to clear if no threats are armed (the common case) -- skip
    -- the lookups/sweep on this high-frequency event.
    if not next(state.armed_threats) then return end
    if mod_name == "modifier_spirit_breaker_charge_of_darkness" then
        if state.armed_threats["bara_charge"] then
            tlog(2, "bara_charge_cleared", { caster = uname(npc) })
            state.armed_threats["bara_charge"] = nil
        end
        return
    elseif mod_name == "modifier_tusk_snowball_movement" then
        if state.armed_threats["tusk_snowball"] then
            tlog(2, "tusk_snowball_cleared", { caster = uname(npc) })
            state.armed_threats["tusk_snowball"] = nil
        end
        return
    end
    -- v0.5.99 lead-(c) fix: generic sweep. The bara/tusk cases above are fixed-key
    -- entries; the OTHER armed rows (channel / castpt:* / lotus_pending:* /
    -- instant_blink:*) carry their threat_mod, so when THAT modifier is destroyed on
    -- its own caster the threat is definitively gone -> drop the row so it cannot
    -- fire a wasted save. Zero-risk (only drops a row whose own threat_mod was just
    -- destroyed on its own caster). Catches channel-interrupt cleanly (Death Ward /
    -- Black Hole stunned). NOTE: the cast-point-CANCEL sub-case is NOT caught here --
    -- a castpt row is keyed on the RESULT debuff, which never exists during the cast,
    -- so there is no matching destroy event. A fire-time liveness check was rejected
    -- (false-skipping a legit save >> wasting one); that residual is accepted.
    for key, entry in pairs(state.armed_threats) do
        if entry and not entry.fired and entry.threat_mod == mod_name
           and entry.caster == npc then
            tlog(2, "armed_threat_cleared_on_destroy", { key = key, mod = mod_name })
            state.armed_threats[key] = nil
        end
    end
end

-- v0.5.147 lib-first lift: the line-projectile intercept CATALOG + geometry +
-- dispatch moved to the shared lib (general item-saves live in lib; only
-- ability injection is hero-local). Catalog = TD.LINE_PROJECTILE_INTERCEPTS
-- (lib/threat_data.lua); mechanism = defense_dispatcher:HandleLineProjectile
-- (lib/defense.lua). The thin OnLinearProjectileCreate below only wires Lina's
-- glue (menu toggle, dedup state, record_save, fs_shard_window) into the lib
-- call. See changelog v0.5.146 (Clockwerk Hookshot added) + v0.5.147 (the lift).

function callbacks.OnLinearProjectileCreate(data)
    -- v0.5.147: thin wrapper over the lib mechanism (Dispatcher:HandleLineProjectile).
    -- Behaviour-identical to the former hero-local port -- same gates, same tlog
    -- stream (projectile_skip / line_projectile_seen / _skip / _intercepted), same
    -- Dispatch("line_intercept_<ability>", ..., "line_projectile", ...). Engine
    -- globals (Entity/NPC) run lib-side; Target/NPCLib (project libs not in the
    -- lib's scope) + Lina state/menu come through these opts closures. opts are
    -- built per-event (OnLinearProjectileCreate is rare, not per-frame).
    defense_dispatcher:HandleLineProjectile(data, {
        me              = state.self_npc,
        catalog         = TD.LINE_PROJECTILE_INTERCEPTS,
        tlog3           = TLOG3_ENABLED,
        enabled         = defense_enabled,
        subsystem_on    = function()
            return not (state.menu and state.menu.enable_line_intercept
                        and not state.menu.enable_line_intercept:Get())
        end,
        origin          = NPCLib.origin,
        uname           = uname,
        is_enemy_hero   = function(src, me) return Target.IsEnemyHero and Target.IsEnemyHero(src, me) end,
        dedup_responded = function(src, mod) return Dedup.threat_already_responded(state.responded_threats, src, mod) end,
        dedup_mark      = function(src, mod) Dedup.threat_mark_responded(state.responded_threats, src, mod) end,
        record_save     = record_save,
        fs_shard_window = fs_shard_window_active,
    })
end

-- v0.5.13 PM-1: Re-host the PE-05 postmortem on OnNpcDying because
-- OnEntityKilled is unsafe-mode-only per UCZone v2 callbacks.md:121-125, which
-- made the v0.5.11 path structurally unreachable for the user's standard-mode
-- runs (explains the T6 ambiguity and zero death_postmortem lines in the
-- v0.5.12 debug.log). OnNpcDying has no unsafe-mode hint (callbacks.md:619)
-- and fires for every npc death in standard mode. We keep OnEntityKilled
-- in place for two reasons:
--   (a) Its non-self branch (armed/responded GC) is fine to run in unsafe
--       mode -- it just doesn't fire at all in standard mode (acceptable;
--       the prefix-indexed maps are bounded by recycled-idx churn).
--   (b) If unsafe mode IS on, OnEntityKilled has `data.source` and
--       `data.ability`, which OnNpcDying does NOT expose -- so we let the
--       OnEntityKilled path log the richer postmortem when available and
--       use a `state.last_postmortem_t` dedup stamp to prevent double-logging
--       when both callbacks fire for the same death.
function callbacks.OnNpcDying(npc)
    -- v0.5.156.4 combo-to-kill timer: when an enemy hero dies while a combo timer is
    -- armed (stamped on combo-press in combo_key_tick), log the REAL elapsed time
    -- combo-press -> death, so the TTK model can be validated against the stopwatch.
    -- Enemy-hero only (skip creeps/illusions); 20s staleness guard; clears on log.
    if state.combo_timer_t0 and npc and npc ~= state.self_npc
       and Target.IsEnemyHero and Target.IsEnemyHero(npc, state.self_npc) then
        local secs = now() - state.combo_timer_t0
        if secs >= 0 and secs < 20 then
            tlog(1, "combo_kill_time", {
                target   = uname(npc),
                secs     = string.format("%.2f", secs),
                fc_start = state.combo_timer_fc_start and "y" or "n",
                fc_now   = (state.lina_fc_active and state.lina_fc_active()) and "y" or "n",
            })
        end
        state.combo_timer_t0 = nil
    end
    -- v0.5.13 PM-1: standard-mode-reachable postmortem. `npc` is the dying
    -- entity (NPC handle). The host does not pass a `data.source` or
    -- `data.ability` here, so killer / killer_ability degrade to the
    -- threat we last saved against (state.last_save_threat_mod, populated
    -- by record_save). This is strictly less precise
    -- than the OnEntityKilled variant but is the only feedback signal the
    -- standard-mode host actually delivers.
    if npc ~= state.self_npc then return end
    local since_save = state.last_save_t and (now() - state.last_save_t) or 999
    if since_save >= 2.0 then return end
    -- Dedup vs the OnEntityKilled branch below (unsafe mode delivers both).
    local last_pm = state.last_postmortem_t or 0
    if (now() - last_pm) < 0.5 then return end
    state.last_postmortem_t = now()
    tlog(1, "death_postmortem", {
        last_save      = state.last_save_intent or "-",
        save_kind      = state.last_save_kind or "-",
        threat_mod     = state.last_save_threat_mod or "-",
        since_save     = string.format("%.2f", since_save),
        killer         = "-",  -- OnNpcDying lacks data.source (degradation vs OnEntityKilled)
        killer_ability = "-",  -- OnNpcDying lacks data.ability (degradation vs OnEntityKilled)
        save_hp        = state.last_save_hp     and string.format("%d", state.last_save_hp)     or "-",
        save_hp_max    = state.last_save_hp_max and string.format("%d", state.last_save_hp_max) or "-",
        hp_nadir       = state.hp_nadir         and string.format("%d", state.hp_nadir)         or "-",
        src            = "OnNpcDying",
    })
end

function callbacks.OnEntityKilled(data)
    -- v0.5.11 PE-05 (port of Sniper v6.15 C1 + v6.15.2 C3 + v6.14.1 low):
    -- close the tuning feedback loop and GC stale defense state on death.
    --   1. If Lina dies within 2.0s of a self-save fire, dump a postmortem
    --      log (last save intent / kind / threat_mod, since_save, killer,
    --      killer's ability) so the user can see "fired X, died to Y" and
    --      catch kind-mismatch / under-rated severity / geometry bugs.
    --   2. For any other dead entity, GC state.armed_threats entries whose
    --      .caster matches and state.responded_threats keys prefixed with
    --      "<idx>:" -- prevents stale armed/responded rows from blocking a
    --      legitimate re-arm if the same caster index gets recycled (or
    --      simply leaking memory across long matches).
    -- Sniper-only bookkeeping (candidates, fog_cache, last_r_target) is
    -- intentionally NOT ported -- Lina has no such structures.
    -- v0.5.13 PM-1 caveat: per UCZone v2 callbacks.md:121-125 this entire
    -- callback is unsafe-mode-only, so in standard mode neither the
    -- postmortem branch nor the GC sweep runs. The postmortem path has
    -- been mirrored on OnNpcDying above (with degraded killer info).
    if not data or not data.target then return end

    if data.target == state.self_npc then
        local since_save = state.last_save_t and (now() - state.last_save_t) or 999
        if since_save < 2.0 then
            -- v0.5.13 PM-1: skip if OnNpcDying already logged within 0.5s.
            local last_pm = state.last_postmortem_t or 0
            if (now() - last_pm) < 0.5 then
                return  -- our own death; OnNpcDying handled the postmortem
            end
            state.last_postmortem_t = now()
            -- v6.15.2 C3 lesson: OnEntityKilled exposes `data.ability` as a
            -- CAbility handle, not `data.ability_name`. Resolve via Ability.GetName.
            local killer_ab_name = "-"
            if data.ability then
                killer_ab_name = (Ability.GetName and Ability.GetName(data.ability))
                                 or tostring(data.ability)
            end
            tlog(1, "death_postmortem", {
                last_save      = state.last_save_intent or "-",
                save_kind      = state.last_save_kind or "-",
                threat_mod     = state.last_save_threat_mod or "-",
                since_save     = string.format("%.2f", since_save),
                killer         = data.source and uname(data.source) or "-",
                killer_ability = killer_ab_name,
                save_hp        = state.last_save_hp     and string.format("%d", state.last_save_hp)     or "-",
                save_hp_max    = state.last_save_hp_max and string.format("%d", state.last_save_hp_max) or "-",
                hp_nadir       = state.hp_nadir         and string.format("%d", state.hp_nadir)         or "-",
                src            = "OnEntityKilled",
            })
        end
        return  -- our own death; no other GC work
    end

    -- v0.5.11: GC armed/responded entries keyed on the dead entity so a
    -- recycled entity_idx (or a fresh Hook/Charge from a respawned caster)
    -- can't be silently blocked by a stale "already responded" stamp.
    local idx = Entity.GetIndex(data.target)
    if idx then
        local prefix = tostring(idx) .. ":"
        for k in pairs(state.responded_threats) do
            if k:sub(1, #prefix) == prefix then
                state.responded_threats[k] = nil
            end
        end
    end
    for k, entry in pairs(state.armed_threats) do
        if entry.caster == data.target then state.armed_threats[k] = nil end
    end
end
-- v0.5.36 MAINT-07: removed empty OnKeyEvent / OnSetDormant stubs (E9
-- cleanup leftovers from v0.5.14); see matching note above the PE-02 block.

----------------------------------------------------------------- wiring -----
Order.Init()
Damage.Init()
Anim.Init()

setup_menu()
register_anim_maps()

-- Register Lina's brain API for cross-hero coordination (expanded in Phase F).
Signal.Register("Lina", {
    last_save_intent = function() return state.last_save_intent end,
})

Order.Wire(callbacks)
Damage.Wire(callbacks)
Anim.Wire(callbacks)

-- Hero gate: UCZone loads every scripts/*.lua for every match regardless of
-- the picked hero (no framework auto-gate). Without this, Lina's brain would
-- run on whoever the player picked and fire Lina spells on the wrong hero.
-- Wrap every callback (brain + lib-chained) so it no-ops on non-Lina heroes.
-- Must exist from v0.1.0 (HERO_PROMPT lesson 1).
state.is_our_hero = function()
    local h = Heroes.GetLocal()
    if not h or not Entity.IsEntity(h) or not Entity.IsNPC(h) then return false end
    return NPC.GetUnitName(h) == "npc_dota_hero_" .. HERO_KEY
end
for cb_name, cb_fn in pairs(callbacks) do
    callbacks[cb_name] = function(...)
        if not state.is_our_hero() then return end
        return cb_fn(...)
    end
end

LOG:info("Lina brain v0.5.180 (gank-band tuning: the proactive defensive FC HP gate FC_DEF_PROACTIVE_HP lowered 0.50 -> 0.35, so the multi-enemy focus band pre-fires FC only when Lina HP fraction is below 0.35 (was 0.50, too eager mid-gank). Single knob; the reactive armed-threat FC path is unchanged. FCDEF04 band cases moved to 0.30 HP + a 0.40-holds guard added (in-brain test, verify via the test key). Offline 452/452, coverage 48/48, luac 5/5. Full history in changelog.md.)")

return callbacks
