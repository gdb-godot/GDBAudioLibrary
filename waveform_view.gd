@tool
class_name GDBAudioWaveformView
extends Control

signal trim_changed(start_seconds: float, end_seconds: float)
signal seek_requested(seconds: float)

var peaks: PackedFloat32Array = PackedFloat32Array():
	set(value):
		peaks = value
		queue_redraw()
var _duration_seconds := 0.0
var _trim_start := 0.0
var _trim_end := 0.0
var _playhead_seconds := 0.0

var duration_seconds: float:
	get:
		return _duration_seconds
	set(value):
		_duration_seconds = maxf(value, 0.0)
		if _duration_seconds <= 0.0:
			_trim_start = 0.0
			_trim_end = 0.0
			_playhead_seconds = 0.0
		else:
			_set_range_internal(_trim_start, _duration_seconds if _trim_end <= 0.0 else _trim_end)
			_playhead_seconds = clampf(_playhead_seconds, 0.0, _duration_seconds)
		queue_redraw()
var trim_start: float:
	get:
		return _trim_start
	set(value):
		_set_range_internal(value, _trim_end)
		queue_redraw()
var trim_end: float:
	get:
		return _trim_end
	set(value):
		_set_range_internal(_trim_start, value)
		queue_redraw()
var playhead_seconds: float:
	get:
		return _playhead_seconds
	set(value):
		_playhead_seconds = clampf(value, 0.0, _duration_seconds)
		queue_redraw()

var _dragging := ""

func _ready() -> void:
	custom_minimum_size = Vector2(360, 128)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func set_full_selection() -> void:
	set_trim_range(0.0, _duration_seconds)


func set_trim_range(start_seconds: float, end_seconds: float, emit_change := true) -> bool:
	if _duration_seconds <= 0.0:
		_trim_start = 0.0
		_trim_end = 0.0
		queue_redraw()
		return false
	var minimum_length := minf(0.01, _duration_seconds)
	var start := clampf(start_seconds, 0.0, _duration_seconds)
	var end := clampf(end_seconds, 0.0, _duration_seconds)
	if end <= start:
		if start >= _duration_seconds:
			start = maxf(0.0, _duration_seconds - minimum_length)
			end = _duration_seconds
		else:
			end = minf(_duration_seconds, start + minimum_length)
	_set_range_internal(start, end)
	queue_redraw()
	if emit_change:
		emit_signal("trim_changed", _trim_start, _trim_end)
	return _trim_end > _trim_start


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed:
				_dragging = _nearest_handle(button.position.x)
				if _dragging == "body":
					emit_signal("seek_requested", _x_to_seconds(button.position.x))
				else:
					_apply_drag(button.position.x)
			else:
				_dragging = ""
	elif event is InputEventMouseMotion and _dragging != "":
		var motion := event as InputEventMouseMotion
		if _dragging == "body":
			emit_signal("seek_requested", _x_to_seconds(motion.position.x))
		else:
			_apply_drag(motion.position.x)


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	var bg := get_theme_color("dark_color_2", "Editor")
	var fg := get_theme_color("font_color", "Editor")
	var accent := get_theme_color("accent_color", "Editor")
	var warn := get_theme_color("warning_color", "Editor")
	draw_rect(rect, bg, true)
	draw_rect(rect, get_theme_color("base_color", "Editor"), false, 1.0)
	if duration_seconds <= 0.0 or peaks.is_empty():
		draw_string(get_theme_default_font(), Vector2(12, size.y * 0.5), "Select an audio file to generate a waveform.", HORIZONTAL_ALIGNMENT_LEFT, -1.0, get_theme_default_font_size(), fg)
		return
	var center_y := size.y * 0.5
	var usable_w := maxf(size.x, 1.0)
	var step := usable_w / float(peaks.size())
	for i in peaks.size():
		var peak := clampf(peaks[i], 0.0, 1.0)
		var x := float(i) * step
		var h := maxf(1.0, peak * size.y * 0.46)
		draw_line(Vector2(x, center_y - h), Vector2(x, center_y + h), fg, maxf(1.0, step))
	var start_x := _seconds_to_x(trim_start)
	var end_x := _seconds_to_x(trim_end)
	draw_rect(Rect2(Vector2(0, 0), Vector2(start_x, size.y)), Color(0, 0, 0, 0.45), true)
	draw_rect(Rect2(Vector2(end_x, 0), Vector2(size.x - end_x, size.y)), Color(0, 0, 0, 0.45), true)
	draw_line(Vector2(start_x, 0), Vector2(start_x, size.y), accent, 3.0)
	draw_line(Vector2(end_x, 0), Vector2(end_x, size.y), accent, 3.0)
	var play_x := _seconds_to_x(playhead_seconds)
	draw_line(Vector2(play_x, 0), Vector2(play_x, size.y), warn, 2.0)


func _nearest_handle(x: float) -> String:
	if duration_seconds <= 0.0:
		return "body"
	var start_x := _seconds_to_x(trim_start)
	var end_x := _seconds_to_x(trim_end)
	if absf(x - start_x) <= 12.0:
		return "start"
	if absf(x - end_x) <= 12.0:
		return "end"
	return "body"


func _apply_drag(x: float) -> void:
	var seconds := _x_to_seconds(x)
	if _dragging == "start":
		set_trim_range(seconds, _trim_end)
	elif _dragging == "end":
		set_trim_range(_trim_start, seconds)


func _x_to_seconds(x: float) -> float:
	if duration_seconds <= 0.0:
		return 0.0
	return clampf(x / maxf(size.x, 1.0), 0.0, 1.0) * duration_seconds


func _seconds_to_x(seconds: float) -> float:
	if duration_seconds <= 0.0:
		return 0.0
	return clampf(seconds / duration_seconds, 0.0, 1.0) * size.x


func _set_range_internal(start_seconds: float, end_seconds: float) -> void:
	if _duration_seconds <= 0.0:
		_trim_start = 0.0
		_trim_end = 0.0
		return
	var minimum_length := minf(0.01, _duration_seconds)
	_trim_start = clampf(start_seconds, 0.0, maxf(0.0, _duration_seconds - minimum_length))
	_trim_end = clampf(end_seconds, _trim_start + minimum_length, _duration_seconds)
