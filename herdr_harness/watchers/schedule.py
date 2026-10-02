"""Bounded, timezone-aware next-fire search with no minute-by-minute scan.

Cron fields use Vixie semantics: a day field *starting* with a star uses AND
with the other day field, including */n. Otherwise the two day fields use OR.
Calendar dates and selected field values are searched, never elapsed minutes.
Local wall times are emitted once during overlaps. Fixed wall times missing
in a spring transition move to its first valid minute; interval ticks in the
gap are skipped. Intervals are aligned to local midnight, then filtered.
"""
from __future__ import annotations

from bisect import bisect_left
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone as dt_timezone
from functools import lru_cache
import os
from pathlib import Path
import re
from typing import Mapping
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .errors import WatchersError

UTC = dt_timezone.utc
SEARCH_YEARS = 8  # Includes leap-day gaps across non-leap century years.
MONTH_NAMES = {name: i for i, name in enumerate(("JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"), 1)}
WEEKDAY_NAMES = {name: i for i, name in enumerate(("SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"))}
DAYS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")


def _invalid(message: str):
    raise WatchersError("invalid_schedule", message)


def timezone_info(value: str) -> ZoneInfo:
    if not isinstance(value, str) or not value or len(value) > 200:
        raise WatchersError("invalid_timezone", "timezone must be an IANA timezone, such as America/Chicago")
    try:
        return ZoneInfo(value)
    except (ZoneInfoNotFoundError, ValueError):
        raise WatchersError("invalid_timezone", f"Unknown IANA timezone: {value}") from None


def machine_timezone(environ: Mapping[str, str] | None = None) -> str:
    """Use the operating system's zone, then TZ, then UTC, in that order."""
    try:
        target = str(Path("/etc/localtime").resolve())
        if "/zoneinfo/" in target:
            candidate = target.split("/zoneinfo/", 1)[1]
            timezone_info(candidate)
            return candidate
    except (OSError, WatchersError):
        pass
    candidate = (os.environ if environ is None else environ).get("TZ", "").removeprefix(":")
    try:
        timezone_info(candidate)
        return candidate
    except WatchersError:
        return "UTC"


def _aware(value: datetime) -> datetime:
    if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None:
        _invalid("Schedule calculations require a timezone-aware datetime")
    return value.astimezone(UTC)


def isoformat(value: datetime) -> str:
    return _aware(value).isoformat().replace("+00:00", "Z")


def parse_datetime(value: str, zone: str = "UTC") -> datetime:
    if not isinstance(value, str) or "T" not in value or len(value) > 100:
        _invalid("once.at must be an ISO date-time")
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        _invalid("once.at must be an ISO date-time")
    if result.tzinfo is None:
        return _resolve_wall(result, timezone_info(zone), gap_forward=True)
    return result.astimezone(UTC)


def _minutes(value, *, end=False) -> int:
    if not isinstance(value, str) or not re.fullmatch(r"\d{2}:\d{2}", value):
        _invalid("Times must use HH:MM")
    hour, minute = map(int, value.split(":"))
    if end and hour == 24 and minute == 0:
        return 1440
    if not 0 <= hour <= 23 or not 0 <= minute <= 59:
        _invalid("Times must be between 00:00 and 23:59 (24:00 is a window endpoint)")
    return hour * 60 + minute


def _days(value) -> tuple[int, ...]:
    if value == "all":
        return tuple(range(1, 8))
    if value == "weekdays":
        return (1, 2, 3, 4, 5)
    if isinstance(value, list) and value and all(type(day) is int and 1 <= day <= 7 for day in value) and len(value) == len(set(value)):
        return tuple(sorted(value))
    _invalid("days must be all, weekdays, or distinct ISO weekdays (1=Monday through 7=Sunday)")


