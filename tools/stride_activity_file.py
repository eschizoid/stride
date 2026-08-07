#!/usr/bin/env python3
"""Decode one FIT/FIT.GZ/GPX member from a Strava export.

Standard library only. The caller validates the member name too; this helper repeats
that check because account exports are untrusted input. It never extracts the archive.
"""

from __future__ import annotations

import datetime as dt
import gzip
import io
import json
import math
from pathlib import Path, PurePosixPath
import sqlite3
import struct
import sys
import zipfile

MAX_ACTIVITY_BYTES = 64 * 1024 * 1024
WANTED_FIELDS = {2, 3, 5, 7, 78, 253}


def safe_member(name: str) -> bool:
    path = PurePosixPath(name)
    lower = name.lower()
    return (
        not path.is_absolute()
        and path.parts[:1] == ("activities",)
        and ".." not in path.parts
        and "\\" not in name
        and lower.endswith((".fit", ".fit.gz", ".gpx"))
    )


def read_member(source: str, member: str) -> bytes:
    if not safe_member(member):
        raise ValueError("unsafe or unsupported activity member")
    if source.lower().endswith(".zip"):
        with zipfile.ZipFile(source) as archive:
            info = archive.getinfo(member)
            if info.file_size > MAX_ACTIVITY_BYTES:
                raise ValueError("activity member exceeds size limit")
            payload = archive.read(info)
    else:
        root = Path(source).resolve()
        path = (root / member).resolve()
        if not path.is_relative_to(root) or path.stat().st_size > MAX_ACTIVITY_BYTES:
            raise ValueError("activity path escapes export or exceeds size limit")
        payload = path.read_bytes()
    if member.lower().endswith(".fit.gz"):
        with gzip.GzipFile(fileobj=io.BytesIO(payload)) as stream:
            payload = stream.read(MAX_ACTIVITY_BYTES + 1)
        if len(payload) > MAX_ACTIVITY_BYTES:
            raise ValueError("decompressed FIT exceeds size limit")
    return payload


def empty_streams() -> dict[str, list[float | int | None]]:
    return {"time": [], "heartrate": [], "watts": [], "altitude": [], "distance": []}


def stream_json(streams: dict[str, list[float | int | None]]) -> str:
    if not streams["time"]:
        raise ValueError("activity contains no timed samples")
    result = {"time": {"data": streams["time"]}}
    for key in ("heartrate", "watts", "altitude", "distance"):
        if any(value is not None for value in streams[key]):
            result[key] = {"data": streams[key]}
    return json.dumps(result, separators=(",", ":"), allow_nan=False)


def stream_wire(streams: dict[str, list[float | int | None]]) -> str:
    """Versioned, allocation-friendly format for Roc's offline decoder."""
    available = {key: any(value is not None for value in streams[key]) for key in ("heartrate", "watts", "altitude", "distance")}
    header = "stride-stream-v1:h={};w={};a={};d={}".format(
        int(available["heartrate"]), int(available["watts"]), int(available["altitude"]), int(available["distance"])
    )
    def line(key: str) -> str:
        if key != "time" and not available[key]:
            return ""
        return ",".join("n" if value is None else str(value) for value in streams[key])
    return "\n".join([header, line("time"), line("heartrate"), line("watts"), line("altitude"), line("distance")])


def decode_wire(raw: str) -> dict[str, list[float | None]]:
    lines = raw.split("\n")
    if len(lines) != 6 or not lines[0].startswith("stride-stream-v1:"):
        raise ValueError("invalid offline stream data")
    keys = ("time", "heartrate", "watts", "altitude", "distance")
    return {
        key: [] if not line else [None if value == "n" else float(value) for value in line.split(",")]
        for key, line in zip(keys, lines[1:])
    }


def pairs(times: list[float | None], values: list[float | None]) -> list[tuple[int, float]]:
    return [(round(time), value) for time, value in zip(times, values) if time is not None and value is not None and value >= 0]


def resample(samples: list[tuple[int, float]], interpolate: bool = False) -> list[tuple[int, float]]:
    output: list[tuple[int, float]] = []
    previous: tuple[int, float] | None = None
    for timestamp, value in sorted(samples, key=lambda sample: sample[0]):
        if previous is None:
            output.append((timestamp, value))
        else:
            gap = timestamp - previous[0]
            if gap <= 0:
                continue
            if gap <= 10:
                step = (value - previous[1]) / gap if interpolate else 0.0
                output.extend((previous[0] + offset, previous[1] + step * offset) for offset in range(1, gap))
            output.append((timestamp, value))
        previous = (timestamp, value)
    return output


