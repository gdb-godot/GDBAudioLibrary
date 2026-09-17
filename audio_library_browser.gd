@tool
extends Control

const WaveformView := preload("res://addons/gdb_audio_library/waveform_view.gd")

const SUPPORTED_EXTENSIONS: PackedStringArray = ["wav", "ogg", "mp3", "flac", "aif", "aiff", "m4a"]
const NATIVE_PREVIEW_EXTENSIONS: PackedStringArray = ["wav", "ogg", "mp3"]
const CACHE_DIR := "user://gdb_audio_library"
const CACHE_FILE := "user://gdb_audio_library/catalog.json"
const SETTINGS_FILE := "user://gdb_audio_library/settings.json"
const PREVIEW_DIR := "user://gdb_audio_library/previews"
const RESULTS_PAGE_SIZE := 250

var editor_interface: EditorInterface

var _library_root := ""
var _catalog_root := ""
var _ffmpeg_path := ""
var _catalog: Array[Dictionary] = []
var _filtered_indices: Array[int] = []
var _sources: PackedStringArray = PackedStringArray()
var _formats: PackedStringArray = PackedStringArray()
var _page := 0
var _selected_index := -1
var _selection_token := 0

var _scan_thread: Thread
var _scan_mutex := Mutex.new()
var _scan_cancel := false
var _scan_done := false
var _scan_error := ""
var _scan_total := 0
var _scan_queue: Array[Dictionary] = []

var _probe_thread: Thread
var _probe_token := 0
var _probe_mutex := Mutex.new()
var _probe_result: Dictionary = {}
var _probe_ready := false
var _pending_probe: Dictionary = {}

var _wave_thread: Thread
var _wave_token := 0
var _wave_mutex := Mutex.new()
var _wave_result: Dictionary = {}
var _wave_ready := false
var _pending_wave: Dictionary = {}

var _export_thread: Thread
var _export_mutex := Mutex.new()
var _export_ready := false
var _export_result: Dictionary = {}

var _root_edit: LineEdit
var _ffmpeg_edit: LineEdit
var _scan_button: Button
var _cancel_scan_button: Button
var _progress: ProgressBar
var _status_label: Label
var _search_edit: LineEdit
var _source_filter: OptionButton
var _format_filter: OptionButton
var _results: ItemList
var _page_label: Label
var _prev_button: Button
var _next_button: Button
var _details_label: RichTextLabel
var _waveform: WaveformView
var _play_button: Button
var _pause_button: Button
var _stop_button: Button
var _seek_slider: HSlider
var _volume_slider: HSlider
var _loop_check: CheckBox
var _play_selection_check: CheckBox
var _trim_start_spin: SpinBox
var _trim_end_spin: SpinBox
var _fade_in_spin: SpinBox
var _fade_out_spin: SpinBox
var _gain_spin: SpinBox
var _preset_option: OptionButton
var _quality_slider: HSlider
var _normalize_check: CheckBox
var _destination_edit: LineEdit
var _export_button: Button
var _export_status: Label
var _folder_dialog: FileDialog
var _ffmpeg_dialog: FileDialog
var _dest_dialog: FileDialog
var _player: AudioStreamPlayer
var _ui_timer: Timer

func _ready() -> void:
	name = "Audio Library"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_ensure_dirs()
	_load_settings()
	_build_ui()
	_load_cache()
	_apply_filters()


func shutdown() -> void:
	_selection_token += 1
	_pending_probe.clear()
	_pending_wave.clear()
	if _player:
		_player.stop()
		_player.stream = null
	_stop_scan()
	_join_thread(_probe_thread)
	_probe_thread = null
	_join_thread(_wave_thread)
	_wave_thread = null
	_join_thread(_export_thread)
	_export_thread = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		shutdown()


