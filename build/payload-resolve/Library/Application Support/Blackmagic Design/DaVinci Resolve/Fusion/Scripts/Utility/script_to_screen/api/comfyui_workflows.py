"""ComfyUI workflow templates for Flux Kontext and LTX Video.

Workflows are Python dicts in ComfyUI API format.
Each node is keyed by a string ID and has 'class_type' and 'inputs'.
Node connections use ["source_node_id", output_index] tuples.
"""

import random


# ── Flux Kontext Workflows ───────────────────────────────────────

def flux_kontext_txt2img(
    prompt: str,
    width: int = 1024,
    height: int = 576,
    steps: int = 28,
    cfg: float = 1.0,
    seed: int = -1,
    model_name: str = "flux1-dev-kontext_fp8_scaled.safetensors",
    clip_name1: str = "clip_l.safetensors",
    clip_name2: str = "t5xxl_fp8_e4m3fn_scaled.safetensors",
    vae_name: str = "ae.safetensors",
) -> dict:
    """Flux Kontext text-to-image workflow."""
    if seed < 0:
        seed = random.randint(0, 2**32)

    return {
        "1": {
            "class_type": "UNETLoader",
            "inputs": {
                "unet_name": model_name,
                "weight_dtype": "fp8_e4m3fn",
            },
        },
        "2": {
            "class_type": "DualCLIPLoader",
            "inputs": {
                "clip_name1": clip_name1,
                "clip_name2": clip_name2,
                "type": "flux",
            },
        },
        "3": {
            "class_type": "VAELoader",
            "inputs": {"vae_name": vae_name},
        },
        "4": {
            "class_type": "CLIPTextEncode",
            "inputs": {
                "text": prompt,
                "clip": ["2", 0],
            },
        },
        "5": {
            "class_type": "EmptySD3LatentImage",
            "inputs": {
                "width": width,
                "height": height,
                "batch_size": 1,
            },
        },
        "6": {
            "class_type": "KSampler",
            "inputs": {
                "model": ["1", 0],
                "positive": ["4", 0],
                "negative": ["4", 0],
                "latent_image": ["5", 0],
                "seed": seed,
                "steps": steps,
                "cfg": cfg,
                "sampler_name": "euler",
                "scheduler": "simple",
                "denoise": 1.0,
            },
        },
        "7": {
            "class_type": "VAEDecode",
            "inputs": {
                "samples": ["6", 0],
                "vae": ["3", 0],
            },
        },
        "8": {
            "class_type": "SaveImage",
            "inputs": {
                "images": ["7", 0],
                "filename_prefix": "sts_flux",
            },
        },
    }


def flux_kontext_img_ref(
    prompt: str,
    input_image_name: str,
    width: int = 1024,
    height: int = 576,
    steps: int = 28,
    cfg: float = 1.0,
    denoise: float = 0.75,
    seed: int = -1,
    model_name: str = "flux1-dev-kontext_fp8_scaled.safetensors",
    clip_name1: str = "clip_l.safetensors",
    clip_name2: str = "t5xxl_fp8_e4m3fn_scaled.safetensors",
    vae_name: str = "ae.safetensors",
) -> dict:
    """Flux Kontext image-referenced generation workflow.

    Uses a reference image for style/character consistency via
    LoadImage -> FluxKontextImageScale -> VAEEncode -> ReferenceLatent.
    """
    if seed < 0:
        seed = random.randint(0, 2**32)

    return {
        "1": {
            "class_type": "UNETLoader",
            "inputs": {
                "unet_name": model_name,
                "weight_dtype": "fp8_e4m3fn",
            },
        },
        "2": {
            "class_type": "DualCLIPLoader",
            "inputs": {
                "clip_name1": clip_name1,
                "clip_name2": clip_name2,
                "type": "flux",
            },
        },
        "3": {
            "class_type": "VAELoader",
            "inputs": {"vae_name": vae_name},
        },
        "4": {
            "class_type": "CLIPTextEncode",
            "inputs": {
                "text": prompt,
                "clip": ["2", 0],
            },
        },
        # Load and encode the reference image
        "10": {
            "class_type": "LoadImage",
            "inputs": {
                "image": input_image_name,
            },
        },
        "11": {
            "class_type": "FluxKontextImageScale",
            "inputs": {
                "image": ["10", 0],
            },
        },
        "12": {
            "class_type": "VAEEncode",
            "inputs": {
                "pixels": ["11", 0],
                "vae": ["3", 0],
            },
        },
        "13": {
            "class_type": "ReferenceLatent",
            "inputs": {
                "latent": ["12", 0],
            },
        },
        # Empty latent for the output size
        "5": {
            "class_type": "EmptySD3LatentImage",
            "inputs": {
                "width": width,
                "height": height,
                "batch_size": 1,
            },
        },
        # Concatenate reference latent with empty latent
        "14": {
            "class_type": "LatentBatch",
            "inputs": {
                "samples1": ["13", 0],
                "samples2": ["5", 0],
            },
        },
        "6": {
            "class_type": "KSampler",
            "inputs": {
                "model": ["1", 0],
                "positive": ["4", 0],
                "negative": ["4", 0],
                "latent_image": ["14", 0],
                "seed": seed,
                "steps": steps,
                "cfg": cfg,
                "sampler_name": "euler",
                "scheduler": "simple",
                "denoise": denoise,
            },
        },
        "7": {
            "class_type": "VAEDecode",
            "inputs": {
                "samples": ["6", 0],
                "vae": ["3", 0],
            },
        },
        "8": {
            "class_type": "SaveImage",
            "inputs": {
                "images": ["7", 0],
                "filename_prefix": "sts_flux_ref",
            },
        },
    }


