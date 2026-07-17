extends CharacterBody2D

# ─── enemy_base.gd ────────────────────────────────────────────────────────────
# Generic base AI for all ground enemies in Legends of Eryndal.
# Mirrors the architecture of player_base.gd:
#   • All shared constants, state variables, and timers live here.
#   • Core behaviours (gravity, patrol, chase, hurt, death) are implemented here.
#   • Subclasses override the virtual hooks (_do_attack, _on_state_enter, etc.)
#     to add their own weapon logic without touching base machinery.
#
# ─── SCENE NODE REQUIREMENTS (minimum) ───────────────────────────────────────
#   CharacterBody2D               ← root (this script or a subclass goes here)
#     CollisionShape2D            CapsuleShape2D recommended
#     Sprite2D
#     DetectionZone (Area2D)      CircleShape2D — radius controls aggro range
#       └─ CollisionShape2D
#     EdgeDetector (RayCast2D)    used to avoid walking off ledges
#     HealthBar (ProgressBar)     optional, auto-hidden if absent
#
#   Root node group  →  "enemies"
#   Player group     →  "player"
#   Terrain layer    →  collision layer 1  (TERRAIN_MASK constant below)
# ─────────────────────────────────────────────────────────────────────────────

class_name enemy_base

# ─── MOVEMENT & PHYSICS CONSTANTS ────────────────────────────────────────────
const GRAVITY              := 900.0
const TERRAIN_MASK         := 1

# ─── PATROL SCAN CONSTANTS ───────────────────────────────────────────────────
const EDGE_SCAN_STEP       := 4.0
const EDGE_SCAN_MAX        := 600.0
const EDGE_SCAN_DOWN       := 40.0
const EDGE_SCAN_WALL_H     := 20.0

# ─── BASE STATS (override via @export in the subclass or Inspector) ───────────
@export var patrol_speed           : float = 65.0
@export var chase_speed            : float = 95.0
@export var max_health             : float = 60.0
@export var attack_range           : float = 38.0   ## Horizontal reach to enter ATTACK state.
@export var attack_engage_margin   : float = 20.0   ## How much closer than attack_range the player must actually be before we commit to attacking — covers the gap between the visual range and where the weapon hitbox really lands. Applies symmetrically in both directions.
@export var attack_y_tolerance     : float = 48.0   ## Max vertical gap that still allows attacking.
@export var attack_windup          : float = 0.4    ## Pause before the hit lands (reaction window).
@export var attack_cooldown        : float = 1.2    ## Minimum gap between successive attacks.
@export var hurt_duration          : float = 0.35
@export var chase_memory           : float = 2.5    ## Seconds the enemy chases after losing sight.
@export var pursuit_duration       : float = 2.5    ## Seconds spent walking to last-known position.
@export var pursuit_stop_dist      : float = 10.0   ## Arrival radius for pursuit.
@export var turn_cooldown          : float = 0.5
@export var max_safe_fall_distance : float = 400.0
@export var vertical_chase_threshold : float = 60.0  ## Y gap beyond which the player counts as "on a different platform".
@export var chase_direction_deadzone : float = 14.0  ## Min |x diff| before direction/facing updates — kills flip jitter when roughly above/below the player.

# ─── PATROL BOUNDS ────────────────────────────────────────────────────────────
@export var patrol_left_edge         : float = 0.0
@export var patrol_right_edge        : float = 0.0
@export var auto_detect_patrol_edges : bool  = true
@export var passive                  : bool  = false   ## If true the enemy never aggros.

# ─── STATES ───────────────────────────────────────────────────────────────────
enum State { PATROL, CHASE, ATTACK, HURT, DEAD }

# ─── DEBUG LABEL ──────────────────────────────────────────────────────────────
@export var show_state_label   : bool    = true
@export var state_label_offset : Vector2 = Vector2(0, -72)

const STATE_LABELS := {
	State.PATROL: "Patrol",
	State.CHASE:  "Chase",
	State.ATTACK: "Attack",
	State.HURT:   "Hurt",
	State.DEAD:   "Dead",
}

