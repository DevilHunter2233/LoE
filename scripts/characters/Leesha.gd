extends player_base

# ─── LIGHT ATTACK CONSTANTS ─────────────────────────────────────
const LIGHT_DAMAGE               := 12.0
const LIGHT_ATTACK_DURATION      := 0.22   # full animation state duration (side / up)
const POGO_ATTACK_DURATION       := 0.15   # full animation state duration (down / pogo)
const LIGHT_HITBOX_DURATION      := 0.08   # hitbox-active window for side / up slash
const POGO_HITBOX_DURATION       := 0.06   # hitbox-active window for pogo (down slash)
const LIGHT_ATTACK_COOLDOWN      := 0.10   # delay before another light attack can start

# ─── HEAVY ATTACK CONSTANTS ──────────────────────────────────────
const HEAVY_DAMAGE               := 24.0
const HEAVY_LUNGE_SPEED          := 520.0
const HEAVY_LUNGE_DURATION       := 0.40   # full animation state duration
const HEAVY_HITBOX_DURATION      := 0.16   # hitbox-active window
const HEAVY_COOLDOWN             := 0.65   # delay before another heavy can start

# ─── POGO CONSTANTS ───────────────────────────────────────────
const POGO_BOUNCE_FORCE          := -600.0
const POGO_VE_GAIN               := 4.0

# ─── PARRY CONSTANTS ──────────────────────────────────────────
const PARRY_WINDOW               := 0.18
const PARRY_COOLDOWN             := 0.50
const PARRY_VE_GAIN              := 10.0

# ─── WALL CONSTANTS ───────────────────────────────────────────
const WALL_SLIDE_SPEED           := 60.0
const WALL_JUMP_X                := 260.0
const WALL_JUMP_Y                := -480.0
# Distance-based lock (replaces the old fixed-time lock). Control returns
# once Leesha has physically travelled this far from the wall she jumped
# off, OR she touches a new wall first — whichever comes first. This keeps
# the wall jump arc consistent even if something (hit-stop, knockback,
# a frame hitch) slows her down mid-arc, which a timer-based lock can't do.
const WALL_JUMP_MIN_DISTANCE     := 40.0

# ─── LEDGE GRAB / CLIMB CONSTANTS ──────────────────────────────
const LEDGE_FORWARD_DIST         := 14.0
const LEDGE_FRONT_RAY_Y          := -8.0
const LEDGE_TOP_RAY_Y            := -34.0
const LEDGE_CLIMB_FORWARD        := 22.0
const LEDGE_CLIMB_UP             := -46.0
const LEDGE_CLIMB_DURATION       := 0.32
const LEDGE_RELEASE_COOLDOWN     := 0.25

# ─── ROLL CONSTANTS ───────────────────────────────────────────
const ROLL_SPEED                 := 380.0
const ROLL_DURATION              := 0.28
const ROLL_COOLDOWN              := 0.55

# ─── AIR DASH CONSTANTS ───────────────────────────────────────
const AIR_DASH_SPEED             := 580.0
# Distance-based (replaces the old fixed-time duration), so the dash always
# covers the same physical distance regardless of hit-stop or frame hitches
# instead of sometimes coming up short or overshooting.
const AIR_DASH_LENGTH            := 82.0   # ≈ AIR_DASH_SPEED * old 0.14s duration

# ─── LIGHT ATTACK STATE ───────────────────────────────────────
var _light_attack_active         : bool  = false
var _light_attack_timer          : float = 0.0
var _light_attack_cooldown_timer : float = 0.0
var _pending_pogo_eligible       : bool  = false

# ─── HEAVY STATE ──────────────────────────────────────────────
var _heavy_lunging               : bool  = false
var _heavy_lunge_timer           : float = 0.0
var _heavy_lunge_direction       : float = 1.0   # facing direction captured when the lunge started
var _heavy_cooldown_timer        : float = 0.0

# ─── PARRY STATE ──────────────────────────────────────────────
var _parry_active                : bool  = false
var _parry_timer                 : float = 0.0
var _parry_cooldown_timer        : float = 0.0

