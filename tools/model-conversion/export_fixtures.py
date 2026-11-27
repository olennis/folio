"""Swift 테스트용 기준 얼굴을 만든다: 원본(PNG), dlib 5점, dlib 칩(PNG), dlib 임베딩.

    python export_fixtures.py ../../PhotoAlbumTests/Fixtures/faces

원본을 PNG로 바꿔 두어 JPEG 해석기 차이 없이 같은 픽셀에서 정렬을 비교한다.
Tom_Cruise 사진은 배율이 2보다 커서 dlib이 이미지 피라미드를 쓰는 경우를 확인한다.
"""
import json
import os
import sys

import dlib
import numpy as np
from PIL import Image

from parity_test import WORK, chip_transform

IMAGES = ["2008_001009.jpg", "2008_002506.jpg", "Tom_Cruise_avp_2014_4.jpg"]


def main(out):
    os.makedirs(out, exist_ok=True)
    detector = dlib.get_frontal_face_detector()
    predictor = dlib.shape_predictor(os.path.join(WORK, "shape_predictor_5_face_landmarks.dat"))
    recognizer = dlib.face_recognition_model_v1(os.path.join(WORK, "dlib_face_recognition_resnet_model_v1.dat"))
    faces = []
    for name in IMAGES:
        image = dlib.load_rgb_image(os.path.join(WORK, "dlib-src", "examples", "faces", name))
        stem = os.path.splitext(name)[0]
        Image.fromarray(image).save(os.path.join(out, f"{stem}.png"))
        for index, box in enumerate(detector(image, 1)):
            shape = predictor(image, box)
            chip = dlib.get_face_chip(image, shape, size=150, padding=0.25)
            chip_name = f"{stem}-chip{index}.png"
            Image.fromarray(chip).save(os.path.join(out, chip_name))
            points = [(shape.part(i).x, shape.part(i).y) for i in range(5)]
            _, _, scale, _, _ = chip_transform(points)
            faces.append({
                "image": f"{stem}.png",
                "chip": chip_name,
                "points": points,
                "scale": scale,
                "box": [box.left(), box.top(), box.width(), box.height()],
                "embedding": list(recognizer.compute_face_descriptor(chip)),
            })
    with open(os.path.join(out, "faces.json"), "w") as f:
        json.dump(faces, f)
    print(f"얼굴 {len(faces)}개 -> {out}")


if __name__ == "__main__":
    main(sys.argv[1])
