# Lina , Liquipedia ability reference

**Source:** https://liquipedia.net/dota2/Lina (the AUTHORITATIVE source)
**Fetched:** 2026-05-27
**Patch:** 7.41c

> **KV-verified corrections (2026-05-28).** Live KV
> (`C:\Umbrella\assets\data`) is runtime truth. Where this snapshot
> differs, the brain (which reads values live) uses KV. Authoritative
> correction record: `notes.md` Phase A. Key deltas applied below:
> Aghs ability is `lina_flame_cloak` (not `lina_supercharged_soul`);
> Eul's item is `item_cyclone` (not `item_eul_scepter`); Scepter item
> is `item_ultimate_scepter`. W damage 80/120/160/200, R damage
> 380/565/750 (wiki shows the older 80/125/170/215, 400/580/760).
> Ethereal applies -30 target magic resistance, not a flat amp.
> Special-value key names corrected in
> the integration block. `lina_combustion` is an undocumented KV
> innate (verify in-demo, not baked into kill math).

**Liquipedia is the authoritative source for Lina's kit.** It is the
community-maintained wiki kept current with each Dota 2 patch. When
secondary guides (DotaCoach, DotaFire, Strafe, bo3.gg, forum write-ups,
YouTube transcripts) disagree with Liquipedia, **Liquipedia wins
automatically**. Do not adopt secondary claims unless they can be
verified against Liquipedia and / or the live KV data.

This file is the cross-reference for brain code that depends on Lina ability
mechanics. Update when patch notes change Lina. Keys to check: W effect delay
(0.5s, the cyclone-exit timing window), R press-to-damage (0.55s: 0.3 cast
point + 0.25 effect delay; the 0.4 back-swing is post-cast animation only,
does NOT gate damage), Fiery Soul max stacks (7 base / 12 with Shard), Flame
Cloak unlock requires Scepter.

The brain reads ability values LIVE via the UCZone API
(`Ability.GetLevelSpecialValueFor`, `Ability.GetCastRange`,
`NPC.GetModifierStackCount`, etc.) , the tables below are the verification
baseline. When live KV and this Liquipedia snapshot disagree, prefer KV for
runtime correctness (the engine reads KV) but treat Liquipedia as the
intent reference (Valve sometimes ships KV bugs Liquipedia documents as
the intended value). Flag any discrepancy in code comments.

---

## Hero meta

| Field | Value |
|---|---|
| Primary attribute | Intelligence (30 + 4/level) |
| Base strength / agility / intelligence | 20 / 23 / 30 |
| Strength / Agility / Intelligence gain | +2.4 / +2.4 / +4.0 per level |
| Base health | 560 |
| Base mana | 435 |
| Health regen | +2.25 base |
| Mana regen | +1.5 base |
| Base damage | 51-59 (avg 55) |
| Base attack time | 1.6 (100 attack speed = 0.625 attacks/sec base) |
| Attack range | 670 (ranged) |
| Projectile speed | 1000 |
| Base armor | 3.83 (688.69 EHP physical) |
| Magic resistance | 28% (777.78 EHP magical) |
| Movement speed | 290 |
| Turn rate | 0.6 (slow) |
| Vision (day / night) | 1800 / 800 |
| Collision / bound radius | 27 / 24 |
| Complexity | 1 (basic) |
| Roles | Support, Carry, Nuker, Disabler |

**Brain implications:**
- **Slow turn rate (0.6)** , Lina is sluggish at re-orienting; cast-direction
  decisions (W placement, R target switching) should account for turn time.
  Sniper's `pre_face_tick` pattern is worth porting.
- **Squishy** , 560 base HP plus low armor. Defensive Layer 2 must fire
  earlier and more conservatively than on Sniper.
- **670 attack range** , short for a ranged hero. Brain should not rely on
  attack-range "kite" patterns the way Sniper does.

---

## Dragon Slave (Q)

