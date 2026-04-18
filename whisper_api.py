#!/usr/bin/env python3
"""
Serviço de transcrição de voz com Whisper - API HTTP assíncrona, hackeável e extensível.
Correções:
- Gravação assíncrona (não bloqueia o Flask)
- Gerenciamento seguro do SQLite (evita locks e race conditions)
- Suporte a GPU via CUDA
- Escolha do método de chunking: "direct" (recomendado) ou "manual"
- Worker thread monitorada (health check)
- Logging estruturado
"""

import os
import sys
import json
import uuid
import hashlib
import sqlite3
import threading
import queue
import logging
import time
from datetime import datetime
from pathlib import Path
from collections import Counter

import numpy as np
import sounddevice as sd
import soundfile as sf
import whisper
import torch
from flask import Flask, request, jsonify

# ============================================================================
# Configuração e logging
# ============================================================================
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[logging.StreamHandler(sys.stderr)]
)
logger = logging.getLogger("whisper-api")

# Variáveis de ambiente
AUDIO_DIR = os.getenv("WHISPER_AUDIO_DIR", "./recordings")
DB_PATH = os.getenv("WHISPER_DB_PATH", "./transcriptions.db")
MODEL_NAME = os.getenv("WHISPER_MODEL", "large-v3-turbo")
CHUNK_DURATION = int(os.getenv("WHISPER_CHUNK_DURATION", "30"))  # usado apenas no método manual
SAMPLE_RATE = int(os.getenv("WHISPER_SAMPLE_RATE", "16000"))
CHANNELS = int(os.getenv("WHISPER_CHANNELS", "1"))
FLASK_HOST = os.getenv("WHISPER_HOST", "0.0.0.0")
FLASK_PORT = int(os.getenv("WHISPER_PORT", "8080"))
USE_CUDA = os.getenv("WHISPER_USE_CUDA", "auto").lower()  # auto, yes, no
CHUNKING_METHOD = os.getenv("WHISPER_CHUNKING_METHOD", "direct").lower()  # "direct" ou "manual"

# Cria pastas
Path(AUDIO_DIR).mkdir(parents=True, exist_ok=True)
Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)

# ============================================================================
# Inicialização do modelo Whisper com GPU se disponível
# ============================================================================
if USE_CUDA == "auto":
    device = "cuda" if torch.cuda.is_available() else "cpu"
elif USE_CUDA == "yes":
    device = "cuda"
else:
    device = "cpu"

logger.info(f"Carregando modelo Whisper '{MODEL_NAME}' no dispositivo: {device}")
model = whisper.load_model(MODEL_NAME, device=device)
logger.info(f"Modelo carregado. Device: {model.device}")
logger.info(f"Método de chunking: {CHUNKING_METHOD}")

# ============================================================================
# Banco de dados SQLite com lock para escrita (evita race conditions)
# ============================================================================
db_lock = threading.Lock()

def init_db():
    with db_lock:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        c.execute("""
            CREATE TABLE IF NOT EXISTS jobs (
                job_id TEXT PRIMARY KEY,
                audio_hash TEXT UNIQUE,
                audio_file TEXT,
                session_id TEXT,
                status TEXT,
                transcript TEXT,
                language TEXT,
                error TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP
            )
        """)
        c.execute("CREATE INDEX IF NOT EXISTS idx_hash ON jobs(audio_hash)")
        c.execute("CREATE INDEX IF NOT EXISTS idx_session ON jobs(session_id)")
        c.execute("CREATE INDEX IF NOT EXISTS idx_status ON jobs(status)")
        conn.commit()
        conn.close()

init_db()

def db_add_job(job_id, audio_hash, audio_file, session_id):
    with db_lock:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        try:
            c.execute(
                "INSERT INTO jobs (job_id, audio_hash, audio_file, session_id, status, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                (job_id, audio_hash, audio_file, session_id, "pending", datetime.now().isoformat())
            )
            conn.commit()
        except sqlite3.IntegrityError as e:
            logger.error(f"IntegrityError ao inserir job: {e}")
            raise
        finally:
            conn.close()