# ─── WALL STATE ───────────────────────────────────────────────
var _on_wall                     : bool  = false
var _wall_direction              : float   = 0.0
var _wall_jump_locked            : bool    = false
var _wall_jump_start_position    : Vector2 = Vector2.ZERO   # distance-based lock reference point

# ─── LEDGE STATE ──────────────────────────────────────────────
var _ledge_grabbing              : bool    = false
var _ledge_climbing              : bool    = false
var _ledge_climb_timer           : float   = 0.0
var _ledge_climb_start           : Vector2 = Vector2.ZERO
var _ledge_climb_target          : Vector2 = Vector2.ZERO
var _ledge_direction             : float   = 1.0
var _ledge_ray_front             : RayCast2D
var _ledge_ray_top               : RayCast2D
var _ledge_release_cooldown      : float   = 0.0

# ─── ROLL STATE ───────────────────────────────────────────────
var _is_rolling                  : bool  = false
var _roll_timer                  : float = 0.0
var _roll_direction              : float = 1.0
var _roll_cooldown_timer         : float = 0.0

# ─── AIR DASH STATE ───────────────────────────────────────────
var _air_dash_used               : bool    = false
var _air_dashing                 : bool    = false
var _air_dash_direction          : float   = 1.0
var _air_dash_start_position     : Vector2 = Vector2.ZERO   # distance-based termination reference point

@export var has_double_jump : bool = true
@export var has_dash        : bool = true   ## Ground dodge-dash — locked until unlocked.
@export var has_air_dash    : bool = true   ## Single dash while airborne — locked until unlocked.

# ─── HITBOX TRACKING ──────────────────────────────────────────
# Each active hitbox keeps its own remaining-time and damage value.
# Durations are now per-attack (light, pogo, heavy differ).
var _hitbox_timers  : Dictionary = {}   # Area2D -> remaining active time
var _hitbox_damage  : Dictionary = {}   # Area2D -> damage for this activation

# ─── HITBOX NODES ─────────────────────────────────────────────
@onready var _hitbox_side  : Area2D = $Dagger     # light attack — side
@onready var _hitbox_up    : Area2D = $Dagger2    # light attack — up
@onready var _hitbox_down  : Area2D = $Dagger3    # light attack — down (pogo)
@onready var _hitbox_heavy : Area2D = $Dagger4    # heavy attack — side only

# ─────────────────────────────────────────────────────────────
func _ready() -> void:
	super._ready()
	add_to_group("player")
	for hb in [_hitbox_side, _hitbox_up, _hitbox_down, _hitbox_heavy]:
		_disable_hitbox(hb)
		hb.body_entered.connect(_on_hitbox_body_entered.bind(hb))
	health_changed.connect(_on_health_changed)
	player_died.connect(_on_player_died)
	_setup_ledge_rays()

func _get_max_jumps() -> int:
	return 2 if has_double_jump else 1
# ─── HITBOX HELPERS ───────────────────────────────────────────
func _disable_hitbox(hb: Area2D) -> void:
	hb.set_deferred("monitoring",  false)
	hb.set_deferred("monitorable", false)
	for child in hb.get_children():
		if child is CollisionShape2D:
			child.set_deferred("disabled", true)

func _enable_hitbox(hb: Area2D) -> void:
	hb.monitoring  = true
	hb.monitorable = true
	for child in hb.get_children():
		if child is CollisionShape2D:
			child.set_deferred("disabled", false)

# ─── LEDGE RAYCAST SETUP ───────────────────────────────────────
func _setup_ledge_rays() -> void:
	_ledge_ray_front = RayCast2D.new()
	_ledge_ray_front.position        = Vector2(0, LEDGE_FRONT_RAY_Y)
	_ledge_ray_front.target_position = Vector2(LEDGE_FORWARD_DIST, 0)
	_ledge_ray_front.collision_mask  = collision_mask
	_ledge_ray_front.enabled         = true
	add_child(_ledge_ray_front)

	_ledge_ray_top = RayCast2D.new()
	_ledge_ray_top.position        = Vector2(0, LEDGE_TOP_RAY_Y)
	_ledge_ray_top.target_position = Vector2(LEDGE_FORWARD_DIST, 0)
	_ledge_ray_top.collision_mask  = collision_mask
	_ledge_ray_top.enabled         = true
	add_child(_ledge_ray_top)

