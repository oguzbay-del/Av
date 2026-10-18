"""kus_bulucu.py ve dogrula.py'nin ortak ön/son işlemesi (Swift'teki BirdDetector/DetectionDecoder ile aynı)."""
import numpy as np
from PIL import Image

SIZE = 640
PAD = 114
THRESHOLD = 0.25  # uygulamadaki DetectionDecoder.defaultThreshold
IOU = 0.45


def letterbox(img, size=SIZE):
    """PIL → size×size RGB tuval (sol üst hizalı, gri dolgu) ve ölçek r (girdi pikseli = r × asıl piksel)."""
    r = min(size / img.width, size / img.height)
    w, h = max(1, round(img.width * r)), max(1, round(img.height * r))
    canvas = Image.new("RGB", (size, size), (PAD, PAD, PAD))
    canvas.paste(img.convert("RGB").resize((w, h), Image.BILINEAR), (0, 0))
    return canvas, r


def iou(a, b):
    """cx, cy, w, h kutuları arasında kesişim/birleşim."""
    ax0, ay0, ax1, ay1 = a[0] - a[2] / 2, a[1] - a[3] / 2, a[0] + a[2] / 2, a[1] + a[3] / 2
    bx0, by0, bx1, by1 = b[0] - b[2] / 2, b[1] - b[3] / 2, b[0] + b[2] / 2, b[1] + b[3] / 2
    iw, ih = max(0.0, min(ax1, bx1) - max(ax0, bx0)), max(0.0, min(ay1, by1) - max(ay0, by0))
    inter = iw * ih
    union = a[2] * a[3] + b[2] * b[3] - inter
    return inter / union if union > 0 else 0.0


def nms(boxes, scores, threshold=THRESHOLD, iou_limit=IOU, limit=5):
    """Eşik + açgözlü örtüşme bastırma; (kutu, puan) listesi, puana göre."""
    order = np.argsort(-np.asarray(scores))
    kept = []
    for i in order:
        s = float(scores[i])
        if s < threshold:
            break
        b = [float(v) for v in boxes[i]]
        if all(iou(b, k) <= iou_limit for k, _ in kept):
            kept.append((b, s))
        if len(kept) >= limit:
            break
    return kept
