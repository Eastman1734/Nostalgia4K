"""CUDA inference with TensorRT 10.x; optional PyTorch CUDA backend."""
from __future__ import annotations
import hashlib
import json
import os
import platform
import time
import urllib.request
import uuid
from pathlib import Path
import numpy as np
import torch
import events
from sr_model import load_model

MODEL_URL = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth"
MODEL_SHA256 = "49fafd45f8fd7aa8d31ab2a22d14d91b536c34494a5cfe31eb5d89c2fa266abb"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_bytes(path: Path, data):
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        temporary.write_bytes(data)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def weights(root: Path) -> Path:
    folder = root / "models"
    folder.mkdir(exist_ok=True)
    path = folder / "RealESRGAN_x2plus.pth"
    if path.exists() and sha256(path) == MODEL_SHA256:
        return path
    print("Downloading Real-ESRGAN x2 weights (64 MiB)...", flush=True)
    events.emit("stage", name="model_download", message="Downloading AI model")
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        request = urllib.request.Request(MODEL_URL, headers={"User-Agent": "Nostalgia4K/1.0"})
        with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as file:
            while chunk := response.read(1024 * 1024):
                file.write(chunk)
        if sha256(temporary) != MODEL_SHA256:
            raise RuntimeError("Model SHA256 mismatch; the downloaded weights will not be loaded.")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
    return path


def cuda_check(device: int):
    if not torch.cuda.is_available():
        raise RuntimeError("CUDA is unavailable. Run Install.ps1 and update your NVIDIA driver.")
    torch.cuda.set_device(device)
    props = torch.cuda.get_device_properties(device)
    print(f"GPU: {props.name}; VRAM {props.total_memory / 2**30:.1f} GiB; CUDA {torch.version.cuda}", flush=True)
    events.emit("gpu", name=props.name, vram=round(props.total_memory / 2**30, 1))
    # A real allocation/kernel catches an unsupported GPU architecture early.
    test = torch.ones(16, device=f"cuda:{device}") * 2
    torch.cuda.synchronize(device)
    if test.sum().item() != 32:
        raise RuntimeError("CUDA test failed")
    return props


class TorchCuda:
    def __init__(self, path, extent, device=0, precision="fp16"):
        cuda_check(device)
        self.device = f"cuda:{device}"
        self.dtype = torch.float16 if precision == "fp16" else torch.float32
        self.model = load_model(path).to(device=self.device, dtype=self.dtype)

    @torch.inference_mode()
    def __call__(self, patch):
        x = torch.from_numpy(patch.transpose(2, 0, 1).copy()).unsqueeze(0).to(self.device, self.dtype) / 255
        return self.model(x)[0].float().permute(1, 2, 0).cpu().numpy()


