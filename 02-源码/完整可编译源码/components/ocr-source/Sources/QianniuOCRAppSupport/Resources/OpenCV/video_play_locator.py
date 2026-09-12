#!/usr/bin/env python3
"""Locate a Qianniu-style circular play control inside one media-card crop."""

from __future__ import annotations

import argparse
import json
import math

import cv2
import numpy as np


def triangle_candidate(contour: np.ndarray):
    area = cv2.contourArea(contour)
    if area < 18:
        return None
    x, y, width, height = cv2.boundingRect(contour)
    if not (5 <= width <= 100 and 7 <= height <= 120 and 0.42 <= width / height <= 1.28):
        return None
    fill = area / max(width * height, 1)
    if not 0.25 <= fill <= 0.76:
        return None
    perimeter = cv2.arcLength(contour, True)
    polygon = cv2.approxPolyDP(contour, 0.055 * perimeter, True)
    if len(polygon) < 3 or len(polygon) > 5 or not cv2.isContourConvex(polygon):
        return None
    moments = cv2.moments(contour)
    if moments["m00"] == 0:
        return None
    center_x = moments["m10"] / moments["m00"]
    center_y = moments["m01"] / moments["m00"]
    if (center_x - x) / max(width, 1) > 0.54:
        return None

    points = polygon.reshape(-1, 2)
    rightmost = points[np.argmax(points[:, 0])]
    left_points = points[points[:, 0] < x + width * 0.62]
    if len(left_points) < 2:
        return None
    vertical_span = float(left_points[:, 1].max() - left_points[:, 1].min())
    if vertical_span < height * 0.62:
        return None
    if abs(float(rightmost[1]) - (y + height / 2)) > height * 0.38:
        return None
    return center_x, center_y, float(height), area


def circle_evidence(gray: np.ndarray, triangle_x: float, triangle_y: float, triangle_height: float):
    expected_x = triangle_x + triangle_height * 0.20
    expected_y = triangle_y
    half = int(max(20, triangle_height * 2.2))
    left = max(0, int(expected_x) - half)
    top = max(0, int(expected_y) - half)
    right = min(gray.shape[1], int(expected_x) + half + 1)
    bottom = min(gray.shape[0], int(expected_y) + half + 1)
    region = gray[top:bottom, left:right]
    if min(region.shape) < 20:
        return None
    circles = cv2.HoughCircles(
        cv2.GaussianBlur(region, (5, 5), 1.15),
        cv2.HOUGH_GRADIENT,
        dp=1.0,
        minDist=max(10, int(triangle_height)),
        param1=70,
        param2=max(7, int(triangle_height * 0.30)),
        minRadius=max(6, int(triangle_height * 0.72)),
        maxRadius=max(9, int(triangle_height * 1.85)),
    )
    if circles is None:
        return None
    best = None
    for local_x, local_y, radius in circles[0]:
        center_x = float(local_x + left)
        center_y = float(local_y + top)
        distance = math.hypot(center_x - expected_x, center_y - expected_y)
        if distance > max(6.0, triangle_height * 0.50):
            continue
        score = 1.0 - min(1.0, distance / max(triangle_height * 0.50, 1.0))
        if best is None or score > best[0]:
            best = (score, center_x, center_y, float(radius))
    return best


def locate(image: np.ndarray):
    maximum_dimension = max(image.shape[:2])
    scale = min(1.0, 520.0 / maximum_dimension)
    if scale < 1.0:
        image = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    normalized = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8)).apply(gray)
    smooth = cv2.GaussianBlur(normalized, (0, 0), 1.0)
    local = cv2.subtract(smooth, cv2.GaussianBlur(smooth, (0, 0), 9.0))
    masks = []
    for percentile in (88, 92, 95, 97):
        threshold = max(145, int(np.percentile(smooth, percentile)))
        masks.append(cv2.threshold(smooth, threshold, 255, cv2.THRESH_BINARY)[1])
    for threshold in (18, 28, 38):
        masks.append(cv2.threshold(local, threshold, 255, cv2.THRESH_BINARY)[1])

    candidates = []
    for mask_index, mask in enumerate(masks):
        contours, _ = cv2.findContours(mask, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
        for contour in contours:
            triangle = triangle_candidate(contour)
            if triangle is None:
                continue
            triangle_x, triangle_y, triangle_height, area = triangle
            circle = circle_evidence(gray, triangle_x, triangle_y, triangle_height)
            if circle is None:
                continue
            circle_score, center_x, center_y, radius = circle
            candidates.append((mask_index, circle_score, min(area / 400.0, 1.0), center_x, center_y, radius))
    if not candidates:
        return None

    clusters = []
    for candidate in candidates:
        for cluster in clusters:
            if math.hypot(candidate[3] - cluster[0][3], candidate[4] - cluster[0][4]) <= 8:
                cluster.append(candidate)
                break
        else:
            clusters.append([candidate])
    image_center = (image.shape[1] / 2, image.shape[0] / 2)
    ranked = []
    for cluster in clusters:
        masks_seen = len({candidate[0] for candidate in cluster})
        if masks_seen < 2:
            continue
        weights = np.asarray([candidate[1] + candidate[2] for candidate in cluster])
        center_x = float(np.average([candidate[3] for candidate in cluster], weights=weights))
        center_y = float(np.average([candidate[4] for candidate in cluster], weights=weights))
        center_distance = math.hypot(center_x - image_center[0], center_y - image_center[1])
        normalized_distance = center_distance / max(math.hypot(*image_center), 1.0)
        score = masks_seen * 0.55 + max(candidate[1] for candidate in cluster) \
            + max(candidate[2] for candidate in cluster) - normalized_distance * 0.30
        ranked.append((score, center_x, center_y))
    if not ranked:
        return None
    ranked.sort(reverse=True)
    _, center_x, center_y = ranked[0]
    return center_x / scale, center_y / scale


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", required=True)
    args = parser.parse_args()
    image = cv2.imread(args.image, cv2.IMREAD_COLOR)
    if image is None:
        print(json.dumps({"found": False}))
        return
    point = locate(image)
    if point is None:
        print(json.dumps({"found": False}))
    else:
        print(json.dumps({"found": True, "x": point[0], "y": point[1]}))


if __name__ == "__main__":
    main()
