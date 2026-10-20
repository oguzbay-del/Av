#!/usr/bin/env bash
# Av Haritası — kuş tanıma sunucusu (Cloud Run) için tek seferlik Google Cloud kurulumu.
#
# Google Cloud Shell'de (https://shell.cloud.google.com) çalıştırın:
#   bash <(curl -fsSL https://raw.githubusercontent.com/oguzbay-del/Av/main/tools/kus_sunucu/gcp_kurulum.sh)
#   bash <(curl -fsSL ...) PROJE_KIMLIGI                  # etkin proje yerine başka proje
#   bash <(curl -fsSL ...) --butce FATURA_HESABI_KIMLIGI   # ek olarak 5 USD bütçe uyarısı
#
# Yaptıkları: API'leri açar, Artifact Registry deposu (eski imajları silen temizlik
# ilkesiyle), GitHub Actions'ın anahtarsız (Workload Identity Federation) dağıtım
# yapacağı hizmet hesabını ve sunucunun yetkisiz çalışma hesabını oluşturur.
# Hiçbir anahtar dosyası üretilmez. Tekrar çalıştırmak güvenlidir.
set -euo pipefail

BOLGE="europe-west1"
DEPO="av-haritasi"
GITHUB_DEPO="oguzbay-del/Av"
HAVUZ="github"
SAGLAYICI="github"
DAGITIM_SA_AD="github-deploy"
CALISMA_SA_AD="kus-sunucu"
BUTCE_AD="Av Haritasi kus sunucu (5 USD)"

yardim() {
  cat <<'EOF'
Kullanım: gcp_kurulum.sh [PROJE_KIMLIGI] [--butce FATURA_HESABI_KIMLIGI]
  PROJE_KIMLIGI  verilmezse etkin gcloud projesi kullanılır (gcloud config get-value project)
  --butce        aylık 5 USD bütçe uyarısı oluşturur (fatura hesabı kimliği: 0X0X0X-0X0X0X-0X0X0X;
                 listelemek için: gcloud billing accounts list)
EOF
}

PROJE=""
BUTCE_HESAP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --butce)
      [[ $# -ge 2 && -n "$2" ]] || { echo "HATA: --butce için fatura hesabı kimliği gerekli." >&2; exit 2; }
      BUTCE_HESAP="$2"; shift 2 ;;
    --butce=*) BUTCE_HESAP="${1#*=}"; shift ;;
    -h|--help) yardim; exit 0 ;;
    -*) echo "HATA: bilinmeyen seçenek: $1" >&2; yardim >&2; exit 2 ;;
    *) PROJE="$1"; shift ;;
  esac
done

adim() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
uyari() { printf '\033[1;33mUYARI: %s\033[0m\n' "$*" >&2; }
hata() { printf '\033[1;31mHATA: %s\033[0m\n' "$*" >&2; exit 1; }

# Yeni oluşturulan hesaplar IAM'de birkaç saniye geç görünebilir; birkaç kez dene.
tekrarla() {
  local i
  for i in 1 2 3 4 5; do
    if "$@"; then return 0; fi
    echo "  ... yeniden deneniyor ($i/5)" >&2
    sleep 10
  done
  "$@"
}

command -v gcloud >/dev/null || hata "gcloud bulunamadı. Bu betiği Google Cloud Shell'de çalıştırın."

if [[ -z "$PROJE" ]]; then
  PROJE="$(gcloud config get-value project 2>/dev/null || true)"
fi
if [[ -z "$PROJE" || "$PROJE" == "(unset)" ]]; then
  hata "Proje seçili değil. 'gcloud config set project PROJE_KIMLIGI' çalıştırın ya da proje kimliğini betiğe argüman olarak verin."
fi

# Bütün gcloud komutları bu projeyi kullansın ve hiçbir soru sormasın.
export CLOUDSDK_CORE_PROJECT="$PROJE"
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

adim "Proje denetleniyor: $PROJE"
PROJE_NO="$(gcloud projects describe "$PROJE" --format='value(projectNumber)')" \
  || hata "Proje bulunamadı ya da erişim yok: $PROJE"
[[ -n "$PROJE_NO" ]] || hata "Proje numarası okunamadı: $PROJE"
echo "Proje numarası: $PROJE_NO"

