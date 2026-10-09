# BirdNET V2.4 — atıf / attribution

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
