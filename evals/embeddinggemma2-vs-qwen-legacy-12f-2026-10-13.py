#!/usr/bin/env python3
"""A/B: EmbeddingGemma-2 CoreML (ANE) против Qwen3-Embedding-0.6B (bmem :8123).
Корпус = реальные md bm-native; запросы размечены по содержанию.
Метрики: top-1/top-3 accuracy, латентность эмбеддинга, косинус-согласованность моделей."""
import json, time, math, urllib.request, numpy as np, psutil, os, sys
from transformers import AutoTokenizer
import coremltools as ct

MODEL_DIR = os.path.expanduser("~/.bmem/models/embeddinggemma-2-coreml")
REPO = os.path.expanduser("~/Documents/AI-projects/bm-native")

DOCS = {
    "fix1":  f"{REPO}/docs/fix1-chunker-2026-10-12.md",
    "fix2":  f"{REPO}/docs/fix2-idle-unload-2026-10-12.md",
    "fix3":  f"{REPO}/docs/fix3-embed-cache-2026-10-12.md",
    "fix4":  f"{REPO}/docs/fix4-memory-pressure-2026-10-12.md",
    "fix5":  f"{REPO}/docs/fix5-dedup-mem-2026-10-12.md",
    "bench": f"{REPO}/docs/bench-baseline-2026-10-12.md",
    "roadmap": f"{REPO}/ROADMAP.md",
    "changelog": f"{REPO}/CHANGELOG.md",
    "audit": f"{REPO}/docs/AUDIT-2026-10-12.md",
    "connect": f"{REPO}/docs/CONNECTING.md",
    "release": f"{REPO}/RELEASE-NOTES.md",
    "idea":  f"{REPO}/IDEA.md",
}
QUERIES = [
    ("почему демон жрал 100 процентов cpu вечный цикл", "fix1"),
    ("как модель выгружается после простоя и через сколько секунд", "fix2"),
    ("контент-адресуемый кэш эмбеддингов md5 переэмбед только хвоста", "fix3"),
    ("давление памяти от операционной системы critical warning сброс", "fix4"),
    ("двойное индексирование подпапок дедуп метрики rss footprint", "fix5"),
    ("бенчмарк десять эталонных запросов ноль из десяти фикстуры", "bench"),
    ("что планируем дальше ключ api конфиг дорожная карта", "roadmap"),
    ("список изменений релиза версии фиксов", "changelog"),
    ("аудит текущего состояния продуктаCompetitors конкуренты", "audit"),
    ("как подключить hermes openclaw obsidian к памяти", "connect"),
    ("инструкция установки dmg перетащить приложения карантин", "release"),
    ("идея продукта зачем мы это строим второй мозг агентов", "idea"),
    # английский срез
    ("idle timeout unload model weights to save RAM", "fix2"),
    ("how to install the dmg on another mac", "release"),
]
# поправим опечатку в одном запросе (специально остаётся шум — честнее для обоих)
QUERIES[8] = ("аудит продукта и конкурентов что уже работает", "audit")

cfg = json.load(open(f"{MODEL_DIR}/config.json"))
PASSAGE_PREFIX = "title: none | text: "
QUERY_PREFIX = "task: search result | query: "
SCALE = cfg["embed_scale"]

tok = AutoTokenizer.from_pretrained(MODEL_DIR)
# таблица эмбеддингов: bf16 -> f32 через сдвиг, memmap чтобы не грузить 256 МБ в RAM дважды
table = np.memmap(f"{MODEL_DIR}/embeddings.bf16", dtype=np.uint16,
                  mode="r").reshape(262144, 512)

def embeds_for(texts, prefix):
    """список текстов -> матрица (inputs_embeds fp16, маски, длины) для функции embed_S"""
    vecs = []
    for t in texts:
        ids = [2] + tok(prefix + t, add_special_tokens=False)["input_ids"] + [1]
        ids = ids[:512]
        rows = np.asarray(table[ids], dtype=np.uint32) << 16
        vecs.append(rows.view(np.float32).reshape(len(ids), 512) * SCALE)
    S = max(len(v) for v in vecs)
    fn = min(s for s in (32, 48, 64, 128, 256, 512) if s >= S)
    batch = np.zeros((len(vecs), fn, 512), np.float16)
    mask = np.zeros((len(vecs), fn), np.float16)
    for i, v in enumerate(vecs):
        batch[i, : len(v)] = v.astype(np.float16)
        mask[i, : len(v)] = 1
    return fn, batch, mask

