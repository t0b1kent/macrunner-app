#!/usr/bin/env python3
"""Load packaged GStreamer factories without constructing a media pipeline.

Usage: python3 scripts/release/verify_engine_media.py ENGINE_ROOT
The native check runs in a bounded child process with a temporary registry and
home directory. ENGINE_ROOT is read only; no Wine, game, audio or GPU is started.
"""

import ctypes
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile


# Include Wine's explicitly created parser/converter elements, not just codecs.
# Factory -> plugin mapping also checks provenance after dynamic discovery.
FACTORY_PLUGINS = {
    "decodebin": "playback", "decodebin3": "playback", "parsebin": "playback",
    "typefind": "coreelements", "filesrc": "coreelements", "queue": "coreelements",
    "capsfilter": "coreelements", "identity": "coreelements", "multiqueue": "coreelements",
    "qtdemux": "isomp4", "matroskademux": "matroska", "oggdemux": "ogg", "avidemux": "avi",
    "h264parse": "videoparsersbad", "aacparse": "audioparsers",
    "avdec_h264": "libav", "avdec_aac": "libav", "avdec_wmv3": "libav",
    "theoradec": "theora", "vp8dec": "vpx", "vorbisdec": "vorbis",
    "videoconvert": "videoconvertscale", "videoscale": "videoconvertscale",
    "deinterlace": "deinterlace", "videoflip": "videofilter",
    "audioconvert": "audioconvert", "audioresample": "audioresample",
}
FACTORIES = tuple(FACTORY_PLUGINS)
RESULT_MARKER = "MACRUNNER_MEDIA_RESULT="
TIMEOUT_SECONDS = 60


class GError(ctypes.Structure):
    _fields_ = [("domain", ctypes.c_uint32), ("code", ctypes.c_int),
                ("message", ctypes.c_char_p)]


class GList(ctypes.Structure):
    pass


GList._fields_ = [("data", ctypes.c_void_p),
                 ("next", ctypes.POINTER(GList)),
                 ("prev", ctypes.POINTER(GList))]


def inside(path, directory):
    try:
        path.relative_to(directory)
        return True
    except ValueError:
        return False


def media_environment(engine, data, manifest):
    """Resolve the manifest's actual media settings, without host GST defaults."""
    templates = manifest.get("environment")
    if not isinstance(templates, dict):
        raise ValueError("ENGINE.json has no environment object")
    relevant = {name + suffix for name in (
        "GST_PLUGIN_PATH", "GST_PLUGIN_SYSTEM_PATH", "GST_PLUGIN_SCANNER", "GST_REGISTRY",
    ) for suffix in ("", "_1_0")}
    values = {}
    for key, template in templates.items():
        if key not in relevant:
            continue
        if not isinstance(template, str):
            raise ValueError(f"Non-string environment template: {key}")
        value = template.replace("${ENGINE}", str(engine)).replace("${DATA}", str(data))
        if "${" in value:
            raise ValueError(f"Unresolved environment template: {key}")
        values[key] = value

    def effective(name):
        if name + "_1_0" in values:
            return values[name + "_1_0"]
        if name in values:
            return values[name]
        raise ValueError(f"Missing explicit media environment: {name}[_1_0]")

    plugins = (engine / "media/gstreamer-1.0").resolve(strict=True)
    if not plugins.is_dir() or not inside(plugins, engine):
        raise ValueError("Plugin directory escapes engine or is not a directory")
    paths = []
    for name in ("GST_PLUGIN_PATH", "GST_PLUGIN_SYSTEM_PATH"):
        value = effective(name)
        if not value:
            continue
        for item in value.split(os.pathsep):
            if not item or not Path(item).is_absolute():
                raise ValueError(f"Unsafe relative/empty path component: {name}")
            resolved = Path(item).resolve(strict=True)
            if not resolved.is_dir() or not inside(resolved, plugins):
                raise ValueError(f"Plugin search path escapes packaged plugins: {name}")
            paths.append(resolved)
    if plugins not in paths:
        raise ValueError("Packaged plugin directory is absent from effective search paths")

    scanner = Path(effective("GST_PLUGIN_SCANNER")).resolve(strict=True)
    expected_scanner = (engine / "media/bin/gst-plugin-scanner").resolve(strict=True)
    if scanner != expected_scanner or not inside(scanner, engine):
        raise ValueError("Scanner is not the packaged scanner")
    if not scanner.is_file() or not os.access(scanner, os.X_OK):
        raise ValueError("Packaged scanner is not executable")
    registry_value = effective("GST_REGISTRY")
    registry = Path(registry_value).resolve()
    if not Path(registry_value).is_absolute() or not inside(registry, data):
        raise ValueError("Registry must be located under temporary ${DATA}")
    registry.parent.mkdir(parents=True, exist_ok=True)
    # Both spelling variants remain as declared; GStreamer chooses _1_0 first.
    # Force a fresh external scan rather than accepting caller scan suppression.
    values["GST_REGISTRY_FORK"] = "yes"
    values["GST_REGISTRY_REUSE_PLUGIN_SCANNER"] = "yes"
    values["GST_REGISTRY_UPDATE"] = "yes"
    return values, plugins, scanner, registry


