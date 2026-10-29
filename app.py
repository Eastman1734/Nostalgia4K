"""Nostalgia4K: Real-ESRGAN x2 -> optional grayscale -> NVENC MP4.

Frames stream through RAM; no directory of extracted 4K images is created.
"""
from __future__ import annotations
import argparse
import json
import math
import os
import subprocess
import sys
import time
import uuid
from datetime import datetime
from pathlib import Path
import numpy as np
import events
from core import (find_original, executable, probe, read_frame, tiled_upscale,
                  finish_frame, decoder_command, encoder_command, target_size, NO_WINDOW)

ROOT = Path(__file__).resolve().parent


def arguments():
    p = argparse.ArgumentParser(description="AI upscale x2 with NVIDIA TensorRT/CUDA and NVENC; grayscale by default.")
    p.add_argument("--input", type=Path, help="Original video. Automatically finds the OK.ru video if omitted.")
    p.add_argument("--output", type=Path, help="New output MP4; existing files are never overwritten.")
    p.add_argument("--start", type=float, default=0, help="Start time in seconds")
    p.add_argument("--seconds", type=float, default=0, help="Limit duration; 0 processes the remaining film")
    p.add_argument("--strength", type=float, default=0.75, help="AI blend 0..1; default .75 preserves some original texture")
    p.add_argument("--color", action="store_true", help="Keep color; default output is grayscale")
    p.add_argument("--tile", type=int, default=256, help="Core tile size; lower to 128 for less VRAM")
    p.add_argument("--halo", type=int, default=32, help="Context pixels around each tile; increase to 64 if seams appear")
    p.add_argument("--precision", choices=["fp16", "fp32"], default="fp16")
    p.add_argument("--backend", choices=["tensorrt", "torch"], default="tensorrt")
    p.add_argument("--device", type=int, default=0, help="NVIDIA GPU index")
    p.add_argument("--cq", type=int, default=18, help="NVENC quality; lower is larger/higher quality")
    p.add_argument("--audio-codec", choices=["copy", "aac"], default="copy")
    p.add_argument("--resolution", choices=["source", "1080p", "1440p", "2160p", "2x"], default="2x")
    p.add_argument("--preset", choices=["p5", "p7"], default="p7")
    p.add_argument("--events", action="store_true", help="Structured progress for the desktop interface")
    p.add_argument("--inspect", action="store_true", help="Read input metadata without loading the neural model")
    p.add_argument("--doctor", action="store_true", help="Check CUDA, TensorRT and NVENC without processing a film")
    p.add_argument("--prepare", action="store_true", help="Download weights and build/load the inference engine only")
    args = p.parse_args()
    if args.start < 0 or args.seconds < 0 or not 0 <= args.strength <= 1:
        p.error("start/seconds must be non-negative; strength must be between 0 and 1")
    if args.tile < 16 or args.tile % 2 or args.halo < 0 or args.halo % 2:
        p.error("tile must be even and >=16; halo must be even and >=0")
    if not 1 <= args.cq <= 51:
        p.error("cq must be between 1 and 51")
    return args


def nvenc_check(ffmpeg, device):
    command = [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
               "-f", "lavfi", "-i", "color=black:size=256x256:rate=1", "-frames:v", "1",
               "-c:v", "h264_nvenc", "-gpu", str(device), "-preset", "p7", "-f", "null", "-"]
    result = subprocess.run(command, capture_output=True, encoding="utf-8", errors="replace", timeout=90, creationflags=NO_WINDOW)
    if result.returncode:
        raise RuntimeError("NVENC check failed. Update the NVIDIA driver; run Install.ps1.\n" + result.stderr[-4000:])
    print("NVENC H.264 p7: OK", flush=True)


def terminate(process):
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def hms(seconds):
    if not math.isfinite(seconds):
        return "--:--:--"
    seconds = max(0, round(seconds))
    return f"{seconds // 3600:02d}:{seconds // 60 % 60:02d}:{seconds % 60:02d}"


