"""dlib 얼굴 인식 모델 XML을 Keras 모델로 다시 쌓고 Core ML(.mlpackage)로 바꾼다.

ksachdeva/dlib-to-tf-keras-converter와 같은 방식이다: dlib의 net_to_xml로 풀어 쓴 XML을
입력 쪽부터 읽으며 같은 층을 Keras로 만들고 가중치를 그대로 옮긴다.

    python convert.py work/dlib_face_recognition_resnet_model_v1.xml out/FaceEmbedding.mlpackage

dlib과 다른 점을 맞추는 곳:
- dlib 텐서는 NCHW, Keras는 NHWC. 합성곱 가중치는 (out, in, h, w) -> (h, w, in, out)으로 돌린다.
- dlib add_prev는 두 입력의 크기가 다르면 큰 쪽에 맞추고 빈 곳은 0으로 채운다(왼쪽 위 기준).
  축소 블록에서 4x4와 3x3, 2x2와 1x1이 만나는 곳이 있어 Keras에서도 0으로 채워 더한다.
- 입력 정규화 (픽셀 - 평균) / 256 은 Core ML ImageType의 scale/bias로 넣는다. 채널 순서는 RGB.
"""

import argparse
import re
import sys
import xml.etree.ElementTree as ET

import numpy as np
import tensorflow as tf


def read_layers(path):
    """XML의 층을 출력 쪽부터(idx 0) 읽어 입력 쪽부터 순서로 돌려준다."""
    layers = []
    for _, element in ET.iterparse(path, events=("end",)):
        if element.tag != "layer":
            continue
        kind = element.get("type")
        if kind == "comp" or kind == "input" or kind == "loss":
            child = element[0]
            values = np.fromstring(child.text or "", sep=" ", dtype=np.float32) if (child.text or "").strip() else None
            layers.append({"kind": kind, "name": child.tag, "attrs": dict(child.attrib), "values": values})
        else:
            # tag / skip 층은 자식 없이 id만 있다.
            layers.append({"kind": kind, "name": kind, "attrs": dict(element.attrib), "values": None})
        element.clear()
    layers.reverse()
    return layers


def pad_to(x, height, width, channels):
    """dlib add_prev처럼 오른쪽 아래와 뒤쪽 채널을 0으로 채운다."""
    shape = tf.shape(x)
    return tf.pad(x, [[0, 0], [0, height - shape[1]], [0, width - shape[2]], [0, channels - shape[3]]])