class TensorRT:
    def __init__(self, path, extent, cache, device=0, precision="fp16"):
        props = cuda_check(device)
        # Import after torch so its CUDA runtime DLLs are already loaded on Windows.
        import tensorrt as trt
        self.trt = trt
        if not trt.__version__.startswith("10."):
            raise RuntimeError("This version uses TensorRT 10.x. Re-run Install.ps1 to install the pinned version.")
        self.logger = trt.Logger(trt.Logger.WARNING)
        key = {"weights": sha256(path), "extent": extent, "precision": precision,
               "gpu": props.name, "sm": [props.major, props.minor], "trt": trt.__version__,
               "cuda": torch.version.cuda, "platform": platform.platform(), "app": 1}
        token = hashlib.sha256(json.dumps(key, sort_keys=True).encode()).hexdigest()[:24]
        cache.mkdir(parents=True, exist_ok=True)
        engine_path = cache / f"x2-{token}.plan"
        self.runtime = trt.Runtime(self.logger)
        engine = None
        if engine_path.exists():
            print("Loading cached TensorRT engine...", flush=True)
            events.emit("stage", name="engine_load", message="Loading cached engine")
            engine = self.runtime.deserialize_cuda_engine(engine_path.read_bytes())
        if engine is None:
            self.build(path, extent, precision, cache / f"x2-{extent}.onnx", engine_path)
            engine = self.runtime.deserialize_cuda_engine(engine_path.read_bytes())
        if engine is None:
            raise RuntimeError("TensorRT could not deserialize the engine.")
        self.engine = engine
        self.context = engine.create_execution_context()
        if self.context is None:
            raise RuntimeError("TensorRT could not allocate an execution context. Try --tile 128.")
        self.stream = torch.cuda.Stream(device=device)
        inputs = [engine.get_tensor_name(i) for i in range(engine.num_io_tensors)
                  if engine.get_tensor_mode(engine.get_tensor_name(i)) == trt.TensorIOMode.INPUT]
        outputs = [engine.get_tensor_name(i) for i in range(engine.num_io_tensors)
                   if engine.get_tensor_mode(engine.get_tensor_name(i)) == trt.TensorIOMode.OUTPUT]
        if len(inputs) != 1 or len(outputs) != 1:
            raise RuntimeError("Expected one input and one output tensor")
        self.input_name, self.output_name = inputs[0], outputs[0]
        mapping = {trt.float32: torch.float32, trt.float16: torch.float16}
        self.x = torch.empty(tuple(engine.get_tensor_shape(self.input_name)),
                             dtype=mapping[engine.get_tensor_dtype(self.input_name)], device=f"cuda:{device}")
        self.y = torch.empty(tuple(engine.get_tensor_shape(self.output_name)),
                             dtype=mapping[engine.get_tensor_dtype(self.output_name)], device=f"cuda:{device}")
        self.context.set_tensor_address(self.input_name, self.x.data_ptr())
        self.context.set_tensor_address(self.output_name, self.y.data_ptr())
        self.stream.wait_stream(torch.cuda.current_stream(device))

    def build(self, path, extent, precision, onnx_path, engine_path):
        trt = self.trt
        print(f"Exporting ONNX, tile input {extent}x{extent}...", flush=True)
        events.emit("stage", name="export", message="Preparing ONNX model")
        model = load_model(path)
        temporary_onnx = onnx_path.with_name(onnx_path.name + "." + uuid.uuid4().hex + ".tmp")
        try:
            with torch.inference_mode(), torch.backends.nnpack.flags(enabled=False):
                torch.onnx.export(model, torch.zeros(1, 3, extent, extent), str(temporary_onnx),
                                  input_names=["rgb"], output_names=["sr"], opset_version=17,
                                  dynamo=False, do_constant_folding=True)
            os.replace(temporary_onnx, onnx_path)
        finally:
            temporary_onnx.unlink(missing_ok=True)
        del model
        builder = trt.Builder(self.logger)
        network = builder.create_network(1 << int(trt.NetworkDefinitionCreationFlag.EXPLICIT_BATCH))
        parser = trt.OnnxParser(network, self.logger)
        if not parser.parse(onnx_path.read_bytes()):
            raise RuntimeError("ONNX parse failed:\n" + "\n".join(str(parser.get_error(i)) for i in range(parser.num_errors)))
        config = builder.create_builder_config()
        config.set_memory_pool_limit(trt.MemoryPoolType.WORKSPACE, 2 * 2**30)
        # Strict FP32 mode is available for diagnosis; FP16 uses Tensor Cores.
        config.clear_flag(trt.BuilderFlag.TF32)
        if precision == "fp16":
            if not builder.platform_has_fast_fp16:
                raise RuntimeError("This GPU does not support fast FP16.")
            config.set_flag(trt.BuilderFlag.FP16)
        config.builder_optimization_level = 3
        print("Building TensorRT engine. First run can take several minutes; later runs use the cache.", flush=True)
        events.emit("stage", name="engine_build", message="Optimizing model for this GPU")
        begun = time.monotonic()
        serialized = builder.build_serialized_network(network, config)
        if serialized is None:
            raise RuntimeError("TensorRT build failed. Try --tile 128 or --backend torch.")
        atomic_bytes(engine_path, bytes(serialized))
        print(f"TensorRT engine ready in {time.monotonic() - begun:.0f}s", flush=True)

    @torch.inference_mode()
    def __call__(self, patch):
        host = torch.from_numpy(patch.transpose(2, 0, 1).copy()).unsqueeze(0)
        with torch.cuda.stream(self.stream):
            self.x.copy_(host)
            self.x.div_(255)
            if not self.context.execute_async_v3(stream_handle=self.stream.cuda_stream):
                raise RuntimeError("TensorRT execute_async_v3 failed")
            output = self.y[0].float().permute(1, 2, 0).contiguous().cpu()
        self.stream.synchronize()
        return output.numpy()