func _orient_ledge_rays(dir: float) -> void:
	_ledge_ray_front.target_position.x = LEDGE_FORWARD_DIST * dir
	_ledge_ray_top.target_position.x   = LEDGE_FORWARD_DIST * dir

# ─── PHYSICS LOOP ─────────────────────────────────────────────
var _was_on_floor_last_frame : bool = false   # cached pre-move floor state

func _physics_process(delta: float) -> void:
	# Capture floor state BEFORE move_and_slide so pogo landing on an enemy
	# head doesn't incorrectly see is_on_floor() = true and block the bounce.
	_was_on_floor_last_frame = is_on_floor()
	_tick_timers(delta)
	_update_wall_jump_lock()
	_update_active_hitboxes(delta)
	_handle_ledge(delta)
	_handle_wall_slide(delta)
	_handle_air_dash(delta)
	_handle_heavy_lunge(delta)
	_handle_roll(delta)
	_handle_light_attack(delta)
	_handle_parry(delta)
	_sync_all_hitbox_facing()
	if Input.is_action_just_pressed("attack_light"):
		_try_light_attack()
	if Input.is_action_just_pressed("attack_heavy"):
		_try_heavy_attack()
	if Input.is_action_just_pressed("parry"):
		_try_parry()
	if Input.is_action_just_pressed("roll") and is_on_floor():
		_try_roll()
	if Input.is_action_just_pressed("jump") and _heavy_lunging:
		_cancel_heavy_lunge()
	super._physics_process(delta)

func _tick_timers(delta: float) -> void:
	if _light_attack_cooldown_timer > 0.0: _light_attack_cooldown_timer -= delta
	if _heavy_cooldown_timer > 0.0:       _heavy_cooldown_timer -= delta
	if _roll_cooldown_timer  > 0.0: _roll_cooldown_timer -= delta
	if _parry_cooldown_timer > 0.0: _parry_cooldown_timer -= delta
	if _ledge_release_cooldown > 0.0: _ledge_release_cooldown -= delta

# ─── WALL JUMP LOCK (distance-based) ───────────────────────────
# Replaces the old fixed-time lock. Control returns once Leesha has
# travelled far enough from the wall, or the instant she reaches another
# wall (so she can't get stuck sailing past a wall she should've grabbed).
func _update_wall_jump_lock() -> void:
	if not _wall_jump_locked: return
	var traveled : float = absf(global_position.x - _wall_jump_start_position.x)
	if traveled >= WALL_JUMP_MIN_DISTANCE or is_on_wall():
		_wall_jump_locked = false

# ─── HITBOX FACING SYNC ───────────────────────────────────────
func _sync_all_hitbox_facing() -> void:
	var dir : float = 1.0 if facing_right else -1.0
	for hb in [_hitbox_side, _hitbox_up, _hitbox_down, _hitbox_heavy]:
		# Mirror position: move the hitbox to the correct side.
		hb.position.x = abs(hb.position.x) * dir
		# Mirror the shape itself so ConvexPolygon geometry faces correctly.
		hb.scale.x = dir

# ─── WALL SLIDE ───────────────────────────────────────────────
func _handle_wall_slide(_delta: float) -> void:
	if _ledge_grabbing or _ledge_climbing:
		_on_wall = false
		return
	if is_on_floor() or is_dashing or _air_dashing:
		_on_wall = false
		return
	if is_on_wall():
		var wall_normal    := get_wall_normal()
		_wall_direction     = -sign(wall_normal.x)
		var dir            := Input.get_axis("move_left", "move_right")
		if sign(dir) == sign(_wall_direction):
			_on_wall       = true
			velocity.y     = min(velocity.y, WALL_SLIDE_SPEED)
			facing_right   = _wall_direction < 0
			return
	_on_wall = false

