"""Minimal ctypes bridge to CoreFoundation, IOKit and Metal.

Everything dyno reads is available to an unprivileged user through these three
system libraries, which is why the tool never needs sudo. Keeping the bridge in
one module means the rest of the codebase deals in plain Python objects.
"""

from __future__ import annotations

import ctypes
import ctypes.util
from ctypes import (
    POINTER,
    byref,
    c_bool,
    c_char_p,
    c_double,
    c_int,
    c_int64,
    c_long,
    c_uint32,
    c_uint64,
    c_void_p,
)
from typing import Any

_CF_PATH = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
_IOKIT_PATH = "/System/Library/Frameworks/IOKit.framework/IOKit"
_METAL_PATH = "/System/Library/Frameworks/Metal.framework/Metal"
_OBJC_PATH = "/usr/lib/libobjc.A.dylib"

CF = ctypes.CDLL(_CF_PATH)
IOKit = ctypes.CDLL(_IOKIT_PATH)

kCFStringEncodingUTF8 = 0x08000100
kCFAllocatorDefault = None
kIOMainPortDefault = 0

# --- CoreFoundation ---------------------------------------------------------

CF.CFRelease.restype = None
CF.CFRelease.argtypes = [c_void_p]
CF.CFRetain.restype = c_void_p
CF.CFRetain.argtypes = [c_void_p]
CF.CFGetTypeID.restype = c_long
CF.CFGetTypeID.argtypes = [c_void_p]

CF.CFStringCreateWithCString.restype = c_void_p
CF.CFStringCreateWithCString.argtypes = [c_void_p, c_char_p, c_uint32]
CF.CFStringGetCStringPtr.restype = c_char_p
CF.CFStringGetCStringPtr.argtypes = [c_void_p, c_uint32]
CF.CFStringGetCString.restype = c_bool
CF.CFStringGetCString.argtypes = [c_void_p, c_char_p, c_long, c_uint32]
CF.CFStringGetLength.restype = c_long
CF.CFStringGetLength.argtypes = [c_void_p]
CF.CFStringGetTypeID.restype = c_long

CF.CFNumberGetValue.restype = c_bool
CF.CFNumberGetValue.argtypes = [c_void_p, c_int, c_void_p]
CF.CFNumberIsFloatType.restype = c_bool
CF.CFNumberIsFloatType.argtypes = [c_void_p]
CF.CFNumberGetTypeID.restype = c_long

CF.CFBooleanGetValue.restype = c_bool
CF.CFBooleanGetValue.argtypes = [c_void_p]
CF.CFBooleanGetTypeID.restype = c_long

CF.CFDataGetLength.restype = c_long
CF.CFDataGetLength.argtypes = [c_void_p]
CF.CFDataGetBytePtr.restype = POINTER(ctypes.c_ubyte)
CF.CFDataGetBytePtr.argtypes = [c_void_p]
CF.CFDataGetTypeID.restype = c_long

CF.CFArrayGetCount.restype = c_long
CF.CFArrayGetCount.argtypes = [c_void_p]
CF.CFArrayGetValueAtIndex.restype = c_void_p
CF.CFArrayGetValueAtIndex.argtypes = [c_void_p, c_long]
CF.CFArrayGetTypeID.restype = c_long

CF.CFDictionaryGetCount.restype = c_long
CF.CFDictionaryGetCount.argtypes = [c_void_p]
CF.CFDictionaryGetValue.restype = c_void_p
CF.CFDictionaryGetValue.argtypes = [c_void_p, c_void_p]
CF.CFDictionaryGetKeysAndValues.restype = None
CF.CFDictionaryGetKeysAndValues.argtypes = [c_void_p, c_void_p, c_void_p]
CF.CFDictionaryGetTypeID.restype = c_long

