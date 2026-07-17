extends CharacterBody2D
class_name player_base

# ─── MOVEMENT CONSTANTS ───────────────────────────────────────
const WALK_SPEED            := 180.0
const SPRINT_SPEED          := 320.0
const JUMP_FORCE            := -520.0
const DOUBLE_JUMP_FORCE     := -440.0
const GRAVITY               := 1200.0
const DASH_SPEED            := 600.0
# Distance-based (replaces the old fixed-time duration) so the dash always
# covers the same physical distance regardless of hit-stop or a frame
# hitch, and terminates cleanly the instant it hits a wall.
const DASH_LENGTH           := 90.0   # ≈ DASH_SPEED * old 0.15s duration

# ─── FEEL CONSTANTS ─────────────
const FALL_GRAVITY_MULT     := 2.5
const LOW_JUMP_GRAVITY_MULT := 2.0
const AIR_CONTROL           := 0.75
const GROUND_ACCEL          := 20.0
const GROUND_DECEL          := 25.0
const AIR_ACCEL             := 10.0

# ─── HEALTH CONSTANTS ─────────────────────────────────────────
const MAX_HEALTH            := 100.0
const IFRAME_DURATION       := 0.8   # seconds of invincibility after being hit

# ─── VE CONSTANTS ─────────────────────────────────────────────
const VE_MAX             := 100.0
const VE_GAIN_SPRINT     := 2.0
const VE_GAIN_DODGE      := 5.0
const VE_GAIN_HIT_DEALT  := 3.0
const VE_GAIN_HIT_TAKEN  := 8.0
const VE_GAIN_SELFLESS   := 25.0

# ─── HEALING / ENERGY CONSTANTS ────────────────────────────────
# Hollow-Knight-style focus heal: hold "heal", channel-up, then tick
# damage out of the energy meter into HP for as long as the key is held.
const ENERGY_MAX                := 100.0
const ENERGY_GAIN_HIT_DEALT      := 10.0   # energy gained per landed hit
const ENERGY_GAIN_PARRY          := 15.0   # bonus energy for a successful parry
const ENERGY_GAIN_KILL           := 20.0   # bonus energy when a hit kills the enemy
const HALF_HEART_HP              := 10.0   # Minecraft-style: half heart = 10 hp, full heart = 20 hp
const HEAL_CHARGE_TIME           := 0.65   # channel-up delay before the first tick lands
const HEAL_TICK_INTERVAL         := 0.85   # time between each subsequent tick while held
const HEAL_ENERGY_COST_PER_TICK  := 30.0   # energy spent per tick
const HEAL_HP_PER_TICK           := HALF_HEART_HP   # hp restored per tick (one half-heart)

# ─── STATES ───────────────────────────────────────────────────
enum State {
	IDLE, RUN, JUMP, FALL,
	DASH, ROLL,
	LIGHT_COMBO, HEAVY_SWEEP,   # LIGHT_COMBO name kept for compatibility — Leesha now uses it for a single directional light attack, not a 3-hit combo
	HURT, DEAD, VEILBREAK,
	PARRY, LEDGE_GRAB, LEDGE_CLIMB,
	HEAL
}

# States in which a heal channel may never be started or continued.
const HEAL_BLOCKED_STATES := [
	State.HURT, State.DEAD, State.VEILBREAK,
	State.DASH, State.ROLL,
	State.LIGHT_COMBO, State.HEAVY_SWEEP, State.PARRY,
	State.LEDGE_GRAB, State.LEDGE_CLIMB,
]

# ─── SHARED STATE ─────────────────────────────────────────────
var current_state   : int     = State.IDLE
var current_health  : float   = MAX_HEALTH
var ve_meter        : float   = 0.0
var facing_right    : bool    = true
var jumps_used      : int     = 0
var is_dashing      : bool    = false
var dash_direction  : float   = 1.0
var dash_start_position : Vector2 = Vector2.ZERO   # distance-based termination reference point
var is_sprinting    : bool    = false
var is_in_veilbreak : bool    = false
var is_attacking    : bool    = false
var energy_meter    : float   = 0.0

# ─── HEALING CHANNEL STATE ─────────────────────────────────────
var _is_healing      : bool  = false
var _heal_timer      : float = 0.0   # countdown to the next tick