# ─── SHARED STATE ─────────────────────────────────────────────────────────────
var current_state  : int   = State.PATROL
var current_health : float = 0.0   # set from max_health in _ready
var direction      : float = 1.0
var player         : Node  = null

# Attack timing
var _attack_cooldown_timer : float = 0.0
var _attack_windup_timer   : float = 0.0
var _in_windup             : bool  = false

# Misc timers / state flags
var _hurt_timer          : float = 0.0
var _idle_pause          : float = 0.0
var _chase_memory_timer  : float = 0.0
var _last_turn_ms        : int   = 0
var _player_in_detection : bool  = false

# Pursuit state — walks to last-known position when chase-memory expires.
var _last_known_player_pos : Vector2 = Vector2.ZERO
var _pursuit_timer         : float   = 0.0
var _is_pursuing           : bool    = false

# Platform landing re-detection
var _was_on_floor : bool = true

# Diving-to-lower-platform commitment — set once when we decide to chase the
# player down through a specific edge, held until we land again. Prevents
# recomputing (and flip-flopping) the direction every single frame.
var _is_diving        : bool  = false
var _diving_direction : float = 0.0

# ─── SIGNALS ──────────────────────────────────────────────────────────────────
signal health_changed(new_value: float)
signal enemy_died

# ─── NODE REFS ────────────────────────────────────────────────────────────────
var _sprite        : Sprite2D         = null
var _detection     : Area2D           = null
var _edge_detector : RayCast2D        = null
var _health_bar    : ProgressBar      = null
var _fill_style    : StyleBoxFlat     = null
var _state_label   : Label            = null

# ─── READY ────────────────────────────────────────────────────────────────────
func _ready() -> void:
	add_to_group("enemies")
	current_health = max_health

	if has_node("Sprite2D"):      _sprite        = $Sprite2D
	if has_node("DetectionZone"): _detection     = $DetectionZone
	if has_node("EdgeDetector"):  _edge_detector = $EdgeDetector
	if has_node("HealthBar"):     _health_bar    = $HealthBar

	if _detection:
		_detection.body_entered.connect(_on_detection_entered)
		_detection.body_exited.connect(_on_detection_exited)

	_init_patrol_bounds()
	_init_health_bar()
	_setup_state_label()

	_on_ready()   # virtual hook for subclasses

# Called at the end of _ready so subclasses can do extra initialisation
# without needing to call super._ready() and re-cache nodes.
func _on_ready() -> void:
	pass

# ─── PATROL BOUNDS SETUP ──────────────────────────────────────────────────────
func _init_patrol_bounds() -> void:
	if patrol_left_edge == 0.0 and patrol_right_edge == 0.0:
		if auto_detect_patrol_edges:
			_autodetect_patrol_edges()
		else:
			patrol_left_edge  = global_position.x - 80.0
			patrol_right_edge = global_position.x + 80.0

func _autodetect_patrol_edges() -> void:
	var margin := _get_body_half_width() + 6.0
	patrol_left_edge  = _scan_patrol_edge(-1.0, margin)
	patrol_right_edge = _scan_patrol_edge( 1.0, margin)

func _get_body_half_width() -> float:
	if has_node("CollisionShape2D"):
		var col : CollisionShape2D = $CollisionShape2D
		if col and col.shape:
			var s := col.shape
			if s is CapsuleShape2D:   return s.radius
			if s is CircleShape2D:    return s.radius
			if s is RectangleShape2D: return s.size.x * 0.5
	return 12.0

func _scan_patrol_edge(dir: float, margin: float) -> float:
	var space       := get_world_2d().direct_space_state
	var origin_y    := global_position.y
	var spawn_x     := global_position.x
	var last_safe_x := spawn_x
	var distance    := 0.0
	while distance < EDGE_SCAN_MAX:
		var px : float = spawn_x + dir * distance
		var fq := PhysicsRayQueryParameters2D.create(
			Vector2(px, origin_y - 4.0), Vector2(px, origin_y + EDGE_SCAN_DOWN), TERRAIN_MASK)
		fq.exclude = [self]
		if space.intersect_ray(fq).is_empty(): break
		var wq := PhysicsRayQueryParameters2D.create(
			Vector2(spawn_x, origin_y - EDGE_SCAN_WALL_H),
			Vector2(px,      origin_y - EDGE_SCAN_WALL_H), TERRAIN_MASK)
		wq.exclude = [self]
		if not space.intersect_ray(wq).is_empty(): break
		last_safe_x = px
		distance   += EDGE_SCAN_STEP
	return last_safe_x - dir * margin