func _build_ui() -> void:
	var main := VBoxContainer.new()
	main.set_anchors_preset(Control.PRESET_FULL_RECT)
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_theme_constant_override("separation", 8)
	add_child(main)

	var title := Label.new()
	title.text = "Audio Library"
	title.add_theme_font_size_override("font_size", int(get_theme_default_font_size() * 1.25))
	main.add_child(title)

	var root_row := HBoxContainer.new()
	main.add_child(root_row)
	root_row.add_child(_label("Library root"))
	_root_edit = LineEdit.new()
	_root_edit.text = _library_root
	_root_edit.placeholder_text = "Choose your external audio library folder"
	_root_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root_row.add_child(_root_edit)
	var browse_root := Button.new()
	browse_root.text = "Choose..."
	root_row.add_child(browse_root)
	_scan_button = Button.new()
	_scan_button.text = "Scan / Rescan"
	root_row.add_child(_scan_button)
	_cancel_scan_button = Button.new()
	_cancel_scan_button.text = "Cancel"
	_cancel_scan_button.disabled = true
	root_row.add_child(_cancel_scan_button)

	var ffmpeg_row := HBoxContainer.new()
	main.add_child(ffmpeg_row)
	ffmpeg_row.add_child(_label("FFmpeg"))
	_ffmpeg_edit = LineEdit.new()
	_ffmpeg_edit.text = _ffmpeg_path
	_ffmpeg_edit.placeholder_text = "Pick ffmpeg executable for FLAC/AIF/AIFF/M4A preview, probing, waveform and export"
	_ffmpeg_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ffmpeg_row.add_child(_ffmpeg_edit)
	var browse_ffmpeg := Button.new()
	browse_ffmpeg.text = "Choose..."
	ffmpeg_row.add_child(browse_ffmpeg)

	var progress_row := HBoxContainer.new()
	main.add_child(progress_row)
	_progress = ProgressBar.new()
	_progress.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	progress_row.add_child(_progress)
	_status_label = Label.new()
	_status_label.text = "Load a cache or scan a library root."
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	progress_row.add_child(_status_label)

	var split := HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 520
	main.add_child(split)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(left)

	var filter_row := HBoxContainer.new()
	left.add_child(filter_row)
	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "Search multiple words in file, path, source or category"
	_search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	filter_row.add_child(_search_edit)
	_source_filter = OptionButton.new()
	_source_filter.custom_minimum_size.x = 150
	filter_row.add_child(_source_filter)
	_format_filter = OptionButton.new()
	_format_filter.custom_minimum_size.x = 110
	filter_row.add_child(_format_filter)

	_results = ItemList.new()
	_results.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_results.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_results.fixed_icon_size = Vector2i(16, 16)
	left.add_child(_results)

	var page_row := HBoxContainer.new()
	left.add_child(page_row)
	_prev_button = Button.new()
	_prev_button.text = "Previous"
	page_row.add_child(_prev_button)
	_page_label = Label.new()
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page_row.add_child(_page_label)
	_next_button = Button.new()
	_next_button.text = "Next"
	page_row.add_child(_next_button)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(right)

	_details_label = RichTextLabel.new()
	_details_label.bbcode_enabled = true
	_details_label.fit_content = true
	_details_label.custom_minimum_size.y = 120
	_details_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(_details_label)

	_waveform = WaveformView.new()
	_waveform.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_child(_waveform)

	var audition_row := HBoxContainer.new()
	right.add_child(audition_row)
	_play_button = Button.new()
	_play_button.text = "Play"
	audition_row.add_child(_play_button)
	_pause_button = Button.new()
	_pause_button.text = "Pause"
	audition_row.add_child(_pause_button)
	_stop_button = Button.new()
	_stop_button.text = "Stop"
	audition_row.add_child(_stop_button)
	audition_row.add_child(_label("Seek"))
	_seek_slider = HSlider.new()
	_seek_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	audition_row.add_child(_seek_slider)
	audition_row.add_child(_label("Volume"))
	_volume_slider = HSlider.new()
	_volume_slider.min_value = -48.0
	_volume_slider.max_value = 6.0
	_volume_slider.step = 0.5
	_volume_slider.value = -6.0
	_volume_slider.custom_minimum_size.x = 120
	audition_row.add_child(_volume_slider)
	_loop_check = CheckBox.new()
	_loop_check.text = "Loop"
	audition_row.add_child(_loop_check)
	_play_selection_check = CheckBox.new()
	_play_selection_check.text = "Selection"
	_play_selection_check.button_pressed = true
	audition_row.add_child(_play_selection_check)

	var trim_row := HBoxContainer.new()
	right.add_child(trim_row)
	trim_row.add_child(_label("Start"))
	_trim_start_spin = _time_spin()
	trim_row.add_child(_trim_start_spin)
	trim_row.add_child(_label("End"))
	_trim_end_spin = _time_spin()
	trim_row.add_child(_trim_end_spin)
	var full_button := Button.new()
	full_button.text = "Full file"
	trim_row.add_child(full_button)
	trim_row.add_child(_label("Fade in"))
	_fade_in_spin = _time_spin(0.0, 30.0)
	trim_row.add_child(_fade_in_spin)
	trim_row.add_child(_label("Fade out"))
	_fade_out_spin = _time_spin(0.0, 30.0)
	trim_row.add_child(_fade_out_spin)
	trim_row.add_child(_label("Gain dB"))
	_gain_spin = _number_spin(-48.0, 24.0, 0.5)
	trim_row.add_child(_gain_spin)

	var export_row := HBoxContainer.new()
	right.add_child(export_row)
	_preset_option = OptionButton.new()
	_preset_option.add_item("Short SFX WAV 48kHz 16-bit PCM")
	_preset_option.add_item("Music/Ambience OGG Vorbis")
	export_row.add_child(_preset_option)
	export_row.add_child(_label("OGG quality"))
	_quality_slider = HSlider.new()
	_quality_slider.min_value = -1.0
	_quality_slider.max_value = 10.0
	_quality_slider.step = 0.5
	_quality_slider.value = 5.0
	_quality_slider.custom_minimum_size.x = 130
	export_row.add_child(_quality_slider)
	_normalize_check = CheckBox.new()
	_normalize_check.text = "Normalize"
	export_row.add_child(_normalize_check)

	var dest_row := HBoxContainer.new()
	right.add_child(dest_row)
	dest_row.add_child(_label("Destination"))
	_destination_edit = LineEdit.new()
	_destination_edit.placeholder_text = "Choose an output file path, including res://..."
	_destination_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dest_row.add_child(_destination_edit)
	var browse_dest := Button.new()
	browse_dest.text = "Choose..."
	dest_row.add_child(browse_dest)
	_export_button = Button.new()
	_export_button.text = "Export Copy"
	dest_row.add_child(_export_button)

	_export_status = Label.new()
	_export_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_export_status)

	_player = AudioStreamPlayer.new()
	add_child(_player)
	_player.volume_db = float(_volume_slider.value)
	_player.finished.connect(_on_player_finished)
	_loop_check.toggled.connect(func(_enabled: bool) -> void: _configure_current_stream_loop())
	_play_selection_check.toggled.connect(func(_enabled: bool) -> void: _configure_current_stream_loop())

	_ui_timer = Timer.new()
	_ui_timer.wait_time = 0.1
	_ui_timer.autostart = true
	add_child(_ui_timer)

	_folder_dialog = FileDialog.new()
	_folder_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_folder_dialog.access = FileDialog.ACCESS_FILESYSTEM
	add_child(_folder_dialog)
	_ffmpeg_dialog = FileDialog.new()
	_ffmpeg_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_ffmpeg_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_ffmpeg_dialog.filters = PackedStringArray(["*.exe ; Executables"])
	add_child(_ffmpeg_dialog)
	_dest_dialog = FileDialog.new()
	_dest_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_dest_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dest_dialog.filters = PackedStringArray(["*.wav ; WAV audio", "*.ogg ; OGG audio"])
	add_child(_dest_dialog)

	browse_root.pressed.connect(func() -> void: _folder_dialog.popup_centered_ratio(0.7))
	browse_ffmpeg.pressed.connect(func() -> void: _ffmpeg_dialog.popup_centered_ratio(0.7))
	browse_dest.pressed.connect(func() -> void: _dest_dialog.popup_centered_ratio(0.7))
	_folder_dialog.dir_selected.connect(_on_library_root_chosen)
	_root_edit.text_submitted.connect(_on_library_root_chosen)
	_ffmpeg_dialog.file_selected.connect(func(path: String) -> void: _ffmpeg_edit.text = path; _ffmpeg_path = path; _save_settings())
	_dest_dialog.file_selected.connect(func(path: String) -> void: _destination_edit.text = path)
	_scan_button.pressed.connect(_start_scan)
	_cancel_scan_button.pressed.connect(_stop_scan)
	_search_edit.text_changed.connect(func(_text: String) -> void: _page = 0; _apply_filters())
	_source_filter.item_selected.connect(func(_idx: int) -> void: _page = 0; _apply_filters())
	_format_filter.item_selected.connect(func(_idx: int) -> void: _page = 0; _apply_filters())
	_results.item_selected.connect(_select_visible_result)
	_prev_button.pressed.connect(func() -> void: _page = maxi(_page - 1, 0); _render_results())
	_next_button.pressed.connect(func() -> void: _page += 1; _render_results())
	_play_button.pressed.connect(_play_selected)
	_pause_button.pressed.connect(func() -> void: _player.stream_paused = not _player.stream_paused)
	_stop_button.pressed.connect(func() -> void: _player.stop(); _waveform.playhead_seconds = 0.0)
	_seek_slider.value_changed.connect(func(value: float) -> void: if _player.playing: _player.seek(value); _waveform.playhead_seconds = value)
	_volume_slider.value_changed.connect(func(value: float) -> void: _player.volume_db = value)
	_waveform.trim_changed.connect(_on_wave_trim_changed)
	_waveform.seek_requested.connect(func(seconds: float) -> void: _seek_slider.value = seconds; if _player.playing: _player.seek(seconds))
	_trim_start_spin.value_changed.connect(func(value: float) -> void: _set_trim(value, float(_trim_end_spin.value)))
	_trim_end_spin.value_changed.connect(func(value: float) -> void: _set_trim(float(_trim_start_spin.value), value))
	full_button.pressed.connect(func() -> void: _waveform.set_full_selection(); _sync_trim_spins())
	_export_button.pressed.connect(_export_selected)


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return label


