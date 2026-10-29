# Nostalgia4K Desktop

**English** · [Русский](README-RU.md)

Neural video upscaling (×2) for Windows x64 and NVIDIA RTX GPUs, with optional black-and-white output and MP4 export through hardware H.264 NVENC. Model: Real-ESRGAN x2plus. Execution: NVIDIA TensorRT 10.13 and CUDA 12.8 (PyTorch as a fallback backend).

This is an independent program; the neural network model was created by the Real-ESRGAN authors, not by NVIDIA, and no training is performed. This is an experimental build: start with the diagnostic check and a short preview.

![Nostalgia4K main window](docs/screenshots/main.png)

## Install and run (graphical installer)

1. Extract the **whole** repository or archive into a folder.
2. Double-click **Setup.cmd**. A Windows Forms installer opens (Windows PowerShell 5.1; no extra UI library is needed).
3. Click **Install / update**, wait for the checks, then **Open Nostalgia4K**. The installer creates a separate Python environment, downloads PyTorch (CUDA 12.8), TensorRT, FFmpeg and FFprobe (several gigabytes in total), and checks that CUDA and NVENC really work. If Python 3.11/3.12 is missing it tries to install Python 3.12 through winget for the current user.
4. For later launches use the desktop shortcut or **Start.cmd**.

Requirements: Windows 10/11 x64, an NVIDIA RTX GPU, and a driver that supports CUDA 12.8 (a current Studio Driver is recommended). A full CUDA Toolkit is not needed.

## Main window

- Choose a file or drag a video into the window. Colour or black-and-white output (colour by default).
- Resolution: 4K, 1440p, 1080p, source size, or exactly ×2. Aspect ratio is preserved (4:3 at "4K" becomes 2880×2160, not stretched to 16:9).
- Compression quality (NVENC settings, not the neural network): High · recommended (p7, CQ 18), Compact file (p5, CQ 22), Very high · larger file (p7, CQ 15).
- AI strength: from a softer result to the full model effect (default 0.75, i.e. 75% AI result and 25% enlarged original).
- Preview: 20 seconds from 00:03:00 by default; start and length can be changed. Output folder, progress, remaining time, stop button, log and "open result".

Results are never overwritten: a number is added if the name is taken. AAC/MP3/ALAC audio is copied; other codecs are re-encoded to AAC for MP4 compatibility. The first TensorRT engine build can take several minutes and is cached per GPU and settings.

## Command line

Run a diagnostic check, then a preview, then the full video (`Start.ps1` parameters):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start.ps1 -Doctor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start.ps1 -Preview
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start.ps1 -InputFile "D:\Video\movie.mp4"
```

| Parameter | Purpose |
|---|---|
| `-Preview -Start 600 -Seconds 15` | Preview of 15 seconds from 10:00 |
| `-Strength 0.5` / `-Strength 1` | Softer effect / full neural result |
| `-Color` | Keep colour |
| `-CQ 16` | Less compression loss, usually a larger file |
| `-Tile 128`, `-Halo 64` | Lower VRAM use / more context at tile edges (slower) |
| `-Precision fp32` | Numerical diagnostics; slower, more memory |
| `-Backend torch` | CUDA through PyTorch instead of TensorRT |
| `-OutputFile "D:\Video\out.mp4"` | Another output name; existing files are never overwritten |
| `-Doctor` / `-Prepare` | Check CUDA, TensorRT and NVENC / only download the model and build the engine |

Without `-InputFile` the program uses the single source video in the folder. Output names look like `name_ai4k_bw.mp4`; the original is not modified.

## Limitations

- The algorithm is frame-by-frame; temporal consistency is not modelled, so flicker is possible. AI can invent small details and smooth film grain. Check faces, edges, motion and background in a preview before processing a whole film.
- Frame rate is preserved (fractional rates such as 24000/1001 included); variable frame rate is normalised to a constant average rate. No frame interpolation.
- The first video stream and all audio streams are processed. Subtitles and chapters are not carried over.
- SDR BT.709 is the target. HDR and rotated video are out of scope. Non-standard sizes are scaled exactly ×2.
- Ctrl+C stops the process; resuming is not implemented. An unfinished `.part.mp4` is kept for diagnostics, and only a successfully completed result gets its final name. FFmpeg logs are in `logs`, run parameters in a JSON next to the finished MP4.
- Everything runs locally; video is not uploaded anywhere.

## What was verified

In the development environment (Linux, no GPU) 12 automated tests pass: published Real-ESRGAN weights and a full neural conversion loop on CPU, colour vs grayscale, output dimensions, compression presets, fractional FPS, audio retention and incomplete-frame handling. All Python modules compile and the PowerShell files pass a syntax check. The Windows Forms interface, the installer and TensorRT/CUDA/NVENC execution were **not** tested there: run `-Doctor` and a short preview on your PC. Speed and absence of artefacts are not guaranteed.

## License and notices

The original source code is licensed under the [Apache License 2.0](LICENSE) (see also [NOTICE](NOTICE)). The model weights, PyTorch, TensorRT, FFmpeg and other dependencies are not included in this repository; the installer downloads them from their official sources and they remain under their own licenses. `sr_model.py` adapts the RRDB architecture from [BasicSR](https://github.com/XPixelGroup/BasicSR) ([LICENSE-BasicSR.txt](LICENSE-BasicSR.txt)); the model is from [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) ([LICENSE-RealESRGAN.txt](LICENSE-RealESRGAN.txt)). NVIDIA, TensorRT, CUDA and NVENC are trademarks of NVIDIA Corporation; this project is not endorsed by NVIDIA.