# ─── WALL JUMP ────────────────────────────────────────────────
func _handle_jump() -> void:
	if _ledge_grabbing or _ledge_climbing: return
	if _on_wall and Input.is_action_just_pressed("jump"):
		if current_state not in [State.HURT, State.DEAD]:
			_do_wall_jump()
			return
	super._handle_jump()

func _do_wall_jump() -> void:
	velocity.x               = -_wall_direction * WALL_JUMP_X
	velocity.y               = WALL_JUMP_Y
	_on_wall                 = false
	_wall_jump_locked        = true
	_wall_jump_start_position = global_position
	jumps_used               = 1
	_change_state(State.JUMP)

func _handle_movement(delta: float) -> void:
	if _ledge_grabbing or _ledge_climbing: return
	if _wall_jump_locked: return
	super._handle_movement(delta)

func _apply_gravity(delta: float) -> void:
	if _ledge_grabbing or _ledge_climbing: return
	super._apply_gravity(delta)

# ─── DOUBLE JUMP ──────────────────────────────────────────────
func _do_jump_override() -> void:
	_do_jump(DOUBLE_JUMP_FORCE)

# ─── LEDGE GRAB / CLIMB ─────────────────────────────────────────
func _handle_ledge(delta: float) -> void:
	if _ledge_climbing:
		_update_ledge_climb(delta)
		return

	if _ledge_grabbing:
		velocity = Vector2.ZERO
		var dir := Input.get_axis("move_left", "move_right")
		if Input.is_action_just_pressed("jump") or sign(dir) == _ledge_direction:
			_start_ledge_climb()
		elif sign(dir) == -_ledge_direction:
			_release_ledge()
		return

	if _ledge_release_cooldown > 0.0:
		return

	if is_on_floor() or _is_rolling or _air_dashing or _heavy_lunging or _wall_jump_locked or current_state == State.HEAL:
		return
	if not is_on_wall():
		return

	var wall_normal := get_wall_normal()
	var probe_dir: float = -sign(wall_normal.x)
	var input_dir   := Input.get_axis("move_left", "move_right")
	if sign(input_dir) != probe_dir:
		return

	_ledge_direction = probe_dir
	_orient_ledge_rays(_ledge_direction)
	_ledge_ray_front.force_raycast_update()
	_ledge_ray_top.force_raycast_update()

	var front_collider = _ledge_ray_front.get_collider() if _ledge_ray_front.is_colliding() else null
	var top_collider    = _ledge_ray_top.get_collider() if _ledge_ray_top.is_colliding() else null

	var front_is_wall : bool = _ledge_ray_front.is_colliding() \
		and not (is_instance_valid(front_collider) and front_collider.is_in_group("enemies"))
	var top_is_open    : bool = not _ledge_ray_top.is_colliding() \
		or (is_instance_valid(top_collider) and top_collider.is_in_group("enemies"))

	if front_is_wall and top_is_open:
		_start_ledge_grab()

func _start_ledge_grab() -> void:
	_ledge_grabbing = true
	velocity         = Vector2.ZERO
	jumps_used       = 0
	_air_dash_used   = false
	facing_right     = _ledge_direction > 0
	_change_state(State.LEDGE_GRAB)
	print("Leesha — Ledge grabbed")

func _release_ledge() -> void:
	_ledge_grabbing        = false
	_ledge_release_cooldown = LEDGE_RELEASE_COOLDOWN
	_change_state(State.FALL)

func _start_ledge_climb() -> void:
	_ledge_grabbing      = false
	_ledge_climbing      = true
	_ledge_climb_timer   = LEDGE_CLIMB_DURATION
	_ledge_climb_start   = global_position
	_ledge_climb_target  = global_position + Vector2(LEDGE_CLIMB_FORWARD * _ledge_direction, LEDGE_CLIMB_UP)
	col_shape.set_deferred("disabled", true)
	_change_state(State.LEDGE_CLIMB)

