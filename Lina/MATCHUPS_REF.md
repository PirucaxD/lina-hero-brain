# Lina , matchups, counters, allies

**Patch:** 7.41c
**Source hierarchy:** Liquipedia is authoritative for ability data; pro
build trackers (D2PT) and DotaBuff counter pages drive the patch-current
matchup data below. Cross-check any specific claim against Liquipedia
ability mechanics before encoding it into brain logic.

This file is the brain's decision-input for "is this matchup good or bad
for Lina" and "which hero should the brain prioritize as a kill target".

---

## Hard counters (Lina should play passive)

These heroes shut down Lina's burst, survive it, or punish her squishy
profile reliably. Brain should refuse aggressive commits against them
when they have any item / level advantage.

| Counter | Mechanism | Brain implication |
|---|---|---|
| **Anti-Mage** | Mana Break drains Lina's mana per hit; Spell Shield (40% resist + 25% chance to refund spells) eats R | Reduce R-commit confidence vs AM; check `NPC.HasState(target, MODIFIER_STATE_MAGIC_IMMUNE)` and pre-emptive break (Q + W before R) |
| **Pugna** | Nether Ward reflects spell damage to Lina; Decrepify amps incoming damage on Lina | Brain should auto-target Ward with Q if visible; avoid casting under it |
| **Anti-mage / Pugna combo** | Spell-shield Linkens layered | Linken-breaker chain mandatory |
| **Spirit Breaker** | Charge of Darkness closes 1500u, bash-stuns Lina before she can W | Layer 2 must dispatch save (Wind Waker / Flame Cloak / BKB) on `armed_threat_fire | via=charge_arrived` |
| **Mars** | Bulwark blocks 50% of frontal physical (less relevant); Arena of Blood blocks line spells (including Q and R cast) | Brain should NOT R into Arena; check `NPC.HasModifier(target, "modifier_mars_arena_of_blood_buff")` before R commit |
| **Storm Spirit** | Ball Lightning chases Lina across the map, eats R via BKB / mana shield | Refuse R-commit on Storm with mana for BL escape; prioritize chain-cast burst (W stun before R) |
| **Bristleback** | Quill Spray + Bristleback passive (high physical resist + reduced damage from rear) absorbs spells over time | Lina's spell-burst is less effective; brain de-prioritizes BB as kill target |
| **Silencer** | Last Word + Global Silence prevents Lina from casting | Brain detects `modifier_silencer_global_silence` / `modifier_silencer_last_word` and aborts pending steps |
| **Faceless Void (enemy)** | Chronosphere locks Lina in place + cancels her cast | Brain detects `modifier_faceless_void_chronosphere_freeze` and aborts |
| **Doom (enemy)** | Doom silences + reduces magic damage; Lina cannot cast under it | BKB / Lotus / Aeon pre-emptive save against incoming Doom |
| **Nyx Assassin** | Spiked Carapace reflects Lina's spells; Burrow + Vendetta gap-close | Brain detects Carapace active modifier and refuses R; treats Vendetta-marked Lina as armed-threat |

## Soft counters (Lina can fight but with caution)

| Counter | Mechanism | Brain implication |
|---|---|---|
| **Phantom Assassin** | Blink + Phantom Strike gap close; Blur evasion vs autos | Already in armed_threats catalog; defensive cyclone-self on blink-arrive; PA is killable in W stun (defensive save first, then offensive WQR if mana) |
| **Ursa** | Fury Swipes + Overpower bursts Lina down in melee | Self-Ethereal (3s physical immune) or BKB pre-emptive |
| **Slark** | Pounce gap-close + Shadow Dance invis recovery | Cyclone-self on pounce-arrive; brain detects `modifier_slark_pounce` |
| **Riki** | Smoke Screen silences Lina; Permanent Invisibility ambush | Lotus reflect if Smoke Screen incoming; detection ward dependency |
| **Templar Assassin** | Refraction + Psi Blades; Meld stealth attacks | Refraction marks block Lina spells; brain checks `modifier_templar_assassin_refraction` |
| **Necrophos** | Reaper's Scythe globally executes; Heartstopper Aura drains HP | BKB top-priority vs incoming Reaper's Scythe |
| **Outworld Destroyer** | Astral Imprisonment removes Lina from game; Sanity's Eclipse based on int diff | Astral-active Lina cannot cast; brain queues post-Astral combo via pending_steps |

## Good matchups (Lina dominates)

| Target | Mechanism | Brain implication |
|---|---|---|
| **Shadow Fiend** | Low HP, no escape, eats WQR burst | High-priority kill target; brain commits R freely on confirmed kill math |
| **Drow Ranger** | Squishy, no escape (Marksmanship range), eats W stun + Q nuke | Same |
| **Sniper** | Identical squishy + no escape profile (mirror-mid scenario) | Same; brain handles via standard combat math |
| **Crystal Maiden** | 525 base HP, eats one Q | Free kill on engagement |
| **Skywrath Mage** | 419 base HP , lowest in pool | Q alone often kills |
| **Lich** | Squishy support; eats burst | Free kill if W lands |
| **Witch Doctor** | Squishy; Maledict mirror-match | Burst beats his sustain |
| **Pudge (early game)** | Slow turn rate, eats stun, no escape pre-Pipe | Combat math favors Lina pre-Pipe |