func _time_spin(min_value := 0.0, max_value := 86400.0) -> SpinBox:
	return _number_spin(min_value, max_value, 0.01)


func _number_spin(min_value: float, max_value: float, step: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.allow_greater = true
	spin.custom_minimum_size.x = 92
	return spin


func _ensure_dirs() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PREVIEW_DIR))


func _load_settings() -> void:
	_library_root = ""
	_ffmpeg_path = ""
	if not FileAccess.file_exists(SETTINGS_FILE):
		return
	var file := FileAccess.open(SETTINGS_FILE, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		var data := parsed as Dictionary
		_library_root = str(data.get("library_root", _library_root))
		_ffmpeg_path = str(data.get("ffmpeg_path", _ffmpeg_path))


func _save_settings() -> void:
	_ensure_dirs()
	var data := {"library_root": _root_edit.text if _root_edit else _library_root, "ffmpeg_path": _ffmpeg_edit.text if _ffmpeg_edit else _ffmpeg_path}
	var file := FileAccess.open(SETTINGS_FILE, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))


func _load_cache() -> void:
	if not FileAccess.file_exists(CACHE_FILE):
		_status_label.text = "No cache yet. Scan a library root to build one."
		return
	var file := FileAccess.open(CACHE_FILE, FileAccess.READ)
	if file == null:
		_status_label.text = "Could not read cache: %s" % FileAccess.get_open_error()
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary:
		var data := parsed as Dictionary
		var cached_root := str(data.get("root", ""))
		if _canonical_path(cached_root) != _canonical_path(_library_root):
			_catalog.clear()
			_catalog_root = ""
			_status_label.text = "Cached catalog belongs to a different library root. Scan this root to build its catalog."
			return
		_catalog_root = cached_root
		_catalog.clear()
		var items: Array = data.get("items", [])
		for item in items:
			if item is Dictionary:
				var cached_item := (item as Dictionary).duplicate()
				cached_item["library_root"] = str(cached_item.get("library_root", cached_root))
				_catalog.append(cached_item)
		_status_label.text = "Loaded %d cached audio files." % _catalog.size()
		_rebuild_filter_options()


func _save_cache() -> void:
	_ensure_dirs()
	var data := {"version": 1, "root": _library_root, "scanned_at_unix": Time.get_unix_time_from_system(), "items": _catalog}
	var file := FileAccess.open(CACHE_FILE, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))


func _start_scan() -> void:
	if _scan_thread and _scan_thread.is_started():
		return
	_library_root = _root_edit.text.strip_edges()
	_ffmpeg_path = _ffmpeg_edit.text.strip_edges()
	_save_settings()
	if _library_root.is_empty() or not DirAccess.dir_exists_absolute(_library_root):
		_status_label.text = "Library root is missing or disconnected: %s" % _library_root
		return
	_reset_selection("Scanning a new catalog...")
	_catalog.clear()
	_catalog_root = _library_root
	_filtered_indices.clear()
	_results.clear()
	_scan_cancel = false
	_scan_done = false
	_scan_error = ""
	_scan_total = 0
	_scan_queue.clear()
	_scan_button.disabled = true
	_cancel_scan_button.disabled = false
	_progress.value = 0.0
	_status_label.text = "Scanning..."
	_scan_thread = Thread.new()
	_scan_thread.start(_scan_worker.bind(_library_root))


func _stop_scan() -> void:
	_scan_cancel = true
	_join_thread(_scan_thread)
	_scan_thread = null
	_scan_mutex.lock()
	_scan_queue.clear()
	_scan_done = false
	_scan_mutex.unlock()
	_scan_button.disabled = false
	_cancel_scan_button.disabled = true
	_catalog.clear()
	_filtered_indices.clear()
	_rebuild_filter_options()
	_render_results()
	if _status_label and _status_label.text.begins_with("Scanning"):
		_status_label.text = "Scan cancelled. Rescan to build a complete catalog."


func _scan_worker(root: String) -> void:
	var visited: Dictionary = {}
	_scan_directory(root, root, visited)
	_scan_mutex.lock()
	_scan_done = true
	_scan_mutex.unlock()