| Field | Value |
|---|---|
| Type | Point / unit target spell |
| Cast animation | 0.35 + 0.38 back-swing |
| Cast range | 1075 (affected by cast-range bonuses) |
| Effect radius (initial / end) | 275 / 200 |
| Travel distance | 1075 |
| Max effective reach | **1275** (cast range + end radius) |
| Projectile speed | 1200 |
| Time to full distance | ~0.9s |
| Cooldown | 11 / 10 / 9 / 8s (level 10 LEFT talent: 8 / 7 / 6 / 5) |
| Mana cost | 100 / 110 / 120 / 130 |
| Damage (magical) | 65 / 125 / 185 / 245 |
| Dispel | n/a (direct damage) |
| Pierces debuff immunity | NO |
| Pierces spell block | YES |
| Reflected by spell reflection | NO (does not proc reflect) |

**Brain implications:**
- **Lead-target math**: projectile speed 1200u/s. At 1075u cast range a fully
  travelling Q takes ~0.9s end-to-end. Lead the target by
  `target_pos + target_velocity * 0.9` when casting at max range.
- **Effective reach 1275u** beats the cast range , Q can hit targets just
  past Lina's 1075u cast distance if their position falls within the 200u
  end radius. Don't gate Q dispatch on a strict 1075 check.
- **Reversed-cone AoE** (275 initial → 200 final) means the wave is widest
  near Lina. For multi-target hits, casting in the direction of the densest
  cluster + slightly short of full range maximizes hit count.
- **One Fiery Soul stack per enemy hit per cast** , a Q that clips three
  creeps adds three stacks. Useful for stack-building during the lane.
- **Applies Slow Burn** (innate) , every Q adds a 4s DoT worth `Q_damage *
  0.64 / 4 per second` (additional ~10/20/30/40 magical DPS depending on
  level, doubled to 20/40/60/80 with 25-LEFT talent).
- **Cooldown talent at level 10 LEFT** drops CD to 8/7/6/5s. Brain should
  re-read `Ability.GetCooldown(Q, true)` after talent picks rather than
  hardcoding 11/10/9/8.

---

## Light Strike Array (W)

| Field | Value |
|---|---|
| Type | Area target |
| Cast animation | 0.45 + 0.67 back-swing (alt: 0.45 + 0.43) |
| Cast range | 700 |
| Effect radius | 250 |
| **Effect delay** | **0.5 seconds** (visual + audio only visible/audible to allies) |
| Max reach | 950 (cast range + effect radius) |
| Cooldown | 13 / 11 / 9 / 7s |
| Mana cost | 100 / 110 / 120 / 130 |
| Damage (magical) | 80 / 120 / 160 / 200 (KV runtime; wiki shows 80/125/170/215) (level 15 LEFT talent +110: 190 / 230 / 270 / 310) |
| Stun duration | 1.2 / 1.6 / 2.0 / 2.4s |
| Dispel | Strong dispel only (stun) |
| Tree destruction | Yes (during the 0.5s delay) |
| Pierces debuff immunity | NO |
| Pierces spell block | YES |

**Brain implications:**
- **0.5s effect delay is the central timing primitive.** Cast W now → stun
  applies in 0.5s. The canonical Eul combo schedules W to cast at
  `eul_cast_t + 2.0s` so the stun lands at `eul_cast_t + 2.5s` (cyclone
  end). This delay is what makes lead-prediction critical: a target running
  290+ MS will move 145u during the 0.5s window , outside the 250u radius
  if cast point-blank, sometimes outside even at edge-of-radius.
- **Lead math**: place W at `target_pos + target_velocity * (cast_point +
  0.5)` to stun a moving target. Use Sniper's `Geom.lead_target` helper
  with `t = 0.95s` (cast point 0.45 + delay 0.5).
- **Only allies see the warning circle** , enemies have no visual cue
  during the 0.5s delay (other than the audio). Cast in fog or on an
  unsuspecting target = guaranteed stun.
