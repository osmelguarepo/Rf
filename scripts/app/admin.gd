extends CanvasLayer
## The developer dashboard (scripts/app/tuning.gd holds its values), shown when the game was started with --admin: F1
## opens a full-screen page, white text on black, and F1 closes it. The game waits while the page is open
## (App._process()), so the values are tried by closing the page and driving. Moving a slider changes the game's rules
## at once; Reset puts the shipped rules back; the five slots keep and bring back a set of values. Mouse only: every
## control refuses the keyboard's focus.

const App := preload("res://scripts/app/app.gd")
const Tuning := preload("res://scripts/app/tuning.gd")

const MARGIN := 12
const COLUMN_GAP := 24
const TEXT_SIZE := 8

var app: App
var _sliders := {}
var _labels := {}
var _status: Label
## True while the page sets the sliders itself, so that does not count as the developer's change.
var _syncing := false


func setup(p_app: App) -> void:
	app = p_app
	layer = 100
	visible = false
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = _theme()
	add_child(root)
	var background := ColorRect.new()
	background.color = Color.BLACK
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, MARGIN)
	root.add_child(margin)
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", COLUMN_GAP)
	margin.add_child(columns)

	var rules := VBoxContainer.new()
	rules.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rules.add_theme_constant_override("separation", 2)
	columns.add_child(rules)
	rules.add_child(_label("ADMIN: GAME RULES"))
	for field: Dictionary in Tuning.FIELDS:
		var key: String = field["key"]
		var label := _label("")
		rules.add_child(label)
		_labels[key] = label
		var slider := HSlider.new()
		slider.focus_mode = Control.FOCUS_NONE
		slider.min_value = field["min"]
		slider.max_value = field["max"]
		slider.step = field["step"]
		slider.custom_minimum_size = Vector2(0, 10)
		slider.value_changed.connect(_on_slider.bind(key))
		rules.add_child(slider)
		_sliders[key] = slider

	var side_box := VBoxContainer.new()
	side_box.custom_minimum_size = Vector2(200, 0)
	side_box.add_theme_constant_override("separation", 4)
	columns.add_child(side_box)
	side_box.add_child(_label("PRESETS"))
	for slot in range(1, Tuning.PRESET_SLOTS + 1):
		var row := HBoxContainer.new()
		var name_label := _label("Slot %d" % slot)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)
		var save := _button("Save")
		save.pressed.connect(_on_save.bind(slot))
		row.add_child(save)
		var load_button := _button("Load")
		load_button.pressed.connect(_on_load.bind(slot))
		row.add_child(load_button)
		side_box.add_child(row)
	var reset := _button("Reset to shipped rules")
	reset.pressed.connect(_on_reset)
	side_box.add_child(reset)
	_status = _label("")
	side_box.add_child(_status)
	var help := _label("F1  close and play\n* = changed from the shipped rules")
	help.size_flags_vertical = Control.SIZE_EXPAND | Control.SIZE_SHRINK_END
	side_box.add_child(help)
	_sync()


func toggle() -> void:
	visible = not visible
	if visible:
		_sync()


## White text on black, in the game's pixel font.
func _theme() -> Theme:
	var theme := Theme.new()
	if app.atlas != null and app.atlas.font != null:
		theme.default_font = app.atlas.font
	theme.default_font_size = TEXT_SIZE
	theme.set_color("font_color", "Label", Color.WHITE)
	for state: String in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		theme.set_color(state, "Button", Color.WHITE)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.2, 0.2, 0.2)
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(0.35, 0.35, 0.35)
	theme.set_stylebox("normal", "Button", normal)
	theme.set_stylebox("hover", "Button", hover)
	theme.set_stylebox("pressed", "Button", hover)
	return theme


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	return button


## The sliders and their labels from the values.
func _sync() -> void:
	_syncing = true
	for field: Dictionary in Tuning.FIELDS:
		var key: String = field["key"]
		(_sliders[key] as HSlider).value = app.tuning.value(key)
		_show(key)
	_syncing = false


func _show(key: String) -> void:
	var field := Tuning.field_of(key)
	var shipped := Tuning.default_of(key)
	var now := app.tuning.value(key)
	var mark := "" if is_equal_approx(now, shipped) else "  *"
	(_labels[key] as Label).text = "%s: %s%s" % [field["label"], str(snappedf(now, 0.01)), mark]


func _on_slider(v: float, key: String) -> void:
	if _syncing:
		return
	app.tuning.set_value(key, v)
	_show(key)
	app.retune()


func _on_reset() -> void:
	app.tuning.reset()
	_sync()
	app.retune()
	_status.text = "Shipped rules"


func _on_save(slot: int) -> void:
	_status.text = "Saved slot %d" % slot if app.tuning.save_preset(slot) else "Could not save slot %d" % slot


func _on_load(slot: int) -> void:
	if app.tuning.load_preset(slot):
		_sync()
		app.retune()
		_status.text = "Loaded slot %d" % slot
	else:
		_status.text = "Slot %d is empty" % slot