func _scan_directory(root: String, current: String, visited: Dictionary) -> void:
	if _scan_cancel:
		return
	var normalized := _normalize_path(current)
	if visited.has(normalized):
		return
	visited[normalized] = true
	var dir := DirAccess.open(current)
	if dir == null:
		_scan_mutex.lock()
		_scan_error = "Skipped inaccessible folder: %s" % current
		_scan_mutex.unlock()
		return
	dir.list_dir_begin()
	while true:
		if _scan_cancel:
			break
		var name := dir.get_next()
		if name.is_empty():
			break
		if name == "." or name == ".." or name.begins_with("."):
			continue
		var path := current.path_join(name)
		if dir.current_is_dir():
			if dir.is_link(name):
				continue
			_scan_directory(root, path, visited)
		else:
			var ext := name.get_extension().to_lower()
			if not SUPPORTED_EXTENSIONS.has(ext):
				continue
			var item := _make_catalog_item(root, path, name, ext)
			_scan_mutex.lock()
			_scan_queue.append(item)
			_scan_total += 1
			_scan_mutex.unlock()
	dir.list_dir_end()


func _make_catalog_item(root: String, path: String, file_name: String, ext: String) -> Dictionary:
	var rel := path.trim_prefix(root).trim_prefix("\\").trim_prefix("/")
	var parts := rel.replace("\\", "/").split("/", false)
	var source := "Uncategorized"
	var category := ""
	if parts.size() > 0:
		source = parts[0]
	if parts.size() > 2:
		category = parts[1]
	elif parts.size() > 1:
		category = parts[0]
	var mtime := FileAccess.get_modified_time(path)
	var size := FileAccess.get_size(path)
	var haystack := ("%s %s %s %s %s" % [file_name, rel, source, category, ext]).to_lower()
	return {
		"name": file_name,
		"absolute_path": path,
		"relative_path": rel,
		"extension": ext,
		"size": size,
		"mtime": mtime,
		"library_root": root,
		"source": source,
		"category": category,
		"search": haystack,
		"license_paths": _nearby_license_paths(root, path)
	}


func _nearby_license_paths(root: String, path: String) -> Array[String]:
	var found: Array[String] = []
	var dir_path := path.get_base_dir()
	var root_norm := _normalize_path(root)
	while _normalize_path(dir_path).begins_with(root_norm):
		for name in ["LICENSE", "LICENSE.txt", "LICENSE.md", "LICENSES.md", "README.md", "Readme.md", "license.txt"]:
			var candidate := dir_path.path_join(name)
			if FileAccess.file_exists(candidate):
				found.append(candidate)
				if found.size() >= 4:
					return found
		if _normalize_path(dir_path) == root_norm:
			break
		dir_path = dir_path.get_base_dir()
	return found


func _process(_delta: float) -> void:
	_drain_scan_queue()
	_drain_probe_result()
	_drain_wave_result()
	_drain_export_result()
	if _player and _player.playing:
		var pos := _player.get_playback_position()
		_seek_slider.set_value_no_signal(pos)
		_waveform.playhead_seconds = pos
		if _play_selection_check.button_pressed and pos >= _waveform.trim_end:
			if _loop_check.button_pressed:
				_player.seek(_waveform.trim_start)
			else:
				_player.stop()
		elif not _play_selection_check.button_pressed and _loop_check.button_pressed and _player.stream and pos >= _player.stream.get_length():
			_player.play(0.0)


func _on_player_finished() -> void:
	var restart_position := _loop_restart_position()
	if restart_position >= 0.0:
		_player.play(restart_position)


func _loop_restart_position() -> float:
	if not _loop_check or not _loop_check.button_pressed or not _player or _player.stream == null:
		return -1.0
	return _waveform.trim_start if _play_selection_check.button_pressed else 0.0


func _drain_scan_queue() -> void:
	if not _scan_thread:
		return
	var batch: Array[Dictionary] = []
	var done := false
	var error := ""
	var total := 0
	_scan_mutex.lock()
	if not _scan_queue.is_empty():
		batch = _scan_queue.duplicate()
		_scan_queue.clear()
	done = _scan_done
	error = _scan_error
	total = _scan_total
	_scan_mutex.unlock()
	for item in batch:
		_catalog.append(item)
	if total > 0:
		_progress.value = fmod(float(total), 100.0)
		_status_label.text = "Scanning... %d audio files found%s" % [total, ("; " + error) if not error.is_empty() else ""]
	if done:
		_join_thread(_scan_thread)
		_scan_thread = null
		_scan_button.disabled = false
		_cancel_scan_button.disabled = true
		_progress.value = 100.0
		_save_cache()
		_rebuild_filter_options()
		_apply_filters()
		_status_label.text = "Scan complete: %d audio files cached." % _catalog.size()


func _rebuild_filter_options() -> void:
	var source_set: Dictionary = {}
	var format_set: Dictionary = {}
	for item in _catalog:
		source_set[str(item.get("source", ""))] = true
		format_set[str(item.get("extension", ""))] = true
	_sources = PackedStringArray(source_set.keys())
	_formats = PackedStringArray(format_set.keys())
	_sources.sort()
	_formats.sort()
	_source_filter.clear()
	_source_filter.add_item("All sources")
	for source in _sources:
		_source_filter.add_item(source)
	_format_filter.clear()
	_format_filter.add_item("All formats")
	for fmt in _formats:
		_format_filter.add_item(fmt.to_upper())


func _apply_filters() -> void:
	_filtered_indices.clear()
	var words := _search_edit.text.to_lower().split(" ", false) if _search_edit else PackedStringArray()
	var source := "" if _source_filter == null or _source_filter.selected <= 0 else _source_filter.get_item_text(_source_filter.selected)
	var fmt := "" if _format_filter == null or _format_filter.selected <= 0 else _format_filter.get_item_text(_format_filter.selected).to_lower()
	for i in _catalog.size():
		var item := _catalog[i]
		if not source.is_empty() and str(item.get("source", "")) != source:
			continue
		if not fmt.is_empty() and str(item.get("extension", "")) != fmt:
			continue
		var haystack := str(item.get("search", ""))
		var matches := true
		for word in words:
			if not haystack.contains(word):
				matches = false
				break
		if matches:
			_filtered_indices.append(i)
	_render_results()