- **Max reach 950u** , cast at 700 max + radius 250 means W can stun a
  target at 950u Lina-distance if Lina aims at the boundary correctly.
- **Tree destruction during delay** , Lina can clear a small tree wall
  before stunning. Niche but useful.
- **Strong-dispel-only** , Eul's, Manta, BKB, etc. clear the stun. Aeon
  Disk (basic-dispel) does NOT clear LSA stun.

---

## Fiery Soul (E)

| Field | Value |
|---|---|
| Type | Passive |
| Max stacks (base) | **7** |
| Max stacks (with Aghs Shard, 5s window post-R) | **12** |
| Stack duration | 18 seconds (refreshes ALL stacks on new gain) |
| Attack speed per stack | 8 / 16 / 24 / 32 (level 20 LEFT talent: 18 / 26 / 34 / 42) |
| Movement speed per stack | 1% / 1.5% / 2% / 2.5% (level 20 LEFT: 2 / 2.5 / 3 / 3.5%) |
| Magic resist per stack (level 15 RIGHT talent ONLY) | +5% |
| Stack source | Dragon Slave, Light Strike Array, Laguna Blade, Flame Cloak (Scepter), and any drafted ability in Ability Draft |
| Break-disableable | YES (existing stacks remain frozen; no new stacks while broken) |

**Brain implications:**
- **THE STACK REFRESH BEHAVIOUR is the design key.** A new stack gain
  refreshes the DURATION of ALL existing stacks (not just the new one).
  Continuous casting maintains stacks indefinitely. The pro pattern of
  cycling Q + W on cooldown produces near-permanent 7-stack uptime in a
  sustained fight.
- **Live stack count via API**:
  `NPC.GetModifierStackCount(me, "modifier_lina_fiery_soul")`. Use this in
  decisions like "fire Flame Cloak when stacks < 4 to refresh to 7" or
  "skip a non-essential spell if stacks are already at 7 and target is
  almost dead , don't waste mana refreshing".
- **Stack triggers**: Q, W, R, Flame Cloak. NOT item abilities, NOT
  0-cooldown abilities, NOT proc abilities. The brain's stack-building
  archetype (`combo_sustain_qw`) should explicitly count Q + W as the
  stack sources; R is incidental during the combo.
- **AS amplification at max level (32/stack)**: 7 stacks = +224 attack
  speed, 12 stacks (Shard window) = +384. That's near-cap AS. Chase autos
  with Fiery Soul are devastating; the brain should consider "build stacks
  + chase with autos" as a real combat strategy, not just spell burst.
- **+5% magic resist per stack (level 15 RIGHT talent)** , at 7 stacks
  that's +35% magic resist on top of base 28%. Combined with Flame Cloak's
  +35% it stacks toward survivability. If the user picks this talent the
  brain's defensive math should re-read live magic resist.
- **Break disables it** , Silver Edge break, Doom's Doom, Viper's Nethertoxin
  level 4 all freeze stacks. Brain should query `NPC.HasState(me,
  Enum.ModifierState.MODIFIER_STATE_PASSIVES_DISABLED)` before relying on
  stack growth.

---

## Laguna Blade (R)

| Field | Value |
|---|---|
| Type | Unit target (single enemy) |
| Cast point | **0.3s** (lock-in window; R cannot be cancelled after this) |
| Cast back-swing | 0.4s (post-cast animation; does NOT gate damage; Lina is free to move/cast at +0.3s) |
| **Effect delay (post-cast)** | **0.25s** |
| **Total press-to-damage** | **0.55s** (0.3 cast point + 0.25 effect delay) |
| Cast range | 750 (affected by cast-range bonuses) |
| Cooldown | 70 / 60 / 50s (level 20 RIGHT talent: 50 / 40 / 30) |
| Mana cost | 150 / 300 / 450 |
| Damage (magical, spell damage) | 380 / 565 / 750 (KV runtime; wiki shows 400/580/760) |
| Target restrictions | Cannot target Couriers |
| Dispel | n/a (direct damage) |
| Pierces debuff immunity | NO (target with BKB takes 0 damage) |
| Spell-blocked by Linkens | YES |
| Reflected by Spell Reflection | YES |

