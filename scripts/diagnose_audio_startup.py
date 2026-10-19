#!/usr/bin/env python3
"""Compile production capture/cue code, measure real-device timing, and inspect cue PCM.

This records only the diagnostic process's generated cue. Microphone samples are
counted, never written. It does not change the selected system audio devices.
Requires Xcode and previously granted microphone/system-audio capture permission.
"""
import argparse
import json
import math
from pathlib import Path
import re
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def analyze(path):
    raw = path.read_bytes()
    assert raw[:4] == b"RIFF" and raw[8:12] == b"WAVE", "Expected WAV"
    offset = 12
    fmt = payload = None
    while offset + 8 <= len(raw):
        kind, size = struct.unpack_from("<4sI", raw, offset)
        block = raw[offset + 8:offset + 8 + size]
        if kind == b"fmt ":
            fmt = block
        elif kind == b"data":
            payload = block
        offset += 8 + size + size % 2
    encoding, channels, rate, _, _, bits = struct.unpack_from("<HHIIHH", fmt)
    if encoding == 0xFFFE:
        encoding = struct.unpack_from("<H", fmt, 24)[0]
    assert encoding == 3 and channels == 1 and bits == 32, "Expected mono Float32"
    samples = [x[0] for x in struct.iter_unpack("<f", payload)]
    active = [i for i, value in enumerate(samples) if abs(value) > 0.001]
    assert active, f"Silent output: {path}"
    onset, end = active[0], active[-1]
    frequencies = []
    for begin, finish, expected in [(0.02, 0.065, 740), (0.12, 0.24, 1047), (0.325, 0.37, 1318.5)]:
        segment = samples[onset + int(begin * rate):onset + int(finish * rate)]
        window = [v * (0.5 - 0.5 * math.cos(2 * math.pi * i / (len(segment)-1))) for i, v in enumerate(segment)]
        def energy(frequency):
            step = 2 * math.pi * frequency / rate
            real = sum(value * math.cos(step*i) for i, value in enumerate(window))
            imag = sum(value * math.sin(step*i) for i, value in enumerate(window))
            return real*real + imag*imag
        peak_frequency = max(range(round(expected)-40, round(expected)+41, 2), key=energy)
        assert energy(expected) > 1, "Missing tone segment"
        assert abs(peak_frequency - expected) <= 10, "Incorrect cue frequency"
        frequencies.append(peak_frequency)
    duration = (end-onset)*1000/rate
    assert 375 <= duration <= 410, f"Truncated cue: {duration:.1f} ms"
    return {"file": str(path), "signalDurationMs": round(duration, 2),
            "peak": max(map(abs, samples)), "frequenciesHz": frequencies}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "tmp/audio-startup-diagnostic")
    parser.add_argument("--max-first-buffer-ms", type=float, default=1000,
                        help="Absolute timing gate; use 250 for the tested Bluetooth/loopback routes")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    services = ROOT / "Sources/HorseWhisprer/Services"
    # Compile the production player and its protocol, without constructing app
    # settings/licensing/UI. Renderer and playback implementation are unchanged.
    source = (services / "RecordingFeedbackService.swift").read_text()
    extracted = source[:source.index("@MainActor\nfinal class RecordingFeedbackService")]
    extracted += source[source.index("@MainActor\nfinal class SystemCuePlayer"):]
    (out / "ProductionCuePlayer.swift").write_text(extracted)
    (out / "ASRResultStub.swift").write_text("import Foundation\nstruct TranscriptionResult: Sendable { let text: String; let duration: TimeInterval }\n")
    sources = list((ROOT / "scripts/diagnostics").glob("*.swift")) + [out / "ProductionCuePlayer.swift", out / "ASRResultStub.swift"]
    sources += [services / name for name in ["CueWaveData.swift", "CueRoutePlanner.swift", "StreamingAudioCapture.swift", "AudioQueueCapture.swift"]]
    sources += [ROOT / "Sources/HorseWhisprer/Models" / name for name in ["RecordingCueCatalog.swift", "NativeASRModels.swift"]]
    binary = out / "audio-startup-diagnostic"
    with (out / "compile.log").open("w") as log:
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", *map(str, sources), "-o", str(binary)], stdout=log, stderr=subprocess.STDOUT, check=True)
    result = subprocess.run([str(binary), str(out)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    (out / "timing.log").write_text(result.stdout)
    print(result.stdout)
    result.check_returncode()
    measurements = [analyze(out / f"direct-{name}.wav") for name in ["first", "repeat"]]
    first_buffers = [float(v) for v in re.findall(r"FIRST_BUFFER \S+ ms=([\d.]+)", result.stdout)]
    baseline = [float(v) for v in re.findall(r"BASELINE_BUFFER \S+ ms=([\d.]+)", result.stdout)]
    assert len(first_buffers) == 2 and len(baseline) == 2, "Missing capture timing"
    report = {"firstBufferMs": first_buffers, "baselineFirstBufferMs": baseline, "cues": measurements,
              "scope": "Digital process output and real input callbacks; not an acoustic measurement inside the earbuds."}
    (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    assert max(first_buffers) < args.max_first_buffer_ms, f"Slow capture: {first_buffers}"
    assert sum(first_buffers) <= sum(baseline) * 1.1, f"Capture regressed against prior engine: {report}"



if __name__ == "__main__":
    main()