def normalized(values: list[float]) -> float | None:
    if len(values) < 30:
        return None
    prefix = [0.0]
    for value in values:
        prefix.append(prefix[-1] + value)
    sum_fourth = 0.0
    for index in range(len(values) - 29):
        mean = (prefix[index + 30] - prefix[index]) / 30.0
        sum_fourth += mean ** 4
    return (sum_fourth / (len(values) - 29)) ** 0.25


def best_contiguous(samples: list[tuple[int, float]], window: int) -> float | None:
    if window <= 0 or len(samples) < window:
        return None
    prefix = [0.0]
    for _, value in samples:
        prefix.append(prefix[-1] + value)
    best: float | None = None
    for index in range(len(samples) - window + 1):
        if samples[index + window - 1][0] - samples[index][0] == window - 1:
            mean = (prefix[index + window] - prefix[index]) / window
            best = mean if best is None else max(best, mean)
    return best


def minetti_ratio(grade: float) -> float:
    value = max(-0.45, min(0.45, grade))
    cost = 155.4 * value**5 - 30.4 * value**4 - 43.3 * value**3 + 46.3 * value**2 + 19.5 * value + 3.6
    return max(0.4, cost / 3.6)


def grade_speeds(times: list[float], distances: list[float], altitudes: list[float]) -> list[tuple[int, float]]:
    distance_1s = resample([(round(t), d) for t, d in zip(times, distances)], interpolate=True)
    altitude_1s = resample([(round(t), a) for t, a in zip(times, altitudes)], interpolate=True)
    output: list[tuple[int, float]] = []
    previous: tuple[int, float, float] | None = None
    for (timestamp, distance), (_, altitude) in zip(distance_1s, altitude_1s):
        current = (timestamp, distance, altitude)
        if previous is None:
            previous = current
            continue
        elapsed = timestamp - previous[0]
        delta = distance - previous[1]
        if elapsed <= 0:
            continue
        if elapsed > 10 or delta <= 0:
            previous = current
            continue
        speed = (delta / elapsed) * minetti_ratio((altitude - previous[2]) / delta)
        output.append((timestamp, speed))
        previous = current
    return output


def stream_metrics(streams: dict[str, list[float | None]], zones: tuple[float, float, float, float], ftp: float, threshold: float) -> dict[str, object]:
    time = streams["time"]
    hr = [(t, value) for t, value in pairs(time, streams["heartrate"]) if 35.0 <= value <= 220.0]
    watts = [(t, value) for t, value in pairs(time, streams["watts"]) if 0.0 <= value <= 2500.0]
    watts_1s = resample(watts)

    zone_seconds = [0, 0, 0, 0, 0]
    previous_time: int | None = None
    for timestamp, value in hr:
        if previous_time is not None:
            elapsed = min(30, timestamp - previous_time)
            if elapsed > 0:
                zone = 0 if value <= zones[0] else 1 if value <= zones[1] else 2 if value <= zones[2] else 3 if value <= zones[3] else 4
                zone_seconds[zone] += elapsed
        previous_time = timestamp

    power_intensity = [0, 0, 0]
    previous_time = None
    if ftp > 0:
        for timestamp, value in watts:
            if previous_time is not None:
                elapsed = min(30, timestamp - previous_time)
                if elapsed > 0 and value > 0:
                    band = 0 if value < ftp * 0.76 else 1 if value < ftp * 0.91 else 2
                    power_intensity[band] += elapsed
            previous_time = timestamp

    valid_altitude = bool(streams["altitude"])
    triple = [
        (t, d, a)
        for t, d, a in zip(time, streams["distance"], streams["altitude"])
        if t is not None and d is not None and a is not None
    ] if valid_altitude else []
    if not triple:
        triple = [(t, d, 0.0) for t, d in zip(time, streams["distance"]) if t is not None and d is not None]
    speed_pairs = grade_speeds(
        [sample[0] for sample in triple],
        [sample[1] for sample in triple],
        [sample[2] for sample in triple],
    )
    speeds = [value for _, value in speed_pairs]
    if not watts:
        power_intensity = [0, 0, 0]
        if threshold > 0:
            for value in speeds:
                band = 0 if value < threshold * 0.76 else 1 if value < threshold * 0.91 else 2
                power_intensity[band] += 1

    durations = (5, 15, 30, 60, 300, 600, 3600)
    return {
        "zones": zone_seconds,
        "np": normalized([value for _, value in watts_1s]),
        "best20": best_contiguous(watts_1s, 1200),
        "curve": [best_contiguous(watts_1s, duration) or 0.0 for duration in durations],
        "ngp": normalized(speeds),
        "best20_speed": best_contiguous(speed_pairs, 1200),
        "intensity": power_intensity,
        "has_watts": bool(watts),
    }


