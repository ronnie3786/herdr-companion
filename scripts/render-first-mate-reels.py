#!/usr/bin/env python3
"""Edit synthetic native Mac captures into narrated First Mate explainers.

Requires ffmpeg/ffprobe with libx264, drawtext, loudnorm and xfade. Supply actual
synthetic-demo app captures and generated WAV narration in --input. No app UI is
fabricated. Captures retain their aspect ratio, with editorial titles outside
the application and a restrained camera move. Temporary renders stay in build/.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import pathlib
import re
import subprocess
import textwrap

ROOT = pathlib.Path(__file__).resolve().parents[1]
FPS = 30
LEAD = 0.6
TAIL = 0.7
DISSOLVE = 0.6
BACKGROUND = "0x11141f"

# Cue boundaries follow pauses in the generated narration, in source WAV time.
CUES = {
    "one-conversation": [
        (0, 1.85, "Every feature gets its own First Mate."),
        (2.12, 5.17, "Tell it what you want to achieve, and it shapes the next step with you."),
        (5.44, 9.60, "Planning, implementation, and review happen in independent agent sessions."),
        (9.91, 12.57, "Your First Mate stays here, ready for your next question."),
        (12.80, 15.72, "The workspace shows what is running and where the evidence lives."),
        (15.90, 18.14, "When a major step finishes, the work pauses."),
        (18.39, 21.05, "First Mate brings you a clear result and a recommendation."),
        (21.45, 24.05, "You choose what comes next, in your own words."),
    ],
    "review-crew": [
        (0, 2.58, "A review can involve seven independent agents"),
        (2.70, 6.15, "without turning your workspace into seven conversations to manage."),
        (6.42, 8.86, "Open the workflow to see the review as one step."),
        (9.18, 11.10, "Open Agents to meet the specialists."),
        (11.42, 14.40, "Each has its own saved session, assignment, and result."),
        (14.75, 17.33, "Documents stay attached to the step that produced them,"),
        (17.44, 19.70, "so you can trace a finding back to its source."),
        (19.99, 22.02, "First Mate brings those findings together."),
        (22.35, 26.67, "You inspect the evidence, make the decision, and shape the next part of the workflow."),
    ],
    "continuity": [
        (0, 2.40, "Long work needs more than a long conversation."),
        (2.68, 6.76, "The companion service keeps the work log, tracks execution, and watches for trouble."),
        (7.03, 8.58, "When a session needs a fresh start,"),
        (8.70, 12.72, "its checkpoint preserves the assignment, decisions, evidence, and next action."),
        (13.10, 17.42, "A successor loads that checkpoint and verifies its workspace before taking over."),
        (17.68, 20.46, "The old session becomes history, not a loose end."),
        (20.71, 22.82, "You can follow what happened in the feature journal."),
        (23.17, 25.35, "First Mate stays focused on the feature,"),
        (25.57, 27.73, "while the system keeps track of the details."),
    ],
}

# Times are transition centers. Editorial copy is separate from the UI capture.
SCENES = {
    "one-conversation": [
        (0, "planning-light.png", "One conversation. A whole crew.", "01 / SHAPE THE FEATURE", ""),
        (6.1, "implementation-light.png", "Delegate the work. Keep the conversation.", "02 / INDEPENDENT SESSIONS", ""),
        (13.35, "review-graph.png", "The whole workflow stays in view.", "03 / SEE THE WORK", ""),
        (16.5, "checkpoint-light.png", "The next step starts with you.", "04 / YOUR DIRECTION", ""),
    ],
    "review-crew": [
        (0, "review-graph.png", "Seven perspectives. One clear result.", "01 / ONE REVIEW STEP", ""),
        (8.1, "review-agents.png", "A specialist for every perspective.", "02 / MEET THE CREW", ""),
        (12.0, "review-session.png", "Every result has a source.", "03 / THE EXACT SESSION", "Saved independently.\nAttached to its assignment.\nAvailable when you need the detail."),
        (15.3, "review-documents.png", "Evidence stays with the work.", "04 / RETAINED DOCUMENTS", ""),
        (22.65, "checkpoint-light.png", "One clear result. Your next decision.", "05 / HUMAN CHECKPOINT", ""),
    ],
    "continuity": [
        (0, "continuity-dark.png", "Fresh sessions. Continuous work.", "01 / PROTECT THE FEATURE", ""),
        (7.6, "handoff-history-dark.png", "A successor verifies the handoff.", "02 / A VERIFIED SUCCESSOR", "The assignment continues.\nThe session gets a fresh start.\nThe evidence stays connected."),
        (18.2, "predecessor-dark.png", "The previous session becomes history.", "03 / RETAIN THE PREDECESSOR", "A saved session you can revisit.\nAn explicit place in the lineage.\nA clear record of the transition."),
        (21.3, "journal-dark.png", "The journal keeps the whole story.", "04 / FOLLOW THE HISTORY", ""),
    ],
}


def run(args: list[str], *, capture: bool = False) -> str:
    result = subprocess.run(args, check=False, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(result.stderr[-8000:])
    return result.stdout if capture else result.stderr


def probe(path: pathlib.Path) -> dict:
    return json.loads(run(["ffprobe", "-v", "error", "-show_format", "-show_streams",
                           "-of", "json", str(path)], capture=True))


def ff_path(path: pathlib.Path) -> str:
    return str(path).replace("\\", "\\\\").replace("'", "'\\''").replace(":", "\\:")


def stamp(seconds: float) -> str:
    millis = round(seconds * 1000)
    hours, millis = divmod(millis, 3_600_000)
    minutes, millis = divmod(millis, 60_000)
    seconds, millis = divmod(millis, 1000)
    return f"{hours:02}:{minutes:02}:{seconds:02}.{millis:03}"


def text_filter(path: pathlib.Path, font: pathlib.Path, size: int, x: str | int,
                y: str | int, color: str = "0xf4f2ff") -> str:
    return (f"drawtext=fontfile='{ff_path(font)}':textfile='{ff_path(path)}':"
            f"fontsize={size}:fontcolor={color}:x={x}:y={y}:line_spacing=14")


def render_scene(scene: tuple, index: int, duration: float, input_dir: pathlib.Path,
                 cache: pathlib.Path, regular: pathlib.Path, bold: pathlib.Path) -> pathlib.Path:
    _, filename, title, chapter, description = scene
    source = input_dir / filename
    details = probe(source)["streams"][0]
    portrait = details["height"] > details["width"]
    fingerprint = hashlib.sha256(source.read_bytes() + json.dumps(
        [scene, duration, str(regular), str(bold), "layout-v4" if portrait else "layout-v3"]
    ).encode()).hexdigest()[:16]
    target = cache / f"scene-{fingerprint}.mp4"
    if target.exists():
        return target
    labels = {}
    for key, value in {
        "brand": "HERDR / FIRST MATE", "title": title, "chapter": chapter,
        "footer": "ACTUAL MAC INTERFACE  /  SYNTHETIC DEMO  /  GENERATED NARRATION",
        "body": description,
    }.items():
        labels[key] = cache / f"{fingerprint}-{key}.txt"
        labels[key].write_text(value)
    body_filters = []
    for line_index, line in enumerate(description.splitlines()):
        body_path = cache / f"{fingerprint}-body-{line_index}.txt"
        body_path.write_text(line)
        body_filters.append(text_filter(body_path, regular, 31, 110, 462 + line_index * 50, "0xc8cfdf"))
    frames = math.ceil(duration * FPS)
    # Padding is deliberately larger than the camera move, retaining every edge
    # of the real screenshot throughout. There is no simulated interaction.
    if portrait:
        width, height, x, y = 864, 960, 970, 156
        image_w, image_h = 824, 924
    else:
        width, height, x, y = 1792, 960, 64, 152
        image_w, image_h = 1740, 912
    filters = [
        f"[0:v]scale={image_w}:{image_h}:force_original_aspect_ratio=decrease:flags=lanczos,"
        f"pad={width}:{height}:(ow-iw)/2:(oh-ih)/2:color={BACKGROUND},"
        f"zoompan=z='1+0.012*on/{max(1, frames-1)}':x='iw/2-iw/zoom/2':"
        f"y='ih/2-ih/zoom/2':d=1:s={width}x{height}:fps={FPS},"
        f"trim=duration={duration:.6f},setpts=PTS-STARTPTS[picture]",
        f"color=c={BACKGROUND}:s=1920x1200:r={FPS}:d={duration:.6f}[matte]",
        f"[matte][picture]overlay={x}:{y}:shortest=1,"
        "drawbox=x=80:y=134:w=1760:h=1:color=0x313747:t=fill,"
        "drawbox=x=80:y=134:w=112:h=2:color=0xb5a0ff:t=fill,"
        + text_filter(labels["brand"], bold, 19, 80, 33, "0xb5a0ff") + ","
        + text_filter(labels["chapter"], regular, 18, "1840-tw", 34, "0xa3acbf") + ","
        + text_filter(labels["title"], bold, 46, 80, 75) + ","
        + text_filter(labels["footer"], regular, 14, 80, 1160, "0x8893aa")
        + ("," + ",".join(body_filters) if portrait and body_filters else "")
        + ",format=yuv420p[out]",
    ]
    graph = cache / f"{fingerprint}.filter"
    graph.write_text(";\n".join(filters))
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-filter_complex_threads", "2",
         "-loop", "1", "-framerate", str(FPS), "-i", str(source),
         "-filter_complex_script", str(graph), "-map", "[out]", "-an", "-t", f"{duration:.6f}",
         "-c:v", "libx264", "-threads", "2", "-preset", "fast", "-crf", "17",
         "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(target)])
    print(f"Rendered {filename}", flush=True)
    return target


def render_reel(item: dict, input_dir: pathlib.Path, output: pathlib.Path,
                cache: pathlib.Path, regular: pathlib.Path, bold: pathlib.Path) -> dict:
    reel_id = item["id"]
    source_audio = input_dir / f"{reel_id}.wav"
    audio_duration = float(probe(source_audio)["format"]["duration"])
    duration = math.ceil((audio_duration + LEAD + TAIL) * FPS) / FPS
    script = " ".join(cue[2] for cue in CUES[reel_id])
    assert script == item["text"], f"Caption transcript differs from narration: {reel_id}"
    captions = output / f"{reel_id}.vtt"
    captions.write_text("WEBVTT\n\n" + "\n\n".join(
        f"{number}\n{stamp(start + LEAD)} --> {stamp(end + LEAD)}\n"
        + "\n".join(textwrap.wrap(text, width=57))
        for number, (start, end, text) in enumerate(CUES[reel_id], 1)
    ) + "\n")
    scenes = SCENES[reel_id]
    clips = []
    for index, scene in enumerate(scenes):
        start = max(0, scene[0] - DISSOLVE / 2)
        end = scenes[index + 1][0] + DISSOLVE / 2 if index + 1 < len(scenes) else duration
        clips.append(render_scene(scene, index, end - start, input_dir, cache, regular, bold))

    # Two-pass normalization avoids abrupt limiting and records objective levels.
    loudness_log = run(["ffmpeg", "-hide_banner", "-i", str(source_audio), "-af",
                       "loudnorm=I=-16:TP=-1.5:LRA=9:print_format=json", "-f", "null", "-"])
    loudness = json.loads(re.findall(r"\{[^{}]+\}", loudness_log)[-1])
    normalization = ("loudnorm=I=-16:TP=-1.5:LRA=9:linear=true:"
                     f"measured_I={loudness['input_i']}:measured_TP={loudness['input_tp']}:"
                     f"measured_LRA={loudness['input_lra']}:measured_thresh={loudness['input_thresh']}:"
                     f"offset={loudness['target_offset']}")
    filters = [f"[{index}:v]settb=AVTB,setpts=PTS-STARTPTS[v{index}]" for index in range(len(clips))]
    previous = "v0"
    for index in range(1, len(clips)):
        current = f"transition{index}"
        filters.append(f"[{previous}][v{index}]xfade=transition=fade:duration={DISSOLVE}:"
                       f"offset={scenes[index][0] - DISSOLVE / 2:.6f}[{current}]")
        previous = current
    filters.append(f"[{previous}]trim=duration={duration:.6f},"
                   "scale=out_range=tv:out_color_matrix=bt709,format=yuv420p,setsar=1[video]")
    filters.append(f"[{len(clips)}:a]{normalization},aresample=48000,adelay=600:all=1,"
                   f"apad=whole_dur={duration:.6f},atrim=duration={duration:.6f}[audio]")
    graph = cache / f"{reel_id}-final.filter"
    graph.write_text(";\n".join(filters))
    target = output / f"{reel_id}.mp4"
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-filter_complex_threads", "2"]
    for clip in clips:
        command += ["-i", str(clip)]
    command += ["-i", str(source_audio), "-i", str(captions), "-filter_complex_script", str(graph),
                "-map", "[video]", "-map", "[audio]", "-map", f"{len(clips)+1}:s:0",
                "-c:v", "libx264", "-threads", "2", "-preset", "slow", "-crf", "19",
                "-pix_fmt", "yuv420p", "-color_range", "tv", "-colorspace", "bt709",
                "-color_primaries", "bt709", "-color_trc", "bt709",
                "-c:a", "aac", "-b:a", "192k", "-c:s", "mov_text",
                "-metadata:s:s:0", "language=eng", "-metadata", f"title={item['title']}",
                "-metadata", "comment=Edited actual Mac UI captures. Synthetic demo. Generated narration.",
                "-map_metadata", "-1", "-movflags", "+faststart", "-t", f"{duration:.6f}", str(target)]
    run(command)
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", "2", "-i", str(target),
         "-frames:v", "1", "-q:v", "2", "-update", "1", str(output / f"{reel_id}.jpg")])
    # Decode all audio/video frames, catching truncated or corrupt final media.
    run(["ffmpeg", "-hide_banner", "-v", "error", "-i", str(target), "-map", "0:v", "-map", "0:a",
         "-f", "null", "-"])
    result = {"id": reel_id, "duration": duration, "bytes": target.stat().st_size,
              "sha256": hashlib.sha256(target.read_bytes()).hexdigest(), "source_loudness": loudness,
              "sources": [scene[1] for scene in scenes], "output": target.name,
              "streams": [{k: stream[k] for k in ("codec_type", "codec_name", "width", "height", "sample_rate")
                           if k in stream} for stream in probe(target)["streams"]]}
    (cache / f"{reel_id}-verification.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"Verified {reel_id}: {duration:.2f}s, {target.stat().st_size / 1_000_000:.1f} MB", flush=True)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=pathlib.Path, default=ROOT / "build/first-mate-media")
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / "docs/first-mate/explainer/media")
    parser.add_argument("--only", choices=list(SCENES))
    parser.add_argument("--font", type=pathlib.Path, default=pathlib.Path("/System/Library/Fonts/Supplemental/Arial.ttf"))
    parser.add_argument("--bold-font", type=pathlib.Path, default=pathlib.Path("/System/Library/Fonts/Supplemental/Arial Bold.ttf"))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    cache = ROOT / "build/first-mate-media/render-cache"
    cache.mkdir(parents=True, exist_ok=True)
    narrations = json.loads((ROOT / "docs/first-mate/explainer/narration.json").read_text())
    for item in narrations:
        if not args.only or item["id"] == args.only:
            render_reel(item, args.input, args.output, cache, args.font, args.bold_font)


if __name__ == "__main__":
    main()
