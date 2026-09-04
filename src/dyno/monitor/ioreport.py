"""Thin wrapper around /usr/lib/libIOReport.dylib.

IOReport is the same telemetry pipe ``powermetrics`` drinks from, but reading it
directly needs no elevated privileges. A subscription accumulates counters; a
delta between two samples gives energy consumed and time spent in each power
state over the interval.
"""

from __future__ import annotations

import ctypes
import time
from concurrent.futures import ThreadPoolExecutor
from ctypes import POINTER, byref, c_int, c_int64, c_uint64, c_void_p
from dataclasses import dataclass
from typing import Callable, Iterator

from .cf import CF, cfstr, from_cfstring, release

IOReport = ctypes.CDLL("/usr/lib/libIOReport.dylib")

IOReport.IOReportCopyChannelsInGroup.restype = c_void_p
IOReport.IOReportCopyChannelsInGroup.argtypes = [c_void_p, c_void_p, c_uint64, c_uint64, c_uint64]
IOReport.IOReportMergeChannels.restype = None
IOReport.IOReportMergeChannels.argtypes = [c_void_p, c_void_p, c_void_p]
IOReport.IOReportCreateSubscription.restype = c_void_p
IOReport.IOReportCreateSubscription.argtypes = [
    c_void_p,
    c_void_p,
    POINTER(c_void_p),
    c_uint64,
    c_void_p,
]
IOReport.IOReportCreateSamples.restype = c_void_p
IOReport.IOReportCreateSamples.argtypes = [c_void_p, c_void_p, c_void_p]
IOReport.IOReportCreateSamplesDelta.restype = c_void_p
IOReport.IOReportCreateSamplesDelta.argtypes = [c_void_p, c_void_p, c_void_p]

for _name in (
    "IOReportChannelGetGroup",
    "IOReportChannelGetSubGroup",
    "IOReportChannelGetChannelName",
    "IOReportChannelGetUnitLabel",
    "IOReportStateGetNameForIndex",
):
    getattr(IOReport, _name).restype = c_void_p
IOReport.IOReportChannelGetGroup.argtypes = [c_void_p]
IOReport.IOReportChannelGetSubGroup.argtypes = [c_void_p]
IOReport.IOReportChannelGetChannelName.argtypes = [c_void_p]
IOReport.IOReportChannelGetUnitLabel.argtypes = [c_void_p]
IOReport.IOReportChannelGetFormat.restype = c_int
IOReport.IOReportChannelGetFormat.argtypes = [c_void_p]
IOReport.IOReportSimpleGetIntegerValue.restype = c_int64
IOReport.IOReportSimpleGetIntegerValue.argtypes = [c_void_p, c_int]
IOReport.IOReportStateGetCount.restype = c_int
IOReport.IOReportStateGetCount.argtypes = [c_void_p]
IOReport.IOReportStateGetNameForIndex.argtypes = [c_void_p, c_int]
IOReport.IOReportStateGetResidency.restype = c_int64
IOReport.IOReportStateGetResidency.argtypes = [c_void_p, c_int]

FORMAT_SIMPLE = 1
FORMAT_STATE = 2

# Energy channels report in different units depending on the SoC generation.
_ENERGY_SCALE_TO_JOULES = {"nJ": 1e-9, "uJ": 1e-6, "mJ": 1e-3, "J": 1.0}


@dataclass(frozen=True)
class Channel:
    """One decoded IOReport channel from a sample delta."""

    group: str
    subgroup: str | None
    name: str
    unit: str
    format: int
    value: int | None = None
    states: tuple[tuple[str, int], ...] = ()

    def energy_joules(self) -> float | None:
        scale = _ENERGY_SCALE_TO_JOULES.get(self.unit)
        if scale is None or self.value is None:
            return None
        return self.value * scale


class IOReportError(RuntimeError):
    pass