func _render_results() -> void:
	if not _results:
		return
	_results.clear()
	var pages := maxi(1, int(ceil(float(_filtered_indices.size()) / float(RESULTS_PAGE_SIZE))))
	_page = clampi(_page, 0, pages - 1)
	var start := _page * RESULTS_PAGE_SIZE
	var end := mini(start + RESULTS_PAGE_SIZE, _filtered_indices.size())
	for visible_i in range(start, end):
		var item := _catalog[_filtered_indices[visible_i]]
		var text := "%s  [%s / %s / %s]" % [item.get("name", ""), item.get("source", ""), item.get("category", ""), str(item.get("extension", "")).to_upper()]
		_results.add_item(text)
	_page_label.text = "%d results - page %d/%d (showing up to %d)" % [_filtered_indices.size(), _page + 1, pages, RESULTS_PAGE_SIZE]
	_prev_button.disabled = _page <= 0
	_next_button.disabled = _page >= pages - 1
	if _filtered_indices.is_empty():
		_details_label.text = "No matching cached audio. Adjust filters or rescan."


func _select_visible_result(local_index: int) -> void:
	var global_visible := _page * RESULTS_PAGE_SIZE + local_index
	if global_visible < 0 or global_visible >= _filtered_indices.size():
		return
	_selected_index = _filtered_indices[global_visible]
	if not _has_selected_item():
		_reset_selection("The selected cache entry is no longer available.")
		return
	_selection_token += 1
	_export_button.disabled = false
	_player.stop()
	_waveform.peaks = PackedFloat32Array()
	_waveform.duration_seconds = 0.0
	_seek_slider.value = 0.0
	_show_selected_details("Loading metadata and waveform...")
	_start_probe(_selection_token, _catalog[_selected_index])
	_start_waveform(_selection_token, _catalog[_selected_index])


func _show_selected_details(extra: String = "") -> void:
	if not _has_selected_item():
		return
	var item := _catalog[_selected_index]
	var license_text := "None found nearby"
	var licenses: Array = item.get("license_paths", [])
	if not licenses.is_empty():
		license_text = "\n".join(licenses)
	var stale := "" if FileAccess.file_exists(str(item.get("absolute_path", ""))) else "\n[color=orange]Missing or disconnected since scan.[/color]"
	_details_label.text = "[b]%s[/b]\nSource: %s\nCategory: %s\nFormat: %s\nSize: %s\nPath: %s\nNearby provenance docs:\n%s%s\n%s" % [
		item.get("name", ""),
		item.get("source", ""),
		item.get("category", ""),
		str(item.get("extension", "")).to_upper(),
		_format_bytes(int(item.get("size", 0))),
		item.get("absolute_path", ""),
		license_text,
		stale,
		extra
	]


func _start_probe(token: int, item: Dictionary, ffmpeg_path := "") -> void:
	var chosen_ffmpeg := ffmpeg_path if not ffmpeg_path.is_empty() else _ffmpeg_edit.text.strip_edges()
	if _probe_thread and _probe_thread.is_started():
		_pending_probe = {"token": token, "item": item.duplicate(), "ffmpeg": chosen_ffmpeg}
		return
	_probe_ready = false
	_probe_token = token
	_probe_thread = Thread.new()
	_probe_thread.start(_probe_worker.bind(token, item.duplicate(), chosen_ffmpeg))


func _probe_worker(token: int, item: Dictionary, ffmpeg: String) -> void:
	var result := {"token": token, "ok": false, "message": "", "duration": 0.0, "sample_rate": 0, "channels": ""}
	var path := str(item.get("absolute_path", ""))
	if not FileAccess.file_exists(path):
		result.message = "File is missing or disconnected."
	elif not FileAccess.file_exists(ffmpeg):
		result.message = "FFmpeg is required for metadata probing. Pick an executable."
	else:
		var output: Array = []
		OS.execute(ffmpeg, PackedStringArray(["-hide_banner", "-i", path]), output, true, false)
		var text := "\n".join(output)
		var parsed := _parse_ffmpeg_metadata(text)
		result.merge(parsed, true)
		result.ok = float(result.get("duration", 0.0)) > 0.0
		result.message = "Metadata loaded." if result.ok else "Could not parse FFmpeg metadata."
	_probe_mutex.lock()
	_probe_result = result
	_probe_ready = true
	_probe_mutex.unlock()


func _drain_probe_result() -> void:
	if not _probe_ready:
		return
	_probe_mutex.lock()
	var result := _probe_result.duplicate()
	_probe_ready = false
	_probe_mutex.unlock()
	_join_thread(_probe_thread)
	_probe_thread = null
	if not _pending_probe.is_empty():
		var pending := _pending_probe.duplicate()
		_pending_probe.clear()
		_start_probe(int(pending.token), pending.item, str(pending.ffmpeg))
	if int(result.get("token", -1)) != _selection_token:
		return
	if not _has_selected_item():
		return
	var duration := float(result.get("duration", 0.0))
	if duration > 0.0:
		_waveform.duration_seconds = duration
		_waveform.trim_start = 0.0
		_waveform.trim_end = duration
		_seek_slider.max_value = duration
		_trim_start_spin.max_value = duration
		_trim_end_spin.max_value = duration
		_sync_trim_spins()
	_show_selected_details("Duration: %.3fs\nSample rate: %s Hz\nChannels: %s\n%s" % [duration, result.get("sample_rate", "?"), result.get("channels", "?"), result.get("message", "")])


func _parse_ffmpeg_metadata(text: String) -> Dictionary:
	var result := {"duration": 0.0, "sample_rate": 0, "channels": ""}
	var duration_re := RegEx.new()
	duration_re.compile("Duration: (\\d+):(\\d+):(\\d+\\.\\d+)")
	var dm := duration_re.search(text)
	if dm:
		result.duration = float(dm.get_string(1)) * 3600.0 + float(dm.get_string(2)) * 60.0 + float(dm.get_string(3))
	var audio_re := RegEx.new()
	audio_re.compile("Audio:.*?(\\d+) Hz, ([^,]+)")
	var am := audio_re.search(text)
	if am:
		result.sample_rate = int(am.get_string(1))
		result.channels = am.get_string(2)
	return result