@dataclass(frozen=True)
class CronField:
    values: tuple[int, ...]
    star: bool

    @classmethod
    def parse(cls, text: str, low: int, high: int, label: str, aliases=None, sunday=False):
        aliases = aliases or {}
        text = text.upper()
        values = set()

        def number(source):
            if source in aliases:
                value = aliases[source]
            elif re.fullmatch(r"\d+", source):
                value = int(source)
            else:
                _invalid(f"Invalid {label} value: {source}")
            if not low <= value <= high:
                _invalid(f"{label} must be between {low} and {high}")
            return value

        for part in text.split(","):
            pieces = part.split("/")
            if len(pieces) > 2 or not pieces[0]:
                _invalid(f"Invalid {label} field")
            step = 1
            if len(pieces) == 2:
                if not re.fullmatch(r"\d+", pieces[1]) or int(pieces[1]) <= 0:
                    _invalid(f"{label} step must be positive")
                step = int(pieces[1])
            if pieces[0] == "*":
                start, end = low, high
            else:
                bounds = pieces[0].split("-")
                if len(bounds) > 2:
                    _invalid(f"Invalid {label} range")
                start = number(bounds[0])
                end = number(bounds[1]) if len(bounds) == 2 else start
                if end < start:
                    _invalid(f"{label} range must be ascending")
            values.update((0 if sunday and n == 7 else n) for n in range(start, end + 1, step))
        if not values:
            _invalid(f"{label} has no values")
        return cls(tuple(sorted(values)), text.startswith("*"))


class CronExpression:
    """Parsed five-field cron expression; compatible with Cronboard's syntax."""

    def __init__(self, expression: str):
        if not isinstance(expression, str) or len(expression) > 512:
            _invalid("cron.expression must be a five-field expression")
        fields = expression.split()
        if len(fields) != 5:
            _invalid("Expected five cron fields: minute hour day-of-month month day-of-week")
        self.expression = " ".join(fields)
        self.minute = CronField.parse(fields[0], 0, 59, "minute")
        self.hour = CronField.parse(fields[1], 0, 23, "hour")
        self.day = CronField.parse(fields[2], 1, 31, "day of month")
        self.month = CronField.parse(fields[3], 1, 12, "month", MONTH_NAMES)
        self.weekday = CronField.parse(fields[4], 0, 7, "day of week", WEEKDAY_NAMES, sunday=True)

    def date_matches(self, value: date) -> bool:
        dom = value.day in self.day.values
        dow = value.isoweekday() % 7 in self.weekday.values
        day_matches = dom and dow if self.day.star or self.weekday.star else dom or dow
        return value.month in self.month.values and day_matches

    def matches(self, value: datetime, timezone: str = "UTC") -> bool:
        value = _aware(value).astimezone(timezone_info(timezone))
        return self.date_matches(value.date()) and value.hour in self.hour.values and value.minute in self.minute.values

    def next_dates(self, after: datetime, count: int = 5, timezone: str = "UTC") -> list[datetime]:
        results = []
        for _ in range(max(0, min(count, 100))):
            result = next_fire({"kind": "cron", "expression": self.expression}, timezone, after)
            if result is None:
                break
            results.append(result)
            after = result
        return results


@lru_cache(maxsize=256)
def _cron(expression: str) -> CronExpression:
    return CronExpression(expression)


def validate_schedule(schedule: dict, timezone: str = "UTC") -> dict:
    timezone_info(timezone)
    if not isinstance(schedule, dict):
        _invalid("schedule must be an object")
    kind = schedule.get("kind")
    keys = {"interval": {"every_minutes", "days", "window"}, "daily": {"at", "days"}, "cron": {"expression"}, "once": {"at"}}
    if not isinstance(kind, str) or kind not in keys:
        _invalid("schedule.kind must be interval, daily, cron, or once")
    unknown = set(schedule) - keys[kind] - {"kind", "summary"}
    if unknown:
        _invalid(f"Unknown {kind} schedule fields: {', '.join(sorted(unknown))}")
    result = {key: value for key, value in schedule.items() if key != "summary"}
    if kind in ("interval", "daily"):
        days = result.setdefault("days", "all")
        _days(days)
        if isinstance(days, list):
            result["days"] = sorted(days)
    if kind == "interval":
        every = result.get("every_minutes")
        if type(every) is not int or not 1 <= every <= 1440:
            _invalid("every_minutes must be an integer from 1 through 1440")
        if "window" in result:
            window = result["window"]
            if not isinstance(window, list) or len(window) != 2:
                _invalid("window must contain a start and end time")
            start, end = _minutes(window[0]), _minutes(window[1], end=True)
            if start >= end:
                _invalid("window must be ascending and half-open; split overnight windows into two watchers")
    elif kind == "daily":
        _minutes(result.get("at"))
    elif kind == "cron":
        expression = result.get("expression")
        if not isinstance(expression, str):
            _invalid("cron.expression must be a five-field expression")
        result["expression"] = _cron(expression).expression
    else:
        result["at"] = isoformat(parse_datetime(result.get("at"), timezone))
    result["summary"] = schedule_summary(result, timezone)
    return result


