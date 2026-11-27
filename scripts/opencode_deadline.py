"""Wall-clock budget for optional lookups on Linux CI runners."""

import signal
import threading
import time


def lookup_budget(seconds):
    """Calls require the main thread and exclusive use of the process real-time timer."""
    deadline = time.monotonic() + seconds

    def expired(*_):
        raise TimeoutError("Optional context deadline")

    def call(fetch, *args, **kwargs):
        if threading.current_thread() is not threading.main_thread() or any(signal.getitimer(signal.ITIMER_REAL)):
            raise RuntimeError("Optional lookups require the main thread and an unused ITIMER_REAL")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            expired()
        handler = signal.signal(signal.SIGALRM, expired)
        try:
            signal.setitimer(signal.ITIMER_REAL, remaining)
            return fetch(*args, **kwargs)
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, handler)

    return call
