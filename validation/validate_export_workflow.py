import argparse
import math
import os
import shutil
import subprocess
import sys
import tempfile
import wave
from pathlib import Path


ERROR_MARKERS = ("SCRIPT ERROR", "Parse Error", "Stack overflow", "ERROR:")


def write_wav(path: Path, duration: float, frequency: float) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    sample_rate = 44100
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        frames = bytearray()
        for index in range(int(duration * sample_rate)):
            value = int(math.sin(2.0 * math.pi * frequency * index / sample_rate) * 12000)
            frames.extend(value.to_bytes(2, "little", signed=True))
        output.writeframes(frames)


def run_checked(command: list[str], cwd: Path, env: dict[str, str], label: str) -> str:
    result = subprocess.run(command, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(result.stdout, end="")
    errors = [line for line in result.stdout.splitlines() if any(marker in line for marker in ERROR_MARKERS)]
    if result.returncode != 0 or errors:
        raise RuntimeError(f"{label} failed (exit {result.returncode}); logged errors: {errors}")
    return result.stdout


def main() -> int:
    parser = argparse.ArgumentParser(description="Run actual Godot integration checks for GDB Audio Library")
    parser.add_argument("--godot", required=True, type=Path)
    parser.add_argument("--ffmpeg", required=True, type=Path)
    args = parser.parse_args()
    if not args.godot.is_file() or not args.ffmpeg.is_file():
        parser.error("Godot and FFmpeg executable paths must exist")

    addon = Path(__file__).resolve().parents[1]
    temp_parent = Path(tempfile.gettempdir()).resolve()
    temp = Path(tempfile.mkdtemp(prefix="gdb_audio_library_integration_", dir=temp_parent)).resolve()
    try:
        project_addon = temp / "addons" / "gdb_audio_library"
        shutil.copytree(addon, project_addon, ignore=shutil.ignore_patterns(".git", ".godot", "__pycache__"))
        library = temp / "Library"
        output = temp / "Output"
        output.mkdir()
        write_wav(library / "Source A" / "tone with spaces & Unicode Ω.wav", 1.25, 440.0)
        write_wav(library / "Source B" / "second.wav", 0.3, 220.0)

        alias: Path | None = temp / "Library Alias"
        try:
            alias.symlink_to(library, target_is_directory=True)
        except OSError:
            alias = None

        (temp / "project.godot").write_text(
            'config_version=5\n'
            '[application]\n'
            'config/name="GDB Audio Library Integration"\n'
            '[editor_plugins]\n'
            'enabled=PackedStringArray("res://addons/gdb_audio_library/plugin.cfg")\n',
            encoding="utf-8",
        )
        env = os.environ.copy()
        env.update(
            {
                "GDB_AUDIO_TEST_LIBRARY": str(library),
                "GDB_AUDIO_TEST_OUTPUT": str(output),
                "GDB_AUDIO_TEST_FFMPEG": str(args.ffmpeg),
                "GDB_AUDIO_TEST_ALIAS": str(alias) if alias is not None else "",
            }
        )
        godot = str(args.godot)
        run_checked([godot, "--headless", "--path", str(temp), "--editor", "--quit"], temp, env, "enabled plugin load")
        runtime_log = run_checked(
            [
                godot,
                "--headless",
                "--audio-driver",
                "Dummy",
                "--path",
                str(temp),
                "--script",
                "res://addons/gdb_audio_library/validation/integration_test.gd",
            ],
            temp,
            env,
            "Godot integration",
        )
        if "INTEGRATION_PASS" not in runtime_log:
            raise RuntimeError("Godot integration did not reach its pass marker")
        print("VALIDATION_PASS: enabled plugin and actual Godot addon workflow")
        return 0
    except Exception as error:
        print(f"VALIDATION_FAIL: {error}", file=sys.stderr)
        return 1
    finally:
        if temp.parent != temp_parent or not temp.name.startswith("gdb_audio_library_integration_"):
            raise RuntimeError("Unexpected integration cleanup directory")
        shutil.rmtree(temp, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