# ─── I-FRAME STATE ────────────────────────────────────────────
# Invincibility frames after being hit — prevents stun-lock.
# While true, take_damage() is a no-op.
# Set via _start_iframes(duration). Subclasses can read this
# to drive a flashing sprite effect.
var is_invincible   : bool    = false

# ─── HAZARD SAFE-GROUND TRACKING ───────────────────────────────
# Last stable grounded position, used by take_hazard_damage() to snap the
# player back to solid ground after touching an instant-damage hazard
# (spikes, etc.) — Hollow Knight style, instead of a hard respawn-to-bench.
var _last_safe_position : Vector2 = Vector2.ZERO

# Hazard hits must NOT mutate position/velocity from inside the Area2D's
# body_entered signal — that signal fires DURING move_and_slide()'s internal
# physics step, and move_and_slide() will then finish its slide calculation
# using the pre-callback velocity/position, silently overwriting our teleport
# (same issue already noted in Leesha's _pogo_bounce). So take_hazard_damage()
# only queues the hit here; _process_pending_hazard_hit() applies it AFTER
# move_and_slide() has fully finished for the frame.
var _hazard_hit_pending         : bool    = false
var _pending_hazard_half_hearts : int     = 0
var _pending_hazard_knockback   : Vector2 = Vector2.ZERO

# ─── STATE DEBUG LABEL ─────────────────────────────────────────
# A small floating label above the character showing current_state.
# Toggle off per-instance in the Inspector once you don't need it.
@export var show_state_label   : bool    = true
@export var state_label_offset : Vector2 = Vector2(0, -64)   # tune so it clears the sprite's head
var _state_label : Label

const STATE_LABELS := {
	State.IDLE: "Idle", State.RUN: "Running", State.JUMP: "Jumping", State.FALL: "Falling",
	State.DASH: "Dashing", State.ROLL: "Rolling",
	State.LIGHT_COMBO: "Attacking (Light)", State.HEAVY_SWEEP: "Attacking (Heavy)",
	State.HURT: "Hurt", State.DEAD: "Dead", State.VEILBREAK: "Veilbreak",
	State.PARRY: "Parrying", State.LEDGE_GRAB: "Ledge Grab", State.LEDGE_CLIMB: "Climbing",
	State.HEAL: "Healing",
}

# ─── NODES ────────────────────────────────────────────────────
@onready var coyote_timer        : Timer             = $CoyoteTimer
@onready var jump_buffer_timer   : Timer             = $JumpBufferTimer
@onready var dash_cooldown_timer : Timer             = $DashCooldownTimer
@onready var col_shape           : CollisionShape2D  = $CollisionShape2D
var anim_tree   : AnimationTree   = null
var anim_player : AnimationPlayer = null

# ─── SHRINK-SHAPE CACHE (used by slide & Leesha's roll) ────────
# We resize the shape directly (not col_shape.scale) because scaling a
# CollisionShape2D node does NOT reliably shrink the physics body in Godot 4.
# These are populated once in _ready from the shape's actual inspector values.
var _stand_shape_height : float = 0.0   # full-height capsule/rect height
var _stand_shape_offset : float = 0.0   # full-height shape Y offset (col_shape.position.y)
var _crouch_height_ratio: float = 0.55  # shrunk shape's fraction of standing height, used by slide/roll

# ─── SIGNALS ──────────────────────────────────────────────────
signal ve_meter_changed(new_value: float)
signal energy_changed(new_value: float)
signal veilbreak_triggered
signal veilbreak_ended
signal state_changed(new_state: int)
signal health_changed(new_value: float)
signal player_died

# ─────────────────────────────────────────────────────────────
func _ready() -> void:
	if has_node("AnimationTree"):
		anim_tree = $AnimationTree
	if has_node("AnimationPlayer"):
		anim_player = $AnimationPlayer
	_setup_state_label()
	# Cache the standing shape dimensions so _set_crouch can resize correctly.
	_cache_stand_shape()

