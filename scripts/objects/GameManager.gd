extends Node

# ─── HIT-STOP NAMED CONSTANTS (milliseconds, wall-clock) ──────
# Pass these into trigger_hit_stop() from anywhere.
const HITSTOP_LIGHT         : int = 30    # 0.05–0.08s   light attack lands
const HITSTOP_HEAVY         : int = 80   # 0.10–0.17s   heavy attack lands
const HITSTOP_POGO          : int = 30    # 0.03–0.07s   pogo bounce
const HITSTOP_PLAYER_HIT    : int = 115   # 0.10–0.13s   player takes damage
const HITSTOP_ENEMY_STRONG  : int = 105   # 0.08–0.13s   enemy hit by strong attack
const HITSTOP_MINIBOSS_HIT  : int = 165   # 0.13–0.20s   mini-boss hit
const HITSTOP_BOSS_DEATH    : int = 375   # 0.25–0.50s   boss killed
const HITSTOP_PLAYER_DEATH  : int = 200   # 0.15–0.25s   player killed

# ─── RESTORE RAMP ─────────────────────────────────────────────
const HIT_STOP_RESTORE_MS   : int = 60    # wall-clock ms to ramp time_scale 0→1
										  # Set to 0 for instant snap-back.

# ─── STATE ────────────────────────────────────────────────────
var is_paused            : bool  = false
var _hit_stop_active     : bool  = false
var _hit_stop_end_ms     : int   = 0      # absolute wall-clock time the freeze ends
var _restoring           : bool  = false
var _restore_start_ms    : int   = 0
var _last_time_scale     : float = 1.0

# ─── PAUSE ────────────────────────────────────────────────────
func pause(paused: bool) -> void:
	is_paused = paused
	if paused:
		_last_time_scale  = Engine.time_scale
		Engine.time_scale = 0.0
	else:
		Engine.time_scale = _last_time_scale

# ─── HIT-STOP ─────────────────────────────────────────────────
# Pass one of the HITSTOP_* constants (or any int in ms).
# If a shorter hit-stop is requested while a longer one is still
# running, the running one takes priority.
func trigger_hit_stop(duration_ms: int) -> void:
	if is_paused: return
	var end_ms : int = Time.get_ticks_msec() + duration_ms
	# Only upgrade; never shorten an ongoing freeze.
	if _hit_stop_active and end_ms <= _hit_stop_end_ms: return
	_last_time_scale  = 1.0
	_hit_stop_active  = true
	_restoring        = false
	_hit_stop_end_ms  = end_ms
	Engine.time_scale = 0.0

# ─── PROCESS ──────────────────────────────────────────────────
# IMPORTANT: Never use `delta` here for timing — when time_scale = 0,
# _process delta is also 0, so any move_toward / lerp using it is a
# no-op and the freeze becomes permanent. All timing uses wall-clock
# (Time.get_ticks_msec) which is unaffected by time_scale.
func _process(_delta: float) -> void:
	if is_paused: return

	if _hit_stop_active:
		if Time.get_ticks_msec() >= _hit_stop_end_ms:
			_hit_stop_active  = false
			_restoring        = true
			_restore_start_ms = Time.get_ticks_msec()
			if HIT_STOP_RESTORE_MS <= 0:
				Engine.time_scale = _last_time_scale
				_restoring = false
		else:
			Engine.time_scale = 0.0
		return

	if _restoring:
		var r_elapsed : int   = Time.get_ticks_msec() - _restore_start_ms
		var t         : float = clamp(float(r_elapsed) / float(HIT_STOP_RESTORE_MS), 0.0, 1.0)
		Engine.time_scale = lerp(0.0, _last_time_scale, t)
		if t >= 1.0:
			Engine.time_scale = _last_time_scale
			_restoring = false
