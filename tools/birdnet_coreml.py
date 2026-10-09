#!/usr/bin/env python3
"""BirdNET V2.4 ses modelini Core ML'e çevirir (cihazda, internetsiz kuş sesi tanıma).

Kaynak: BirdNET'in resmi model kaydı (Zenodo 15050749, "BirdNET Model V2.4", Kahl, Wood, Klinck;
Cornell Lab of Ornithology). BirdNET-Analyzer ve `birdnet` pip paketi modeli buradan indirir;
`birdnetlib` paketindeki `BirdNET_GLOBAL_6K_V2.4_Model_FP32.tflite` ile bu kayıttaki
`audio-model.tflite` bayt bayt aynıdır (md5 6c7c4210…).

Kullanılan dosyalar:
  BirdNET_v2.4_keras.zip   → audio-model.h5 (ağırlıklar; çevrilen model)
  BirdNET_v2.4_tflite.zip  → audio-model.tflite (karşılaştırma için referans),
                             meta-model.tflite (yer/hafta modeli), labels/*.txt

Çıktılar (--out, varsayılan build/birdnet):
  BirdNET.mlpackage        48 kHz mono 3 sn (144 000 örnek, Float32) → 6 522 logit (FP16 mlprogram, iOS 17)
  BirdNET_Labels.txt       "Bilimsel ad_İngilizce ad", model çıktısıyla aynı sıra
  BirdNET_Istanbul_Weeks.json  İstanbul (41,1 K, 29,0 D) için 48 haftalık tür listesi (meta model ≥ 0,03)
  LICENSE.txt, ATTRIBUTION.md  CC BY-NC-SA 4.0 ve atıf
  validation.json          referans TFLite ile karşılaştırma sonuçları

Spektrogram neden modelin içinde kalabiliyor:
  BirdNET'in özel katmanı (MelSpecLayerSimple) STFT'nin karmaşık sonucunu `tf.cast(…, float32)` ile
  float'a çevirir; bu yalnızca GERÇEL kısmı alır. Gerçel kısım = Σ x[n]·hann[n]·cos(2πkn/N) doğrusal bir
  işlemdir, ardından gelen mel matrisi çarpımı da doğrusaldır. İkisi tek bir Conv1D çekirdeğine
  (N × 96, adım = frame_step) katlanır; mel ekseninin ters çevrilmesi de çekirdek sütunlarının sırasına
  katlanır. Geriye Core ML'in desteklediği işlemler kalır: min/max normalleştirme, conv1d, |x|^p,
  transpose. (x²)^a yerine |x|^(2a) kullanılır: matematiksel olarak aynıdır ama FP16'da x² taşmaz
  (x ~ 3000 → x² ~ 9·10⁶ > 65 504).
  Son sigmoid katmanı çıkarılır: model, referans TFLite gibi LOGIT verir; uygulama
  1 / (1 + exp(-logit)) uygular (BirdNET-Analyzer, duyarlılık 1,0).

İndirilen Python kodu (MelSpecLayerSimple.py) ÇALIŞTIRILMAZ; katman burada yeniden yazılmıştır.

Kullanım:
  python3 tools/birdnet_coreml.py --out build/birdnet
  python3 tools/birdnet_coreml.py --out build/birdnet --clips a.wav b.mp3   # ek test kayıtları
Gereksinimler: tensorflow-cpu 2.15, coremltools 8.x, numpy<2, scipy, soundfile (+ mp3 için ffmpeg).
Core ML tahmini (çevrilen modelin doğrulanması) yalnızca macOS'ta çalışır; Linux'ta Keras eşdeğeri
referansla karşılaştırılır ve .mlpackage yine üretilir.
"""
import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np

ZENODO = "https://zenodo.org/records/15050749/files/"
FILES = {
    "BirdNET_v2.4_keras.zip": "c59eb166ee53c8e3973ef094729c7886",
    "BirdNET_v2.4_tflite.zip": "c13f7fd28a5f7a3b092cd993087f93f7",
}
SR = 48_000
WINDOW = 3 * SR
N_CLASSES = 6522
ISTANBUL = (41.1, 29.0)
META_THRESHOLD = 0.03
UA = {"User-Agent": "AvHaritasi-birdnet-coreml/1.0 (kisisel, ticari olmayan)"}
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAK = os.path.join(REPO, "ios", "AvHaritasi", "MapData", "mak_2026_2027.json")
# BirdNET (Clements 2021) adı → MAK listesindeki ad (yalnızca farklı olanlar)
SYNONYMS = {"Streptopelia senegalensis": "Spilopelia senegalensis"}