func _physics_process(delta: float) -> void:
	_apply_gravity(delta)
	_handle_dash(delta)
	_handle_movement(delta)
	_handle_jump()
	_handle_veilbreak()
	_handle_heal(delta)
	_update_ve_sprint(delta)
	move_and_slide()
	_process_pending_hazard_hit()
	_post_move_checks()
	_update_facing()
	_update_safe_position()

# ─── GRAVITY ──────────────────────────────────────────────────
func _apply_gravity(delta: float) -> void:
	if is_dashing: return
	if not is_on_floor():
		var mult : float = 1.0
		if velocity.y > 0:
			mult = FALL_GRAVITY_MULT
		elif velocity.y < 0 and not Input.is_action_pressed("jump"):
			mult = LOW_JUMP_GRAVITY_MULT
		velocity.y += GRAVITY * mult * delta
		velocity.y  = min(velocity.y, 900.0)
		if velocity.y > 0 and current_state not in [State.DASH, State.LIGHT_COMBO, State.HEAVY_SWEEP, State.HURT, State.DEAD, State.VEILBREAK]:
			_change_state(State.FALL)
	else:
		if jumps_used > 0:
			jumps_used = 0
		if current_state == State.FALL or current_state == State.JUMP:
			_change_state(State.IDLE)

# ─── MOVEMENT ─────────────────────────────────────────────────
func _handle_movement(delta: float) -> void:
	if is_dashing: return
	if current_state in [State.HURT, State.DEAD]: return
	if current_state == State.HEAL:
		is_sprinting = false
		velocity.x   = move_toward(velocity.x, 0.0, GROUND_DECEL * delta)
		return

	var dir := Input.get_axis("move_left", "move_right")
	is_sprinting = Input.is_action_pressed("dash") and is_on_floor() and dir != 0

	var speed : float = SPRINT_SPEED if is_sprinting else WALK_SPEED

	var control : float = AIR_CONTROL if not is_on_floor() else 1.0
	var accel   : float = GROUND_ACCEL if is_on_floor() else AIR_ACCEL

	if dir != 0:
		var target_x : float = dir * speed * control
		velocity.x   = lerp(velocity.x, target_x, accel * delta)
		facing_right = dir > 0
		if is_on_floor() and current_state == State.IDLE:
			_change_state(State.RUN)
	else:
		var decel : float = GROUND_DECEL if is_on_floor() else AIR_ACCEL * 0.5
		velocity.x = lerp(velocity.x, 0.0, decel * delta)
		if is_on_floor() and current_state == State.RUN:
			_change_state(State.IDLE)

# ─── JUMP ─────────────────────────────────────────────────────
func _handle_jump() -> void:
	if is_on_floor():
		coyote_timer.start()

	if Input.is_action_just_pressed("jump"):
		if current_state in [State.HURT, State.DEAD, State.VEILBREAK, State.HEAL]: return
		if is_on_floor() or not coyote_timer.is_stopped():
			_do_jump(JUMP_FORCE)
		elif jumps_used < _get_max_jumps():
			_do_jump_override()
		else:
			jump_buffer_timer.start()

	if is_on_floor() and not jump_buffer_timer.is_stopped():
		_do_jump(JUMP_FORCE)
		jump_buffer_timer.stop()

	if Input.is_action_just_released("jump") and velocity.y < -200:
		velocity.y *= 0.5

func _do_jump(force: float) -> void:
	velocity.y = force
	jumps_used += 1
	coyote_timer.stop()
	_change_state(State.JUMP)

func _get_max_jumps() -> int:
	return 1
	
func _do_jump_override() -> void:
	_do_jump(DOUBLE_JUMP_FORCE)

# ─── DASH ─────────────────────────────────────────────────────
func _handle_dash(delta: float) -> void:
	if is_dashing:
		velocity.x = dash_direction * DASH_SPEED
		velocity.y = 0.0
		# Distance-based termination: end the dash once this much distance
		# has actually been covered, rather than after a fixed duration.
		# Keeps the dash's reach consistent through hit-stop/frame hitches
		# and cuts it short cleanly on wall impact instead of overshooting.
		var traveled : float = global_position.distance_to(dash_start_position)
		if traveled >= DASH_LENGTH or is_on_wall():
			is_dashing = false
			velocity.x = dash_direction * WALK_SPEED
			_change_state(State.IDLE)
		return

	if Input.is_action_just_pressed("dash") and not is_sprinting:
		if dash_cooldown_timer.is_stopped() and current_state not in [State.HURT, State.DEAD, State.HEAL]:
			_start_dash()

