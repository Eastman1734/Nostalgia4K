"""Line-delimited messages for the Windows desktop front end."""
import json

enabled = False


def emit(kind, **data):
    if enabled:
        print("\n@@N4K@@" + json.dumps({"type": kind, **data}, ensure_ascii=True), flush=True)
