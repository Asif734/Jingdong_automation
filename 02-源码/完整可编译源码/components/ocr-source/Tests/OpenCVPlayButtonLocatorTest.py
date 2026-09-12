import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile

import cv2
import numpy as np


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "Sources/QianniuOCRAppSupport/Resources/OpenCV/video_play_locator.py"


def run_locator(image: np.ndarray) -> dict:
    with tempfile.TemporaryDirectory() as directory:
        image_path = pathlib.Path(directory) / "sample.png"
        cv2.imwrite(str(image_path), image)
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--image", str(image_path)],
            check=True,
            capture_output=True,
            text=True,
        )
        return json.loads(result.stdout)


def synthetic_card(background: int = 170) -> np.ndarray:
    image = np.full((360, 280, 3), background, np.uint8)
    disk = min(55, max(4, background - 30))
    draw_play(image, (140, 150), 30, disk)
    return image


def draw_play(image: np.ndarray, center: tuple[int, int], radius: int, disk: int):
    x, y = center
    cv2.circle(image, center, radius, (disk, disk, disk), -1, cv2.LINE_AA)
    triangle_height = int(radius * 1.05)
    cv2.fillConvexPoly(
        image,
        np.array([
            [x - triangle_height // 4, y - triangle_height // 2],
            [x - triangle_height // 4, y + triangle_height // 2],
            [x + triangle_height // 2, y],
        ], np.int32),
        (248, 248, 248),
        cv2.LINE_AA,
    )


def test_finds_play_button_on_bright_and_dark_cards():
    for background in (235, 170, 35):
        response = run_locator(synthetic_card(background))
        assert response["found"] is True
        assert abs(response["x"] - 140) <= 6
        assert abs(response["y"] - 150) <= 6


def test_rejects_bare_triangle_without_round_overlay():
    image = np.full((360, 280, 3), 170, np.uint8)
    cv2.fillConvexPoly(
        image,
        np.array([[132, 134], [132, 166], [155, 150]], np.int32),
        (248, 248, 248),
        cv2.LINE_AA,
    )
    assert run_locator(image) == {"found": False}


def test_stable_real_control_beats_one_larger_decoy_inside_video_content():
    image = np.full((520, 360, 3), 145, np.uint8)
    draw_play(image, (180, 135), 30, 45)
    # Colored/low-contrast decoy represents a play-like icon inside the video.
    cv2.circle(image, (270, 430), 48, (80, 55, 55), -1, cv2.LINE_AA)
    cv2.fillConvexPoly(
        image,
        np.array([[258, 402], [258, 458], [302, 430]], np.int32),
        (215, 232, 245),
        cv2.LINE_AA,
    )
    response = run_locator(image)
    assert response["found"] is True
    assert abs(response["x"] - 180) <= 7
    assert abs(response["y"] - 135) <= 7


if __name__ == "__main__":
    test_finds_play_button_on_bright_and_dark_cards()
    test_rejects_bare_triangle_without_round_overlay()
    test_stable_real_control_beats_one_larger_decoy_inside_video_content()
    print("OpenCV locator tests passed")
