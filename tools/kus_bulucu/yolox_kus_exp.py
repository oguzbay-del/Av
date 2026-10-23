# YOLOX deney dosyası: YOLOX-S'in tek sınıf ("bird") ince ayarı (resmi YOLOX eğitim kodu, Apache-2.0).
# Kullanım (YOLOX kaynağı içinde): python tools/train.py -f <bu dosya> -d 2 -b 32 --fp16 -c <başlangıç.pth>
# Ayarlar ortamdan: VERI (veri.py çıktısı), EPOCHS, NO_AUG, TRAIN_ANN, VAL_ANN, LR (görüntü başına × 64),
# CIKTI_EGITIM (çıktı klasörü), ISCI (işlemci başına veri yükleyici).
import os

from yolox.exp import Exp as MyExp


class Exp(MyExp):
    def __init__(self):
        super().__init__()
        # YOLOX-S
        self.depth = 0.33
        self.width = 0.50
        self.num_classes = 1
        self.exp_name = "kus_bulucu"
        self.output_dir = os.environ.get("CIKTI_EGITIM", "./YOLOX_outputs")

        self.data_dir = os.environ.get("VERI", "/tmp/veri")
        self.train_ann = os.environ.get("TRAIN_ANN", "train.json")
        self.val_ann = os.environ.get("VAL_ANN", "izleme.json")
        self.data_num_workers = int(os.environ.get("ISCI", "4"))

        self.input_size = (640, 640)
        self.test_size = (640, 640)
        self.multiscale_range = 5  # 480–800
        # Küçük/uzak kuş için mosaic ölçeği küçültmeye kaydırıldı (varsayılan 0.1–2)
        self.mosaic_scale = (0.1, 1.5)
        self.mixup_scale = (0.5, 1.5)
        self.mosaic_prob = 1.0
        self.mixup_prob = 1.0
        self.enable_mixup = True

        # İnce ayar: COCO ağırlıklarından başlar; kısa ısınma, yarım öğrenme hızı
        self.max_epoch = int(os.environ.get("EPOCHS", "30"))
        self.no_aug_epochs = int(os.environ.get("NO_AUG", "5"))
        self.warmup_epochs = 1
        self.basic_lr_per_img = float(os.environ.get("LR", "0.005")) / 64.0
        self.eval_interval = int(os.environ.get("EVAL_INTERVAL", "5"))
        self.save_history_ckpt = False
        self.print_interval = 20
        self.test_conf = 0.001
        self.nmsthre = 0.65

    def get_eval_dataset(self, **kwargs):
        from yolox.data import COCODataset, ValTransform

        return COCODataset(data_dir=self.data_dir, json_file=self.val_ann, name="images",
                           img_size=self.test_size, preproc=ValTransform(legacy=kwargs.get("legacy", False)))

    def get_dataset(self, cache=False, cache_type="ram"):
        from yolox.data import COCODataset, TrainTransform

        return COCODataset(data_dir=self.data_dir, json_file=self.train_ann, name="images",
                           img_size=self.input_size,
                           preproc=TrainTransform(max_labels=50, flip_prob=self.flip_prob, hsv_prob=self.hsv_prob),
                           cache=cache, cache_type=cache_type)
