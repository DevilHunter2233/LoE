extends CanvasLayer

# ─── TEXTURES ──────────────────────────────────────────────────
@export var crystal_full  : Texture2D   # your Full.png
@export var crystal_half  : Texture2D   # your Half.png
@export var crystal_empty : Texture2D   # the dark/empty crystal

# ─── NODES ─────────────────────────────────────────────────────
@onready var crystal_row  : HBoxContainer    = $HudRoot/CrystalRow
@onready var ve_bar       : TextureProgressBar = $HudRoot/VEBar
@onready var energy_bar   : TextureProgressBar = $HudRoot/EnergyBar
@onready var portrait     : TextureRect      = $HudRoot/Portrait

const CRYSTAL_COUNT := 5          
const MAX_HEALTH    := CRYSTAL_COUNT * 20   

var _crystals : Array[TextureRect] = []

# ─── READY ─────────────────────────────────────────────────────
func _ready() -> void:
	# Collect crystal nodes in order
	for child in crystal_row.get_children():
		if child is TextureRect:
			_crystals.append(child)
	
	# Bar ranges
	ve_bar.min_value     = 0.0
	ve_bar.max_value     = 100.0
	ve_bar.value         = 0.0
	energy_bar.min_value = 0.0
	energy_bar.max_value = 100.0
	energy_bar.value     = 0.0
	
	# Connect to player signals (player must be in group "player")
	_connect_to_player()

func _connect_to_player() -> void:
	# Wait a frame so the player scene is ready
	await get_tree().process_frame
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty(): return
	var player := players[0]
	if player.has_signal("health_changed"):
		player.health_changed.connect(_on_health_changed)
	if player.has_signal("ve_meter_changed"):
		player.ve_meter_changed.connect(_on_ve_changed)
	if player.has_signal("energy_changed"):
		player.energy_changed.connect(_on_energy_changed)
	
	# Sync to current values immediately
	_on_health_changed(player.current_health)
	_on_ve_changed(player.ve_meter)
	_on_energy_changed(player.energy_meter)

# ─── SIGNAL HANDLERS ───────────────────────────────────────────
func _on_health_changed(current: float) -> void:
	var hp := int(current)
	for i in _crystals.size():
		var crystal_hp_full  := (i + 1) * 20
		var crystal_hp_half  := crystal_hp_full - 10
		if hp >= crystal_hp_full:
			_crystals[i].texture = crystal_full
		elif hp >= crystal_hp_half:
			_crystals[i].texture = crystal_half
		else:
			_crystals[i].texture = crystal_empty

func _on_ve_changed(value: float) -> void:
	ve_bar.value = value

func _on_energy_changed(value: float) -> void:
	energy_bar.value = value
