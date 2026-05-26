"""Shared ANSI color utilities for Hermes CLI modules."""

import os
import sys


def _windows_vt_supported() -> bool:
    """Return True if the Windows console has VT processing active.

    Called only on win32; checks ENABLE_VIRTUAL_TERMINAL_PROCESSING on the
    stdout handle.  If the handle isn't a real console (redirected/piped)
    this returns False, which is correct — piped output shouldn't carry
    colour codes either.
    """
    try:
        import ctypes
        import ctypes.wintypes

        kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
        h_out = kernel32.GetStdHandle(-11)  # STD_OUTPUT_HANDLE
        if h_out == ctypes.wintypes.HANDLE(-1).value:
            return False
        mode = ctypes.wintypes.DWORD(0)
        if not kernel32.GetConsoleMode(h_out, ctypes.byref(mode)):
            return False
        return bool(mode.value & 0x0004)  # ENABLE_VIRTUAL_TERMINAL_PROCESSING
    except Exception:
        return False


def should_use_color() -> bool:
    """Return True when colored output is appropriate.

    Respects the NO_COLOR environment variable (https://no-color.org/)
    and TERM=dumb, in addition to the existing TTY check.
    On Windows, also verifies that VT (ANSI) processing is enabled on the
    console handle so that raw escape sequences are not printed as literals.
    """
    if os.environ.get("NO_COLOR") is not None:
        return False
    if os.environ.get("TERM") == "dumb":
        return False
    if not sys.stdout.isatty():
        return False
    if sys.platform == "win32" and not _windows_vt_supported():
        return False
    return True


class Colors:
    RESET = "\033[0m"
    BOLD = "\033[1m"
    DIM = "\033[2m"
    RED = "\033[31m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    BLUE = "\033[34m"
    MAGENTA = "\033[35m"
    CYAN = "\033[36m"


def color(text: str, *codes) -> str:
    """Apply color codes to text (only when color output is appropriate)."""
    if not should_use_color():
        return text
    return "".join(codes) + text + Colors.RESET
