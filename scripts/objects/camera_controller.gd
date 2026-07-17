# camera_controller.gd
# Attach this script to your Camera2D node.
# It handles:
#   - Smooth follow of the player (position smoothing)
#   - Y-damping adjustment on fast fall (shows more of what's below)
#   - Screen shake via trigger_shake(strength, duration)
#
# HOW TO USE:
#   1. Attach to Camera2D in Kael/Leesha/Dragen scene
#   2. Set `player` export to the CharacterBody2D root
#   3. Shake is called from Leesha/character scripts:
#      $Camera2D.trigger_shake(0.03, 0.05)   — light hit
#      $Camera2D.trigger_shake(0.065, 0.08)  — heavy hit
#      $Camera2D.trigger_shake(0.10, 0.10)   — player hit
#      $Camera2D.trigger_shake(0.275, 0.20)  — player death
#      (see SHAKE REFERENCE TABLE below for full list)

extends Camera2D

# ─── EXPORTS ──────────────────────────────────────────────────
@export var player                   : CharacterBody2D  ## Drag your character root here
@export var fall_speed_threshold     : float = -280.0   ## Y velocity below this = falling fast
@export var fall_y_damp              : float = 1.8      ## Damping when falling (looser)
@export var normal_y_damp            : float = 5.0      ## Damping at rest / rising
@export var damp_lerp_speed          : float = 6.0      ## How quickly damping transitions

# ─── SHAKE REFERENCE TABLE ────────────────────────────────────
# Event                     strength    duration
# Light attack hits enemy   0.03        0.05
# Heavy attack hits enemy   0.065       0.08
# Pogo hit                  0.02        0.04
# Player gets hit           0.10        0.10
# Strong enemy hits player  0.15        0.12
# Player death              0.275       0.20
# Mini-boss hit             0.115       0.10
# Mini-boss death           0.25        0.20
# Boss hit                  0.14        0.12
# Boss stagger              0.275       0.15
# Boss death                0.55        0.40

# ─── SHAKE STATE ──────────────────────────────────────────────
var _shake_strength  : float = 0.0   # current strength (decays to 0 over duration)
var _shake_max       : float = 0.0   # strength at the moment trigger_shake was called
var _shake_duration  : float = 0.0   # total duration of this shake event
var _shake_elapsed   : float = 0.0   # time since shake started

# ─── INTERNAL ─────────────────────────────────────────────────
var _current_y_damp  : float = 5.0
var _has_lerped_down : bool  = false

# ─────────────────────────────────────────────────────────────
func _ready() -> void:
	_current_y_damp = normal_y_damp

func _process(delta: float) -> void:
	_update_y_damp(delta)
	_update_shake(delta)

# ─── Y DAMPING ────────────────────────────────────────────────
func _update_y_damp(delta: float) -> void:
	if not is_instance_valid(player): return

	var vel_y : float = player.velocity.y

	if vel_y < fall_speed_threshold and not _has_lerped_down:
		_has_lerped_down = true
		_current_y_damp  = lerpf(_current_y_damp, fall_y_damp, damp_lerp_speed * delta)

	elif vel_y >= 0.0 and _has_lerped_down:
		_has_lerped_down = false
		_current_y_damp  = lerpf(_current_y_damp, normal_y_damp, damp_lerp_speed * delta)

	position_smoothing_speed = _current_y_damp

# ─── SHAKE ────────────────────────────────────────────────────
# trigger_shake(strength, duration)
#   strength — peak pixel offset (e.g. 0.03 for a light tap, 0.55 for boss death)
#   duration — how many seconds until the shake fully dies out (linear decay)
#
# If called while a shake is already running, it takes the stronger
# of the two strengths and the longer of the two durations — so
# rapid hits stack naturally instead of resetting each other.
func trigger_shake(strength: float, duration: float) -> void:
	if strength >= _shake_strength:
		_shake_max      = strength
		_shake_strength = strength
		_shake_duration = duration
		_shake_elapsed  = 0.0
	elif duration > (_shake_duration - _shake_elapsed):
		# Incoming shake is weaker but lasts longer — extend the current one.
		_shake_duration = _shake_elapsed + duration

func _update_shake(delta: float) -> void:
	if _shake_duration <= 0.0 or _shake_elapsed >= _shake_duration:
		offset          = Vector2.ZERO
		_shake_strength = 0.0
		_shake_duration = 0.0
		_shake_elapsed  = 0.0
		return

	_shake_elapsed  += delta
	var t : float    = clamp(_shake_elapsed / _shake_duration, 0.0, 1.0)
	_shake_strength  = lerpf(_shake_max, 0.0, t)   # linear decay strength → 0

	offset = Vector2(
		randf_range(-_shake_strength, _shake_strength),
		randf_range(-_shake_strength, _shake_strength)
	)