func _update_ledge_climb(delta: float) -> void:
	_ledge_climb_timer -= delta
	velocity             = Vector2.ZERO
	var t : float = 1.0 - clamp(_ledge_climb_timer / LEDGE_CLIMB_DURATION, 0.0, 1.0)
	global_position       = _ledge_climb_start.lerp(_ledge_climb_target, t)
	if _ledge_climb_timer <= 0.0:
		_ledge_climbing  = false
		global_position  = _ledge_climb_target
		col_shape.set_deferred("disabled", false)
		_change_state(State.IDLE)

# ─── AIR DASH ─────────────────────────────────────────────────
func _handle_air_dash(_delta: float) -> void:
	if not _air_dashing: return
	velocity.x = _air_dash_direction * AIR_DASH_SPEED
	velocity.y = 0.0
	# Distance-based termination: end the dash once Leesha has actually
	# covered AIR_DASH_LENGTH pixels, rather than after a fixed duration.
	# This keeps the dash's reach consistent even through hit-stop or a
	# frame hitch, and also cuts it short cleanly if she slams into a wall
	# (get_real_velocity()/position won't advance further than the wall).
	var traveled : float = global_position.distance_to(_air_dash_start_position)
	if traveled >= AIR_DASH_LENGTH or is_on_wall():
		_air_dashing = false
		velocity.x   = _air_dash_direction * WALK_SPEED

func _start_dash() -> void:
	if _ledge_grabbing or _ledge_climbing: return
	if current_state == State.HEAL: return

	if is_on_floor():
		if has_dash:
			super._start_dash()
		return

	# Airborne: only one air dash is ever allowed per air-time, and only if
	# unlocked. No fallback to the ground dash here — that was the bug that
	# let repeated presses keep re-triggering ground._start_dash() mid-air.
	if has_air_dash and not _air_dash_used:
		var dir             := Input.get_axis("move_left", "move_right")
		_air_dash_direction    = dir if dir != 0.0 else (1.0 if facing_right else -1.0)
		_air_dashing           = true
		_air_dash_used         = true
		_air_dash_start_position = global_position
		_change_state(State.DASH)

func _post_move_checks() -> void:
	if is_on_floor():
		_air_dash_used = false
		if _ledge_grabbing or _ledge_climbing:
			_ledge_grabbing = false
			_ledge_climbing = false

# ─── ROLL ─────────────────────────────────────────────────────
func _try_roll() -> void:
	if _roll_cooldown_timer > 0.0:  return
	if _is_rolling:                  return
	if _heavy_lunging: return
	if current_state in [State.HURT, State.DEAD, State.VEILBREAK, State.HEAVY_SWEEP, State.HEAL]: return
	_is_rolling          = true
	_roll_timer          = ROLL_DURATION
	_roll_direction      = 1.0 if facing_right else -1.0
	_roll_cooldown_timer = ROLL_COOLDOWN
	_start_iframes(ROLL_DURATION)
	_set_crouch(true)
	_change_state(State.ROLL)

func _handle_roll(delta: float) -> void:
	if not _is_rolling: return
	_roll_timer -= delta
	velocity.x   = _roll_direction * ROLL_SPEED
	if _roll_timer <= 0.0:
		_is_rolling = false
		_set_crouch(false)
		_change_state(State.IDLE)

# ─── LIGHT ATTACK — single, directional ────────────────────────
func _get_attack_direction() -> String:
	if Input.is_action_pressed("aim_up"):
		return "up"
	if Input.is_action_pressed("aim_down"):
		return "down"
	return "side"