ATTRIBUTION = """# BirdNET V2.4 — atıf / attribution

Bu klasördeki model ve veri dosyaları BirdNET V2.4'ten türetilmiştir.
The model and data files in this folder are derived from BirdNET V2.4.

- Model: BirdNET GLOBAL 6K V2.4 (Zenodo record 15050749, https://doi.org/10.5281/zenodo.15050749)
- Authors: Stefan Kahl, Connor M. Wood, Maximilian Eibl, Holger Klinck
- K. Lisa Yang Center for Conservation Bioacoustics, Cornell Lab of Ornithology &
  Chemnitz University of Technology
- Project: https://github.com/birdnet-team/BirdNET-Analyzer
- Paper: Kahl, S., Wood, C. M., Eibl, M., & Klinck, H. (2021). BirdNET: A deep learning solution for
  avian diversity monitoring. Ecological Informatics, 61, 101236.
  https://doi.org/10.1016/j.ecoinf.2021.101236

Lisans / Licence: Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International
(CC BY-NC-SA 4.0), see LICENSE.txt. Ticari kullanım yasaktır; türetilmiş dosyalar aynı lisansla
paylaşılmalıdır. Commercial use requires a separate licence from the Cornell Lab of Ornithology
(ccb-birdnet@cornell.edu).

Değişiklikler / Changes (Av Haritası, tools/birdnet_coreml.py):
- Keras modeli Core ML mlprogram biçimine (FP16) çevrildi. Spektrogram katmanı eşdeğer bir Conv1D
  ile yeniden yazıldı (STFT gerçel kısmı × mel matrisi tek çekirdekte); son sigmoid çıkarıldı (logit).
- Converted to Core ML (FP16 mlprogram); the spectrogram layer was re-expressed as an equivalent
  Conv1D (real STFT part × mel matrix folded into one kernel); final sigmoid removed (logits).
- BirdNET_Istanbul_Weeks.json: species list computed with the BirdNET V2.4 meta (range) model for
  41.1 N, 29.0 E, weeks 1–48, threshold 0.03.
"""


def log(*a):
    print(*a, flush=True)


# MARK: İndirme

def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(cache):
    os.makedirs(cache, exist_ok=True)
    paths = {}
    for name, digest in FILES.items():
        path = os.path.join(cache, name)
        if not (os.path.exists(path) and md5(path) == digest):
            log(f"İndiriliyor: {ZENODO}{name}")
            tmp = path + ".part"
            with urllib.request.urlopen(urllib.request.Request(ZENODO + name, headers=UA), timeout=600) as r, \
                    open(tmp, "wb") as f:
                shutil.copyfileobj(r, f, 1 << 20)
            os.replace(tmp, path)
        got = md5(path)
        if got != digest:
            raise SystemExit(f"{name}: md5 uyuşmuyor ({got} != {digest})")
        paths[name] = path
    return paths


def extract(zip_path, members, dest):
    """Yalnızca adı verilen dosyaları, düz adla çıkarır (zip içindeki yollara güvenilmez)."""
    os.makedirs(dest, exist_ok=True)
    out = {}
    with zipfile.ZipFile(zip_path) as z:
        names = set(z.namelist())
        for m in members:
            if m not in names:
                raise SystemExit(f"{os.path.basename(zip_path)} içinde {m} yok")
            target = os.path.join(dest, m.replace("/", "__"))
            with z.open(m) as src, open(target, "wb") as dst:
                shutil.copyfileobj(src, dst)
            out[m] = target
    return out


def read_labels(path):
    with open(path, encoding="utf-8") as f:
        labels = [l.strip("\r\n") for l in f.read().replace("\r\n", "\n").split("\n")]
    labels = [l for l in labels if l]
    if len(labels) != N_CLASSES:
        raise SystemExit(f"{path}: {len(labels)} etiket (beklenen {N_CLASSES})")
    return labels


# MARK: Keras modeli

