"""Golden Cronboard vectors plus Watchers timezone and missed-run behavior."""
from datetime import datetime, timedelta, timezone
import unittest
from unittest.mock import patch

from herdr_harness.watchers.errors import WatchersError
from herdr_harness.watchers.schedule import (
    CronExpression, default_missed_runs, machine_timezone, missed_run_trigger,
    next_fire, preview, schedule_summary, validate_schedule,
)


def dt(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def cron(expression):
    return {"kind": "cron", "expression": expression}


class WatchersScheduleTests(unittest.TestCase):
    def test_cronboard_common_schedules_and_validation(self):
        self.assertEqual(schedule_summary(cron("*/15 * * * *"), "UTC"), "every 15 min")
        self.assertEqual(schedule_summary(cron("0 9 * * 1-5"), "UTC"), "weekdays at 9:00 AM")
        self.assertEqual(schedule_summary(cron("30 18 * * *"), "UTC"), "every day at 6:30 PM")
        for expression in ("70 9 * * *", "0 9 * *"):
            with self.subTest(expression=expression), self.assertRaises(WatchersError):
                CronExpression(expression)

    def test_cronboard_future_weekdays(self):
        self.assertEqual(
            CronExpression("0 9 * * 1-5").next_dates(dt("2026-07-24T09:01:00Z"), count=2),
            [dt("2026-07-27T09:00:00Z"), dt("2026-07-28T09:00:00Z")],
        )

    def test_cronboard_names_ranges_lists_steps(self):
        expression = CronExpression("0,30 8-10/2 * JAN,MAR MON-FRI")
        self.assertTrue(expression.matches(dt("2026-03-02T10:30:00Z")))
        self.assertFalse(expression.matches(dt("2026-03-02T09:30:00Z")))
        self.assertEqual(expression.next_dates(dt("2026-02-28T10:30:00Z"), 1), [dt("2026-03-02T08:00:00Z")])

    def test_cronboard_chicago_seasonal_offsets(self):
        for start, expected in (("2026-09-06T09:30:00Z", "2026-09-06T14:33:00Z"), ("2026-12-06T09:30:00Z", "2026-12-06T15:33:00Z")):
            with self.subTest(start=start):
                self.assertEqual(next_fire(cron("33 9 * * *"), "America/Chicago", dt(start)), dt(expected))
                self.assertEqual(next_fire(cron("36 9 * * *"), "America/Chicago", dt(start)), dt(expected) + timedelta(minutes=3))

    def test_vixie_star_step_uses_and_for_day_fields(self):
        schedule = cron("0 9 */2 * MON")
        self.assertEqual(next_fire(schedule, "UTC", dt("2026-03-01T10:00:00Z")), dt("2026-03-09T09:00:00Z"))
        self.assertFalse(CronExpression("0 9 */2 * MON").matches(dt("2026-03-02T09:00:00Z")))
        self.assertFalse(CronExpression("0 9 2 * */2").matches(dt("2026-03-02T09:00:00Z")))

    def test_vixie_restricted_days_use_or(self):
        expression = CronExpression("0 9 3 * MON")
        self.assertTrue(expression.matches(dt("2026-03-02T09:00:00Z")))
        self.assertTrue(expression.matches(dt("2026-03-03T09:00:00Z")))
        self.assertFalse(expression.matches(dt("2026-03-04T09:00:00Z")))

    def test_star_flag_depends_on_field_prefix(self):
        self.assertTrue(CronExpression("0 9 *,2 * MON").day.star)
        self.assertFalse(CronExpression("0 9 2,* * MON").day.star)

    def test_sunday_zero_seven_and_names_agree(self):
        start = dt("2026-03-02T00:00:00Z")
        for expression in ("0 9 * * 0", "0 9 * * 7", "0 9 * * sun"):
            self.assertEqual(next_fire(cron(expression), "UTC", start), dt("2026-03-08T09:00:00Z"))

    def test_month_end_and_leap_years(self):
        self.assertEqual(next_fire(cron("0 0 31 * *"), "UTC", dt("2026-04-01T00:00:00Z")), dt("2026-05-31T00:00:00Z"))
        self.assertEqual(next_fire(cron("0 0 29 FEB *"), "UTC", dt("2096-02-29T00:00:00Z")), dt("2104-02-29T00:00:00Z"))

    def test_impossible_cron_is_bounded_without_resolving_minutes(self):
        with patch("herdr_harness.watchers.schedule._resolve_wall") as resolve:
            self.assertIsNone(next_fire(cron("* * 31 FEB *"), "UTC", dt("2026-01-01T00:00:00Z")))
            resolve.assert_not_called()

    def test_sparse_search_jumps_directly_to_matching_time(self):
        from herdr_harness.watchers.schedule import _resolve_wall
        with patch("herdr_harness.watchers.schedule._resolve_wall", wraps=_resolve_wall) as resolve:
            self.assertEqual(next_fire(cron("0 0 1 JAN *"), "UTC", dt("2026-01-02T00:00:00Z")), dt("2027-01-01T00:00:00Z"))
            self.assertEqual(resolve.call_count, 1)

    def test_dst_gap_moves_fixed_time_to_first_valid_minute(self):
        after = dt("2026-03-08T07:50:00Z")  # Chicago 01:50, ten minutes before gap.
        for schedule in (cron("30 2 * * *"), {"kind": "daily", "at": "02:30"}):
            with self.subTest(schedule=schedule):
                self.assertEqual(next_fire(schedule, "America/Chicago", after), dt("2026-03-08T08:00:00Z"))
                self.assertEqual(next_fire(schedule, "America/Chicago", dt("2026-03-08T08:00:00Z")), dt("2026-03-09T07:30:00Z"))

    def test_non_hour_dst_gap(self):
        self.assertEqual(next_fire({"kind": "daily", "at": "02:15"}, "Australia/Lord_Howe", dt("2026-10-03T15:00:00Z")), dt("2026-10-03T15:30:00Z"))

    def test_dst_overlap_emits_only_first_fold(self):
        schedule = {"kind": "daily", "at": "01:30"}
        first = next_fire(schedule, "America/Chicago", dt("2026-11-01T05:00:00Z"))
        self.assertEqual(first, dt("2026-11-01T06:30:00Z"))
        self.assertEqual(next_fire(schedule, "America/Chicago", first), dt("2026-11-02T07:30:00Z"))
        self.assertEqual(next_fire(schedule, "America/Chicago", dt("2026-11-01T07:10:00Z")), dt("2026-11-02T07:30:00Z"))

    def test_interval_alignment_days_half_open_window(self):
        schedule = {"kind": "interval", "every_minutes": 60, "days": "weekdays", "window": ["08:15", "10:00"]}
        self.assertEqual(next_fire(schedule, "UTC", dt("2026-10-02T08:14:00Z")), dt("2026-10-02T09:00:00Z"))
        self.assertEqual(next_fire(schedule, "UTC", dt("2026-10-02T09:00:00Z")), dt("2026-10-05T09:00:00Z"))
        self.assertIsNone(next_fire({**schedule, "window": ["08:15", "08:30"]}, "UTC", dt("2026-10-02T00:00:00Z")))

    def test_daily_iso_weekdays(self):
        schedule = {"kind": "daily", "at": "07:00", "days": [7]}
        self.assertEqual(next_fire(schedule, "UTC", dt("2026-10-02T00:00:00Z")), dt("2026-10-04T07:00:00Z"))

    def test_interval_dst_gap_skips_missing_ticks(self):
        schedule = {"kind": "interval", "every_minutes": 45}
        self.assertEqual(next_fire(schedule, "America/Chicago", dt("2026-03-08T07:50:00Z")), dt("2026-03-08T08:00:00Z"))

    def test_interval_dst_overlap_never_repeats_a_wall_tick(self):
        schedule = {"kind": "interval", "every_minutes": 30}
        self.assertEqual(next_fire(schedule, "America/Chicago", dt("2026-11-01T06:30:00Z")), dt("2026-11-01T08:00:00Z"))

    def test_once_absolute_and_local_datetime(self):
        after = dt("2026-10-01T00:00:00Z")
        self.assertEqual(next_fire({"kind": "once", "at": "2026-10-02T09:00:00-05:00"}, "America/Chicago", after), dt("2026-10-02T14:00:00Z"))
        self.assertEqual(next_fire({"kind": "once", "at": "2026-10-02T09:00:00"}, "America/Chicago", after), dt("2026-10-02T14:00:00Z"))
        self.assertIsNone(next_fire({"kind": "once", "at": "2026-10-01T00:00:00Z"}, "UTC", after))

    def test_preview_keeps_raw_cron_and_exact_count(self):
        schedule = cron("0 9 1 JAN *")
        result = preview(schedule, "UTC", count=3, after=dt("2026-01-02T00:00:00Z"))
        self.assertEqual(result["summary"], "on a custom schedule")
        self.assertEqual(len(result["next"]), 3)
        self.assertEqual(validate_schedule(schedule)["expression"], "0 9 1 JAN *")

    def test_once_summary_uses_watcher_date(self):
        self.assertEqual(schedule_summary({"kind": "once", "at": "2026-10-02T20:00:00Z"}, "America/Chicago", dt("2026-10-02T12:00:00Z")), "today at 3:00 PM")

    def test_defaults_and_missed_run_computation(self):
        self.assertEqual(default_missed_runs({"kind": "interval", "every_minutes": 60}), "skip")
        self.assertEqual(default_missed_runs({"kind": "interval", "every_minutes": 120}), "run_once")
        self.assertEqual(default_missed_runs({"kind": "daily", "at": "09:00"}), "run_once")
        self.assertEqual(default_missed_runs(cron("*/5 * * * *")), "skip")
        self.assertEqual(default_missed_runs(cron("0 9 * * MON")), "run_once")
        schedule = {"kind": "interval", "every_minutes": 5}
        fire = dt("2026-10-02T10:05:00Z")
        values = dict(schedule=schedule, timezone="UTC", fire_at=fire, last_tick_at=fire - timedelta(seconds=20))
        self.assertEqual(missed_run_trigger(**values, now=fire + timedelta(seconds=20), missed_runs="skip"), "scheduled")
        self.assertIsNone(missed_run_trigger(**values, now=fire + timedelta(minutes=6), missed_runs="skip"))
        self.assertEqual(missed_run_trigger(**values, now=fire + timedelta(minutes=6), missed_runs="run_once"), "catch_up")
        self.assertIsNone(missed_run_trigger(**values, now=fire - timedelta(seconds=1), missed_runs="run_once"))

    def test_machine_timezone_precedence(self):
        with patch("herdr_harness.watchers.schedule.Path.resolve", return_value="/usr/share/zoneinfo/Europe/London"):
            self.assertEqual(machine_timezone({"TZ": "America/Chicago"}), "Europe/London")
        with patch("herdr_harness.watchers.schedule.Path.resolve", return_value="/etc/localtime"):
            self.assertEqual(machine_timezone({"TZ": "America/Chicago"}), "America/Chicago")
            self.assertEqual(machine_timezone({"TZ": "No/SuchZone"}), "UTC")

    def test_invalid_schedules_return_domain_errors(self):
        values = [None, {}, {"kind": []}, {"kind": "daily", "at": "25:00"}, {"kind": "daily", "at": "07:00", "days": [0]}, {"kind": "daily", "at": "07:00", "days": [True]}, {"kind": "interval", "every_minutes": True}, {"kind": "interval", "every_minutes": 1441}, {"kind": "interval", "every_minutes": 15, "window": ["18:00", "08:00"]}, {"kind": "once", "at": "2026-10-02"}, {"kind": "cron", "expression": {}}, cron("*/0 * * * *"), cron("0 9 * * FRI-MON"), cron("0,,5 9 * * *")]
        for value in values:
            with self.subTest(value=value), self.assertRaises(WatchersError):
                validate_schedule(value)
        with self.assertRaises(WatchersError):
            next_fire(cron("* * * * *"), "UTC", datetime(2026, 10, 2))


if __name__ == "__main__":
    unittest.main()
