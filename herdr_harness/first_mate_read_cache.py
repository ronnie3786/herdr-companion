"""Bounded, single-flight caching for read-only First Mate assessments.

An entry is reusable only after the caller has freshly observed its evidence and
workspace identity. Mutation/gate decisions continue to compute independently.
"""
from __future__ import annotations

from collections import OrderedDict
from concurrent.futures import Future
from copy import deepcopy
import threading
import time
from typing import Callable, TypeVar


T = TypeVar("T")


class AssessmentReadCache:
    def __init__(self, *, ttl: float = 10.0, capacity: int = 64, clock=time.monotonic):
        self.ttl, self.capacity, self.clock = ttl, capacity, clock
        self._lock = threading.Lock()
        self._entries = OrderedDict()
        self._flights: dict[str, Future] = {}

    def get(self, feature_id: str, identity: Callable[[], str], compute: Callable[[], T]) -> T:
        # The whole probe/evaluation is one flight per feature. Waiters recheck
        # the inputs afterwards; a write during the flight cannot reuse it.
        while True:
            with self._lock:
                flight = self._flights.get(feature_id)
                if flight is None:
                    flight = self._flights[feature_id] = Future()
                    break
            # A failed probe or computation is shared by concurrent readers,
            # but is never retained for a later request.
            flight.result()
        error: BaseException | None = None
        try:
            key = identity()
            now = self.clock()
            with self._lock:
                entry = self._entries.get(feature_id)
                if entry and entry[0] == key and now - entry[1] < self.ttl:
                    self._entries.move_to_end(feature_id)
                    return deepcopy(entry[2])
            result = compute()
            # Do not retain an assessment across a change concurrent with its
            # computation. A subsequent request must assess the new inputs.
            if identity() == key:
                with self._lock:
                    self._entries[feature_id] = (key, self.clock(), deepcopy(result))
                    self._entries.move_to_end(feature_id)
                    while len(self._entries) > self.capacity:
                        self._entries.popitem(last=False)
            return result
        except BaseException as exc:
            error = exc
            raise
        finally:
            with self._lock:
                self._flights.pop(feature_id, None)
                if error is None:
                    flight.set_result(None)
                else:
                    flight.set_exception(error)