def convert(args, source, target, video, infer, ffmpeg):
    remaining = video.duration - args.start
    if remaining <= 0:
        raise ValueError("Start time is beyond the end of the video")
    duration = min(args.seconds, remaining) if args.seconds else remaining
    requested = max(1, math.ceil(duration * float(video.fps) - 1e-8))
    temporary = target.with_name(target.stem + "." + uuid.uuid4().hex + ".part.mp4")
    logs = ROOT / "logs"
    logs.mkdir(exist_ok=True)
    run_id = datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
    decoder_log, encoder_log = logs / (run_id + "-decode.log"), logs / (run_id + "-encode.log")
    dimensions = target_size(video, getattr(args, "resolution", "2x"))
    preset = getattr(args, "preset", "p7")
    encode = encoder_command(ffmpeg, source, temporary, video, args.start, requested, args.cq,
                             output_size=dimensions, preset=preset)
    encode[-1:-1] = ["-gpu", str(args.device)]
    if args.audio_codec == "aac":
        index = encode.index("-c:a")
        encode[index + 1] = "aac"
        encode[index + 2:index + 2] = ["-b:a", "192k"]
    decoder = encoder = None
    count = 0
    begun, last_report = time.monotonic(), 0.0
    print(f"Input:  {source}", flush=True)
    print(f"Output: {target}", flush=True)
    print(f"{video.width}x{video.height} -> {dimensions[0]}x{dimensions[1]}; {video.fps} fps; {hms(duration)}", flush=True)
    events.emit("stage", name="processing", message="Processing video", total=requested,
                width=dimensions[0], height=dimensions[1])
    print("AI restoration is much heavier than simple grayscale encoding. Measuring speed...", flush=True)
    try:
        with decoder_log.open("wb") as dlog, encoder_log.open("wb") as elog:
            decoder = subprocess.Popen(decoder_command(ffmpeg, source, video, args.start, requested),
                                       stdout=subprocess.PIPE, stderr=dlog, stdin=subprocess.DEVNULL, creationflags=NO_WINDOW)
            encoder = subprocess.Popen(encode, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=elog, creationflags=NO_WINDOW)

            def tile_progress(current, total):
                nonlocal last_report
                now = time.monotonic()
                if now - last_report >= 2:
                    elapsed = now - begun
                    speed = count / elapsed if elapsed else 0
                    if count:
                        left = (requested - count) / speed
                        events.emit("progress", current=count, total=requested, percent=count * 100 / requested,
                                    fps=speed, eta=hms(left), elapsed=hms(elapsed))
                        if not events.enabled:
                            print(f"\r{count}/{requested} frames | {speed:.2f} fps | {speed / float(video.fps):.3f}x | ETA {hms(left)}    ",
                                  end="", flush=True)
                    else:
                        events.emit("warmup", current=current, total=total, elapsed=hms(elapsed))
                        if not events.enabled:
                            print(f"\rFirst frame: tile {current}/{total}, elapsed {hms(elapsed)}    ", end="", flush=True)
                    last_report = now

            while count < requested:
                if encoder.poll() is not None:
                    raise RuntimeError(f"Encoder exited early. See {encoder_log}")
                data = read_frame(decoder.stdout, video.width * video.height * 3)
                if data is None:
                    break
                frame = np.frombuffer(data, np.uint8).reshape(video.height, video.width, 3)
                ai = tiled_upscale(frame, infer, args.tile, args.halo, tile_progress)
                output = finish_frame(ai, frame, args.strength, not args.color, dimensions)
                encoder.stdin.write(output.tobytes())
                count += 1
            decoder.stdout.close()
            if decoder.wait(timeout=120):
                raise RuntimeError(f"Decoder failed. See {decoder_log}")
            encoder.stdin.close()
            events.emit("stage", name="finalizing", message="Finalizing MP4")
            if encoder.wait(timeout=600):
                raise RuntimeError(f"Encoder failed. See {encoder_log}")
        if not count:
            raise RuntimeError("No frames were decoded")
        if target.exists():
            raise FileExistsError(f"Output was created by another process; keeping the temporary file: {temporary}")
        # Windows rename refuses to overwrite an existing destination.
        temporary.rename(target)
        elapsed = time.monotonic() - begun
        report = {"input": str(source), "output": str(target), "frames": count,
                  "fps": str(video.fps), "resolution": list(dimensions),
                  "seconds_elapsed": elapsed, "processing_fps": count / elapsed,
                  "backend": args.backend, "precision": args.precision, "strength": args.strength,
                  "tile": args.tile, "halo": args.halo, "grayscale": not args.color,
                  "model": "RealESRGAN_x2plus", "encoder": "h264_nvenc", "preset": preset, "cq": args.cq}
        target.with_suffix(".json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"\nDone: {target}\nElapsed {hms(elapsed)}; average {count / elapsed:.2f} fps", flush=True)
        events.emit("done", path=str(target), elapsed=hms(elapsed), fps=count / elapsed, frames=count)
    except BaseException:
        terminate(decoder)
        terminate(encoder)
        # Keep a failed temporary output for diagnosis. It is never the final filename.
        print(f"\nRun did not finish. Logs: {decoder_log}, {encoder_log}", file=sys.stderr)
        if temporary.exists():
            print(f"Incomplete output: {temporary}", file=sys.stderr)
        raise
    finally:
        terminate(decoder)
        terminate(encoder)


def main():
    args = arguments()
    events.enabled = args.events
    if args.inspect:
        if args.input is None:
            raise ValueError("--inspect requires --input")
        video = probe(executable("ffprobe", ROOT), args.input.resolve(strict=True))
        events.emit("metadata", width=video.width, height=video.height, fps=float(video.fps),
                    duration=video.duration, audio=video.audio, audio_codecs=list(video.audio_codecs),
                    outputs={name: target_size(video, name) for name in ["source", "1080p", "1440p", "2160p", "2x"]})
        if not events.enabled:
            print(json.dumps(video.__dict__, default=str))
        return
    events.emit("stage", name="checking", message="Checking NVIDIA GPU")
    import torch
    torch.set_num_threads(2)
    from gpu import weights, TensorRT, TorchCuda, cuda_check
    ffmpeg, ffprobe = executable("ffmpeg", ROOT), executable("ffprobe", ROOT)
    if args.doctor:
        cuda_check(args.device)
        import tensorrt as trt
        print(f"PyTorch {torch.__version__}; TensorRT {trt.__version__}")
        logger = trt.Logger(trt.Logger.WARNING)
        builder = trt.Builder(logger)
        if builder is None:
            raise RuntimeError("TensorRT builder initialization failed")
        print(f"TensorRT builder: OK; fast FP16: {builder.platform_has_fast_fp16}")
        nvenc_check(ffmpeg, args.device)
        print("Checks passed. Next: Start.ps1 -Preview")
        events.emit("checked", message="GPU checks passed")
        return
    source = target = video = None
    if not args.prepare:
        folder = ROOT.parent / "videos"
        source = (args.input if args.input else find_original(folder)).resolve(strict=True)
        suffix = "_ai4k_" + ("color" if args.color else "bw") + ("_preview" if args.seconds else "")
        target = (args.output or source.with_name(source.stem + suffix + ".mp4")).resolve()
        if target.suffix.lower() != ".mp4":
            raise ValueError("Output filename must end in .mp4")
        if target == source or target.exists():
            raise FileExistsError("Output exists or matches the original. Select a new --output path.")
        target.parent.mkdir(parents=True, exist_ok=True)
        video = probe(ffprobe, source)
        if (video.width, video.height) != (1920, 1080) and args.resolution == "2x":
            print(f"Note: this app scales exactly 2x; the result will be {video.width * 2}x{video.height * 2}, not forced 4K.")
        nvenc_check(ffmpeg, args.device)
    path = weights(ROOT)
    events.emit("stage", name="engine", message="Preparing neural model")
    backend = TensorRT if args.backend == "tensorrt" else TorchCuda
    infer = backend(path, args.tile + 2 * args.halo, ROOT / "cache", args.device, args.precision) if args.backend == "tensorrt" else backend(path, args.tile + 2 * args.halo, args.device, args.precision)
    if args.prepare:
        print("Model and inference backend are ready.")
    else:
        convert(args, source, target, video, infer, ffmpeg)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nStopped by user.", file=sys.stderr)
        sys.exit(130)
    except Exception as error:
        events.emit("error", message=str(error))
        print(f"\nERROR: {error}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)