## Ally synergies (heroes that set Lina up)

| Ally | Setup mechanism | Brain interaction |
|---|---|---|
| **Faceless Void** | Chronosphere freezes targets for ~5s | Brain detects `modifier_faceless_void_chronosphere_freeze` on enemies and auto-fires R + W + Q on the highest-priority chrono'd enemy |
| **Magnus** | Reverse Polarity stuns 3-4s | Brain detects `modifier_magnataur_reverse_polarity_stun` and auto-fires WQR on the stunned cluster |
| **Bane** | Fiend's Grip channel tethers enemy 875u | Brain detects channel + commits R on grip-locked target |
| **Lion** | Hex (sheep stun) + Earth Spike chain | Brain queues WQR on hex'd target |
| **Shadow Shaman** | Hex + Shackles channel | Same as Lion |
| **Bara (Spirit Breaker)** | Charge of Darkness 1500u long stun | Brain queues WQR on charge-arrival on enemy |
| **Tusk** | Snowball stun on multiple enemies | Brain reacts to snowball-arrival; AoE WQR via tf_burst |
| **Disruptor** | Glimpse + Static Storm + Kinetic Field | Brain commits R on Glimpse-returned target; auto-Q during Static Storm channel |
| **Mars (ally)** | Arena of Blood locks enemies in place | Brain identifies trapped-in-arena enemies for kill priority |

## Items pros buy SPECIFICALLY against Lina

Brain should expect these items on enemy heroes and adjust:

- **Linken's Sphere** (carries) , blocks R. Brain detects
  `NPC.IsLinkensProtected(target)` and routes through Ethereal-break
  or Q-break before R.
- **Lotus Orb** (supports / carries) , reflects R back at Lina.
  Single reflected R is often lethal on 560-base-HP Lina. Brain MUST
  gate R commit on `NPC.HasModifier(target, "modifier_item_lotus_orb_active")`
  and similar. Hard refuse.
- **Black King Bar** , Lina deals 0 damage during BKB. Brain detects
  `NPC.HasState(target, MODIFIER_STATE_MAGIC_IMMUNE)` and skips R
  entirely.
- **Orchid / Bloodthorn (vs Lina)** , silences Lina. Lina cannot cast.
  Brain detects own-silence and aborts pending steps.
- **Eul's Scepter (vs Lina)** , cyclones Lina mid-cast. Brain detects
  own-cyclone and aborts pending R.
- **Glimmer Cape (on enemy carry)** , invis + magic resist. Reduces
  Lina's burst effectiveness. Brain de-prioritizes glimmered targets.
- **Aeon Disk (on enemy carry)** , invuln when HP < 80%. Brain
  detects pending Aeon proc and may abort R via STOP order.

## Lane phase patterns

### Lina vs ranged mid (Shadow Fiend, Storm, QoP, Pugna, OD)
- Trade Q-for-Q in early levels.
- Q max by level 7 outdamages most mid-pool spells in mana-per-damage.
- At level 6, look for Q + R kill on overextended enemy.

### Lina vs melee mid (Pudge, Tiny, Necrophos)
- Right-click harass with 670 attack range outranges most melee.
- Q max for chip; W only when target is stationary (no escape spell).

### Lina vs hard counter (Mars, Bristleback, Spirit Breaker)
- Passive farm. Buy Bottle + Null Talisman + Boots.
- Rotate to side lanes for kills instead of lane bullying.

### Lina at level 6
- First R commit: usually a kill if target ≤ 400 effective magical HP.
- Brain at level 6 should auto-flag aggressive R-commit windows.

## Roshan capability

Lina can solo Roshan at:
- Level 18+ with Aghs Scepter + Aghs Shard + Ethereal Blade
- Burst calc: Flame Cloak (35% spell amp) + Ethereal (40% magic amp)
  + R 760 + Q 245 + W 215 = ~3000 magical damage to a Lotus / no-magic-
  resist Rosh. Probably not solo viable until very late; brain treats
  Rosh-solo as out-of-scope for v1.0.

Lina helps Rosh nuke from range , brain detects ally heroes hitting
Rosh and considers committing R if visible.

---

## Brain implication summary

| Decision input | Source |
|---|---|
| Refuse aggressive combat | Hard-counter list above |
| Commit R freely on confirmed kill | Good-matchup list above |
| React to ally setup spells | Synergy list , modifier names go into `lib/threat_data.lua` ENEMY_BUFF_THREATS as ally-visible flags |
| Check before R commit | Linkens / Lotus / BKB list above |
| Lane behavior calibration | Lane phase patterns above |

The matchup data here informs the brain's `commit_pred` predicates and
target valuation scoring. None of it changes the kit; it shapes WHEN
the brain commits the kit.