# ── LTX Video Workflows ─────────────────────────────────────────
#
# Uses ComfyUI's built-in LTX nodes (no custom node pack required):
#   CheckpointLoaderSimple, LTXVConditioning, LTXVScheduler,
#   EmptyLTXVLatentVideo, LTXVImgToVideo, BasicGuider,
#   KSamplerSelect, SamplerCustomAdvanced, RandomNoise

def ltx_video_img2vid(
    prompt: str,
    input_image_name: str,
    num_frames: int = 121,
    steps: int = 30,
    cfg: float = 3.0,
    seed: int = -1,
    width: int = 768,
    height: int = 512,
    fps: int = 24,
    model_name: str = "ltx-video-2b-v0.9.5.safetensors",
    clip_name: str = "t5xxl_fp8_e4m3fn_scaled.safetensors",
) -> dict:
    """LTX Video image-to-video workflow using built-in ComfyUI nodes."""
    if seed < 0:
        seed = random.randint(0, 2**32)

    # Ensure num_frames follows LTX constraint: must be 8k+1
    num_frames = ((num_frames - 1) // 8) * 8 + 1

    return {
        # Load the LTX checkpoint (model + vae; clip is separate)
        "1": {
            "class_type": "CheckpointLoaderSimple",
            "inputs": {
                "ckpt_name": model_name,
            },
        },
        # Load T5-XXL text encoder separately for LTX
        "9": {
            "class_type": "CLIPLoader",
            "inputs": {
                "clip_name": clip_name,
                "type": "ltxv",
            },
        },
        # Load the conditioning image
        "2": {
            "class_type": "LoadImage",
            "inputs": {
                "image": input_image_name,
            },
        },
        # Text conditioning (using separately loaded T5)
        "3": {
            "class_type": "CLIPTextEncode",
            "inputs": {
                "text": prompt,
                "clip": ["9", 0],
            },
        },
        # Negative prompt (empty)
        "4": {
            "class_type": "CLIPTextEncode",
            "inputs": {
                "text": "",
                "clip": ["9", 0],
            },
        },
        # Image-to-video conditioning (outputs positive, negative, latent)
        "5": {
            "class_type": "LTXVImgToVideo",
            "inputs": {
                "positive": ["3", 0],
                "negative": ["4", 0],
                "vae": ["1", 2],
                "image": ["2", 0],
                "width": width,
                "height": height,
                "length": num_frames,
                "batch_size": 1,
                "strength": 1.0,
            },
        },
        # LTX-specific conditioning wrapper
        "10": {
            "class_type": "LTXVConditioning",
            "inputs": {
                "positive": ["5", 0],
                "negative": ["5", 1],
                "frame_rate": float(fps),
            },
        },
        # LTX-specific scheduler
        "11": {
            "class_type": "LTXVScheduler",
            "inputs": {
                "steps": steps,
                "max_shift": 2.05,
                "base_shift": 0.95,
                "stretch": True,
                "terminal": 0.1,
            },
        },
        # Sampler selection
        "12": {
            "class_type": "KSamplerSelect",
            "inputs": {
                "sampler_name": "euler",
            },
        },
        # Random noise
        "13": {
            "class_type": "RandomNoise",
            "inputs": {
                "noise_seed": seed,
            },
        },
        # Guider (wraps model + conditioning)
        "14": {
            "class_type": "BasicGuider",
            "inputs": {
                "model": ["1", 0],
                "conditioning": ["10", 0],
            },
        },
        # Advanced sampler
        "6": {
            "class_type": "SamplerCustomAdvanced",
            "inputs": {
                "noise": ["13", 0],
                "guider": ["14", 0],
                "sampler": ["12", 0],
                "sigmas": ["11", 0],
                "latent_image": ["5", 2],
            },
        },
        # Decode
        "7": {
            "class_type": "VAEDecode",
            "inputs": {
                "samples": ["6", 0],
                "vae": ["1", 2],
            },
        },
        # Save as animated WEBP
        "8": {
            "class_type": "SaveAnimatedWEBP",
            "inputs": {
                "images": ["7", 0],
                "filename_prefix": "sts_ltx",
                "fps": fps,
                "lossless": False,
                "quality": 85,
                "method": "default",
            },
        },
    }


def ltx_video_txt2vid(
    prompt: str,
    num_frames: int = 121,
    steps: int = 30,
    cfg: float = 3.0,
    seed: int = -1,
    width: int = 768,
    height: int = 512,
    fps: int = 24,
    model_name: str = "ltx-video-2b-v0.9.5.safetensors",
    clip_name: str = "t5xxl_fp8_e4m3fn_scaled.safetensors",
) -> dict:
    """LTX Video text-to-video workflow (no image conditioning)."""
    if seed < 0:
        seed = random.randint(0, 2**32)

    num_frames = ((num_frames - 1) // 8) * 8 + 1

    return {
        # Load checkpoint (model + vae; clip is separate)
        "1": {
            "class_type": "CheckpointLoaderSimple",
            "inputs": {
                "ckpt_name": model_name,
            },
        },
        # Load T5-XXL text encoder separately
        "9": {
            "class_type": "CLIPLoader",
            "inputs": {
                "clip_name": clip_name,
                "type": "ltxv",
            },
        },
        # Text conditioning (using separately loaded T5)
        "3": {
            "class_type": "CLIPTextEncode",
            "inputs": {
                "text": prompt,
                "clip": ["9", 0],
            },
        },
        # Negative prompt
        "4": {
            "class_type": "CLIPTextEncode",
            "inputs": {
                "text": "",
                "clip": ["9", 0],
            },
        },
        # LTX conditioning wrapper
        "10": {
            "class_type": "LTXVConditioning",
            "inputs": {
                "positive": ["3", 0],
                "negative": ["4", 0],
                "frame_rate": float(fps),
            },
        },
        # Empty latent video
        "5": {
            "class_type": "EmptyLTXVLatentVideo",
            "inputs": {
                "width": width,
                "height": height,
                "length": num_frames,
                "batch_size": 1,
            },
        },
        # LTX-specific scheduler
        "11": {
            "class_type": "LTXVScheduler",
            "inputs": {
                "steps": steps,
                "max_shift": 2.05,
                "base_shift": 0.95,
                "stretch": True,
                "terminal": 0.1,
            },
        },
        # Sampler selection
        "12": {
            "class_type": "KSamplerSelect",
            "inputs": {
                "sampler_name": "euler",
            },
        },
        # Random noise
        "13": {
            "class_type": "RandomNoise",
            "inputs": {
                "noise_seed": seed,
            },
        },
        # Guider
        "14": {
            "class_type": "BasicGuider",
            "inputs": {
                "model": ["1", 0],
                "conditioning": ["10", 0],
            },
        },
        # Advanced sampler
        "6": {
            "class_type": "SamplerCustomAdvanced",
            "inputs": {
                "noise": ["13", 0],
                "guider": ["14", 0],
                "sampler": ["12", 0],
                "sigmas": ["11", 0],
                "latent_image": ["5", 0],
            },
        },
        # Decode
        "7": {
            "class_type": "VAEDecode",
            "inputs": {
                "samples": ["6", 0],
                "vae": ["1", 2],
            },
        },
        # Save as animated WEBP
        "8": {
            "class_type": "SaveAnimatedWEBP",
            "inputs": {
                "images": ["7", 0],
                "filename_prefix": "sts_ltx",
                "fps": fps,
                "lossless": False,
                "quality": 85,
                "method": "default",
            },
        },
    }
