"""Run with: python -m unittest discover -s tests -v"""
import io
import json
import os
import shutil
import subprocess
import tempfile
import sys
import unittest
from fractions import Fraction
from pathlib import Path
import numpy as np
from core import (read_frame, find_original, tiled_upscale, finish_frame, probe,
                  decoder_command, encoder_command, target_size, Video)


class SmallReads(io.BytesIO):
    def read(self, n=-1):
        return super().read(min(7, n))


class CoreTests(unittest.TestCase):
    def test_resolution_choices_preserve_aspect_and_even_encoder_dimensions(self):
        wide = Video(1920, 1080, Fraction(24000, 1001), 10, True)
        self.assertEqual(target_size(wide, '2160p'), (3840, 2160))
        self.assertEqual(target_size(wide, '1440p'), (2560, 1440))
        self.assertEqual(target_size(wide, '1080p'), (1920, 1080))
        self.assertEqual(target_size(wide, 'source'), (1920, 1080))
        classic = Video(640, 480, Fraction(25), 10, False)
        self.assertEqual(target_size(classic, '2160p'), (2880, 2160))
        portrait = Video(1080, 1920, Fraction(25), 10, False)
        w, h = target_size(portrait, '2160p')
        self.assertEqual(h, 2160)
        self.assertEqual(w % 2, 0)
        self.assertAlmostEqual(w / h, 1080 / 1920, delta=.001)

    def test_selected_output_size_is_applied_after_neural_enhancement(self):
        original = np.full((16, 24, 3), (200, 10, 30), np.uint8)
        ai = np.full((32, 48, 3), (.8, .1, .2), np.float32)
        color = finish_frame(ai, original, 1, False, (24, 16))
        gray = finish_frame(ai, original, 1, True, (36, 24))
        self.assertEqual(color.shape, (16, 24, 3))
        self.assertGreater(int(color[0, 0, 0]), int(color[0, 0, 1]))
        self.assertEqual(gray.shape, (24, 36, 3))
        np.testing.assert_array_equal(gray[..., 0], gray[..., 2])

    def test_gui_protocol_is_one_ascii_json_record_per_event(self):
        from contextlib import redirect_stdout
        import events
        previous = events.enabled
        stream = io.StringIO()
        try:
            events.enabled = True
            with redirect_stdout(stream):
                events.emit('done', path='C:\\Видео\\фильм.mp4')
                events.emit('progress', current=1, total=2, percent=50)
        finally:
            events.enabled = previous
        records = [json.loads(line[7:]) for line in stream.getvalue().splitlines() if line.startswith('@@N4K@@')]
        self.assertEqual(records[0]['path'], 'C:\\Видео\\фильм.mp4')
        self.assertEqual(records[1]['percent'], 50)
        self.assertTrue(stream.getvalue().isascii())
    def test_frame_reader_handles_fragmented_pipe_reads_and_rejects_truncation(self):
        self.assertEqual(read_frame(SmallReads(b"a" * 101), 101), b"a" * 101)
        self.assertIsNone(read_frame(SmallReads(b""), 101))
        with self.assertRaisesRegex(RuntimeError, "incomplete"):
            read_frame(SmallReads(b"a" * 100), 101)

    def test_tile_stitching_covers_odd_edges_without_offsets_or_gaps(self):
        frame = np.random.default_rng(5).integers(0, 256, (39, 65, 3), dtype=np.uint8)
        nearest = lambda x: np.repeat(np.repeat(x.astype(np.float32) / 255, 2, 0), 2, 1)
        for halo in (0, 2, 32):
            result = tiled_upscale(frame, nearest, 16, halo)
            np.testing.assert_array_equal(result, nearest(frame))

    def test_nan_output_is_rejected(self):
        frame = np.zeros((16, 16, 3), np.uint8)
        with self.assertRaisesRegex(RuntimeError, "NaN"):
            tiled_upscale(frame, lambda p: np.full((32, 32, 3), np.nan), 16, 0)

    def test_grayscale_and_strength_endpoints(self):
        frame = np.full((16, 16, 3), (180, 30, 10), np.uint8)
        ai = np.full((32, 32, 3), (0, 1, 0), np.float32)
        result = finish_frame(ai, frame, 1, True)
        np.testing.assert_array_equal(result[..., 0], result[..., 1])
        np.testing.assert_array_equal(result[..., 1], result[..., 2])
        self.assertEqual(int(result[0, 0, 0]), round(255 * 0.7152))
        result = finish_frame(ai, frame, 0, False)
        np.testing.assert_array_equal(result, np.tile(frame[0, 0], (32, 32, 1)))

    def test_original_selection_ignores_both_parallel_copies_and_temporary_outputs(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            original = root / "Sample film [12345].mp4"
            for name in (original.name, original.stem + "_bw.mp4", original.stem + "_bw_nvenc.mp4",
                         original.stem + "_ai4k_bw_preview.mp4", original.stem + "_bw.aabb.part.mp4"):
                (root / name).touch()
            self.assertEqual(find_original(root), original)

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "FFmpeg required")
    def test_real_media_pipeline_keeps_fractional_fps_audio_and_grayscale(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "Тест [1].mp4"
            output = Path(folder) / "Тест [1]_out.mp4"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=24000/1001",
                            "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000", "-t", "1.5",
                            "-c:v", "libx264", "-threads", "1", "-c:a", "aac", str(source)], check=True)
            original_size = source.stat().st_size
            video = probe("ffprobe", source)
            self.assertEqual(video.fps, Fraction(24000, 1001))
            decode = decoder_command("ffmpeg", source, video, 0.25, 12)
            encode = encoder_command("ffmpeg", source, output, video, 0.25, 12, 18)
            # Exercise the same mux/filter pipeline using a CPU encoder in CI.
            for option in ("-tune", "-rc", "-cq", "-b:v"):
                index = encode.index(option)
                del encode[index:index + 2]
            encode[encode.index("h264_nvenc")] = "libx264"
            encode[encode.index("p7")] = "ultrafast"
            encode[-1:-1] = ["-threads", "1"]
            d = subprocess.Popen(decode, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            e = subprocess.Popen(encode, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                for _ in range(12):
                    data = read_frame(d.stdout, video.width * video.height * 3)
                    self.assertIsNotNone(data)
                    rgb = np.frombuffer(data, np.uint8).reshape(video.height, video.width, 3)
                    ai = np.repeat(np.repeat(rgb.astype(np.float32) / 255, 2, 0), 2, 1)
                    e.stdin.write(finish_frame(ai, rgb, 1, True).tobytes())
                e.stdin.close()
                d.stdout.close()
                self.assertEqual(d.wait(timeout=30), 0, d.stderr.read().decode())
                self.assertEqual(e.wait(timeout=30), 0, e.stderr.read().decode())
            finally:
                for process in (d, e):
                    if process.poll() is None:
                        process.kill()
                        process.wait()
                    for handle in (process.stdin, process.stdout, process.stderr):
                        if handle is not None and not handle.closed:
                            handle.close()
            info = probe("ffprobe", output)
            self.assertEqual((info.width, info.height), (128, 96))
            self.assertEqual(info.fps, video.fps)
            self.assertTrue(info.audio)
            self.assertAlmostEqual(info.duration, 12 / float(video.fps), delta=0.05)
            self.assertEqual(source.stat().st_size, original_size)
            frame = subprocess.check_output(["ffmpeg", "-v", "error", "-i", str(output), "-frames:v", "1",
                                              "-pix_fmt", "yuv420p", "-f", "rawvideo", "pipe:1"])
            np.testing.assert_array_equal(np.frombuffer(frame, np.uint8)[128 * 96:], 128)

    @unittest.skipUnless(shutil.which('ffmpeg'), 'FFmpeg required')
    def test_inspect_mode_emits_gui_metadata_without_cuda(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / 'inspect.mp4'
            subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=64x48:rate=24',
                            '-t', '0.2', '-c:v', 'libx264', '-threads', '1', str(source)], check=True)
            result = subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] / 'app.py'),
                                     '--inspect', '--events', '--input', str(source)],
                                    capture_output=True, text=True, check=True)
            records = [json.loads(line[7:]) for line in result.stdout.splitlines() if line.startswith('@@N4K@@')]
            self.assertEqual(records[0]['type'], 'metadata')
            self.assertEqual(records[0]['outputs']['2160p'], [2880, 2160])
            self.assertFalse(records[0]['audio'])


class WeightTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("SR_TEST_WEIGHTS"), "Set SR_TEST_WEIGHTS to the downloaded x2 checkpoint")
    def test_published_weights_load_and_produce_finite_double_resolution(self):
        import torch
        from sr_model import load_model
        torch.set_num_threads(2)
        torch.backends.nnpack.set_flags(False)
        model = load_model(Path(os.environ["SR_TEST_WEIGHTS"]))
        with torch.inference_mode():
            result = model(torch.rand(1, 3, 16, 24))
        self.assertEqual(tuple(result.shape), (1, 3, 32, 48))
        self.assertTrue(torch.isfinite(result).all().item())

    @unittest.skipUnless(os.environ.get("SR_TEST_WEIGHTS") and shutil.which("ffmpeg"), "Real weights and FFmpeg required")
    def test_application_loop_with_real_neural_model_and_audio(self):
        import torch
        from types import SimpleNamespace
        from unittest.mock import patch
        import app
        from sr_model import load_model
        torch.set_num_threads(2)
        torch.backends.nnpack.set_flags(False)
        model = load_model(Path(os.environ["SR_TEST_WEIGHTS"]))

        @torch.inference_mode()
        def infer(rgb):
            x = torch.from_numpy(rgb.transpose(2, 0, 1).copy()).unsqueeze(0).float() / 255
            return model(x)[0].permute(1, 2, 0).numpy()

        actual_popen = subprocess.Popen

        def cpu_encoder_for_ci(command, **kwargs):
            command = list(command)
            if "h264_nvenc" in command:
                for option in ("-tune", "-rc", "-cq", "-b:v", "-gpu"):
                    index = command.index(option)
                    del command[index:index + 2]
                command[command.index("h264_nvenc")] = "libx264"
                command[command.index('-preset') + 1] = "ultrafast"
                command[-1:-1] = ["-threads", "1"]
            return actual_popen(command, **kwargs)

        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source, target = root / "original.mp4", root / "result.mp4"
            subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=16x16:rate=24",
                            "-f", "lavfi", "-i", "sine=frequency=440", "-t", "0.5", "-c:v", "libx264",
                            "-threads", "1", "-c:a", "aac", str(source)], check=True)
            video = probe("ffprobe", source)
            for color, resolution, preset, cq in [(False, '2x', 'p7', 18), (True, 'source', 'p5', 22)]:
                target = root / ('color.mp4' if color else 'gray.mp4')
                args = SimpleNamespace(start=0, seconds=.2, cq=cq, device=0, audio_codec="copy", tile=16,
                                       halo=0, strength=1, color=color, backend="qa-cpu", precision="fp32",
                                       resolution=resolution, preset=preset)
                with patch.object(app, "ROOT", root), patch.object(app.subprocess, "Popen", cpu_encoder_for_ci):
                    app.convert(args, source, target, video, infer, "ffmpeg")
                self.assertTrue(target.is_file())
                result = probe("ffprobe", target)
                self.assertEqual((result.width, result.height), (16, 16) if color else (32, 32))
                self.assertTrue(result.audio)
                report = json.loads(target.with_suffix(".json").read_text())
                self.assertEqual(report['frames'], 5)
                self.assertEqual(report['preset'], preset)
                self.assertEqual(report['cq'], cq)
            self.assertFalse(list(root.glob("*.part.mp4")))


if __name__ == "__main__":
    unittest.main()
