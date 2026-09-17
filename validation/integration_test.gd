extends SceneTree

const Browser := preload("res://addons/gdb_audio_library/audio_library_browser.gd")
const Waveform := preload("res://addons/gdb_audio_library/waveform_view.gd")

var _browser: Control

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var library := OS.get_environment("GDB_AUDIO_TEST_LIBRARY")
	var output := OS.get_environment("GDB_AUDIO_TEST_OUTPUT")
	var ffmpeg := OS.get_environment("GDB_AUDIO_TEST_FFMPEG")
	assert(not library.is_empty() and not output.is_empty() and FileAccess.file_exists(ffmpeg))

	_test_waveform()
	_browser = Browser.new()
	root.add_child(_browser)
	await process_frame

	assert(_browser._folder_dialog.access == FileDialog.ACCESS_FILESYSTEM)
	assert(_browser._ffmpeg_dialog.access == FileDialog.ACCESS_FILESYSTEM)
	assert(_browser._dest_dialog.access == FileDialog.ACCESS_FILESYSTEM)
	assert(_browser._details_label.bbcode_enabled)

	var source := library.path_join("Source A").path_join("tone with spaces & Unicode Ω.wav")
	var second_source := library.path_join("Source B").path_join("second.wav")
	var source_hash := FileAccess.get_sha256(source)
	_test_path_validation(source, library, output)

	_browser._root_edit.text = library
	_browser._ffmpeg_edit.text = ffmpeg
	_browser._start_scan()
	await _wait_for_scan()
	assert(_browser._catalog.size() == 2)
	assert(_browser._catalog_root.simplify_path().to_lower() == library.simplify_path().to_lower())
	for item in _browser._catalog:
		assert(str(item.library_root).simplify_path().to_lower() == library.simplify_path().to_lower())

	_browser._select_visible_result(0)
	await _wait_for_audio_workers()
	assert(_browser._waveform.duration_seconds > 0.1)
	assert(not _browser._waveform.peaks.is_empty())
	assert(_browser._has_selected_item())

	_browser._reset_selection("stale test")
	_browser._start_probe(_browser._selection_token - 1, _browser._catalog[0], ffmpeg)
	_browser._start_waveform(_browser._selection_token - 1, _browser._catalog[0], ffmpeg)
	await _wait_for_audio_workers()
	assert(_browser._selected_index == -1)
	assert(_browser._waveform.duration_seconds == 0.0)
	assert(_browser._waveform.peaks.is_empty())

	_browser._selected_index = 0
	_browser._waveform.duration_seconds = 1.25
	_browser._waveform.set_full_selection()
	_browser._trim_start_spin.value = 0.3
	_browser._trim_end_spin.value = 0.8
	assert(is_equal_approx(_browser._waveform.trim_start, 0.3))
	assert(is_equal_approx(_browser._waveform.trim_end, 0.8))
	_test_exports(source, library, output, ffmpeg, source_hash)
	_test_loop_playback(source)

	_browser._start_scan()
	assert(_browser._selected_index == -1)
	assert(_browser._catalog.is_empty())
	_browser._play_selected()
	assert(_browser._export_status.text.contains("Select"))
	_browser._stop_scan()

	var cache_file := FileAccess.open("user://gdb_audio_library/catalog.json", FileAccess.WRITE)
	assert(cache_file != null)
	cache_file.store_string(JSON.stringify({"root": library, "items": [{"name": "stale.wav"}]}))
	cache_file.close()
	_browser._library_root = output
	_browser._catalog.clear()
	_browser._catalog.append({"name": "must clear"})
	_browser._load_cache()
	assert(_browser._catalog.is_empty())
	assert(_browser._catalog_root.is_empty())

	_browser.shutdown()
	_browser.queue_free()
	await process_frame
	await process_frame
	print("INTEGRATION_PASS")
	quit(0)


func _test_waveform() -> void:
	var waveform := Waveform.new()
	root.add_child(waveform)
	waveform.size = Vector2(100.0, 100.0)
	waveform.duration_seconds = 0.0
	assert(waveform.trim_start == 0.0 and waveform.trim_end == 0.0)
	waveform.duration_seconds = 1.25
	assert(is_equal_approx(waveform.trim_start, 0.0))
	assert(is_equal_approx(waveform.trim_end, 1.25))
	waveform.set_trim_range(0.2, 0.7)
	assert(is_equal_approx(waveform.trim_start, 0.2))
	assert(is_equal_approx(waveform.trim_end, 0.7))
	waveform._dragging = "start"
	waveform._apply_drag(90.0)
	assert(waveform.trim_start < waveform.trim_end)
	assert(waveform.trim_end <= waveform.duration_seconds)
	waveform._dragging = "end"
	waveform._apply_drag(0.0)
	assert(waveform.trim_start < waveform.trim_end)
	waveform.set_trim_range(1.25, 1.25)
	assert(waveform.trim_start < waveform.trim_end)
	assert(is_equal_approx(waveform.trim_end, 1.25))
	waveform.set_full_selection()
	assert(is_equal_approx(waveform.trim_start, 0.0))
	assert(is_equal_approx(waveform.trim_end, 1.25))
	waveform.queue_free()


