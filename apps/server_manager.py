"""
VieNeu-TTS Multi-Server Manager
================================
FastAPI backend for managing multiple VPS servers running VieNeu-TTS.

Usage:
    uv run vieneu-manager          # Start on port 8080
    uv run vieneu-manager --port 9000
"""

import json
import os
import sys
import time
import uuid
import asyncio
import tempfile
import logging
from pathlib import Path
from typing import Optional, Dict, Any, List

import httpx
from fastapi import FastAPI, HTTPException, Query, UploadFile, File, Form
from fastapi.responses import HTMLResponse, FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

# --- Configuration ---
APP_DIR = Path(__file__).parent
PROJECT_ROOT = APP_DIR.parent
CONFIG_PATH = PROJECT_ROOT / "servers.json"
UI_PATH = APP_DIR / "server_ui.html"
OUTPUTS_DIR = PROJECT_ROOT / "outputs"
OUTPUTS_DIR.mkdir(exist_ok=True)
VOICES_DIR = OUTPUTS_DIR / "voices"
VOICES_DIR.mkdir(exist_ok=True)
CUSTOM_VOICES_JSON = VOICES_DIR / "custom_voices.json"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("VieNeu.Manager")

# --- Pydantic Models ---

class ServerConfig(BaseModel):
    id: str = Field(default_factory=lambda: str(uuid.uuid4())[:8])
    name: str = "New Server"
    host: str = "localhost"
    port: int = 23333
    is_default: bool = False
    model_name: str = "pnnbao-ump/VieNeu-TTS"
    description: str = ""
    use_https: bool = False


class ServerUpdate(BaseModel):
    name: Optional[str] = None
    host: Optional[str] = None
    port: Optional[int] = None
    is_default: Optional[bool] = None
    model_name: Optional[str] = None
    description: Optional[str] = None
    use_https: Optional[bool] = None


def get_api_base(server: ServerConfig) -> str:
    """Build API base URL, handling HTTPS and default ports."""
    protocol = "https" if server.use_https else "http"
    # Skip port for standard ports (443 for HTTPS, 80 for HTTP)
    if (server.use_https and server.port == 443) or (not server.use_https and server.port == 80):
        return f"{protocol}://{server.host}/v1"
    return f"{protocol}://{server.host}:{server.port}/v1"


class SynthesizeRequest(BaseModel):
    server_id: str
    text: str
    voice_name: Optional[str] = None
    custom_voice_id: Optional[str] = None  # for cloned voices
    temperature: float = 1.0
    top_k: int = 50
    max_chars: int = 256


class HealthResult(BaseModel):
    server_id: str
    name: str
    status: str  # "online", "offline", "error"
    latency_ms: Optional[float] = None
    models: Optional[List[str]] = None
    error: Optional[str] = None


# --- Server Config Store ---

class ServerStore:
    """Manages server configurations persisted to servers.json."""

    def __init__(self, config_path: Path):
        self.config_path = config_path
        self.servers: Dict[str, ServerConfig] = {}
        self._load()

    def _load(self):
        if self.config_path.exists():
            try:
                data = json.loads(self.config_path.read_text(encoding="utf-8"))
                for s in data.get("servers", []):
                    server = ServerConfig(**s)
                    self.servers[server.id] = server
                logger.info(f"Loaded {len(self.servers)} server(s) from {self.config_path.name}")
            except Exception as e:
                logger.error(f"Failed to load config: {e}")
                self.servers = {}
        else:
            # Create default config
            default = ServerConfig(
                id="local",
                name="Local Server",
                host="localhost",
                port=23333,
                is_default=True,
                description="Local LMDeploy instance",
            )
            self.servers[default.id] = default
            self._save()

    def _save(self):
        data = {"servers": [s.model_dump() for s in self.servers.values()]}
        self.config_path.write_text(
            json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8"
        )

    def list_all(self) -> List[ServerConfig]:
        return list(self.servers.values())

    def get(self, server_id: str) -> Optional[ServerConfig]:
        return self.servers.get(server_id)

    def get_default(self) -> Optional[ServerConfig]:
        for s in self.servers.values():
            if s.is_default:
                return s
        if self.servers:
            return next(iter(self.servers.values()))
        return None

    def add(self, server: ServerConfig) -> ServerConfig:
        if server.is_default:
            self._clear_default()
        self.servers[server.id] = server
        self._save()
        return server

    def update(self, server_id: str, updates: ServerUpdate) -> ServerConfig:
        if server_id not in self.servers:
            raise KeyError(f"Server '{server_id}' not found")
        server = self.servers[server_id]
        update_data = updates.model_dump(exclude_unset=True)
        if update_data.get("is_default"):
            self._clear_default()
        for key, val in update_data.items():
            setattr(server, key, val)
        self._save()
        return server

    def delete(self, server_id: str) -> bool:
        if server_id not in self.servers:
            return False
        del self.servers[server_id]
        self._save()
        return True

    def _clear_default(self):
        for s in self.servers.values():
            s.is_default = False


