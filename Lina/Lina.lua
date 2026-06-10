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
-- v0.5.28 task-9 (IMP-A10 NPC.GetMagicalResist diagnostic): one-shot guard.
-- Populated by the IMP-A10 gate to emit a single `imp_a10_mr_probe` tlog per
-- session (NOT per target). Captures the raw API return (type + value) +
-- decision context so the user can verify the actual contract on this
-- Umbrella build and decide the v0.5.29 fix (correct API name / threshold
-- bump / fallback-on-zero handling).
-- v0.5.39 P1-IMP-A10-ONCE: collapsed from per-target table to one-shot bool;
-- the API contract is uniform across targets so one probe per session suffices.
state.imp_a10_probed_once = false
-- v0.5.29 task-6-A diag: throttle cursor for the tf_r_value_pick summary
-- tlog. Set to now() each time a picked-target summary fires; gated to ~1Hz
-- to keep default-verbosity log clean during sustained combo holds.
state.tf_r_pick_diag_t = 0
state.last_preface_t       = 0    -- pre_face_tick cooldown cursor (E12 deviation)
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
    "item_black_king_bar", "item_aeon_disk",
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
    "item_cyclone", "item_force_staff", "item_hurricane_pike",
    "lina_w_anti_gap",  -- v0.5.44 (DEFENSE_PLAN.md sec 2.1 + Q1): tail position; W fires only when all items above are on CD. High-viability targets: Bara Charge, Bara Nether Strike, Tusk Snowball, MK Primal Spring.
}
local LINA_SAVE_OVERRIDES = {}
for _, m in ipairs({
    "modifier_phantom_assassin_phantom_strike",
    "modifier_phantom_assassin_phantom_strike_target",  -- v0.2.2: the ACTUAL modifier that lands (log-confirmed)
    "modifier_spirit_breaker_charge_of_darkness",
    "modifier_slark_pounce",
    "modifier_tusk_snowball_movement",
    "modifier_queenofpain_blink",
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
    "slark_pounce",
    "tusk_snowball",
    "queenofpain_blink",
}) do
    state.ANIM_SAVE_OVERRIDES[ab] = CH.GAP_CLOSE_SAVES
end