func _test_path_validation(source: String, library: String, output: String) -> void:
	var escaped := output.path_join("..").path_join(library.get_file()).path_join("escape.wav")
	var direct_inside := library.path_join("inside.wav")
	assert(not bool(Browser.validate_export_paths(source, source, library).ok))
	assert(not bool(Browser.validate_export_paths(source, direct_inside, library).ok))
	assert(not bool(Browser.validate_export_paths(source, escaped, library).ok))
	assert(not bool(Browser.validate_export_paths(source, "relative.wav", library).ok))
	assert(not bool(Browser.validate_export_paths(source, output.path_join("missing").path_join("file.wav"), library).ok))
	var alias := OS.get_environment("GDB_AUDIO_TEST_ALIAS")
	if not alias.is_empty():
		assert(not bool(Browser.validate_export_paths(source, alias.path_join("aliased.wav"), library).ok))


func _test_exports(source: String, library: String, output: String, ffmpeg: String, source_hash: String) -> void:
	var wav_dest := output.path_join("trim output Ω.wav")
	var recipe := {
		"source": source,
		"source_mtime": FileAccess.get_modified_time(source),
		"library_root": library,
		"destination": wav_dest,
		"preset": 0,
		"quality": 5.0,
		"start": 0.2,
		"end": 0.7,
		"fade_in": 0.01,
		"fade_out": 0.01,
		"gain_db": 0.0,
		"normalize": false
	}
	_browser._export_worker(ffmpeg, recipe)
	var first: Dictionary = _browser._export_result.duplicate()
	assert(bool(first.ok))
	assert(FileAccess.file_exists(str(first.destination)))
	var wav := AudioStreamWAV.load_from_file(str(first.destination))
	assert(wav != null)
	assert(absf(wav.get_length() - 0.5) < 0.04)
	assert(wav.mix_rate == 48000)
	assert(wav.format == AudioStreamWAV.FORMAT_16_BITS)
	assert(FileAccess.file_exists(str(first.destination) + ".gdb_audio_provenance.json"))

	_browser._export_worker(ffmpeg, recipe)
	var collision: Dictionary = _browser._export_result.duplicate()
	assert(bool(collision.ok))
	assert(str(collision.destination) != str(first.destination))
	assert(str(collision.destination).contains("_001.wav"))

	recipe.destination = output.path_join("music.ogg")
	recipe.preset = 1
	_browser._export_worker(ffmpeg, recipe)
	var ogg_result: Dictionary = _browser._export_result.duplicate()
	assert(bool(ogg_result.ok))
	var ogg := AudioStreamOggVorbis.load_from_file(str(ogg_result.destination))
	assert(ogg != null)
	assert(absf(ogg.get_length() - 0.5) < 0.05)

	recipe.destination = output.path_join("wrong.wav")
	_browser._export_worker(ffmpeg, recipe)
	assert(not bool(_browser._export_result.ok))
	_browser._library_root = output
	recipe.destination = output.path_join("..").path_join(library.get_file()).path_join("forbidden.wav")
	_browser._export_worker(ffmpeg, recipe)
	assert(not bool(_browser._export_result.ok))
	assert(not FileAccess.file_exists(library.path_join("forbidden.wav")))
	assert(FileAccess.get_sha256(source) == source_hash)


func _test_loop_playback(source: String) -> void:
	var stream := AudioStreamWAV.load_from_file(source)
	assert(stream != null)
	_browser._player.stream = stream
	_browser._loop_check.button_pressed = true
	_browser._play_selection_check.button_pressed = false
	_browser._configure_current_stream_loop()
	assert(stream.loop_mode == AudioStreamWAV.LOOP_FORWARD)
	assert(_browser._player.finished.is_connected(_browser._on_player_finished))
	assert(is_equal_approx(_browser._loop_restart_position(), 0.0))
	_browser._play_selection_check.button_pressed = true
	_browser._waveform.duration_seconds = stream.get_length()
	_browser._waveform.set_trim_range(0.2, stream.get_length())
	_browser._configure_current_stream_loop()
	assert(stream.loop_mode == AudioStreamWAV.LOOP_DISABLED)
	assert(is_equal_approx(_browser._loop_restart_position(), 0.2))
	_browser._player.stop()
	_browser._player.stream = null
	stream = null
	await process_frame


func _wait_for_scan() -> void:
	for _i in 600:
		if _browser._scan_thread == null:
			return
		await process_frame
	assert(false, "scan timed out")


func _wait_for_audio_workers() -> void:
	for _i in 1200:
		if _browser._probe_thread == null and _browser._wave_thread == null and _browser._pending_probe.is_empty() and _browser._pending_wave.is_empty():
			return
		await process_frame
	assert(false, "audio workers timed out")