FATURA="$(gcloud billing projects describe "$PROJE" --format='value(billingEnabled)' 2>/dev/null || echo bilinmiyor)"
if [[ "$FATURA" == "False" ]]; then
  hata "Projeye fatura hesabı bağlı değil. Konsolda Faturalandırma > Hesabı bağla adımını tamamlayıp tekrar çalıştırın: https://console.cloud.google.com/billing/linkedaccount?project=$PROJE"
elif [[ "$FATURA" != "True" ]]; then
  uyari "Fatura durumu okunamadı; devam ediliyor (API açılamazsa fatura bağlantısını denetleyin)."
fi

adim "API'ler açılıyor (birkaç dakika sürebilir)"
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  secretmanager.googleapis.com \
  cloudresourcemanager.googleapis.com

adim "Artifact Registry deposu: $DEPO ($BOLGE)"
if gcloud artifacts repositories describe "$DEPO" --location="$BOLGE" >/dev/null 2>&1; then
  echo "Depo zaten var."
else
  gcloud artifacts repositories create "$DEPO" \
    --repository-format=docker \
    --location="$BOLGE" \
    --description="Av Haritasi kus tanima sunucusu imajlari"
fi

# Depolama ücreti düşük kalsın: en yeni 2 imaj sürümü dışındakiler silinir
# (temizlik arka planda, yaklaşık günde bir çalışır; "Keep" ilkesi önceliklidir).
ILKE="$(mktemp)"
trap 'rm -f "$ILKE"' EXIT
cat >"$ILKE" <<'EOF'
[
  {
    "name": "eskileri-sil",
    "action": {"type": "Delete"},
    "condition": {"tagState": "any"}
  },
  {
    "name": "son-2-surumu-tut",
    "action": {"type": "Keep"},
    "mostRecentVersions": {"keepCount": 2}
  }
]
EOF
gcloud artifacts repositories set-cleanup-policies "$DEPO" \
  --location="$BOLGE" --policy="$ILKE" --no-dry-run >/dev/null
echo "Temizlik ilkesi: en yeni 2 sürüm tutulur."

sa_olustur() {  # $1 = hesap adı, $2 = görünen ad
  local eposta="$1@$PROJE.iam.gserviceaccount.com"
  if gcloud iam service-accounts describe "$eposta" >/dev/null 2>&1; then
    echo "Hizmet hesabı zaten var: $eposta"
  else
    gcloud iam service-accounts create "$1" --display-name="$2"
  fi
}

DAGITIM_SA="$DAGITIM_SA_AD@$PROJE.iam.gserviceaccount.com"
CALISMA_SA="$CALISMA_SA_AD@$PROJE.iam.gserviceaccount.com"

adim "Hizmet hesapları"
# Çalışma hesabı: sunucu bununla çalışır; hiçbir rolü yoktur (modeller imajda, dış erişim gerekmez).
sa_olustur "$CALISMA_SA_AD" "Kus sunucu (Cloud Run calisma hesabi)"
# Dağıtım hesabı: yalnızca GitHub Actions kullanır.
sa_olustur "$DAGITIM_SA_AD" "GitHub Actions dagitim"

adim "Dağıtım hesabına en az yetki veriliyor"
# Cloud Run hizmetini oluşturma/güncelleme ve herkese açma (allUsers invoker) için run.admin.
tekrarla gcloud projects add-iam-policy-binding "$PROJE" \
  --member="serviceAccount:$DAGITIM_SA" --role="roles/run.admin" --condition=None >/dev/null
# İmaj itme yetkisi yalnızca bu depoda.
tekrarla gcloud artifacts repositories add-iam-policy-binding "$DEPO" --location="$BOLGE" \
  --member="serviceAccount:$DAGITIM_SA" --role="roles/artifactregistry.writer" >/dev/null
# Hizmeti çalışma hesabıyla dağıtabilmek için (actAs) yalnızca o hesap üzerinde.
tekrarla gcloud iam service-accounts add-iam-policy-binding "$CALISMA_SA" \
  --member="serviceAccount:$DAGITIM_SA" --role="roles/iam.serviceAccountUser" >/dev/null
echo "Roller: run.admin (proje), artifactregistry.writer ($DEPO), iam.serviceAccountUser ($CALISMA_SA_AD)"

adim "Workload Identity Federation: havuz '$HAVUZ'"
HAVUZ_DURUM="$(gcloud iam workload-identity-pools describe "$HAVUZ" --location=global --format='value(state)' 2>/dev/null || true)"
if [[ -z "$HAVUZ_DURUM" ]]; then
  gcloud iam workload-identity-pools create "$HAVUZ" --location=global --display-name="GitHub Actions"