class Subscription:
    """A live subscription to a set of IOReport groups."""

    def __init__(self, groups: list[tuple[str, str | None]]):
        # Each IOReportCopyChannelsInGroup call walks the whole registry and
        # costs ~200 ms whether or not the group exists. The calls are
        # independent and release the GIL, so fetch them concurrently rather
        # than paying that cost once per group at startup.
        def fetch(entry: tuple[str, str | None]) -> int:
            group, subgroup = entry
            return IOReport.IOReportCopyChannelsInGroup(
                cfstr(group), cfstr(subgroup) if subgroup else None, 0, 0, 0
            )

        if len(groups) > 1:
            with ThreadPoolExecutor(max_workers=len(groups)) as pool:
                fetched = list(pool.map(fetch, groups))
        else:
            fetched = [fetch(groups[0])] if groups else []

        merged: int | None = None
        for channels in fetched:
            if not channels:
                continue
            if merged is None:
                merged = channels
            else:
                IOReport.IOReportMergeChannels(merged, channels, None)
                release(channels)
        if merged is None:
            raise IOReportError("no IOReport channels matched the requested groups")

        self._channels = merged
        subscribed = c_void_p()
        self._subscription = IOReport.IOReportCreateSubscription(
            None, merged, byref(subscribed), 0, None
        )
        if not self._subscription:
            raise IOReportError("IOReportCreateSubscription failed")
        self._subscribed = subscribed
        self._previous = IOReport.IOReportCreateSamples(
            self._subscription, self._subscribed, None
        )
        self._previous_at = time.monotonic()

    def has_subgroup(self, subgroup: str) -> bool:
        """Whether the subscription covers a subgroup, without taking a sample.

        Sampling to find out would reset the delta baseline and leave the next
        real sample with a zero-length window.
        """
        array = CF.CFDictionaryGetValue(self._channels, cfstr("IOReportChannels"))
        if not array:
            return False
        for index in range(CF.CFArrayGetCount(array)):
            item = CF.CFArrayGetValueAtIndex(array, index)
            if from_cfstring(IOReport.IOReportChannelGetSubGroup(item)) == subgroup:
                return True
        return False

    def sample(self, keep: "Callable[[str, str | None, str], bool] | None" = None
               ) -> tuple[list[Channel], float]:
        """Return the channels changed since the previous call, plus elapsed
        seconds. The first call after construction measures from init time.

        ``keep`` filters channels by (group, subgroup, name) before their state
        arrays are decoded, which matters: a bandwidth subgroup alone carries
        seventy channels of thirty-two states each.
        """
        current = IOReport.IOReportCreateSamples(self._subscription, self._subscribed, None)
        now = time.monotonic()
        elapsed = now - self._previous_at
        delta = IOReport.IOReportCreateSamplesDelta(self._previous, current, None)
        release(self._previous)
        self._previous = current
        self._previous_at = now
        try:
            return list(_decode(delta, keep)), elapsed
        finally:
            release(delta)

    def close(self) -> None:
        release(self._previous)
        self._previous = None
        release(self._subscription)
        self._subscription = None
        release(self._subscribed.value if self._subscribed else None)
        self._subscribed = None
        release(self._channels)
        self._channels = None

    def __enter__(self) -> "Subscription":
        return self

    def __exit__(self, *_exc) -> None:
        self.close()


def _decode(
    delta: int | None, keep: "Callable[[str, str | None, str], bool] | None" = None
) -> Iterator[Channel]:
    if not delta:
        return
    array = CF.CFDictionaryGetValue(delta, cfstr("IOReportChannels"))
    if not array:
        return
    for index in range(CF.CFArrayGetCount(array)):
        item = CF.CFArrayGetValueAtIndex(array, index)
        fmt = IOReport.IOReportChannelGetFormat(item)
        group = from_cfstring(IOReport.IOReportChannelGetGroup(item)) or ""
        subgroup = from_cfstring(IOReport.IOReportChannelGetSubGroup(item))
        name = from_cfstring(IOReport.IOReportChannelGetChannelName(item)) or ""
        if keep is not None and not keep(group, subgroup, name):
            continue
        unit = (from_cfstring(IOReport.IOReportChannelGetUnitLabel(item)) or "").strip()
        if fmt == FORMAT_SIMPLE:
            yield Channel(
                group, subgroup, name, unit, fmt,
                value=IOReport.IOReportSimpleGetIntegerValue(item, 0),
            )
        elif fmt == FORMAT_STATE:
            count = IOReport.IOReportStateGetCount(item)
            states = tuple(
                (
                    (from_cfstring(IOReport.IOReportStateGetNameForIndex(item, i)) or "").strip(),
                    IOReport.IOReportStateGetResidency(item, i),
                )
                for i in range(count)
            )
            yield Channel(group, subgroup, name, unit, fmt, states=states)