**Brain implications:**
- **0.55s total press-to-damage** (0.3 cast point + 0.25 effect delay)
  is the vulnerability window. The 0.4 back-swing comes AFTER the cast
  resolves and is purely animation , Lina can move or cast again the
  instant the cast point ends at +0.3s. During the 0.55s window the
  target can blink, Eul-self, BKB, Manta-dispel, or simply move out of
  LoS , any of these dodges R entirely. Sniper's R-abort pattern
  (`Ability.IsInAbilityPhase(R)` + abort conditions + `DOTA_UNIT_ORDER_STOP`)
  applies on a much tighter window than Sniper's 2.0s R cast.
- **Abort window practically is 0.3s** (the cast point). Once cast point
  ends, R is committed , only target-side dodges (BKB during the 0.25s
  effect delay) can save them. Brain's abort decision must fire inside
  the 0.3s window.
- **Spell Block (Linkens) eats R completely.** A pre-R Linken-breaker step
  is mandatory if target has Linkens active. The Sniper `BreakLinkens`
  helper carries over directly. Brain should query
  `NPC.IsLinkensProtected(target)` before R commit and route to break-then-R
  if true.
- **Spell Reflection (Lotus Orb, Spiked Carapace)** sends R back at Lina.
  Lina has 28% base magic resist , eating a reflected 580-damage R is ~417
  damage, on a 560-base-HP hero, often lethal. Brain MUST gate R commit on
  `NPC.HasModifier(target, "modifier_item_lotus_orb_active")` and similar.
- **Magic immunity = 0 damage.** Cheap mistake. Gate via
  `NPC.HasState(target, Enum.ModifierState.MODIFIER_STATE_MAGIC_IMMUNE)`.
- **750u cast range, no global** , Lina cannot save allies from across the
  map the way Sniper can. The TAP-style "press once to save ally" use case
- **Talent at 20 RIGHT** drops CD to 50/40/30s. Substantial uptime gain;
  brain should re-read live CD via `Ability.GetCooldown(R, true)`.

---

## Innate , Slow Burn

| Field | Value |
|---|---|
| Type | Passive on ALL spells (Q + W + R) |
| Impact-to-DPS conversion | 0.64 (level 25 RIGHT talent: 0.8) |
| Debuff duration | 4 seconds (level 25 RIGHT talent: 5) |
| Damage type | Magical, spell damage |
| Tick rate | 1-second intervals, starts +1s after debuff applied |
| Total spell damage multiplier | **1.64x** (1.8x with talent) , applied before magic reduction |
| Break-disableable | NO (innate) |
| Hidden modifier | `modifier_lina_slow_burn_intrinsic` (undispellable) |
| Debuff modifier | `modifier_lina_slow_burn` (only dispellable by death) |

**Brain implications:**
- **Every spell does 1.64x its raw damage** for the purposes of kill math.
  A 245 raw Q + 215 raw W + 760 raw R = 1220 raw. With Slow Burn the
  effective magical damage is **1220 * 1.64 = 2001** before magic reduction.
  Brain kill-math (`r_alone_kill`, `setup_kill` checks) must include this
  multiplier or the brain will under-estimate burst.
- **The DoT lingers 4s after impact** , a target that survived the burst
  by 200 HP often dies to the residual DoT 2-3 seconds later. Brain's
  `r_kill_steal` predicate should check `target_eff_hp <= r_dmg +
  slow_burn_pending_dot` not just R damage alone.
- **The DoT modifier is undispellable except by death.** A target that
  ate a Q + LSA + R is in trouble for 4s no matter what they do (short of
  Aeon-disk → Manta → BKB combos).
