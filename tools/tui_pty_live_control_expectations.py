from __future__ import annotations

from dataclasses import dataclass
from typing import Final


@dataclass(frozen=True, slots=True)
class Marker:
    marker_id: str
    ordered_fragments: tuple[str, ...]


REQUIRED_MARKERS: Final[tuple[Marker, ...]] = (
    Marker("stop_confirm", ("CONFIRM stop — press s again",)),
    Marker("stop_queued", ("ACTION queued stop_lab_run · target rollback id",)),
    Marker("stop_active", ("stop active · operator confirmed safe stop",)),
    Marker("stop_duplicate", ("REFUSED duplicate action id: tui-stop-active",)),
    Marker("help_overlay", ("HELP OVERLAY",)),
    Marker("help_close", ("HELP OVERLAY", "NORMAL", "▣ m live vm")),
    Marker("scrub_hint", ("cursor 4/4", "cursor 3/4")),
    Marker("scrub_forward", ("cursor 4/4",)),
    Marker("scrub_backward", ("cursor 3/4",)),
    Marker("rollback_confirm", ("CONFIRM rollback — press b again",)),
    Marker("rollback_queued", ("ACTION queued rollback_lab_run · target rollback id",)),
    Marker("rollback_active", ("rollback active · operator confirmed rollback",)),
    Marker("rollback_duplicate", ("REFUSED duplicate action id: tui-rollback-active",)),
    Marker("stop_stale", ("REFUSED stale action id: tui-stop-active",)),
    Marker("no_live_target", ("no live target",)),
)

HELP_CLOSE_SETTLE_SECONDS: Final[float] = 1.5
STOP_SESSION_MARKERS: Final[tuple[Marker, ...]] = REQUIRED_MARKERS[:9]
ROLLBACK_SESSION_MARKERS: Final[tuple[Marker, ...]] = REQUIRED_MARKERS[9:]


def has_marker(transcript: str, marker: Marker) -> bool:
    cursor = 0
    for fragment in marker.ordered_fragments:
        pos = transcript.find(fragment, cursor)
        if pos < 0:
            return False
        cursor = pos + len(fragment)
    return True


def missing_marker_ids(transcript: str) -> list[str]:
    return [marker.marker_id for marker in REQUIRED_MARKERS if not has_marker(transcript, marker)]


def has_all_markers(transcript: str, markers: tuple[Marker, ...]) -> bool:
    return all(has_marker(transcript, marker) for marker in markers)
