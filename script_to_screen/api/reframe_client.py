"""Reframe shot client using HuggingFace Spaces Gradio API.

Calls the Qwen-Image-Edit space to generate camera angle variations
of an existing image using Chinese camera commands.
"""

import os
import shutil
import time
from typing import Optional

ANGLE_PRESETS = {
    "Front View": "保持正面视角",
    "Left Side (45\u00b0)": "将镜头向左旋转45度",
    "Right Side (45\u00b0)": "将镜头向右旋转45度",
    "Top Down": "将镜头转为俯视",
    "Low Angle": "将镜头向下移动",
    "Wide Angle": "将镜头转为广角镜头",
    "Close Up": "将镜头转为特写镜头",
    "Back View": "将镜头向左旋转180度",
    "Move Forward": "将镜头向前移动",
}

SPACE_ID = "multimodalart/qwen-image-multiple-angles-3d-camera"


def reframe_image(
    image_path: str,
    angle_preset: Optional[str] = None,
    custom_prompt: Optional[str] = None,
    output_dir: Optional[str] = None,
    shot_key: str = "",
) -> dict:
    """Reframe an image using a camera angle preset or custom prompt.

    Args:
        image_path: Path to the source image.
        angle_preset: One of the keys from ANGLE_PRESETS (e.g. "Left Side (45)").
        custom_prompt: Free-form camera instruction (Chinese or English).
            If both angle_preset and custom_prompt are given, custom_prompt wins.
        output_dir: Directory to save the result image. Defaults to same dir as source.
        shot_key: Shot key for naming the output file (e.g. "s1_sh1").

    Returns:
        dict with keys: status, file_path, filename, angle
    """
    from gradio_client import Client, handle_file

    # Determine the camera prompt
    if custom_prompt and custom_prompt.strip():
        camera_prompt = custom_prompt.strip()
    elif angle_preset and angle_preset in ANGLE_PRESETS:
        camera_prompt = ANGLE_PRESETS[angle_preset]
    else:
        camera_prompt = ANGLE_PRESETS["Front View"]

    if not os.path.isfile(image_path):
        return {"status": "error", "error": f"Image not found: {image_path}"}

    if output_dir is None:
        output_dir = os.path.dirname(image_path)
    os.makedirs(output_dir, exist_ok=True)

    try:
        client = Client(SPACE_ID)
        result = client.predict(
            input_image=handle_file(image_path),
            prompt=camera_prompt,
            api_name="/predict",
        )
    except Exception as e:
        return {"status": "error", "error": f"Gradio API call failed: {e}"}

    # result is the path to the generated image file
    result_path = str(result)
    if not os.path.isfile(result_path):
        return {"status": "error", "error": f"Result file not found: {result_path}"}

    # Build output filename
    angle_tag = (angle_preset or "custom").replace(" ", "_").replace("(", "").replace(")", "").replace("°", "")
    timestamp = int(time.time())
    if shot_key:
        filename = f"{shot_key}_reframe_{angle_tag}_{timestamp}.png"
    else:
        basename = os.path.splitext(os.path.basename(image_path))[0]
        filename = f"{basename}_reframe_{angle_tag}_{timestamp}.png"

    dest_path = os.path.join(output_dir, filename)
    shutil.copy2(result_path, dest_path)

    return {
        "status": "ok",
        "file_path": dest_path,
        "filename": filename,
        "angle": angle_preset or "custom",
        "prompt_used": camera_prompt,
    }