def db_update_job_status(job_id, status, transcript=None, language=None, error=None):
    with db_lock:
        conn = sqlite3.connect(DB_PATH)
        c = conn.cursor()
        if transcript is not None:
            c.execute(
                "UPDATE jobs SET status=?, transcript=?, language=?, error=?, updated_at=? WHERE job_id=?",
                (status, transcript, language, error, datetime.now().isoformat(), job_id)
            )
        else:
            c.execute(
                "UPDATE jobs SET status=?, error=?, updated_at=? WHERE job_id=?",
                (status, error, datetime.now().isoformat(), job_id)
            )
        conn.commit()
        conn.close()

def db_get_job(job_id):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT job_id, audio_hash, audio_file, session_id, status, transcript, language, error, created_at, updated_at FROM jobs WHERE job_id=?", (job_id,))
    row = c.fetchone()
    conn.close()
    if row:
        return {
            "job_id": row[0],
            "audio_hash": row[1],
            "audio_file": row[2],
            "session_id": row[3],
            "status": row[4],
            "transcript": row[5],
            "language": row[6],
            "error": row[7],
            "created_at": row[8],
            "updated_at": row[9]
        }
    return None

def db_get_by_hash(audio_hash):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT job_id, audio_hash, audio_file, session_id, status, transcript, language, error, created_at, updated_at FROM jobs WHERE audio_hash=?", (audio_hash,))
    row = c.fetchone()
    conn.close()
    if row:
        return {
            "job_id": row[0],
            "audio_hash": row[1],
            "audio_file": row[2],
            "session_id": row[3],
            "status": row[4],
            "transcript": row[5],
            "language": row[6],
            "error": row[7],
            "created_at": row[8],
            "updated_at": row[9]
        }
    return None

def db_list_by_session(session_id):
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT job_id, audio_hash, audio_file, session_id, status, transcript, language, created_at FROM jobs WHERE session_id=? ORDER BY created_at DESC", (session_id,))
    rows = c.fetchall()
    conn.close()
    return [
        {
            "job_id": r[0],
            "audio_hash": r[1],
            "audio_file": r[2],
            "session_id": r[3],
            "status": r[4],
            "transcript": r[5],
            "language": r[6],
            "created_at": r[7]
        } for r in rows
    ]

# ============================================================================
# Funções de áudio (gravação em thread separada)
# ============================================================================
def compute_file_hash(filepath):
    sha256 = hashlib.sha256()
    with open(filepath, "rb") as f:
        for block in iter(lambda: f.read(65536), b""):
            sha256.update(block)
    return sha256.hexdigest()

def record_audio_sync(duration_sec, output_path):
    """Gravação síncrona (executada em thread separada)."""
    logger.info(f"Gravando {duration_sec} segundos em {output_path}")
    recording = sd.rec(int(duration_sec * SAMPLE_RATE),
                       samplerate=SAMPLE_RATE,
                       channels=CHANNELS,
                       dtype='float32')
    sd.wait()
    sf.write(output_path, recording, SAMPLE_RATE)
    logger.info(f"Gravação concluída: {output_path}")
    return output_path

def split_audio_array(audio, sr, chunk_dur):
    """Divide um array numpy em pedaços de chunk_dur segundos."""
    chunk_samples = int(chunk_dur * sr)
    chunks = []
    for start in range(0, len(audio), chunk_samples):
        end = min(start + chunk_samples, len(audio))
        chunks.append(audio[start:end])
    return chunks

def transcribe_audio_file_direct(audio_path):
    """
    Método DIRETO: usa o Whisper internamente para gerenciar áudios longos.
    Recomendado para melhor precisão (janela deslizante com contexto).
    """
    use_fp16 = (model.device.type == "cuda")
    logger.info(f"Transcrevendo (direct) {audio_path} (fp16={use_fp16})")
    result = model.transcribe(audio_path, language=None, task="transcribe", fp16=use_fp16)
    text = result["text"].strip()
    lang = result["language"]
    logger.info(f"Transcrição concluída. Idioma: {lang}, texto: {text[:50]}...")
    return text, lang