_TYPE_STRING = CF.CFStringGetTypeID()
_TYPE_NUMBER = CF.CFNumberGetTypeID()
_TYPE_BOOL = CF.CFBooleanGetTypeID()
_TYPE_DATA = CF.CFDataGetTypeID()
_TYPE_ARRAY = CF.CFArrayGetTypeID()
_TYPE_DICT = CF.CFDictionaryGetTypeID()

kCFNumberSInt64Type = 4
kCFNumberFloat64Type = 13

_cfstr_cache: dict[str, int] = {}


def cfstr(value: str) -> int:
    """Create (and cache) a CFString. Cached strings are intentionally leaked
    once each -- they are constants used for the lifetime of the process."""
    cached = _cfstr_cache.get(value)
    if cached is None:
        cached = CF.CFStringCreateWithCString(
            kCFAllocatorDefault, value.encode("utf-8"), kCFStringEncodingUTF8
        )
        _cfstr_cache[value] = cached
    return cached


def from_cfstring(ref: int | None) -> str | None:
    if not ref:
        return None
    ptr = CF.CFStringGetCStringPtr(ref, kCFStringEncodingUTF8)
    if ptr is not None:
        return ptr.decode("utf-8", "replace")
    length = CF.CFStringGetLength(ref) * 4 + 1
    buf = ctypes.create_string_buffer(length)
    if CF.CFStringGetCString(ref, buf, length, kCFStringEncodingUTF8):
        return buf.value.decode("utf-8", "replace")
    return None


def to_python(ref: int | None) -> Any:
    """Recursively convert a CoreFoundation value into Python primitives."""
    if not ref:
        return None
    type_id = CF.CFGetTypeID(ref)
    if type_id == _TYPE_STRING:
        return from_cfstring(ref)
    if type_id == _TYPE_NUMBER:
        if CF.CFNumberIsFloatType(ref):
            out = c_double()
            CF.CFNumberGetValue(ref, kCFNumberFloat64Type, byref(out))
            return out.value
        out64 = c_int64()
        CF.CFNumberGetValue(ref, kCFNumberSInt64Type, byref(out64))
        return out64.value
    if type_id == _TYPE_BOOL:
        return bool(CF.CFBooleanGetValue(ref))
    if type_id == _TYPE_DATA:
        length = CF.CFDataGetLength(ref)
        ptr = CF.CFDataGetBytePtr(ref)
        return bytes(bytearray(ptr[i] for i in range(length)))
    if type_id == _TYPE_ARRAY:
        return [to_python(CF.CFArrayGetValueAtIndex(ref, i)) for i in range(CF.CFArrayGetCount(ref))]
    if type_id == _TYPE_DICT:
        count = CF.CFDictionaryGetCount(ref)
        keys = (c_void_p * count)()
        values = (c_void_p * count)()
        CF.CFDictionaryGetKeysAndValues(ref, keys, values)
        return {from_cfstring(keys[i]): to_python(values[i]) for i in range(count)}
    return None


def release(ref: int | None) -> None:
    if ref:
        CF.CFRelease(ref)


# --- IOKit ------------------------------------------------------------------

IOKit.IOServiceMatching.restype = c_void_p
IOKit.IOServiceMatching.argtypes = [c_char_p]
IOKit.IOServiceGetMatchingService.restype = c_uint32
IOKit.IOServiceGetMatchingService.argtypes = [c_uint32, c_void_p]
IOKit.IOServiceGetMatchingServices.restype = c_int
IOKit.IOServiceGetMatchingServices.argtypes = [c_uint32, c_void_p, POINTER(c_uint32)]
IOKit.IOIteratorNext.restype = c_uint32
IOKit.IOIteratorNext.argtypes = [c_uint32]
IOKit.IOObjectRelease.restype = c_int
IOKit.IOObjectRelease.argtypes = [c_uint32]
IOKit.IORegistryEntryCreateCFProperty.restype = c_void_p
IOKit.IORegistryEntryCreateCFProperty.argtypes = [c_uint32, c_void_p, c_void_p, c_uint32]
IOKit.IORegistryEntryCreateCFProperties.restype = c_int
IOKit.IORegistryEntryCreateCFProperties.argtypes = [
    c_uint32,
    POINTER(c_void_p),
    c_void_p,
    c_uint32,
]
IOKit.IORegistryEntryGetChildIterator.restype = c_int
IOKit.IORegistryEntryGetChildIterator.argtypes = [c_uint32, c_char_p, POINTER(c_uint32)]
IOKit.IORegistryEntryGetName.restype = c_int
IOKit.IORegistryEntryGetName.argtypes = [c_uint32, c_char_p]


