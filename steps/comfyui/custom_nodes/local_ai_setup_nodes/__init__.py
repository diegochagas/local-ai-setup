"""Small ComfyUI nodes that apps using this machine's ComfyUI through its
HTTP API need (local-ai-setup's steps/comfyui installs this folder into
ComfyUI's custom_nodes/).

BBoxFromJSON: box prompts for SAM 2 (ComfyUI-segment-anything-2's
Sam2Segmentation, installed by the same step). Its `bboxes` input only
takes a link - in the API format a literal list is read as a [node, slot]
link - so a client sends its boxes as a JSON string through this node.
Used by GIMPhoto's Select Subject.
"""

import json


class BBoxFromJSON:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "boxes": ("STRING", {"default": "[[0, 0, 64, 64]]",
                                 "tooltip": "JSON list of [x1, y1, x2, y2] boxes in image pixels"}),
        }}

    RETURN_TYPES = ("BBOX",)
    RETURN_NAMES = ("bboxes",)
    FUNCTION = "make"
    CATEGORY = "local-ai-setup"

    def make(self, boxes):
        parsed = json.loads(boxes)
        if not parsed or not all(isinstance(b, list) and len(b) == 4 for b in parsed):
            raise ValueError("boxes must be a JSON list of [x1, y1, x2, y2]")
        # Sam2Segmentation expects one list of boxes per image of the batch
        return ([[[float(v) for v in b] for b in parsed]],)


NODE_CLASS_MAPPINGS = {"BBoxFromJSON": BBoxFromJSON}
NODE_DISPLAY_NAME_MAPPINGS = {"BBoxFromJSON": "Boxes from JSON"}