func _try_light_attack() -> void:
	if _heavy_lunging: return
	if _light_attack_active: return
	if _light_attack_cooldown_timer > 0.0: return
	if current_state in [State.HURT, State.DEAD, State.VEILBREAK, State.LEDGE_GRAB, State.LEDGE_CLIMB, State.HEAL]: return

	var dir := _get_attack_direction()
	var hitbox : Area2D
	match dir:
		"up":   hitbox = _hitbox_up
		"down": hitbox = _hitbox_down
		_:      hitbox = _hitbox_side

	_pending_pogo_eligible       = (dir == "down")
	_light_attack_active         = true
	# Pogo uses a shorter animation; all other light attacks use standard duration.
	_light_attack_timer          = POGO_ATTACK_DURATION if dir == "down" else LIGHT_ATTACK_DURATION
	_light_attack_cooldown_timer = LIGHT_ATTACK_COOLDOWN
	_change_state(State.LIGHT_COMBO)
	print("Leesha — Light Attack (%s) | DMG: %.1f" % [dir, LIGHT_DAMAGE])
	# Hitbox duration also differs: pogo window is tighter than a standard slash.
	var hb_duration : float = POGO_HITBOX_DURATION if dir == "down" else LIGHT_HITBOX_DURATION
	_activate_hitbox(hitbox, LIGHT_DAMAGE, hb_duration)

func _handle_light_attack(delta: float) -> void:
	if not _light_attack_active: return
	_light_attack_timer -= delta
	if _light_attack_timer <= 0.0:
		_light_attack_active = false
		if current_state == State.LIGHT_COMBO:
			_change_state(State.IDLE)

# ─── HEAVY ATTACK — ground only, side only ─────────────────────
func _try_heavy_attack() -> void:
	if not is_on_floor(): return
	if _heavy_lunging: return
	if _heavy_cooldown_timer > 0.0: return
	if _light_attack_active: return
	if current_state in [State.HURT, State.DEAD, State.VEILBREAK, State.LEDGE_GRAB, State.LEDGE_CLIMB, State.HEAL]: return
	_heavy_lunging      = true
	_heavy_lunge_timer  = HEAVY_LUNGE_DURATION
	_heavy_cooldown_timer = HEAVY_COOLDOWN
	_heavy_lunge_direction = 1.0 if facing_right else -1.0
	_change_state(State.HEAVY_SWEEP)
	print("Leesha — Heavy Jab | DMG: %.1f" % HEAVY_DAMAGE)
	_activate_hitbox(_hitbox_heavy, HEAVY_DAMAGE, HEAVY_HITBOX_DURATION)

func _handle_heavy_lunge(delta: float) -> void:
	if not _heavy_lunging: return

	# If the player has flipped facing since the hit landed (e.g. pressed
	# the opposite movement key right after), don't keep forcing lunge
	# velocity in the new direction — that's what sent Leesha flying. Cancel
	# the lunge instead: velocity goes to zero, and normal _handle_movement
	# takes it from there (so holding the new key then moves her normally).
	var current_dir : float = 1.0 if facing_right else -1.0
	if current_dir != _heavy_lunge_direction:
		_cancel_heavy_lunge()
		return

	_heavy_lunge_timer -= delta
	velocity.x          = _heavy_lunge_direction * HEAVY_LUNGE_SPEED
	if _heavy_lunge_timer <= 0.0:
		_heavy_lunging = false
		velocity.x     = 0.0
		_change_state(State.IDLE)

func _cancel_heavy_lunge() -> void:
	if not _heavy_lunging: return
	_heavy_lunging      = false
	_heavy_lunge_timer  = 0.0
	velocity.x          = 0.0          # kill ALL lunge momentum
	# Clean the hitbox out of both tracking dicts so _update_active_hitboxes
	# doesn't try to tick a hitbox that no longer has a live attack behind it.
	_disable_hitbox(_hitbox_heavy)
	_hitbox_timers.erase(_hitbox_heavy)
	_hitbox_damage.erase(_hitbox_heavy)
	_change_state(State.IDLE)
# ─── PARRY ──────────────────────────────────────────────────────
func _try_parry() -> void:
	if _parry_cooldown_timer > 0.0: return
	if current_state in [State.HURT, State.DEAD, State.VEILBREAK, State.LEDGE_GRAB, State.LEDGE_CLIMB, State.HEAL]: return
	_parry_active         = true
	_parry_timer          = PARRY_WINDOW
	_parry_cooldown_timer = PARRY_COOLDOWN
	_change_state(State.PARRY)
	print("Leesha — Parry window open")

