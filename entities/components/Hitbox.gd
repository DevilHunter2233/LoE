extends Area2D
class_name Hitbox

# ─────────────────────────────────────────────
# Signals
# ─────────────────────────────────────────────
# Emitted once per valid hit. Connect this to GameManager for hitstop/screenshake
# instead of coupling Hitbox directly to GameManager.
signal hit_landed(target: Node, damage: float)

# ─────────────────────────────────────────────
# Exports  (set per-hitbox in the Inspector)
# ─────────────────────────────────────────────
@export var damage: float = 10.0
@export var knockback_force: float = 200.0

# ─────────────────────────────────────────────
# Internal state
# ─────────────────────────────────────────────
# Tracks every body already hit this swing so one enable→disable cycle
# can never hit the same target twice, even if it stays inside the shape.
var _hit_entities: Array = []

# ─────────────────────────────────────────────
# Lifecycle
# ─────────────────────────────────────────────
func _ready() -> void:
	# Hitboxes start disabled. Call enable_hitbox() from an animation track
	# or from code at the start of an attack window.
	monitoring = false
	monitorable = false
	body_entered.connect(_on_body_entered)

# ─────────────────────────────────────────────
# Public API — call from character scripts or AnimationPlayer tracks
# ─────────────────────────────────────────────
func enable_hitbox() -> void:
	_hit_entities.clear()
	set_deferred("monitoring", true)

func disable_hitbox() -> void:
	set_deferred("monitoring", false)
	_hit_entities.clear()

# ─────────────────────────────────────────────
# Hit delivery
# ─────────────────────────────────────────────
func _on_body_entered(body: Node) -> void:
	# Skip if already hit this swing
	if body in _hit_entities:
		return
	_hit_entities.append(body)

	# Resolve knockback direction from hitbox position toward target
	var kb_dir: Vector2 = Vector2.ZERO
	if body is Node2D:
		kb_dir = (body.global_position - global_position).normalized()

	# Call take_damage directly on the entity — works for any player, enemy, or boss
	if body.has_method("take_damage"):
		body.take_damage(damage, kb_dir, knockback_force)
		hit_landed.emit(body, damage)
