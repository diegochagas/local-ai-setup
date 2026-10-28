"""image-chat's workflows, session and ComfyUI client, without ComfyUI."""

import doctest
import io
import json
import pathlib
import sys
import unittest
import urllib.error
from pathlib import Path

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "image-chat"))

import comfy_api  # noqa: E402
import session  # noqa: E402
import workflows  # noqa: E402
from comfy_api import ComfyClient, ComfyError  # noqa: E402
from session import ChatSession  # noqa: E402


class FakeComfyServer:
    """Answers ComfyClient's requests from a table of path prefix -> bytes."""

    def __init__(self, answers: dict[str, bytes]) -> None:
        self.answers = answers
        self.paths: list[str] = []

    def __call__(self, request, timeout):
        path = request.full_url.removeprefix("http://comfy")
        self.paths.append(path)
        for prefix, body in self.answers.items():
            if path.startswith(prefix):
                return io.BytesIO(body)
        raise urllib.error.HTTPError(request.full_url, 400, "bad", {}, io.BytesIO(b"no such node"))


def history(status: dict, outputs: dict) -> bytes:
    return json.dumps({"p1": {"status": status, "outputs": outputs}}).encode()


class Workflows(unittest.TestCase):
    def test_every_model_ends_in_a_preview_of_the_decoded_edit(self):
        for model in workflows.MODELS:
            graph = workflows.edit_workflow(model, "in.png", (512, 768), "erase the texts", 7)
            self.assertEqual(graph["16"]["class_type"], "PreviewImage")
            self.assertEqual(graph["7"]["inputs"]["image"], "in.png")
            self.assertEqual(graph["8"]["inputs"]["height"], 768)

    def test_links_point_at_nodes_that_exist(self):
        for model in workflows.MODELS:
            graph = workflows.edit_workflow(model, "in.png", (512, 512), "x", 1)
            links = [v[0] for node in graph.values() for v in node["inputs"].values() if isinstance(v, list)]
            self.assertTrue(set(links) <= set(graph), f"{model}: {set(links) - set(graph)}")

    def test_unknown_model_names_the_known_ones(self):
        with self.assertRaisesRegex(ValueError, "klein, qwen"):
            workflows.edit_workflow("sdxl", "in.png", (16, 16), "x", 1)

    def test_small_pictures_are_not_upscaled(self):
        self.assertEqual(workflows.model_size(640, 480), (640, 480))


class Session(unittest.TestCase):
    def make(self) -> ChatSession:
        return ChatSession(Path("/out"), "cat", [Path("/in/cat.jpg")])

    def test_each_edit_becomes_the_current_picture_with_a_new_name(self):
        s = self.make()
        s.record_edit(s.next_output(), "make it red")
        self.assertEqual(s.current, Path("/out/cat-01.png"))
        self.assertEqual(s.next_output(), Path("/out/cat-02.png"))

    def test_undo_keeps_the_original_and_never_reuses_a_name(self):
        s = self.make()
        s.record_edit(s.next_output(), "a")
        self.assertTrue(s.undo())
        self.assertFalse(s.undo())
        self.assertEqual(s.current, Path("/in/cat.jpg"))
        self.assertEqual(s.next_output(), Path("/out/cat-02.png"))

    def test_only_installed_models_can_be_chosen(self):
        with self.assertRaisesRegex(ValueError, "'gpt'"):
            self.make().set_model("gpt")


class Client(unittest.TestCase):
    def test_returns_the_first_image_of_a_successful_run(self):
        server = FakeComfyServer({
            "/history/p1": history({"status_str": "success"},
                                   {"16": {"images": [{"filename": "a.png", "subfolder": "", "type": "temp"}]}}),
            "/view?filename=a.png": b"PNG",
        })
        self.assertEqual(ComfyClient("http://comfy", server).wait_for_image("p1"), b"PNG")

    def test_a_failed_run_reports_the_exception_comfyui_gives(self):
        error = ["execution_error", {"exception_type": "torch.OutOfMemoryError", "exception_message": "out of memory\n"}]
        server = FakeComfyServer({"/history/p1": history({"status_str": "error", "messages": [error]}, {})})
        with self.assertRaisesRegex(ComfyError, "torch.OutOfMemoryError: out of memory$"):
            ComfyClient("http://comfy", server).wait_for_image("p1")

    def test_waits_while_the_run_is_not_in_the_history(self):
        server = FakeComfyServer({"/history/p1": b"{}"})
        with self.assertRaisesRegex(ComfyError, "did not finish"):
            ComfyClient("http://comfy", server, sleep=lambda _: None).wait_for_image("p1", timeout_seconds=0.05)

    def test_a_refused_request_carries_comfyuis_answer(self):
        with self.assertRaisesRegex(ComfyError, "/prompt: HTTP 400: no such node"):
            ComfyClient("http://comfy", FakeComfyServer({})).queue({})

    def test_upload_returns_the_name_load_image_takes(self):
        server = FakeComfyServer({"/upload/image": b'{"name": "chat_1.png", "subfolder": "image-chat"}'})
        self.assertEqual(ComfyClient("http://comfy", server).upload(b"PNG"), "image-chat/chat_1.png")


def load_tests(loader, tests, _pattern):
    for module in (workflows, session, comfy_api):
        tests.addTests(doctest.DocTestSuite(module))
    return tests


if __name__ == "__main__":
    unittest.main()