def matching_services(class_name: str):
    """Yield io_object_t handles for every service of a class. The caller must
    not retain them past the loop; they are released on the way out."""
    iterator = c_uint32(0)
    matching = IOKit.IOServiceMatching(class_name.encode())
    if not matching:
        return
    if IOKit.IOServiceGetMatchingServices(kIOMainPortDefault, matching, byref(iterator)) != 0:
        return
    try:
        while True:
            entry = IOKit.IOIteratorNext(iterator)
            if not entry:
                break
            try:
                yield entry
            finally:
                IOKit.IOObjectRelease(entry)
    finally:
        IOKit.IOObjectRelease(iterator)


def entry_property(entry: int, key: str) -> Any:
    ref = IOKit.IORegistryEntryCreateCFProperty(entry, cfstr(key), kCFAllocatorDefault, 0)
    if not ref:
        return None
    try:
        return to_python(ref)
    finally:
        release(ref)


def entry_properties(entry: int) -> dict[str, Any]:
    props = c_void_p()
    if IOKit.IORegistryEntryCreateCFProperties(entry, byref(props), kCFAllocatorDefault, 0) != 0:
        return {}
    try:
        return to_python(props.value) or {}
    finally:
        release(props.value)


def child_entries(entry: int, plane: bytes = b"IOService"):
    iterator = c_uint32(0)
    if IOKit.IORegistryEntryGetChildIterator(entry, plane, byref(iterator)) != 0:
        return
    try:
        while True:
            child = IOKit.IOIteratorNext(iterator)
            if not child:
                break
            try:
                yield child
            finally:
                IOKit.IOObjectRelease(child)
    finally:
        IOKit.IOObjectRelease(iterator)


# --- Metal (via objc_msgSend) ----------------------------------------------


def metal_device_info() -> dict[str, Any]:
    """Return the Metal device's name and its recommended working-set size.

    ``recommendedMaxWorkingSetSize`` is the number that actually matters for
    local LLMs: it is the amount of unified memory the GPU may hold before the
    system starts pushing allocations back to the CPU side.
    """
    try:
        objc = ctypes.CDLL(_OBJC_PATH)
        metal = ctypes.CDLL(_METAL_PATH)
    except OSError:
        return {}

    objc.sel_registerName.restype = c_void_p
    objc.sel_registerName.argtypes = [c_char_p]
    metal.MTLCreateSystemDefaultDevice.restype = c_void_p

    device = metal.MTLCreateSystemDefaultDevice()
    if not device:
        return {}

    def send(selector: str, restype):
        fn = objc.objc_msgSend
        fn.restype = restype
        fn.argtypes = [c_void_p, c_void_p]
        return fn(device, objc.sel_registerName(selector.encode()))

    info: dict[str, Any] = {}
    try:
        info["name"] = from_cfstring(send("name", c_void_p))
        info["recommended_max_working_set"] = int(send("recommendedMaxWorkingSetSize", c_uint64))
        info["has_unified_memory"] = bool(send("hasUnifiedMemory", c_bool))
    except Exception:
        return {}
    finally:
        fn = objc.objc_msgSend
        fn.restype = None
        fn.argtypes = [c_void_p, c_void_p]
        fn(device, objc.sel_registerName(b"release"))
    return info
