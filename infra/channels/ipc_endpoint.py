from __future__ import annotations

import asyncio
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Awaitable, Callable, Literal

from agent.config import DEFAULT_SOCKET


@dataclass(frozen=True)
class IPCEndpoint:
    kind: Literal["tcp", "unix"]
    host: str = "127.0.0.1"
    port: int = 8765
    path: str = ""


ConnectionHandler = Callable[
    [asyncio.StreamReader, asyncio.StreamWriter], Awaitable[None]
]


def resolve_ipc_endpoint(address: str | None = None) -> IPCEndpoint:
    text = (address or DEFAULT_SOCKET).strip() or DEFAULT_SOCKET
    if text.startswith("tcp://"):
        return _parse_tcp_address(text.removeprefix("tcp://"))
    if _looks_like_tcp_address(text):
        return _parse_tcp_address(text)
    if os.name == "nt":
        return _parse_tcp_address(DEFAULT_SOCKET)
    return IPCEndpoint(kind="unix", path=text)


async def start_ipc_server(
    handler: ConnectionHandler,
    address: str | None = None,
) -> tuple[asyncio.Server, IPCEndpoint]:
    endpoint = resolve_ipc_endpoint(address)
    if endpoint.kind == "tcp":
        server = await asyncio.start_server(handler, endpoint.host, endpoint.port)
        return server, endpoint

    Path(endpoint.path).unlink(missing_ok=True)
    server = await asyncio.start_unix_server(handler, path=endpoint.path)
    os.chmod(endpoint.path, 0o600)
    return server, endpoint


async def open_ipc_connection(
    address: str | None = None,
) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    endpoint = resolve_ipc_endpoint(address)
    if endpoint.kind == "tcp":
        return await asyncio.open_connection(endpoint.host, endpoint.port)
    return await asyncio.open_unix_connection(endpoint.path)


def cleanup_ipc_endpoint(endpoint: IPCEndpoint | None) -> None:
    if endpoint and endpoint.kind == "unix":
        Path(endpoint.path).unlink(missing_ok=True)


def describe_ipc_address(address: str | None = None) -> str:
    return describe_ipc_endpoint(resolve_ipc_endpoint(address))


def describe_ipc_endpoint(endpoint: IPCEndpoint) -> str:
    if endpoint.kind == "tcp":
        return f"tcp://{endpoint.host}:{endpoint.port}"
    return endpoint.path


def _looks_like_tcp_address(text: str) -> bool:
    if ":" not in text:
        return False
    host, port = text.rsplit(":", 1)
    return bool(host) and port.isdigit()


def _parse_tcp_address(text: str) -> IPCEndpoint:
    host, port_text = text.rsplit(":", 1)
    return IPCEndpoint(kind="tcp", host=host or "127.0.0.1", port=int(port_text))