# --- Health Check Utility ---

async def check_server_health(server: ServerConfig, timeout: float = 5.0) -> HealthResult:
    """Check if a VieNeu-TTS server is reachable and get model info."""
    url = f"{get_api_base(server)}/models"
    start = time.monotonic()
    try:
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.get(url)
            latency = (time.monotonic() - start) * 1000
            if resp.status_code == 200:
                data = resp.json()
                models = []
                if "data" in data:
                    models = [m.get("id", "unknown") for m in data["data"]]
                return HealthResult(
                    server_id=server.id,
                    name=server.name,
                    status="online",
                    latency_ms=round(latency, 1),
                    models=models,
                )
            else:
                return HealthResult(
                    server_id=server.id,
                    name=server.name,
                    status="error",
                    latency_ms=round(latency, 1),
                    error=f"HTTP {resp.status_code}",
                )
    except httpx.ConnectError:
        return HealthResult(
            server_id=server.id,
            name=server.name,
            status="offline",
            error="Connection refused",
        )
    except httpx.TimeoutException:
        return HealthResult(
            server_id=server.id,
            name=server.name,
            status="offline",
            error="Timeout",
        )
    except Exception as e:
        return HealthResult(
            server_id=server.id,
            name=server.name,
            status="error",
            error=str(e),
        )


# --- Synthesis via Remote SDK ---

async def synthesize_via_server(
    server: ServerConfig,
    text: str,
    voice_name: Optional[str] = None,
    custom_voice_id: Optional[str] = None,
    temperature: float = 1.0,
    top_k: int = 50,
    max_chars: int = 256,
) -> Path:
    """
    Synthesize speech using a remote VieNeu-TTS server.
    Returns path to the generated WAV file.
    """
    api_base = get_api_base(server)

    # Use the SDK in remote mode
    from vieneu import Vieneu

    tts = Vieneu(
        mode="remote",
        api_base=api_base,
        model_name=server.model_name,
    )

    # Determine voice: custom clone vs preset
    voice_data = None
    ref_audio_path = None
    ref_text = None

    if custom_voice_id:
        # Use custom cloned voice
        custom_voice = _get_custom_voice(custom_voice_id)
        if custom_voice:
            ref_audio_path = VOICES_DIR / custom_voice["filename"]
            ref_text = custom_voice.get("ref_text", "")
            if not ref_audio_path.exists():
                logger.warning(f"Custom voice file not found: {ref_audio_path}")
                ref_audio_path = None
    elif voice_name:
        try:
            voice_data = tts.get_preset_voice(voice_name)
        except Exception:
            logger.warning(f"Voice '{voice_name}' not found, using default")

    # Run synthesis in thread pool to avoid blocking the event loop
    loop = asyncio.get_event_loop()
    wav = await loop.run_in_executor(
        None,
        lambda: tts.infer(
            text=text,
            voice=voice_data,
            ref_audio=str(ref_audio_path) if ref_audio_path else None,
            ref_text=ref_text if ref_audio_path else None,
            temperature=temperature,
            top_k=top_k,
            max_chars=max_chars,
        ),
    )

    # Save to file
    output_path = OUTPUTS_DIR / f"tts_{uuid.uuid4().hex[:8]}.wav"
    tts.save(wav, output_path)
    return output_path