def bind(library, name, result, arguments):
    function = getattr(library, name)
    function.restype = result
    function.argtypes = arguments
    return function


def construct_elements(make_element, unref):
    """Exercise each factory in NULL state; never link or start a pipeline."""
    created, errors = [], []
    for name in FACTORIES:
        element = make_element(name.encode("ascii"), None)
        if element:
            created.append(name)
            unref(element)
        else:
            errors.append("Failed to construct " + name)
    return created, errors


def inspect_engine(engine, data):
    manifest = json.loads((engine / "ENGINE.json").read_text())
    values, plugins, scanner, registry_path = media_environment(engine, data, manifest)
    for key in tuple(os.environ):
        if key.startswith(("GST_", "DYLD_")):
            del os.environ[key]
    os.environ.update(values)
    core_path = (engine / "wine/lib/wine/aarch64-unix/libgstreamer-1.0.0.dylib").resolve(strict=True)
    if not inside(core_path, engine):
        raise ValueError("GStreamer core escapes the engine")
    gst = ctypes.CDLL(str(core_path))
    init = bind(gst, "gst_init_check", ctypes.c_int,
                [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.POINTER(GError))])
    get_registry = bind(gst, "gst_registry_get", ctypes.c_void_p, [])
    scan = bind(gst, "gst_registry_scan_path", ctypes.c_int,
                [ctypes.c_void_p, ctypes.c_char_p])
    find = bind(gst, "gst_element_factory_find", ctypes.c_void_p, [ctypes.c_char_p])
    get_plugin = bind(gst, "gst_plugin_feature_get_plugin", ctypes.c_void_p,
                      [ctypes.c_void_p])
    filename = bind(gst, "gst_plugin_get_filename", ctypes.c_char_p, [ctypes.c_void_p])
    plugin_name = bind(gst, "gst_plugin_get_name", ctypes.c_char_p, [ctypes.c_void_p])
    unref = bind(gst, "gst_object_unref", None, [ctypes.c_void_p])
    load_plugin = bind(gst, "gst_plugin_load", ctypes.c_void_p, [ctypes.c_void_p])
    make_element = bind(gst, "gst_element_factory_make", ctypes.c_void_p,
                        [ctypes.c_char_p, ctypes.c_char_p])
    get_plugins = bind(gst, "gst_registry_get_plugin_list", ctypes.POINTER(GList),
                       [ctypes.c_void_p])
    free_plugins = bind(gst, "gst_plugin_list_free", None, [ctypes.POINTER(GList)])
    error = ctypes.POINTER(GError)()
    if not init(None, None, ctypes.byref(error)):
        message = error.contents.message.decode("utf-8", "replace") if error else "unknown error"
        raise RuntimeError("gst_init_check failed: " + message)
    registry = get_registry()
    if not registry:
        raise RuntimeError("No GStreamer registry")
    # False also means gst_init_check already scanned these files; factories
    # and their provenance below are the acceptance criteria.
    scan(registry, os.fsencode(plugins))
    errors, factories, registered, static_plugins = [], {}, {}, []
    loaded_plugins = set()

    def checked_filename(plugin):
        raw = filename(plugin)
        if not raw:
            return None
        path = Path(os.fsdecode(raw)).resolve(strict=True)
        if not inside(path, plugins) or not path.is_file():
            raise ValueError("Plugin outside packaged directory: " + str(path))
        return str(path.relative_to(engine))

    head = get_plugins(registry)
    node = head
    try:
        while node:
            plugin = node.contents.data
            name = (plugin_name(plugin) or b"<unnamed>").decode("utf-8", "replace")
            path = checked_filename(plugin)
            if path is None:
                static_plugins.append(name)
            else:
                registered[name] = path
            node = node.contents.next
    finally:
        if head:
            free_plugins(head)

    for name in FACTORIES:
        factory = find(name.encode("ascii"))
        if not factory:
            errors.append("Missing factory: " + name)
            continue
        plugin = loaded = None
        try:
            plugin = get_plugin(factory)
            if not plugin:
                errors.append("Factory has no plugin: " + name)
                continue
            path = checked_filename(plugin)
            if path is None:
                errors.append("Required factory has no packaged plugin filename: " + name)
                continue
            expected = "media/gstreamer-1.0/libgst" + FACTORY_PLUGINS[name] + ".dylib"
            if path != expected:
                errors.append("Factory belongs to an unexpected plugin: " + name + " -> " + path)
                continue
            # Registry metadata alone does not prove that dyld can load the
            # plugin into this process. The returned plugin owns another ref,
            # including when it is the same pointer as the registry plugin.
            loaded = load_plugin(plugin)
            if not loaded:
                errors.append("Plugin failed to load for factory: " + name)
                continue
            loaded_path = checked_filename(loaded)
            if loaded_path != path:
                errors.append("Loaded plugin differs from registry for factory: " + name)
                continue
            loaded_plugins.add(path)
            factories[name] = path
        finally:
            if loaded:
                unref(loaded)
            if plugin:
                unref(plugin)
            unref(factory)
    created, construction_errors = construct_elements(make_element, unref)
    errors.extend(construction_errors)
    return {
        "ok": not errors, "engine": str(engine), "check": "plugin-load-and-element-construction",
        "factoryCount": len(factories), "requiredFactoryCount": len(FACTORIES),
        "factories": factories, "registeredPluginCount": len(registered),
        "loadedPluginCount": len(loaded_plugins), "decodebinCreated": "decodebin" in created,
        "constructedFactoryCount": len(created), "constructedFactories": created,
        "staticPlugins": sorted(static_plugins),
        "scannerConfigured": str(scanner.relative_to(engine)),
        "temporaryRegistryCreated": registry_path.is_file(), "errors": errors,
    }