func _start_dash() -> void:
	var dir            := Input.get_axis("move_left", "move_right")
	dash_direction      = dir if dir != 0.0 else (1.0 if facing_right else -1.0)
	is_dashing          = true
	dash_start_position = global_position
	dash_cooldown_timer.start()
	_change_state(State.DASH)

# ─── SHAPE RESIZE HELPERS (used by Leesha's roll) ─────────────
func _set_crouch(crouching: bool) -> void:
	# Reset scale — we never use node scale for this; we resize the shape directly.
	col_shape.scale = Vector2.ONE
	if col_shape.shape == null: return

	if crouching:
		var new_h : float = _stand_shape_height * _crouch_height_ratio
		_apply_shape_height(new_h)
		# Sink the shape down so feet stay on the floor.
		# The shape's centre moves up by half the height we removed.
		var removed : float = _stand_shape_height - new_h
		col_shape.position.y = _stand_shape_offset + removed * 0.5
	else:
		_apply_shape_height(_stand_shape_height)
		col_shape.position.y = _stand_shape_offset

func _cache_stand_shape() -> void:
	# Must be called after @onready vars are ready.
	if col_shape == null or col_shape.shape == null: return
	_stand_shape_offset = col_shape.position.y
	var shp := col_shape.shape
	if shp is CapsuleShape2D:
		# CapsuleShape2D total height = height + 2 * radius
		_stand_shape_height = shp.height + shp.radius * 2.0
	elif shp is RectangleShape2D:
		_stand_shape_height = shp.size.y
	else:
		_stand_shape_height = 40.0   # safe fallback

func _apply_shape_height(h: float) -> void:
	var shp := col_shape.shape
	if shp is CapsuleShape2D:
		# Keep radius fixed; only shrink the cylindrical segment.
		var new_seg : float = max(0.0, h - shp.radius * 2.0)
		shp.height = new_seg
	elif shp is RectangleShape2D:
		shp.size.y = h

# ─── VEILBREAK ────────────────────────────────────────────────
func _handle_veilbreak() -> void:
	if Input.is_action_just_pressed("veilbreak"):
		if ve_meter >= VE_MAX and not is_in_veilbreak and current_state != State.HEAL:
			_trigger_veilbreak()

func _trigger_veilbreak() -> void:
	is_in_veilbreak = true
	_change_state(State.VEILBREAK)
	emit_signal("veilbreak_triggered")

func _end_veilbreak() -> void:
	is_in_veilbreak = false
	_change_state(State.IDLE)
	emit_signal("veilbreak_ended")

# ─── STATE MACHINE ────────────────────────────────────────────
func _change_state(new_state: int) -> void:
	if current_state == new_state: return
	_on_state_exit(current_state)
	current_state = new_state
	_on_state_enter(new_state)
	emit_signal("state_changed", new_state)
	_drive_anim_tree(new_state)
	_update_state_label()

func _on_state_exit(_old_state: int) -> void:
	pass

func _on_state_enter(_new_state: int) -> void:
	pass

# ─── STATE DEBUG LABEL ─────────────────────────────────────────
func _setup_state_label() -> void:
	if not show_state_label: return
	_state_label = Label.new()
	_state_label.custom_minimum_size = Vector2(140, 20)
	_state_label.position            = state_label_offset - Vector2(70, 0)
	_state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_state_label.z_index              = 100
	_state_label.add_theme_font_size_override("font_size", 14)
	_state_label.add_theme_color_override("font_color", Color.WHITE)
	_state_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_state_label.add_theme_constant_override("outline_size", 4)
	add_child(_state_label)
	_update_state_label()

func _update_state_label() -> void:
	if not is_instance_valid(_state_label): return
	_state_label.text = STATE_LABELS.get(current_state, State.keys()[current_state])