func _start_waveform(token: int, item: Dictionary, ffmpeg_path := "") -> void:
	var chosen_ffmpeg := ffmpeg_path if not ffmpeg_path.is_empty() else _ffmpeg_edit.text.strip_edges()
	if _wave_thread and _wave_thread.is_started():
		_pending_wave = {"token": token, "item": item.duplicate(), "ffmpeg": chosen_ffmpeg}
		return
	_wave_ready = false
	_wave_token = token
	_wave_thread = Thread.new()
	_wave_thread.start(_wave_worker.bind(token, item.duplicate(), chosen_ffmpeg))


func _wave_worker(token: int, item: Dictionary, ffmpeg: String) -> void:
	var result := {"token": token, "ok": false, "message": "", "peaks": PackedFloat32Array(), "preview_path": ""}
	var path := str(item.get("absolute_path", ""))
	if not FileAccess.file_exists(path):
		result.message = "File missing."
	elif not FileAccess.file_exists(ffmpeg):
		result.message = "FFmpeg is required to build waveform previews."
	else:
		var id := _preview_id(path, int(item.get("mtime", 0)), int(item.get("size", 0)))
		var raw_path := ProjectSettings.globalize_path(PREVIEW_DIR.path_join(id + ".s16le"))
		var wav_path := ProjectSettings.globalize_path(PREVIEW_DIR.path_join(id + ".wav"))
		if not FileAccess.file_exists(raw_path):
			var args := PackedStringArray(["-y", "-hide_banner", "-v", "error", "-i", path, "-vn", "-ac", "1", "-ar", "4000", "-f", "s16le", raw_path])
			var output: Array = []
			var code := OS.execute(ffmpeg, args, output, true, false)
			if code != 0:
				result.message = "Waveform decode failed: %s" % "\n".join(output)
			else:
				result.ok = true
		else:
			result.ok = true
		if result.ok:
			result.peaks = _read_raw_peaks(raw_path, 1024)
			var ext := str(item.get("extension", "")).to_lower()
			if NATIVE_PREVIEW_EXTENSIONS.has(ext):
				result.preview_path = path
			else:
				if not FileAccess.file_exists(wav_path):
					var wav_args := PackedStringArray(["-y", "-hide_banner", "-v", "error", "-i", path, "-vn", "-acodec", "pcm_s16le", "-ar", "48000", wav_path])
					var wav_output: Array = []
					var wav_code := OS.execute(ffmpeg, wav_args, wav_output, true, false)
					if wav_code != 0:
						result.message = "Preview WAV decode failed: %s" % "\n".join(wav_output)
				if FileAccess.file_exists(wav_path):
					result.preview_path = wav_path
	_wave_mutex.lock()
	_wave_result = result
	_wave_ready = true
	_wave_mutex.unlock()


func _read_raw_peaks(path: String, bins: int) -> PackedFloat32Array:
	var peaks := PackedFloat32Array()
	peaks.resize(bins)
	if not FileAccess.file_exists(path):
		return peaks
	var bytes := FileAccess.get_file_as_bytes(path)
	var sample_count := bytes.size() / 2
	if sample_count <= 0:
		return peaks
	var samples_per_bin := maxi(1, sample_count / bins)
	for i in range(sample_count):
		var lo := int(bytes[i * 2])
		var hi := int(bytes[i * 2 + 1])
		var value := (hi << 8) | lo
		if value >= 32768:
			value -= 65536
		var amp := absf(float(value) / 32768.0)
		var bin := mini(i / samples_per_bin, bins - 1)
		if amp > peaks[bin]:
			peaks[bin] = amp
	return peaks


func _drain_wave_result() -> void:
	if not _wave_ready:
		return
	_wave_mutex.lock()
	var result := _wave_result.duplicate()
	_wave_ready = false
	_wave_mutex.unlock()
	_join_thread(_wave_thread)
	_wave_thread = null
	if not _pending_wave.is_empty():
		var pending := _pending_wave.duplicate()
		_pending_wave.clear()
		_start_waveform(int(pending.token), pending.item, str(pending.ffmpeg))
	if int(result.get("token", -1)) != _selection_token:
		return
	if not _has_selected_item():
		return
	if bool(result.get("ok", false)):
		_waveform.peaks = result.get("peaks", PackedFloat32Array())
		var item := _catalog[_selected_index]
		item.preview_path = result.get("preview_path", "")
		_catalog[_selected_index] = item
	else:
		_export_status.text = str(result.get("message", "Waveform failed."))


func _play_selected() -> void:
	if not _has_selected_item():
		_export_status.text = "Select a cached audio file first."
		return
	var item := _catalog[_selected_index]
	var path := str(item.get("preview_path", ""))
	if path.is_empty():
		path = str(item.get("absolute_path", ""))
	var stream := _load_stream(path, str(item.get("extension", "")).to_lower())
	if stream == null:
		_export_status.text = "Preview unsupported or failed. For FLAC/AIF/AIFF/M4A, wait for FFmpeg preview decode."
		return
	_player.stream = stream
	_configure_current_stream_loop()
	_player.stream_paused = false
	var start := _waveform.trim_start if _play_selection_check.button_pressed else float(_seek_slider.value)
	_player.play(start)


func _configure_current_stream_loop() -> void:
	if not _player or _player.stream == null:
		return
	var native_loop := _loop_check.button_pressed and not _play_selection_check.button_pressed
	if _player.stream is AudioStreamWAV:
		var wav := _player.stream as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD if native_loop else AudioStreamWAV.LOOP_DISABLED
	elif _player.stream is AudioStreamOggVorbis:
		var ogg := _player.stream as AudioStreamOggVorbis
		ogg.loop = native_loop
	elif _player.stream is AudioStreamMP3:
		var mp3 := _player.stream as AudioStreamMP3
		mp3.loop = native_loop


