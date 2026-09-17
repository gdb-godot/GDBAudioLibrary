@tool
extends EditorPlugin

const AudioLibraryBrowser := preload("res://addons/gdb_audio_library/audio_library_browser.gd")

var _browser: Control

func _enter_tree() -> void:
	_browser = AudioLibraryBrowser.new()
	_browser.editor_interface = get_editor_interface()
	_browser.name = "Audio Library"
	_browser.visible = false
	_browser.set_anchors_preset(Control.PRESET_FULL_RECT)
	get_editor_interface().get_editor_main_screen().add_child(_browser)
	_make_visible(false)


func _exit_tree() -> void:
	if _browser:
		_browser.shutdown()
		get_editor_interface().get_editor_main_screen().remove_child(_browser)
		_browser.queue_free()
		_browser = null


func _has_main_screen() -> bool:
	return true


func _make_visible(visible: bool) -> void:
	if _browser:
		_browser.visible = visible


func _get_plugin_name() -> String:
	return "Audio Library"


func _get_plugin_icon() -> Texture2D:
	var base := get_editor_interface().get_base_control()
	return base.get_theme_icon("AudioStreamPlayer", "EditorIcons")