def transcribe_audio_file_manual(audio_path):
    """
    Método MANUAL: divide o áudio em chunks de tamanho fixo.
    Útil para debugging ou controle fino, mas pode perder contexto nas bordas.
    """
    use_fp16 = (model.device.type == "cuda")
    logger.info(f"Transcrevendo (manual) {audio_path} (fp16={use_fp16})")
    
    audio = whisper.load_audio(audio_path)
    sr = 16000
    total_duration = len(audio) / sr

    if total_duration <= CHUNK_DURATION:
        result = model.transcribe(audio_path, language=None, task="transcribe", fp16=use_fp16)
        return result["text"].strip(), result["language"]

    logger.info(f"Áudio longo ({total_duration:.1f}s) -> dividindo em chunks de {CHUNK_DURATION}s")
    chunks = split_audio_array(audio, sr, CHUNK_DURATION)
    full_text = []
    detected_languages = []

    for i, chunk in enumerate(chunks):
        result = model.transcribe(chunk, language=None, task="transcribe", fp16=use_fp16)
        full_text.append(result["text"].strip())
        detected_languages.append(result["language"])
        logger.info(f"Chunk {i+1}/{len(chunks)} transcrito")

    main_lang = Counter(detected_languages).most_common(1)[0][0]
    return " ".join(full_text), main_lang

def transcribe_audio_file(audio_path):
    """Dispatcher: escolhe o método conforme variável de ambiente."""
    if CHUNKING_METHOD == "manual":
        return transcribe_audio_file_manual(audio_path)
    else:  # "direct" (padrão)
        return transcribe_audio_file_direct(audio_path)

# ============================================================================
# Fila de processamento e worker (com monitoramento)
# ============================================================================
task_queue = queue.Queue()
worker_running = True
def worker():
    """Thread que processa jobs da fila."""
    logger.info("Worker thread iniciada")
    while worker_running:
        try:
            job_id, audio_path, session_id, audio_hash = task_queue.get(timeout=1)
        except queue.Empty:
            continue
        try:
            logger.info(f"Processando job {job_id} - session={session_id}, audio={audio_path}")
            db_update_job_status(job_id, "processing")
            transcript, language = transcribe_audio_file(audio_path)
            db_update_job_status(job_id, "completed", transcript=transcript, language=language)
            logger.info(f"Job {job_id} (session {session_id}) concluído.")
        except Exception as e:
            error_msg = str(e)
            logger.error(f"Erro no job {job_id}: {error_msg}", exc_info=True)
            db_update_job_status(job_id, "failed", error=error_msg)
        finally:
            task_queue.task_done()
            
def worker_old():
    """Thread que processa jobs da fila."""
    logger.info("Worker thread iniciada")
    while worker_running:
        try:
            job_id, audio_path, session_id, audio_hash = task_queue.get(timeout=1)
        except queue.Empty:
            continue
        try:
            logger.info(f"Processando job {job_id} - {audio_path}")
            db_update_job_status(job_id, "processing")

            # Transcrição (método configurável)
            transcript, language = transcribe_audio_file(audio_path)

            db_update_job_status(job_id, "completed", transcript=transcript, language=language)
            logger.info(f"Job {job_id} concluído.")
        except Exception as e:
            error_msg = str(e)
            logger.error(f"Erro no job {job_id}: {error_msg}", exc_info=True)
            db_update_job_status(job_id, "failed", error=error_msg)
        finally:
            task_queue.task_done()
    logger.info("Worker thread encerrada")

