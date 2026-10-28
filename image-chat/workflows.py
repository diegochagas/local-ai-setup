"""ComfyUI API workflows for one image edit with the installed models.

Two edit models from setup.sh's model sets:
  klein  FLUX.2 klein 4B (fp8, distilled 4 steps), ~45 s per edit on a
         6 GB GPU; keeps the picture's structure well.
  qwen   Qwen-Image-Edit-2511 (GGUF Q4 + Lightning 4-step LoRA), ~100 s
         per edit; follows the instruction best.

Same graphs as comic-skills' restore-photos/scripts/comfy_client.py, which
was tested on both models; the result comes back through PreviewImage, so
nothing is written in ComfyUI's output folder.
"""

from typing import Any

Workflow = dict[str, dict[str, Any]]

KLEIN = {"unet": "flux-2-klein-4b-fp8.safetensors",
         "clip": "qwen_3_4b.safetensors",
         "vae": "flux2-vae.safetensors"}
QWEN = {"unet": "qwen-image-edit-2511-Q4_K_M.gguf",
        "clip": "qwen_2.5_vl_7b_fp8_scaled.safetensors",
        "vae": "qwen_image_vae.safetensors",
        "lora": "Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"}
MODELS = ("klein", "qwen")


def model_size(width: int, height: int, megapixels: float = 1.0) -> tuple[int, int]:
    """Size the model works at: at most `megapixels`, sides multiple of 16.

    >>> model_size(2000, 1000)
    (1408, 704)
    """
    scale = min(1.0, (megapixels * 1e6 / (width * height)) ** 0.5)
    return (max(16, round(width * scale / 16) * 16),
            max(16, round(height * scale / 16) * 16))


def _scaled_input(image_name: str, width: int, height: int) -> Workflow:
    return {
        "7": {"class_type": "LoadImage", "inputs": {"image": image_name}},
        "8": {"class_type": "ImageScale", "inputs": {"image": ["7", 0], "upscale_method": "lanczos",
                                                     "width": width, "height": height, "crop": "disabled"}},
    }


def _decode_and_preview(samples_node: str) -> Workflow:
    return {
        "15": {"class_type": "VAEDecode", "inputs": {"samples": [samples_node, 0], "vae": ["3", 0]}},
        "16": {"class_type": "PreviewImage", "inputs": {"images": ["15", 0]}},
    }


def klein_workflow(image_name: str, width: int, height: int, prompt: str, seed: int) -> Workflow:
    """FLUX.2 klein edit: the picture goes in as a ReferenceLatent."""
    m = KLEIN
    return {
        "1": {"class_type": "UNETLoader", "inputs": {"unet_name": m["unet"], "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader", "inputs": {"clip_name": m["clip"], "type": "flux2", "device": "default"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": m["vae"]}},
        **_scaled_input(image_name, width, height),
        "9": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["2", 0], "text": prompt}},
        "10": {"class_type": "ConditioningZeroOut", "inputs": {"conditioning": ["9", 0]}},
        "13": {"class_type": "VAEEncode", "inputs": {"pixels": ["8", 0], "vae": ["3", 0]}},
        "11": {"class_type": "ReferenceLatent", "inputs": {"conditioning": ["9", 0], "latent": ["13", 0]}},
        "12": {"class_type": "ReferenceLatent", "inputs": {"conditioning": ["10", 0], "latent": ["13", 0]}},
        "17": {"class_type": "CFGGuider", "inputs": {"model": ["1", 0], "positive": ["11", 0],
                                                     "negative": ["12", 0], "cfg": 1.0}},
        "18": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler"}},
        "19": {"class_type": "Flux2Scheduler", "inputs": {"steps": 4, "width": width, "height": height}},
        "20": {"class_type": "EmptyFlux2LatentImage", "inputs": {"width": width, "height": height, "batch_size": 1}},
        "21": {"class_type": "RandomNoise", "inputs": {"noise_seed": seed}},
        "14": {"class_type": "SamplerCustomAdvanced", "inputs": {"noise": ["21", 0], "guider": ["17", 0],
                                                                 "sampler": ["18", 0], "sigmas": ["19", 0],
                                                                 "latent_image": ["20", 0]}},
        **_decode_and_preview("14"),
    }


def _qwen_encoder(prompt: str) -> dict[str, Any]:
    return {"class_type": "TextEncodeQwenImageEditPlus",
            "inputs": {"clip": ["2", 0], "vae": ["3", 0], "image1": ["8", 0], "prompt": prompt}}


def _qwen_reference(conditioning_node: str) -> dict[str, Any]:
    return {"class_type": "FluxKontextMultiReferenceLatentMethod",
            "inputs": {"conditioning": [conditioning_node, 0], "reference_latents_method": "index_timestep_zero"}}


def qwen_workflow(image_name: str, width: int, height: int, prompt: str, seed: int) -> Workflow:
    """Qwen-Image-Edit-2511 edit, 4 steps with the Lightning LoRA."""
    m = QWEN
    return {
        "1": {"class_type": "UnetLoaderGGUF", "inputs": {"unet_name": m["unet"]}},
        "2": {"class_type": "CLIPLoader", "inputs": {"clip_name": m["clip"], "type": "qwen_image", "device": "default"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": m["vae"]}},
        "4": {"class_type": "ModelSamplingAuraFlow", "inputs": {"model": ["1", 0], "shift": 3.1}},
        "5": {"class_type": "CFGNorm", "inputs": {"model": ["4", 0], "strength": 1.0}},
        "6": {"class_type": "LoraLoaderModelOnly", "inputs": {"model": ["5", 0], "lora_name": m["lora"],
                                                              "strength_model": 1.0}},
        **_scaled_input(image_name, width, height),
        "9": _qwen_encoder(prompt),
        "10": _qwen_encoder(""),
        "11": _qwen_reference("9"),
        "12": _qwen_reference("10"),
        "13": {"class_type": "VAEEncode", "inputs": {"pixels": ["8", 0], "vae": ["3", 0]}},
        "14": {"class_type": "KSampler", "inputs": {"model": ["6", 0], "positive": ["11", 0], "negative": ["12", 0],
                                                    "latent_image": ["13", 0], "seed": seed, "steps": 4, "cfg": 1.0,
                                                    "sampler_name": "euler", "scheduler": "simple", "denoise": 1.0}},
        **_decode_and_preview("14"),
    }


def edit_workflow(model: str, image_name: str, size: tuple[int, int], prompt: str, seed: int) -> Workflow:
    """The edit graph for `model` (one of MODELS).

    >>> edit_workflow("klein", "in.png", (512, 512), "make it red", 1)["9"]["inputs"]["text"]
    'make it red'
    """
    builders = {"klein": klein_workflow, "qwen": qwen_workflow}
    if model not in builders:
        raise ValueError(f"unknown model {model!r}, expected one of {', '.join(MODELS)}")
    return builders[model](image_name, size[0], size[1], prompt, seed)