def keras_layers():
    import tensorflow as tf

    class MelSpecLayerSimple(tf.keras.layers.Layer):
        """BirdNET'in özgün spektrogram katmanı (yeniden yazım; yalnızca h5 dosyasını açmak ve referans için)."""

        def __init__(self, sample_rate, spec_shape, frame_step, frame_length, fmin, fmax, data_format,
                     mel_filterbank=None, **kwargs):
            super().__init__(**kwargs)
            self.sample_rate = sample_rate
            self.spec_shape = list(spec_shape)
            self.frame_step = frame_step
            self.frame_length = frame_length
            self.fmin = fmin
            self.fmax = fmax
            self.data_format = data_format
            if mel_filterbank is not None:
                self.mel = np.asarray(mel_filterbank, np.float32)
            else:
                self.mel = tf.signal.linear_to_mel_weight_matrix(
                    num_mel_bins=self.spec_shape[0], num_spectrogram_bins=frame_length // 2 + 1,
                    sample_rate=sample_rate, lower_edge_hertz=fmin, upper_edge_hertz=fmax).numpy()

        def build(self, input_shape):
            self.mag_scale = self.add_weight(name="magnitude_scaling", shape=(),
                                             initializer=tf.keras.initializers.Constant(1.23))
            super().build(input_shape)

        def call(self, inputs):
            x = inputs - tf.reduce_min(inputs, axis=1, keepdims=True)
            x = x / (tf.reduce_max(x, axis=1, keepdims=True) + 0.000001)
            x = (x - 0.5) * 2.0
            spec = tf.signal.stft(x, self.frame_length, self.frame_step, fft_length=self.frame_length,
                                  window_fn=tf.signal.hann_window, pad_end=False)
            spec = tf.math.real(spec)
            spec = tf.tensordot(spec, self.mel, 1)
            spec = tf.pow(spec, 2.0)
            spec = tf.pow(spec, 1.0 / (1.0 + tf.exp(self.mag_scale)))
            spec = tf.reverse(spec, axis=[2])
            spec = tf.transpose(spec, [0, 2, 1])
            return tf.expand_dims(spec, -1)

    class ConvMelSpec(tf.keras.layers.Layer):
        """Core ML'e çevrilebilir eşdeğer: normalleştirme → Conv1D(STFT gerçel kısmı × mel, ters sıra) → |x|^p."""

        def __init__(self, kernel, step, exponent, **kwargs):
            super().__init__(**kwargs)
            self.kernel_np = np.asarray(kernel, np.float32)
            self.step = int(step)
            self.exponent = float(exponent)

        def build(self, input_shape):
            self.kernel = self.add_weight(name="stft_mel_kernel", shape=self.kernel_np.shape, trainable=False,
                                          initializer=tf.keras.initializers.Constant(self.kernel_np))
            super().build(input_shape)

        def call(self, inputs):
            x = inputs - tf.reduce_min(inputs, axis=1, keepdims=True)
            x = x / (tf.reduce_max(x, axis=1, keepdims=True) + 0.000001)
            x = (x - 0.5) * 2.0
            x = tf.expand_dims(x, -1)                                       # (B, T, 1)
            spec = tf.nn.conv1d(x, self.kernel, stride=self.step, padding="VALID")  # (B, frames, mels)
            spec = tf.pow(tf.abs(spec), self.exponent)
            spec = tf.transpose(spec, [0, 2, 1])                            # (B, mels, frames)
            return tf.expand_dims(spec, -1)

    return MelSpecLayerSimple, ConvMelSpec