def _valid_wall(wall: datetime, zone: ZoneInfo) -> list[datetime]:
    values = set()
    for fold in (0, 1):
        candidate = wall.replace(tzinfo=zone, fold=fold).astimezone(UTC)
        if candidate.astimezone(zone).replace(tzinfo=None) == wall:
            values.add(candidate)
    return sorted(values)


def _resolve_wall(wall: datetime, zone: ZoneInfo, *, gap_forward: bool) -> datetime | None:
    valid = _valid_wall(wall, zone)
    if valid:
        return valid[0]  # One fire for ambiguous local times, always the first fold.
    if not gap_forward:
        return None
    # ZoneInfo round-trips a missing time to the far side of its gap. Find the
    # boundary by binary search in wall minutes, including non-hour transitions.
    future = [wall.replace(tzinfo=zone, fold=fold).astimezone(UTC).astimezone(zone).replace(tzinfo=None) for fold in (0, 1)]
    upper = min(value for value in future if value > wall)
    base = wall.replace(second=0, microsecond=0)
    lo, hi = 0, max(1, int((upper - base).total_seconds() // 60) + 1)
    while lo < hi:
        mid = (lo + hi) // 2
        if _valid_wall(base + timedelta(minutes=mid), zone):
            hi = mid
        else:
            lo = mid + 1
    return _valid_wall(base + timedelta(minutes=lo), zone)[0]


def _next_month(day: date, months: tuple[int, ...]) -> date | None:
    index = bisect_left(months, day.month)
    if index < len(months):
        month, year = months[index], day.year
    else:
        month, year = months[0], day.year + 1
    if year > 9999:
        return None
    return day if month == day.month and year == day.year else date(year, month, 1)


def next_fire(schedule: dict, timezone: str, after: datetime) -> datetime | None:
    """Return the first strictly future UTC fire, or None within eight years."""
    schedule = validate_schedule(schedule, timezone)
    after = _aware(after)
    zone = timezone_info(timezone)
    kind = schedule["kind"]
    if kind == "once":
        candidate = parse_datetime(schedule["at"], timezone)
        return candidate if candidate > after else None
    local = after.astimezone(zone)
    day = local.date()
    end_year = min(9999, day.year + SEARCH_YEARS)
    try:
        limit = date(end_year, day.month, day.day)
    except ValueError:
        limit = date(end_year, day.month, 28)
    cron = _cron(schedule["expression"]) if kind == "cron" else None
    if cron:
        times = tuple(hour * 60 + minute for hour in cron.hour.values for minute in cron.minute.values)
    elif kind == "daily":
        times = (_minutes(schedule["at"]),)
    else:
        start, end = (0, 1440) if "window" not in schedule else (_minutes(schedule["window"][0]), _minutes(schedule["window"][1], end=True))
        every = schedule["every_minutes"]
        times = tuple(range(((start + every - 1) // every) * every, end, every))
    if not times:
        return None
    allowed_days = _days(schedule.get("days", "all"))
    while day <= limit:
        if cron:
            day = _next_month(day, cron.month.values)
            if day is None or day > limit:
                return None
            matches = cron.date_matches(day)
        else:
            matches = day.isoweekday() in allowed_days
        if matches:
            floor = local.hour * 60 + local.minute if day == local.date() else 0
            for minute in times[bisect_left(times, floor):]:
                wall = datetime(day.year, day.month, day.day) + timedelta(minutes=minute)
                candidate = _resolve_wall(wall, zone, gap_forward=kind != "interval")
                if candidate is not None and candidate > after:
                    return candidate
        if day == date.max:
            break
        day += timedelta(days=1)
    return None


def _time_label(minutes: int, *, short=False) -> str:
    hour, minute = divmod(minutes % 1440, 60)
    suffix = "AM" if hour < 12 else "PM"
    return f"{hour % 12 or 12}{'' if short and minute == 0 else ':' + str(minute).zfill(2)} {suffix}"


def _days_label(days) -> str:
    if days == "weekdays":
        return "weekdays"
    if isinstance(days, list):
        return " and ".join(DAYS[value - 1] + "s" for value in days)
    return "every day"


def schedule_summary(schedule: dict, timezone: str, now: datetime | None = None) -> str:
    """Design cadence phrase, lowercase at its start and without a final period."""
    kind = schedule.get("kind")
    if kind == "interval":
        every = schedule["every_minutes"]
        base = "every minute" if every == 1 else f"every {every} min" if every < 60 or every % 60 else "every hour" if every == 60 else f"every {every // 60} hours"
        days = schedule.get("days", "all")
        if days == "weekdays":
            base += ", weekdays"
        elif isinstance(days, list):
            base += ", " + ", ".join(DAYS[value - 1][:3] for value in days)
        if "window" in schedule:
            start, end = schedule["window"]
            base += f" {_time_label(_minutes(start), short=True)}–{_time_label(_minutes(end, end=True), short=True)}"
        return base
    if kind == "daily":
        minute = _minutes(schedule["at"])
        days = schedule.get("days", "all")
        prefix = "every night" if days == "all" and (minute < 300 or minute >= 1260) else _days_label(days)
        return f"{prefix} at {_time_label(minute)}"
    if kind == "once":
        zone = timezone_info(timezone)
        at = parse_datetime(schedule["at"], timezone).astimezone(zone)
        today = (now or datetime.now(UTC)).astimezone(zone).date()
        label = "today" if at.date() == today else "tomorrow" if at.date() == today + timedelta(days=1) else at.strftime("%B") + f" {at.day}, {at.year}"
        return f"{label} at {_time_label(at.hour * 60 + at.minute)}"
    if kind == "cron":
        cron = _cron(schedule["expression"])
        minute, hour, day, month, weekday = cron.expression.split()
        if day == month == weekday == "*" and hour == "*":
            if minute == "*":
                return "every minute"
            if minute.startswith("*/") and len(cron.minute.values) > 1:
                return f"every {minute[2:]} min"
            if minute == "0":
                return "every hour"
        if len(cron.minute.values) == len(cron.hour.values) == 1 and day == month == "*":
            days = "all" if weekday == "*" else "weekdays" if set(cron.weekday.values) == {1, 2, 3, 4, 5} else sorted(value or 7 for value in cron.weekday.values)
            return schedule_summary({"kind": "daily", "at": f"{cron.hour.values[0]:02}:{cron.minute.values[0]:02}", "days": days}, timezone, now)
        return "on a custom schedule"
    _invalid("Unknown schedule kind")


def preview(schedule: dict, timezone: str, count: int = 5, after: datetime | None = None) -> dict:
    if type(count) is not int or not 0 <= count <= 100:
        _invalid("preview count must be from 0 through 100")
    normalized = validate_schedule(schedule, timezone)
    cursor = after or datetime.now(UTC)
    results = []
    for _ in range(count):
        cursor = next_fire(normalized, timezone, cursor)
        if cursor is None:
            break
        results.append(isoformat(cursor))
    return {"summary": schedule_summary(normalized, timezone, after), "next": results, "timezone": timezone}


def schedule_period_seconds(schedule: dict, timezone: str = "UTC", after: datetime | None = None) -> float:
    kind = schedule.get("kind")
    if kind == "interval":
        return schedule["every_minutes"] * 60
    if kind in ("daily", "once"):
        return 86400
    first = next_fire(schedule, timezone, after or datetime(2024, 1, 1, tzinfo=UTC))
    second = next_fire(schedule, timezone, first) if first else None
    return (second - first).total_seconds() if second else 86400


def default_missed_runs(schedule: dict) -> str:
    return "skip" if schedule_period_seconds(schedule) <= 3600 else "run_once"


def missed_run_trigger(schedule: dict, timezone: str, *, fire_at: datetime, last_tick_at: datetime, now: datetime, missed_runs: str) -> str | None:
    """Classify a due fire after a scheduler gap, without replaying a backlog."""
    fire_at, last_tick_at, now = map(_aware, (fire_at, last_tick_at, now))
    if fire_at > now:
        return None
    period = min(600, schedule_period_seconds(schedule, timezone, fire_at - timedelta(microseconds=1)))
    if (now - last_tick_at).total_seconds() < period:
        return "scheduled"
    return "catch_up" if missed_runs == "run_once" else None