def worker(engine, data):
    try:
        result = inspect_engine(Path(engine).resolve(strict=True), Path(data).resolve(strict=True))
    except Exception as error:
        result = {"ok": False, "errors": [f"{type(error).__name__}: {error}"]}
    print(RESULT_MARKER + json.dumps(result, separators=(",", ":")), flush=True)
    return 0 if result["ok"] else 1


def main(argv):
    if len(argv) == 4 and argv[1] == "--worker":
        return worker(argv[2], argv[3])
    try:
        if len(argv) != 2:
            raise ValueError("Usage: verify_engine_media.py ENGINE_ROOT")
        engine = Path(argv[1]).resolve(strict=True)
        with tempfile.TemporaryDirectory(prefix="macrunner-media-check-") as temporary:
            data = Path(temporary)
            env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(data),
                   "TMPDIR": str(data), "XDG_CACHE_HOME": str(data / "cache"),
                   "XDG_DATA_HOME": str(data / "data"), "LANG": "C"}
            child = subprocess.Popen(
                [sys.executable, "-I", str(Path(__file__).resolve()), "--worker", str(engine), str(data)],
                env=env, cwd=data, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, errors="replace", start_new_session=True,
            )
            try:
                stdout, stderr = child.communicate(timeout=TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                # Include only this worker's scanner descendants in timeout cleanup.
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.communicate()
                raise
            results = [line[len(RESULT_MARKER):] for line in stdout.splitlines()
                       if line.startswith(RESULT_MARKER)]
            if len(results) != 1:
                raise RuntimeError(f"Native verifier returned {child.returncode} without one result; "
                                   f"stderr: {stderr[-1500:]}")
            result = json.loads(results[0])
            if child.returncode != 0:
                result["ok"] = False
            if stderr:
                result["nativeDiagnostics"] = stderr[-1500:]
            result["childExitCode"] = child.returncode
    except subprocess.TimeoutExpired:
        result = {"ok": False, "errors": [f"Native verifier timed out after {TIMEOUT_SECONDS}s"]}
    except Exception as error:
        result = {"ok": False, "errors": [f"{type(error).__name__}: {error}"]}
    print(json.dumps(result, separators=(",", ":")))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