-- v0.5.2: authoritative save chain for Sniper Assassinate (user note
-- 2026-05-29 + DEMO 3 data). Single-target magical ult; Ethereal-self is
-- DELIBERATELY ABSENT (it amplifies magical damage taken by +40%). The Lotus
-- HP gate (v0.5.2 C) bypasses lotus-worthy threats.
--
-- v0.5.39 BUG-2: chain reordered for the Lotus-defer punishment intent.
-- Lotus heads the chain (reflect = punishment-intent payoff); BKB second as
-- the magic-immune fallback when Lotus is unavailable; cheap displacement
-- (Force / Pike) third so Lina exits the projectile lock cone when Lotus and
-- BKB are both on CD; WW as the heavy displacement backstop (longer CD,
-- saved for cases where Force/Pike refuse via K.SAVE_FIRE_DISTANCE_SELF_PUSH_FLOOR);
-- Glimmer (40% MR) next, then Aeon Disk (lethal-damage block backstop) and
-- Flame Cloak (35% MR + spell amp) as deep MR tails. The lotus_defer_if_close
-- gate (grep `local function lotus_defer_if_close`) only commits to this chain
-- after the cooldown-deferral window closes, so the head Lotus slot fires
-- whenever the deferred-fire path armed under the assassinate cast point.
LINA_SAVE_OVERRIDES["modifier_sniper_assassinate"] = {
    "item_lotus_orb",
    "item_black_king_bar",
    "item_force_staff",
    "item_hurricane_pike",
    "item_wind_waker",
    "item_glimmer_cape",
    "item_aeon_disk",
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
    -- Force > Pike-self > Manta > WW (user spec). Pugna Life Drain tether
    -- 1100u (lib/threat_data line 335; Sniper noted 1300u, take the lib value).
    -- Force/Pike push 600/425u -- alone insufficient vs 1100u, but Pugna typically
    -- channels from inside that range. SaveCounters knows displacement_far /
    -- displacement_blink work; authoritative bypass skips that gate anyway so
    -- Lina commits to displacement-first per user directive. Manta as status
    -- dispel pops the channel link; WW as the heavy backstop.
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
    "item_aeon_disk",
}
CH.DISRUPTOR_KFR    = {
    -- WW > Eul > Force > Pike-self (user spec). Sniper v6.15.10 / v6.15.247
    -- empirically showed that displacement-over-time (Pike / Force sliding push)
    -- is INTERCEPTED by the Kinetic Field wall -- only instant impulse motions
    -- cross. Lina lacks Sniper's grenade, but WW (2.5s airborne + invuln + 2.5s
    -- cyclone duration outlasts KFR's 2.6s) and Eul (same airborne, 2.5s) BOTH
    -- carry Lina UP and over the wall via the airborne dispel-and-relocate
    -- mechanic. Force/Pike kept as last-ditch -- they often fail vs the wall
    -- but firing-and-failing is better than no_effective_save when WW/Eul are
    -- on CD. Authoritative bypass keeps the chain from being culled by the
    -- displacement_perp SaveCounters filter (lib/threat_data line 268).
    "item_wind_waker",
    "item_cyclone",
    "item_force_staff",
    "item_hurricane_pike",
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
    "item_aeon_disk",        -- lethal-block during Chrono; last resort
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
    "item_aeon_disk",        -- lethal-block fallback
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
LINA_SAVE_OVERRIDES["modifier_bane_fiends_grip"]                = CH.BANE_GRIP
LINA_SAVE_OVERRIDES["modifier_pugna_life_drain"]                = CH.PUGNA_DRAIN
LINA_SAVE_OVERRIDES["modifier_legion_commander_duel"]           = CH.LEGION_DUEL
LINA_SAVE_OVERRIDES["modifier_disruptor_kinetic_field_remnant"] = CH.DISRUPTOR_KFR
LINA_SAVE_OVERRIDES["modifier_witch_doctor_death_ward"]         = CH.WD_DEATH_WARD  -- v0.5.47
LINA_SAVE_OVERRIDES["modifier_abyssal_underlord_pit_of_malice_ensare"] = CH.UNDERLORD_PIT  -- v0.5.47
-- v0.5.71 Phase 4 slice 6 high-impact ult overrides:
LINA_SAVE_OVERRIDES["modifier_doom_bringer_doom"]                = CH.DOOM
LINA_SAVE_OVERRIDES["modifier_magnataur_reverse_polarity_stun"]  = CH.MAGNUS_RP
LINA_SAVE_OVERRIDES["modifier_faceless_void_chronosphere"]       = CH.FV_CHRONO
LINA_SAVE_OVERRIDES["modifier_enigma_black_hole"]                = CH.ENIGMA_BH
LINA_SAVE_OVERRIDES["modifier_beastmaster_primal_roar"]          = CH.BEASTMASTER_PR  -- v0.5.73: canonical name (was _stun in v0.5.71)
LINA_SAVE_OVERRIDES["modifier_tidehunter_ravage"]                = CH.TIDE_RAVAGE

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
K.LINA_ATTACK_ENGAGE_RADIUS      = 700  -- Sniper ATTACK_ENGAGE_RADIUS parity; covers Lina's 670 attack range
K.LINA_COMMITTED_ATTACKER_RETREAT_BUFFER = 200  -- attacker further than 700+200=900 = released

CH.COMMITTED_ATTACKER_SAVES = {
    "item_force_staff", "item_hurricane_pike", "item_wind_waker",
    "item_cyclone", "item_glimmer_cape", "lina_w_anti_gap",
}
LINA_SAVE_OVERRIDES["lina_committed_attacker"] = CH.COMMITTED_ATTACKER_SAVES

-- State table init (per-tick attacker latches + per-caster re-arm latches).
-- Declared here adjacent to the helpers so the file stays grep-coherent;
-- could be hoisted to the L175-230 state.* block if maintenance prefers.
state.attacking_seen_t              = state.attacking_seen_t or {}
state.committed_attacker_armed_t    = state.committed_attacker_armed_t or {}
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
    -- Future interruptible channels to consider:
    -- modifier_pugna_life_drain        (already has WW-first chain),
    -- modifier_shadow_shaman_shackles,
    -- modifier_enigma_black_hole_pull.
}

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
    local ok, list = pcall(Entity.GetHeroesInRadius, me,
                           K.LINA_ATTACK_ENGAGE_RADIUS, Enum.TeamType.TEAM_ENEMY)
    if not ok or type(list) ~= "table" then return end
    local t = now()
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
    if d > K.LINA_ATTACK_ENGAGE_RADIUS then return false end
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
    return (now() - seen) < K.LINA_COMMITTED_ATTACK_WINDOW_S
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
    local t = now()
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
    local ok, list = pcall(Entity.GetHeroesInRadius, me, K.LINA_ATTACK_ENGAGE_RADIUS,
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
    local diag_in700      = 0
    local diag_attacking  = 0
    local diag_kiting     = 0
    local diag_committed  = 0
    local diag_armed      = 0
    local diag_latched    = 0
    for i = 1, #list do
        local h = list[i]
        if h and Entity.IsEntity(h) and Target.IsAlive and Target.IsAlive(h) then
            diag_in700 = diag_in700 + 1
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
            if committed then
                local ok2, idx = pcall(Entity.GetIndex, h)
                if ok2 and idx then
                    local last_arm = state.committed_attacker_armed_t[idx] or 0
                    if (t - last_arm) >= K.LINA_COMMITTED_ATTACK_WINDOW_S then
                        diag_armed = diag_armed + 1
                        local d     = dist_to(h) or K.LINA_ATTACK_ENGAGE_RADIUS
                        local speed = (NPC.GetMoveSpeed and NPC.GetMoveSpeed(h)) or 300
                        state.committed_attacker_armed_t[idx] = t
                        tlog(1, "committed_attacker_armed", {
                            caster  = uname(h),
                            dist    = string.format("%.0f", d),
                            mvspeed = string.format("%.0f", speed),
                        })
                        local intent = "committed_attacker_" .. tostring(idx)
                        defense_dispatcher:Dispatch(
                            intent,                            -- intent
                            "lina_committed_attacker",         -- threat_mod (synthetic)
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
            in700     = tostring(diag_in700),
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
        prepend = { "item_wind_waker", "item_black_king_bar", "item_aeon_disk" },
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
}

-- Save-cast closures. Universal item self-casts plus the two Lina-specific
-- ones (Flame Cloak ability, Ethereal Blade self-cast). Aeon is passive
-- auto-trigger, so it has NO fire entry (the chain skips it; the brain only
-- logs the proc). Force/Pike self-push gate on safe_push_destination (E10).
local SAVE_FIRE = {
    item_wind_waker   = {
        short = "windwaker",
        -- v0.5.16 Group 4 guard + v0.5.20 instrumentation: log every closure
        -- invocation regardless of guard/fire outcome so we can correlate
        -- user-observed in-game saves against actual brain dispatch.
        -- v0.5.60 Phase 5 slice 3 / v0.5.62 fix: cast in place (WW lifts
        -- Lina airborne 3s untargetable), then arm the tick-driven
        -- state.pending_post_airborne_move which (a) pauses Native HR/OW
        -- so the baseline orbwalker cannot preempt and (b) issues the
        -- MOVE_TO_POSITION when the modifier_wind_waker clears. v0.5.60
        -- queue=true alone was preempted by USER-tagged baseline orders
        -- the moment cyclone ended (per v0.5.61 demo log L3254 etc.).
        fire  = function(intent, threat_caster)
            local guarded = NPC.HasModifier(state.self_npc, "modifier_wind_waker")
            tlog(1, "save_fire_invoked", { item = "item_wind_waker", intent = tostring(intent),
                guarded = guarded and "y" or "n" })
            if guarded then return false end
            local ok = issue_item_self(intent, "def", NPCLib.item(state.self_npc, "item_wind_waker"))
            if ok then
                -- v0.5.64: WW self-cast allows movement at fixed 300 MS
                -- during the 2.5s airborne (per Liquipedia: "they can
                -- move freely at a fixed speed, free pathing, ignores
                -- turn rates"). Pass moves_during_airborne=true so the
                -- tick reissues MOVE while the modifier is still active
                -- and Lina actually travels during the lift instead of
                -- walking the full distance afterward.
                state.queue_safe_post_move("ww", 600, threat_caster, "modifier_wind_waker", true)
            end
            return ok
        end,
    },
    item_cyclone      = {
        short = "eul",
        -- v0.5.65 (user spec: "IF EUL does not move while on air, do
        -- nothing"): EUL is a FULL disable per Liquipedia (STUNNED +
        -- INVULNERABLE + NO_HEALTH_BAR, "no horizontal movement is
        -- possible during the effect"). The brain cannot reposition
        -- Lina during airborne, and forcing a post-airborne walk in a
        -- direction Lina did not choose just fights the player's
        -- positioning intent. So EUL is pure cast-and-survive: fire
        -- the immunity, land in place, let the player / baseline
        -- orbwalker handle positioning afterward. Unlike WW (which CAN
        -- move at 300 MS during airborne and DOES call
        -- queue_safe_post_move), EUL just casts and returns.
        fire  = function(intent, threat_caster)
            local guarded = NPC.HasModifier(state.self_npc, "modifier_eul_cyclone")
            tlog(1, "save_fire_invoked", { item = "item_cyclone", intent = tostring(intent),
                guarded = guarded and "y" or "n" })
            if guarded then return false end
            return issue_item_self(intent, "def", NPCLib.item(state.self_npc, "item_cyclone"))
        end,
    },
    -- v0.5.2 C: HP gate on chain-walked Lotus. DEMO 3 showed 5x Lotus fires in
    -- one session against real reflectable threats but mostly low-impact
    -- (enemy Lina R at low level, Bara Nether Strike). 14s CD is too expensive
    -- for routine reflection. Rule: skip Lotus from the chain when Lina is
    -- healthy (HP > 0.85) AND the threat is not in LOTUS_WORTHY_INCOMING. The
    -- worthy path (try_save_lotus_first via OnModifierCreate) is unaffected -
    -- it has its own dispatch + the lib curates LOTUS_WORTHY_INCOMING for
    -- always-reflect targets (Lina R, Lion Finger, +v0.5.2 Sniper Assassinate).
    -- Returning false lets the chain fall through to BKB / WW / Glimmer / etc.
    item_lotus_orb    = {
        short           = "lotus",
        -- v0.5.55: prep_time / active_duration removed -- no consumer
        -- left after the chain-walker catalog gate was removed.
        fire  = function(intent, threat_caster, threat_mod)
            -- v0.5.21 IMP-A8: HP-fraction gate replaced with expected-damage
            -- gate keyed on threat_mod (full modifier_* name; matches the
            -- canonical key namespace used everywhere else in this file).
            -- FIRE Lotus when expected damage >= 30% of current HP OR when
            -- the threat is LOTUS_WORTHY_INCOMING. SKIP Lotus when expected
            -- damage is below the 30% threshold (low-impact threat not worth
            -- the 14s Lotus CD). If threat_mod is absent from LINA_EXPECTED_DAMAGE
            -- we fall back to the original 0.85 HP-fraction gate so unknown
            -- threats keep current behaviour (no regression).
            local me = state.self_npc
            local hp    = (me and Entity.GetHealth    and Entity.GetHealth(me))    or 0
            local hpmax = (me and Entity.GetMaxHealth and Entity.GetMaxHealth(me)) or 1
            local hp_frac = (hpmax > 0) and (hp / hpmax) or 1
            local is_worthy = LOTUS_WORTHY_INCOMING and threat_mod
                              and LOTUS_WORTHY_INCOMING[threat_mod] or false
            local exp_dmg = threat_mod and LINA_EXPECTED_DAMAGE[threat_mod] or nil
            if exp_dmg ~= nil then
                local threshold = hp * 0.30
                if exp_dmg < threshold and not is_worthy then
                    tlog(3, "lotus_dmg_gate_skip", {
                        exp_dmg = tostring(exp_dmg),
                        hp = tostring(hp),
                        threshold = string.format("%.0f", threshold),
                        mod = threat_mod or "-",
                    })
                    return false
                end
            else
                -- v0.5.72 Phase 4 slice 7 (audit rec #5): severity-derived
                -- fallback when LINA_EXPECTED_DAMAGE has no entry for the
                -- threat. Maps TD.SeverityOf:
                --   "high"   -> ignore HP gate, fire (high-severity threats
                --               warrant Lotus regardless of HP)
                --   "low"    -> skip Lotus (low-severity not worth 14s CD)
                --   "medium" / unknown -> existing 0.85 HP fallback
                -- Auto-covers ~180 mods that have severity tier in the lib
                -- but aren't hand-listed in LINA_EXPECTED_DAMAGE (5 entries).
                local sev = (TD.SeverityOf and threat_mod) and TD.SeverityOf(threat_mod) or nil
                if sev == "high" then
                    tlog(3, "lotus_sev_gate_fire", { sev = "high", mod = threat_mod or "-" })
                    -- fall through to issue (fire)
                elseif sev == "low" then
                    tlog(3, "lotus_sev_gate_skip", {
                        sev = "low", mod = threat_mod or "-",
                    })
                    return false
                elseif hp_frac > 0.85 and not is_worthy then
                    tlog(3, "lotus_hp_gate_skip", {
                        hp_frac = string.format("%.2f", hp_frac),
                        mod = threat_mod or "-",
                        sev = sev or "-",
                    })
                    return false
                end
            end
            return issue_item_self(intent, "def", NPCLib.item(state.self_npc, "item_lotus_orb"))
        end,
    },
    item_glimmer_cape = {
        short = "glimmer",
        fire  = function(intent)
            local guarded = NPC.HasModifier(state.self_npc, "modifier_item_glimmer_cape_fade")
            tlog(1, "save_fire_invoked", { item = "item_glimmer_cape", intent = tostring(intent),
                guarded = guarded and "y" or "n" })
            if guarded then return false end
            return issue_item_self(intent, "def", NPCLib.item(state.self_npc, "item_glimmer_cape"))
        end,
    },
    item_manta        = { short = "manta",     fire = function(intent) return issue_item_no_target(intent, "def", NPCLib.item(state.self_npc, "item_manta")) end },
    item_black_king_bar = {
        short           = "bkb",
        -- v0.5.55: prep_time / active_duration removed -- no consumer
        -- left after the chain-walker catalog gate was removed.
        fire  = function(intent)
            local guarded = NPC.HasModifier(state.self_npc, "modifier_black_king_bar_immune")
            tlog(1, "save_fire_invoked", { item = "item_black_king_bar", intent = tostring(intent),
                guarded = guarded and "y" or "n" })
            if guarded then return false end
            return issue_item_no_target(intent, "def", NPCLib.item(state.self_npc, "item_black_king_bar"))
        end,
    },
    item_invis_sword  = { short = "shadowblade", fire = function(intent) return issue_item_no_target(intent, "def", NPCLib.item(state.self_npc, "item_invis_sword")) end },
    item_silver_edge  = { short = "silveredge",  fire = function(intent) return issue_item_no_target(intent, "def", NPCLib.item(state.self_npc, "item_silver_edge")) end },
    item_force_staff  = {
        short = "force",
        -- v0.5.58 Phase 5 slice 2: Force pushes 600u along Lina's CURRENT
        -- facing, same shape as Pike's self-cast. Route through the shared
        -- state.try_self_push harness: danger-aware destination pick via
        -- Escape.PickDir + two-phase turn-then-fire. The legacy gate-only
        -- state.safe_push_destination(threat_caster, 600) check is REPLACED
        -- by the helper (the helper does its own threat-distance + terrain
        -- + danger-aware ranking via Escape.SafePushDestination internally).
        fire  = function(intent, threat_caster)
            local it = NPCLib.item(state.self_npc, "item_force_staff"); if not it then return false end
            return state.try_self_push(intent, it, "item_force_staff", 600, threat_caster)
        end,
    },
    -- Pike used like Sniper (hero-agnostic convention): PRIMARY is enemy-target
    -- - cast on the threat caster, which pushes them + Lina apart radially,
    -- FACING-INDEPENDENT - a reliable defensive semi-blink. Self-cast (push in
    -- Lina's facing) is only a fallback when no enemy is in cast range, gated by
    -- safe_push_destination (lesson 61). This is the v0.2.3 fix for Pike
    -- self-refusing vs a faced melee attacker (fire_returned_false).
    item_hurricane_pike = {
        short           = "pike",
        -- v0.5.54: prep_time + active_duration REMOVED. Per user spec
        -- "AutoDisabler is a native script that is 100% verified and
        -- working ... Pike is a skill disable", Pike belongs to the
        -- framework AutoDisabler's Force Interrupt path. Brain stays
        -- out of AD's lane: no prep_time = neither v0.5.51 hero-side
        -- catalog gate nor v0.5.53 lib catalog gate triggers on Pike,
        -- and AD handles Pike's fire timing. The chain still passes
        -- through Pike (via legacy distance gate) as a fallback when
        -- AD hasn't / can't, but the v0.5.51 catalog double-fire
        -- pattern (brain catalog_eta_pike on top of AutoDisabler.lua
        -- casts) is gone. Glimmer / BKB / Lotus / WW / Eul / FC / W
        -- KEEP their prep_time -- they're brain-owned saves (dodges /
        -- escape / arrival-stun), not AD-owned disables.
        -- v0.5.11 PE-03 (Sniper S29 port): the engine silently drops the FIRST
        -- cast of a freshly-acquired item (Pike included) -- the order reaches
        -- ExecuteOrder, cooldown stays 0, and Lina's first real Pike save of the
        -- game is eaten without feedback. Two-part Pike-scoped work-around,
        -- mirroring Sniper Sniper.lua L5976-6028 / L6145-6152:
        --   PRIME : when Lina owns an un-primed Pike and is safe (no enemies
        --           within state.COMBO_CLASSIFY_RADIUS, no recent combo press),
        --           pike_prime_tick fires one throwaway Pike-on-self to spend
        --           the doomed first cast early.
        --   DOUBLE: if a real Pike save fires before Pike was primed, the fire
        --           closure stamps state.pike_reissue and pike_prime_tick
        --           re-issues Pike once the next frame -- the 2nd cast lands.
        -- state.pike_primed flips true ONLY on positive proof (cooldown > 0).
        -- v0.5.57 / v0.5.58 (Phase 5): enemy-target primary branch is
        -- unchanged (Pike-on-enemy pushes them apart radially, no facing
        -- dependency). The self-cast fallback routes through the shared
        -- state.try_self_push harness (v0.5.58 slice 2) which does a
        -- danger-aware Escape.PickDir + two-phase turn-then-fire so the
        -- 600u push along Lina's CURRENT facing lands in a safe spot.
        -- Mirrors Sniper.lua:5877 pike_self_reposition. v0.5.58 also wires
        -- Force Staff through the same helper.
        fire  = function(intent, threat_caster, threat_mod)
            local it = NPCLib.item(state.self_npc, "item_hurricane_pike"); if not it then return false end
            if threat_caster and Entity.IsEntity(threat_caster) and Target.IsAlive(threat_caster)
               and not (NPC.HasState and NPC.HasState(threat_caster, MS.MODIFIER_STATE_MAGIC_IMMUNE))
               and dist_to(threat_caster) <= state.pike_enemy_range() then
                local ok = issue_item_target(intent, "def", it, threat_caster)
                if ok and not state.pike_primed then
                    state.pike_reissue = { caster = threat_caster, t = now(), self_cast = false }
                end
                return ok
            end
            return state.try_self_push(intent, it, "item_hurricane_pike", 600, threat_caster)
        end,
    },
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
        fire  = function(intent)
            -- v0.5.40.2: UCZone exposes HP via Entity.GetHealth /
            -- GetMaxHealth, NOT NPC.GetHealth (used everywhere else in
            -- Lina.lua at L940, L1579, L2172, L3640, L6082, L6184, etc.).
            -- v0.5.40.1's NPC.* form threw `attempt to call a nil value
            -- (field 'GetHealth')` at runtime when state.self_npc was
            -- alive, crashing the chain walker. The two
            -- fc_defensive_skip_hp tlogs that did fire in the v0.5.40.1
            -- demo log were FALSE PASSES from the
            -- `me and Entity.IsAlive(me) and ... or 1.0` short-circuit
            -- defaulting hp_pct=1.0 when self_npc was nil/dead. Below uses
            -- the canonical Lina pattern (L1579-1580) with full nil guards.
            local me = state.self_npc
            local hp_pct = 1.0
            if me and Entity.IsAlive and Entity.IsAlive(me)
               and Entity.GetHealth and Entity.GetMaxHealth then
                local hp    = Entity.GetHealth(me)    or 0
                local hpmax = Entity.GetMaxHealth(me) or 1
                if hpmax > 0 then hp_pct = hp / hpmax end
            end
            if hp_pct > 0.30 then
                tlog(2, "fc_defensive_skip_hp", {
                    reason   = "hp_above_30pct",
                    hp_pct   = string.format("%.2f", hp_pct),
                })
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
            local _w_caster_for_gate = threat_caster or state.cur_armed_caster
            if state.compute_arrival_time and threat_mod and _w_caster_for_gate then
                local _g_impact_t, _, _g_cat_entry, _g_speed =
                    state.compute_arrival_time(threat_mod, _w_caster_for_gate, me)
                if _g_impact_t and _g_cat_entry then
                    local _g_kind = _g_cat_entry.kind or ""
                    if _g_kind == "homing_charge" or _g_kind == "homing_carry" then
                        local W_LEAD = 1.12
                        local W_AOE_RADIUS = 225
                        local _g_upper = (_g_speed and _g_speed > 0)
                            and (W_LEAD + W_AOE_RADIUS / _g_speed)
                            or (W_LEAD + 0.20)
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
                    end
                    -- channel_at_caster / cast_point_targeted: fall
                    -- through to fire (no timing constraint).
                end
                -- impact_t nil / cat_entry nil = no catalog entry; fall
                -- through to fire (legacy behavior for unmapped mods).
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
                                local W_LEAD = 1.12
                                local bara_travel = eff_speed * W_LEAD
                                local d_at_det = math.max(0, d_now - bara_travel)
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
                d_now  = d_now_dbg    and string.format("%.0f", d_now_dbg)    or nil,
                d_det  = d_at_det_dbg and string.format("%.0f", d_at_det_dbg) or nil,
                speed  = eff_speed_dbg and string.format("%.0f", eff_speed_dbg) or nil,
            })
            return issue_cast_position(intent, w, pos, "def")
        end,
    },
    -- HERO-SPECIFIC: Ethereal Blade self-cast (3-4s physical immune; niche vs
    -- physical burst; still takes magic).
    item_ethereal_blade_self = {
        short = "ether_self",
        fire  = function(intent)
            local eb = NPCLib.item(state.self_npc, "item_ethereal_blade"); if not eb then return false end
            return issue_item_target(intent, "def", eb, state.self_npc)
        end,
    },
}

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
    return Escape.ComputeSafeDest(state.self_npc, threat_caster, push_dist)
end

-- v0.5.75 alias over Escape.TrySelfPush (lifted from Lina v0.5.58).
-- Lib returns (pending|nil, ok). When pending is non-nil, the lib armed
-- a turn-then-fire and Lina stashes it for pending_self_push_tick. nil
-- means either immediate cast OR no safe dest; caller's `ok` decides
-- whether the chain falls through to the next save.
state.try_self_push = function(intent, item, item_name, push_dist, threat_caster)
    local pending, ok = Escape.TrySelfPush(state.self_npc, intent, item,
                                            item_name, push_dist,
                                            threat_caster, state.escape_cfg)
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
    modifier_disruptor_kinetic_field_remnant = function(_c, target, _armed, _ab, _now_t)
        -- Custom: uses 2.6s fallback when GetModifierRemaining returns 0
        -- (the Kinetic Field thinker often outlives the modifier read window
        -- by a tick; 2.6s matches the v6 lifetime). Kept inline because the
        -- generic Remaining factory floors at 0.1s rather than substituting
        -- a default.
        local rem = 0
        if target and Entity.IsEntity and Entity.IsEntity(target) and NPC.GetModifierRemaining then
            local ok, v = pcall(NPC.GetModifierRemaining, target, "modifier_disruptor_kinetic_field_remnant")
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
    compute_arrival_time = state.compute_arrival_time,
    -- Lina HP fraction for the severity skip. Per
    -- reference_uczone_hp_api memory HP lives on Entity, not NPC.
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
        item_pipe_of_insight = true,  -- 30s CD, magic-shield + ally aura
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
    item_wind_waker         = 300,  -- v0.5.15 PT-01: bumped 150 -> 300. 150u was unreachable for Tusk-class closures (522 ms hits the radius in ~0.3s, well past the dispatch window), so eta_critical became the de facto gate. 300u lets the distance check actually contribute on fast approaches without firing pre-emptively from across the lane.
    item_cyclone            = 300,  -- v0.5.15 PT-01: matched item_wind_waker (same fire semantics, same role in the chain).
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
                    if _w_kind == "homing_charge" or _w_kind == "homing_carry" then
                        local W_LEAD = 1.12
                        local W_AOE_RADIUS = 225
                        local _w_lower = W_LEAD
                        local _w_upper = (_w_speed and _w_speed > 0)
                            and (W_LEAD + W_AOE_RADIUS / _w_speed)
                            or (W_LEAD + 0.20)
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
                        -- Out of window: block legacy gates from
                        -- firing W. Return -1 sentinel so eta <= -1
                        -- in armed_threats_tick is always false.
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

-- v0.5.38 MAINT-11.2: post-fire effect helper extracted from
-- armed_threats_tick. Behaviour-neutral. Side-effect ordering preserved:
-- entry.fired stamp, slot nil, armed_threat_fire tlog (kvargs character-
-- identical), try_save_self call, Dedup.threat_mark_responded (AFTER
-- try_save_self returns, mirroring the inlined order), scratch clear.
-- Void return: the inlined original never inspected try_save_self's
-- return value, so promoting it to a bool would be a behaviour delta.
local function armed_post_fire(key, entry, eta, d, fire_reason)
    entry.fired = true
    state.armed_threats[key] = nil
    -- v0.5.46 Problem B belt: stash threat eta for SAVE_FIRE.lina_w_anti_gap.fire
    -- to consult below. W skips if cur_armed_eta < 1.0s AND the threat mod is
    -- in the v0.5.46.2 carry-Lina allowlist (state.W_skip_too_late_mods).
    -- cast_point entries pass eta=0 here as a sentinel (real timing lives in
    -- entry._cp_t), so stash nil for those to avoid a false skip. Cleared at
    -- function end so non-armed call sites of W's .fire (proactive Dispatch,
    -- etc.) see nil and fall through. v0.5.46.2: also stash threat_mod so the
    -- W belt can gate against the carry-Lina allowlist (Tusk snowball etc).
    state.cur_armed_eta        = (not entry.cast_point_threat) and eta or nil
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
    if entry.cast_point_threat then
        try_save_self("armed_" .. key, entry.threat_mod, entry.caster, entry.category, entry.ability, entry)
    else
        try_save_self("armed_" .. key, entry.threat_mod, entry.caster, "close_gap", entry.ability, entry)
    end
    Dedup.threat_mark_responded(state.responded_threats, entry.caster, entry.threat_mod)
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
            if NPCLib.item_ready(state.self_npc, "item_lotus_orb") then
                entry.fired = true
                state.armed_threats[key] = nil
                tlog(1, "lotus_defer_fired", { key = key, mod = entry.threat_mod })
                -- v0.5.40 A3-2: route armed lotus-defer fire through Dispatch
                -- so the Lotus chain-head walk shares the v0.5.40 lock domain
                -- with the castpt/line/anim paths. fire_thunk=nil delegates the
                -- actual cast to the chain walker (Lotus is head of the resolved
                -- chain for this entry's threat_mod). armed_entry=entry threads
                -- the live row through to CountConcurrentExcluding for
                -- entry-handle-identity self-exclusion (matches armed_chain_peek).
                defense_dispatcher:Dispatch("lotus_defer_" .. entry.threat_mod,
                                            entry.threat_mod, entry.caster,
                                            state.self_npc, nil,
                                            nil, nil, entry, record_save,
                                            { fs_shard_window = fs_shard_window_active() })  -- v0.5.40 B2 GAP-3
                Dedup.threat_mark_responded(state.responded_threats, entry.caster, entry.threat_mod)
            elseif now() > (entry.deadline_t or 0) then
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
                if entry.max_dist and d > entry.max_dist then
                    tlog(2, "cast_point_threat_abort_dist", { key = key,
                        dist = string.format("%.0f", d),
                        max_dist = tostring(entry.max_dist) })
                    state.armed_threats[key] = nil
                elseif cp_remaining < -0.3 then
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
}
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
    for mod_name in pairs(PERSISTENT_THREATS) do
        if NPC.HasModifier(me, mod_name) then
            local last_t = state.last_persistent_tick_t[mod_name] or 0
            if (now_t - last_t) >= K.PERSISTENT_THREAT_TICK_INTERVAL then
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
                    tlog(1, "persistent_threat_tick", { mod = mod_name, caster = uname(caster) })
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

-- E12 (deviation, "moved" from Phase E): pre-face an incoming threat so turn
-- time (Lina's 0.6 turn rate) does not extend her next cast. Defense-triggered
-- (scans enemies with a READY targeted-threat ability approaching within TTI),
-- but the payoff is mostly offensive (faster W / R onto the threat) since
-- Lina's save ITEMS are instant and need no facing. Issues a one-frame
-- ATTACK_TARGET that any user input on the next frame supersedes. DEFAULT OFF
-- (it overrides movement); enable in the Defense menu. Ported Sniper.lua:7390.
K.PRE_FACE_TTI_THRESHOLD = 2.5  -- v0.5.15 PT-04: bumped 1.0 -> 2.5. 1.0s TTI requires >1000u/s closure which no unboosted hero hits; the gate was effectively dead. 2.5s catches Tusk/Bara/PA-class approaches in time for the 0.6 turn rate to matter.
K.PRE_FACE_COOLDOWN      = 0.4
K.PRE_FACE_ANGLE_OK      = 25
K.PRE_FACE_SCAN_RADIUS   = 1000

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

local function enemy_has_ready_target_threat(enemy)
    for slot = 0, 5 do
        local ok_a, a = pcall(NPC.GetAbilityByIndex, enemy, slot)
        if ok_a and a and Ability.GetLevel(a) > 0 and Ability.IsReady(a) then
            local ok_n, ability_name = pcall(Ability.GetName, a)
            if ok_n and ability_name and ABILITY_TO_THREAT[ability_name] then
                return true, ability_name
            end
        end
    end
    return false, nil
end

-- v0.5.6 (E3): per-drop-point skip diagnostics so users can see WHY pre_face
-- did not fire (v0.5.4 B4 fix audit found zero pre_face_* events in the
-- re-test log). Cheap level-3 tlog at every early return; no behaviour change.
local function pre_face_tick()
    if not state.menu then return end
    if state.menu.preface_enable and not state.menu.preface_enable:Get() then
        if TLOG3_ENABLED then tlog(3, "pre_face_skip", { reason = "toggle_off" }) end
        return
    end
    if not defense_enabled() then
        if TLOG3_ENABLED then tlog(3, "pre_face_skip", { reason = "defense_off" }) end
        return
    end
    if state.menu.combo_key and state.menu.combo_key:IsDown() then
        if TLOG3_ENABLED then tlog(3, "pre_face_skip", { reason = "combo_key_down" }) end
        return
    end
    if not self_alive_ok() then
        if TLOG3_ENABLED then tlog(3, "pre_face_skip", { reason = "not_self_alive" }) end
        return
    end

    local me = state.self_npc
    local r_ability = ability(A.R)
    if r_ability and Ability.IsInAbilityPhase(r_ability) then
        if TLOG3_ENABLED then tlog(3, "pre_face_skip", { reason = "cast_in_progress" }) end
        return
    end

    -- v0.5.37 PERF-07: read the per-frame now() sample stashed by OnUpdateEx.
    -- pre_face_tick is only called from OnUpdateEx (line 5117); the cooldown
    -- stamp at state.last_preface_t = now_t below uses the same value.
    local now_t = state.frame_t
    if (now_t - (state.last_preface_t or 0)) < K.PRE_FACE_COOLDOWN then
        if TLOG3_ENABLED then tlog(3, "pre_face_skip", { reason = "cooldown" }) end
        return
    end

    local me_pos = NPCLib.origin(me)
    if not me_pos then
        if TLOG3_ENABLED then tlog(3, "pre_face_skip", { reason = "no_me_pos" }) end
        return
    end
    local enemies = NPCs.InRadius(me_pos, K.PRE_FACE_SCAN_RADIUS,
        Entity.GetTeamNum(me), Enum.TeamType.TEAM_ENEMY, true, true)
    if not enemies or #enemies == 0 then
        if TLOG3_ENABLED then tlog(3, "pre_face_skip", { reason = "no_enemies_in_radius" }) end
        return
    end

    local best_e, best_tti, best_via = nil, math.huge, nil
    for _, e in ipairs(enemies) do
        if Target.IsValid(e) and Target.IsAlive(e)
           and Target.IsEnemyHero(e, me) and Target.NotIllusion(e)
        then
            local has, ability_name = enemy_has_ready_target_threat(e)
            -- v0.5.4 (B4 fix): NPC.GetMoveSpeed returns the move-speed STAT and
            -- is non-zero even while the unit is standing still, so using it as
            -- a velocity proxy false-trips TTI on any stationary enemy with a
            -- ready targeted threat. Gate the TTI computation on NPC.IsRunning;
            -- when the enemy is actually moving the stat is a reasonable speed
            -- proxy, otherwise skip and let other defenses handle the threat.
            if has and NPC.IsRunning and NPC.IsRunning(e) then
                local d = dist_to(e)
                local sp = NPC.GetMoveSpeed(e) or 300
                if sp < 200 then sp = 200 end
                local tti = d / sp
                if tti < K.PRE_FACE_TTI_THRESHOLD and tti < best_tti then
                    best_e, best_tti, best_via = e, tti, ability_name
                end
            end
        end
    end

    if not best_e then
        if TLOG3_ENABLED then tlog(3, "pre_face_skip", { reason = "no_running_enemy_with_threat" }) end
        return
    end

    local best_pos = Entity.GetAbsOrigin(best_e)
    if not best_pos then
        if TLOG3_ENABLED then tlog(3, "pre_face_skip", { reason = "no_me_pos" }) end
        return
    end
    local angle = math.deg(math.abs(NPC.FindRotationAngle(me, best_pos)))
    if angle < K.PRE_FACE_ANGLE_OK then
        if TLOG3_ENABLED then tlog(3, "pre_face_skip", { reason = "angle_ok_already" }) end
        return
    end

    local ok = safe_issue {
        hero       = HERO_KEY,
        layer      = "def",
        intent     = "preface_" .. uname(best_e),
        order_type = UO.DOTA_UNIT_ORDER_ATTACK_TARGET,
        unit       = me,
        target     = best_e,
    }
    if ok then
        state.last_preface_t = now_t
        tlog(1, "preface_attack", {
            target = uname(best_e),
            tti    = string.format("%.2f", best_tti),
            angle  = string.format("%.0f", angle),
            via    = best_via or "?",
        })
    end
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
            tlog(1, "instant_blink_armed", { caster = uname(ev.caster), ability = ev.ability_name or "?" })
            if threat then Dedup.threat_clear_responded(state.responded_threats, ev.caster, threat) end
            state.armed_threats[key] = { caster = ev.caster, threat_mod = threat,
                ability = ev.ability_name, eta_speed = 1500, eta_trigger = 0.4,
                fired = false, instant_blink = true, t = now() }
        end
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
local function resolve_live_cast_point(caster, ability_name, default)
    if not caster or not ability_name then return default or 0 end
    if not NPC.GetAbility or not Ability.GetCastPoint then return default or 0 end
    local ok_ab, ab = pcall(NPC.GetAbility, caster, ability_name)
    if not ok_ab or not ab then return default or 0 end
    local ok_cp, cp = pcall(Ability.GetCastPoint, ab, true)
    if ok_cp and type(cp) == "number" and cp > 0 then return cp end
    return default or 0
end

-- Laguna impact damage at current level (KV "damage" = 380/565/750) + the
-- Slow Burn innate DoT (burn_damage_pct 64 -> +0.64x impact over 4s). Returns
-- (impact, burn). r_total = impact + burn (1.64x); the 4s DoT is optimistic
-- for a kill predicate, so r_alone_kill stays user-tunable.
local function lina_r_damage()
    local r = ability(A.R)
    if not r or Ability.GetLevel(r) <= 0 then return 0, 0 end
    local impact = 0
    if Ability.GetLevelSpecialValueFor then
        local ok, v = pcall(Ability.GetLevelSpecialValueFor, r, "damage")
        if ok and type(v) == "number" and v > 0 then impact = v end
    end
    if impact == 0 then impact = ({ 380, 565, 750 })[Ability.GetLevel(r)] or 380 end
    return impact, impact * 0.64
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

    local q, w, r = ability(A.Q), ability(A.W), ability(A.R)
    ctx.ready_q = ability_ready(A.Q)
    ctx.ready_w = ability_ready(A.W)
    ctx.ready_r = ability_ready(A.R)
    ctx.flame_cloak_ready = ability_ready(A.FC)
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
        local fc_h = ability(A.FC)
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

    local impact, burn = lina_r_damage()
    ctx.r_dmg            = impact
    ctx.slow_burn_pending = burn
    ctx.r_total          = impact + burn
    ctx.eff_hp_magical   = lina_eff_hp_magical(target)
    ctx.r_alone_kill     = impact > 0 and ctx.eff_hp_magical <= ctx.r_total

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
state.compute_arrival_time = function(threat_mod, caster, target, modifier_handle)
    return TD.ComputeArrivalTime(threat_mod, caster, target, modifier_handle, state.item_kv)
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
-- v0.5.79 feature C: Ethereal Blade magic-damage amplification used by the
-- ether_wqr kill-confirm. Ethereal's debuff amplifies magic damage taken by
-- the target (~+40% in 7.4x; the IMP-A10 gate frames it as "-30 MR amp"). The
-- kill-confirm multiplies r_total by (1 + this) and compares to eff_hp_magical.
-- Tunable here if the live amp differs; the kill-confirm toggle (default ON)
-- and the wqr fall-through bound any error to "engage without ethereal".
local ETHER_MAGIC_AMP = 0.40

-- v0.5.80 feature D: power-spike save chips for the live Diagnostics HUD.
-- The at-a-glance "am I safe right now" set: high-impact defensive saves +
-- the displacement chain heads. Only items Lina actually owns render (compact
-- line); each shows "rdy" or remaining cooldown in seconds. Menu-label HUD
-- (1Hz refresh), NOT an OnDraw overlay (feedback_hero_brain_iteration).
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
    local c = Geometry.BestAoeCenter(units, W_AOE, W_LEAD, target)
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
        -- v0.5.4: fall back to self origin when both cluster and r_target are
        -- gone (sustain path passes r_target=nil; pile may BKB/evaporate before
        -- pending_steps_tick re-aims). Returning nil propagated through
        -- issue_cast_position into safe_issue with no nil-pos guard; self
        -- origin lets the range gate abort the cast visibly instead.
        return (r_target and Entity.IsEntity(r_target) and Entity.GetAbsOrigin(r_target)) or NPCLib.origin(me)
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
        -- v0.5.4: see tf_w_aim - self origin fallback so nil never reaches
        -- safe_issue when the cluster evaporates mid-chain on the sustain path.
        return (r_target and Entity.IsEntity(r_target) and Entity.GetAbsOrigin(r_target)) or me_pos
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
    return false
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

local function pick_offense_target()
    local me = state.self_npc
    if not me then return nil end
    local list = get_enemies_in_classify_radius(me)  -- v0.5.36 PERF-12: shared per-tick cache
    if not list then return nil end
    local attacking, nearest, best_d
    for i = 1, #list do
        local h = list[i]
        -- Skip magic-immune: Lina's entire kit (Q/W/R) is magical, so a BKB'd
        -- target is untouchable - never pick it as a burst target.
        if h and Target.IsAlive(h) and Target.NotIllusion(h) and Target.NotClone(h)
           and not NPC.HasState(h, MS.MODIFIER_STATE_MAGIC_IMMUNE) then
            local hd = dist_to(h)
            if not attacking and NPC.IsAttacking and NPC.IsAttacking(h) and hd <= 600 then attacking = h end
            if not best_d or hd < best_d then best_d, nearest = hd, h end
        end
    end
    return attacking or nearest
end

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
-- Cyclone setup (Eul OR Wind Waker; both cyclone an enemy 2.5s, invuln then
-- fall). Cyclone -> W placed where they land (stun as cyclone ends ~2.5s) ->
-- R during stun -> Q. cyclone_item is "item_cyclone" or "item_wind_waker".
state.build_lina_cyclone_wrq_steps = function(ctx, cyclone_item)
    local short = (cyclone_item == "item_wind_waker") and "ww" or "eul"
    return {
        { ability = cyclone_item, kind = "item_target", short = short,
          arg = function(c) return c.target end, delay_s = 0 },
        { ability = A.W, kind = "pt", short = "w",
          arg = function(c) return state.predict_cyclone_exit(c.target) end, delay_s = 2.0 },
        { ability = A.R, kind = "ut", short = "r",
          arg = function(c) return c.target end, delay_s = 2.6,
          cond = function(c) return not r_target_blocked(c) end },
        { ability = A.Q, kind = "pt", short = "q",
          arg = function(c) return state.predict_lead_path(c.target) end, delay_s = 3.0 },
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
    -- m.sustain_r_reserve (default ON) lets the user disable for low-mana
    -- edge cases. When OFF, behaves exactly as v0.5.34.
    local sustain_reserve_on = state.menu and state.menu.sustain_r_reserve
                               and state.menu.sustain_r_reserve:Get()
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
    local cap_aware = state.menu and state.menu.fs_cap_aware and state.menu.fs_cap_aware:Get()
    local in_lock = layer1_in_lock()
    if in_lock and state.last_layer1_was_r then return end  -- hard R lock
    local r_finish_only = in_lock                            -- light lock: only the finisher

    local target = pick_offense_target()
    if not target then tlog(3, "lina_starter", { decision = "idle", reason = "no_target" }); return end

    local ctx = build_layer1_ctx(target)
    local fast = (target and NPC.GetMoveSpeed and (NPC.GetMoveSpeed(target) or 0) >= 290) or false
    local target_fleeing_fast = ctx.kiting_us and fast and (ctx.eff_hp_magical <= ctx.r_total)

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
    local ww_ready_threat_in_range
    if (now() - (state.ww_threatened_t or 0)) < 0.2 then
        ww_ready_threat_in_range = state.ww_threatened_cached or false
    else
        ww_ready_threat_in_range = false
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
                                ww_ready_threat_in_range = true
                                break
                            end
                        end
                    end
                end
                if ww_ready_threat_in_range then break end
            end
        end
        state.ww_threatened_t = now()
        state.ww_threatened_cached = ww_ready_threat_in_range
    end
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
        local wqr_undershoots = (not ctx.r_alone_kill) and (ctx.eff_hp_magical > ctx.r_total)
        if mr_val ~= nil then
            ether_needed = mr_significant or wqr_undershoots
        end
        -- v0.5.39 P1-IMP-A10-ONCE: one-shot per session (was per-target). The
        -- API contract is uniform across targets so a single probe diagnoses
        -- the build; per-target stamping was bloat under sustained combo holds.
        local tname = uname(target)
        if not state.imp_a10_probed_once then
            state.imp_a10_probed_once = true
            tlog(1, "imp_a10_mr_probe", {
                target          = tname,
                api_ok          = ok and "y" or "n",
                raw_type        = type(mr),
                raw_value       = tostring(mr),
                mr_val          = (mr_val ~= nil) and string.format("%.3f", mr_val) or "nil",
                mr_significant  = mr_significant and "y" or "n",
                wqr_undershoots = wqr_undershoots and "y" or "n",
                r_alone_kill    = ctx.r_alone_kill and "y" or "n",
                eff_hp_magical  = string.format("%.0f", ctx.eff_hp_magical or 0),
                r_total         = string.format("%.0f", ctx.r_total or 0),
                ether_needed    = ether_needed and "y" or "n",
            })
        end
    end
    -- v0.5.79 feature C: Ethereal+R kill-confirm. ether_wqr spends Ethereal
    -- (4s lockout) + the full W/Q/R combo; only commit it when the ethereal-
    -- amplified R secures the kill. Consistent with the codebase's R-centric
    -- kill model (r_alone_kill / wqr_undershoots also use r_total only). On
    -- failure the ladder falls through to eul/ww/wqr -- Lina STILL engages but
    -- preserves the ethereal finisher for a confirmed kill. Toggle (default ON)
    -- gates the whole check; a tlog records each suppression for demo tuning.
    local ether_kill_ok = true
    local kill_confirm_on = state.menu and state.menu.ether_kill_confirm
                            and state.menu.ether_kill_confirm:Get()
    if kill_confirm_on and ctx.ether_ready then
        local amplified = (ctx.r_total or 0) * (1 + ETHER_MAGIC_AMP)
        ether_kill_ok = (ctx.eff_hp_magical or math.huge) <= amplified
        if not ether_kill_ok then
            tlog(2, "ether_kill_confirm_skip", {
                eff_hp    = string.format("%.0f", ctx.eff_hp_magical or 0),
                r_total   = string.format("%.0f", ctx.r_total or 0),
                amplified = string.format("%.0f", amplified),
                amp       = string.format("%.2f", ETHER_MAGIC_AMP),
            })
        end
    end
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
    elseif ctx.ether_ready and ctx.in_ether_range and ctx.in_w_range and ctx.ready_r and ctx.ready_w and ctx.mana >= cost_ether and ether_needed and ether_kill_ok then
        archetype, steps = "ether_wqr", state.build_lina_ether_wqr_steps(ctx)
    elseif ctx.eul_ready and ctx.in_eul_range and cyclone_safe and ctx.ready_r and ctx.ready_w and ctx.mana >= cost_eul then
        archetype, steps = "eul_wrq", state.build_lina_cyclone_wrq_steps(ctx, "item_cyclone")
    elseif ww_ready and in_ww_range and not ww_threatened and ww_healthy and cyclone_safe and ctx.ready_r and ctx.ready_w and ctx.mana >= cost_ww then
        archetype, steps = "ww_wrq", state.build_lina_cyclone_wrq_steps(ctx, "item_wind_waker")
    elseif ctx.ready_w and ctx.ready_r and ctx.in_w_range and ctx.mana >= cost_wqr and not (target_fleeing_fast and not force) then
        archetype, steps = "wqr", state.build_lina_wqr_steps(ctx)
    elseif ctx.ready_r and ctx.in_r_range and target_fleeing_fast and not r_target_blocked(ctx) then
        archetype, steps = "r_first_rwq", state.build_lina_r_first_rwq_steps(ctx)
    else
        -- v0.5.15 OBS-03 (ladder-miss diag): every higher-tier gate failed,
        -- log per-tier ok bits so the trace explains WHY we landed on sustain.
        tlog(3, "lina_starter_ladder_miss", {
            ether_ok = (ctx.ether_ready and ctx.in_ether_range and ctx.in_w_range and ctx.ready_r and ctx.ready_w and ctx.mana >= cost_ether and ether_needed and ether_kill_ok) and "y" or "n",
            eul_ok   = (ctx.eul_ready and ctx.in_eul_range and cyclone_safe and ctx.ready_r and ctx.ready_w and ctx.mana >= cost_eul) and "y" or "n",
            ww_ok    = (ww_ready and in_ww_range and not ww_threatened and ww_healthy and cyclone_safe and ctx.ready_r and ctx.ready_w and ctx.mana >= cost_ww) and "y" or "n",
            wqr_ok   = (ctx.ready_w and ctx.ready_r and ctx.in_w_range and ctx.mana >= cost_wqr and not (target_fleeing_fast and not force)) and "y" or "n",
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
        tlog(1, "lina_flame_cloak_offensive", {
            trigger = "pre_combo", archetype = archetype,
            fs = tostring(ctx.fiery_soul_stacks or 0),
            mana = string.format("%.0f", ctx.mana or 0),
            mana_after = string.format("%.0f", (ctx.mana or 0) - fc_cost),
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
    local pts = {}
    for i = 1, #list do
        local e = list[i]
        -- Only count enemies W can actually affect: magic-immune enemies take
        -- no stun/damage and give no Fiery Soul stack, so they must not pull
        -- the cluster center toward themselves.
        if e and Target.IsAlive(e) and Target.NotIllusion(e)
           and not NPC.HasState(e, MS.MODIFIER_STATE_MAGIC_IMMUNE) then
            local p = Entity.GetAbsOrigin(e)
            if p then pts[#pts + 1] = p end
        end
    end
    if #pts == 0 then
        state.cluster_cache_t, state.cluster_cache_center, state.cluster_cache_n = frame_t, nil, 0
        return nil, 0
    end
    -- The enemy with the most neighbours within 250u anchors the densest
    -- cluster; centroid via VectorCenter (extension global) with a safe
    -- fallback to that anchor's own position (always a valid W center).
    -- v0.5.24 PERF-03 stretch: track winning anchor index + count only; build
    -- the members list once for the winner instead of allocating per-anchor.
    local best_n, best_anchor_idx = 0, 1
    for i = 1, #pts do
        local pi = pts[i]
        local n = 0
        for j = 1, #pts do
            if pi:Distance2D(pts[j]) <= 250 then n = n + 1 end
        end
        if n > best_n then best_n, best_anchor_idx = n, i end
    end
    local best_anchor = pts[best_anchor_idx]
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
    local cap_aware = state.menu and state.menu.fs_cap_aware and state.menu.fs_cap_aware:Get()

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
    local want_fc_open = fc_menu_on
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
        tlog(1, "lina_flame_cloak_offensive", {
            trigger = "pre_tf_opener", archetype = "tf_opener",
            cluster = string.format("%d", cluster_n),
            fs      = tostring(ctx.fiery_soul_stacks or 0),
            mana    = string.format("%.0f", ctx.mana or 0),
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
            r_worth = (r_impact >= eff_hp)
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
        local want_fc = fc_menu_on
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
            tlog(1, "lina_flame_cloak_offensive", {
                trigger = "pre_tf_burst", archetype = "tf_burst",
                cluster = string.format("%d", cluster_n),
                fs = tostring(ctx.fiery_soul_stacks or 0),
                mana = string.format("%.0f", ctx.mana or 0),
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
        -- v0.5.35 task TF-FC-sustain (Bug B v0.5.33 follow-up): optional FC
        -- pre-amp in tf_sustain context. Gated by m.fc_offensive_sustain_use
        -- (default OFF; v0.5.33 design deliberately excluded sustain because
        -- "no R commit -> 25s CD not worth"). When the user opts in AND the
        -- cluster is dense enough (cluster_n >= 3) AND FC is ready and not in
        -- flight, fire FC before the W/Q. Skips at fs_at_cap (FC sets stacks
        -- to 7 base, would downgrade Shard window cap 12) and during
        -- fs_shard_window. Throttle uses the same 1.5s state.last_fc_dispatch_t
        -- cursor as the starter/tf_burst sites - if a burst already ate FC
        -- recently, sustain won't double-fire.
        local fc_sustain_on = state.menu and state.menu.fc_offensive_sustain_use
                              and state.menu.fc_offensive_sustain_use:Get()
        local fc_sustain_throttled = (now() - (state.last_fc_dispatch_t or 0)) < 1.5
        local fc_sustain_cost = ctx.flame_cloak_ready and ability_mana(A.FC) or 0
        local want_fc_sustain = fc_sustain_on
                                and cluster_n >= 3
                                and ctx.flame_cloak_ready
                                and not ctx.flame_cloak_in_flight
                                and not ctx.is_channelling
                                and not ctx.fs_at_cap
                                and not ctx.fs_shard_window
                                and not fc_sustain_throttled
                                and ctx.mana >= (fc_sustain_cost + ability_mana(A.W) + ability_mana(A.Q))
        if want_fc_sustain then
            tlog(1, "lina_flame_cloak_offensive", {
                trigger = "pre_tf_sustain", archetype = "tf_sustain",
                cluster = string.format("%d", cluster_n),
                fs = tostring(ctx.fiery_soul_stacks or 0),
                mana = string.format("%.0f", ctx.mana or 0),
            })
            -- v0.5.40 A6-4: route TF sustain FC through dispatcher (synthetic mod).
            -- Gates above (want_fc_sustain) already passed; thunk fires + returns true
            -- (state.fire_steps returns nil, explicit return true keeps lock HELD).
            local _a6_fired = defense_dispatcher:Dispatch(
                "lina_fc_offensive_pre_tf_sustain",
                "lina_fc_offensive_pre_tf_sustain",
                state.self_npc,
                state.self_npc,
                function(_intent, _mod, _caster)
                    state.fire_steps("tf_flame_cloak_pre_sustain",
                        state.build_lina_flame_cloak_steps(ctx), ctx)
                    return true
                end,
                nil, "lina_flame_cloak", nil, nil,
                { fs_shard_window = fs_shard_window_active() })  -- v0.5.40 B2 GAP-3 (offensive gate above already vetoed in-window; redundant but uniform)
            state.last_fc_dispatch_t = now()
        end
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
           and not (Target.HasReadyLotus and Target.HasReadyLotus(e)) then
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
local function pending_step_imminent(window_s)
    local t       = now()
    local w       = window_s or 0
    local horizon = t + w
    local spacing = state.STEP_REISSUE_SPACING or 0.25
    for i = 1, #state.pending_steps do
        local p     = state.pending_steps[i]
        local tries = p.tries or 0
        if tries == 0 then
            local fa = p.fire_at or 0
            if fa >= t and fa <= horizon then return true end
        else
            local first_t = p.first_t
            if first_t then
                local next_issue = first_t + tries * spacing
                if next_issue >= t and next_issue <= horizon then return true end
            end
        end
    end
    return false
end
-- v0.5.8 E4 (covers history_F1 / history_F7 / lib_native_F2): belt-and-suspenders
-- watchdog. The framework Hit & Run subsystem has been observed to stay latched
-- in a non-engaging state after our final paused->restored edge of a combo even
-- though Native.RestoreHitRun() re-wrote hr_enabled/hr_override/hr_kiting back
-- to their saved values; the brain's paused/restored accounting ends balanced
-- but auto-attacks never resume. Mitigation: 500ms after the LAST
-- restore-newly-fired transition, while we are still in the restored state,
-- defensively re-assert hr_override=true / hr_enabled=true / hr_kiting=true
-- (idempotent at the widget level - if the framework already holds these, the
-- Set is a no-op). hr_was_paused is the across-tick edge memory; it is reset
-- after every transition so a fresh combo's restore re-arms the watchdog.
local function update_hitrun_pause()
    local m = state.menu
    if m and m.pause_hitrun and not m.pause_hitrun:Get() then
        set_native_hitrun(false)  -- feature off -> ensure restored
    else
        local strict = m and m.pause_hitrun_strict and m.pause_hitrun_strict:Get()
        local active
        if strict then
            -- v0.5.5 wide-pause fallback (A/B safety net)
            active = state.combo_hold_active
                  or (#state.pending_steps > 0)
                  or (now() < (state.combo_active_until or 0))
        else
            active = combo_spell_phasing() or pending_step_imminent(0.15)
        end
        set_native_hitrun(active and true or false)
    end
    -- v0.5.8 E4: arm the post-restore re-assert watchdog on the paused->restored
    -- edge. We sample Native.IsPaused() AFTER set_native_hitrun so the edge
    -- detection is grounded in the lib's authoritative paused[] flag, not our
    -- local intent. hr_last_restore_at is cleared after a single re-assert so we
    -- never spam widget Sets in steady-state.
    local is_paused_now = (Native.IsPaused and Native.IsPaused(LINA_MENU)) or false
    if state.hr_was_paused and not is_paused_now then
        state.hr_last_restore_at = now()
    end
    state.hr_was_paused = is_paused_now
    if state.hr_last_restore_at
       and (now() - state.hr_last_restore_at) >= 0.5
       and not is_paused_now then
        if Native.ReassertEnabled then
            pcall(Native.ReassertEnabled, LINA_MENU)
            tlog(1, "native_hr_reassert", { dt_ms = "500" })
        end
        state.hr_last_restore_at = nil
    end
end

-- TAP/HOLD classifier. Reads the combo key each tick; press<0.18s = TAP (stub),
-- longer = HOLD routed to starter (1-2) / teamfight (3+), latched on hold-start.
state.combo_key_tick = function()
    local m = state.menu
    if not m or not m.combo_key then return end
    -- v0.5.4: if the user holds the combo key and then toggles master/offense
    -- OFF, we must force a clean release before bailing - otherwise
    -- combo_hold_active stays latched, update_hitrun_pause keeps native Hit &
    -- Run paused indefinitely, and combo_key_was_down=true blocks the next
    -- press-edge from firing on re-enable.
    local function force_release()
        state.combo_hold_active      = false
        state.combo_hold_active_mode = nil
        state.combo_key_was_down     = false
    end
    if not offense_enabled() then force_release(); return end
    if m.enable_offense and not m.enable_offense:Get() then force_release(); return end
    local down = false
    local ok, v = pcall(function() return m.combo_key:IsDown() end)
    if ok then down = v and true or false end
    local force_down = false
    if m.force_key then
        local okf, fv = pcall(function() return m.force_key:IsDown() end)
        if okf then force_down = fv and true or false end
    end
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
    local down = false
    local ok, v = pcall(function() return m.wave_key:IsDown() end)
    if ok then down = v and true or false end
    if not down then return end
    -- light throttle: re-evaluate ~5x/sec (Q CD + safe_issue dedup do the rest)
    local t = now()
    if (t - (state.last_wave_clear_t or 0)) < 0.2 then return end
    state.last_wave_clear_t = t

    local me = state.self_npc
    local me_pos = me and Entity.GetAbsOrigin(me)
    if not (me and me_pos) then return end

    local q_ready = ability_ready("lina_dragon_slave")
    local w_ready = m.wave_use_w and m.wave_use_w:Get()
                    and ability_ready("lina_light_strike_array")
    if not (q_ready or w_ready) then return end

    -- mana gates
    local mana    = (NPC.GetMana and NPC.GetMana(me)) or 0
    local maxmana = (NPC.GetMaxMana and NPC.GetMaxMana(me)) or 0
    local floor_frac = (m.wave_mana_floor and (m.wave_mana_floor:Get() / 100)) or 0
    local reserve_r  = m.wave_reserve_r and m.wave_reserve_r:Get()
    local r_cost = reserve_r and ability_mana("lina_laguna_blade") or 0
    if maxmana > 0 and (mana / maxmana) < floor_frac then return end

    local min_creeps = (m.wave_min_creeps and m.wave_min_creeps:Get()) or 3
    local creeps = state.farm_gather_creeps(Q_LENGTH)
    if #creeps == 0 then return end

    local fired = false
    -- Q: best line aim
    if q_ready then
        local q_cost = ability_mana("lina_dragon_slave")
        if mana >= q_cost and (mana - q_cost) >= r_cost then
            local aim, hit_n = Farm.BestLineAim(me_pos, creeps, Q_LENGTH, Q_HALF_WIDTH)
            if aim and Farm.WorthCasting(hit_n, min_creeps) then
                local q = ability("lina_dragon_slave")
                if q and issue_cast_position("wave_clear_q", q, aim, "agg") then
                    fired = true
                    tlog(1, "wave_clear_q", {
                        hits = tostring(hit_n),
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
    local down = false
    local ok, v = pcall(function() return m.dump_key:IsDown() end)
    if ok then down = v and true or false end
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
    local down = false
    local ok, v = pcall(function() return m.panic_key:IsDown() end)
    if ok then down = v and true or false end
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
    local down = false
    local ok, v = pcall(function() return m.test_key:IsDown() end)
    if ok then down = v and true or false end
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
        local gi, glist = state.gank_imminent_self and state.gank_imminent_self()
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
        local sp, sc = state.safest_spot_near and state.safest_spot_near()
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

local function dodger_chain_disable()
    if state.dodger_disabled then return end
    local saved, read_shape = {}, nil
    for _, item in ipairs(DODGER_CHAIN_ITEMS) do
        local v, shape = _dodger_read(item)
        saved[item] = v
        read_shape = read_shape or shape
    end
    local n_set, write_shape = 0, nil
    for _, item in ipairs(DODGER_CHAIN_ITEMS) do
        local ok, shape = _dodger_write(item, false)
        if ok then n_set = n_set + 1 end
        write_shape = write_shape or shape
    end
    state.dodger_saved = saved
    state.dodger_disabled = true
    tlog(1, "dodger_chain_disabled", {
        items      = tostring(#DODGER_CHAIN_ITEMS),
        set_ok     = tostring(n_set),
        read_shape = tostring(read_shape or "nil"),
        write_shape = tostring(write_shape or "nil"),
    })
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
    m.force_key = gCore:Bind("Force-commit key (bypass commit check)",
                             Enum.ButtonCode.KEY_NONE)
    m.force_key:ToolTip("Hold to force a combo even when the kill check refuses.")
    m.panic_key = gCore:Bind("Panic-save key (force next save)",
                             Enum.ButtonCode.KEY_NONE)
    m.panic_key:ToolTip("Press to force the defense layer to fire its next "
        .. "save immediately.")
    m.enable_offense = gCore:Switch("Enable offense (Layer 1)", true)
    m.enable_offense:ToolTip("Master toggle for the HOLD-only adaptive combo "
        .. "(Starter / Team Fight) on the combo key. Off = combo key does "
        .. "nothing; defense and auto-R are unaffected by this toggle.")
    m.auto_r = gCore:Switch("Auto-R kill steal", true)
    m.auto_r:ToolTip("Fire Laguna automatically (no combo key) when R alone "
        .. "(plus Slow Burn) kills a visible enemy in range. Skips magic-immune "
        .. "and Linkens-protected targets.")
    m.pause_hitrun = gCore:Switch("Pause native Hit & Run in combos", true)
    m.pause_hitrun:ToolTip("Disable the framework's built-in Hit & Run (MOVE "
        .. "flood) AND Orb Walker (auto-attack flood) while a combo runs, so their "
        .. "orders stop cancelling the brain's deferred Q / R. Both restored once "
        .. "the combo finishes.")
    -- v0.5.8 (E1, covers history_F1/F3/F4/F7, lib_native_F7, log_timing_F1):
    -- restore the v0.5.5 wide-pause discipline as the default. Wide-pause issues
    -- exactly one Set(Enabled=false) edge on combo entry and one Set(Enabled=true)
    -- edge on full combo release; the v0.5.6 E1 / v0.5.7 E3 narrow-pause regime
    -- floods the framework HR module with 3+ edges per combo, which (with no Orb
    -- Walker Enabled widget present for Lina, F1/F5 cross-lens) leaves HR latched
    -- in a non-engaging state after the final restore. Narrow-pause code path is
    -- preserved behind this toggle for A/B once the framework-recovery question
    -- is answered. update_hitrun_pause() above already implements the strict
    -- branch unchanged -- this registration just flips the default from
    -- nil/false (toggle never registered pre-v0.5.8) to true.
    m.pause_hitrun_strict = gCore:Switch("Wide-pause HR (strict mode)", true)
    m.pause_hitrun_strict:ToolTip("Wide-pause HR for full combo lifecycle "
        .. "(v0.5.5 default, recommended). OFF = narrow per-cast-window pause "
        .. "(v0.5.6-v0.5.7 experimental, known to leave AA stuck off post-combo "
        .. "on heroes lacking Orb Walker Enabled widget).")
    -- v0.5.5: Fiery Soul cap-aware TF. Single shipping toggle so the new
    -- ELIMINATION-mode behaviour at FS cap (7 base, 12 with Aghs Shard for 5s
    -- post-R) can be A/B-tested against the v0.5.4 baseline. Default ON because
    -- v0.5.5 ships the change active. Read exclusively by E4 (offense layer);
    -- no other archetype consults it. Stack count itself comes from the
    -- ctx.fiery_soul_stacks B2 path (NPC.GetModifier + Modifier.GetStackCount,
    -- in build_layer1_ctx where ctx.fiery_soul_stacks is populated).
    m.fs_cap_aware = gCore:Switch("Cap-aware TF (Fiery Soul)", true)
    m.fs_cap_aware:ToolTip("At Fiery Soul cap (7 base, 12 with Aghs Shard for 5s "
        .. "post-R), pivot to ELIMINATION mode: suppress stack-building archetypes "
        .. "(sustain_qw, tf_sustain) and commit tf_burst on full-HP snipes too. "
        .. "Below cap, behaves exactly like v0.5.4.")

    -- v0.5.35 task Q6 (sustain-QW mana floor from v0.5.33 audit): reserve R
    -- cost across all sustain dispatches so the brain doesn't drain mana
    -- below the R kill-floor. Default ON.
    m.sustain_r_reserve = gCore:Switch("Sustain reserves R mana", true)
    m.sustain_r_reserve:ToolTip("When ON, sustain_qw / sustain_qw_cap skip W "
        .. "(and Q) when firing them would leave mana below ability_mana(R). "
        .. "Keeps Lina's R viable for the next ready window. OFF reverts to "
        .. "the v0.5.34 behaviour of spending W/Q whenever mana > the single "
        .. "spell cost. Burst archetypes (which already gate on cost_wqr) "
        .. "are unaffected by this toggle.")

    -- v0.5.33 FC-C-08: Flame Cloak offensive auto-fire toggle. FC is the
    -- Aghs-Scepter-granted instant (+35% spell amp / +35% magic res / 7s) we
    -- want to fire BEFORE the burst archetype so the amp applies to W/Q/R.
    -- Default ON. Toggle OFF for clean revert if mana-burn or unexpected
    -- combo timing surfaces in real games.
    m.fc_offensive_use = gCore:Switch("Flame Cloak auto-fire (offensive)", true)
    m.fc_offensive_use:ToolTip("Aghs Scepter only. Before any burst combo "
        .. "(ether_wqr / eul_wrq / ww_wrq / wqr / r_first_rwq), fire Flame "
        .. "Cloak first so its +35% spell amp lifts W/Q/R damage. Triggers: "
        .. "(c) pre-R commit when stacks are below cap, OR (a) stack refresh "
        .. "in active fight when stacks<4. Skipped during fs_shard_window "
        .. "(would downgrade cap 12->7) and during r_finisher (R alone "
        .. "kills, FC is waste). Defensive save-chain use unaffected.")

    -- v0.5.35 task TF-FC-sustain (v0.5.33 Bug B follow-up): optional FC
    -- pre-amp in tf_sustain when cluster_n >= 3. Default OFF - the v0.5.33
    -- design rationale ("no R commit -> 25s CD not worth") stands; this is
    -- the opt-in for players who want maximum spell-amp on dense pile damage
    -- even at the cost of FC's 25s CD between bursts.
    m.fc_offensive_sustain_use = gCore:Switch("Flame Cloak pre-amp on TF sustain (opt-in)", false)
    m.fc_offensive_sustain_use:ToolTip("Aghs Scepter only. When ON and the "
        .. "teamfight cluster has >=3 enemies, fire Flame Cloak before the "
        .. "tf_sustain W/Q so the +35% spell amp covers the pile damage. "
        .. "Default OFF: FC's 25s CD is reserved for tf_burst R commits. "
        .. "Skipped at fs_at_cap / fs_shard_window / in_flight / channelling, "
        .. "same as the starter and tf_burst sites; shares the 1.5s "
        .. "state.last_fc_dispatch_t throttle.")

    -- v0.5.79 feature C: Ethereal+R kill-confirm. Gate the ether_wqr starter
    -- commit on a calculated post-amp magical kill so Lina does not blow the
    -- 4s-lockout Ethereal on a target it will not finish. On a no-kill verdict
    -- the ladder falls through to eul/ww/wqr (still engages, ethereal saved).
    m.ether_kill_confirm = gCore:Switch("Ethereal+R kill-confirm", true)
    m.ether_kill_confirm:ToolTip("Only commit the Ethereal+W+Q+R starter combo "
        .. "when the ethereal-amplified Laguna (r_total x 1.40) covers the "
        .. "target's effective magical HP. If it would not kill, skip ethereal "
        .. "and fall through to Eul / Wind Waker / bare WQR so the 4s-lockout "
        .. "Ethereal finisher is preserved for a confirmed kill. OFF = v0.5.78 "
        .. "behaviour (ether_wqr fires whenever ethereal is 'needed' per the "
        .. "MR / undershoot gate, kill or not).")

    -- v0.5.78 wave-clear (HOLD): mana + stack aware lane/jungle farm. Q (Dragon
    -- Slave) line nuke at the aim hitting the most creeps; optional W on a dense
    -- camp. Opt-in: KEY_NONE default so the bind does nothing until assigned.
    m.wave_key = gCore:Bind("Wave-clear key (HOLD)", Enum.ButtonCode.KEY_NONE)
    m.wave_key:ToolTip("HOLD to farm: fire Dragon Slave (Q) at the line aim "
        .. "hitting the most nearby creeps, plus Light Strike Array (W) on a "
        .. "dense camp when mana-rich. Player controls movement; the brain only "
        .. "nukes creeps already in range. Gated by min-creeps + mana floor + "
        .. "R reserve. KEY_NONE = off until you assign a key.")
    m.wave_min_creeps = gCore:Slider("Wave-clear: min creeps to fire Q", 1, 6, 3)
    m.wave_min_creeps:ToolTip("Only cast Q when the line would hit at least this "
        .. "many creeps. 3 = won't waste Q on a lone creep; fires on stacked "
        .. "camps / lane waves. Set 1 to nuke anything. W fires at min+1 (a real "
        .. "pack, not a pair).")
    m.wave_mana_floor = gCore:Slider("Wave-clear: mana floor %", 0, 90, 30)
    m.wave_mana_floor:ToolTip("Skip wave-clear entirely while mana fraction is "
        .. "below this %. Keeps a buffer for fights / saves. 30 = stop farming "
        .. "below 30% mana.")
    m.wave_reserve_r = gCore:Switch("Wave-clear reserves R mana", true)
    m.wave_reserve_r:ToolTip("When ON, never spend Q/W on farm if it would drop "
        .. "mana below Laguna Blade's cost, so R stays available for a kill. "
        .. "OFF = farm down to the mana-floor % only.")
    m.wave_use_w = gCore:Switch("Wave-clear uses W on dense camps", true)
    m.wave_use_w:ToolTip("Also drop Light Strike Array (W) on a tightly-packed "
        .. "camp (min-creeps + 1 in the W AoE) when mana allows after Q + the R "
        .. "reserve. Faster clear + a Fiery Soul stack; spends the stun. OFF = "
        .. "Q only.")

    ------------------------------------------------------------- Defense --
    m.auto_defense = gDef:Switch("Enable auto-defense (Layer 2)", true)
    m.auto_defense:ToolTip("Always-on save layer: Wind Waker / Flame Cloak / "
        .. "BKB / Glimmer / Lotus / Force / Pike on incoming threats.")
    m.ally_save = gDef:Switch("Enable ally-save (threat-reactive)", false)
    m.ally_save:ToolTip("Opt-in (support builds). When a recognized threat "
        .. "(gap-close, hard disable, targeted burst, channel) lands on an "
        .. "ally hero, fire an ally-castable save ON them: Glimmer to break a "
        .. "target lock, Lotus to dispel / reflect, Force to reposition. "
        .. "Threat-triggered, not an HP threshold. Off by default.")
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
    -- v0.5.54: AutoDisabler override is now OPT-IN (was default ON in
    -- v0.5.52). Per user spec, AutoDisabler is a verified native
    -- script with broad coverage; disabling it gave up that coverage
    -- for one local Pike-on-Bara conflict. The brain now gates the
    -- conflict at the data layer (Pike has no prep_time so the brain
    -- catalog gate doesn't fire it) instead of zeroing the framework
    -- subsystem. The toggle is preserved for users who explicitly
    -- want the v0.5.52 override behavior (not recommended).
    m.override_autodisabler = gDef:Switch('Override AutoDisabler Force Interrupt items', false)
    m.override_autodisabler:ToolTip("DEPRECATED (default OFF in v0.5.54). "
        .. "v0.5.52 default ON zeroed AutoDisabler's Force Interrupt "
        .. "items (Pike + Force Staff) at GAME_IN_PROGRESS to prevent "
        .. "brain-vs-framework double-fire on Bara charge. v0.5.54 "
        .. "reverses this: AutoDisabler stays active per its native "
        .. "config and the brain stays out of its lane by dropping "
        .. "prep_time from Pike. The toggle is preserved for users "
        .. "who explicitly want the v0.5.52 override behavior but is "
        .. "now no-op by default. To re-enable: turn this on, then "
        .. "Pike + Force Staff in AutoDisabler/Force Interrupt/Usage "
        .. "are zeroed at GAME_IN_PROGRESS (state.AD.disable is gone "
        .. "from OnUpdateEx; this toggle's ON state has no effect in "
        .. "v0.5.54+ -- it is preserved for menu compatibility only).")
    m.preface_enable = gDef:Switch("Pre-face incoming threats", false)
    m.preface_enable:ToolTip("Turn to face an approaching enemy that has a "
        .. "ready targeted threat, so Lina's 0.6 turn rate does not delay her "
        .. "next W / R. Off by default; issues a brief attack-face your next "
        .. "input overrides. Most useful once offense (Phase F) ships.")

    --------------------------------------------------------- Diagnostics --
    m.diag = gDiag:Slider("Log verbosity", 0, 3, 1)
    m.diag:ToolTip("0 = silent, 1 = decisions, 2 = + skips, 3 = full trace. "
        .. "Written to C:\\Umbrella\\debug.log.")
    gDiag:Label("- Brain status (live) -")
    m.lbl_self     = gDiag:Label("self: not acquired")
    m.lbl_counters = gDiag:Label("counts: l1=0 l2=0")
    -- v0.5.80 feature D: live power-spike save readiness (owned items only).
    m.lbl_saves    = gDiag:Label("saves: -")
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
    -- is now GENERATED by tools/gen_anim_maps.py from npc_heroes.json +
    -- npc_abilities.json. Cast-activity slots are derived (D18 algorithm);
    -- roles are seeded from the prior hand-tuned maps + threat_data.lua, with
    -- a CHANNELLED-behaviour draft for the tail. Re-run the generator after a
    -- patch; do NOT hand-edit these blocks. 68 heroes, 105 threat abilities.
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
        [AB[4]] = { ability = "bloodseeker_rupture", role = "ult_burst" },
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
        [AB[1]] = { ability = "brewmaster_cinder_brew", role = "hard_disable" },
    })
    -- broodmother (v6.15.268 zero-coverage fill)
    -- v0.5.36: Sticky Snare is POINT VECTOR_TARGETING CHANNELLED -- Brood places a
    -- web-snare that roots Lina if she walks through. anim catches the
    -- cast.
    Anim.RegisterMap("npc_dota_hero_broodmother", {
        [AB[2]] = { ability = "broodmother_sticky_snare", role = "hard_disable" },
    })
    -- bristleback (v6.15.266 zero-coverage fill)
    -- Hairball is a hidden POINT-AOE that fires a line of viscous goo (same
    -- mechanic as Viscous Nasal Goo Q, but auto-cast multi-target).
    Anim.RegisterMap("npc_dota_hero_bristleback", {
        [AB[2]] = { ability = "bristleback_hairball", role = "hard_disable" },
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
        [AB[5]] = { ability = "clinkz_burning_barrage", role = "channel_start" },  -- (draft)
    })
    -- crystal_maiden
    Anim.RegisterMap("npc_dota_hero_crystal_maiden", {
        [AB[4]] = { ability = "crystal_maiden_freezing_field", role = "channel_start" },
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
        [AB[4]] = { ability = "dark_willow_terrorize", role = "hard_disable" },
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
        [AB[2]] = { ability = "doom_bringer_infernal_blade", role = "hard_disable", instant_target = true },
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
        [AB[3]] = { ability = "ember_spirit_sleight_of_fist", role = "hard_disable" },
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
        [AB[1]] = { ability = "gyrocopter_homing_missile", role = "hard_disable", instant_target = true },  -- 0 cast, IGNORE_BACKSWING
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
        [AB[1]] = { ability = "juggernaut_swift_slash", role = "gap_close", instant_target = true },
        [AB[4]] = { ability = "juggernaut_omni_slash", role = "channel_start", instant_target = true },
    })
    -- keeper_of_the_light
    Anim.RegisterMap("npc_dota_hero_keeper_of_the_light", {
        [AB[1]] = { ability = "keeper_of_the_light_illuminate", role = "channel_start" },  -- (draft)
    })
    -- kunkka (v6.15.263 zero-coverage fill)
    Anim.RegisterMap("npc_dota_hero_kunkka", {
        [AB[1]] = { ability = "kunkka_torrent", role = "hard_disable" },  -- POINT-AOE, 0.4 cast, 1.5s warning
        [AB[2]] = { ability = "kunkka_x_marks_the_spot", role = "hard_disable", instant_target = true },  -- unit-target, IGNORE_BACKSWING
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
        [AB[4]] = { ability = "lich_chain_frost", role = "ult_burst" },
    })
    -- life_stealer
    Anim.RegisterMap("npc_dota_hero_life_stealer", {
        [AB[2]] = { ability = "life_stealer_open_wounds", role = "hard_disable" },
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
        [AB[1]] = { ability = "marci_grapple", role = "gap_close", instant_target = true },
    })
    -- medusa (v6.15.268 zero-coverage fill)
    -- Mystic Snake is UNIT_TARGET (bounces between enemies). Gorgon Grasp
    -- is POINT-AOE stun. Both aim-required; default facing gate.
    Anim.RegisterMap("npc_dota_hero_medusa", {
        [AB[1]] = { ability = "medusa_mystic_snake", role = "hard_disable" },
        [AB[3]] = { ability = "medusa_gorgon_grasp", role = "hard_disable" },
    })
    -- mars
    Anim.RegisterMap("npc_dota_hero_mars", {
        [AB[1]] = { ability = "mars_spear", role = "hard_disable" },
        [AB[2]] = { ability = "mars_gods_rebuke", role = "hard_disable" },
        [AB[4]] = { ability = "mars_arena_of_blood", role = "hard_disable" },
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
        [AB[4]] = { ability = "nyx_assassin_vendetta", role = "gap_close" },
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
        [AB[4]] = { ability = "omniknight_hammer_of_purity", role = "hard_disable", instant_target = true },
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
        [AB[1]] = { ability = "primal_beast_onslaught", role = "gap_close" },
        [AB[4]] = { ability = "primal_beast_pulverize", role = "channel_start", instant_target = true },
    })
    -- puck
    Anim.RegisterMap("npc_dota_hero_puck", {
        [AB[2]] = { ability = "puck_waning_rift", role = "hard_disable" },
        [AB[3]] = { ability = "puck_phase_shift", role = "channel_start" },  -- (draft)
        [AB[4]] = { ability = "puck_dream_coil", role = "hard_disable" },
    })
    -- pudge
    -- v6.15.250: Dismember is unit-target (Pudge selects Sniper by
    -- reference, doesn't aim); add instant_target so the channel-start
    -- save fires even when Pudge faces away. Meat Hook is a line skill-
    -- shot (Pudge DOES aim it) -- facing gate stays for that one.
    Anim.RegisterMap("npc_dota_hero_pudge", {
        [AB[1]] = { ability = "pudge_meat_hook", role = "gap_close" },
        [AB[4]] = { ability = "pudge_dismember", role = "channel_start", instant_target = true },
    })
    -- pugna
    Anim.RegisterMap("npc_dota_hero_pugna", {
        [AB[4]] = { ability = "pugna_life_drain", role = "channel_start", instant_target = true },
    })
    -- rattletrap
    Anim.RegisterMap("npc_dota_hero_rattletrap", {
        [AB[4]] = { ability = "rattletrap_hookshot", role = "gap_close" },
    })
    -- riki (v6.15.267 added blink_strike + smoke_screen)
    -- Blink Strike is UNIT_TARGET 0.3 cast IGNORE_BACKSWING -- Riki blinks
    -- to target and attacks; no aim. Smoke Screen is POINT-AOE silence +
    -- miss chance (anim catches the placement).
    Anim.RegisterMap("npc_dota_hero_riki", {
        [AB[1]] = { ability = "riki_blink_strike", role = "gap_close", instant_target = true },
        [AB[2]] = { ability = "riki_smoke_screen", role = "hard_disable" },
        [AB[3]] = { ability = "riki_tricks_of_the_trade", role = "channel_start" },  -- (draft)
    })
    -- ringmaster
    Anim.RegisterMap("npc_dota_hero_ringmaster", {
        [AB[1]] = { ability = "ringmaster_tame_the_beasts", role = "channel_start" },  -- (draft)
        [AB[3]] = { ability = "ringmaster_impalement", role = "hard_disable" },
        [AB[4]] = { ability = "ringmaster_wheel", role = "hard_disable" },
    })
    -- rubick (v6.15.258 zero-coverage fill)
    Anim.RegisterMap("npc_dota_hero_rubick", {
        [AB[1]] = { ability = "rubick_telekinesis", role = "hard_disable" },  -- 0.1 cast, lift+land stun (IGNORE_BACKSWING)
    })
    -- sand_king
    Anim.RegisterMap("npc_dota_hero_sand_king", {
        [AB[1]] = { ability = "sandking_burrowstrike", role = "hard_disable" },
        [AB[4]] = { ability = "sandking_epicenter", role = "hard_disable" },
    })
    -- shadow_demon
    Anim.RegisterMap("npc_dota_hero_shadow_demon", {
        [AB[1]] = { ability = "shadow_demon_disruption", role = "hard_disable" },
        [AB[4]] = { ability = "shadow_demon_demonic_purge", role = "hard_disable" },
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
        [AB[1]] = { ability = "slardar_slithereen_crush", role = "hard_disable" },
        [AB[3]] = { ability = "slardar_amplify_damage", role = "hard_disable", instant_target = true },
    })
    -- slark
    Anim.RegisterMap("npc_dota_hero_slark", {
        [AB[2]] = { ability = "slark_pounce", role = "gap_close" },
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
        [AB[4]] = { ability = "treant_overgrowth", role = "hard_disable" },
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
        [AB[1]] = { ability = "visage_grave_chill", role = "hard_disable", instant_target = true },
        [AB[2]] = { ability = "visage_soul_assumption", role = "ult_burst", instant_target = true },
    })
    -- vengefulspirit (existing)
    Anim.RegisterMap("npc_dota_hero_vengefulspirit", {
        [AB[4]] = { ability = "vengefulspirit_nether_swap", role = "hard_disable" },
    })
    -- void_spirit
    Anim.RegisterMap("npc_dota_hero_void_spirit", {
        [AB[1]] = { ability = "void_spirit_aether_remnant", role = "hard_disable" },
        [AB[4]] = { ability = "void_spirit_astral_step", role = "gap_close" },
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
        [AB[4]] = { ability = "witch_doctor_death_ward", role = "channel_start" },
    })
    -- zuus
    Anim.RegisterMap("npc_dota_hero_zuus", {
        [AB[2]] = { ability = "zuus_lightning_bolt", role = "ult_burst" },
        [AB[4]] = { ability = "zuus_thundergods_wrath", role = "ult_burst" },
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
-- PE-04's LINA_SAVE_OVERRIDES entry for modifier_disruptor_kinetic_field_remnant
-- (chain: WW > Eul > Force > Pike) via the OnModifierCreate path. The
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
        state.pending_post_airborne_move_tick()  -- v0.5.62 Phase 5 slice 3 fix:
                                         -- fire EUL / WW post-move once
                                         -- the airborne modifier clears
                                         -- (or restore Native on timeout)
        pre_face_tick()            -- E12: opt-in pre-face incoming threats
        -- Layer 1 offense (Phase F): latch -> scheduled steps -> R-abort ->
        -- auto-R kill-steal -> HOLD/TAP combo-key dispatch.
        Geometry.SampleVelocities(state.self_npc)  -- v0.3.6: feed the smoothed-prediction buffer
        state.pending_steps_tick() -- fire deferred combo steps at their delays
        state.r_abort_tick()       -- STOP a doomed R mid-cast (refund mana/CD)
        state.lina_r_kill_steal_tick()
        state.combo_key_tick()     -- HOLD/TAP classify + starter/teamfight dispatch
        state.wave_clear_tick()    -- v0.5.78: HOLD wave-clear (Q line + W dense camp), mana+stack aware
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
            local lbl_c = state.menu.lbl_counters
            if lbl_c then
                _lbl_set(lbl_c, string.format("counts: l1=%d l2=%d",
                    state.l1_counter or 0, state.l2_counter or 0))
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
    handle_modseen_accumulator(npc, modifier, mod_name, is_self)
    handle_ally_save(npc, modifier, mod_name, is_self)
    if handle_lotus_first(npc, modifier, mod_name, is_self) then return end
    handle_unrecognized_harvest(npc, modifier, mod_name, is_self)
    if handle_threat_on_self(npc, modifier, mod_name, is_self) then return end

    -- Homing close-gap: ARM at modifier-create, FIRE near impact (armed tick).
    if mod_name == "modifier_spirit_breaker_charge_of_darkness"
       and Target.IsEnemyHero and Target.IsEnemyHero(npc, state.self_npc) then
        local existing = state.armed_threats["bara_charge"]
        if not existing or existing.caster ~= npc then
            tlog(1, "bara_charge_armed", { caster = uname(npc) })
            state.modcreate_counter = state.modcreate_counter + 1
            -- v0.5.4: key on KV-stable ability name so armed_threats_tick hits
            -- the ANIM_SAVE_OVERRIDES branch; survives future lib modifier renames.
            state.armed_threats["bara_charge"] = { caster = npc,
                ability = "spirit_breaker_charge_of_darkness",
                threat_mod = "modifier_spirit_breaker_charge_of_darkness",
                eta_speed = 600, eta_trigger = 0.8, fired = false }
        end
    elseif mod_name == "modifier_tusk_snowball_movement"
       and Target.IsEnemyHero and Target.IsEnemyHero(npc, state.self_npc) then
        local existing = state.armed_threats["tusk_snowball"]
        if not existing or existing.caster ~= npc then
            tlog(1, "tusk_snowball_armed", { caster = uname(npc) })
            state.modcreate_counter = state.modcreate_counter + 1
            -- v0.5.4: key on KV-stable ability name (see bara_charge note above).
            state.armed_threats["tusk_snowball"] = { caster = npc,
                ability = "tusk_snowball",
                threat_mod = "modifier_tusk_snowball_movement",
                eta_speed = 1200, eta_trigger = 0.5, fired = false }
        end
    end
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
    if mod_name == "modifier_spirit_breaker_charge_of_darkness" then
        if state.armed_threats["bara_charge"] then
            tlog(2, "bara_charge_cleared", { caster = uname(npc) })
            state.armed_threats["bara_charge"] = nil
        end
    elseif mod_name == "modifier_tusk_snowball_movement" then
        if state.armed_threats["tusk_snowball"] then
            tlog(2, "tusk_snowball_cleared", { caster = uname(npc) })
            state.armed_threats["tusk_snowball"] = nil
        end
    end
end

-- v0.5.11 PE-02: line-projectile intercept (port of Sniper.lua
-- callbacks.OnLinearProjectileCreate, the Pudge-hook perpendicular-distance
-- save). OnModifierCreate fires AFTER the hook has already grabbed Lina, so
-- Force / Pike / WW can no longer displace her out of the line. By the time
-- the modifier lands the cast is committed; the only window where a self-
-- displacement save can actually break the threat is between projectile
-- creation and projectile arrival. Generalized to the five signature line
-- threats called out in PE-02: pudge hook, mirana arrow, magnataur skewer,
-- sven storm bolt, earthshaker fissure. The hit-radius column is the
-- projectile collision width on Lina (1.0 hull); +75 buffer covers Lina's
-- own jitter while the order resolves.
--
-- Threat-mod resolution: where a canonical pre-impact modifier exists in
-- lib/threat_data.lua (verified at port time: modifier_pudge_meat_hook,
-- modifier_mirana_arrow, modifier_magnataur_skewer, modifier_sven_storm_bolt)
-- it is passed to try_save_self so ResolveSaveOrder consults
-- LINA_SAVE_OVERRIDES / PATCHED_RECOMMENDED_SAVES (mirrors Sniper). Fissure
-- has no per-modifier pre-impact entry, so threat_mod is left nil and the
-- "line_projectile" category_hint drives the chain via CATEGORY_CHAINS
-- (line_projectile is the canonical lib category; lib/threat_data.lua key).
local LINE_PROJECTILE_INTERCEPTS = {
    -- src_unit_name              ability_name                threat_mod (nilable, canonical)              hit_radius
    npc_dota_hero_pudge         = { ability = "pudge_meat_hook",        threat_mod = "modifier_pudge_meat_hook",     hit_radius = 130 },
    npc_dota_hero_mirana        = { ability = "mirana_arrow",           threat_mod = "modifier_mirana_arrow",        hit_radius = 115 },
    npc_dota_hero_magnataur     = { ability = "magnataur_skewer",       threat_mod = "modifier_magnataur_skewer",    hit_radius = 125 },
    npc_dota_hero_sven          = { ability = "sven_storm_bolt",        threat_mod = "modifier_sven_storm_bolt",     hit_radius = 96  },
    npc_dota_hero_earthshaker   = { ability = "earthshaker_fissure",    threat_mod = nil,                            hit_radius = 100 },
}

function callbacks.OnLinearProjectileCreate(data)
    -- v0.5.21 OBS-05: per-reason skip emits so future debug.log retests can
    -- localize which gate killed a projectile event (engine delivered vs
    -- filtered here vs filtered downstream). Level 3 throughout to keep
    -- default verbosity 1 quiet; the 5-hero LINE_PROJECTILE_INTERCEPTS gate
    -- is the highest-volume branch when -v 3 is set.
    if not state.self_npc or not data then
        if TLOG3_ENABLED then tlog(3, "projectile_skip", { reason = "no_self_or_data" }) end
        return
    end
    -- v0.5.13 E3 (HI-1, HI-2 option a): align gate with Sniper.lua:9647 by
    -- dropping the layer2_can_fire() precheck. A recently-fired save would
    -- otherwise silently suppress the line-intercept event entirely; the
    -- dispatcher's CanFire still gates the actual cast downstream.
    if not defense_enabled() then
        if TLOG3_ENABLED then tlog(3, "projectile_skip", { reason = "defense_off" }) end
        return
    end
    -- v0.5.21 OBS-11: per-subsystem toggle. Bypass the entire line-projectile
    -- intercept layer (Pudge Hook, Mirana Arrow, Magnus Skewer, Sven Bolt,
    -- ES Fissure) when the user wants to handle those manually.
    if state.menu and state.menu.enable_line_intercept
       and not state.menu.enable_line_intercept:Get() then
        if TLOG3_ENABLED then tlog(3, "projectile_skip", { reason = "subsystem_off" }) end
        return
    end
    local src = data.source
    if not src or not Entity.IsEntity(src) or not Entity.IsNPC(src) then
        if TLOG3_ENABLED then tlog(3, "projectile_skip", { reason = "src_not_npc" }) end
        return
    end
    if not Target.IsEnemyHero or not Target.IsEnemyHero(src, state.self_npc) then
        if TLOG3_ENABLED then tlog(3, "projectile_skip", { reason = "src_not_enemy" }) end
        return
    end
    local src_name = NPC.GetUnitName(src)
    local entry = LINE_PROJECTILE_INTERCEPTS[src_name]
    if not entry then
        if TLOG3_ENABLED then tlog(3, "projectile_skip", { reason = "src_not_hook_caster" }) end
        return
    end

    local me_pos = NPCLib.origin(state.self_npc)
    local origin = data.origin or NPCLib.origin(src)
    local velocity = data.velocity
    if not me_pos or not origin or not velocity then
        if TLOG3_ENABLED then tlog(3, "projectile_skip", { reason = "missing_geometry", src = uname(src) }) end
        return
    end
    local vel_len = velocity:Length2D()
    if vel_len < 1 then
        if TLOG3_ENABLED then tlog(3, "projectile_skip", { reason = "zero_velocity", src = uname(src) }) end
        return
    end
    local dir = velocity:Normalized()
    local to_me = me_pos - origin
    local along = to_me:Dot(dir)
    -- Heading-toward-Lina: projectile origin is behind us along its travel
    -- axis. Same gate Sniper uses (along < 0 -> reject); also implicitly
    -- prevents firing on a projectile already past us.
    if along < 0 then
        if TLOG3_ENABLED then tlog(3, "projectile_skip", { reason = "heading_away", src = uname(src) }) end
        return
    end
    local perp = (to_me - dir * along):Length2D()
    -- v0.5.13 E3 (HI-1, HI-2): observability tlog so future Pudge / Mirana /
    -- Magnus / Sven / ES retests can tell apart "engine never delivered the
    -- event" (no log line) from "delivered but filtered downstream" (this
    -- line present, followed by a skip or intercepted line).
    -- v0.5.14 E9 (BL-A8): moved BELOW perp/along compute so the logged values
    -- are real, not "-" placeholders. The original placement at the top of
    -- the function logged before either was computed; the relocation costs
    -- one extra reject path (along<0) of silence but every other branch
    -- (skip / intercept) now reflects the actual numbers.
    if TLOG3_ENABLED then
        tlog(3, "line_projectile_seen", {
            src   = uname(src),
            vel   = string.format("%.0f", vel_len),
            perp  = string.format("%.0f", perp),
            along = string.format("%.0f", along),
        })
    end
    local fire_floor = entry.hit_radius + 75
    if perp >= fire_floor then
        -- v0.5.13 E3 (HI-1, HI-2): name the most common reject path so the
        -- log distinguishes "geometry refused" from "throttle / source filter".
        if TLOG3_ENABLED then
            tlog(3, "line_projectile_skip", {
                src    = uname(src),
                reason = "perp_over_floor",
                perp   = string.format("%.0f", perp),
                floor  = tostring(fire_floor),
            })
        end
        return
    end

    -- Dedup key: prefer canonical mod (matches OnModifierCreate's eventual
    -- mark so the modifier-lands path no-ops cleanly). For fissure (no mod)
    -- fall back to "<ability>_incoming" as called out in PE-02; keeps the
    -- key unique per cast without colliding with any catalog mod_name.
    local dedup_mod = entry.threat_mod or (entry.ability .. "_incoming")
    if Dedup.threat_already_responded(state.responded_threats, src, dedup_mod) then
        if TLOG3_ENABLED then tlog(3, "projectile_skip", { reason = "dedup_hit", src = uname(src), mod = dedup_mod }) end
        return
    end

    tlog(1, "line_projectile_intercepted", {
        src      = uname(src),
        ability  = entry.ability,
        perp     = string.format("%.0f", perp),
        along    = string.format("%.0f", along),
        floor    = tostring(fire_floor),
    })
    -- v0.5.14 E3 (BL-A6): mark dedup BEFORE try_save_self (and after the
    -- geometry gate passes), not only on save-success. Previously, if no save
    -- was available the call returned without marking, so every subsequent
    -- OnLinearProjectileCreate event for the same hook re-entered this path
    -- and re-burned the dispatcher's layer-2 throttle. The THREAT_WINDOW
    -- (2s, lib/dedup.lua:49) is wide enough to cover any legitimate
    -- re-acquire for a single cast. Matches the Sniper.lua:9647 convention
    -- of one dedup mark per intercepted line-projectile.
    Dedup.threat_mark_responded(state.responded_threats, src, dedup_mod)
    -- v0.5.40 A3-3: route line-projectile intercept through Dispatch with
    -- category_hint="line_projectile" so fissure (threat_mod nil) still
    -- resolves to the line-projectile chain via ResolveSaveOrder. The lock
    -- key tuple is (state.self_npc, canonical(threat_mod), src). Per the
    -- v0.5.40 dispatcher API, when src is nil (fog projectile) the lock leg
    -- collapses to nil and the dispatcher logs lock_key_unresolvable at v=2
    -- and falls through to the v0.5.39 unlocked path -- safe migration for
    -- the fog case. For threats with a canonical mod, the hero/lib override
    -- tables take precedence inside ResolveSaveOrder (perp_displacement primary).
    defense_dispatcher:Dispatch("line_intercept_" .. entry.ability,
                                entry.threat_mod, src,
                                state.self_npc, nil,
                                "line_projectile", entry.ability, nil,
                                record_save,
                                { fs_shard_window = fs_shard_window_active() })  -- v0.5.40 B2 GAP-3
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

LOG:info("Lina brain v0.5.82 (optimization pass + quality checks): from a fan-out optimization Workflow (8 reviewers + adversarial verify; 32 raised, 15 confirmed, 0 high-risk). User: 'run the same process on the optimization side setting up quality checks'. Applied the 2 high-value low-risk opts + added in-brain contract tests; quality-check tooling lands repo-side. **Opt 1 (highest value) sample_attacker_latches**: was running the WIDEST per-frame hero enumeration in the whole tick chain (Entity.GetHeroesInRadius 3200u TEAM_ENEMY + per-hero IsAttacking loop) EVERY frame with NO gate, even when the commit-attacker feature is off, and stamping latches out to 3200u that the consumer (is_committed_attacker_on_self) rejects beyond 700u. Fix: gate on state.menu.enable_commit_attacker like scan_and_arm already does + narrow radius to K.LINA_ATTACK_ENGAGE_RADIUS (700). Behaviour-neutral (accept window unchanged); kills a large per-frame cost. **Opt 2 wave_clear_tick W dedup**: the v0.5.81 fix added a SECOND state.farm_gather_creeps(w_range) call (2-3 engine enumerations + full per-unit predicate pass) after the Q-range gather. Since the Q list (1075) is a strict superset of W range, filter it in-memory by squared distance <= w_range instead of re-querying the engine. Removes the redundant sweep; identical W creep set. **In-brain test Q82_fog_escape_alias_contracts**: new state.tests entry (runs via the Diagnostics test key) that nils state.self_npc and asserts all 7 v0.5.76-78 fog/escape/farm aliases (fog_snapshot, possible_gankers, gank_imminent_self, missing_from_map, initiators_accounted_for, pike_advance_pick, safest_spot_near) return their documented shape with no throw -- the exact nil-deref/shape class the workflow flagged. **Quality-check tooling (repo-side, this version)**: tools/run_tests.lua gains a Vector stub + lib/farm unit tests (BestLineAim/BestPointAim/CountInLine/WorthCasting); a .luacheckrc with the UCZone framework-globals allowlist; tools/predeploy_check.ps1 codifying the luac + lesson-15 banner + no-BOM + hash protocol. **Deferred (reported, not applied -- 4 medium-risk)**: combo_key_tick per-frame closure+thunk alloc; PickDir double-scoring DangerAtPos; ResolveSaveOrder tlog-table alloc when L3 off; build_layer1_ctx ability double-fetch. All touch shared-lib / battle-tested offense-defense paths; left for a focused pass. **Files**: Lina.lua only (deployed). lib/* + Sniper.lua unchanged. luac clean, no BOM, lesson 15 verified. **Verification on next demo**: commit-attacker OFF -> no 3200u enum in the tick (was every frame); wave-clear W identical targeting at lower cost; run the test key -> Q82 + existing tests pass.")

return callbacks
