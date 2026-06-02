# Lina , items reference (7.41C)

**Source hierarchy:** Liquipedia is authoritative for item mechanics.
KV files (`C:\Umbrella\assets\data\items.json`) are runtime ground
truth. Pro build trackers (D2PT) drive the meta item PATH below.

This file lists every item Lina commonly carries in 7.41C, with the
values the brain needs for save / combo / cooldown math. All numeric
values are documented as REFERENCE , the brain reads them live via
`Ability.GetLevelSpecialValueFor(item, "key")` and never hardcodes.

---

## Core build (7.41C pro consensus)

Approximate buy order from lane phase to late game:

1. Tango, Iron Branch x4, Faerie Fire, Observer Ward
2. Bottle, Null Talisman, Boots of Speed, Magic Wand
3. **Kaya** , spell amp foundation
4. **Aghanim's Scepter** (Flame Cloak grant) , mid-game power spike
5. **Boots of Travel** , global presence
6. **Yasha and Kaya** , MS + spell amp + status resist
7. **Blink Dagger** , positioning for the W setup
8. **Ethereal Blade** , canonical setup item (replaces Eul's in 7.41C)

Extension / situational (any of):
- Aghanim's Shard (Laguna Fiery-Soul-to-12 for 5s)
- Octarine Core (cooldown reduction; combos with R-CD talent)
- Wind Waker (3s self-cyclone save)
- Black King Bar
- Aeon Disk
- Hurricane Pike / Force Staff
- Sheepstick
- Bloodstone (lower priority in 7.41C)
- Refresher Orb (very late game; R + Flame Cloak refresh)

**Notable absences vs older patches**:
- Eul's Scepter , replaced by Ethereal Blade as setup item.
- Veil of Discord , situational vs magic-resist lineups; not core.

---

## Offensive items (setup + burst)

### Ethereal Blade (CANONICAL setup, 7.41C)

| Field | Value |
|---|---|
| Cast range | 800 (target-cast) |
| Cast point | 0 (instant) |
| Cooldown | 22s |
| Mana cost | 100 |
| Effect (target-cast) | Target becomes ETHEREAL for 4s |
| Ethereal effect | Physical-immune, cannot attack, slowed 80% MS, **-30 magic resistance** (KV ethereal_damage_bonus -30; subtractive resist reduction, NOT a flat amp) |
| Effect (self-cast) | Lina becomes ethereal for 4s (KV duration_ally 4) |
| Self-effect | Physical-immune, cannot attack, -30 own magic resistance |
| Damage on cast | 50 + 100% of summed attributes (str+agi+int), magical, pops Linkens |
| Dispel | Dispelled by strong dispel |
| Modifier (target) | `modifier_item_ethereal_blade_ethereal` |
| Modifier (self) | `modifier_item_ethereal_blade_slow` (on enemies hit while caster is ethereal) |

**Brain implications:**
- Target-cast is the canonical combo opener. The 75+str damage AND
  ethereal application means Linkens pops on cast , `BreakLinkens`
  is built into the combo.
- The -30 magic-resistance reduction applies during the ethereal
  window (KV ethereal_damage_bonus -30; Liquipedia "Magic Resistance
  Reduction 30%"; model as resist reduction, about x1.40 vs a
  25%-resist target). Q, W, R all benefit.
- Self-cast is a niche save , physical immune but Lina still takes
  magic damage AND cannot cast spells. Brain should prefer Wind
  Waker / Flame Cloak / BKB for defense.
- Target ethereal CANNOT be Aeon-Disked (Aeon is basic dispel; ether
  requires strong dispel). Brain math assumes 4s ethereal is locked.
- During ethereal, target cannot attack , this is the perfect window
  for Lina to position closer.

### Aghanim's Scepter , Flame Cloak (cross-reference)

Aghs Scepter grants Lina a 4th ability slot (Flame Cloak). Full
ability-mechanics table is in `LIQUIPEDIA_REF.md` under
"Aghanim's Scepter , Flame Cloak (4th ability slot)". Key
item-level facts for the brain:

- 25s CD, 7s duration, 50 mana , see LIQUIPEDIA_REF for values.
- Acts as defensive AND offensive cooldown simultaneously.
- Brain auto-fires (no combo_key) when:
  - In fight + Fiery Soul stacks < 4 (refresh trigger)
  - HP < 50% + magic damage incoming (defensive trigger)
  - Just before R commit (offensive +35% spell amp)
- Interrupts Lina's own channels (TP). Refuse if Lina is mid-TP.
- Live availability:
  `NPC.HasScepter(me) and Ability.IsReady(flame_cloak_ability)`.

### Aghanim's Shard (cross-reference)

Aghs Shard upgrades Laguna Blade. Full effect table is in
`LIQUIPEDIA_REF.md` under "Aghanim's Shard , Laguna Blade
enhancement". Item-level facts for the brain:

- Sets Fiery Soul to 12 stacks for 5s post-R.
- After every R commit (with Shard owned), brain switches to
  chase-with-autos archetype for 5s , 12 × 32 = 384 AS chase
  autos.
- Live availability: `NPC.HasShard(me)`.
- Cooldown is tied to R's CD; no independent CD tracking needed.

### Kaya (early-game spell amp)

| Field | Value |
|---|---|
| Stats | +90 mana, +5 str, +5 agi, +10 int |
| Spell amp | +12% |
| Mana cost reduction | +12% |
| Status resistance | +12% |

### Yasha and Kaya

| Field | Value |
|---|---|
| Stats | Yasha + Kaya combined |
| Movement speed | +12% |
| Spell amp | +18% |
| Attack speed | +20 |

Brain treats Yasha+Kaya spell amp as additive with Kaya base , net
+18% spell amp post-upgrade.

### Blink Dagger

| Field | Value |
|---|---|
| Range | 1200 (long blink) |
| Damage taken break | 3s no-blink window after taking enemy damage |
| Cooldown | 12s |

**Brain implications:**
- Blink+W combo: blink 1200u + W 700u cast range = 1900u burst threat.
- Brain detects user-issued blink and queues W on target's current
  position (Phase G enhancement, see `combo_blink_w_setup`).

---

## Defensive items (saves)

### Wind Waker (top of save chain in 7.41C)

| Field | Value |
|---|---|
| Cast time | ~0s instant |
| Cooldown | 19s (KV; shares "cyclone" CD with Eul's / item_cyclone) |
| Mana | 175 |
| Self-cast cyclone | 2.5s |
| Strong-dispel | YES (full dispel; clears stuns, silences, debuffs) |
| Cyclone effect | Invulnerable, suspended in air, cannot act |
| Modifier | `modifier_item_wind_waker` |

**Brain implications:**
- Top of save chain. 3s + strong dispel is the strongest single
  defensive item Lina has.
- Cyclone time gives R-cooldown 3s of progress.

### Flame Cloak (via Aghs Scepter, double-duty)

Already documented above. Used both offensively and defensively.

### Black King Bar

| Field | Value |
|---|---|
| Cast time | 0s instant |
| Cooldown | 95s |
| Duration | 9 / 8 / 7s (max 3 levels; decreases per cast) |
| Effect | Magic immunity (block magic + most debuffs) |
| Modifier | `modifier_black_king_bar` |

### Glimmer Cape

| Field | Value |
|---|---|
| Cast time | 0s |
| Cooldown | 15s |
| Mana | 125 |
| Duration | 5s |
| Effect | Invis + 20% magic resist + 375 damage barrier |
| Channel | Breaks on damage |
| Modifier | `modifier_item_glimmer_cape` |

### Aeon Disk

| Field | Value |
|---|---|
| Cooldown | 105 / 125 / 145 / 165s (KV; rises per level) |
| Auto-fire trigger | HP drops below 70% (passive auto-trigger) |
| Effect | Basic dispel + 2.5s buff, 75% status resistance (KV; NOT invuln, verify Liquipedia) |
| Modifier (active) | `modifier_item_aeon_disk_active` |

**Brain implications:**
- Auto-trigger, not user-initiated. Brain logs `aeon_proc` event when
  modifier appears.

### Lotus Orb

| Field | Value |
|---|---|
| Cast time | 0s |
| Cooldown | 15s |
| Mana | 175 |
| Duration | 5s |
| Effect | Reflects targeted abilities back at caster |
| Active modifier | `modifier_item_lotus_orb_active` |

**Brain implications:**
- Pre-emptive cast vs incoming targeted ults (Doom, Skywrath ult,
  Duel, Drag from Beastmaster, etc.).
- Brain reads LOTUS_WORTHY_INCOMING table from `lib/threat_data.lua`.

### Force Staff

| Field | Value |
|---|---|
| Cast range | 550 (ally/self); 850 (enemy) |
| Cooldown | 19s (shares "force" CD with Hurricane Pike) |
| Mana | 150 |
| Push distance | 600u |
| Push duration | 0.5s |
| Modifier | `modifier_item_force_staff_active` |

### Hurricane Pike

| Field | Value (7.41C) |
|---|---|
| Cast range (enemy) | 425 |
| Push distance (SELF) | 600u (KV push_length); enemy push 425u (enemy_length) |
| Cooldown | 19s (shares "force" CD with Force Staff) |
| Mana | 150 |
| Self-shot bonus | 5 attacks at +130 attack range after self-push |
| Modifier (push) | `modifier_item_hurricane_pike_active` |

Note (KV-verified 2026-05-28): SELF-cast push is 600u (push_length);
the 425u is the ENEMY push (enemy_length) and enemy cast range. The
SAVE_FIRE pike-self closure must use 600u, NOT 425u.

### Manta Style

| Field | Value |
|---|---|
| Cast time | 0s |
| Cooldown | 34s |
| Mana | 125 |
| Effect | Basic dispel + 2 illusions (18s) |
| Modifier | `modifier_manta` |

### Eul's Scepter of Divinity (LEGACY , not in 7.41C core)

| Field | Value |
|---|---|
| Cast range | 550 (target-cast) |
| Cooldown | 23s (shares "cyclone" CD with Wind Waker) |
| Mana | 175 |
| Cyclone duration | 2.5s (self OR enemy) |
| Cyclone effect | Invulnerable, suspended in air, cannot act |
| Dispel | Strong dispel on cast |
| Modifier (self) | `modifier_eul_scepter_dispel` |
| Modifier (target) | `modifier_eul_scepter_dispel` (same name; check disambiguation in KV) |

Only relevant if Lina happens to own Eul's (legacy combo
`combo_eul_wrq`).

---

## Mana items

### Bottle

| Field | Value |
|---|---|
| Charges | 3 |
| Heal per charge | 135 HP + 70 mana over 3s |
| Rune refill | YES |
| Cost | 600g |

Mid Lina staple.

### Null Talisman

| Field | Value |
|---|---|
| Stats | +6 int, +3 str, +3 agi |
| Mana regen | +50% |
| Spell amp | +3% |
| Stackable | Up to 2 |

### Magic Wand

| Field | Value |
|---|---|
| Charges | 0/15 |
| Per-charge | 15 HP + 15 mana per charge on activation |
| Refill | Charges per enemy ability cast |

### Bloodstone (extension)

| Field | Value |
|---|---|
| Mana | +200 |
| Mana regen | +200% |
| Spell amp | +12% |
| HP | +150 |
| Active | Heal 750 + spell vampirism |
| Cooldown | 25s |
| Mana cost | 100 |

Often replaced by Kaya → Yasha+Kaya path in 7.41C, but viable for
spell-spam playstyle.

---

## Save geometry , push direction and facing dependency per item

Per HERO_PROMPT lesson 8 ("Document each save closure's cast
geometry"). For each defensive save Lina dispatches, this table
records: how the cast resolves geometrically, whether it
displaces Lina or the target, the direction relative to facing,
and what the brain must check before firing.

| Save | Target / Self | Geometry | Push direction | Facing matters? | Pre-cast checks |
|---|---|---|---|---|---|
| Wind Waker self | self-cast (no position) | Lina goes airborne for 3s | n/a , Lina suspended in place | NO | none beyond `IsReady` + `IsCastable(mana)` |
| Flame Cloak (Aghs Scepter) | self-cast | Lina z-axis ascend 100u, flying pathing for 7s | n/a , buff only | NO | not channeling, `IsReady`, `mana >= 50` |
| Black King Bar | self-cast (instant) | Lina gains magic immunity | n/a | NO | `IsCastable`; HERO_PROMPT lesson 19 , refuse if redundant (already magic-immune) |
| Glimmer Cape | self-cast (target self) | Invis + magic resist for 5s | n/a | NO | check no enemy `MODIFIER_STATE_TRUESIGHT` source nearby (gem / sentry); detection invalidates Glimmer |
| Aeon Disk | auto-fires below HP threshold | basic dispel + 1.25s invuln | n/a | NO | not brain-controlled; brain logs proc event |
| Lotus Orb | self-cast | reflect modifier on Lina, 4s | n/a | NO | only useful if incoming targeted spell predicted in window; check `LOTUS_WORTHY_INCOMING` |
| Ethereal Blade self-cast | self-cast | physical-immune ethereal for 3s | n/a , Lina cannot attack/be-attacked-physically | NO | refuse if magic damage incoming (Lina still vulnerable to magic) |
| Force Staff self-cast | self-cast | Lina pushed in OWN facing direction 600u | **YES** , pushes Lina the way she's facing | Lesson 61 safety: refuse if facing threat (would push INTO it); refuse if destination has more enemies than current position; refuse for HOMING close_gap threats (Bara / Tusk re-target) |
| Hurricane Pike self-cast | self-cast | Lina pushed in own facing direction 600u (KV push_length) | **YES** (same as Force) | Same safety as Force; Pike SELF push is 600u (the 425u is the enemy push) |
| Manta Style | self-cast | basic dispel + 2 illusions of Lina | n/a | NO | breaks Lina's silence; refuse if Lina is mid-channel (interrupts own) |
| Eul's self (legacy) | self-cast (target self) | Lina cyclone airborne 2.5s + strong dispel on cast | n/a , Lina suspended | NO | only used if Lina owns Eul's (not 7.41C core) |
| Ethereal Blade target-cast (offensive) | target-cast | Target ethereal 4s, -30 magic resist | target stays in place (no knockback) | NO | Linkens auto-pops (50 + summed attrs damage on cast); refuse if target has Lotus active (reflects) |
| Force Staff target-cast (ally save) | target-cast on ally | Ally pushed in ally's facing direction 600u | **Ally facing matters**; brain cannot directly read ally's facing intent | Refuse force-ally if ally is mid-channel of own ability |
| Force Staff target-cast (enemy push) | target-cast on enemy | Enemy pushed in own facing 600u | Enemy facing matters | Niche; use Wind Waker instead for disable |

**Notes for the brain:**
- Force / Pike self-cast are **direction-dependent** , the engine
  uses Lina's CURRENT facing at the moment of cast. The brain
  should pre-face Lina via a HOLD POSITION + rotate command 0.1s
  before issuing Force, OR pick a destination point and gate the
  cast on Lina already facing that direction.
- Wind Waker / Flame Cloak / BKB / Aeon / Lotus / Manta are
  geometry-free , no pre-cast positioning needed.
- Ethereal Blade target-cast triggers a 50 + summed-attributes magic damage
  pulse on cast , this pops Linkens, BUT also triggers a Lotus
  Orb active modifier if the target has one. Brain MUST gate
  Ethereal target-cast on `not Lotus_active`.

## GridNav usage for save destination selection (Phase E plan)

Per HERO_PROMPT Phase 4 ("Use the pathing primitives for Layer 2
escape decisions"). When Lina's save chain reaches a
displacement save (Force Staff or Pike self), the brain should
pick the destination via `GridNav.BuildPath` ranked by danger.

### `GridNav.CreateNpcMap()` , danger overlay

Returns a per-cell danger score map. Cells near enemy heroes
score high; cells in friendly tower coverage score low (safe).

### `GridNav.IsTraversableFromTo(pos_a, pos_b)` , cheap reachability

Before committing a Force-self with destination `D`, verify
Lina can actually reach `D` (no impassable terrain / trees in
the way).

### Brain integration

```
For each potential Force/Pike self-cast destination:
  1. Compute destination from Lina facing * push distance
  2. GridNav.IsTraversableFromTo(lina_pos, destination)
     → if false, rotate facing and retry
  3. GridNav.CreateNpcMap() lookup at destination
     → if more enemy weight than current cell, refuse cast
  4. If safe destination found, issue Force-self
```

This is the lesson 61 implementation.

## Item-aware brain logic

### Save chain priority (7.41C core build, no Eul)

```
Layer 2 save chain (highest to lowest priority):

1. item_wind_waker (3s cyclone + strong dispel)
2. lina_flame_cloak (Flame Cloak , +35% magic res + Fiery Soul refresh)
3. item_black_king_bar (10s magic immunity, against multi-spell magic)
4. item_aeon_disk (auto-trigger; not brain-initiated)
5. item_glimmer_cape (invis + 22% magic res)
6. item_lotus_orb (reflect pre-emptive)
7. item_ethereal_blade self-cast (physical immune; niche)
8. item_force_staff (self-push 600u)
9. item_hurricane_pike (self-push 425u)
10. item_manta (basic dispel + illusions)
11. item_cyclone (legacy fallback if owned)
```

### Combo step item triggers

```
Offensive combo step items (combo_ether_wqr):

1. item_ethereal_blade target-cast (open)
2. lina_light_strike_array (W)
3. lina_dragon_slave (Q)
4. lina_laguna_blade (R)
5. auto-attacks with Fiery Soul stacks
```

### Mana budget gate

```
combo_ether_wqr full cost (KV-verified 2026-05-28):
  Ethereal Blade:  100 mana
  W (LSA L4):      130 mana
  Q (Dragon L4):   130 mana
  R (Laguna L3):   450 mana
                   ---
  TOTAL:           810 mana

Brain refuses combo if current mana < 810 OR
  current mana < (810 + safety_buffer_for_save_items).

Safety buffer for one emergency save: Wind Waker is 175 mana (NOT
75). Conservative refuse threshold ~985 with a Wind-Waker buffer, or
used 860) should be revisited to 810 bare / ~985 with save buffer.
```

### Items vs Lina (enemy uses these)

Brain accounts for the following enemy items:

- **Linken's Sphere** on enemy carry , blocks R. Pre-R Linken-break
  required (Ethereal target-cast pops Linken first; combo handles this
  automatically). Modifier: `modifier_item_sphere_target` /
  `modifier_item_linkens_buff`.
- **Lotus Orb** active on target , reflects R. Hard refuse R commit
  during `modifier_item_lotus_orb_active`.
- **BKB** active on target , magic immune. Refuse R commit during
  `MODIFIER_STATE_MAGIC_IMMUNE`.
- **Eul's / Wind Waker** (self-cast on target by them) , target is
  invulnerable during cyclone. Refuse R commit during target's own
  `modifier_eul_scepter_dispel` / `modifier_item_wind_waker`.
- **Orchid / Bloodthorn** on Lina , silenced. Brain detects own-silence
  and aborts pending steps.

---

## Verification tasks (Phase A4)

When Phase A4 reads `items.json`, verify against this reference:

- [x] item_ethereal_blade cast range 800, cooldown 22s (NOT 25),
      ether 4s, cast point 0, mana 100; on-cast 50 + summed attrs;
      applies -30 magic resistance (NOT a flat +40% amp). VERIFIED KV.
- [x] item_wind_waker cooldown 19s (NOT 40), cyclone 2.5s (NOT 3),
      mana 175; shares "cyclone" CD with item_cyclone. VERIFIED.
- [x] item_ultimate_scepter grants lina_flame_cloak (IsGrantedByScepter
      1, AbilityDraftExtraAbilities scepter). VERIFIED. Detect via
      NPC.HasScepter.
- [ ] item_aghanims_shard: laguna supercharge_stacks 12 /
      supercharge_duration 5 (ability-side VERIFIED KV). Active buff
      modifier name not in KV; verify in-demo.
- [x] item_hurricane_pike SELF push 600u, enemy push 425u, enemy
      cast range 425u, CD 19s, mana 150. VERIFIED KV.
- [x] item_cyclone (Eul's) cyclone 2.5s, cast range 550 (NOT 700),
      CD 23s, mana 175. VERIFIED KV.

Flag any KV-vs-Liquipedia discrepancies. Liquipedia is authoritative.