func _load_stream(path: String, ext: String) -> AudioStream:
	if path.get_extension().to_lower() == "wav" or ext == "wav":
		return AudioStreamWAV.load_from_file(path)
	if path.get_extension().to_lower() == "mp3" or ext == "mp3":
		return AudioStreamMP3.load_from_file(path)
	if path.get_extension().to_lower() == "ogg" or ext == "ogg":
		return AudioStreamOggVorbis.load_from_file(path)
	return null


func _on_wave_trim_changed(start_seconds: float, end_seconds: float) -> void:
	_set_trim(start_seconds, end_seconds, false)


func _set_trim(start_seconds: float, end_seconds: float, update_wave := true) -> void:
	var duration := _waveform.duration_seconds
	if duration <= 0.0:
		return
	var start := clampf(start_seconds, 0.0, duration)
	var end := clampf(end_seconds, 0.0, duration)
	if update_wave:
		_waveform.set_trim_range(start, end, false)
	_sync_trim_spins()


func _sync_trim_spins() -> void:
	_trim_start_spin.set_value_no_signal(_waveform.trim_start)
	_trim_end_spin.set_value_no_signal(_waveform.trim_end)


func _export_selected() -> void:
	if not _has_selected_item():
		_export_status.text = "Select a file before export."
		return
	_ffmpeg_path = _ffmpeg_edit.text.strip_edges()
	if not FileAccess.file_exists(_ffmpeg_path):
		_export_status.text = "FFmpeg executable is missing. Pick a valid executable before export."
		return
	var source := str(_catalog[_selected_index].get("absolute_path", ""))
	var dest := _destination_edit.text.strip_edges()
	if dest.is_empty():
		_export_status.text = "Choose a destination output path."
		return
	var source_root := str(_catalog[_selected_index].get("library_root", _catalog_root))
	var extension_check := _validate_preset_extension(dest, _preset_option.selected)
	if not bool(extension_check.get("ok", false)):
		_export_status.text = str(extension_check.get("message", "Invalid output extension."))
		return
	dest = str(extension_check.path)
	_destination_edit.text = dest
	var validation := validate_export_paths(source, dest, source_root)
	if not bool(validation.get("ok", false)):
		_export_status.text = str(validation.get("message", "Invalid destination."))
		return
	var duration := _waveform.duration_seconds
	var start := float(_trim_start_spin.value)
	var end := float(_trim_end_spin.value)
	if not (start >= 0.0 and end > start and end <= duration):
		_export_status.text = "Invalid trim bounds. Require 0 <= start < end <= duration."
		return
	_join_thread(_export_thread)
	_export_ready = false
	_export_button.disabled = true
	_export_status.text = "Exporting copy..."
	var recipe := {
		"source": source,
		"source_mtime": int(_catalog[_selected_index].get("mtime", 0)),
		"library_root": source_root,
		"destination": dest,
		"preset": _preset_option.selected,
		"quality": float(_quality_slider.value),
		"start": start,
		"end": end,
		"fade_in": float(_fade_in_spin.value),
		"fade_out": float(_fade_out_spin.value),
		"gain_db": float(_gain_spin.value),
		"normalize": _normalize_check.button_pressed
	}
	_export_thread = Thread.new()
	_export_thread.start(_export_worker.bind(_ffmpeg_path, recipe))


static func validate_export_paths(source: String, destination: String, library_root: String) -> Dictionary:
	var src_global := ProjectSettings.globalize_path(source) if source.begins_with("res://") or source.begins_with("user://") else source
	var dst_global := ProjectSettings.globalize_path(destination) if destination.begins_with("res://") or destination.begins_with("user://") else destination
	var root_global := ProjectSettings.globalize_path(library_root) if library_root.begins_with("res://") or library_root.begins_with("user://") else library_root
	if not src_global.is_absolute_path() or not dst_global.is_absolute_path() or not root_global.is_absolute_path():
		return {"ok": false, "message": "Source, destination and library root must resolve to absolute paths."}
	var src := _canonical_path(src_global)
	var dst := _canonical_path(dst_global)
	var root := _canonical_path(root_global)
	if src == dst:
		return {"ok": false, "message": "Destination must not equal the source file."}
	if not root.is_empty() and (dst == root or dst.begins_with(root + "/")):
		return {"ok": false, "message": "Exports inside the read-only source library are rejected."}
	if _has_link_component(src_global) or _has_link_component(root_global) or _has_link_component(dst_global):
		return {"ok": false, "message": "Paths containing filesystem links or aliases are not accepted for protected export validation."}
	var destination_dir := dst_global.simplify_path().get_base_dir()
	if not DirAccess.dir_exists_absolute(destination_dir):
		return {"ok": false, "message": "Destination directory does not exist: %s" % destination_dir}
	return {"ok": true, "path": dst_global.simplify_path()}


