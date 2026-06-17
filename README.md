# lina-hero-brain

A decision-making brain for Dota 2's Lina, written for the UCZone Lua
scripting API. It runs as a companion to the framework's built-in Lina
script: the baseline keeps doing the routine work (orbwalk, item usage,
target picking, kill-stealing), and the brain adds the decisions the
baseline cannot make on its own, the ones that need state across ticks
or domain knowledge about Lina specifically. Multi-spell combos timed
around the Fiery Soul stack window. Cast-point-aware defensive saves
that fire when the cast is about to land, not when its modifier first
appears. Aghs-Shard math that knows the post-R window raises the FS
cap from 7 to 12 and that firing Flame Cloak inside that window throws
five stacks away. A per-threat dispatch lock that closes the
"two saves on one threat" class of bugs that every multi-path defense
layer inherits sooner or later.

This repository is the full source: the brain itself
(`Lina/Lina.lua`, around 7,000 lines), the shared Lua libraries it
sits on (`lib/`), the code generators that build the data libraries
from Valve's KV files (`tools/`), and the architecture and reference
documents written alongside it.

The threat catalog reaches 97% of the 7.41C hero roster (shared with
the sister project [sniper-hero-brain](https://github.com/PirucaxD/sniper-hero-brain),
which is where the catalog originates). One regen of the data libs
after a Dota patch and Lina's defense layer is current; no hand-typed
magnitudes to silently drift.

## License + intended use

Source available under the [PolyForm Noncommercial 1.0.0](LICENSE)
license. Free for personal study, classroom teaching, academic
research, hobby projects, and anything else that is not a commercial
purpose. No warranty, no liability. The intent is for students poking
at game AI, state machines, threat modeling, and brittle-API
integration to be able to read the full thing, including the
comments, and copy ideas (not re-sell). If you want to use this
commercially, that is outside the license, reach out and we can talk.

The hand-written modules under `lib/` are a snapshot of the upstream
[uczone-toolkit](https://github.com/PirucaxD/uczone-toolkit), which
is MIT-licensed. Pull `lib/` from the toolkit directly if you want it
under MIT terms.

## The augmentation model

The brain does not replace the framework's hero script. It is a
sidecar.

UCZone ships a generic per-hero baseline plus framework-wide
subsystems (Hit & Run, Orb Walker, Items Manager, Dodger, Linkbreaker,
Target Lock). Those are competent at the mechanical layer and
patch-maintained. The brain leaves them running and only issues the
*additional* orders that need reasoning the baseline does not do:
"this enemy committed onto me, run the W+R+Q burst", "Sniper is
casting Assassinate from 3000u away, arm a Lotus and fire it at the
end of his cast point, not now", "we have Aghs charges of Flame Cloak
and a teamfight is starting, pre-amp with FC before the burst".

This choice is load-bearing, and it is the source of some of the
hardest problems in the post-mortem. The brain and the native
subsystems both issue orders to the same unit and do not coordinate
through any API. Living with that is a recurring theme.

## Features

What the brain adds on top of the native Lina script:

**Offense, on the combo key:**

- A burst-combo dispatcher with five Layer-1 archetypes
  (`ether_wqr`, `eul_wrq`, `ww_wrq`, `wqr`, `r_first_rwq`) selected
  per tick from a starter ladder against 1-2 enemies. Each archetype
  is a per-step plan with abort-on-cd, abort-on-no-land, and an
  optional pre-amp.
- An always-on R kill-steal that fires Laguna Blade when the snipe
  is lethal-now and not blocked (Lotus, BKB, spell-deflect, hard CC
  reservation).
- A cannot-kill gate (`Target.IsUnkillableNow`) on every kill-commit
  and target pick: a target under Dazzle Shallow Grave, Oracle False
  Promise, or with Wraith King Reincarnation ready cannot die now, so
  the brain skips it instead of dumping a combo into a guaranteed
  survivor and picks a killable target instead.
- A team-fight mode for cluster_n>=3 with `tf_burst` (W+Q+R
  on a chosen R-target), `tf_sustain` (W+Q poke on the pile with no
  R commit), and `tf_q_poke` (a Q-only chip when the rest is on CD).
- Flame Cloak offensive pre-amp on every burst path when Aghs is
  owned: the +35% spell amp + +35% magic resistance + uninterrupted
  movement for 7s is a kill accelerator, not a stack-conservation
  resource, so the brain fires it whenever a W+Q+R burst is about
  to commit. The +35% spell amp is also credited in the kill math:
  while the buff is up, the effective R hit and W+Q+R combo burst
  are scaled by x1.35 (stacking multiplicatively with an Ethereal
  resist-reduction), so the brain commits the kills it can actually
  secure with the buff on, not just the ones the un-amped burst
  would land.
- A teamfight-opener FC pre-amp at the first tick of a new
  engagement that pre-amps the W+R burst before the user's combo
  reaches the spells.

**Defense, always on, no key:**

- A fact-driven counter filter on every save chain. Each threat has
  a `THREAT_PROFILE` of Liquipedia + KV facts (damage school,
  spell-immunity piercing, dispel type, delivery, primary harm);
  `DeriveCounters` assembles those into `THREAT_COUNTER`, the set of
  save-kinds that actually counter the threat. At compose time
  `SaveCounters` filters the chain so a save is only offered when it
  genuinely counters what is incoming: no offering Eul against a
  spell-immunity-piercing grip, no offering a magic-resist item
  against pure damage. This is hero-agnostic and shared with the
  sister Sniper brain.
- A line-projectile intercept (`OnLinearProjectileCreate`): when a
  linear skillshot is created with Lina in its path (Pudge Hook,
  Mirana Arrow, Magnus Skewer, Clockwerk Hookshot), the brain
  displaces her out of the line before impact. The mechanism lives
  in the shared lib (`Defense.HandleLineProjectile` reading
  `ThreatData.LINE_PROJECTILE_INTERCEPTS`); the hero only wires the
  callback.
- A per-(target, canonical_mod, caster) dispatch lock that
  structurally prevents two saves from firing for the same threat.
  When the anim path fires Wind Waker against Spirit Breaker's
  Charge, the armed_threats_tick path's later attempt to fire
  Hurricane Pike sees `dispatch_blocked existing_save=wind_waker`
  and stops. See [Findings](#findings-and-hard-problems) for the
  story.
- Cast-point arming for `modifier_sniper_assassinate`,
  `modifier_lion_finger_of_death`, `modifier_lina_laguna_blade`,
  `modifier_ancient_apparition_ice_blast`,
  `modifier_obsidian_destroyer_sanity_eclipse`,
  `modifier_tinker_laser`, `modifier_zuus_thundergods_wrath`,
  `modifier_doom_bringer_doom`. Defenses fire at end-of-cast-point
  via chain-head ETA, not at modifier-create. Closes the "Lotus
  burned 2 seconds before Sniper's R lands" pattern.
- A Lotus-defer branch on Sniper Assassinate: when Lotus is on
  cooldown but recovers inside the 1.2s effective cast window, the
  brain arms a deferred Lotus fire instead of immediately walking
  the chain to BKB. Lotus reflects, BKB stays banked.
- An ally-save domain that is independent of the self-save domain
  (separate lock map). Lotus on self does not silence Glimmer on an
  ally for the same threat.
- A defensive Flame Cloak guard: FC fires defensively only when
  Lina is under 30% HP. The 50-mana + 25s-CD spell is reserved for
  clutch saves; healthy-Lina threats go to the next save in the chain.
  Within the 5s post-R Aghs-Shard window FC is demoted to chain
  tail (firing it would downgrade the 12-stack FS cap to 7).
- A panic-key bypass that drops both the dispatcher's reaction-window
  throttle and the per-threat lock for one save, so a user-driven
  panic frame is never silenced by a routine prior save against
  the same threat.

**Feedback:**

- A live status panel in the menu: current Layer 1 archetype,
  Fiery Soul stack count, cap window, last refused combo and why,
  and dispatcher lock state.
- A structured debug log for post-match review, at four verbosity
  levels.

## Installing

The brain is two parts that deploy together:

1. Copy `Lina/Lina.lua` into the framework's script directory.
2. Copy the `lib/` directory alongside it. The brain `require`s
   `lib.defense`, `lib.threat_data`, `lib.dedup`, `lib.native`, and
   the rest; without `lib/` it will not load.
3. Reload scripts. On load the brain prints a version banner to
   the debug log.
4. **Hand ability casting to the brain.** Open
   `Lina -> Main Settings` and turn **off every ability icon**
   there, both the row under `Hero Settings -> Abilities` and the
   row under `Kill Stealer -> Abilities`. A disabled icon shows
   red. This step is required: any ability left enabled lets the
   native script cast Dragon Slave / Light Strike Array / Fiery Soul
   / Laguna Blade / Flame Cloak on its own, racing the brain for
   the same spell.

Leave the rest of the native Lina script enabled. Items Settings,
Hit & Run, Orb Walker and Target Selection are the routine work the
brain delegates to and relies on; the brain only needs to be the
*sole caster of Lina's abilities*. It is a companion to the native
script, not a replacement (see [The augmentation model](#the-augmentation-model)).

## Using the brain

Everything offensive runs off one key. Defense needs no key and no
input.

**The combo key** (default Mouse5, rebindable in the menu):

- **Hold** it with **1-2 enemies** near Lina for the **Starter
  loop**. Each tick the brain re-reads the fight and picks one of
  the five burst archetypes.
- **Hold** it with **3+ enemies** near Lina for **Team Fight** mode.
  The mode is latched when you start holding, so one unit crossing
  the count boundary cannot flip the brain mid-combo.

Two more keys are unbound by default; set them on the Core page if
you want them:

- **Force-commit key**, hold it while pressing the combo key to make
  the brain commit even when the kill check would otherwise refuse.
- **Panic-save key**, press it to force the defense layer to fire
  its next save immediately, bypassing the reaction-window throttle
  and the per-threat lock for one frame.

### What to expect

- With the master toggle on and no input, the brain is **silent**.
  It acts only when you press the combo key or when a real threat
  appears.
- **Hold the key on a single target with W+R ready** , the burst
  archetype dispatcher picks the best W+Q+R order (`ether_wqr`,
  `eul_wrq`, `ww_wrq`, `wqr`, or `r_first_rwq`) based on which
  items / abilities the target is exposed to.
- **Hold the key with 3+ enemies clustered** , Team Fight mode
  picks an R target by scoring (lowest eff-HP, R-killable, no
  Lotus, no spell-deflect), pre-amps with Flame Cloak if Aghs is
  owned, then runs the W+Q+R commit.
- **Hold the key with nothing committable** , Q pokes the cluster
  at 5Hz, no wasted ultimate.
- **An enemy gap-closes, hard-disables, or ults you**, at any time
  with no key held , the defense layer fires the save that counters
  that specific threat, at the right moment (cast-point armed for
  delayed threats, immediate for instant-disable).
- **Lina is at 25% HP and a Sniper R is incoming** , defensive FC
  fires as part of the chain.
- **You are about to die and the save layer did not pick what you
  wanted** , tap the panic-save key.

The Diagnostics page carries a live status panel showing what the
brain is deciding, and when it refuses a combo, why.

## Menu settings

The brain's settings are under **Heroes -> Hero List -> Lina ->
Brain**, split across three pages.

### Core

| Setting | Default | Meaning |
|---|---|---|
| Enable Lina brain | on | Master toggle. When off the brain issues nothing and the native Lina runs alone. |
| Combo key | Mouse5 | Hold for the adaptive Starter / Team Fight loop. |
| Use Flame Cloak offensively | on | Enable the offensive FC pre-amp on starter and teamfight bursts. |
| Use Flame Cloak in sustain (opt-in) | off | Extend the FC pre-amp to `tf_sustain` (W+Q-only paths). Off by default; FC is normally reserved for kill-commits, not poke. |
| R commit floor | 100 (40-150) | Kill-value gate for Laguna Blade. 40 fishes for any kill, 100 is strict, 150 is conservative. |
| Force-commit key | unbound | Hold to force a burst when the kill check would refuse. |
| Panic-save key | unbound | Press to force the defense layer to fire its next save immediately. |

### Defense

| Setting | Default | Meaning |
|---|---|---|
| Enable auto-defense (Layer 2) | on | The always-on save layer: Lotus, BKB, Force, Pike, WW, Glimmer, Aeon, and FC as a low-HP backstop. |
| Auto-punish enemy channels | on | Auto-fire Laguna Blade or W on an enemy starting a channel or a teleport in range. |
| Pre-face imminent threats | on | Briefly rotates Lina to beat fast enemy cast points so an interrupt-style threat can be Q-stunned. |
| Lotus first vs single-target burst | on | Lotus is the chain head for Sniper-Assassinate-class threats. The Lotus-defer-if-close branch arms when Lotus is on CD but recovers within 1.2s of the cast point. |
| Save ally toggle | on | The ally-save layer (Glimmer, Lotus on ally, etc.) runs on its own lock domain, independent of self-save. |

### Diagnostics

| Setting | Default | Meaning |
|---|---|---|
| Log verbosity | 1 (0-3) | 0 silent, 1 decisions, 2 adds skipped decisions, 3 full trace. Written to the debug log. |
| Show raw-API debug panel | off | Extra read-only labels exposing raw framework reads. A research aid, leave off in normal play. |

The page also carries a live, read-only status panel: current Layer
1 archetype, Layer 2 last save, Fiery Soul stack count, cap window
(7 base, 12 in the 5s post-R Aghs-Shard window), dispatcher lock
state, and cooldown readiness.

## Repository layout

```
Lina/
  Lina.lua              the brain (one file, ~7k lines)
lib/                    shared Lua libraries (see "The library set")
tools/                  KV-data generators + log/test tooling
DEFENSE_CATEGORIES.md   threat-category -> save-chain mapping
API_GOTCHAS.md          UCZone API quirks found the hard way
API_REFERENCE.md        condensed API reference
```

The brain is deployed by copying `Lina/Lina.lua` (and `lib/` when a
library changed) into the framework's script directory. Source and
runtime are kept in sync; the repository is the source.

## Architecture

This section is the map. The brain itself is one file; reading it
end to end is the long form.

### The Layer 1 / Layer 2 split

- **Layer 1** is offensive: combo dispatch, archetype selection,
  per-step scheduler, fog snipe, kill-steal.
- **Layer 2** is defensive: the save chain, armed threats,
  cast-point armed-fires, anim subscribers, channel detection.

The split is not just code organization. They are separate
dispatcher state machines that hold separate locks, so an offensive
FC pre-amp and a defensive FC save against an incoming Sniper R
don't collide on FC's 25s cooldown; they go through the same
dispatch domain (per-(target, mod, caster) lock) with synthetic
mod keys for the Layer 1 use, and the lock decides who gets it.

### Starter archetypes

`starter_tick` is a per-tick situational appraisal. Each off-throttle
tick it re-reads the engagement and picks one archetype:

- **`ether_wqr`**, the W+Q+R burst with an Ether Blade pre-amp on a
  high-magic-resist target. Q drops the LSA stun, W cones into the
  cluster, R commits.
- **`eul_wrq`**, the W+R+Q burst with an Eul's Scepter setup on a
  high-mobility target. Eul self-disjoints, W rotates, R commits, Q
  closes.
- **`ww_wrq`**, the Wind Waker variant where WW is used offensively
  for a self-disjoint + reposition before the W+R commit. The
  dispatcher tracks WW's offensive use separately from its save use.
- **`wqr`**, the fast-cast W+Q+R when no item pre-amp applies.
- **`r_first_rwq`**, the R-first variant when R alone is lethal
  and the W+Q are follow-up cleanup.

A target that resists one archetype on this tick can be reclassified
next tick. Per-tick re-evaluation is the state machine.

### Team Fight

`teamfight_tick` runs three TF archetypes plus a pre-amp gate:

- **`tf_burst`**, the W+Q+R commit on a scored R-target inside the
  cluster.
- **`tf_sustain`**, W+Q poke on the cluster centroid with no R
  commit (saves R for the next kill window).
- **`tf_q_poke`**, Q-only chip when W and R are on CD.
- **`pre_tf_opener`** (the v0.5.39 BUG-1 addition), a Flame Cloak
  pre-amp fired before the user's combo reaches the W+R commit.
  Latched per-engagement (re-arms after a 4s tick gap), the brain
  fires FC as the first action of a new fight when W and R are
  ready, then the user's burst follows with +35% spell amp.

### Fiery Soul stack-aware

Lina's passive caps at 7 stacks base, 12 in the 5s post-R window
when Aghs Shard is owned. Several decisions key on stack state:

- **Q poke at cap**, `tf_q_poke` re-targets Q at the lowest-eff-HP
  enemy in Q range, not the cluster centroid, because at cap the W
  centroid wants the maximum stuns, not the maximum damage.
- **FC pre-amp gate**, `not ctx.fs_at_cap` (FC sets FS to 7, so at
  cap it's a no-op) and `not ctx.fs_shard_window` (FC would
  downgrade the 12-cap to 7).
- **Defensive FC chain demote**, when the dispatcher's
  `ResolveSaveOrder` receives `ctx.fs_shard_window=true`, the
  chain walker demotes `lina_flame_cloak` to the chain tail so
  BKB / Pike / Force fire before FC.
- **FC credited in the kill math** (v0.5.153), when Flame Cloak is
  active the kill predicates scale the effective R hit and W+Q+R
  combo by `ctx.fc_amp_mult` (`1 + 0.35`). The raw fields stay
  un-amped for display and non-kill readers; only the `*_eff`
  fields the commit gates compare against carry the +35%. It
  stacks multiplicatively with the Ethereal resist-reduction, so
  with the buff up the brain commits kills the un-amped burst
  would not have secured.

### Defense: anim + cast-point arming

Two detection routes feed one save dispatcher:

- **Anim route**, generated `Anim.Subscribe` handlers detect an
  incoming threat by its cast animation. The fast path: it reacts
  before the threat lands.
- **Modifier-create route**, `OnModifierCreate` resolves a threat
  from the modifier the ability puts on Lina.

For threats with non-trivial cast points (Sniper Assassinate 2.0s,
OD Sanity Eclipse 1.7s, Lion Finger 0.6s, Doom 0.5s), the dispatcher
arms a `castpt:*` entry in `state.armed_threats` and fires at the
end of the cast point via a chain-head ETA trigger, not at
modifier-create. So Lotus reflects Sniper's R when Sniper's R is
about to land, not 2 seconds beforehand.

### The per-threat dispatch lock

`lib/defense.lua` ships a Dispatcher that holds a per-(target,
canonical_mod, caster) lock map. When `defense_dispatcher:Dispatch`
fires a save, it takes the lock for a TTL computed by a per-mod ETA
resolver (Bara Charge's TTL is `distance / 600 + 0.3s`, Sniper R's
is `cast_point_remaining + 0.3s`, channel threats cap at
PERSISTENT_THREAT_TICK_INTERVAL - 0.1s so re-fire works). Subsequent
attempts on the same threat tuple see `dispatch_blocked` and stop.

`canonicalize_mod` folds sibling modifier names (Bara
`_vision`/`_target`/`_debuff` all map to the bare canonical) so the
anim path and the armed-tick path share the same lock key even when
they see different sibling spellings of the same threat.

The lock is the v0.5.40 work. Before it, the brain relied on a
hero-side `Dedup.threat_mark_responded` 2.0s window that was stamped
post-fire; the window expired on slow-travel threats (a 1500u Bara
charge takes >2s to arrive) and lost the race against same-tick
sibling fire paths. The lock is held for the threat's actual
resolution window and held atomically inside `Dispatch`.

### The threat-counter axis

Which saves are even eligible against a given threat is not
hand-listed; it is derived from facts. `lib/threat_data.lua` carries
a `THREAT_PROFILE` per threat modifier, a small bundle of
Liquipedia- and KV-grounded facts: damage school, whether it pierces
spell immunity, dispel type, delivery (spell / channel / attack /
projectile), the dominant harm (disable vs damage), and judgment
fields like `lotus_reflectable`. `ThreatData.DeriveCounters` runs
those facts through a fixed rule set at module load and assembles
`THREAT_COUNTER`, the set of save-*kinds* that actually counter each
threat. `ThreatData.SaveCounters(save, threat_mod)` is then a pure
set intersection of the save's kinds against the threat's required
kinds.

`ResolveSaveOrder` calls `SaveCounters` as a compose-time filter on
the item backbone, so a save is dropped from the chain whenever it
does not genuinely counter the incoming threat: no magic-resist item
against pure damage, no Eul against a spell-immunity-piercing grip,
no displacement against a threat flagged `blocks_forced_movement`.
The axis is hero-agnostic, the same profiles and rules serve the
sister Sniper brain, and it is fact-based rather than per-threat
hardcoded, so a corrected Liquipedia fact updates every chain that
touches that threat at once.

### Chain composition

`Defense.ComposeChain` builds a final save chain from a category
item backbone plus hero ability injections. The backbone is the raw
`TD.CATEGORY_CHAINS` entry for the threat's category; each injection
declares its anchor (`head`, `tail`, `{before=X}`, `{after=X}`) and
is spliced in, with a first-occurrence-wins dedupe. It is pure (no
engine calls, safe at load time) and used two ways: automatically by
`ResolveSaveOrder` for category-resolved threats, and directly by
the hero to build bespoke chains (Lina's committed-attacker
variants). The compose-time `SaveCounters` filter runs on the
backbone; hero ability injections are spliced after it and are never
filtered, because the hero vouches for its own abilities.

### Always-on ticks

Beyond the combo and defense layers, a set of ticks runs every
frame: armed-threat resolution (the homing branch for Bara/Tusk,
the cast-point branch for Sniper-class, the lotus-pending branch
for the Lotus-defer-if-close path), persistent-threat re-fire (Duel
/ Static Storm / Doom-debuff every 2.1s), the R-cast abort monitor
(re-issues R every tick until it locks, copying the native script's
own re-issue pattern), the Pike prime/re-issue tick (see the
post-mortem for the fresh-item engine quirk it works around), and
the deferred-step scheduler that handles per-step abort-on-cd /
abort-on-no-land.

### One hard constraint: the 200-locals limit

Lua 5.4 allows 200 local variables per function. The brain's main
chunk is near that ceiling. Every module-level function and
constant added after the limit was first hit is stored as a field
on one `state` table (`state.foo = function() ... end`), not as a
`local`. A table field does not consume a local slot. This is why
the code is full of `state.X` rather than plain locals; it is not
a style choice, it is the only thing that compiles.

## The library set

The brain sits on a set of hero-agnostic Lua libraries in `lib/`.
They split into tiers.

**Tier 1, event plumbing:** `order` (one validated chokepoint for
every order, with queue dedup), `damage` (recent-damage feed and
kill math), `anim` (enemy animation -> "they cast X" events),
`target` (composable unit predicates, including `IsUnkillableNow`,
the Shallow-Grave / False-Promise / WK-Reincarnation cannot-kill
gate), `native` (Hit & Run / Orb Walker pause/resume + reassert
wrappers).

**Tier 2, reasoning and data:** `threat_data` (the threat catalog:
per-threat `THREAT_PROFILE` facts, the `DeriveCounters`-assembled
`THREAT_COUNTER` map, the canonical-mod alias table, and the
line-projectile intercept catalog), `save_select` (scores and ranks
the saves a threat exposes, gated by the `SaveCounters` set
intersection so only genuine counters are ever offered), `defense`
(the dispatcher: per-(target, mod, caster) lock + chain compose +
chain walk + ETA resolution + line-projectile intercept + ally
domain), `item_saves` (the hero-agnostic defensive item save bodies,
one `.fire`-shaped builder per item that a hero merges into its own
save map), `dedup`, `geometry`, `signal`, `npc`, `timing`.

**Tier 3, positioning and capability:** `escape` (danger-aware
escape-destination picking: fog-aware push, safe-direction search,
and the turn-then-push harness Pike / Force / Eul self-casts share),
`farm` (stateless wave-clear geometry and a mana- and stack-aware
cast-worthiness policy for the AoE / line nukes).

**The KV-data libraries:** `item_data`, `ability_data`,
`unit_data`, `hero_data`. These are pure static reference,
*generated* from Valve's KV files. They are never hand-edited.

### Regenerating the data libraries after a patch

This is the most important maintenance operation, and it is one
command per library. Valve ships the game's authoritative numbers
as JSON KV files (`npc_heroes.json`, `npc_abilities.json`,
`npc_units.json`, `items.json`, `neutral_items.json`). The
generators in `tools/` read those and emit the corresponding lib:

```
gen_item_data.py     -> lib/item_data.lua
gen_ability_data.py  -> lib/ability_data.lua
gen_unit_data.py     -> lib/unit_data.lua
gen_hero_data.py     -> lib/hero_data.lua
gen_anim_maps.py     -> the animation-route maps
```

Each generator is the single source of truth for its output. After
a Dota patch: drop in the new KV files, re-run the generators, and
the libs are current. If a value in a generated lib is wrong, the
fix goes in the generator, never in the lib. This is the
difference between a catalog that rots over patches and one that
does not.

## Building, deploying, testing

The loop is: edit the source, syntax-check, bump the version
banner, deploy, play a bot match, read the log.

- **Syntax check:** `luac.exe -p Lina.lua`. Pure-data libs can
  also be exec-tested out of game with `lua.exe` and a
  `package.path` pointing at the repo.
- **Deploy:** copy `Lina.lua` (and changed libs) into the
  framework script directory. Source and runtime must stay
  identical.

### The version banner

The first line of `Lina.lua` is a `LOG:info(...)` call holding one
double-quoted string: the version number followed by an embedded
changelog. It prints on load. Because the banner embeds the
changelog, a `grep` of the debug log for the version pattern tells
you exactly which build actually ran. That matters: a stale log is
worthless as verification data, and confirming the banner is the
first step of every log review.

The banner is one single line, often several thousand characters.
It is edited with a literal string-replace from a script, not with
a text editor, because the line overflows ordinary editing tools.

### The debug log

The brain emits structured diagnostic events to the framework log.
The discipline that matters most:

- **`cast_verify` is ground truth for whether an ability fired.**
  It reads the ability's cooldown back after the cast point and
  reports `fired=y/n`. If you want to know whether a cast actually
  happened, this is the only event that knows.
- **`layer1_dispatch`, `layer2_save`, and similar are dispatch
  records, not fire proof.** They say the brain decided to do
  something. They do not say the engine executed it.

`combo_classify`, `starter`, `teamfight`, `armed_threat_fire`,
`lock_acquired`, `dispatch_blocked`, `cast_point_threat_armed`,
and `threat_unrecognized` round out the picture: what mode was
chosen, what the gates read, which save dispatched, which armed
slot fired, and which modifier names the threat catalog still does
not recognize.

## Findings and hard problems

This is the section to read if you are building anything that
drives a unit in this engine. None of it was obvious at the start.

### The double-fire problem and the dispatcher unification

For most of Lina's development, an incoming threat that had more
than one viable defense route through the brain would sometimes get
two saves fired against it. Spirit Breaker's Charge of Darkness was
the canonical case: the anim-route handler fired Wind Waker at
cast-start (the right call), and then around a second later the
armed_threats_tick homing-branch fired Hurricane Pike (also a
reasonable save in isolation), and Lina had spent two displacement
saves on one charge that one would have stopped.

The first round of fixes was per-threat. Each time a new dual-fire
case surfaced (Lion Finger, Sniper Assassinate, Lina Laguna), a new
hardcoded exclusion was added at the offending site. The fixes
landed in v0.5.21 through v0.5.39 and they worked, one at a time.
What they did not do was close the *class* of bug: every new
defense route added later inherited the same problem.

The v0.5.40 release pivoted to a structural fix. The dispatcher in
`lib/defense.lua` now holds a per-(target_idx, canonical_mod,
caster_idx) lock map. When any dispatch site (anim subscriber,
armed-tick branch, modifier-create handler, line-projectile
intercept) fires through `Dispatcher:Dispatch`, it acquires the
lock for the threat's actual resolution window. Sibling attempts on
the same threat see `dispatch_blocked existing_save=<short>` and
stop, without the brain having to know that two paths exist for the
same threat.

The lock key uses *canonical* modifier names because the engine
applies different sibling modifiers (Bara's
`_vision` and `_target` on the victim, `_debuff` on the caster) for
the same logical threat, and the anim path / armed-tick path can
see different siblings. A `CANONICAL_MOD_ALIASES` table in
`lib/threat_data.lua` collapses them, verified by VPK-grepping
`pak01_009.vpk` for each entry rather than guessing.

The lesson is the one the Sniper-side post-mortem points at from a
different angle: when the same class of bug keeps showing up at
different sites, the fix is structural, not per-site. Sniper's
chain-order-first-wins is one structural answer (it works because
Sniper has fewer fire paths). Lina's dispatcher lock is another
(it works because Lina has more, and the chain-order answer is
not strong enough on its own).

### The missing cfg.self_npc closure (a lesson about silent fallbacks)

The v0.5.40 release deployed with the dispatcher unification, and
the demo immediately showed the *same* double-fires the lock was
designed to close. Inspecting the log: `dispatch_blocked` count was
zero. Hundreds of `lock_key_unresolvable` tlogs at v=2.

The dispatcher's lock-key resolver returns nil when target,
canonical_mod, or caster is nil. On nil it emits a v=2 tlog and
falls through to the v0.5.39 unlocked path; this is deliberate, so
fog projectiles (caster unknown) and uncataloged threats don't hard-
crash the dispatch.

The compat wrapper around `TrySaveSelf` resolves `target_unit =
cfg.self_npc and cfg.self_npc() or nil`. The cfg passed to
`Defense.New` was missing the `self_npc` closure. Every legacy
fire route ran through the compat wrapper with `target_unit=nil`,
the lock-key resolver shrugged, and the dispatch ran unlocked.

One line:

```lua
self_npc = function() return state.self_npc end,
```

That was the entire structural fix from v0.5.40.0 to v0.5.40.1.

Two lessons sit underneath this. **First**, silent-fallback paths
in shared libraries are a maintenance hazard. The dispatcher's
nil-tolerant lock-key was the right design for the fog-projectile
case, but it turned a cfg-wiring miss into a silent regression.
Adding a v=1 (info-level) marker for "lock-key skipped on N
consecutive dispatches" would have surfaced this in the first
minute of the demo. **Second**, when a structural fix lands and the
class of bug it was supposed to close is still happening, the first
diagnosis to chase is "is the structural fix actually engaged",
not "is the design wrong".

### The HP API gotcha (Entity, not NPC)

While we are on UCZone API surprises: HP is on `Entity`, mana is on
`NPC`. The asymmetry is real. `Entity.GetHealth(unit)` and
`Entity.GetMaxHealth(unit)` are the accessors used at 8+ sites in
this brain and 15+ sites in the sister Sniper brain. `NPC.GetHealth`
does not exist; calling it throws `attempt to call a nil value
(field 'GetHealth')` at runtime.

The v0.5.40.1 hotfix added a defensive Flame Cloak HP gate that
used the obvious-looking `NPC.GetHealth / NPC.GetMaxHealth`. Lua's
short-circuit `and ... or 1.0` fallback masked the throw in the
"Lina nil/dead" path (the `or 1.0` consumed the false-from-short-
circuit), so the gate looked like it was firing in the demo log.
It wasn't. The "Lina alive" path threw, the chain walker bailed
inside the framework's pcall, and no save fired silently.

Loose rule for new code on this framework: if the property is a
world-object attribute (origin, HP, alive, index), look on
`Entity`. If it is a unit-level attribute (mana, abilities,
modifiers), look on `NPC`. Verify against the canonical pattern in
the existing brain before writing.

### Cast-point arming vs modifier-create timing

The natural-feeling place to fire a defense is `OnModifierCreate`,
when the engine puts the incoming threat's modifier on Lina. For
fast threats (Lion Voodoo, Disruptor's silence, basically the
instant-disable class), this is correct: there is no pre-impact
window, the threat is on you the moment the modifier appears, fire
the save now.

For threats with cast points, this is too early. Sniper's
Assassinate has a 2.0s cast point. If you read the modifier on
*cast-start*, fire Lotus at modifier-create, the reflect is
*gone* by the time the bullet arrives 2.0s later. The player
watches Lotus pop, then dies to a Sniper R 1.8s later with no save
on cooldown.

The v0.5.39 BUG-3 work added a `CAST_POINT_THREATS` catalog and a
deferred-fire branch in `armed_threats_tick`: cast-pointed threats
arm a `castpt:*` entry at modifier-create, then fire when chain-head
SAVE_ETA_TRIGGER (typically 0.5s before impact) triggers. For
Sniper R, that's at `cp_remaining ~0.5s`, so Lotus reflects with
0.5s of margin and is correctly burned on a real cast.

The catch was deciding which threats are "cast-pointed enough" to
defer. The current catalog: Sniper Assassinate, Lion Finger, Lina
Laguna, AA Ice Blast, OD Sanity Eclipse, Tinker Laser, Zeus Wrath,
Doom. Each has a measured cp_default and a max_dist gate (so
out-of-range casts don't fire saves we'll need elsewhere). New
threats need a catalog entry and a re-test, not a code-path
modification.

### Aghs-Shard, Flame Cloak, and the cap downgrade

Lina's Fiery Soul caps at 7 stacks. With Aghs Shard, after she
casts Laguna Blade, the cap rises to 12 for 5 seconds (the
`modifier_lina_laguna_super_charged` window). Inside that window
each kill adds stacks toward 12, instead of being capped at 7.

Flame Cloak sets Fiery Soul to 7 outright. It is non-additive: it
*replaces* the current stack count with 7. Outside the shard
window this is fine (FC fired at FS=3 brings FS to 7, gain of 4).
Inside the shard window it is a downgrade: FC fired at FS=11 brings
FS to 7, you have just thrown away four attack-speed + move-speed
stacks for the FC's +35% spell amp.

The fix is two-part. The offensive FC sites (starter pre-amp,
TF-opener, TF-burst) all gate on `not ctx.fs_shard_window`, so the
brain refuses to fire offensive FC inside the post-R window. The
defensive FC fire (`SAVE_FIRE.lina_flame_cloak`) returns false
inside the window, which makes the chain walker advance past FC to
the next save (BKB / Pike / Force / Glimmer). The dispatcher's
`ResolveSaveOrder` *also* demotes `lina_flame_cloak` to chain tail
when `ctx.fs_shard_window` is set, so the demotion happens before
the per-save `.fire` closure even runs. Defense in depth.

### The fresh-item engine quirk

The engine silently drops the *first* cast of a freshly-acquired
item. The order is well-formed, it reaches the engine intact, and
nothing happens. Second and later casts work. One cast "breaks the
item in".

The workaround is two-part. *Prime*: when Lina owns the item, it
is un-used, and she is safe, the brain fires one throwaway cast to
spend the doomed first attempt while it costs nothing. *Double-issue*:
if a real save needs the item before it was primed, the brain
re-issues it one frame later, so the second (landing) cast covers
the save. A freshly-bought save item cannot be trusted for its
first save; plan for that.

This is the same engine quirk Sniper documents and works around.
Lina's `pike_prime_tick` is the equivalent of Sniper's prime/re-
issue tick. If you build a new hero, copy the pattern, do not try
to derive it from first principles.

### Per-threat ETA-based lock TTL

The dispatcher lock holds for a TTL computed per-threat by an
`eta_resolver` table. Bara's resolver is `distance / 600 + 0.3s`,
Sniper's is `cast_point_remaining + 0.3s`, Lion Voodoo's is
`modifier_remaining or 0.5s`. Persistent threats (Duel, Static
Storm, Doom debuff) cap the resolver output at 1.9s so the lock
TTL (eta + 0.3s buffer = 2.2s) fits *inside* the persistent re-fire
interval of 2.1s, which lets the next periodic re-tick re-acquire
the lock without an explicit force-release.

The first design used a fixed 2.0s window matching the legacy
dedup. That window was wrong for two cases. For fast threats (Lion
Voodoo, ~0s ETA), the lock would silence subsequent kosher saves
for 1.7s of dead time. For slow threats (Sniper R from 3000u, ~2s
ETA), the lock would *expire* before the threat arrived, exactly
the failure the design was supposed to close. ETA-based, with the
persistent-class cap, is the shape that works.

### The KV-derivation principle

Valve's KV data is authoritative and it does not rot. Hand-
maintained catalogs do: a hardcoded per-level damage table, a
guessed cast range, a copied cooldown all silently drift the first
time a patch changes them.

So anything that can be derived from KV is generated or read live,
never hand-maintained. The data libraries are generated. Magnitudes
that mirror a KV field are read from a generated lib, not typed as
literals. The few genuine literals that remain are the ones with
no KV source (a projectile speed Valve does not expose, a heuristic
damage estimate), and each is commented as such so it is not
"migrated" by mistake.

### Modifier names cannot be derived

The one hard wall. `npc_abilities.json` exposes ability names,
behaviors, damage, cooldowns, cast ranges, and AbilityValues. It
does *not* expose the names of the modifiers an ability applies. A
threat catalog keyed on modifier names therefore cannot be
generated; `modifier_<ability>` is a convention guess.

The brain handles this by logging every unrecognized modifier that
lands on Lina (`threat_unrecognized`) and correcting the guesses
from real matches. The deeper fix is design, not data: prefer
keying logic on the ability name (which is KV-authoritative) over
the modifier name (which is a guess). The defense layer's anim
route does exactly that; the modifier-create route is the fallback.

The v0.5.40 alias catalog (`CANONICAL_MOD_ALIASES`) handles the
related problem of one logical threat shipping multiple sibling
modifiers. VPK-grep each candidate to confirm the engine actually
ships it before adding an alias entry, do not trust intuition about
modifier names.

## Conventions

A few rules that are not obvious from the code:

- New module-level functions and constants are `state.X`, never
  `local X` (the 200-locals limit, above).
- Generated files are never hand-edited. Change the generator,
  re-run it.
- One behavioral change per version, and each version bumps the
  banner.
- The version banner is one long single-line string and is edited
  with a literal replace from a script, not a text editor.
- Coordinates are formatted with `%.0f`, not `%d`; they are floats.
- Comments explain *why*, and they are written for the next
  maintainer.
- Modifier names that go into a catalog are VPK-verified before
  the entry lands; the `dota_modifier_test apply <name> <duration>`
  console command is the fallback for items with no KV-registered
  name.

## Where to read more

- `DEFENSE_CATEGORIES.md`, the threat-category to save-chain mapping
  the dispatcher consults.
- `API_GOTCHAS.md`, every UCZone API quirk found the hard way, with
  the symptom and the fix.
- `API_REFERENCE.md`, the condensed, brain-task-organized API
  reference.
- `tools/README.md`, the KV generators and the log/test tooling.
- [sniper-hero-brain](https://github.com/PirucaxD/sniper-hero-brain),
  the sister project. Most architecture patterns originated there;
  this brain is the second hero to confirm the shape, and its
  README carries the longer-form treatment of the offensive combo
  and defensive save-layer patterns.
- [uczone-toolkit](https://github.com/PirucaxD/uczone-toolkit), the
  upstream MIT-licensed `lib/` source.
