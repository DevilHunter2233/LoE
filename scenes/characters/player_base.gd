extends CharacterBody2D

# ─── CONSTANTS ───────────────────────────────────────────────
const WALK_SPEED       := 180.0
const SPRINT_SPEED     := 320.0
const JUMP_FORCE       := -520.0
const DOUBLE_JUMP_FORCE := -440.0
const GRAVITY          := 1200.0
const DASH_SPEED       := 600.0
const DASH_DURATION    := 0.15
const SLIDE_SPEED      := 400.0
const SLIDE_DURATION   := 0.35
const CROUCH_SCALE     := Vector2(1.0, 0.6)

# ─── VE METER ────────────────────────────────────────────────
const VE_MAX           := 100.0
const VE_GAIN_SPRINT   := 2.0   # per second
const VE_GAIN_DODGE    := 5.0   # on perfect dodge
const VE_GAIN_HIT_DEALT := 3.0
const VE_GAIN_HIT_TAKEN := 8.0
const VE_GAIN_SELFLESS := 25.0

# ─── STATE ───────────────────────────────────────────────────
var ve_meter       := 0.0
var can_double_jump := false
var is_dashing     := false
var dash_timer     := 0.0
var dash_direction := 1.0
var is_crouching   := false
var is_sliding     := false
var slide_timer    := 0.0
var is_sprinting   := false
var jumps_used     := 0
var facing_right   := true
var is_in_veilbreak := false

# ─── NODES ───────────────────────────────────────────────────
@onready var coyote_timer       : Timer = $CoyoteTimer
@onready var jump_buffer_timer  : Timer = $JumpBufferTimer
@onready var dash_cooldown_timer: Timer = $DashCooldownTimer
@onready var col_shape          : CollisionShape2D = $CollisionShape2D

# ─── SIGNALS ─────────────────────────────────────────────────
signal ve_meter_changed(new_value: float)
signal veilbreak_triggered
signal veilbreak_ended
signal landed

# ─────────────────────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	_apply_gravity(delta)
	_handle_dash(delta)
	_handle_movement(delta)
	_handle_crouch_slide(delta)
	_handle_jump()
	_handle_veilbreak()
	_update_ve_sprint(delta)
	move_and_slide()
	_post_move_checks()

# ─── GRAVITY ─────────────────────────────────────────────────
func _apply_gravity(delta: float) -> void:
	if is_dashing:
		return
	if not is_on_floor():
		velocity.y += GRAVITY * delta
		velocity.y = min(velocity.y, 900.0) # terminal velocity
	else:
		if jumps_used > 0:
			jumps_used = 0
			can_double_jump = true
			emit_signal("landed")

# ─── MOVEMENT ────────────────────────────────────────────────
func _handle_movement(delta: float) -> void:
	if is_dashing or is_sliding:
		return

	var dir := Input.get_axis("move_left", "move_right")
	is_sprinting = Input.is_action_pressed("dash") and is_on_floor() and dir != 0

	var speed := SPRINT_SPEED if is_sprinting else WALK_SPEED
	if is_crouching:
		speed *= 0.5

	if dir != 0:
		velocity.x = dir * speed
		facing_right = dir > 0
	else:
		# friction
		velocity.x = move_toward(velocity.x, 0, speed * 8 * delta)

# ─── JUMP ────────────────────────────────────────────────────
func _handle_jump() -> void:
	# coyote time: give grace period after walking off ledge
	if is_on_floor():
		coyote_timer.start()
	
	if Input.is_action_just_pressed("jump"):
		if is_on_floor() or not coyote_timer.is_stopped():
			_do_jump(JUMP_FORCE)
		elif jumps_used < 1:
			_do_jump(DOUBLE_JUMP_FORCE)
		else:
			jump_buffer_timer.start() # buffer for when you land
	
	# if buffered jump fires on landing
	if is_on_floor() and not jump_buffer_timer.is_stopped():
		_do_jump(JUMP_FORCE)
		jump_buffer_timer.stop()
	
	# variable jump height — release early = lower jump
	if Input.is_action_just_released("jump") and velocity.y < -200:
		velocity.y *= 0.5

func _do_jump(force: float) -> void:
	velocity.y = force
	jumps_used += 1
	coyote_timer.stop()
	add_ve(VE_GAIN_SPRINT * 0.5) # small VE boost on jump

# ─── DASH ────────────────────────────────────────────────────
func _handle_dash(delta: float) -> void:
	if is_dashing:
		dash_timer -= delta
		velocity.x = dash_direction * DASH_SPEED
		velocity.y = 0
		if dash_timer <= 0:
			is_dashing = false
			velocity.x = dash_direction * WALK_SPEED
		return

	if Input.is_action_just_pressed("dash") and not is_sprinting:
		if dash_cooldown_timer.is_stopped():
			_start_dash()

func _start_dash() -> void:
	var dir := Input.get_axis("move_left", "move_right")
	dash_direction = dir if dir != 0 else (1.0 if facing_right else -1.0)
	is_dashing = true
	dash_timer = DASH_DURATION
	dash_cooldown_timer.start()

# ─── CROUCH & SLIDE ──────────────────────────────────────────
func _handle_crouch_slide(delta: float) -> void:
	if is_sliding:
		slide_timer -= delta
		velocity.x = move_toward(velocity.x, 0, 200 * delta)
		if slide_timer <= 0 or abs(velocity.x) < 20:
			_end_slide()
		return

	if Input.is_action_just_pressed("crouch"):
		if is_sprinting and is_on_floor():
			_start_slide()
		else:
			_set_crouch(true)
	
	if Input.is_action_just_released("crouch"):
		_set_crouch(false)

func _start_slide() -> void:
	is_sliding = true
	slide_timer = SLIDE_DURATION
	velocity.x = (1.0 if facing_right else -1.0) * SLIDE_SPEED
	_set_crouch(true)

func _end_slide() -> void:
	is_sliding = false
	_set_crouch(false)

func _set_crouch(crouching: bool) -> void:
	is_crouching = crouching
	col_shape.scale = CROUCH_SCALE if crouching else Vector2.ONE

# ─── VEILBREAK ───────────────────────────────────────────────
func _handle_veilbreak() -> void:
	if Input.is_action_just_pressed("veilbreak"):
		if ve_meter >= VE_MAX and not is_in_veilbreak:
			_trigger_veilbreak()

func _trigger_veilbreak() -> void:
	is_in_veilbreak = true
	emit_signal("veilbreak_triggered")
	# subclasses override this to activate beast form

# call this from beast form script when meter empties
func _end_veilbreak() -> void:
	is_in_veilbreak = false
	emit_signal("veilbreak_ended")

# ─── VE METER ────────────────────────────────────────────────
func add_ve(amount: float) -> void:
	ve_meter = clamp(ve_meter + amount, 0.0, VE_MAX)
	emit_signal("ve_meter_changed", ve_meter)

func _update_ve_sprint(delta: float) -> void:
	if is_sprinting:
		add_ve(VE_GAIN_SPRINT * delta)

func on_hit_dealt() -> void:
	add_ve(VE_GAIN_HIT_DEALT)

func on_hit_taken() -> void:
	add_ve(VE_GAIN_HIT_TAKEN)

func on_selfless_act() -> void:
	add_ve(VE_GAIN_SELFLESS)

# ─── POST MOVE ───────────────────────────────────────────────
func _post_move_checks() -> void:
	# flip sprite based on facing
	if facing_right:
		scale.x = abs(scale.x)
	else:
		scale.x = -abs(scale.x)
