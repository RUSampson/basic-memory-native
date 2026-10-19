#!/usr/bin/env python3
"""A/B-приёмка: EmbeddingGemma-2 CoreML против боевого Qwen3-Embedding-0.6B.

Замороженный бенч: 50 размеченных запросов (RU/EN) на ЖИВОМ корпусе реестра
(~10.6k чанков заметок ai-projects + hermes/openclaw), не 12 файлов первой
пробы 13.10 (та сохранена в docs/embeddinggemma2-vs-qwen-2026-10-13.md).

Стенд:
  <stand>/home-qwen/.bmem/{bmem.db,config.json,models}  — копия боевой БД,
  <stand>/home-gemma/.bmem/...                            боевой бинарь
  qwen-сторона: ~/.local/bin/bmem (дефолтный бэкенд)
  gemma-сторона: bm-native/.build/release/bmem + BMEM_EMBED_BACKEND=gemma

Метрики: top-1/top-3 accuracy, латентность поиска (медина/p90) через сокет
демона, footprint в покое после idle-выгрузки, время повторной загрузки,
RSS/CPU под полным переиндексом, регрессия FIX-1..FIX-5 (идентичность
чанкера, idle-unload, memoryPressure по control-FIFO, mem-метрики в логе,
self-exit по BMEM_MEM_LIMIT_MB).

Запуск:  python3 embeddinggemma2-vs-qwen.py --stand <dir> [--side qwen|gemma]
Вывод:   <stand>/metrics.json + таблица в stdout; код 0 = прогон успешен
         (вердикт по порогу — в json поле verdict, не в коде выхода).

Порог приёмки (тело карточки): top-1 нового >= top-1 старого И >= 80%;
footprint покоя не выше старого; p90 поиска <= 2x старого.
"""
import argparse
import json
import os
import re
import socket
import sqlite3
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

try:
    import psutil
except ImportError:
    psutil = None

HOME_REAL = os.path.expanduser("~")
QWEN_BIN = f"{HOME_REAL}/.local/bin/bmem"
GEMMA_BIN = f"{HOME_REAL}/Documents/AI-projects/bm-native/.build/release/bmem"
CORPUS_ROOT = f"{HOME_REAL}/Documents/AI-projects"
PROJECT = "ai-projects"
IDLE_TIMEOUT = "45"           # секунды простоя до выгрузки (стенд, не бой)
SELFEXIT_LIMIT_MB = "100"     # заведомо ниже любого live-footprint → 5 подряд
SELFEXIT_INTERVAL = "5"

