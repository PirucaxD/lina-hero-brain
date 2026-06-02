# Lina , animation-to-ability map (pre-built for Lina's mid pool + common gap-closers)

**Source hierarchy:** Liquipedia is authoritative for ability mechanics
and animation names. KV in `C:\Umbrella\assets\data\npc_abilities.json`
(`AbilityCastAnimation` field) is the runtime source for activity codes.
This file pre-populates Phase B5 (animation-to-ability map for Lina's
plausible matchups). Update on each patch.

This file maps each relevant enemy ability to:
- Its activity code (the `OnUnitAnimation.activity` value)
- Its role (gap_close, hard_disable, ult_burst, channel_start, dispel, save)
- Lina's response (Layer 2 save dispatch, Layer 1 abort, threat catalog)

The brain uses this via `lib/threat_data.lua`'s `ABILITY_TO_THREAT` map
(already populated for many of these heroes via Sniper's iteration). Lina
inherits the catalog and adds hero-specific patches where the response
diverges from Sniper's default.

---

## Mid pool (heroes Lina most often faces in mid lane)

### Storm Spirit

| Ability | Activity | Role | Lina response |
|---|---|---|---|
| `storm_spirit_static_remnant` | `ACT_DOTA_CAST_ABILITY_1` | proximity_damage | Layer 1 abort if Lina in 235u of remnant; queue R if visible |
| `storm_spirit_electric_vortex` | `ACT_DOTA_CAST_ABILITY_2` | pull (channel) | Layer 2 cyclone-self if targeted; aim R during channel-lock |
| `storm_spirit_overload` | passive | post-cast amp | n/a |
| `storm_spirit_ball_lightning` | `ACT_DOTA_CAST_ABILITY_4` | gap_close + escape | Pre-burst R commit before BL escape; armed_threat=instant_blink |

### Queen of Pain

| Ability | Activity | Role | Lina response |
|---|---|---|---|
| `queenofpain_shadow_strike` | `ACT_DOTA_CAST_ABILITY_1` | DoT magic | n/a (chip damage) |
| `queenofpain_blink` | `ACT_DOTA_CAST_ABILITY_2` | gap_close | armed_threat = instant_blink:queenofpain_blink; pre-emptive cyclone-self if HP low |
| `queenofpain_scream_of_pain` | `ACT_DOTA_CAST_ABILITY_3` | AoE magic | n/a |
| `queenofpain_sonic_wave` | `ACT_DOTA_CAST_ABILITY_4` | ult_burst (1100 dmg cone) | BKB / Lotus reflect; Lina's R faster than QoP's ult cast |

### Puck

| Ability | Activity | Role | Lina response |
|---|---|---|---|
| `puck_illusory_orb` | `ACT_DOTA_CAST_ABILITY_1` | proj nuke + reposition | Stand sideways if visible |
| `puck_waning_rift` | `ACT_DOTA_CAST_ABILITY_2` | AoE silence + damage | armed_threat=silence; BKB pre-emptive if HP low |
| `puck_phase_shift` | `ACT_DOTA_CAST_ABILITY_3` | invuln dodge | Wait R commit until phase ends |
| `puck_dream_coil` | `ACT_DOTA_CAST_ABILITY_4` | tether stun | Strong-dispel (Wind Waker) on coil-snap |

### Sniper (mirror-mid)

Already in catalog from Sniper work. Brain knows:
- `sniper_shrapnel` (1800u zone) , stand outside
- `sniper_assassinate` (3000u channel + cast) , armed_threat=cast_target; BKB/Lotus during R cast
- `sniper_concussive_grenade` (shard) , knockback + 3s disarm; Wind Waker dispel

### Pugna

| Ability | Activity | Role | Lina response |
|---|---|---|---|
| `pugna_nether_blast` | `ACT_DOTA_CAST_ABILITY_1` | AoE nuke | n/a (Lina is squishy; dodge by moving) |
| `pugna_decrepify` | `ACT_DOTA_CAST_ABILITY_2` | amp magic damage 40% | Detect on self; refuse aggressive commit |
| `pugna_nether_ward` | `ACT_DOTA_CAST_ABILITY_3` | ground unit reflects spells | Q the Nether Ward on cast; never cast under it |
| `pugna_life_drain` | channel | channel_on_self | Wind Waker / BKB to interrupt own-side; Lina's R during channel locks Pugna |

### Outworld Destroyer

| Ability | Activity | Role | Lina response |
|---|---|---|---|
| `obsidian_destroyer_arcane_orb` | passive autoattack | int steal | n/a |
| `obsidian_destroyer_astral_imprisonment` | `ACT_DOTA_CAST_ABILITY_2` | banish (4s removal) | If on Lina: aborts everything; queue post-Astral combo |
| `obsidian_destroyer_equilibrium` | passive | sustain | n/a |
| `obsidian_destroyer_sanity_eclipse` | `ACT_DOTA_CAST_ABILITY_4` | ult based on int diff | BKB / Aeon pre-emptive; Lina has high int → less effective on her |

### Tinker

| Ability | Activity | Role | Lina response |
|---|---|---|---|
| `tinker_laser` | `ACT_DOTA_CAST_ABILITY_1` | nuke + blind | n/a (chip) |
| `tinker_heat_seeking_missile` | `ACT_DOTA_CAST_ABILITY_2` | homing nuke | Manta-illusion / Glimmer if visible |
| `tinker_defense_matrix` | passive | shield | n/a |
| `tinker_rearm` | channel | refresh items + spells | armed_threat=tinker_rearm; Lina R into rearm channel = lock kill |

### Death Prophet

| Ability | Activity | Role | Lina response |
|---|---|---|---|
| `death_prophet_carrion_swarm` | `ACT_DOTA_CAST_ABILITY_1` | AoE nuke | n/a |
| `death_prophet_silence` | `ACT_DOTA_CAST_ABILITY_2` | AoE silence | BKB / cyclone-self; aborts Lina pending steps |
| `death_prophet_spirit_siphon` | `ACT_DOTA_CAST_ABILITY_3` | tether drain | armed_threat=tether; Strong-dispel breaks |
| `death_prophet_exorcism` | `ACT_DOTA_CAST_ABILITY_4` | summons drain | Position away |

### Templar Assassin

| Ability | Activity | Role | Lina response |
|---|---|---|---|
| `templar_assassin_refraction` | `ACT_DOTA_CAST_ABILITY_1` | spell + attack block (3 instances each) | armed_threat=refraction_block; pop with Q or Ether-cast before R |
| `templar_assassin_meld` | `ACT_DOTA_CAST_ABILITY_2` | invis attack with armor reduction | Detect lost-vision; armed_threat=meld_pending |
| `templar_assassin_psi_blades` | passive | spill damage line | n/a |
| `templar_assassin_psionic_trap` | `ACT_DOTA_CAST_ABILITY_4` | summons traps | Q clears traps |

### Invoker

| Ability | Activity | Role | Lina response |
|---|---|---|---|
| `invoker_cold_snap` | invoked | chained mini-stun | armed_threat; W during snap |
| `invoker_ghost_walk` | invoked | invis + slow aura | Detect lost-vision; lock R window |
| `invoker_tornado` | invoked (`ACT_DOTA_CAST_ABILITY_4` variants) | airborne nuke 2s | BKB / Lotus pre-emptive |
| `invoker_emp` | invoked | mana drain AoE | Maintain mana; refuse R commit if EMP'd |
| `invoker_alacrity` | invoked self-buff | n/a | n/a |
| `invoker_chaos_meteor` | invoked | AoE rolling damage | Position away |
| `invoker_sun_strike` | invoked global | global instant nuke | Lotus reflect (if active); else dodge |
| `invoker_forge_spirit` | invoked summon | n/a | Q clears |
| `invoker_ice_wall` | invoked | wall slow | Position around |
| `invoker_deafening_blast` | invoked | knockback + disarm + damage | armed_threat=knockback_disarm; Wind Waker dispel |

Invoker's invoked abilities use the same `ACT_DOTA_CAST_ABILITY_4` /
`ACT_DOTA_CAST_ABILITY_5` etc. activity codes but the invoked ability is
the actual cast. Brain reads `Ability.GetName` post-cast to determine
which spell was invoked.

### Necrophos

| Ability | Activity | Role | Lina response |
|---|---|---|---|
| `necrolyte_death_pulse` | `ACT_DOTA_CAST_ABILITY_1` | nuke + heal | n/a |
| `necrolyte_heartstopper_aura` | passive | HP drain | n/a |
| `necrolyte_sadist` | passive | int regen on kill | n/a |
| `necrolyte_reapers_scythe` | `ACT_DOTA_CAST_ABILITY_4` | execute (mini-stun 1.5s + damage based on missing HP) | **CRITICAL**: BKB pre-emptive; reflects via Lotus; Lina has high int so Reaper kills her easily |

### Lina (mirror-mid)

| Ability | Activity | Role | Lina response |
|---|---|---|---|
| `lina_dragon_slave` | `ACT_DOTA_CAST_ABILITY_1` | line nuke | Side-step / Wind Waker |
| `lina_light_strike_array` | `ACT_DOTA_CAST_ABILITY_2` | delayed AoE stun | armed_threat=lsa_pending; Wind Waker / cyclone-self during 0.5s pre-impact |
| `lina_laguna_blade` | `ACT_DOTA_CAST_ABILITY_4` | single-target nuke | BKB / Lotus pre-emptive; Wind Waker dispel post-cast |
| `lina_flame_cloak` (Aghs) | self-buff | own offense + def | n/a from Lina-side |

---

## Common gap-closers (Lina's primary defensive threats)

### Phantom Assassin (most common)

| Ability | Activity | Role | Lina response |
|---|---|---|---|
| `phantom_assassin_stifling_dagger` | `ACT_DOTA_CAST_ABILITY_1` | slow + damage | n/a (chip) |
| `phantom_assassin_phantom_strike` | `ACT_DOTA_CAST_ABILITY_2` | gap_close + bonus AS | **armed_threat=instant_blink:phantom_assassin_phantom_strike**; pre-emptive Wind Waker / BKB on blink-arrive |
| `phantom_assassin_blur` | passive | dodge | Increases R-commit confidence (R is magical, ignores Blur) |
| `phantom_assassin_coup_de_grace` | passive | crit | n/a |

### Spirit Breaker

| Ability | Activity | Role | Lina response |
|---|---|---|---|
| `spirit_breaker_charge_of_darkness` | `ACT_DOTA_CAST_ABILITY_1` | 1500u charge + 2s bash | **CRITICAL armed_threat=charge_arrived**: Wind Waker on charge-arrive; BKB pre-emptive if HP < 50% |
| `spirit_breaker_bulldoze` | `ACT_DOTA_CAST_ABILITY_2` | MS + status resist | n/a |
| `spirit_breaker_greater_bash` | passive | bash | n/a |
| `spirit_breaker_nether_strike` | `ACT_DOTA_CAST_ABILITY_4` | teleport + stun | armed_threat=teleport_stun; same as charge |

### Tusk

| Ability | Activity | Role | Lina response |
|---|---|---|---|
| `tusk_ice_shards` | `ACT_DOTA_CAST_ABILITY_1` | wall + damage | Side-step |
| `tusk_snowball` | channel + impact | gap_close + AoE stun | armed_threat=snowball_impact; Wind Waker on impact |
| `tusk_walrus_punch` | `ACT_DOTA_CAST_ABILITY_3` | critical knockback | armed_threat=knockback_disarm; Wind Waker |

### Slark

| Ability | Activity | Role | Lina response |
|---|---|---|---|
| `slark_dark_pact` | `ACT_DOTA_CAST_ABILITY_1` | strong dispel + damage | n/a |
| `slark_pounce` | `ACT_DOTA_CAST_ABILITY_2` | gap_close + tether 3.5s | **armed_threat=pounce_tether**: Wind Waker dispels tether; or Force-staff out of pounce |
| `slark_essence_shift` | passive | stat steal | n/a |
| `slark_shadow_dance` | `ACT_DOTA_CAST_ABILITY_4` | invis-heal | Detect lost-vision; reset combat |

### Ursa

| Ability | Activity | Role | Lina response |
|---|---|---|---|
| `ursa_earthshock` | `ACT_DOTA_CAST_ABILITY_1` | AoE slow | n/a |
| `ursa_overpower` | `ACT_DOTA_CAST_ABILITY_2` | self-buff AS | Detect; BKB if Ursa on Lina |
| `ursa_fury_swipes` | passive | stacking damage | Move away after 2 stacks |
| `ursa_enrage` | `ACT_DOTA_CAST_ABILITY_4` | self-buff + dispel | n/a |

### Magnus

| Ability | Activity | Role | Lina response |
|---|---|---|---|
| `magnataur_shockwave` | `ACT_DOTA_CAST_ABILITY_1` | line damage + pull | Side-step |
| `magnataur_empower` | self / ally buff | n/a from Lina-side | n/a |
| `magnataur_skewer` | `ACT_DOTA_CAST_ABILITY_3` | gap_close pull line | armed_threat=skewer_pull; Wind Waker / BKB during pull |
| `magnataur_reverse_polarity` | `ACT_DOTA_CAST_ABILITY_4` | AoE 3-4s stun (ally setup) | If ally Magnus: brain auto-WQR on stunned cluster (tf_burst). If enemy Magnus: BKB pre-emptive |

### Faceless Void

| Ability | Activity | Role | Lina response |
|---|---|---|---|
| `faceless_void_time_walk` | `ACT_DOTA_CAST_ABILITY_1` | gap_close + slow rewind | armed_threat=time_walk_arrived |
| `faceless_void_time_dilation` | `ACT_DOTA_CAST_ABILITY_2` | AoE CD freeze | Detect; refuse R commit if R locked by dilation |
| `faceless_void_chronosphere` | `ACT_DOTA_CAST_ABILITY_4` | 5s AoE freeze | If enemy: BKB pre-emptive (Lina dies in chrono). If ally: tf_burst on highest-priority chrono'd target |

### Bara (Spirit Breaker, listed separately above)

Already covered.

### Riki

| Ability | Activity | Role | Lina response |
|---|---|---|---|
| `riki_blink_strike` | `ACT_DOTA_CAST_ABILITY_2` | gap_close + back-attack | armed_threat=blink_strike_arrived; Wind Waker |
| `riki_smoke_screen` | `ACT_DOTA_CAST_ABILITY_1` | AoE silence | BKB / cyclone-self; armed_threat=silence |
| `riki_permanent_invisibility` | passive | invis | Detect missing |
| `riki_tricks_of_the_trade` | `ACT_DOTA_CAST_ABILITY_4` | back-attack channel + invuln | Strong-dispel Wind Waker breaks; or wait it out |

---

## How brain consumes this map

1. **`lib/threat_data.lua` ABILITY_TO_THREAT** owns the global
   ability-name -> modifier-name map. Lina inherits the existing
   Sniper-iterated catalog (already populated for many of these
   heroes). Add Lina-specific entries via `LINA_THREAT_PATCHES`.

2. **`OnUnitAnimation` callback** in Sniper.lua provides the entry
   point (already ported via lib chain). For each animation event,
   the brain looks up the enemy hero + activity code, finds the
   ability via this map, and routes to the appropriate response.

3. **Layer 2 dispatcher** reads the response field. `armed_threat`
   responses queue an `armed_threats` entry; `BKB pre-emptive`
   responses fire immediately; `cyclone-self` responses cyclone via
   Wind Waker.

4. **Layer 1 abort** responses interrupt pending offensive steps via
   `pending_steps_tick` clear.

---

## Particle signatures (backup detector via OnParticleCreate)

Per HERO_PROMPT Phase 4: "Particle signatures via `OnParticleCreate`
are the backup detector for hard-to-read casts". For abilities
where `OnUnitAnimation` is unreliable (e.g., abilities with no
activity code, or activity codes shared between multiple spells),
the brain falls back to particle detection.

| Particle signature (prefix match) | Source ability | Lina response |
|---|---|---|
| `particles/units/heroes/hero_bane/bane_grip` | Bane Fiend's Grip channel | Wind Waker dispel (strong) breaks grip; armed_threat=channel_on_self |
| `particles/units/heroes/hero_doom/doom_doom` | Doom ult | BKB pre-emptive; Lotus reflect if up |
| `particles/units/heroes/hero_pudge/pudge_dismember` | Pudge Dismember channel | Wind Waker breaks; armed_threat=channel_on_self |
| `particles/units/heroes/hero_pugna/pugna_drain` | Pugna Life Drain channel | Wind Waker breaks; brain can R Pugna during channel to lock kill |
| `particles/units/heroes/hero_bloodseeker/bloodseeker_rupture` | Rupture mark | refuse R commit on rupture'd Lina (movement causes self-damage); cyclone-self safe |
| `particles/units/heroes/hero_disruptor/disruptor_static_storm` | Static Storm AoE silence | BKB pre-emptive if in radius; armed_threat=silence; multi-fire persistent_threats_tick |
| `particles/units/heroes/hero_legion_commander/legion_duel` | Legion Duel locked | BKB if losing duel; Wind Waker is broken by duel-lock (cannot dispel duel itself; just survive) |
| `particles/units/heroes/hero_silencer/silencer_global_silence` | Global Silence cast | aborts all Lina pending steps |
| `particles/units/heroes/hero_nyx_assassin/nyx_carapace` | Spiked Carapace active | refuse R + W (reflects); wait for expiration |
| `particles/units/heroes/hero_axe/axe_call` | Berserker's Call AoE taunt | armed_threat=forced-attack; BKB / Wind Waker breaks |
| `particles/items_fx/aeon_disk_buff` | Enemy Aeon Disk active | refuse R commit; target is invuln-window pending |
| `particles/items_fx/lotus_orb_active` | Enemy Lotus active | hard refuse R / Ether target-cast (reflects) |
| `particles/items_fx/black_king_bar_active` | Enemy BKB | refuse R; magic immune |

**Note**: particle signature names are version-specific and may
shift per patch. Verify exact prefixes via `OnParticleCreate`
logging in Phase B5. The brain reads `data.name` (or equivalent
particle path field) and prefix-matches.

## Verification tasks (Phase B5)

When Phase B5 builds the Lina-specific anim map, verify against this
file:

- [ ] Activity codes match KV `AbilityCastAnimation` values.
- [ ] Each ability has a modifier in `lib/threat_data.lua`
      `THREATS_ON_SELF` OR `ENEMY_BUFF_THREATS`.
- [ ] Lina-specific responses (Wind Waker > Eul, Flame Cloak as save)
      override Sniper-default responses where needed.
- [ ] Patch-new heroes (Kez, Marci, Ringmaster in 7.41C) , verify
      separately if relevant to Lina's matchup pool.

Any new modifier names surfaced should be added to
`lib/threat_data.lua` (after the standard hero-agnostic curation
process) and reflected in this file.
