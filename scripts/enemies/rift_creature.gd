extends enemy_base

# ─── rift_creature.gd ─────────────────────────────────────────────────────────
# Sword-wielding enemy specific to the Rift biome.
# Extends EnemyBase and adds only what is unique to this enemy:
#   • AttackHitBox node management (enable/disable for the sword swing)
#   • Deferred shape-cast damage delivery
#   • Hitbox X-flip to always face the player
#
# ─── SCENE NODE REQUIREMENTS (in addition to EnemyBase requirements) ─────────
#   AttackHitBox (Area2D)       RectangleShape2D or CircleShape2D
#     └─ CollisionShape2D       starts DISABLED; enabled only during swing
#
# ─── COLLISION SETUP ──────────────────────────────────────────────────────────
#   Enemy CharacterBody2D
#     Layer : enemy layer (e.g. layer 3)  |  Mask : terrain only (layer 1)
#   AttackHitBox (Area2D)
#     Layer : 0  |  Mask : player layer
#   DetectionZone (Area2D)
#     Mask  : player layer
#   Player CharacterBody2D
#     Mask  : terrain layer only
#       (pogo / bouncing handled by player's jump-on-enemy logic, not physics)
# ─────────────────────────────────────────────────────────────────────────────

# ─── SWORD TUNING ─────────────────────────────────────────────────────────────
## How long the sword hitbox stays hot after the windup finishes (ms).
const ATTACK_SWING_MS  := 500

# ─── SWORD STATE ──────────────────────────────────────────────────────────────
var _attacking       : bool = false
var _swing_start_ms  : int  = 0

# ─── HITBOX NODE REFS ─────────────────────────────────────────────────────────
var _attack_hitbox  : Area2D           = null
var _attack_shape   : CollisionShape2D = null
var _hitbox_offset_x : float           = 0.0   # cached magnitude for flip math

# ─── READY HOOK ───────────────────────────────────────────────────────────────
func _on_ready() -> void:
	if has_node("AttackHitBox"):
		_attack_hitbox   = $AttackHitBox
		_hitbox_offset_x = abs(_attack_hitbox.position.x)
		for child in _attack_hitbox.get_children():
			if child is CollisionShape2D:
				_attack_shape = child
				break
		if _attack_shape:
			_attack_shape.set_deferred("disabled", true)

	print("RiftCreature ready | HP %.0f | Patrol %.0f→%.0f | passive: %s" % [
		max_health, patrol_left_edge, patrol_right_edge, passive])

# ─── EXTRA TIMER TICK ─────────────────────────────────────────────────────────
func _tick_extra_timers(_delta: float) -> void:
	if _attacking:
		if (Time.get_ticks_msec() - _swing_start_ms) >= ATTACK_SWING_MS:
			_attacking = false
			_disable_hitbox()

# ─── WINDUP HOOKS ─────────────────────────────────────────────────────────────
func _on_windup_started() -> void:
	pass   # Play wind-up animation here, e.g.: $AnimationPlayer.play("attack_windup")

func _on_windup_finished() -> void:
	super._on_windup_finished()   # sets _attack_cooldown_timer
	if current_state in [State.HURT, State.DEAD]: return

	_attacking      = true
	_swing_start_ms = Time.get_ticks_msec()

	if _attack_shape:
		_attack_shape.set_deferred("disabled", false)

	_deferred_damage_check.call_deferred()

# ─── DAMAGE DELIVERY ──────────────────────────────────────────────────────────
# Uses a deferred shape cast so set_deferred("disabled", false) has applied.
# This hits the player even if they were already overlapping when the shape
# turned on — get_overlapping_bodies() misses bodies that entered while the
# shape was disabled, so we bypass it with an instant intersect_shape call.
func _deferred_damage_check() -> void:
	if not is_instance_valid(self): return
	if current_state in [State.HURT, State.DEAD]: return
	if player == null or _attack_hitbox == null or _attack_shape == null: return

	var space   := get_world_2d().direct_space_state
	var shape_q := PhysicsShapeQueryParameters2D.new()
	shape_q.shape          = _attack_shape.shape
	shape_q.transform      = _attack_hitbox.global_transform
	shape_q.collision_mask = _attack_hitbox.collision_mask
	shape_q.exclude        = [self]

	var results := space.intersect_shape(shape_q)
	var hit := false
	for r in results:
		if r.get("collider") == player:
			hit = true
			break

	if hit and player.has_method("take_damage"):
		player.take_damage(10.0)   # ATTACK_DAMAGE — tune in Inspector via exported base vars
	else:
		pass   # swing missed — play whoosh SFX here if desired

# ─── ATTACK INTERRUPTED HOOK ──────────────────────────────────────────────────
func _on_attack_interrupted() -> void:
	_attacking = false
	_disable_hitbox()

# ─── HITBOX HELPERS ───────────────────────────────────────────────────────────
func _disable_hitbox() -> void:
	if _attack_shape:
		_attack_shape.set_deferred("disabled", true)

# ─── FACING — extends base to also flip the hitbox ────────────────────────────
func _sync_facing() -> void:
	super._sync_facing()   # flips Sprite2D
	if _attack_hitbox:
		_attack_hitbox.position.x = _hitbox_offset_x * direction
