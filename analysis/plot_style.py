"""Shared figure styling helpers for analysis scripts.

When clean mode is enabled (--clean), decorative titles and commentary notes
are omitted.  Data value labels on the graph are always kept.
"""

from __future__ import annotations

CLEAN = False


def set_clean(enabled: bool = True) -> None:
    global CLEAN
    CLEAN = enabled


def is_clean() -> bool:
    return CLEAN


def suptitle(fig, text: str, *, clean: str | None = None, **kwargs) -> None:
    if CLEAN and clean is not None:
        fig.suptitle(clean, **kwargs)
    elif not CLEAN:
        fig.suptitle(text, **kwargs)


def title(ax, text: str, *, clean: str | None = None, **kwargs) -> None:
    ax.set_title(clean if CLEAN and clean is not None else text, **kwargs)


def note(ax, *args, **kwargs) -> None:
    """Decorative note — hidden in clean mode."""
    if not CLEAN:
        ax.text(*args, **kwargs)


def annotate(ax, *args, **kwargs) -> None:
    """Decorative annotation — hidden in clean mode."""
    if not CLEAN:
        ax.annotate(*args, **kwargs)


def label(ax, *args, **kwargs) -> None:
    """Data value label — always shown."""
    ax.text(*args, **kwargs)


def value_annotate(ax, *args, **kwargs) -> None:
    """Data value annotation — always shown."""
    ax.annotate(*args, **kwargs)