- **Level 25 LEFT talent adds a crit debuff** , `modifier_lina_crit_debuff`
  on Slow Burn-affected enemies makes Lina's auto-attacks deal 150% damage.
  This is the chase-with-autos finisher. If the user takes this talent the
  brain should switch chase-archetype priority: don't waste mana on Q for
  chip, just auto-attack a Slow-Burn-debuffed target for guaranteed crits.
  Query `NPC.HasTalent(me, "special_bonus_unique_lina_3")` (verify exact
  name in KV).

---

## 7.41C item build (NOT from Liquipedia , from pro-build sources)

Liquipedia's overview page does not list item synergies. The
following is sourced from dotacoach.gg + dota2protracker.com +
zathong.com for 7.41C:

**Core items (in approximate buy order):**

1. **Bottle / Iron Branches / Faerie Fire / Tango / Observer Ward**
   , lane sustain.
2. **Null Talisman / Magic Wand / Boots of Speed** , early stats.
3. **Bottle** (if mid) + **Kaya** , spell amp + Lina's primary
   damage scaling.
4. **Aghanim's Scepter** , grants Flame Cloak (4th ability). The
   user's main mid-game power spike.
5. **Boots of Travel** , global presence.
6. **Yasha and Kaya** , move speed + spell amp + status resist.
7. **Blink Dagger** , positioning for the W setup combo.
8. **Ethereal Blade** , single-target setup item. Sets target
   ethereal for 4s (physical-immune, cannot attack), slows 80% MS,
   and **reduces the target's magic resistance by 30** during ethereal
   (KV ethereal_damage_bonus -30, a subtractive resist reduction not a
   flat amp; Liquipedia "Magic Resistance Reduction 30%"; cast point 0,
   CD 22, mana 100). This
   replaces Eul's Scepter as the canonical Lina setup item in
   7.41C.

