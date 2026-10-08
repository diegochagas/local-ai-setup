"""This setup's own ComfyUI nodes (steps/comfyui/custom_nodes), without
ComfyUI."""

import importlib.util
import pathlib
import unittest

NODES = pathlib.Path(__file__).resolve().parent.parent / "steps/comfyui/custom_nodes/local_ai_setup_nodes/__init__.py"
spec = importlib.util.spec_from_file_location("local_ai_setup_nodes", NODES)
nodes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nodes)


class BBoxFromJSON(unittest.TestCase):
    def test_boxes_become_one_batch_of_float_boxes(self):
        (bboxes,) = nodes.BBoxFromJSON().make("[[1, 2, 30, 40], [5, 6, 7, 8]]")
        self.assertEqual(bboxes, [[[1.0, 2.0, 30.0, 40.0], [5.0, 6.0, 7.0, 8.0]]])

    def test_bad_boxes_are_refused(self):
        for bad in ("[]", "[[1, 2, 3]]", '["a"]'):
            with self.assertRaises(ValueError):
                nodes.BBoxFromJSON().make(bad)

    def test_registered_under_the_name_apps_use(self):
        self.assertIs(nodes.NODE_CLASS_MAPPINGS["BBoxFromJSON"], nodes.BBoxFromJSON)


if __name__ == "__main__":
    unittest.main()
