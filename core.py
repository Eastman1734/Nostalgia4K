"""GPU-independent media handling and tile geometry."""
from __future__ import annotations
import math
import re
import shutil
import subprocess
import json
import os
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
import numpy as np

VIDEO_EXTENSIONS = {".mp4", ".mkv", ".mov", ".avi", ".webm", ".ts", ".m4v", ".flv"}
NO_WINDOW = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0


def find_original(folder: Path) -> Path:
    candidates = sorted(p for p in folder.iterdir() if p.is_file()
                        and p.suffix.lower() in VIDEO_EXTENSIONS
                        and not re.search(r"(?:_bw(?:_nvenc)?|_ai4k.*)$", p.stem, re.I)
                        and ".part." not in p.name)
    if len(candidates) == 1:
        return candidates[0]
    raise ValueError("Cannot select one original. Use --input with the complete video path.")


def executable(name: str, root: Path) -> str:
    for folder in (root / "tools", root.parent / "tools"):
        for candidate in (folder / (name + ".exe"), folder / name):
            if candidate.is_file():
                return str(candidate.resolve())
    found = shutil.which(name)
    if found:
        return found
    raise FileNotFoundError(f"{name} not found. Run Install.ps1 or put {name}.exe in tools.")


@dataclass(frozen=True)
class Video:
    width: int
    height: int
    fps: Fraction
    duration: float
    audio: bool
    audio_codecs: tuple[str, ...] = ()


def probe(ffprobe: str, source: Path) -> Video:
    result = subprocess.run([ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(source)],
                            capture_output=True, check=True, encoding="utf-8", creationflags=NO_WINDOW)
    data = json.loads(result.stdout)
    stream = next((x for x in data["streams"] if x["codec_type"] == "video"), None)
    if stream is None:
        raise ValueError("The input has no video stream.")
    if stream.get("color_transfer") in {"smpte2084", "arib-std-b67"}:
        raise ValueError("HDR input is not supported; this pipeline is for SDR BT.709 footage.")
    for item in stream.get("side_data_list", []):
        if int(item.get("rotation", 0)) % 360:
            raise ValueError("Rotated video is not supported in this version. Normalize rotation first.")
    rate = stream.get("avg_frame_rate", "0/0")
    if rate in ("0/0", "0", "N/A"):
        rate = stream.get("r_frame_rate", "0/0")
    fps = Fraction(rate)
    if not 0 < fps <= 240:
        raise ValueError(f"Unsupported frame rate: {fps}")
    duration = float(stream.get("duration") or data["format"].get("duration") or 0)
    if duration <= 0:
        raise ValueError("Cannot determine video duration.")
    return Video(int(stream["width"]), int(stream["height"]), fps, duration,
                 any(x["codec_type"] == "audio" for x in data["streams"]),
                 tuple(x.get("codec_name", "") for x in data["streams"] if x["codec_type"] == "audio"))


def read_frame(pipe, size: int) -> bytes | None:
    chunks, received = [], 0
    while received < size:
        chunk = pipe.read(size - received)
        if not chunk:
            if received:
                raise RuntimeError(f"Decoder returned an incomplete frame: {received}/{size} bytes.")
            return None
        chunks.append(chunk)
        received += len(chunk)
    return b"".join(chunks)


def tiled_upscale(frame: np.ndarray, infer, tile: int, halo: int, progress=None) -> np.ndarray:
    """Fixed-size overlapping inference tiles; retain only each tile's center.

    Even tile/halo sizes preserve pixel-unshuffle alignment. Edge padding gives
    every tile exactly the same shape, allowing one cached TensorRT engine.
    """
    if tile < 16 or tile % 2 or halo < 0 or halo % 2:
        raise ValueError("tile must be even and >=16; halo must be even and >=0")
    h, w, channels = frame.shape
    if channels != 3 or frame.dtype != np.uint8:
        raise ValueError("Expected an RGB uint8 frame")
    padded_h, padded_w = math.ceil(h / tile) * tile, math.ceil(w / tile) * tile
    padded = np.pad(frame, ((halo, padded_h - h + halo), (halo, padded_w - w + halo), (0, 0)), mode="edge")
    output = np.empty((h * 2, w * 2, 3), dtype=np.float32)
    extent = tile + 2 * halo
    completed = 0
    total = math.ceil(h / tile) * math.ceil(w / tile)
    for y in range(0, h, tile):
        for x in range(0, w, tile):
            patch = np.ascontiguousarray(padded[y:y + extent, x:x + extent])
            result = infer(patch)
            if result.shape != (extent * 2, extent * 2, 3):
                raise RuntimeError(f"Unexpected neural output shape: {result.shape}")
            if not np.isfinite(result).all():
                raise RuntimeError("Neural output contains NaN/Inf. Retry with --precision fp32.")
            oh, ow = min(tile, h - y) * 2, min(tile, w - x) * 2
            pad = halo * 2
            output[y * 2:y * 2 + oh, x * 2:x * 2 + ow] = result[pad:pad + oh, pad:pad + ow]
            completed += 1
            if progress:
                progress(completed, total)
    return output