func _export_worker(ffmpeg: String, recipe: Dictionary) -> void:
	var result := {"ok": false, "message": "", "destination": ""}
	var protected_root := str(recipe.get("library_root", ""))
	var extension_check := _validate_preset_extension(str(recipe.destination), int(recipe.preset))
	if not bool(extension_check.get("ok", false)):
		result.message = str(extension_check.get("message", "Invalid output extension."))
		_finish_export_worker(result)
		return
	var initial_validation := validate_export_paths(str(recipe.source), str(extension_check.path), protected_root)
	if not bool(initial_validation.get("ok", false)):
		result.message = str(initial_validation.get("message", "Invalid export path."))
		_finish_export_worker(result)
		return
	var dest := str(initial_validation.path)
	var final_dest := _unique_output_path(dest)
	var temp_dest := final_dest + ".gdb_audio_tmp"
	var length := float(recipe.end) - float(recipe.start)
	if length <= 0.0:
		result.message = "Invalid trim bounds: export selection must have positive duration."
		_finish_export_worker(result)
		return
	for candidate in [final_dest, temp_dest]:
		var final_validation := validate_export_paths(str(recipe.source), str(candidate), protected_root)
		if not bool(final_validation.get("ok", false)):
			result.message = str(final_validation.get("message", "Final export path failed validation."))
			_finish_export_worker(result)
			return
	var args := PackedStringArray(["-y", "-hide_banner", "-v", "error", "-ss", str(recipe.start), "-t", str(length), "-i", str(recipe.source), "-vn"])
	var filters: Array[String] = []
	if float(recipe.fade_in) > 0.0:
		filters.append("afade=t=in:st=0:d=%.3f" % float(recipe.fade_in))
	if float(recipe.fade_out) > 0.0:
		var fade_start := maxf(0.0, length - float(recipe.fade_out))
		filters.append("afade=t=out:st=%.3f:d=%.3f" % [fade_start, float(recipe.fade_out)])
	if absf(float(recipe.gain_db)) > 0.001:
		filters.append("volume=%fdB" % float(recipe.gain_db))
	if bool(recipe.normalize):
		filters.append("loudnorm")
	if not filters.is_empty():
		args.append_array(PackedStringArray(["-af", ",".join(filters)]))
	if int(recipe.preset) == 0:
		args.append_array(PackedStringArray(["-ar", "48000", "-acodec", "pcm_s16le", "-f", "wav", temp_dest]))
	else:
		args.append_array(PackedStringArray(["-ar", "48000", "-acodec", "libvorbis", "-q:a", str(recipe.quality), "-f", "ogg", temp_dest]))
	var output: Array = []
	var code := OS.execute(ffmpeg, args, output, true, false)
	if code != 0:
		result.message = "FFmpeg export failed: %s" % "\n".join(output)
		if FileAccess.file_exists(temp_dest):
			DirAccess.remove_absolute(temp_dest)
	else:
		var err := DirAccess.rename_absolute(temp_dest, final_dest)
		if err == OK:
			var provenance := recipe.duplicate()
			provenance.destination = final_dest
			var prov_file := FileAccess.open(final_dest + ".gdb_audio_provenance.json", FileAccess.WRITE)
			if prov_file:
				prov_file.store_string(JSON.stringify(provenance, "\t"))
			result.ok = true
			result.destination = final_dest
			result.message = "Exported: %s" % final_dest
		else:
			result.message = "Could not move temporary export into place: %s" % error_string(err)
	_finish_export_worker(result)


func _finish_export_worker(result: Dictionary) -> void:
	_export_mutex.lock()
	_export_result = result
	_export_ready = true
	_export_mutex.unlock()


func _drain_export_result() -> void:
	if not _export_ready:
		return
	_export_mutex.lock()
	var result := _export_result.duplicate()
	_export_ready = false
	_export_mutex.unlock()
	_join_thread(_export_thread)
	_export_thread = null
	_export_button.disabled = false
	_export_status.text = str(result.get("message", "Export finished."))
	if bool(result.get("ok", false)) and str(result.get("destination", "")).begins_with(ProjectSettings.globalize_path("res://")) and editor_interface:
		editor_interface.get_resource_filesystem().scan()


func _unique_output_path(path: String) -> String:
	if not FileAccess.file_exists(path):
		return path
	var base := path.get_basename()
	var ext := path.get_extension()
	for i in range(1, 10000):
		var candidate := "%s_%03d.%s" % [base, i, ext]
		if not FileAccess.file_exists(candidate):
			return candidate
	return "%s_%d.%s" % [base, Time.get_unix_time_from_system(), ext]


func _preview_id(path: String, mtime: int, size: int) -> String:
	return ("%s_%d_%d" % [_normalize_path(path).sha256_text().substr(0, 16), mtime, size])


func _format_bytes(value: int) -> String:
	if value < 1024:
		return "%d B" % value
	if value < 1024 * 1024:
		return "%.1f KB" % (float(value) / 1024.0)
	if value < 1024 * 1024 * 1024:
		return "%.1f MB" % (float(value) / (1024.0 * 1024.0))
	return "%.1f GB" % (float(value) / (1024.0 * 1024.0 * 1024.0))


func _normalize_path(path: String) -> String:
	return _canonical_path(path)


static func _canonical_path(path: String) -> String:
	return path.replace("\\", "/").simplify_path().trim_suffix("/").to_lower()


static func _has_link_component(path: String) -> bool:
	var simplified := path.replace("\\", "/").simplify_path()
	var cursor := simplified
	if not FileAccess.file_exists(cursor) and not DirAccess.dir_exists_absolute(cursor):
		cursor = cursor.get_base_dir()
	while not cursor.is_empty():
		var parent := cursor.get_base_dir()
		if parent == cursor or parent.is_empty():
			break
		var parent_dir := DirAccess.open(parent)
		if parent_dir and parent_dir.is_link(cursor.get_file()):
			return true
		cursor = parent
	return false


func _validate_preset_extension(path: String, preset: int) -> Dictionary:
	var expected := "wav" if preset == 0 else "ogg"
	var extension := path.get_extension().to_lower()
	if extension.is_empty():
		return {"ok": true, "path": path + "." + expected}
	if extension != expected:
		return {"ok": false, "message": "The selected preset requires a .%s destination, not .%s." % [expected, extension]}
	return {"ok": true, "path": path}


func _has_selected_item() -> bool:
	return _selected_index >= 0 and _selected_index < _catalog.size()


func _reset_selection(message := "Select an audio file.") -> void:
	_selection_token += 1
	_selected_index = -1
	_pending_probe.clear()
	_pending_wave.clear()
	if _player:
		_player.stop()
	if _results:
		_results.deselect_all()
	if _waveform:
		_waveform.peaks = PackedFloat32Array()
		_waveform.duration_seconds = 0.0
	if _seek_slider:
		_seek_slider.set_value_no_signal(0.0)
	if _details_label:
		_details_label.text = message
	if _export_button:
		_export_button.disabled = true


func _on_library_root_chosen(path: String) -> void:
	var chosen := path.strip_edges()
	if _canonical_path(chosen) != _canonical_path(_library_root):
		if _scan_thread and _scan_thread.is_started():
			_stop_scan()
		_reset_selection("Library root changed. Scan to load its catalog.")
		_catalog.clear()
		_catalog_root = ""
		_filtered_indices.clear()
		_rebuild_filter_options()
		_render_results()
	_library_root = chosen
	_root_edit.text = chosen
	_save_settings()


func _join_thread(thread: Thread) -> void:
	if thread and thread.is_started():
		thread.wait_to_finish()
