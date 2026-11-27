"""Wall-clock budget for optional lookups on Linux CI runners."""

import signal
import time


def lookup_budget(seconds):
    deadline = time.monotonic() + seconds

    def expired(*_):
        raise TimeoutError("Optional context deadline")

    def call(fetch, *args, **kwargs):
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