def target_size(video: Video, resolution="2x") -> tuple[int, int]:
    if resolution == "2x":
        return video.width * 2, video.height * 2
    if resolution == "source":
        return video.width + video.width % 2, video.height + video.height % 2
    bounds = {"1080p": (1920, 1080), "1440p": (2560, 1440), "2160p": (3840, 2160)}
    bound_w, bound_h = bounds[resolution]
    factor = min(bound_w / video.width, bound_h / video.height)
    return (max(2, min(bound_w, round(video.width * factor / 2) * 2)),
            max(2, min(bound_h, round(video.height * factor / 2) * 2)))


def finish_frame(ai: np.ndarray, original: np.ndarray, strength: float, grayscale: bool,
                 output_size=None) -> np.ndarray:
    if strength < 1:
        base = original.astype(np.float32) / 255
        # Bilinear reference is used only to blend back original texture.
        # The actual enhancement always comes from the neural model.
        import torch
        import torch.nn.functional as F
        tensor = torch.from_numpy(base.transpose(2, 0, 1).copy()).unsqueeze(0)
        base = F.interpolate(tensor, scale_factor=2, mode="bilinear", align_corners=False)[0].permute(1, 2, 0).numpy()
        ai = ai * strength + base * (1 - strength)
    if output_size and (ai.shape[1], ai.shape[0]) != tuple(output_size):
        import torch
        import torch.nn.functional as F
        tensor = torch.from_numpy(ai.transpose(2, 0, 1).copy()).unsqueeze(0)
        ai = F.interpolate(tensor, size=(output_size[1], output_size[0]), mode="bicubic",
                           align_corners=False, antialias=True)[0].permute(1, 2, 0).numpy()
    ai = np.clip(ai, 0, 1)
    if grayscale:
        luma = ai[..., 0] * 0.2126 + ai[..., 1] * 0.7152 + ai[..., 2] * 0.0722
        ai = np.repeat(luma[..., None], 3, axis=2)
    return np.rint(ai * 255).astype(np.uint8)


def decoder_command(ffmpeg, source, video, start, frames):
    return [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-threads", "2",
            "-ss", str(start), "-noautorotate", "-i", str(source), "-map", "0:v:0", "-an", "-sn", "-dn",
            "-vf", f"fps={video.fps},format=rgb24", "-frames:v", str(frames),
            "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"]


def encoder_command(ffmpeg, source, target, video, start, frames, cq, codec="h264_nvenc",
                    output_size=None, preset="p7"):
    width, height = output_size or (video.width * 2, video.height * 2)
    return [ffmpeg, "-hide_banner", "-loglevel", "warning", "-nostdin", "-n",
            "-f", "rawvideo", "-pix_fmt", "rgb24", "-video_size", f"{width}x{height}",
            "-framerate", str(video.fps), "-i", "pipe:0", "-ss", str(start), "-i", str(source),
            "-map", "0:v:0", "-map", "1:a?", "-map_metadata", "-1",
            "-frames:v", str(frames), "-t", str(float(Fraction(frames, 1) / video.fps)),
            "-c:v", codec, "-preset", preset, "-tune", "hq", "-rc", "vbr", "-cq", str(cq), "-b:v", "0",
            "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
            "-vf", "scale=in_range=full:out_range=tv:out_color_matrix=bt709", "-color_range", "tv",
            "-c:a", "copy", "-movflags", "+faststart", str(target)]