# --- Замороженная разметка: (запрос, gold rel_path в корпусе, lang) ---
# Золото проверено по содержанию файлов до прогонов 14.10.2026
# (regex-сверка каждого файла-эталона, см. docs/bench-gemma-2026-10-13.md).
QUERIES = [
    # --- bm-native: фиксы и бенчи (RU) ---
    ("почему демон жрал проц cpu вечный цикл квадратичный чанкер",
     "bm-native/docs/fix1-chunker-2026-10-12.md", "ru"),
    ("как модель выгружается после простоя и через сколько секунд",
     "bm-native/docs/fix2-idle-unload-2026-10-12.md", "ru"),
    ("кэш эмбеддингов по хэшу текста переэмбед только хвоста транскрипта",
     "bm-native/docs/fix3-embed-cache-2026-10-12.md", "ru"),
    ("давление памяти от операционной системы выгрузить модель dispatchsource",
     "bm-native/docs/fix4-memory-pressure-2026-10-12.md", "ru"),
    ("двойное индексирование подпапок дедуп самоликвидация демона при перерасходе",
     "bm-native/docs/fix5-dedup-mem-2026-10-12.md", "ru"),
    ("бенчмарк десять эталонных запросов ноль из десяти фикстуры санбокс",
     "bm-native/docs/bench-baseline-2026-10-12.md", "ru"),
    ("gemma против qwen что лучше из двух движков эмбеддингов",
     "bm-native/docs/embeddinggemma2-vs-qwen-2026-10-13.md", "ru"),
    ("coreml бэкенд embeddimggemma составной ключ embed_cache миграция ane",
     "bm-native/docs/emb1-gemma-coreml-2026-10-13.md", "ru"),
    ("как подключить hermes openclaw obsidian к памяти bmem",
     "bm-native/docs/CONNECTING.md", "ru"),
    ("дорожная карта bmem что дальше релиз публичный",
     "bm-native/ROADMAP.md", "ru"),
    ("аудит bm-native что реально работает а что было враньём",
     "bm-native/docs/AUDIT-2026-10-12.md", "ru"),
    # --- gateway-шлюз продукт (RU) ---
    ("зачем существует продукт gateway-шлюз философия аудит бастион",
     "gateway-proxy/PHILOSOPHY.md", "ru"),
    ("внутренний бреф продукта gateway-шлюз цели аудитория",
     "gateway-proxy/PRODUCT_BRIEF_INTERNAL.md", "ru"),
    ("allowlist ключей и маршрутная таблица кто куда ходит",
     "gateway-proxy/docs/MANIFEST/internal-policy.md", "ru"),
    ("перехват содержимого tty-стрима пользовательской сессии",
     "gateway-proxy/docs/MANIFEST/internal-intercept.md", "ru"),
    ("выдача кредов таргетов из openbao при подключении",
     "gateway-proxy/docs/MANIFEST/internal-secrets.md", "ru"),
    ("host-key прокси и пины таргетов транспорт",
     "gateway-proxy/docs/MANIFEST/internal-transport.md", "ru"),
    ("eBPF единственный способ перехвата команд внутри ssh-сессии проверка",
     "gateway-proxy/research/RESEARCH-2-EBPF-UNIQUENESS.md", "ru"),
    ("схемы маршрутизации ssh подключений через шлюзы бастионы pam",
     "gateway-proxy/research/SSH-CONNECTION-SCHEMES.md", "ru"),
    ("user story как пользователь ходит через коммерческий gateway-шлюз без агента",
     "gateway-proxy/docs-trial/USER-STORY-QA.md", "ru"),
    # --- инфраструктура: vault, dns, ci (RU) ---
    ("git-личности агентов ssh-сертификаты openbao для forgejo",
     "infra/home-lab/docs/git-identities.md", "ru"),
    ("как заходить в секретный vault и где брать креды",
     "infra/home-lab/vault-dev/docs/access-and-credentials.md", "ru"),
    ("vaultwarden или openbao что выбрать для нашего контура",
     "infra/agent-cicd/vaultwarden-vs-openbao.md", "ru"),
    ("работа с личным артефактом секретов age ключ расшифровка",
     "infra/agent-cicd/secrets-instructions.md", "ru"),
    ("dns ddi целевая архитектура kea powerdns на роутере",
     "infra/home-lab/dns/ARCHITECTURE.md", "ru"),
    ("каталог имён контейура доменная зона lab.example каркас обсуждения",
     "infra/home-lab/docs/naming-dns-2026-10-04.md", "ru"),
    ("выбор nas платформы для gen8 сравнение",
     "infra/home-lab/docs/nas-platform.md", "ru"),
    ("почему не заработала попытка docker внутри host-01 анализ",
     "infra/home-lab/docs/ANALIZE-2026-09-22.md", "ru"),
    ("openclaw на этом маке состояние tls wss локальные модели",
     "infra/home-lab/openclaw/README.md", "ru"),
    # --- vpn/sing-box (RU) ---
    ("финальный отчет какие vpn протоколы современные сравнение серверов",
     "net-research/research/2026-07-14/ФИНАЛЬНЫЙ_ОТЧЕТ.md", "ru"),
    ("архитектура приватной корпсети две плоскости где проверяется учётка",
     "net-research/ARCHITECTURE-2026-10.md", "ru"),
    ("сравнение админок 3x-ui и remnawave что поставить",
     "net-research/research/ui-panels/REPORT.md", "ru"),
    # --- cad-scan (RU) ---
    ("спецификация cad-scan on-prem из jpg в dxf и obj",
     "cad-scan/00_SPECIFICATION.md", "ru"),
    ("финальное ревью cad-scan вердикт шести субагентов",
     "cad-scan/08_FINAL_REVIEW.md", "ru"),
    ("e20 правка габаритов в реестре по числу названному человеком",
     "cad-scan/test/runs-2026-10-13/e20-recalibrate/RESULTS.md", "ru"),
    ("e23 склейка нескольких ракурсов детали в одну модель multiview",
     "cad-scan/test/runs-2026-10-14/e23-multiview/RESULTS.md", "ru"),
    ("очередь заданий cad-scan коллизия attempt и reaper зависших статусов",
     "cad-scan/test/runs-2026-10-14/queue-reaper/RESULTS.md", "ru"),
    # --- бизнес/маркетинг (RU) ---
    ("saas ai в N-ском городе анализ рынка и план запуска для новичка",
     "biz-research/SaaS-AI-RU-city-2026-report.md", "ru"),
    ("обогащение ресурсного пула план трендового бора живые ресурсы",
     "market-lab/docs/enrichment_plan.md", "ru"),
    ("сигналы рынка рф август saas ai iam подборка",
     "market-lab/output/2026-08-24/analysis/nws.md", "ru"),
    ("кто такой автор этих заметок",
     "identity/ME.md", "ru"),
    # --- hermes-экосистема (RU) ---
    ("исследование додумки лишние задачи вопросы вместо дела у агента",
     "agent-analysis/README.md", "ru"),
    ("бот в мессенджере max настройка hermes",
     "messenger-agent-ru/docs/MAX_BOT_SETUP.md", "ru"),
    ("имена специалистов sec-lab маппинг английских алиасов на русские фио",
     "sec-lab/AGENT_NAMES_RU.md", "ru"),
    # --- английские запросы ---
    ("how to install the dmg app on another mac and remove quarantine",
     "bm-native/RELEASE-NOTES.md", "en"),
    ("unload model weights after idle timeout to save RAM",
     "bm-native/docs/fix2-idle-unload-2026-10-12.md", "en"),
    ("content addressed embedding cache reindex only changed tail",
     "bm-native/docs/fix3-embed-cache-2026-10-12.md", "en"),
    ("drop the model when the OS reports memory pressure",
     "bm-native/docs/fix4-memory-pressure-2026-10-12.md", "en"),
    ("what is OpenBao introduction and core concepts",
     "infra/home-lab/vault-dev/docs/upstream/docs-what-is-openbao.md", "en"),
    ("AppRole authentication method machine credentials",
     "infra/home-lab/vault-dev/docs/upstream/docs-auth-approle.md", "en"),
    ("operator generate-root CLI command usage",
     "infra/home-lab/vault-dev/docs/upstream/docs-commands-operator-generate-root.md", "en"),
    ("forgejo runner registration token steps",
     "infra/home-lab/docs/upstream/forgejo-runner-registration.md", "en"),
    ("running multiple agent profiles configuration",
     "infra/agent-cicd/docs/upstream/hermes-profiles.md", "en"),
    ("fakeip how first DNS responses get cached in sing-box",
     "vendor-docs/sing-box/docs/configuration/dns/server/fakeip.md", "en"),
    ("DNS over QUIC DoQ server configuration",
     "vendor-docs/sing-box/docs/configuration/dns/server/quic.md", "en"),
    ("hysteria2 outbound protocol configuration",
     "vendor-docs/sing-box/docs/configuration/outbound/hysteria2.md", "en"),
    ("TUN inbound transparent proxy mode setup",
     "vendor-docs/sing-box/docs/configuration/inbound/tun.md", "en"),
    ("GENEVE encapsulation over IPsec deep research",
     "net-research/research/2026-10-01/GENEVE-OVER-IPSEC.md", "en"),
    ("how to connect ML models through API with timeouts in cad-scan",
     "cad-scan/API_MODELS.md", "en"),
    ("Google Trends RU search queries twelve months dataset",
     "market-lab/data/trends_queries.md", "en"),
    ("google trends search queries russian regions enrichment seeds",
     "market-lab/data/trends_queries.md", "en"),
    ("what is Bytebot open source AI desktop agent",
     "desktop-agent/docs/upstream/bytebot-README.md", "en"),
    ("sshpiper open source ssh gateway competitor card",
     "gateway-proxy/competitive/sshpiper.md", "en"),
    ("Teleport access platform competitor card",
     "gateway-proxy/competitive/teleport.md", "en"),
    ("HP iLO device discovery and vulnerability assessment procedure",
     "sec-lab/procedures/hp_ilo_discovery.md", "en"),
    ("installing Burp Bounty Pro plugin",
     "sec-lab/INSTALL.md", "en"),
    ("Shannon safety and limitations of automated pentest",
     "sec-lab/knowledge-base/tools/shannon/docs/safety.md", "en"),
    ("upgrading REA from version 6.1 to 6.2 migration notes",
     "reverse-lab/docs/migration-6.2.md", "en"),
    ("headerless raw binary analysis with Ghidra",
     "reverse-lab/docs/raw-binary.md", "en"),
    ("Notion clipboard case sources and scope evidence",
     "reverse-lab/website/evidence/notion-clipboard.md", "en"),
]