func _handle_parry(delta: float) -> void:
	if not _parry_active: return
	_parry_timer -= delta
	if _parry_timer <= 0.0:
		_parry_active = false
		if current_state == State.PARRY:
			_change_state(State.IDLE)

func take_damage(amount: float, attacker: Node = null) -> void:
	if _parry_active:
		_on_parry_success(attacker)
		return
	super.take_damage(amount, attacker)
	# Hit-stop and shake on player hit (only if still alive — _die() handles death separately).
	if current_state != State.DEAD:
		var gm : Node = get_node_or_null("/root/GameManager")
		if gm:
			gm.trigger_hit_stop(gm.HITSTOP_PLAYER_HIT)
		if has_node("Camera2D"):
			$Camera2D.trigger_shake(0.10, 0.10)

func _on_hazard_hit() -> void:
	var gm : Node = get_node_or_null("/root/GameManager")
	if gm:
		gm.trigger_hit_stop(gm.HITSTOP_PLAYER_HIT)
	if has_node("Camera2D"):
		$Camera2D.trigger_shake(0.12, 0.12)

func _on_parry_success(attacker: Node) -> void:
	_parry_active = false
	add_ve(PARRY_VE_GAIN)
	add_energy(ENERGY_GAIN_PARRY)
	print("Leesha — Parried!")
	var gm : Node = get_node_or_null("/root/GameManager")
	if gm:
		gm.trigger_hit_stop(gm.HITSTOP_PLAYER_HIT)
	if has_node("Camera2D"):
		$Camera2D.trigger_shake(0.10, 0.10)
	if is_instance_valid(attacker) and attacker.has_method("on_parried"):
		attacker.on_parried()
	if current_state == State.PARRY:
		_change_state(State.IDLE)

# ─── HITBOX ACTIVATION ────────────────────────────────────────
func _activate_hitbox(hitbox: Area2D, damage: float, duration: float) -> void:
	_hitbox_damage[hitbox] = damage
	_hitbox_timers[hitbox] = duration
	_enable_hitbox(hitbox)

func _update_active_hitboxes(delta: float) -> void:
	for hitbox in _hitbox_timers.keys():
		_hitbox_timers[hitbox] -= delta
		if _hitbox_timers[hitbox] <= 0.0:
			_disable_hitbox(hitbox)
			_hitbox_timers.erase(hitbox)
			_hitbox_damage.erase(hitbox)

func _on_hitbox_body_entered(body: Node, hitbox: Area2D) -> void:
	if not body.is_in_group("enemies"): return
	var dmg : float = _hitbox_damage.get(hitbox, 0.0)
	if body.has_method("take_damage"):
		var knockback_dir   : Vector2 = Vector2(1.0, 0.0) if facing_right else Vector2(-1.0, 0.0)
		# Knockback force differs per attack — heavy sends enemies flying,
		# pogo gives a small nudge (the bounce is the point, not the push).
		var knockback_force : float = 200.0
		if hitbox == _hitbox_heavy:
			knockback_force = 380.0
		elif hitbox == _hitbox_down:
			knockback_force = 120.0   # pogo — light sideways push
		else:
			knockback_force = 180.0   # standard light slash
		var was_alive : bool = body.current_health > 0.0   # snapshot BEFORE damage
		body.take_damage(dmg, knockback_dir, knockback_force)
		if was_alive and body.current_health <= 0.0:
			on_enemy_kill()
	on_hit_dealt()

	# ── Per-attack hit-stop and shake ──────────────────────────
	var gm : Node = get_node_or_null("/root/GameManager")
	if has_node("Camera2D"):
		var cam : Camera2D = $Camera2D
		if hitbox == _hitbox_heavy:
			if gm: gm.trigger_hit_stop(gm.HITSTOP_HEAVY)
			cam.trigger_shake(0.065, 0.08)
		elif hitbox == _hitbox_down and _pending_pogo_eligible and not _was_on_floor_last_frame:
			if gm: gm.trigger_hit_stop(gm.HITSTOP_POGO)
			cam.trigger_shake(0.02, 0.04)
		else:
			if gm: gm.trigger_hit_stop(gm.HITSTOP_LIGHT)
			cam.trigger_shake(0.03, 0.05)
	else:
		# No camera found — still apply hit-stop.
		if hitbox == _hitbox_heavy:
			if gm: gm.trigger_hit_stop(gm.HITSTOP_HEAVY)
		elif hitbox == _hitbox_down and _pending_pogo_eligible and not _was_on_floor_last_frame:
			if gm: gm.trigger_hit_stop(gm.HITSTOP_POGO)
		else:
			if gm: gm.trigger_hit_stop(gm.HITSTOP_LIGHT)

	# Pogo bounce — use pre-move floor state so landing on an enemy head
	# (which sets is_on_floor() = true in the same frame) still triggers.
	if hitbox == _hitbox_down and _pending_pogo_eligible and not _was_on_floor_last_frame:
		_pogo_bounce()