print("=== загрузка CoreML (первый компиль ANE может занять минуты) ===", flush=True)
t0 = time.time()
MODELS = {}
for fn in (32, 48, 64, 128, 256, 512):
    MODELS[fn] = ct.models.MLModel(f"{MODEL_DIR}/EmbeddingGemma2Text.mlpackage",
                                   compute_units=ct.ComputeUnit.ALL,
                                   function_name=f"embed_{fn}")
print(f"загрузка: {time.time()-t0:.1f} с", flush=True)

def gemma_embed(texts, prefix):
    out = np.zeros((len(texts), 768), np.float32)
    lat = []
    for i in range(len(texts)):
        fn, batch, mask = embeds_for([texts[i]], prefix)
        t1 = time.time()
        r = MODELS[fn].predict({"inputs_embeds": batch[0:1], "attention_mask": mask[0:1]})
        lat.append(time.time() - t1)
        e = np.asarray(r["embedding"], np.float32).reshape(-1)
        out[i] = e / (np.linalg.norm(e) + 1e-9)
    return out, lat

def qwen_embed(texts, is_query):
    # bmem OpenAI-совместимый эндпоинт; внутренняя префиксация — на стороне bmem
    req = urllib.request.Request("http://127.0.0.1:8123/v1/embeddings",
        data=json.dumps({"model": "qwen3-embedding", "input": texts}).encode(),
        headers={"Content-Type": "application/json"})
    lat = []
    t1 = time.time()
    data = json.loads(urllib.request.urlopen(req, timeout=300).read())["data"]
    lat.append((time.time() - t1) / max(1, len(texts)))
    V = np.array([d["embedding"] for d in sorted(data, key=lambda d: d["index"])], np.float32)
    V = V / (np.linalg.norm(V, axis=1, keepdims=True) + 1e-9)
    return V, lat

# --- корпус ---
names = list(DOCS)
corpus = [open(DOCS[n]).read()[:6000] for n in names]  # 6k симв. на файл, честнее для длинных
print(f"корпус: {len(corpus)} файлов, {sum(len(c)//1000 for c in corpus)}k символов", flush=True)

G, glat = gemma_embed(corpus, PASSAGE_PREFIX)
Qw, qlat = qwen_embed(corpus, False)
print(f"gemma индексация: {sum(glat):.1f} с за корпус; {np.mean(glat)*1000:.0f} мс/текст", flush=True)

# --- запросы ---
qs = [q for q, _ in QUERIES]
Gq, qglat = gemma_embed(qs, QUERY_PREFIX)
Qq, qqlat = qwen_embed(qs, True)

g1 = g3 = w1 = w3 = 0
rows = []
for i, (q, gold) in enumerate(QUERIES):
    gs = G @ Gq[i]; ws = Qw @ Qq[i]
    gtop = [names[j] for j in np.argsort(-gs)[:3]]
    wtop = [names[j] for j in np.argsort(-ws)[:3]]
    g1 += gtop[0] == gold; g3 += gold in gtop
    w1 += wtop[0] == gold; w3 += gold in wtop
    rows.append((q[:48], gold, gtop[0], wtop[0], gtop[0] == gold, wtop[0] == gold))

proc = psutil.Process(os.getpid())
print("\n=== РЕЗУЛЬТАТЫ ===")
for q, gold, gt, wt, gok, wok in rows:
    print(f"{'OK ' if gok else 'MISS'}{'/' if gok==wok else '  '}{'OK ' if wok else 'MISS'} gold={gold:9s} gemma->{gt:9s} qwen->{wt}")
print(f"\ngemma top-1 {g1}/{len(rows)}  top-3 {g3}/{len(rows)}   latency {np.median(glat)*1000:.0f} мс (ANE, {int(np.median(qglat)*1000)} мс запрос)")
print(f"qwen  top-1 {w1}/{len(rows)}  top-3 {w3}/{len(rows)}   latency batch {np.mean(qlat)*1000:.0f} мс/текст")
# согласованность между моделями на параллельных текстах
cos = (G @ Gq.T)
print(f"\npic RSS процесса стенда: {proc.memory_info().rss/1e6:.0f} МБ (включая таблицу 256МБ memmap — резидентно ~{psutil.Process(os.getpid()).memory_full_info().uss/1e6:.0f} МБ)")