def stft_mel_kernel(layer):
    """Hann pencereli DFT'nin gerçel kısmı (N × N/2+1) ile mel matrisinin (N/2+1 × M) çarpımı; mel sırası ters."""
    n = layer.frame_length
    t = np.arange(n, dtype=np.float64)
    window = 0.5 - 0.5 * np.cos(2 * np.pi * t / n)        # tf.signal.hann_window(periodic=True)
    k = np.arange(n // 2 + 1, dtype=np.float64)
    cos = np.cos(2 * np.pi * np.outer(t, k) / n)            # (N, K)
    kern = (window[:, None] * cos) @ layer.mel.astype(np.float64)   # (N, M)
    kern = kern[:, ::-1]                                    # tf.reverse(axis=mel)
    return kern[:, None, :].astype(np.float32)              # (N, 1, M) conv1d çekirdeği


def load_models(h5):
    import tensorflow as tf
    MelSpecLayerSimple, ConvMelSpec = keras_layers()
    original = tf.keras.models.load_model(h5, custom_objects={"MelSpecLayerSimple": MelSpecLayerSimple},
                                          compile=False)
    if original.output_shape[-1] != N_CLASSES:
        raise SystemExit(f"Beklenmeyen çıktı boyutu {original.output_shape}")

    def clone(layer):
        if isinstance(layer, MelSpecLayerSimple):
            mag = float(layer.mag_scale.numpy())
            exponent = 2.0 / (1.0 + np.exp(mag))
            log(f"  {layer.name}: N={layer.frame_length} adım={layer.frame_step} "
                f"{layer.fmin}-{layer.fmax} Hz, mag_scale={mag:.6f} → |x|^{exponent:.6f}")
            return ConvMelSpec(stft_mel_kernel(layer), layer.frame_step, exponent, name=layer.name)
        return layer.__class__.from_config(layer.get_config())

    rebuilt = tf.keras.models.clone_model(original, clone_function=clone)
    for src in original.layers:
        if isinstance(src, MelSpecLayerSimple):
            continue
        rebuilt.get_layer(src.name).set_weights(src.get_weights())
    # Son sigmoid'i at: referans TFLite gibi logit ver
    dense = rebuilt.get_layer("CLASS_DENSE_LAYER")
    if dense.get_config().get("activation") != "linear":
        raise SystemExit("CLASS_DENSE_LAYER doğrusal değil; çıktı yapısı değişmiş")
    logits = tf.keras.Model(rebuilt.inputs, dense.output, name="BirdNET_V24_logits")
    return original, logits


def prune_to(logits_model, idx):
    """Çıktı katmanını yalnızca verilen sınıflara indirger (İstanbul listesi).

    Sınıf başına logit değişmez (aynı ağırlık sütunu), yalnızca diğer sınıflar atılır: model
    ~26 MB'tan ~13 MB'a iner ve bölgede olmayan türler hiç üretilemez."""
    import tensorflow as tf
    dense = logits_model.get_layer("CLASS_DENSE_LAYER")
    w, b = dense.get_weights()
    sub = tf.keras.layers.Dense(len(idx), activation="linear", name="ISTANBUL_DENSE_LAYER")
    out = sub(dense.input)
    sub.set_weights([w[:, idx], b[idx]])
    return tf.keras.Model(logits_model.inputs, out, name="BirdNET_V24_Istanbul_logits")


# MARK: Ses

def load_clip(path):
    """Herhangi bir ses dosyası → 48 kHz mono float32 (−1…1)."""
    try:
        import soundfile as sf
        x, sr = sf.read(path, dtype="float32", always_2d=True)
        x = x.mean(axis=1)
    except Exception:
        raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", str(SR), "-f", "f32le", "-"],
                             check=True, capture_output=True).stdout
        return np.frombuffer(raw, np.float32).copy()
    if sr != SR:
        from math import gcd
        from scipy.signal import resample_poly
        g = gcd(SR, sr)
        x = resample_poly(x, SR // g, sr // g).astype(np.float32)
    return x


def windows(x):
    """3 sn pencereler, 1,5 sn örtüşme; kısa son pencere sıfırla doldurulur (uygulamadaki gibi).

    Bir pencere, yalnızca öncekinin içinde kalmayacak kadar (> 1,5 sn) ses kalıyorsa açılır;
    15 sn'lik kayıt → 9 pencere (0, 1,5 … 12 sn)."""
    step = WINDOW // 2
    starts = [s for s in range(0, len(x), step) if s == 0 or len(x) - s > step]
    out = []
    for s in starts:
        w = x[s:s + WINDOW]
        out.append(np.pad(w, (0, WINDOW - len(w))).astype(np.float32))
    return np.stack(out)


def default_clips(tmp):
    """Depodaki 4 kuş sesi (Xeno-canto kayıtlarından kırpılmış) + indirilebilirse 2 tam Xeno-canto kaydı."""
    clips = []
    sounds = os.path.join(REPO, "ios", "AvHaritasi", "Sounds")
    for name in sorted(os.listdir(sounds)) if os.path.isdir(sounds) else []:
        if name.endswith(".wav"):
            clips.append(os.path.join(sounds, name))
    for xc in (1048930, 1004199):   # kınalı keklik, bıldırcın (tools/fetch_sounds.py)
        path = os.path.join(tmp, f"XC{xc}.mp3")
        try:
            with urllib.request.urlopen(urllib.request.Request(f"https://xeno-canto.org/{xc}/download", headers=UA),
                                        timeout=60) as r, open(path, "wb") as f:
                shutil.copyfileobj(r, f)
            clips.append(path)
        except Exception as e:  # noqa: BLE001 — doğrulama yine depodaki kayıtlarla yapılır
            log(f"  XC{xc} indirilemedi ({e}); atlanıyor")
    return clips


# MARK: Doğrulama

def tflite_logits(model_path, batch):
    import tensorflow as tf
    it = tf.lite.Interpreter(model_path=model_path)
    inp = it.get_input_details()[0]
    out = it.get_output_details()[0]
    it.resize_tensor_input(inp["index"], [1, WINDOW])
    it.allocate_tensors()
    res = []
    for w in batch:
        it.set_tensor(inp["index"], w[None, :])
        it.invoke()
        res.append(it.get_tensor(out["index"])[0].copy())
    return np.stack(res)


def sigmoid(x):
    return 1.0 / (1.0 + np.exp(-np.clip(x, -15, 15)))


RELEVANT = 0.01      # bu olasılığın altındaki sınıflar ilk-5'te olsa da gürültüdür (FP16'da sıraları oynar)
MAX_PROB_DIFF = 0.02


def compare(name, ref, got, labels):
    """Pencere başına ilk-5 karşılaştırması.

    Dönüş: (ilk-5 kümesi birebir aynı pencere, anlamlı ilk-5 aynı pencere, toplam, en büyük olasılık farkı, ayrıntı).
    "Anlamlı ilk-5": ilk tahmin aynı ve iki taraftaki ilk-5'in olasılığı ≥ 0,01 olan sınıfları diğer tarafın
    ilk-5'inde de var. FP16'da ~0,001 olasılıklı kuyruk sınıfları yer değiştirebilir; bunlar gösterilmez."""
    rows = []
    ok = rel_ok = 0
    for i, (r, g) in enumerate(zip(ref, got)):
        tr = list(np.argsort(-r)[:5])
        tg = list(np.argsort(-g)[:5])
        pr, pg = sigmoid(r), sigmoid(g)
        same = set(tr) == set(tg)
        relevant = (tr[0] == tg[0]
                    and {j for j in tr if pr[j] >= RELEVANT} <= set(tg)
                    and {j for j in tg if pg[j] >= RELEVANT} <= set(tr))
        ok += same
        rel_ok += relevant
        rows.append({
            "window": i,
            "top5_same_set": bool(same),
            "top5_relevant_same": bool(relevant),
            "top5_same_order": tr == tg,
            "max_abs_logit_diff": float(np.max(np.abs(r - g))),
            "max_abs_prob_diff": float(np.max(np.abs(sigmoid(r) - sigmoid(g)))),
            "reference": [[labels[j], round(float(sigmoid(r[j])), 4)] for j in tr],
            "converted": [[labels[j], round(float(sigmoid(g[j])), 4)] for j in tg],
        })
    worst = max(r["max_abs_prob_diff"] for r in rows)
    log(f"  {name}: ilk-5 kümesi aynı {ok}/{len(rows)}, anlamlı ilk-5 aynı {rel_ok}/{len(rows)} pencere, "
        f"en büyük olasılık farkı {worst:.4f}; ilk tahmin: "
        f"{rows[0]['reference'][0][0]} {rows[0]['reference'][0][1]:.2f} / "
        f"{rows[0]['converted'][0][0]} {rows[0]['converted'][0][1]:.2f}")
    for row in rows:
        if not row["top5_same_set"]:
            log(f"    pencere {row['window']}: referans {row['reference']}")
            log(f"    {' ' * len(str(row['window']))}          çevrilen {row['converted']}")
    return ok, rel_ok, len(rows), worst, rows


# MARK: Core ML

def convert(keras_model, out_dir, labels, n_classes=N_CLASSES):
    import coremltools as ct
    log("Core ML'e çevriliyor (mlprogram, FP16, iOS 17)…")
    ml = ct.convert(
        keras_model,
        source="tensorflow",
        convert_to="mlprogram",
        inputs=[ct.TensorType(name=keras_model.inputs[0].name.split(":")[0], shape=(1, WINDOW), dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )
    spec = ml.get_spec()
    ct.utils.rename_feature(spec, spec.description.input[0].name, "audio")
    ct.utils.rename_feature(spec, spec.description.output[0].name, "logits")
    ml = ct.models.MLModel(spec, weights_dir=ml.weights_dir)
    ml.author = "Stefan Kahl, Connor M. Wood, Maximilian Eibl, Holger Klinck (K. Lisa Yang Center for " \
                "Conservation Bioacoustics, Cornell Lab of Ornithology & Chemnitz University of Technology)"
    ml.license = "CC BY-NC-SA 4.0 (https://creativecommons.org/licenses/by-nc-sa/4.0/) — non-commercial use only"
    ml.short_description = ("BirdNET GLOBAL 6K V2.4 bird sound classifier. Input: 3 s of 48 kHz mono audio "
                            f"(144000 float samples). Output: {n_classes} logits (Istanbul subset when < 6522; order in "
                            "BirdNET_Istanbul_Weeks.json); apply sigmoid. Converted by Av Haritası.")
    ml.version = "2.4"
    ml.input_description["audio"] = "3 s mono audio at 48 kHz, 144000 float samples (any scale; normalised inside)"
    ml.output_description["logits"] = (f"{n_classes} class logits (index = species 'i' in BirdNET_Istanbul_Weeks.json); "
                                       "probability = sigmoid(logit)")
    ml.user_defined_metadata.update({
        "birdnet.version": "2.4",
        "birdnet.output": "logits",
        "birdnet.classes": str(n_classes),
        "birdnet.subset": "istanbul" if n_classes < N_CLASSES else "global",
        "birdnet.sampleRate": str(SR),
        "birdnet.windowSamples": str(WINDOW),
        "birdnet.labelsSha1": hashlib.sha1("\n".join(labels).encode()).hexdigest(),
    })
    path = os.path.join(out_dir, "BirdNET.mlpackage")
    if os.path.exists(path):
        shutil.rmtree(path)
    ml.save(path)
    return path


def coreml_logits(path, batch, units="CPU_ONLY"):
    import coremltools as ct
    ml = ct.models.MLModel(path, compute_units=getattr(ct.ComputeUnit, units))
    return np.stack([np.asarray(ml.predict({"audio": w[None, :]})["logits"]).reshape(-1) for w in batch])


def dir_size(path):
    total = 0
    for root, _, files in os.walk(path):
        total += sum(os.path.getsize(os.path.join(root, f)) for f in files)
    return total


# MARK: Yer/hafta listesi

def week_list(meta_path, labels, tr_labels):
    """Meta modelin İstanbul'da ≥ 0,03 verdiği türler + MAK listelerindeki (av / koruma altında) tüm türler.

    MAK türleri bölgede olası görünmese de listeye girer (haftaları "000…" olabilir): uygulama
    "benzer korunan tür" uyarısını bu türlerin skorlarıyla da hesaplar."""
    import tensorflow as tf
    mak = set()
    if os.path.exists(MAK):
        with open(MAK, encoding="utf-8") as f:
            m = json.load(f)
        mak = set(m.get("huntableLatin") or {}) | set(m.get("protectedLatin") or {})
    it = tf.lite.Interpreter(model_path=meta_path)
    inp = it.get_input_details()[0]
    out = it.get_output_details()[0]
    it.allocate_tensors()
    lat, lon = ISTANBUL
    weeks = np.zeros((48, N_CLASSES), bool)
    for w in range(1, 49):
        it.set_tensor(inp["index"], np.array([[lat, lon, w]], np.float32))
        it.invoke()
        weeks[w - 1] = it.get_tensor(out["index"])[0] >= META_THRESHOLD
    species = []
    in_range = weeks.any(axis=0)
    for i in range(N_CLASSES):
        sci, en = labels[i].split("_", 1)
        alias = SYNONYMS.get(sci)
        if not (in_range[i] or sci in mak or alias in mak):
            continue
        tr = tr_labels[i].split("_", 1)[1] if "_" in tr_labels[i] else en
        entry = {"i": i, "sci": sci, "en": en, "tr": tr, "weeks": "".join("1" if b else "0" for b in weeks[:, i])}
        if alias:
            entry["mak"] = alias
        species.append(entry)
    per_week = weeks.sum(axis=1)
    known = {s["sci"] for s in species} | {s.get("mak") for s in species}
    missing = sorted(x for x in mak if x not in known)
    log(f"İstanbul hafta listesi: bölgede {int(in_range.sum())} tür (hafta başına {per_week.min()}–{per_week.max()}), "
        f"MAK ile birlikte {len(species)}; BirdNET'te olmayan MAK türleri: {', '.join(missing) or '-'}")
    return {
        "model": "BirdNET GLOBAL 6K V2.4 meta (range) model",
        "classes": N_CLASSES,
        "lat": lat,
        "lon": lon,
        "threshold": META_THRESHOLD,
        "mak": "Species listed in MAK 2026-27 (game or protected) are included even when out of range.",
        "weekNote": "BirdNET 48-week year: week = (month - 1) * 4 + min(4, (day - 1) / 7 + 1)",
        "license": "CC BY-NC-SA 4.0 — derived from BirdNET V2.4 (Cornell Lab of Ornithology); see ATTRIBUTION.md",
        "species": species,
    }


def write_week_json(data, path):
    """Küçük ve diff'e uygun: tür başına bir satır."""
    head = {k: v for k, v in data.items() if k != "species"}
    lines = ["{"]
    for k, v in head.items():
        lines.append(f" {json.dumps(k)}: {json.dumps(v, ensure_ascii=False)},")
    lines.append(' "species": [')
    sp = [json.dumps(s, ensure_ascii=False, separators=(",", ":")) for s in data["species"]]
    lines.append(",\n".join("  " + s for s in sp))
    lines.append(" ]")
    lines.append("}")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


# MARK: Ana akış

def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=os.path.join(REPO, "build", "birdnet"))
    ap.add_argument("--cache", help="İndirme önbelleği (varsayılan: <out>/cache)")
    ap.add_argument("--clips", nargs="*", default=None, help="Doğrulama kayıtları (varsayılan: depodaki kuş sesleri + 2 XC)")
    ap.add_argument("--skip-coreml", action="store_true", help="Yalnızca indir, doğrula, hafta listesini üret")
    ap.add_argument("--week-json", help="Hafta listesini ayrıca buraya da yaz (ör. ios/AvHaritasi/BirdNET/…)")
    ap.add_argument("--global-model", action="store_true",
                    help="Tüm 6522 sınıfı tut (varsayılan: yalnızca İstanbul listesindeki türler)")
    ap.add_argument("--min-match", type=float, default=1.0,
                    help="Core ML anlamlı ilk-5'i referansla aynı olan pencerelerin en az oranı (varsayılan 1.0)")
    a = ap.parse_args()

    out = os.path.abspath(a.out)
    cache = os.path.abspath(a.cache or os.path.join(out, "cache"))
    os.makedirs(out, exist_ok=True)
    zips = download(cache)
    raw = os.path.join(cache, "raw")
    k = extract(zips["BirdNET_v2.4_keras.zip"], ["audio-model.h5"], raw)
    t = extract(zips["BirdNET_v2.4_tflite.zip"],
                ["audio-model.tflite", "meta-model.tflite", "labels/en_us.txt", "labels/tr.txt"], raw)

    labels = read_labels(t["labels/en_us.txt"])
    tr_labels = read_labels(t["labels/tr.txt"])
    with open(os.path.join(out, "BirdNET_Labels.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(labels) + "\n")
    with open(os.path.join(out, "BirdNET_Labels_tr.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(tr_labels) + "\n")
    with open(os.path.join(out, "ATTRIBUTION.md"), "w", encoding="utf-8") as f:
        f.write(ATTRIBUTION)
    shutil.copyfile(os.path.join(REPO, "tools", "birdnet", "LICENSE.txt"), os.path.join(out, "LICENSE.txt"))

    weeks = week_list(t["meta-model.tflite"], labels, tr_labels)
    idx = list(range(N_CLASSES))
    if not a.global_model:
        # Uygulama yalnızca İstanbul için: model çıktısı listedeki türlere indirgenir.
        # "i" = indirgenmiş modeldeki sıra, "bi" = BirdNET'in özgün sınıf numarası
        idx = [s["i"] for s in weeks["species"]]
        for pos, sp in enumerate(weeks["species"]):
            sp["bi"] = sp["i"]
            sp["i"] = pos
        weeks["classes"] = len(idx)
        weeks["subset"] = "Model output pruned to these species (Istanbul); 'bi' = original BirdNET class index"
    sub_labels = [labels[j] for j in idx]
    write_week_json(weeks, os.path.join(out, "BirdNET_Istanbul_Weeks.json"))
    if a.week_json:
        write_week_json(weeks, a.week_json)

    log("Keras modeli yükleniyor ve spektrogram katmanları değiştiriliyor…")
    original, logits_model = load_models(k["audio-model.h5"])

    report = {"source": ZENODO, "files": FILES, "clips": {}}
    with tempfile.TemporaryDirectory() as tmp:
        clips = a.clips if a.clips is not None else default_clips(tmp)
        batches = {}
        for c in clips:
            try:
                batches[os.path.basename(c)] = windows(load_clip(c))
            except Exception as e:  # noqa: BLE001
                log(f"  {c} okunamadı: {e}")
        rng = np.random.default_rng(0)
        batches["gurultu"] = (rng.standard_normal((1, WINDOW)) * 0.05).astype(np.float32)
        if len(batches) < 3:
            raise SystemExit("Doğrulama için yeterli kayıt yok")

        log("Referans (TFLite) ile Keras eşdeğeri karşılaştırılıyor…")
        refs = {}
        for name, b in batches.items():
            refs[name] = tflite_logits(t["audio-model.tflite"], b)
            got = logits_model.predict(b, verbose=0)
            ok, _, n, _, rows = compare(f"{name} [keras-eşdeğeri]", refs[name], got, labels)
            report["clips"].setdefault(name, {})["keras_equivalent"] = {"top5_match": f"{ok}/{n}", "windows": rows}
            if ok != n:
                raise SystemExit(f"{name}: yeniden yazılmış spektrogram referansla uyuşmuyor")

        if not a.skip_coreml:
            model_out = logits_model if a.global_model else prune_to(logits_model, idx)
            if not a.global_model:
                for name, b in batches.items():
                    got = model_out.predict(b, verbose=0)
                    ok, _, n, _, _ = compare(f"{name} [istanbul-keras]", refs[name][:, idx], got, sub_labels)
                    if ok != n:
                        raise SystemExit(f"{name}: indirgenmiş model referansın alt kümesiyle uyuşmuyor")
            path = convert(model_out, out, sub_labels, len(idx))
            size = dir_size(path)
            report["mlpackage_bytes"] = size
            log(f"BirdNET.mlpackage: {size / 1e6:.1f} MB")
            if platform.system() == "Darwin":
                # CPU_ONLY zorunlu ölçüt; ALL (GPU/Neural Engine, FP16) bilgi amaçlı raporlanır
                for units in ("CPU_ONLY", "ALL"):
                    log(f"Core ML tahmini referansla karşılaştırılıyor ({units})…")
                    total = matched = relevant = 0
                    worst = 0.0
                    for name, b in batches.items():
                        try:
                            got = coreml_logits(path, b, units)
                            ref = refs[name][:, idx]
                        except Exception as e:  # noqa: BLE001
                            if units == "CPU_ONLY":
                                raise
                            log(f"  {units} çalıştırılamadı: {e}")
                            break
                        ok, rel, n, w, rows = compare(f"{name} [coreml {units}]", ref, got, sub_labels)
                        relevant += rel
                        worst = max(worst, w)
                        report["clips"][name][f"coreml_{units}"] = {"top5_match": f"{ok}/{n}", "windows": rows}
                        total += n
                        matched += ok
                    report[f"coreml_{units}_top5_match"] = f"{matched}/{total}"
                    report[f"coreml_{units}_top5_relevant_match"] = f"{relevant}/{total}"
                    report[f"coreml_{units}_max_prob_diff"] = worst
                    log(f"Core ML {units}: ilk-5 kümesi aynı {matched}/{total}, anlamlı ilk-5 (≥ {RELEVANT}) aynı "
                        f"{relevant}/{total} pencere, en büyük olasılık farkı {worst:.4f}")
                    if units == "CPU_ONLY" and (relevant < a.min_match * total or worst > MAX_PROB_DIFF):
                        with open(os.path.join(out, "validation.json"), "w", encoding="utf-8") as f:
                            json.dump(report, f, ensure_ascii=False, indent=1)
                        raise SystemExit(f"Core ML referansla uyuşmuyor: anlamlı ilk-5 {relevant}/{total}, "
                                         f"olasılık farkı {worst:.4f}")
            else:
                log("Core ML tahmini yalnızca macOS'ta çalışır; Core ML doğrulaması atlandı.")

    with open(os.path.join(out, "validation.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=1)
    log(f"Bitti → {out}")


if __name__ == "__main__":
    sys.exit(main())
