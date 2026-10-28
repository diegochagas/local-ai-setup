"""The few calls of ComfyUI's HTTP API the image chat needs, stdlib only."""

import json
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any, Callable

from workflows import Workflow

POLL_SECONDS = 1.0


class ComfyError(RuntimeError):
    """ComfyUI refused or failed a run; the message carries its reason."""


class ComfyClient:
    """Uploads an image, runs a workflow and downloads its preview image.

    `urlopen` is injectable so tests can answer without a server.
    """

    def __init__(self, base_url: str, urlopen: Callable[..., Any] = urllib.request.urlopen,
                 sleep: Callable[[float], None] = time.sleep) -> None:
        self.base_url = base_url.rstrip("/")
        self._urlopen = urlopen
        self._sleep = sleep

    def _request(self, path: str, body: bytes | None = None, headers: dict[str, str] | None = None) -> bytes:
        request = urllib.request.Request(self.base_url + path, body, headers or {})
        try:
            with self._urlopen(request, timeout=60) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            raise ComfyError(f"{path}: HTTP {error.code}: {error.read().decode(errors='replace')[:500]}") from error

    def upload(self, png: bytes) -> str:
        """Uploads PNG bytes into ComfyUI's input/image-chat/; returns the name LoadImage takes."""
        boundary = uuid.uuid4().hex
        name = f"chat_{uuid.uuid4().hex[:12]}.png"
        body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"subfolder\"\r\n\r\nimage-chat\r\n"
                f"--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"{name}\"\r\n"
                f"Content-Type: image/png\r\n\r\n").encode() + png + f"\r\n--{boundary}--\r\n".encode()
        answer = json.loads(self._request("/upload/image", body,
                                          {"Content-Type": f"multipart/form-data; boundary={boundary}"}))
        return f"{answer['subfolder']}/{answer['name']}" if answer.get("subfolder") else answer["name"]

    def queue(self, workflow: Workflow) -> str:
        """Queues a workflow; returns its prompt id."""
        body = json.dumps({"prompt": workflow}).encode()
        answer = json.loads(self._request("/prompt", body, {"Content-Type": "application/json"}))
        return answer["prompt_id"]

    def wait_for_image(self, prompt_id: str, timeout_seconds: float = 900) -> bytes:
        """Waits for a queued run and returns the bytes of its first image."""
        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            history = json.loads(self._request(f"/history/{prompt_id}"))
            if prompt_id in history:
                return self._first_image(history[prompt_id])
            self._sleep(POLL_SECONDS)
        raise ComfyError(f"run {prompt_id} did not finish within {timeout_seconds:.0f}s")

    def _first_image(self, entry: dict[str, Any]) -> bytes:
        status = entry.get("status", {})
        if status.get("status_str") != "success":
            raise ComfyError(f"run failed: {_failure_reason(status)}")
        images = [image for output in entry["outputs"].values() for image in output.get("images", [])]
        if not images:
            raise ComfyError(f"run finished without an image; outputs: {list(entry['outputs'])}")
        image = images[0]
        query = urllib.parse.urlencode({key: image[key] for key in ("filename", "subfolder", "type")})
        return self._request(f"/view?{query}")

    def interrupt(self) -> None:
        """Stops the run in progress (Ctrl+C during an edit)."""
        self._request("/interrupt", b"", {"Content-Type": "application/json"})


def _failure_reason(status: dict[str, Any]) -> str:
    """The exception ComfyUI reports, e.g. torch.OutOfMemoryError: ..."""
    for kind, details in status.get("messages", []):
        if kind == "execution_error":
            return f"{details.get('exception_type')}: {details.get('exception_message', '').strip()}"
    return json.dumps(status)[-500:]