worker_thread = threading.Thread(target=worker, daemon=True)
worker_thread.start()
def enqueue_recording(duration, session_id):
    """Agenda uma gravação e retorna job_id."""
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")[:-3]
    filename = f"rec_{timestamp}.wav"
    audio_path = os.path.join(AUDIO_DIR, filename)
    job_id = str(uuid.uuid4())
    
    logger.info(f"Agendando gravação: duração={duration}s, session_id={session_id}, job_id={job_id}")
    
    # Cria job pendente primeiro
    db_add_job(job_id, "pending_hash", filename, session_id)  # hash temporário
    
    def do_record():
        try:
            record_audio_sync(duration, audio_path)
            audio_hash = compute_file_hash(audio_path)
            with db_lock:
                conn = sqlite3.connect(DB_PATH)
                c = conn.cursor()
                c.execute("UPDATE jobs SET audio_hash=? WHERE job_id=?", (audio_hash, job_id))
                conn.commit()
                conn.close()
            existing = db_get_by_hash(audio_hash)
            if existing and existing["job_id"] != job_id and existing["status"] == "completed":
                db_update_job_status(job_id, "completed", transcript=existing["transcript"], language=existing["language"])
                logger.info(f"Áudio duplicado (hash {audio_hash}), resultado reaproveitado para job {job_id}")
                return
            task_queue.put((job_id, audio_path, session_id, audio_hash))
        except Exception as e:
            logger.error(f"Falha na gravação do job {job_id}: {e}", exc_info=True)
            db_update_job_status(job_id, "failed", error=str(e))
    
    threading.Thread(target=do_record, daemon=True).start()
    return job_id

def enqueue_recording_old(duration, session_id):
    """Agenda uma gravação e retorna job_id."""
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")[:-3]
    filename = f"rec_{timestamp}.wav"
    audio_path = os.path.join(AUDIO_DIR, filename)
    audio_hash = None
    job_id = str(uuid.uuid4())

    # Cria job pendente primeiro
    db_add_job(job_id, "pending_hash", filename, session_id)  # hash temporário
    # Agora inicia gravação em thread separada
    def do_record():
        try:
            record_audio_sync(duration, audio_path)
            audio_hash = compute_file_hash(audio_path)
            # Atualiza hash no banco
            with db_lock:
                conn = sqlite3.connect(DB_PATH)
                c = conn.cursor()
                c.execute("UPDATE jobs SET audio_hash=? WHERE job_id=?", (audio_hash, job_id))
                conn.commit()
                conn.close()
            # Verifica duplicata
            existing = db_get_by_hash(audio_hash)
            if existing and existing["job_id"] != job_id and existing["status"] == "completed":
                # Já existe transcrição pronta, copia resultado
                db_update_job_status(job_id, "completed", transcript=existing["transcript"], language=existing["language"])
                logger.info(f"Áudio duplicado (hash {audio_hash}), resultado reaproveitado.")
                return
            task_queue.put((job_id, audio_path, session_id, audio_hash))
        except Exception as e:
            logger.error(f"Falha na gravação do job {job_id}: {e}", exc_info=True)
            db_update_job_status(job_id, "failed", error=str(e))
    threading.Thread(target=do_record, daemon=True).start()
    return job_id

# ============================================================================
# API HTTP
# ============================================================================
app = Flask(__name__)

@app.route("/sessions", methods=["GET"])
def api_list_sessions():
    conn = sqlite3.connect(DB_PATH)
    c = conn.cursor()
    c.execute("SELECT DISTINCT session_id FROM jobs WHERE session_id != '' ORDER BY created_at DESC")
    rows = c.fetchall()
    conn.close()
    return jsonify([r[0] for r in rows])

@app.route("/health", methods=["GET"])
def health():
    worker_alive = worker_thread.is_alive()
    return jsonify({
        "status": "ok" if worker_alive else "degraded",
        "model": MODEL_NAME,
        "device": str(model.device),
        "queue_size": task_queue.qsize(),
        "worker_alive": worker_alive,
        "chunking_method": CHUNKING_METHOD
    })

@app.route("/record", methods=["POST"])
def api_record():
    """Grava áudio e agenda transcrição - retorna imediatamente."""
    data = request.get_json() or {}
    duration = data.get("duration")
    if not duration or not isinstance(duration, (int, float)) or duration <= 0:
        return jsonify({"error": "duration must be positive number"}), 400
    
    session_id = data.get("session_id", "").strip()
    if not session_id:
        # Gera um session_id padrão para não ficar vazio
        session_id = f"anonymous_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
        logger.info(f"Nenhum session_id fornecido, usando: {session_id}")
    
    job_id = enqueue_recording(duration, session_id)
    return jsonify({
        "job_id": job_id,
        "session_id": session_id,
        "status": "pending",
        "message": "Recording started, will be transcribed asynchronously"
    })