def now():
    return time.time()


class Daemon:
    """Наш стендовый демон: свой сокет, свой embed-порт off, свой лог."""

    def __init__(self, side, stand, extra_env=None, tag="main"):
        home = f"{stand}/home-{side}"
        binary = QWEN_BIN if side == "qwen" else GEMMA_BIN
        self.sock = f"{stand}/daemon-{side}-{tag}.sock"
        self.log = f"{stand}/daemon-{side}-{tag}.log"
        env = dict(os.environ)
        env.update({
            "HOME": home,
            "BMEM_DB": f"{home}/.bmem/bmem.db",
            "BMEM_SOCKET": self.sock,
            "BMEM_EMBED_PORT": "0",
            "BMEM_MODEL_IDLE_TIMEOUT": IDLE_TIMEOUT,
            "BMEM_MEM_LOG": self.log,
        })
        # 1.1.1: дефолт бинаря — gemma, поэтому qwen-сторону фиксируем явно,
        # иначе после деплоя обе стороны стенда молча поехали бы на gemma.
        env["BMEM_EMBED_BACKEND"] = "qwen" if side == "qwen" else "gemma"
        if extra_env:
            env.update(extra_env)
        # лог стенда — с чистого листа: иначе wait_log по append-файлу матчит
        # строку ВЫГРУЗКИ из прошлого прогона и печёт протухший footprint
        open(self.log, "w").close()
        fh = open(self.log, "a")
        self.p = subprocess.Popen([binary, "daemon"], env=env, stdout=fh,
                                  stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
        self.fh = fh

    def wait_socket(self, timeout=15):
        deadline = now() + timeout
        while now() < deadline:
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(0.5)
                s.connect(self.sock)
                s.close()
                return True
            except OSError:
                time.sleep(0.3)
        return False

    def wait_log(self, pattern, timeout=600):
        rx = re.compile(pattern)
        deadline = now() + timeout
        while now() < deadline:
            txt = open(self.log, errors="replace").read()
            m = rx.search(txt)
            if m:
                return m
            time.sleep(1)
        return None

    def logtail(self, n=40):
        return "\n".join(open(self.log, errors="replace").read().splitlines()[-n:])

    def stop(self):
        if self.p.poll() is None:
            self.p.terminate()
            try:
                self.p.wait(10)
            except subprocess.TimeoutExpired:
                self.p.kill()
        try:
            self.fh.close()
        except Exception:
            pass


def daemon_call(sock_path, tool, args, project=PROJECT, limit=3, timeout_ms=120_000):
    """Протокол Socket.swift: строка JSON + \\n, ответ строка JSON + \\n."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout_ms / 1000)
    s.connect(sock_path)
    payload = json.dumps({"tool": tool, "args": args, "project": project,
                          "limit": limit}).encode() + b"\n"
    s.sendall(payload)
    buf = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
        if buf.endswith(b"\n"):
            break
    s.close()
    obj = json.loads(buf)
    text = json.loads(obj["text"])
    return text, obj.get("isError", False)


class RssSampler(threading.Thread):
    """Пик RSS/средний CPU процесса и его детей — под нагрузкой переиндекса."""

    def __init__(self, cmdline_marker, interval=1.0):
        super().__init__(daemon=True)
        self.marker = cmdline_marker
        self.interval = interval
        self.peak_rss_mb = 0.0
        self.cpu_samples = []
        self.stop_flag = threading.Event()

    def run(self):
        while not self.stop_flag.is_set():
            total_rss = 0.0
            cpus = []
            for p in psutil.process_iter(["pid", "cmdline", "memory_info", "cpu_percent"]):
                try:
                    cl = " ".join(p.info["cmdline"] or [])
                    if self.marker in cl and "RssSampler" not in cl and "grep" not in cl:
                        total_rss += (p.info["memory_info"].rss if p.info["memory_info"] else 0)
                        if p.info["cpu_percent"] is not None:
                            cpus.append(p.info["cpu_percent"])
                except (psutil.NoSuchProcess, psutil.AccessDenied):
                    continue
            if total_rss:
                self.peak_rss_mb = max(self.peak_rss_mb, total_rss / 1e6)
                if cpus:
                    self.cpu_samples.append(sum(cpus) / len(cpus))
            self.stop_flag.wait(self.interval)

    def stop(self):
        self.stop_flag.set()
        self.join(5)


def phase_reindex(side, stand):
    """Полный переиндекс CLI: очистили embed_cache -> model_runs по всему корпусу."""
    db = sqlite3.connect(f"{stand}/home-{side}/.bmem/bmem.db")
    n0 = db.execute("SELECT COUNT(*) FROM embed_cache").fetchone()[0]
    db.execute("DELETE FROM embed_cache")
    db.commit()
    db.close()
    binary = QWEN_BIN if side == "qwen" else GEMMA_BIN
    env = dict(os.environ)
    env["HOME"] = f"{stand}/home-{side}"
    env["BMEM_DB"] = f"{stand}/home-{side}/.bmem/bmem.db"
    env["BMEM_SOCKET"] = f"{stand}/no-daemon-{side}.sock"
    # 1.1.1: qwen-сторона явная (дефолт бинаря после EMB-3 — gemma).
    env["BMEM_EMBED_BACKEND"] = "qwen" if side == "qwen" else "gemma"
    # env в cmdline не виден; CLI-индекс уникален подкомандой (демон = «daemon»,
    # mcp-прокси = «mcp», наш харнесс = python).
    sampler = RssSampler("index --project")
    sampler.start()
    t0 = now()
    r = subprocess.run([binary, "index", "--project", PROJECT], env=env,
                       capture_output=True, text=True, timeout=5400)
    wall = now() - t0
    sampler.stop()
    out = r.stdout + r.stderr
    mr = re.search(r"model_runs=(\d+)", out)
    ch = re.search(r"chunks=(\d+)", out)
    return {
        "embed_cache_before": n0,
        "wall_s": round(wall, 1),
        "model_runs": int(mr.group(1)) if mr else None,
        "chunks_total": int(ch.group(1)) if ch else None,
        "peak_rss_mb": round(sampler.peak_rss_mb),
        "avg_cpu_pct": round(statistics.mean(sampler.cpu_samples), 1) if sampler.cpu_samples else None,
        "rc": r.returncode,
        "tail": out.strip().splitlines()[-3:],
    }


def search_batch(side, stand, sock, queries):
    # NFC-нормализация путей: APFS отдаёт rel_path в NFD (ФИНАЛЬНЫЙ_ОТЧЕТ и т.п.),
    # байтовое сравнение с золотом давало бы ложный промах у обеих сторон.
    import unicodedata
    nfc = lambda p: unicodedata.normalize("NFC", p or "")
    rows = []
    for q, gold, lang in queries:
        t0 = now()
        text, is_err = daemon_call(sock, "search_notes", {"query": q})
        lat = (now() - t0) * 1000
        hits = text.get("results", []) if not is_err else []
        rels = [nfc(h.get("file_path", "").replace(CORPUS_ROOT + "/", "")) for h in hits]
        gold_n = nfc(gold)
        rows.append({
            "q": q, "gold": gold, "lang": lang,
            "top1": rels[0] if rels else None,
            "ok1": bool(rels) and rels[0] == gold_n,
            "ok3": gold_n in rels[:3],
            "score": hits[0].get("score") if hits else None,
            "lat_ms": round(lat),
            "err": is_err,
        })
    return rows


def phase_daemon(side, stand):
    fifo = f"{stand}/ctl-{side}.fifo"
    if not os.path.exists(fifo):
        os.mkfifo(fifo)
    d = Daemon(side, stand, extra_env={"BMEM_CONTROL_FIFO": fifo})
    if not d.wait_socket():
        raise RuntimeError(f"side {side}: демон не поднялся\n{d.logtail()}")
    warm_t = d.wait_log(r"bmem: daemon warm", timeout=1800)
    if not warm_t:
        raise RuntimeError(f"side {side}: daemon warm не дождались\n{d.logtail()}")
    res = {"daemon_startup_note": "warm wait включает инкрементальный reindex"}

    # прогрев модели (первый поиск может грузить модель)
    warmq = search_batch(side, stand, d.sock, [(QUERIES[0][0], QUERIES[0][1], "ru")])
    res["warmup_lat_ms"] = warmq[0]["lat_ms"]

    # бенч 50 запросов (модель горячая; lastUse обновляется, выгрузки не будет)
    rows = search_batch(side, stand, d.sock, QUERIES)
    lats = [r["lat_ms"] for r in rows]
    lats_sorted = sorted(lats)
    res["bench"] = {
        "n": len(rows),
        "top1": sum(1 for r in rows if r["ok1"]),
        "top3": sum(1 for r in rows if r["ok3"]),
        "top1_ru": sum(1 for r in rows if r["ok1"] and r["lang"] == "ru"),
        "n_ru": sum(1 for r in rows if r["lang"] == "ru"),
        "top1_en": sum(1 for r in rows if r["ok1"] and r["lang"] == "en"),
        "n_en": sum(1 for r in rows if r["lang"] == "en"),
        "lat_median_ms": int(statistics.median(lats)),
        "lat_p90_ms": int(lats_sorted[int(0.9 * (len(lats_sorted) - 1))]),
        "errors": sum(1 for r in rows if r["err"]),
    }
    res["bench_rows"] = rows

    # FIX-2 регрессия: idle-выгрузка
    idle_ok = d.wait_log(r"model unloaded after .*? idle, footprint (\d+)\s*MB",
                         timeout=int(IDLE_TIMEOUT) + 90)
    res["idle_unload"] = {
        "seen": bool(idle_ok),
        "footprint_after_unload_mb": int(idle_ok.group(1)) if idle_ok else None,
    }
    # повторная загрузка (ANE-кэш warm)
    reload_row = search_batch(side, stand, d.sock,
                              [(QUERIES[1][0], QUERIES[1][1], "ru")])[0]
    load_m = d.wait_log(r"model loaded in ([\d.]+) s", timeout=120)
    res["idle_unload"]["reload_model_s"] = float(load_m.group(1)) if load_m else None
    res["idle_unload"]["first_search_after_unload_ms"] = reload_row["lat_ms"]

    # FIX-4 регрессия: инъекция давления через control-FIFO
    w = open(fifo, "w")
    w.write("warning")
    w.close()
    warn_m = d.wait_log(r"memory pressure warning, shed ([\d.]+) MB", timeout=60)
    search_batch(side, stand, d.sock, [(QUERIES[2][0], QUERIES[2][1], "ru")])  # модель снова жива
    w = open(fifo, "w")
    w.write("critical")
    w.close()
    crit_m = d.wait_log(r"critical memory pressure, shed ([\d.]+) MB", timeout=60)
    res["fix4_pressure"] = {
        "warning_shed_mb": float(warn_m.group(1)) if warn_m else None,
        "critical_shed_mb": float(crit_m.group(1)) if crit_m else None,
    }

    # FIX-5 mem-метрики в логе (fmt строки «mem: rss …»)
    mem_line = d.wait_log(r"mem: rss \d+ MB footprint \d+ MB", timeout=int(IDLE_TIMEOUT))
    res["fix5_mem_metric_in_log"] = bool(mem_line)

    # RSS демона в покое (до idle-выгрузки он выше; меряем сразу после неё — уже поздно,
    # поэтому снимаем текущий psutil + сверяем с логом выгрузки)
    try:
        proc = psutil.Process(d.p.pid)
        res["daemon_rss_now_mb"] = round(proc.memory_info().rss / 1e6)
    except psutil.NoSuchProcess:
        pass
    d.stop()

    # FIX-5 self-exit: порог 100 МБ заведомо ниже live-footprint → выход по 5 замерам
    sx = Daemon(side, stand, tag="selfexit",
                extra_env={"BMEM_MEM_LIMIT_MB": SELFEXIT_LIMIT_MB,
                           "BMEM_MEM_INTERVAL_SEC": SELFEXIT_INTERVAL})
    sx.wait_socket()
    exited = None
    deadline = now() + 120
    while now() < deadline:
        if sx.p.poll() is not None:
            exited = sx.p.returncode
            break
        time.sleep(1)
    res["fix5_self_exit"] = {
        "exited": exited is not None,
        "exit_code": exited,
        "over_limit_log": bool(re.search(r"over limit, exiting",
                                         open(sx.log, errors="replace").read())),
    }
    sx.stop()
    return res


def chunker_signature(stand, side):
    """FIX-1: границы чанков = content_hash каждого чанка; агрегат по проекту."""
    import hashlib
    db = sqlite3.connect(f"file:{stand}/home-{side}/.bmem/bmem.db?mode=ro", uri=True)
    h = hashlib.md5()
    n = 0
    for (ch,) in db.execute(
            "SELECT c.content_hash FROM chunks c JOIN notes nt ON nt.id=c.note_id "
            "WHERE c.project=? AND nt.rel_path NOT LIKE 'bm-native/scratch/%' "
            "ORDER BY nt.rel_path, c.ord", (PROJECT,)):
        h.update(ch.encode())
        n += 1
    db.close()
    return {"chunks": n, "md5_of_hashes": h.hexdigest()}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stand", required=True)
    ap.add_argument("--side", choices=["qwen", "gemma"], default=None,
                    help="одна сторона (для рестарта после сбоя); по умолчанию обе")
    ap.add_argument("--skip-reindex", action="store_true",
                    help="не гонять полный переиндекс (бенч+регрессии по горячему кэшу)")
    args = ap.parse_args()
    stand = os.path.abspath(args.stand)

    sides = [args.side] if args.side else ["qwen", "gemma"]
    metrics_path = f"{stand}/metrics.json"
    metrics = json.load(open(metrics_path)) if os.path.exists(metrics_path) else {}

    for side in sides:
        print(f"=== сторона {side} ===", flush=True)
        m = metrics.get(side, {})
        if not args.skip_reindex:
            m["reindex_full"] = phase_reindex(side, stand)
            print(f"[{side}] полный переиндекс: {m['reindex_full']}", flush=True)
        m["daemon"] = phase_daemon(side, stand)
        print(f"[{side}] бенч: {m['daemon']['bench']}", flush=True)
        metrics[side] = m
        json.dump(metrics, open(metrics_path, "w"), ensure_ascii=False, indent=1)

    metrics["chunker_signature"] = {s: chunker_signature(stand, s) for s in ["qwen", "gemma"]}
    metrics["chunker_identical"] = (
        metrics["chunker_signature"]["qwen"] == metrics["chunker_signature"]["gemma"])

    # --- порог приёмки ---
    g, q = metrics.get("gemma", {}).get("daemon", {}).get("bench"), \
            metrics.get("qwen", {}).get("daemon", {}).get("bench")
    gate = {}
    if g and q:
        gate["top1_new_ge_old"] = g["top1"] >= q["top1"]
        gate["top1_new_ge_80pct"] = g["top1"] >= 0.8 * g["n"]
        fp_new = metrics["gemma"]["daemon"]["idle_unload"]["footprint_after_unload_mb"]
        fp_old = metrics["qwen"]["daemon"]["idle_unload"]["footprint_after_unload_mb"]
        gate["idle_footprint_not_higher"] = (fp_new is not None and fp_old is not None
                                             and fp_new <= fp_old)
        gate["p90_le_2x_old"] = g["lat_p90_ms"] <= 2 * q["lat_p90_ms"]
        gate["chunker_identical"] = metrics["chunker_identical"]
        metrics["verdict"] = {
            "gate": gate,
            "release_ready": all(gate.values()),
        }
    json.dump(metrics, open(metrics_path, "w"), ensure_ascii=False, indent=1)
    print("\n=== ИТОГ ===")
    print(json.dumps(metrics.get("verdict", "не хватает данных"), ensure_ascii=False, indent=1))
    print(f"metrics: {metrics_path}")


if __name__ == "__main__":
    main()
