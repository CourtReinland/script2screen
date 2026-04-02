"""Reframe shot client using HuggingFace Spaces Gradio API.

Calls the Qwen-Image-Edit-2509 + Multiple-angles LoRA space to generate
camera angle variations of an existing image.

The API uses azimuth (horizontal rotation), elevation (vertical angle),
and distance (zoom) parameters — NOT text prompts.
"""

import os
import shutil
import time
from typing import Optional

# Angle presets mapped to (azimuth, elevation, distance) tuples
# azimuth: 0-315 degrees horizontal rotation
# elevation: -30 to 60 degrees vertical angle
# distance: 0.6-1.4 (1.0 = normal, <1 = closer, >1 = farther)
ANGLE_PRESETS = {
    "Front View":        (0,    0,   1.0),
    "Left Side (45°)":   (315,  0,   1.0),   # 315 = -45 = left
    "Right Side (45°)":  (45,   0,   1.0),
    "Left Side (90°)":   (270,  0,   1.0),
    "Right Side (90°)":  (90,   0,   1.0),
    "Back View":         (180,  0,   1.0),
    "Top Down":          (0,    60,  1.0),
    "Low Angle":         (0,   -30,  1.0),
    "Wide Angle":        (0,    0,   1.4),   # pull back
    "Close Up":          (0,    0,   0.6),   # push in
    "3/4 Left High":     (315,  30,  1.0),
    "3/4 Right High":    (45,   30,  1.0),
}

SPACE_ID = "multimodalart/qwen-image-multiple-angles-3d-camera"


def reframe_image(
    image_path: str,
    angle_preset: Optional[str] = None,
    azimuth: float = 0,
    elevation: float = 0,
    distance: float = 1.0,
    output_dir: Optional[str] = None,
    shot_key: str = "",
    seed: int = 0,
    randomize_seed: bool = True,
    guidance_scale: float = 1.0,
    num_inference_steps: int = 4,
) -> dict:
    """Reframe an image using camera angle parameters.

    Args:
        image_path: Path to the source image.
        angle_preset: One of ANGLE_PRESETS keys (overrides azimuth/elevation/distance).
        azimuth: Horizontal rotation 0-315 degrees.
        elevation: Vertical angle -30 to 60 degrees.
        distance: Zoom level 0.6-1.4 (1.0 = normal).
        output_dir: Directory to save result.
        shot_key: Shot key for naming output file.

    Returns:
        dict with keys: status, file_path, filename, angle
    """
    from gradio_client import Client, handle_file

    if not os.path.isfile(image_path):
        return {"status": "error", "error": f"Image not found: {image_path}"}

    # Apply preset if specified
    if angle_preset and angle_preset in ANGLE_PRESETS:
        azimuth, elevation, distance = ANGLE_PRESETS[angle_preset]

    if output_dir is None:
        output_dir = os.path.dirname(image_path)
    os.makedirs(output_dir, exist_ok=True)

    try:
        client = Client(SPACE_ID)
        result = client.predict(
            image=handle_file(image_path),
            azimuth=azimuth,
            elevation=elevation,
            distance=distance,
            seed=seed,
            randomize_seed=randomize_seed,
            guidance_scale=guidance_scale,
            num_inference_steps=num_inference_steps,
            height=1024,
            width=1024,
            api_name="/infer_camera_edit",
        )
    except Exception as e:
        return {"status": "error", "error": f"Gradio API call failed: {e}"}

    # result is a tuple: (output_image_dict, seed, generated_prompt)
    if isinstance(result, (list, tuple)) and len(result) >= 1:
        output_info = result[0]
        if isinstance(output_info, dict):
            result_path = output_info.get("path", "")
        elif isinstance(output_info, str):
            result_path = output_info
        else:
            result_path = str(output_info)
    else:
        result_path = str(result)

    if not result_path or not os.path.isfile(result_path):
        return {"status": "error", "error": f"Result file not found: {result_path}"}

    # Build output filename
    angle_tag = (angle_preset or f"az{int(azimuth)}_el{int(elevation)}").replace(" ", "_").replace("(", "").replace(")", "").replace("°", "")
    timestamp = int(time.time())
    if shot_key:
        filename = f"{shot_key}_reframe_{angle_tag}_{timestamp}.jpg"
    else:
        basename = os.path.splitext(os.path.basename(image_path))[0]
        filename = f"{basename}_reframe_{angle_tag}_{timestamp}.jpg"

    dest_path = os.path.join(output_dir, filename)

    # The Gradio API often returns WebP images regardless of extension.
    # DaVinci Resolve doesn't support WebP, so convert to JPEG.
    try:
        from PIL import Image as PILImage
        img = PILImage.open(result_path)
        img = img.convert("RGB")  # Ensure RGB for JPEG
        img.save(dest_path, "JPEG", quality=95)
    except ImportError:
        # PIL not available — try ffmpeg as fallback
        import subprocess
        ret = subprocess.run(
            ["ffmpeg", "-y", "-i", result_path, dest_path],
            capture_output=True, timeout=30,
        )
        if ret.returncode != 0:
            # Last resort: just copy and hope Resolve handles it
            shutil.copy2(result_path, dest_path)

    return {
        "status": "ok",
        "file_path": dest_path,
        "filename": filename,
        "angle": angle_preset or f"azimuth={azimuth}, elevation={elevation}, distance={distance}",
    }