# ─── PLATFORM LANDING RE-DETECTION ────────────────────────────────────────────
# While chasing, the enemy can fall off a ledge onto a different platform.
# Its old patrol_left_edge/patrol_right_edge no longer describe where it is
# standing, so re-scan as soon as it touches down outside that old range.
const PLATFORM_RELAND_MARGIN := 8.0

func _check_platform_landing() -> void:
	var on_floor_now := is_on_floor()
	if on_floor_now and not _was_on_floor:
		_is_diving = false
		if auto_detect_patrol_edges \
		and (global_position.x < patrol_left_edge - PLATFORM_RELAND_MARGIN \
		or   global_position.x > patrol_right_edge + PLATFORM_RELAND_MARGIN):
			_autodetect_patrol_edges()
	_was_on_floor = on_floor_now

# ─── HEALTH BAR SETUP ─────────────────────────────────────────────────────────
func _init_health_bar() -> void:
	if not _health_bar: return
	_health_bar.max_value = max_health
	_health_bar.value     = max_health
	_health_bar.visible   = true
	_fill_style           = StyleBoxFlat.new()
	_fill_style.bg_color  = Color(0.2, 0.85, 0.2)
	_health_bar.add_theme_stylebox_override("fill", _fill_style)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.15, 0.15, 0.15)
	_health_bar.add_theme_stylebox_override("background", bg)

# ─── STATE DEBUG LABEL ────────────────────────────────────────────────────────
func _setup_state_label() -> void:
	if not show_state_label: return
	_state_label          = Label.new()
	_state_label.name     = "StateLabel"
	_state_label.position = state_label_offset - Vector2(20.0, 0.0)
	_state_label.add_theme_font_size_override("font_size", 8)
	_state_label.modulate = Color(1.0, 1.0, 0.3)
	add_child(_state_label)
	_update_state_label()

func _update_state_label() -> void:
	if not is_instance_valid(_state_label): return
	_state_label.text = STATE_LABELS.get(current_state, State.keys()[current_state])

# ─── PHYSICS LOOP ─────────────────────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	if current_state == State.DEAD: return
	_apply_gravity(delta)
	_tick_timers(delta)
	match current_state:
		State.PATROL: _update_patrol(delta)
		State.CHASE:  _update_chase()
		State.ATTACK: _update_attack()
		State.HURT:   _update_hurt()
	move_and_slide()
	_check_platform_landing()
	_sync_facing()

func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y += GRAVITY * delta
	else:
		velocity.y = 0.0

func _tick_timers(delta: float) -> void:
	if _attack_cooldown_timer > 0.0:
		_attack_cooldown_timer -= delta

	if _in_windup:
		_attack_windup_timer -= delta
		if _attack_windup_timer <= 0.0:
			_in_windup = false
			_on_windup_finished()

	if _hurt_timer > 0.0:
		_hurt_timer -= delta
		if _hurt_timer <= 0.0 and current_state == State.HURT:
			_change_state(State.CHASE if player != null else State.PATROL)

	if _idle_pause > 0.0:
		_idle_pause -= delta

	_tick_extra_timers(delta)

# Virtual — subclasses add their own per-frame timers here.
func _tick_extra_timers(_delta: float) -> void:
	pass