# --- FastAPI App ---

app = FastAPI(title="VieNeu-TTS Server Manager", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

store = ServerStore(CONFIG_PATH)


# --- Routes ---

@app.get("/", response_class=HTMLResponse)
async def serve_ui():
    """Serve the main web UI."""
    if not UI_PATH.exists():
        return HTMLResponse("<h1>UI not found</h1><p>server_ui.html is missing.</p>", status_code=404)
    return HTMLResponse(UI_PATH.read_text(encoding="utf-8"))


@app.get("/api/servers")
async def list_servers():
    """List all registered servers."""
    return {"servers": [s.model_dump() for s in store.list_all()]}


@app.post("/api/servers")
async def add_server(server: ServerConfig):
    """Register a new server."""
    added = store.add(server)
    return {"server": added.model_dump()}


@app.put("/api/servers/{server_id}")
async def update_server(server_id: str, updates: ServerUpdate):
    """Update an existing server."""
    try:
        updated = store.update(server_id, updates)
        return {"server": updated.model_dump()}
    except KeyError:
        raise HTTPException(status_code=404, detail=f"Server '{server_id}' not found")


@app.delete("/api/servers/{server_id}")
async def delete_server(server_id: str):
    """Remove a server."""
    if store.delete(server_id):
        return {"ok": True}
    raise HTTPException(status_code=404, detail=f"Server '{server_id}' not found")


@app.get("/api/servers/{server_id}/health")
async def get_server_health(server_id: str):
    """Check health of a single server."""
    server = store.get(server_id)
    if not server:
        raise HTTPException(status_code=404, detail="Server not found")
    result = await check_server_health(server)
    return result.model_dump()


@app.get("/api/servers/health-all")
async def get_all_health():
    """Batch health check for all servers."""
    servers = store.list_all()
    tasks = [check_server_health(s) for s in servers]
    results = await asyncio.gather(*tasks)
    return {"results": [r.model_dump() for r in results]}


@app.get("/api/servers/{server_id}/voices")
async def get_server_voices(server_id: str):
    """List available voices on a server."""
    server = store.get(server_id)
    if not server:
        raise HTTPException(status_code=404, detail="Server not found")

    api_base = get_api_base(server)
    try:
        from vieneu import Vieneu
        loop = asyncio.get_event_loop()
        tts = await loop.run_in_executor(
            None,
            lambda: Vieneu(mode="remote", api_base=api_base, model_name=server.model_name),
        )
        voices = tts.list_preset_voices()
        return {
            "voices": [
                {"description": desc, "id": vid} for desc, vid in voices
            ]
        }
    except Exception as e:
        return {"voices": [], "error": str(e)}


@app.post("/api/synthesize")
async def synthesize(req: SynthesizeRequest):
    """Synthesize speech using a selected server."""
    server = store.get(req.server_id)
    if not server:
        raise HTTPException(status_code=404, detail="Server not found")

    try:
        output_path = await synthesize_via_server(
            server=server,
            text=req.text,
            voice_name=req.voice_name,
            custom_voice_id=req.custom_voice_id,
            temperature=req.temperature,
            top_k=req.top_k,
            max_chars=req.max_chars,
        )
        # Return the audio file URL
        filename = output_path.name
        return {"audio_url": f"/api/audio/{filename}", "filename": filename}
    except Exception as e:
        logger.error(f"Synthesis error: {e}", exc_info=True)
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/audio/{filename}")
async def serve_audio(filename: str):
    """Serve generated audio files."""
    file_path = OUTPUTS_DIR / filename
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="Audio file not found")
    return FileResponse(file_path, media_type="audio/wav")


