#!/usr/bin/env bash
# PR'ı CI yeşil olunca kendiliğinden birleştirir (squash). Sahibine sorulmaz (CLAUDE.md › Çalışma düzeni).
# Kullanım: tools/pr_birlestir.sh <PR numarası> [en çok bekleme dk, varsayılan 45]
# - PR'ın head commit'indeki tüm kontroller biter ve hepsi başarılı/atlanmış ise birleştirir.
# - Yol süzgeci yüzünden hiç kontrol başlamazsa (yalnızca belge PR'ı) 90 sn sonra birleştirir.
# - Bir kontrol başarısızsa birleştirmez, adlarını yazar ve 1 ile çıkar.
# - Beklerken PR'a yeni commit itilirse yeni head için baştan bekler; birleştirmede tam 40 karakterlik SHA verilir.
# GraphQL bulut oturumlarında kapalı olduğundan yalnızca REST (gh api) kullanılır.
set -euo pipefail

PR=${1:?PR numarası gerekli}
EN_COK_DK=${2:-45}
REPO=${REPO:-oguzbay-del/av}
BOS_BEKLE_SN=90
ARALIK_SN=30
BITIS=$(( $(date +%s) + EN_COK_DK * 60 ))

bilgi=$(gh api "repos/$REPO/pulls/$PR" --jq '[.state, .merged, .title] | @tsv')
IFS=$'\t' read -r durum birlesti baslik <<< "$bilgi"
if [ "$birlesti" = "true" ]; then echo "PR #$PR zaten birleşmiş."; exit 0; fi
if [ "$durum" != "open" ]; then echo "PR #$PR açık değil ($durum)."; exit 1; fi
echo "PR #$PR: $baslik"

sha=""
bas=0
while :; do
  yeni=$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha)
  if [ "$yeni" != "$sha" ]; then
    sha=$yeni
    bas=$(date +%s)
    echo "head $sha için kontroller bekleniyor"
  fi
  # name<TAB>status<TAB>conclusion
  satirlar=$(gh api "repos/$REPO/commits/$sha/check-runs?per_page=100" \
    --jq '.check_runs[] | [.name, .status, (.conclusion // "")] | @tsv')
  if [ -z "$satirlar" ]; then
    if [ $(( $(date +%s) - bas )) -ge "$BOS_BEKLE_SN" ]; then
      echo "Kontrol başlamadı (yol süzgeci; CI gerektirmeyen PR)."
      break
    fi
  else
    kosan=$(awk -F'\t' '$2 != "completed"' <<< "$satirlar" | wc -l)
    basarisiz=$(awk -F'\t' '$2 == "completed" && $3 != "success" && $3 != "skipped" && $3 != "neutral" {print $1" ("$3")"}' <<< "$satirlar")
    if [ -n "$basarisiz" ]; then
      echo "CI başarısız, birleştirilmedi:"; echo "$basarisiz"; exit 1
    fi
    if [ "$kosan" -eq 0 ]; then
      echo "Tüm kontroller yeşil: $(wc -l <<< "$satirlar")"
      break
    fi
  fi
  if [ "$(date +%s)" -ge "$BITIS" ]; then echo "Zaman aşımı ($EN_COK_DK dk); birleştirilmedi."; exit 1; fi
  sleep "$ARALIK_SN"
done

gh api -X PUT "repos/$REPO/pulls/$PR/merge" -f sha="$sha" -f merge_method=squash \
  -f commit_title="$baslik (#$PR)" --jq '"Birleşti: \(.sha)"'