def build(layers):
    input_layer = layers[0]
    assert input_layer["name"] == "input_rgb_image_sized", input_layer
    size = int(input_layer["attrs"]["nr"])
    means = [float(input_layer["attrs"][c]) for c in ("r", "g", "b")]

    inputs = tf.keras.Input(shape=(size, size, 3), name="image")
    x = inputs
    tags = {}
    count = {"con": 0, "affine": 0, "add": 0}

    for layer in layers[1:]:
        name, attrs, values = layer["name"], layer["attrs"], layer["values"]
        if layer["kind"] == "tag":
            tags[attrs["id"]] = x
        elif layer["kind"] == "skip":
            x = tags[attrs["id"]]
        elif layer["kind"] == "loss":
            break
        elif name == "con":
            filters, kh, kw = int(attrs["num_filters"]), int(attrs["nr"]), int(attrs["nc"])
            sy, sx = int(attrs["stride_y"]), int(attrs["stride_x"])
            py, px = int(attrs["padding_y"]), int(attrs["padding_x"])
            channels = x.shape[-1]
            n = filters * channels * kh * kw
            weights = values[:n].reshape(filters, channels, kh, kw).transpose(2, 3, 1, 0)
            bias = values[n:]
            assert bias.size == filters, (bias.size, filters)
            if py or px:
                x = tf.keras.layers.ZeroPadding2D(((py, py), (px, px)))(x)
            conv = tf.keras.layers.Conv2D(filters, (kh, kw), strides=(sy, sx), padding="valid", name=f"con{count['con']}")
            x = conv(x)
            conv.set_weights([weights, bias])
            count["con"] += 1
        elif name == "affine_con":
            channels = x.shape[-1]
            gamma, beta = values[:channels], values[channels:]
            assert beta.size == channels
            g = tf.constant(gamma.reshape(1, 1, 1, -1))
            b = tf.constant(beta.reshape(1, 1, 1, -1))
            x = tf.keras.layers.Lambda(lambda t, g=g, b=b: t * g + b, name=f"affine{count['affine']}")(x)
            count["affine"] += 1
        elif name == "relu":
            x = tf.keras.layers.ReLU()(x)
        elif name == "max_pool":
            assert attrs["padding_y"] == "0" and attrs["padding_x"] == "0"
            x = tf.keras.layers.MaxPooling2D((int(attrs["nr"]), int(attrs["nc"])),
                                             strides=(int(attrs["stride_y"]), int(attrs["stride_x"])), padding="valid")(x)
        elif name == "avg_pool":
            if attrs["nr"] == "0":
                # avg_pool_everything: 공간 전체 평균.
                x = tf.keras.layers.GlobalAveragePooling2D()(x)
            else:
                assert attrs["padding_y"] == "0" and attrs["padding_x"] == "0"
                x = tf.keras.layers.AveragePooling2D((int(attrs["nr"]), int(attrs["nc"])),
                                                     strides=(int(attrs["stride_y"]), int(attrs["stride_x"])), padding="valid")(x)
        elif name == "add_prev":
            other = tags[attrs["tag"]]
            h = max(x.shape[1], other.shape[1])
            w = max(x.shape[2], other.shape[2])
            c = max(x.shape[3], other.shape[3])
            if x.shape[1:] != (h, w, c):
                x = tf.keras.layers.Lambda(lambda t, h=h, w=w, c=c: pad_to(t, h, w, c))(x)
            if other.shape[1:] != (h, w, c):
                other = tf.keras.layers.Lambda(lambda t, h=h, w=w, c=c: pad_to(t, h, w, c))(other)
            x = tf.keras.layers.Add(name=f"add{count['add']}")([x, other])
            count["add"] += 1
        elif name == "fc_no_bias":
            outputs = int(attrs["num_outputs"])
            inputs_n = x.shape[-1]
            weights = values.reshape(inputs_n, outputs)
            dense = tf.keras.layers.Dense(outputs, use_bias=False, name="embedding")
            x = dense(x)
            dense.set_weights([weights])
        else:
            raise ValueError(f"모르는 층: {name} {attrs}")

    model = tf.keras.Model(inputs, x, name="dlib_face_recognition_resnet_v1")
    return model, size, means


def to_coreml(model, size, means, path):
    import coremltools as ct

    image = ct.ImageType(
        name="image",
        shape=(1, size, size, 3),
        scale=1 / 256.0,
        bias=[-m / 256.0 for m in means],
        color_layout=ct.colorlayout.RGB,
    )
    mlmodel = ct.convert(
        model,
        source="tensorflow",
        inputs=[image],
        convert_to="mlprogram",
        # 1e-3 동등성을 지키려면 FP16으로 줄이지 않는다.
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.iOS17,
    )
    # TF 그래프의 출력 이름은 층 이름과 달라서 변환 뒤에 바꾼다.
    spec = mlmodel.get_spec()
    ct.utils.rename_feature(spec, spec.description.output[0].name, "embedding")
    mlmodel = ct.models.MLModel(spec, weights_dir=mlmodel.weights_dir)
    mlmodel.short_description = "dlib_face_recognition_resnet_model_v1을 옮긴 얼굴 임베딩(128차원). 150x150 정렬 얼굴 입력."
    mlmodel.license = "dlib face recognition model: public domain (CC0). http://dlib.net/files/"
    mlmodel.author = "Davis E. King (dlib) / converted with tools/model-conversion"
    mlmodel.input_description["image"] = "dlib get_face_chip(size=150, padding=0.25)로 정렬한 RGB 얼굴"
    mlmodel.output_description["embedding"] = "128차원 얼굴 임베딩. 유클리드 거리 0.6 미만이면 같은 사람"
    mlmodel.save(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("xml")
    parser.add_argument("out")
    parser.add_argument("--keras", help="Keras 모델도 저장할 경로(.keras)")
    args = parser.parse_args()

    layers = read_layers(args.xml)
    model, size, means = build(layers)
    model.summary(line_length=120, print_fn=lambda s: None)
    print(f"층 {len(model.layers)}개, 입력 {size}x{size}, 평균 RGB {means}, 출력 {model.output_shape}")
    if args.keras:
        model.save(args.keras)
    to_coreml(model, size, means, args.out)
    print(f"저장: {args.out}")


if __name__ == "__main__":
    sys.exit(main())