elif [[ "$HAVUZ_DURUM" == "DELETED" ]]; then
  gcloud iam workload-identity-pools undelete "$HAVUZ" --location=global
else
  echo "Havuz zaten var ($HAVUZ_DURUM)."
fi

adim "Workload Identity Federation: OIDC sağlayıcı '$SAGLAYICI'"
ESLEME="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref"
# Yalnızca bu GitHub deposunun iş akışları belirteç alabilsin.
KOSUL="assertion.repository=='$GITHUB_DEPO'"
SAGLAYICI_DURUM="$(gcloud iam workload-identity-pools providers describe "$SAGLAYICI" \
  --location=global --workload-identity-pool="$HAVUZ" --format='value(state)' 2>/dev/null || true)"
if [[ -z "$SAGLAYICI_DURUM" ]]; then
  gcloud iam workload-identity-pools providers create-oidc "$SAGLAYICI" \
    --location=global --workload-identity-pool="$HAVUZ" \
    --display-name="GitHub OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="$ESLEME" \
    --attribute-condition="$KOSUL"
else
  if [[ "$SAGLAYICI_DURUM" == "DELETED" ]]; then
    gcloud iam workload-identity-pools providers undelete "$SAGLAYICI" \
      --location=global --workload-identity-pool="$HAVUZ"
  fi
  # Var olan sağlayıcının eşleme ve koşulunu da güncel tut.
  gcloud iam workload-identity-pools providers update-oidc "$SAGLAYICI" \
    --location=global --workload-identity-pool="$HAVUZ" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="$ESLEME" \
    --attribute-condition="$KOSUL" >/dev/null
  echo "Sağlayıcı güncellendi."
fi

adim "GitHub deposu ($GITHUB_DEPO) dağıtım hesabını kullanabilsin"
HAVUZ_ADI="projects/$PROJE_NO/locations/global/workloadIdentityPools/$HAVUZ"
tekrarla gcloud iam service-accounts add-iam-policy-binding "$DAGITIM_SA" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/$HAVUZ_ADI/attribute.repository/$GITHUB_DEPO" >/dev/null

if [[ -n "$BUTCE_HESAP" ]]; then
  adim "Bütçe uyarısı (5 USD/ay, %50 / %90 / %100)"
  if ! gcloud services enable billingbudgets.googleapis.com; then
    uyari "Bütçe API'si açılamadı; bütçe adımı atlandı."
  elif gcloud billing budgets list --billing-account="$BUTCE_HESAP" --billing-project="$PROJE" \
        --format='value(displayName)' 2>/dev/null | grep -Fqx "$BUTCE_AD"; then
    echo "Bütçe zaten var."
  elif gcloud billing budgets create \
        --billing-account="$BUTCE_HESAP" \
        --billing-project="$PROJE" \
        --display-name="$BUTCE_AD" \
        --budget-amount=5USD \
        --calendar-period=month \
        --filter-projects="projects/$PROJE_NO" \
        --threshold-rule=percent=0.5 \
        --threshold-rule=percent=0.9 \
        --threshold-rule=percent=1.0 >/dev/null; then
    echo "Bütçe oluşturuldu; uyarılar fatura yöneticilerine e-postayla gelir."
  else
    uyari "Bütçe oluşturulamadı (yetki yok ya da fatura hesabının para birimi USD değil). Konsoldan elle ekleyebilirsiniz: https://console.cloud.google.com/billing/budgets"
  fi
fi

SAGLAYICI_ADI="$HAVUZ_ADI/providers/$SAGLAYICI"
cat <<EOF


================================================================================
 KURULUM TAMAM. Şimdi GitHub'da şu 3 depo DEĞİŞKENİNİ (Variables, sır değil) ekleyin:
 https://github.com/$GITHUB_DEPO/settings/variables/actions  →  "New repository variable"
================================================================================

 Ad:    GCP_PROJECT
 Değer: $PROJE

 Ad:    GCP_WIF_PROVIDER
 Değer: $SAGLAYICI_ADI

 Ad:    GCP_DEPLOY_SA
 Değer: $DAGITIM_SA

================================================================================
 Sonra: Actions → "Kuş sunucusu (Cloud Run)" → Run workflow.
 (Yeni yetkilerin etkinleşmesi birkaç dakika sürebilir; ilk deneme yetki hatası
 verirse 5 dakika bekleyip yeniden çalıştırın.)
================================================================================
EOF