# --- Custom Voice APIs ---

def _load_custom_voices() -> list:
    """Load custom voices metadata."""
    if CUSTOM_VOICES_JSON.exists():
        try:
            return json.loads(CUSTOM_VOICES_JSON.read_text(encoding="utf-8"))
        except Exception:
            return []
    return []

def _save_custom_voices(voices: list):
    """Save custom voices metadata."""
    CUSTOM_VOICES_JSON.write_text(json.dumps(voices, ensure_ascii=False, indent=2), encoding="utf-8")

def _get_custom_voice(voice_id: str) -> Optional[dict]:
    """Get a custom voice by ID."""
    for v in _load_custom_voices():
        if v["id"] == voice_id:
            return v
    return None


@app.get("/api/custom-voices")
async def list_custom_voices():
    """List all custom cloned voices."""
    return {"voices": _load_custom_voices()}


@app.post("/api/custom-voices")
async def upload_custom_voice(
    file: UploadFile = File(...),
    name: str = Form(...),
    ref_text: str = Form(""),
):
    """Upload audio file to create a custom cloned voice."""
    if not file.filename.lower().endswith((".wav", ".mp3", ".flac", ".ogg", ".m4a")):
        raise HTTPException(status_code=400, detail="Unsupported audio format. Use WAV, MP3, FLAC, OGG, or M4A.")

    voice_id = uuid.uuid4().hex[:8]
    ext = Path(file.filename).suffix.lower()
    filename = f"{voice_id}{ext}"
    file_path = VOICES_DIR / filename

    # Save uploaded file
    content = await file.read()
    file_path.write_bytes(content)

    # Add to metadata
    voices = _load_custom_voices()
    voice_entry = {
        "id": voice_id,
        "name": name,
        "filename": filename,
        "ref_text": ref_text,
        "created_at": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    voices.append(voice_entry)
    _save_custom_voices(voices)

    logger.info(f"🎙️ Custom voice uploaded: {name} ({filename})")
    return {"voice": voice_entry}


@app.delete("/api/custom-voices/{voice_id}")
async def delete_custom_voice(voice_id: str):
    """Delete a custom voice."""
    voices = _load_custom_voices()
    voice = next((v for v in voices if v["id"] == voice_id), None)
    if not voice:
        raise HTTPException(status_code=404, detail="Custom voice not found")

    # Delete audio file
    file_path = VOICES_DIR / voice["filename"]
    if file_path.exists():
        file_path.unlink()

    # Remove from metadata
    voices = [v for v in voices if v["id"] != voice_id]
    _save_custom_voices(voices)

    logger.info(f"🗑️ Custom voice deleted: {voice['name']}")
    return {"ok": True}


@app.get("/api/custom-voices/{voice_id}/audio")
async def serve_custom_voice_audio(voice_id: str):
    """Serve custom voice audio file for preview."""
    voice = _get_custom_voice(voice_id)
    if not voice:
        raise HTTPException(status_code=404, detail="Custom voice not found")
    file_path = VOICES_DIR / voice["filename"]
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="Audio file not found")
    return FileResponse(file_path, media_type="audio/wav")


# --- Entry Point ---

def main():
    import argparse
    import uvicorn

    parser = argparse.ArgumentParser(description="VieNeu-TTS Server Manager")
    parser.add_argument("--host", type=str, default="0.0.0.0", help="Bind host")
    parser.add_argument("--port", type=int, default=8080, help="Manager UI port")
    parser.add_argument("--reload", action="store_true", help="Auto-reload on changes")
    args = parser.parse_args()

    logger.info(f"🦜 VieNeu-TTS Server Manager starting on http://{args.host}:{args.port}")
    logger.info(f"📋 Server config: {CONFIG_PATH}")
    logger.info(f"🌐 Open http://localhost:{args.port} in your browser")

    uvicorn.run(
        "apps.server_manager:app",
        host=args.host,
        port=args.port,
        reload=args.reload,
    )


if __name__ == "__main__":
    main()