# ─── PATROL ───────────────────────────────────────────────────────────────────
func _update_patrol(delta: float) -> void:
	if _is_pursuing:
		_pursuit_timer -= delta
		var dist_x : float = abs(global_position.x - _last_known_player_pos.x)
		if _pursuit_timer <= 0.0 or dist_x < pursuit_stop_dist or is_on_wall():
			_is_pursuing = false
		else:
			var dir : float = sign(_last_known_player_pos.x - global_position.x)
			direction  = dir
			velocity.x = dir * patrol_speed
			return

	if _idle_pause > 0.0:
		velocity.x = 0.0
		return

	var can_turn : bool = (Time.get_ticks_msec() - _last_turn_ms) >= int(turn_cooldown * 1000.0)
	if can_turn:
		if _edge_detector:
			_edge_detector.target_position = Vector2(direction * 20.0, 30.0)
			_edge_detector.force_raycast_update()
			if not _edge_detector.is_colliding():
				_turn_around(); return
		if direction > 0.0 and global_position.x >= patrol_right_edge:
			_turn_around(); return
		if direction < 0.0 and global_position.x <= patrol_left_edge:
			_turn_around(); return
		if is_on_wall():
			_turn_around(); return
	velocity.x = direction * patrol_speed

func _turn_around() -> void:
	direction     = -direction
	velocity.x    = 0.0
	_idle_pause   = randf_range(0.2, 0.9)
	_last_turn_ms = Time.get_ticks_msec()

# ─── CHASE ────────────────────────────────────────────────────────────────────
func _update_chase() -> void:
	if player == null:
		_change_state(State.PATROL); return

	if _is_player_attackable():
		_change_state(State.ATTACK); return

	var sees := _can_see_player()
	if sees or _player_in_detection:
		_chase_memory_timer = chase_memory
		if sees:
			_last_known_player_pos = player.global_position
	else:
		_chase_memory_timer -= get_physics_process_delta_time()
		if _chase_memory_timer <= 0.0:
			_start_pursuit()
			return

	var x_diff : float = player.global_position.x - global_position.x
	var y_diff : float = player.global_position.y - global_position.y   # > 0 means player is below us
	var vertically_separated : bool = abs(y_diff) > vertical_chase_threshold

	# ── Player is on a platform ABOVE us ───────────────────────────────────
	# We can't climb to them. Shuffle to sit roughly underneath, but still
	# respect our own platform's edges — there's no reason to fall off a
	# ledge just to get marginally closer horizontally to someone we can't
	# reach anyway. Direction only updates outside the deadzone so the
	# sprite doesn't flip every frame from sub-pixel jitter while stopped.
	if vertically_separated and y_diff < 0.0:
		_is_diving = false
		if abs(x_diff) <= chase_direction_deadzone:
			velocity.x = 0.0
			return

		direction = sign(x_diff)
		var hold_speed : float = direction * chase_speed
		if is_on_floor() and _edge_detector:
			_edge_detector.target_position = Vector2(direction * 20.0, 30.0)
			_edge_detector.force_raycast_update()
			if not _edge_detector.is_colliding() and not _has_landing_below(direction):
				hold_speed = 0.0
		velocity.x = hold_speed
		return

	# ── Player is on a platform BELOW us ────────────────────────────────────
	# Commit to one verified-safe edge and hold that decision until we land
	# again (cleared in _check_platform_landing) — recomputing every frame
	# from near-zero x_diff is exactly what caused the flicker-in-place bug.
	if vertically_separated and y_diff > 0.0:
		if not _is_diving:
			_diving_direction = _pick_dive_direction(x_diff)
			_is_diving        = _diving_direction != 0.0

		if not _is_diving:
			# No safe (no-fall-damage) drop on either side — can't reach them
			# right now. Face their general direction without spamming flips.
			if abs(x_diff) > chase_direction_deadzone:
				direction = sign(x_diff)
			velocity.x = 0.0
			return

		direction  = _diving_direction
		velocity.x = direction * chase_speed
		return

	# ── Roughly level with the player ───────────────────────────────────────
	_is_diving = false
	if abs(x_diff) > chase_direction_deadzone:
		direction = sign(x_diff)

	var desired_speed : float = direction * chase_speed
	if is_on_floor() and _edge_detector and direction != 0.0:
		_edge_detector.target_position = Vector2(direction * 20.0, 30.0)
		_edge_detector.force_raycast_update()
		if not _edge_detector.is_colliding():
			if not _has_landing_below(direction):
				desired_speed = 0.0
	velocity.x = desired_speed