# ─── ANIMATION TREE DRIVER ────────────────────────────────────
func _drive_anim_tree(state: int) -> void:
	if not is_instance_valid(anim_tree): return
	var playback = anim_tree.get("parameters/playback")
	if playback == null: return

	match state:
		State.IDLE:         playback.travel("idle")
		State.RUN:          playback.travel("run")
		State.JUMP:         playback.travel("jump")
		State.FALL:         playback.travel("fall")
		State.DASH:         playback.travel("dash")
		State.ROLL:         playback.travel("slide")
		State.LIGHT_COMBO:  playback.travel("attack_light")
		State.HEAVY_SWEEP:  playback.travel("attack_heavy")
		State.HURT:         playback.travel("hurt")
		State.PARRY:        playback.travel("parry")
		State.LEDGE_GRAB:   playback.travel("ledge_grab")
		State.LEDGE_CLIMB:  playback.travel("ledge_climb")
		State.HEAL:         playback.travel("heal")

# ─── FACING ───────────────────────────────────────────────────
func _update_facing() -> void:
	if has_node("Sprite2D"):
		$Sprite2D.flip_h = not facing_right

# ─── POST MOVE ────────────────────────────────────────────────
func _post_move_checks() -> void:
	pass

# ─── HEALTH SYSTEM ────────────────────────────────────────────
func take_damage(amount: float, _attacker: Node = null) -> void:
	if current_state == State.DEAD: return
	# I-frames: ignore damage while invincible (prevents stun-lock)
	if is_invincible: return

	# Getting hit always breaks a heal channel — no healing through damage.
	if _is_healing:
		_stop_heal()

	current_health = max(current_health - amount, 0.0)
	on_hit_taken()
	emit_signal("health_changed", current_health)

	if current_health <= 0.0:
		_die()
	else:
		_change_state(State.HURT)
		_start_iframes(IFRAME_DURATION)
		await get_tree().create_timer(0.4).timeout
		# Guard: node may have been freed or killed during the await.
		if not is_instance_valid(self): return
		if current_state == State.HURT:
			_change_state(State.IDLE)

## Records the current position as "safe ground" whenever grounded and not
## mid-hit/mid-iframe, so a later hazard touch has somewhere sane to snap back to.
## Called every physics tick from the base _physics_process, so it keeps working
## even for subclasses (Leesha) that override _post_move_checks()/_update_facing().
func _update_safe_position() -> void:
	if is_on_floor() and not is_invincible and current_state != State.DEAD:
		_last_safe_position = global_position

## Damage from environmental hazards (spikes, etc.) — separate from take_damage()
## on purpose: hazards are never parryable, so this bypasses any subclass
## take_damage() override (e.g. Leesha's parry check) entirely.
##
## IMPORTANT: this only QUEUES the hit. Called from inside an Area2D's
## body_entered signal (which fires mid move_and_slide()), so it must not
## touch global_position/velocity/current_state directly — see the note
## on _hazard_hit_pending above. The actual damage/teleport/knockback is
## applied by _process_pending_hazard_hit() right after move_and_slide()
## finishes for the frame.
func take_hazard_damage(half_hearts: int, knockback: Vector2 = Vector2.ZERO) -> void:
	if current_state == State.DEAD: return
	if is_invincible: return
	if _hazard_hit_pending: return   # already queued a hit this frame — ignore extra overlapping spike segments

	_hazard_hit_pending         = true
	_pending_hazard_half_hearts = half_hearts
	_pending_hazard_knockback   = knockback

## Applies a queued hazard hit. Safe to mutate position/velocity/state here —
## this runs after move_and_slide() has fully committed the frame's motion,
## so nothing will silently overwrite the teleport afterward.
func _process_pending_hazard_hit() -> void:
	if not _hazard_hit_pending: return
	_hazard_hit_pending = false

	# Getting hit always breaks a heal channel — no healing through damage.
	if _is_healing:
		_stop_heal()

	var amount : float = _pending_hazard_half_hearts * HALF_HEART_HP
	current_health = max(current_health - amount, 0.0)
	on_hit_taken()
	emit_signal("health_changed", current_health)

	if current_health <= 0.0:
		_die()
		return

	global_position = _last_safe_position
	velocity         = _pending_hazard_knockback
	_on_hazard_hit()

	_change_state(State.HURT)
	_start_iframes(IFRAME_DURATION)
	await get_tree().create_timer(0.4).timeout
	# Guard: node may have been freed or killed during the await.
	if not is_instance_valid(self): return
	if current_state == State.HURT:
		_change_state(State.IDLE)