**Pro deviations / extension items:**
- Black King Bar (anti-disable / counter-initiate).
- Aeon Disk (anti-pickoff at HP threshold).
- Octarine Core (cooldown reduction; combos with R-CD talent).
- Aghanim's Shard (Laguna sets Fiery Soul to 12 for 5s).
- Wind Waker (3s self-cyclone save; replaces Eul's defensive role).
- Hurricane Pike, Force Staff, Sheepstick (situational).
- Bloodstone (mana sustain; lower priority than Kaya/YK/Blink).

**Notable absence vs older patches:** Eul's Scepter of Divinity is
NOT in the 7.41C core. Older guides describe an "Eul cyclone -> W
-> R -> Q" combo as the canonical Lina opener; this is **stale
for 7.41C**. The current canonical setup uses Ethereal Blade.

### Aghs on Laguna Blade , does NOT change damage type

User-confirmed and Liquipedia-confirmed: Aghanim's Scepter on
Lina grants ONLY Flame Cloak (the 4th-slot self-buff ability).
**Laguna Blade remains magical damage regardless of Aghs
ownership.** Secondary sources (dotacoach.gg) that claim Aghs
converts Laguna to pure damage are wrong for 7.41C.

Implication for the combo: Ethereal Blade's -30 magic-resistance
reduction boosts Q, W, AND R during the 4s ethereal window. No
Aghs-conditional pairing logic needed in the brain. R damage is
always magical, always benefits from Ether.

---

## Aghanim's Scepter , Flame Cloak (4th ability slot)

| Field | Value |
|---|---|
| Type | Instant cast, self-buff |
| Cast time | 0 + 0 (truly instant) |
| Cooldown | 25s |
| Mana cost | 50 |
| Duration | 7 seconds |
| Magic resistance bonus | +35% |
| Spell amplification | +35% (additive with other generic spell amp) |
| Sets Fiery Soul stacks to | 7 |
| Pathing | Unobstructed movement + flying (no flying vision) |
| Z-axis ascend | 100u, transition ~0.29s |
| Interrupts own channels | YES (cast cancels Lina's active channels) |
| Dispel | Undispellable (KV SpellDispellableType NO) |

**Brain implications:**
- **Massive offensive AND defensive cooldown.** +35% spell amp on a 245 Q
  + 215 W + 760 R = +427 raw damage in the 7-second window. +35% magic
  resist takes Lina's effective magic resist from 28% to **51.25%** (base
  formula: 1 - (1 - 0.28)(1 - 0.35) = 0.532, so ~53.2% reduction). Stacked
  with Aghs Shard / Glimmer / Pipe this approaches magical-immune.
- **Sets Fiery Soul to 7** , instant max-stack refresh. Use as the
  "go-time" trigger: cast Flame Cloak just before the burst combo, get 7
  stacks of AS + the 35% spell amp + the 35% magic resist + the flying
  pathing for repositioning. The pro pattern is to OPEN with Flame Cloak
  if it's ready, then Eul → W → R → Q.
- **Brain archetype `combo_flame_cloak`** fires when Lina is committed in
  a fight AND Flame Cloak ready AND stacks < 4 (to refresh). Independent
  of combo_key , auto-fire because the AS/MS boost benefits Lina's general
  combat output even without the user holding the key.
- **Interrupts own channels** , if Lina is mid-TP, mid-Manta-channel,
  mid-Spirit-Vessel-channel etc., casting Flame Cloak breaks it. Brain
  should not auto-cast Flame Cloak during Lina-side channels. Query
  `NPC.IsChannellingAbility(me)`.
- **Z-axis flying (pathing only)** lets Lina path over trees, cliffs, and
  unit collision for 7s. Combined with the +35% spell amp this is a
  team-fight initiation tool. The brain has limited use for this
  programmatically , the user controls positioning.
- **Live availability check**:
  `NPC.HasScepter(me) and Ability.IsReady(flame_cloak_ability)`. The 4th
  ability slot index is variable; look up by name
  `lina_flame_cloak` (verify KV) not by slot index.

---

## Aghanim's Shard , Laguna Blade enhancement

| Field | Value |
|---|---|
| Effect | Laguna Blade sets Fiery Soul to **12 stacks** for **5s** post-cast |
| Buff modifier | `lina_laguna_super_charged` (verify exact name) |
| After buff expires | Stacks reduce back to 7 |
| Interaction with Flame Cloak | Shared max-stack priority; either can override the other |

**Brain implications:**
- **12 stacks of Fiery Soul at level 4 E = 384 attack speed + 30% MS for 5s.**
  This is the "supercharge chase" window the user described. After R lands,
  Lina has 5 seconds of near-cap AS to follow up with autos. Brain logic
  should switch to auto-attack-pursuit mode for 5s after every R cast on a
  surviving target (the R didn't kill, but the buff is up , chase to
  finish).
- **Live shard check**: `NPC.HasShard(me)`. The 12-stack burst only fires
  when shard is owned; brain's chase-archetype math should split between
  "with shard: 5s of 384 AS" and "without shard: stack-cap at 7 for 224 AS".

---

## Talents

| Level | LEFT | RIGHT |
|---|---|---|
| 10 | +25 Attack Damage | -3s Dragon Slave cooldown |
| 15 | +110 Light Strike Array damage | +5% Fiery Soul magic resist per stack |
| 20 | +10 Fiery Soul AS per stack; +1% MS per stack | -20s Laguna Blade cooldown |
| 25 | +150% crit on Slow Burn-affected units (3s debuff) | +0.16 Slow Burn factor; +1s duration |

**Brain implications:**
- **Level 10 LEFT (+25 AD)** boosts auto-attack damage by ~50% (base 51-59 +
  25 = 76-84). Chase-with-autos archetype gets stronger.
- **Level 10 RIGHT (-3s Q CD)** drops Q to 8/7/6/5s. Stack-building cycle
  much tighter; brain's `combo_sustain_qw` should re-tune the cycle
  interval.
- **Level 15 LEFT (+110 LSA damage)** turns W into a 190-325 damage stun
  spell instead of 80-215. W becomes a real burst tool, not just setup.
- **Level 15 RIGHT (+5% magic resist per Fiery Soul stack)** is the
  survival talent , 7 stacks = +35% magic resist on top of base. Brain
  defensive math (incoming-damage prediction) should account for it.
- **Level 20 LEFT (+10 AS per stack, +1% MS per stack)** is the
  chase-pattern talent , 7 stacks of base 32 + 10 = 42 AS each, total
  +294 AS at cap. Chase autos dominate kills.
- **Level 20 RIGHT (-20s R CD)** drops R to 50/40/30s. The R-finisher
  archetype becomes far more available. Brain should re-read live CD.
- **Level 25 LEFT (auto-crit on Slow-Burn-affected)** is the
  chase-finisher game-winner. Slow Burn + auto crits at 150%. Brain's
  chase archetype should explicitly track which targets have the Slow
  Burn debuff and prioritize auto-attacking them.
- **Level 25 RIGHT (+0.16 Slow Burn factor, +1s duration)** raises the
  spell damage multiplier from 1.64x to 1.8x and extends DoT from 4s to
  5s. Brain kill-math must update the multiplier when this talent is
  detected.

---

## Facets / Aspects

**Not listed on the Liquipedia page at fetch time (2026-05-27).** The page
notes it is current to 7.41c. Verify against `npc_heroes.json` Facets array

---

## Item synergies, skill build, strategy, patch history

**Sections not present on the overview page.** Liquipedia has subpages
(`/Lina/Matches`, `/Lina/Lore`, `/Lina/Changelogs`) that may carry detail.
Phase A research tasks A5 / A5b cover the strategy and pro-build research
via DotaBuff / D2PT / Strafe.

---

## Modifier-name catalog (for brain code)

These are the modifiers the brain reads via `NPC.HasModifier` /
`NPC.GetModifierStackCount`. Verify exact names in the live game , the
naming convention for Lina has been stable but a patch could rename.

| Modifier | Source | Where used |
|---|---|---|
| `modifier_lina_fiery_soul` | E passive stacks | Stack count for AS/MS chase math |
| `modifier_lina_slow_burn` | Q / W / R impact (innate) | Slow Burn DoT tracker on enemies |
| `modifier_lina_slow_burn_intrinsic` | Innate passive on self | Confirms Slow Burn is active (always) |
| `modifier_lina_crit_debuff` | Level 25 LEFT talent on Slow-Burn-affected enemies | Crit-target marker for chase autos |
| `modifier_lina_laguna_super_charged` | Aghs Shard buff after R | 12-stack window detection |
| `modifier_lina_light_strike_array_stun` | W stun | Confirms target is W-stunned |
| `modifier_lina_flame_cloak` (Flame Cloak) | Aghs Scepter ability buff | Flame Cloak active marker |

**Note:** these names need verification by reading them in a live
`OnModifierCreate` log on Lina. Add the verified names to
`lib/threat_data.lua` if they're not already present, AND to Lina-side
patches if hero-specific behaviour is needed.

---

## Summary table , key numbers at a glance

| Stat | Value |
|---|---|
| Base intelligence / gain | 30 / +4 per level |
| Base health / mana | 560 / 435 |
| Base armor | 3.83 |
| Magic resist (base / Flame Cloak / stacked) | 28% / 51.25% / higher with talent + shard |
| Attack range | 670 |
| Move speed (base) | 290 |
| Q cooldown | 11 / 10 / 9 / 8s (with talent: 8 / 7 / 6 / 5s) |
| Q damage | 65 / 125 / 185 / 245 |
| W cooldown | 13 / 11 / 9 / 7s |
| W stun | 1.2 / 1.6 / 2.0 / 2.4s |
| W effect delay | **0.5s** |
| W cast range / radius / max reach | 700 / 250 / 950 |
| R cooldown | 70 / 60 / 50s (with talent: 50 / 40 / 30s) |
| R damage | 380 / 565 / 750 (KV; wiki 400/580/760) |
| R cast range | **750** |
| R cast point + effect delay | 0.3 + 0.25 = **0.55s press-to-damage** (back-swing 0.4s is animation only) |
| Fiery Soul max stacks | 7 (12 with Shard for 5s post-R) |
| Fiery Soul AS / stack | 8 / 16 / 24 / 32 (level 20 LEFT: 18 / 26 / 34 / 42) |
| Fiery Soul duration | 18s (refreshes on new stack) |
| Slow Burn DoT multiplier | 1.64x (1.8x with talent) |
| Slow Burn duration | 4s (5s with talent) |
| Flame Cloak CD / duration / mana | 25s / 7s / 50 |
| Flame Cloak magic resist / spell amp / stack-set | +35% / +35% / 7 |

---

**Brain integration notes (live API readers):**

```lua
-- Live ability handles
local Q = NPC.GetAbility(me, "lina_dragon_slave")
local W = NPC.GetAbility(me, "lina_light_strike_array")
local E = NPC.GetAbility(me, "lina_fiery_soul")
local R = NPC.GetAbility(me, "lina_laguna_blade")
local FC = NPC.HasScepter(me) and NPC.GetAbility(me, "lina_flame_cloak") or nil

-- Live item handles (7.41C core build)
local ether       = NPCLib.item(me, "item_ethereal_blade")   -- canonical setup
local wind_waker  = NPCLib.item(me, "item_wind_waker")       -- defensive cyclone
local blink       = NPCLib.item(me, "item_blink")            -- positioning
local kaya        = NPCLib.item(me, "item_kaya")             -- spell amp
local yk          = NPCLib.item(me, "item_yasha_and_kaya")
local bkb         = NPCLib.item(me, "item_black_king_bar")
local glimmer     = NPCLib.item(me, "item_glimmer_cape")
local lotus       = NPCLib.item(me, "item_lotus_orb")
local aeon        = NPCLib.item(me, "item_aeon_disk")
local force       = NPCLib.item(me, "item_force_staff")
local eul         = NPCLib.item(me, "item_cyclone")      -- legacy fallback

-- Live values (NEVER hardcode patch numbers , gen lib/ability_data.lua + read live)
local q_dmg  = Ability.GetLevelSpecialValueFor(Q, "dragon_slave_damage")            -- 65/125/185/245
local w_delay = Ability.GetLevelSpecialValueFor(W, "light_strike_array_delay_time")  -- 0.5
local w_radius = Ability.GetLevelSpecialValueFor(W, "light_strike_array_aoe")        -- 250
local w_stun = Ability.GetLevelSpecialValueFor(W, "light_strike_array_stun_duration")-- 1.2/1.6/2.0/2.4
local w_dmg  = Ability.GetLevelSpecialValueFor(W, "light_strike_array_damage")       -- 80/120/160/200
local r_dmg  = Ability.GetLevelSpecialValueFor(R, "damage")                          -- 380/565/750
local r_delay = Ability.GetLevelSpecialValueFor(R, "damage_delay")                   -- 0.25
local r_cast_range = Ability.GetCastRange(R) + NPC.GetCastRangeBonus(me)
local stacks = NPC.GetModifierStackCount(me, "modifier_lina_fiery_soul")
local has_shard = NPC.HasShard(me)
local has_scepter = NPC.HasScepter(me)
local fc_ready = FC and Ability.IsReady(FC) and Ability.GetLevel(FC) > 0

-- Laguna Blade is ALWAYS magical damage (Aghs grants Flame Cloak,
-- not a damage-type swap , confirmed against Liquipedia 2026-05-27).
-- Ethereal Blade's -30 magic-resist reduction boosts Q + W + R during
-- the ethereal window.
```

The verbatim KV special-value keys must be confirmed in
`C:\Umbrella\assets\data\npc_abilities.json` for each ability , Phase A2
