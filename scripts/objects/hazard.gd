extends Area2D

## Damage dealt in half-hearts (HALF_HEART_HP = 10 HP, matches player_base.gd)
@export var damage_half_hearts : int   = 1
@export var knockback_force    : float = 250.0

func _ready() -> void:
	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node2D) -> void:
	if not body.is_in_group("player"):
		return
	if not body.has_method("take_hazard_damage"):
		return

	# Knockback direction: away from the spike horizontally, always popped
	# upward a bit so it reads as a proper "yeeted off the hazard" hit.
	var away_x : float = signf(body.global_position.x - global_position.x)
	if away_x == 0.0:
		away_x = 1.0 if body.facing_right else -1.0
	var knockback_dir := Vector2(away_x, -0.6).normalized()

	body.take_hazard_damage(damage_half_hearts, knockback_dir * knockback_force)