def analyze_store(database: str, activity_id: int, ftp: float, threshold: float, zones: tuple[float, float, float, float], zones_signature: str, revision: int) -> None:
    with sqlite3.connect(database) as connection:
        row = connection.execute(
            """SELECT a.moving_time, COALESCE(a.sport_type,''), a.relative_effort,
                      a.avg_watts, a.avg_hr, a.weighted_avg_watts, r.rpe, s.raw_json
               FROM activities a LEFT JOIN ratings r ON r.activity_id=a.id
               LEFT JOIN streams s ON s.activity_id=a.id WHERE a.id=?""",
            (activity_id,),
        ).fetchone()
        if row is None:
            raise ValueError("activity not found")
        moving_time, sport, relative_effort, avg_watts, avg_hr, weighted_watts, rpe, raw = row
        failed = False
        try:
            metrics = stream_metrics(decode_wire(raw), zones, ftp, threshold)
        except (TypeError, ValueError):
            failed = True
            metrics = {"zones": [0] * 5, "np": None, "best20": None, "curve": [0.0] * 7, "ngp": None, "best20_speed": None, "intensity": [0] * 3, "has_watts": False}

        np_like = metrics["np"] if metrics["np"] is not None else weighted_watts if weighted_watts is not None else avg_watts
        zone_total = sum(metrics["zones"])
        if zone_total:
            rates = (30.0, 55.0, 70.0, 80.0, 100.0)
            hr_score = sum(seconds * rate for seconds, rate in zip(metrics["zones"], rates)) / 3600.0
            hr_model = "hr_zones"
        elif avg_hr is not None:
            zone = 0 if avg_hr <= zones[0] else 1 if avg_hr <= zones[1] else 2 if avg_hr <= zones[2] else 3 if avg_hr <= zones[3] else 4
            hr_score = moving_time * (30.0, 55.0, 70.0, 80.0, 100.0)[zone] / 3600.0
            hr_model = "hr_avg"
        else:
            hr_score = None
            hr_model = "none"
        rpe_score = moving_time / 3600.0 * rpe * 10.0 if rpe is not None else None
        fallbacks = [(rpe_score, "session_rpe"), (hr_score, hr_model), (relative_effort, "relative_effort")] if sport in {"WeightTraining", "Workout", "Crossfit", "HighIntensityIntervalTraining", "Yoga", "Pilates"} else [(hr_score, hr_model), (rpe_score, "session_rpe"), (relative_effort, "relative_effort")]
        fallback_score, fallback_model = next(((score, model) for score, model in fallbacks if score is not None), (0.0, "none"))
        if metrics["ngp"] is not None and threshold > 0:
            exponent = 3.0 if "swim" in sport.lower() else 2.0
            pace_score = moving_time / 3600.0 * (metrics["ngp"] / threshold) ** exponent * 100.0
            pace_model = "rtss"
        else:
            pace_score, pace_model = fallback_score, fallback_model
        if np_like is not None and ftp > 0:
            tss = moving_time * np_like * (np_like / ftp) / (ftp * 3600.0) * 100.0
            model = "power_stream" if metrics["np"] is not None else "weighted_watts" if weighted_watts is not None else "avg_watts"
        else:
            tss, model = pace_score, pace_model

        connection.execute(
            """INSERT OR REPLACE INTO activity_metrics
               (activity_id,tss,normalized_power,intensity_factor,z1_s,z2_s,z3_s,z4_s,z5_s,computed_at,
                best_20min_w,ftp_used,zones_used,metrics_rev,load_model,pi_easy_s,pi_moderate_s,pi_hard_s,
                best_5s_w,best_15s_w,best_30s_w,best_60s_w,best_300s_w,best_600s_w,best_3600s_w,
                best_20min_speed,threshold_pace_used)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (
                activity_id, tss, np_like, np_like / ftp if np_like is not None and ftp > 0 else None,
                *metrics["zones"], dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                metrics["best20"], ftp, zones_signature, revision, model, *metrics["intensity"],
                *metrics["curve"], metrics["best20_speed"], threshold,
            ),
        )
    sys.stdout.write("1" if failed else "0")


def activity_detail(database: str, activity_id: int, ftp: float) -> None:
    with sqlite3.connect(database) as connection:
        row = connection.execute("SELECT raw_json FROM streams WHERE activity_id=?", (activity_id,)).fetchone()
    if row is None:
        raise ValueError("activity streams not found")
    streams = decode_wire(row[0])
    time = streams["time"]
    hr = [value for _, value in pairs(time, streams["heartrate"]) if 35.0 <= value <= 220.0]
    watts = [(timestamp, value) for timestamp, value in pairs(time, streams["watts"]) if 0.0 <= value <= 2500.0]
    watts_1s = resample(watts)
    intensity = [0, 0, 0]
    previous_time: int | None = None
    if ftp > 0:
        for timestamp, value in watts:
            if previous_time is not None:
                elapsed = min(30, timestamp - previous_time)
                if elapsed > 0 and value > 0:
                    band = 0 if value < ftp * 0.76 else 1 if value < ftp * 0.91 else 2
                    intensity[band] += elapsed
            previous_time = timestamp
    sys.stdout.write(json.dumps({
        "max_hr": max(hr, default=0.0),
        "best_60": best_contiguous(watts_1s, 60) or 0.0,
        "best_180": best_contiguous(watts_1s, 180) or 0.0,
        "best_300": best_contiguous(watts_1s, 300) or 0.0,
        "best_1200": best_contiguous(watts_1s, 1200) or 0.0,
        "easy_s": intensity[0],
        "moderate_s": intensity[1],
        "hard_s": intensity[2],
        "failed": False,
    }, separators=(",", ":")))


def base_size(base: int) -> int:
    kind = base & 0x1F
    if kind in {0, 1, 2, 7, 10, 13}:
        return 1
    if kind in {3, 4, 11}:
        return 2
    if kind in {5, 6, 8, 12}:
        return 4
    if kind in {9, 14, 15, 16}:
        return 8
    return 1


def compressed_timestamp(previous: int | None, offset: int) -> int | None:
    if previous is None:
        return None
    candidate = previous - previous % 32 + offset
    return candidate + 32 if candidate <= previous else candidate


def decode_fit(data: bytes) -> str:
    if len(data) < 12 or data[8:12] != b".FIT":
        raise ValueError("invalid FIT header")
    header_size = data[0]
    data_size = int.from_bytes(data[4:8], "little")
    end = header_size + data_size
    if header_size < 12 or end > len(data):
        raise ValueError("truncated FIT data")

    definitions: dict[int, tuple[int, str, list[tuple[int, int, int]], int]] = {}
    streams = empty_streams()
    pos = header_size
    last_timestamp: int | None = None
    first_timestamp: int | None = None
    first_distance: float | None = None

    while pos < end:
        header = data[pos]
        pos += 1
        compressed = bool(header & 0x80)
        if compressed:
            local = (header >> 5) & 0x03
            timestamp = compressed_timestamp(last_timestamp, header & 0x1F)
            is_definition = False
            developer = False
        else:
            local = header & 0x0F
            timestamp = last_timestamp
            is_definition = bool(header & 0x40)
            developer = bool(header & 0x20)

        if is_definition:
            if pos + 5 > end:
                raise ValueError("truncated FIT definition")
            architecture = data[pos + 1]
            endian = ">" if architecture else "<"
            global_message = struct.unpack_from(endian + "H", data, pos + 2)[0]
            count = data[pos + 4]
            pos += 5
            fields: list[tuple[int, int, int]] = []
            if pos + count * 3 > end:
                raise ValueError("truncated FIT fields")
            for _ in range(count):
                fields.append((data[pos], data[pos + 1], data[pos + 2]))
                pos += 3
            developer_size = 0
            if developer:
                if pos >= end:
                    raise ValueError("truncated FIT developer fields")
                developer_count = data[pos]
                pos += 1
                if pos + developer_count * 3 > end:
                    raise ValueError("truncated FIT developer definitions")
                for _ in range(developer_count):
                    developer_size += data[pos + 1]
                    pos += 3
            definitions[local] = (global_message, endian, fields, developer_size)
            continue

        if local not in definitions:
            raise ValueError("FIT data references an undefined local message")
        global_message, endian, fields, developer_size = definitions[local]
        values: dict[int, float | int | None] = {}
        for number, size, base in fields:
            if compressed and number == 253:
                values[number] = timestamp
                continue
            if size <= 0 or pos + size > end:
                raise ValueError("truncated FIT record")
            raw = data[pos : pos + size]
            pos += size
            if number not in WANTED_FIELDS:
                continue
            width = min(base_size(base), len(raw))
            scalar = raw[:width]
            if not scalar or all(byte == 0xFF for byte in scalar):
                values[number] = None
            else:
                values[number] = int.from_bytes(scalar, "big" if endian == ">" else "little")
        if pos + developer_size > end:
            raise ValueError("truncated FIT developer payload")
        pos += developer_size

        raw_timestamp = values.get(253, timestamp)
        if raw_timestamp is not None:
            last_timestamp = int(raw_timestamp)
        if global_message != 20 or last_timestamp is None:
            continue

        if first_timestamp is None:
            first_timestamp = last_timestamp
        raw_distance = values.get(5)
        distance = None if raw_distance is None else float(raw_distance) / 100.0
        if first_distance is None and distance is not None:
            first_distance = distance
        streams["time"].append(last_timestamp - first_timestamp)
        streams["heartrate"].append(float(values[3]) if values.get(3) is not None else None)
        streams["watts"].append(float(values[7]) if values.get(7) is not None else None)
        raw_altitude = values.get(78, values.get(2))
        streams["altitude"].append(float(raw_altitude) / 5.0 - 500.0 if raw_altitude is not None else None)
        streams["distance"].append(max(0.0, distance - first_distance) if distance is not None and first_distance is not None else None)

    return stream_json(streams)


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1].rsplit(":", 1)[-1]


def parse_time(value: str) -> int:
    parsed = dt.datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    return int(parsed.timestamp())


def decode_gpx(data: bytes) -> str:
    import xml.etree.ElementTree as ET

    root = ET.fromstring(data)
    streams = empty_streams()
    first_timestamp: int | None = None
    first_direct_distance: float | None = None
    previous: tuple[float, float] | None = None
    cumulative_distance = 0.0

    for point in (node for node in root.iter() if local_name(node.tag) == "trkpt"):
        latitude = float(point.attrib["lat"])
        longitude = float(point.attrib["lon"])
        values = {local_name(node.tag): (node.text or "").strip() for node in point.iter() if node is not point}
        if "time" not in values:
            continue
        timestamp = parse_time(values["time"])
        if first_timestamp is None:
            first_timestamp = timestamp
        direct = float(values["distance"]) if values.get("distance") else None
        if direct is not None:
            if first_direct_distance is None:
                first_direct_distance = direct
            cumulative_distance = max(0.0, direct - first_direct_distance)
        elif previous is not None:
            lat1, lon1 = previous
            p1, p2 = math.radians(lat1), math.radians(latitude)
            dp = math.radians(latitude - lat1)
            dl = math.radians(longitude - lon1)
            a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
            cumulative_distance += 2 * 6_371_000 * math.asin(math.sqrt(min(1.0, max(0.0, a))))
        previous = (latitude, longitude)
        streams["time"].append(timestamp - first_timestamp)
        streams["heartrate"].append(float(values["hr"]) if values.get("hr") else None)
        streams["watts"].append(float(values["power"]) if values.get("power") else None)
        streams["altitude"].append(float(values["ele"]) if values.get("ele") else None)
        streams["distance"].append(cumulative_distance)

    return stream_json(streams)


def main() -> None:
    analyze = len(sys.argv) == 12 and sys.argv[1] == "--analyze-store"
    detail = len(sys.argv) == 5 and sys.argv[1] == "--activity-detail"
    store = len(sys.argv) == 6 and sys.argv[1] == "--store"
    if detail:
        _, database, activity_id, ftp = sys.argv[1:]
        activity_detail(database, int(activity_id), float(ftp))
        return
    if analyze:
        _, database, activity_id, ftp, threshold, z1, z2, z3, z4, signature, revision = sys.argv[1:]
        analyze_store(database, int(activity_id), float(ftp), float(threshold), (float(z1), float(z2), float(z3), float(z4)), signature, int(revision))
        return
    if store:
        _, database, source, member, activity_id = sys.argv[1:]
    elif len(sys.argv) == 3:
        source, member = sys.argv[1:]
    else:
        raise SystemExit("usage: stride_activity_file.py [--store <db>] <export.zip|dir> <activity-member> [activity-id]")
    payload = read_member(source, member)
    result = decode_gpx(payload) if member.lower().endswith(".gpx") else decode_fit(payload)
    if store:
        decoded = json.loads(result)
        stored = stream_wire({
            key: decoded.get(key, {"data": []})["data"]
            for key in ("time", "heartrate", "watts", "altitude", "distance")
        })
        with sqlite3.connect(database) as connection:
            connection.execute(
                "INSERT OR REPLACE INTO streams (activity_id, raw_json) VALUES (?, ?)",
                (int(activity_id), stored),
            )
            connection.execute("DELETE FROM activity_metrics WHERE activity_id = ?", (int(activity_id),))
    else:
        sys.stdout.write(result)


if __name__ == "__main__":
    main()