func _start_iframes(duration: float) -> void:
	# Grants invincibility for `duration` seconds.
	# Subclasses can read `is_invincible` to drive a flashing sprite effect.
	# Guard against re-entry: if already invincible, don't stack a second timer.
	if is_invincible: return
	is_invincible = true
	await get_tree().create_timer(duration).timeout
	if not is_instance_valid(self): return
	is_invincible = false

func heal(amount: float) -> void:
	current_health = min(current_health + amount, MAX_HEALTH)
	emit_signal("health_changed", current_health)

func _die() -> void:
	_change_state(State.DEAD)
	velocity = Vector2.ZERO
	emit_signal("player_died")

# ─── VE METER ─────────────────────────────────────────────────
func add_ve(amount: float) -> void:
	ve_meter = clamp(ve_meter + amount, 0.0, VE_MAX)
	emit_signal("ve_meter_changed", ve_meter)

func _update_ve_sprint(delta: float) -> void:
	if is_sprinting:
		add_ve(VE_GAIN_SPRINT * delta)

func on_hit_dealt() -> void:
	add_ve(VE_GAIN_HIT_DEALT)
	add_energy(ENERGY_GAIN_HIT_DEALT)

func on_hit_taken() -> void:
	add_ve(VE_GAIN_HIT_TAKEN)

func on_selfless_act() -> void:
	add_ve(VE_GAIN_SELFLESS)

# ─── ENERGY METER ─────────────────────────────────────────────
# Fills from landing hits / successful parries (mirrors VE's hit-driven feel),
# and is spent on the focus-heal channel below.
func add_energy(amount: float) -> void:
	energy_meter = clamp(energy_meter + amount, 0.0, ENERGY_MAX)
	emit_signal("energy_changed", energy_meter)

func on_enemy_kill() -> void:
	add_energy(ENERGY_GAIN_KILL)

# ─── FOCUS HEAL ────────────────────────────────────────────────
# Hold "heal": after a short channel-up, HP regenerates in half-heart (10 hp)
# ticks for as long as the key stays held, the energy meter has enough
# charge, and nothing interrupts the channel (movement input, an attack,
# taking damage, full HP, or running out of energy all cancel it).
func _can_start_heal() -> bool:
	if current_health >= MAX_HEALTH: return false
	if energy_meter < HEAL_ENERGY_COST_PER_TICK: return false
	if not is_on_floor(): return false
	if current_state in HEAL_BLOCKED_STATES: return false
	return true

func _handle_heal(delta: float) -> void:
	if _is_healing:
		if not Input.is_action_pressed("heal"):
			_stop_heal()
			return
		if current_health >= MAX_HEALTH:
			_stop_heal()
			return
		if current_state in HEAL_BLOCKED_STATES:
			_stop_heal()
			return

		_heal_timer -= delta
		if _heal_timer <= 0.0:
			if energy_meter >= HEAL_ENERGY_COST_PER_TICK:
				_do_heal_tick()
				_heal_timer = HEAL_TICK_INTERVAL
			else:
				_stop_heal()
		return

	if Input.is_action_just_pressed("heal") and _can_start_heal():
		_start_heal()

func _start_heal() -> void:
	_is_healing = true
	_heal_timer = HEAL_CHARGE_TIME
	velocity.x  = 0.0
	_change_state(State.HEAL)

func _do_heal_tick() -> void:
	add_energy(-HEAL_ENERGY_COST_PER_TICK)
	heal(HEAL_HP_PER_TICK)
	_on_heal_tick()

func _on_heal_tick() -> void:
	pass   # hook for subclasses — sfx / particle burst / camera nudge

## Hook for subclasses — hit-stop / camera shake / sfx when a hazard
## (spikes, etc.) deals damage. Left empty here since GameManager/Camera2D
## access lives in the character subclass, same pattern as _on_heal_tick().
func _on_hazard_hit() -> void:
	pass

func _stop_heal() -> void:
	if not _is_healing: return
	_is_healing = false
	if current_state == State.HEAL:
		_change_state(State.IDLE)