@app.route("/upload", methods=["POST"])
def api_upload():
    """Upload de arquivo de áudio."""
    if "file" not in request.files:
        return jsonify({"error": "No file part"}), 400
    file = request.files["file"]
    if file.filename == "":
        return jsonify({"error": "Empty filename"}), 400
    session_id = request.form.get("session_id", "")

    ext = Path(file.filename).suffix or ".wav"
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")[:-3]
    filename = f"upload_{timestamp}{ext}"
    audio_path = os.path.join(AUDIO_DIR, filename)
    file.save(audio_path)

    audio_hash = compute_file_hash(audio_path)
    job_id = str(uuid.uuid4())

    # Verificação atômica com lock
    with db_lock:
        existing = db_get_by_hash(audio_hash)
        if existing and existing["status"] == "completed":
            return jsonify({
                "job_id": existing["job_id"],
                "audio_hash": audio_hash,
                "audio_file": filename,
                "session_id": session_id,
                "status": "already_exists",
                "transcript": existing["transcript"]
            })
        db_add_job(job_id, audio_hash, filename, session_id)
    task_queue.put((job_id, audio_path, session_id, audio_hash))
    return jsonify({
        "job_id": job_id,
        "audio_hash": audio_hash,
        "audio_file": filename,
        "session_id": session_id,
        "status": "pending"
    })

@app.route("/job/<job_id>", methods=["GET"])
def api_job_status(job_id):
    job = db_get_job(job_id)
    if not job:
        return jsonify({"error": "Job not found"}), 404
    return jsonify(job)

@app.route("/message", methods=["GET"])
def api_message_by_hash():
    audio_hash = request.args.get("hash")
    if not audio_hash:
        return jsonify({"error": "Missing 'hash' parameter"}), 400
    job = db_get_by_hash(audio_hash)
    if not job:
        return jsonify({"error": "No message with this hash"}), 404
    return jsonify(job)

@app.route("/messages", methods=["GET"])
def api_messages_by_session():
    session_id = request.args.get("session")
    if not session_id:
        return jsonify({"error": "Missing 'session' parameter"}), 400
    rows = db_list_by_session(session_id)
    return jsonify(rows)

@app.route("/queue", methods=["GET"])
def api_queue_info():
    return jsonify({"pending_jobs": task_queue.qsize()})

# ============================================================================
# Ponto de entrada
# ============================================================================
if __name__ == "__main__":
    print(f"""
    ╔══════════════════════════════════════════════════════════════════╗
    ║  Whisper Async Transcription API - Hackeável e Extensível        ║
    ╠══════════════════════════════════════════════════════════════════╣
    ║  Audio dir:      {AUDIO_DIR}
    ║  Database:       {DB_PATH}
    ║  Model:          {MODEL_NAME} (device: {model.device})
    ║  Chunking:       {CHUNKING_METHOD}
    ║  API:            http://{FLASK_HOST}:{FLASK_PORT}
    ╠══════════════════════════════════════════════════════════════════╣
    ║  Endpoints:                                                      ║
    ║    POST   /record         -> grava duração (json: {{"duration":5}})║
    ║    POST   /upload         -> upload arquivo (multipart)          ║
    ║    GET    /job/<job_id>   -> status/resultado                    ║
    ║    GET    /message?hash=<hash> -> consulta por hash              ║
    ║    GET    /messages?session=<id> -> listar sessão                ║
    ║    GET    /queue          -> tamanho da fila                     ║
    ║    GET    /health         -> health check                        ║
    ╚══════════════════════════════════════════════════════════════════╝
    """)
    app.run(host=FLASK_HOST, port=FLASK_PORT, threaded=True)