func _start_pursuit() -> void:
	_is_pursuing   = true
	_pursuit_timer = pursuit_duration
	player         = null
	_change_state(State.PATROL)

func _has_landing_below(dir: float) -> bool:
	var space   := get_world_2d().direct_space_state
	var probe_x := global_position.x + dir * 30.0
	var q       := PhysicsRayQueryParameters2D.create(
		Vector2(probe_x, global_position.y),
		Vector2(probe_x, global_position.y + max_safe_fall_distance),
		TERRAIN_MASK)
	q.exclude = [self]
	return not space.intersect_ray(q).is_empty()

# Probes straight down from one of our own patrol edges — used to decide
# whether diving off that side actually leads to a platform within
# max_safe_fall_distance (i.e. a "no fall damage" drop) before committing.
func _can_dive_from_edge(dir: float) -> bool:
	var edge_x : float = patrol_right_edge if dir > 0.0 else patrol_left_edge
	var space  := get_world_2d().direct_space_state
	var q      := PhysicsRayQueryParameters2D.create(
		Vector2(edge_x, global_position.y),
		Vector2(edge_x, global_position.y + max_safe_fall_distance),
		TERRAIN_MASK)
	q.exclude = [self]
	return not space.intersect_ray(q).is_empty()

# Chooses which edge to walk off when the player is on a lower platform.
# Prefers the side that's actually toward the player; falls back to the
# other side if that one isn't a safe drop; returns 0.0 if neither is.
func _pick_dive_direction(x_diff: float) -> float:
	var preferred : float
	if x_diff != 0.0:
		preferred = sign(x_diff)
	else:
		preferred = 1.0 if (patrol_right_edge - global_position.x) < (global_position.x - patrol_left_edge) else -1.0

	if _can_dive_from_edge(preferred):
		return preferred

	var other : float = -preferred
	if _can_dive_from_edge(other):
		return other

	return 0.0

# ─── ATTACK ───────────────────────────────────────────────────────────────────
func _update_attack() -> void:
	velocity.x = 0.0
	if player == null:
		_change_state(State.PATROL); return

	var x_diff : float = player.global_position.x - global_position.x
	var h_dist : float = abs(x_diff)
	var y_dist : float = abs(player.global_position.y - global_position.y)

	if h_dist > attack_range * 1.25 or y_dist > attack_y_tolerance:
		_cancel_windup()
		_change_state(State.CHASE); return

	if h_dist > 6.0:
		direction = sign(x_diff)

	if not _in_windup and _attack_cooldown_timer <= 0.0:
		_begin_windup()

# ─── ATTACK HELPERS ───────────────────────────────────────────────────────────
func _is_player_attackable() -> bool:
	if player == null: return false
	var x_dist : float = abs(player.global_position.x - global_position.x)
	var y_dist : float = abs(player.global_position.y - global_position.y)
	return x_dist <= attack_range - attack_engage_margin and y_dist <= attack_y_tolerance

func _begin_windup() -> void:
	_in_windup           = true
	_attack_windup_timer = attack_windup
	_on_windup_started()

func _cancel_windup() -> void:
	_in_windup           = false
	_attack_windup_timer = 0.0

# ─── VIRTUAL ATTACK HOOKS ─────────────────────────────────────────────────────
# Subclasses override these — no need to call super.

## Called the moment the windup animation/timer begins.
func _on_windup_started() -> void:
	pass

## Called when the windup timer expires — this is where damage should be dealt.
func _on_windup_finished() -> void:
	_attack_cooldown_timer = attack_cooldown

# ─── HURT ─────────────────────────────────────────────────────────────────────
func _update_hurt() -> void:
	velocity.x = move_toward(velocity.x, 0.0, 500.0 * get_physics_process_delta_time())