func _pogo_bounce() -> void:
	_pending_pogo_eligible = false
	# Remove from tracking dicts — _update_active_hitboxes will call _disable_hitbox
	# at the start of the NEXT frame (safely outside any signal callback).
	# Do NOT call _disable_hitbox directly here: we are inside body_entered signal
	# and touching physics state causes the CharacterBody2D to get pushed to -99999.
	_hitbox_timers[_hitbox_down] = 0.0   # force expire next tick
	velocity.y     = POGO_BOUNCE_FORCE
	jumps_used     = 0
	_air_dash_used = false
	add_ve(POGO_VE_GAIN)
	_change_state(State.JUMP)
	print("Leesha — Pogo!")

# ─── STATE HOOKS ──────────────────────────────────────────────
func _on_state_enter(_new_state: int) -> void:
	if _new_state == State.IDLE:
		_heavy_lunging = false

# ─── HEALTH TERMINAL FEEDBACK ─────────────────────────────────
func _on_health_changed(new_hp: float) -> void:
	print("Leesha HP: %.1f / %.1f" % [new_hp, MAX_HEALTH])

func _on_heal_tick() -> void:
	print("Leesha — Heal tick | +%.1f HP" % HEAL_HP_PER_TICK)
	if has_node("Camera2D"):
		$Camera2D.trigger_shake(0.04, 0.03)

func _on_player_died() -> void:
	print("Leesha — DIED")
	var gm : Node = get_node_or_null("/root/GameManager")
	if gm:
		gm.trigger_hit_stop(gm.HITSTOP_PLAYER_DEATH)
	if has_node("Camera2D"):
		$Camera2D.trigger_shake(0.275, 0.20)

# ─── VEILBREAK — SOLKHAN (stub) ───────────────────────────────
func _trigger_veilbreak() -> void:
	super._trigger_veilbreak()
	print("Leesha: Solkhan form — stub")

# ─── IFRAME SPRITE FLASH ──────────────────────────────────────
func _start_iframes(duration: float) -> void:
	super._start_iframes(duration)
	_flash_sprite(duration)

func _flash_sprite(duration: float) -> void:
	if not has_node("Sprite2D"): return
	var sprite   : Sprite2D = $Sprite2D
	var elapsed  : float    = 0.0
	var interval : float    = 0.08
	while elapsed < duration:
		if not is_instance_valid(self) or current_state == State.DEAD:
			break
		sprite.modulate.a = 0.3
		await get_tree().create_timer(interval).timeout
		if not is_instance_valid(self): return
		sprite.modulate.a = 1.0
		await get_tree().create_timer(interval).timeout
		if not is_instance_valid(self): return
		elapsed += interval * 2.0
	# Always restore alpha, even if we broke out early.
	if is_instance_valid(self):
		sprite.modulate.a = 1.0
