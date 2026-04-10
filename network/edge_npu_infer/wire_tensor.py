"""
Tensor wire helpers for split inference (placement.py send_tensor / recv_tensor).

Serialize NumPy arrays to bytes for gRPC/HTTP/MQTT payloads. Uses NumPy's .npy
container with allow_pickle=False (no arbitrary code execution from bytes).
"""

from __future__ import annotations

import io
from typing import Any

import numpy as np


def pack_tensor(arr: np.ndarray) -> bytes:
    """Serialize array to bytes (FP32 recommended for bandwidth planning)."""
    bio = io.BytesIO()
    np.save(bio, arr, allow_pickle=False)
    return bio.getvalue()


def unpack_tensor(data: bytes) -> np.ndarray:
    """Deserialize bytes from pack_tensor. Raises on corrupt input."""
    return np.load(io.BytesIO(data), allow_pickle=False)


def tensor_nbytes(arr: np.ndarray) -> int:
    """Raw element storage size (contiguous); for quick bandwidth estimates."""
    return int(arr.size * arr.dtype.itemsize)


def make_wire_pair() -> tuple[Any, Any]:
    """Return (send_tensor, recv_tensor) callables for in-process split testing."""

    def send_tensor(t: np.ndarray) -> bytes:
        return pack_tensor(t)

    def recv_tensor(p: bytes) -> np.ndarray:
        return unpack_tensor(p)

    return send_tensor, recv_tensor
