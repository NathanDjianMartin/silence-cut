#!/usr/bin/env python3
"""Detect silences in a video and write an FCPXML timeline for Final Cut Pro.

Modes:
  remove  - silences cut out, speech segments joined
  gaps    - silences replaced by gap clips (structure preserved)
  blade   - clip split at silences, silent parts tagged with a SILENCE keyword + marker

Requires ffmpeg/ffprobe (brew install ffmpeg).
"""
import argparse
import json
import re
import subprocess
import sys
from fractions import Fraction
from pathlib import Path
from urllib.parse import quote
from xml.sax.saxutils import quoteattr


def probe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-print_format", "json", "-show_streams", "-show_format", str(path)],
        capture_output=True, text=True, check=True).stdout
    info = json.loads(out)
    video = next((s for s in info["streams"] if s["codec_type"] == "video"), None)
    audio = next((s for s in info["streams"] if s["codec_type"] == "audio"), None)
    if not video or not audio:
        sys.exit("Le fichier doit contenir une piste vidéo et une piste audio.")
    num, den = map(int, (video.get("avg_frame_rate") or video["r_frame_rate"]).split("/"))
    return {
        "fps": Fraction(num, den),
        "w": int(video["width"]), "h": int(video["height"]),
        "duration": Fraction(info["format"]["duration"]).limit_denominator(100000),
        "rate": int(audio["sample_rate"]), "ch": int(audio.get("channels", 2)),
    }


def detect_silences(path, threshold_db, min_dur, duration):
    """Return [(start, end)] in seconds."""
    p = subprocess.run(
        ["ffmpeg", "-hide_banner", "-nostats", "-i", str(path), "-vn",
         "-af", f"silencedetect=noise={threshold_db}dB:d={min_dur}", "-f", "null", "-"],
        capture_output=True, text=True)
    starts = [float(m) for m in re.findall(r"silence_start: (-?[\d.]+)", p.stderr)]
    ends = [float(m) for m in re.findall(r"silence_end: ([\d.]+)", p.stderr)]
    if len(ends) < len(starts):  # silence runs to end of file
        ends.append(float(duration))
    return [(max(s, 0.0), e) for s, e in zip(starts, ends)]


def build_segments(silences, duration, padding, fps):
    """Alternating (is_silent, start_frame, end_frame), frame-aligned, padding keeps speech edges."""
    total = int(duration * fps)
    cuts = []
    for s, e in silences:
        s, e = s + padding, e - padding  # shrink silence so speech keeps a margin
        a, b = round(s * fps), round(e * fps)
        if b > a:
            cuts.append((a, min(b, total)))
    segs, pos = [], 0
    for a, b in cuts:
        if a > pos:
            segs.append((False, pos, a))
        segs.append((True, a, b))
        pos = b
    if pos < total:
        segs.append((False, pos, total))
    return segs


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("video")
    ap.add_argument("-o", "--output", help="fichier .fcpxml (défaut: <video>.fcpxml)")
    ap.add_argument("-m", "--mode", choices=["remove", "gaps", "blade"], default="remove")
    ap.add_argument("-t", "--threshold", type=float, default=-35, help="seuil en dB (défaut -35)")
    ap.add_argument("-d", "--min-duration", type=float, default=0.5, help="durée mini du silence en s (défaut 0.5)")
    ap.add_argument("-p", "--padding", type=float, default=0.1, help="marge gardée autour de la parole en s (défaut 0.1)")
    a = ap.parse_args()

    src = Path(a.video).expanduser().resolve()
    info = probe(src)
    fps = info["fps"]
    silences = detect_silences(src, a.threshold, a.min_duration, info["duration"])
    segs = build_segments(silences, info["duration"], a.padding, fps)
    saved = sum(b - a_ for sil, a_, b in segs if sil) / float(fps)
    print(f"{len(silences)} silences détectés, {saved:.1f}s de silence sur {float(info['duration']):.1f}s")

    fd = 1 / fps  # frame duration

    def t(frames):
        f = Fraction(frames) * fd
        return f"{f.numerator}/{f.denominator}s" if f.denominator != 1 else f"{f.numerator}s"

    name = src.stem
    clips, offset = [], 0
    for sil, s, e in segs:
        n = e - s
        if a.mode == "remove" and sil:
            continue
        if a.mode == "gaps" and sil:
            clips.append(f'<gap name="Silence" offset="{t(offset)}" start="3600s" duration="{t(n)}"/>')
        else:
            inner = ""
            if a.mode == "blade" and sil:
                inner = (f'<keyword start="{t(s)}" duration="{t(n)}" value="SILENCE"/>'
                         f'<marker start="{t(s)}" duration="{t(1)}" value="SILENCE"/>')
            clips.append(
                f'<asset-clip ref="r2" name={quoteattr(name)} offset="{t(offset)}" start="{t(s)}" '
                f'duration="{t(n)}" format="r1" tcFormat="NDF" audioRole="dialogue">{inner}</asset-clip>')
        offset += n

    total_frames = int(info["duration"] * fps)
    xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE fcpxml>
<fcpxml version="1.10">
  <resources>
    <format id="r1" frameDuration="{fd.numerator}/{fd.denominator}s" width="{info['w']}" height="{info['h']}"/>
    <asset id="r2" name={quoteattr(name)} start="0s" duration="{t(total_frames)}" hasVideo="1" hasAudio="1" format="r1" audioSources="1" audioChannels="{info['ch']}" audioRate="{info['rate']}">
      <media-rep kind="original-media" src="file://{quote(str(src))}"/>
    </asset>
  </resources>
  <library>
    <event name="SilenceCut">
      <project name={quoteattr(name + ' - ' + a.mode)}>
        <sequence format="r1" duration="{t(offset)}" tcStart="0s" tcFormat="NDF">
          <spine>
            {chr(10).join('            ' + c for c in clips).strip()}
          </spine>
        </sequence>
      </project>
    </event>
  </library>
</fcpxml>
"""
    out = Path(a.output) if a.output else src.with_suffix(".fcpxml")
    out.write_text(xml, encoding="utf-8")
    print(f"Écrit: {out}  (File > Import > XML… dans Final Cut Pro)")


if __name__ == "__main__":
    main()
