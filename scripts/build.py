"""Build the Soluna runtime and its extlua module without editing the engine."""
import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess
import json

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("target", choices=["native", "web"])
parser.add_argument("--soluna", type=Path, default=ROOT / "soluna")
parser.add_argument("--luamake", type=Path)
parser.add_argument("--cmake-option", action="append", default=[])
options = parser.parse_args()
engine = options.soluna.resolve()
host = {"Linux": "linux", "Darwin": "macos", "Windows": "windows"}[platform.system()]
tool_host = {"linux": "linux", "windows": "win32", "macos": "osx_arm64" if platform.machine() == "arm64" else "osx"}[host]
luamake = options.luamake or engine / "bin/luamake-bin/bin" / tool_host / ("luamake.exe" if host == "windows" else "luamake")
if not luamake.is_file():
    raise SystemExit("Missing luamake. Initialize the Soluna submodules or pass --luamake.")

env = dict(os.environ, SOLUNA_DIR=str(engine))
runtime_build = ROOT / "build" / ("runtime-web" if options.target == "web" else "runtime-native")
runtime_bin = runtime_build / "bin"
module_build = ROOT / "build" / options.target
destination = ROOT / "dist" / options.target
runtime_build.mkdir(parents=True, exist_ok=True)

def run(command, cwd=ROOT):
    print(" ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=cwd, env=env, check=True)

arguments = ["-f", ROOT / "make.lua", "-builddir", os.path.relpath(runtime_build, engine), "-bindir", os.path.relpath(runtime_bin, engine)]
if options.target == "web":
    if not shutil.which("emcc"):
        raise SystemExit("Activate the Emscripten SDK before building the web client.")
    arguments += ["-compiler", "emcc"]
run([luamake, "init", *arguments], engine)
run([luamake, *arguments, "soluna"], engine)

module_build.mkdir(parents=True, exist_ok=True)
shdc = engine / "bin/sokol-tools-bin/bin" / tool_host / ("sokol-shdc.exe" if host == "windows" else "sokol-shdc")
shader_language = "wgsl" if options.target == "web" else {"linux":"glsl430", "macos":"metal_macos", "windows":"hlsl4"}[host]
run([shdc, "--input", ROOT / "extlua/radial_shape.glsl", "--output", module_build / "radial_shape.glsl.h", "--slang", shader_language, "--format", "sokol"])

configure = ["cmake", "-S", ROOT, "-B", module_build, f"-DSOLUNA_DIR={engine}"]
if options.target == "web":
    configure.insert(0, "emcmake")
configure.extend(options.cmake_option)
run(configure)
run(["cmake", "--build", module_build, "--config", "Release"])

destination.mkdir(parents=True, exist_ok=True)
(ROOT / "game/manifest.json").write_text(json.dumps(["/game/" + str(p.relative_to(ROOT / "game")).replace("\\", "/") for p in sorted((ROOT / "game").rglob("*")) if p.is_file() and p.name != "manifest.json"]))
if options.target == "web":
    runtime_destination = destination / "runtime"
    runtime_destination.mkdir(exist_ok=True)
    for source in runtime_bin.iterdir():
        if source.is_file() and source.name.startswith("soluna."):
            shutil.copy2(source, runtime_destination / source.name)
    # Apply the same WebGPU glue fixes as the pinned engine's release action.
    glue = runtime_destination / "soluna.js"
    source = glue.read_text()
    for old, new in (
        ("setBindGroup(groupIndex,group,(growMemViews(),HEAPU32),dynamicOffsetsPtr>>2,dynamicOffsetCount)",
         "setBindGroup(groupIndex,group,(growMemViews(),HEAPU32).subarray(dynamicOffsetsPtr>>2,(dynamicOffsetsPtr>>2)+dynamicOffsetCount))"),
        ("setBindGroup(groupIndex, group, (growMemViews(), HEAPU32), ((dynamicOffsetsPtr) >> 2), dynamicOffsetCount)",
         "setBindGroup(groupIndex, group, (growMemViews(), HEAPU32).subarray(((dynamicOffsetsPtr) >> 2), ((dynamicOffsetsPtr) >> 2) + dynamicOffsetCount))"),
        ("var group=WebGPU.getJsObject(groupPtr);if(dynamicOffsetCount==0)",
         "var group=WebGPU.getJsObject(groupPtr);if(!group){return}if(dynamicOffsetCount==0)"),
        ("var group = WebGPU.getJsObject(groupPtr);\n  if (dynamicOffsetCount == 0)",
         "var group = WebGPU.getJsObject(groupPtr);\n  if (!group) { return; }\n  if (dynamicOffsetCount == 0)"),
    ):
        source = source.replace(old, new)
    glue.write_text(source)
    shutil.copy2(module_build / "bin/websocket.wasm", runtime_destination / "websocket.wasm")
    shutil.copy2(ROOT / "web/index.html", destination / "index.html")
else:
    shutil.copytree(ROOT / "game", destination / "game", dirs_exist_ok=True)
    suffix = ".dll" if host == "windows" else ".so"
    module = module_build / "bin" / ("websocket" + suffix)
    if not module.exists():
        module = module_build / "bin/Release" / ("websocket" + suffix)
    shutil.copy2(module, destination / module.name)
    executable = "soluna.exe" if host == "windows" else "soluna"
    shutil.copy2(runtime_bin / executable, destination / executable)
print(f"Ready: {destination}")