# ─── TAKE DAMAGE ──────────────────────────────────────────────────────────────
func take_damage(amount: float, knockback_direction: Vector2 = Vector2.ZERO, knockback_force: float = 200.0) -> void:
	if current_state == State.DEAD: return

	current_health = max(current_health - amount, 0.0)
	_update_health_bar()
	emit_signal("health_changed", current_health)

	if _sprite:
		_sprite.modulate = Color.RED
		var t := get_tree().create_timer(0.12, true, false, true)
		await t.timeout
		if is_instance_valid(self) and current_state != State.DEAD:
			_sprite.modulate = Color.WHITE

	if current_health <= 0.0:
		_die(); return

	if knockback_direction != Vector2.ZERO:
		velocity.x = knockback_direction.x * knockback_force
		velocity.y = -100.0

	_cancel_windup()
	_on_attack_interrupted()

	_hurt_timer = hurt_duration
	_change_state(State.HURT)

## Virtual — called whenever the current attack is interrupted (hurt or parried).
## Subclasses use this to disable their hitboxes.
func _on_attack_interrupted() -> void:
	pass

func heal(amount: float) -> void:
	current_health = min(current_health + amount, max_health)
	_update_health_bar()
	emit_signal("health_changed", current_health)

# ─── HEALTH BAR ───────────────────────────────────────────────────────────────
func _update_health_bar() -> void:
	if not _health_bar or not _fill_style: return
	_health_bar.value = current_health
	var pct := current_health / max_health
	if pct > 0.6:
		_fill_style.bg_color = Color(0.2, 0.85, 0.2)
	elif pct > 0.3:
		_fill_style.bg_color = Color(0.95, 0.72, 0.07)
	else:
		_fill_style.bg_color = Color(0.9, 0.15, 0.1)

# ─── DEATH ────────────────────────────────────────────────────────────────────
func _die() -> void:
	_change_state(State.DEAD)
	velocity = Vector2.ZERO
	for child in get_children():
		if child is CollisionShape2D:
			child.set_deferred("disabled", true)
	emit_signal("enemy_died")
	_on_death()

## Virtual — override to add loot drops, custom death FX, etc.
func _on_death() -> void:
	if _sprite:
		var tw := create_tween()
		tw.tween_property(_sprite, "modulate:a", 0.0, 0.7)
		tw.tween_callback(queue_free)
	else:
		await get_tree().create_timer(0.7).timeout
		queue_free()

# ─── LINE OF SIGHT ────────────────────────────────────────────────────────────
func _can_see_player() -> bool:
	if player == null: return false
	var space := get_world_2d().direct_space_state
	var q     := PhysicsRayQueryParameters2D.create(global_position, player.global_position, 1)
	q.exclude  = [self]
	var result := space.intersect_ray(q)
	return result.is_empty() or result.get("collider") == player

# ─── FACING ───────────────────────────────────────────────────────────────────
## Base implementation flips the Sprite2D. Subclasses can call super and then
## reposition their own hitboxes (see rift_creature.gd for an example).
func _sync_facing() -> void:
	if direction == 0.0: return
	if _sprite:
		_sprite.flip_h = direction < 0.0

# ─── STATE MACHINE ────────────────────────────────────────────────────────────
func _change_state(new_state: int) -> void:
	if current_state == new_state: return
	_on_state_exit(current_state)
	current_state = new_state
	if new_state != State.CHASE:
		_is_diving = false
	_on_state_enter(new_state)
	_update_state_label()

## Virtual — called just before leaving a state.
func _on_state_exit(_old_state: int) -> void:
	pass

## Virtual — called just after entering a new state.
## Subclasses override this instead of writing per-state setup in _update_*.
func _on_state_enter(_new_state: int) -> void:
	pass

# ─── DETECTION SIGNALS ────────────────────────────────────────────────────────
func _on_detection_entered(body: Node) -> void:
	if passive: return
	if body.is_in_group("player"):
		player               = body
		_player_in_detection = true
		_chase_memory_timer  = chase_memory
		if current_state == State.PATROL:
			_change_state(State.CHASE)

func _on_detection_exited(body: Node) -> void:
	if body.is_in_group("player"):
		_player_in_detection = false

# ─── PARRY HOOK ───────────────────────────────────────────────────────────────
## Called by the player's parry system when this enemy's attack is parried.
func on_parried() -> void:
	_cancel_windup()
	_on_attack_interrupted()
	_hurt_timer = hurt_duration * 2.0
	_change_state(State.HURT)
