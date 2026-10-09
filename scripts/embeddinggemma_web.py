#!/usr/bin/env python3
import argparse
import html
import os
from pathlib import Path
from typing import Annotated

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field
from starlette.middleware.trustedhost import TrustedHostMiddleware

MODEL_ID = "google/embeddinggemma-2"
VALID_DIMS = (128, 256, 512, 768)
MAX_INPUTS = 16
MAX_TEXT_LENGTH = 8192
MAX_SEARCH_FILES = 200
MAX_SEARCH_CHUNKS = 100
model = None
SEARCH_ROOT = Path(os.environ.get("TERMUX_AI_SEARCH_ROOT", str(Path.home()))).expanduser().resolve()


def get_model():
    global model
    if model is None:
        from sentence_transformers import SentenceTransformer

        model = SentenceTransformer(
            MODEL_ID,
            config_kwargs={"vision_config": None, "audio_config": None},
        )
    return model


class EmbeddingRequest(BaseModel):
    input: str | list[str]
    model: str = MODEL_ID
    dimensions: int = Field(default=256, strict=True)


class CompareRequest(BaseModel):
    query: Annotated[str, Field(min_length=1, max_length=MAX_TEXT_LENGTH)]
    document: Annotated[str, Field(min_length=1, max_length=MAX_TEXT_LENGTH)]
    dimensions: int = Field(default=256, strict=True)


class SearchRequest(BaseModel):
    query: Annotated[str, Field(min_length=1, max_length=MAX_TEXT_LENGTH)]
    path: Annotated[str, Field(min_length=1, max_length=4096)]
    top: int = Field(default=5, ge=1, le=20)
    dimensions: int = Field(default=256, strict=True)


def check_dimensions(dimensions: int) -> None:
    if dimensions not in VALID_DIMS:
        raise HTTPException(status_code=422, detail=f"dimensions must be one of {VALID_DIMS}")


def check_texts(texts: list[str]) -> None:
    if not texts or len(texts) > MAX_INPUTS:
        raise HTTPException(status_code=422, detail=f"input must contain between 1 and {MAX_INPUTS} texts")
    if any(not text.strip() or len(text) > MAX_TEXT_LENGTH for text in texts):
        raise HTTPException(status_code=422, detail=f"texts must be non-empty and no longer than {MAX_TEXT_LENGTH} characters")


app = FastAPI(title="EmbeddingGemma 2 Local", docs_url=None, redoc_url=None)
app.add_middleware(TrustedHostMiddleware, allowed_hosts=["127.0.0.1", "localhost", "[::1]"])


@app.get("/", response_class=HTMLResponse)
def home():
    return HTML.replace("__SEARCH_PATH__", html.escape(str(SEARCH_ROOT), quote=True))


@app.get("/health")
def health():
    return {"status": "ok", "model": MODEL_ID}


@app.get("/v1/models")
def list_models():
    return {
        "object": "list",
        "data": [{"id": MODEL_ID, "object": "model", "owned_by": "google"}],
    }


@app.post("/v1/embeddings")
def embeddings(request: EmbeddingRequest):
    check_dimensions(request.dimensions)
    if request.model not in (MODEL_ID, "embeddinggemma-2"):
        raise HTTPException(status_code=404, detail="model not found")
    texts = [request.input] if isinstance(request.input, str) else request.input
    check_texts(texts)
    encoder = get_model()
    tokenized = encoder.tokenize(texts)
    token_count = int(tokenized["attention_mask"].sum().item())
    vectors = encoder.encode(
        texts,
        truncate_dim=request.dimensions,
        normalize_embeddings=True,
    )
    return {
        "object": "list",
        "data": [
            {"object": "embedding", "index": index, "embedding": vector.tolist()}
            for index, vector in enumerate(vectors)
        ],
        "model": MODEL_ID,
        "usage": {"prompt_tokens": token_count, "total_tokens": token_count},
    }


@app.post("/api/compare")
def compare(request: CompareRequest):
    check_dimensions(request.dimensions)
    encoder = get_model()
    query_vector = encoder.encode(
        request.query,
        prompt_name="SearchQuery",
        truncate_dim=request.dimensions,
        normalize_embeddings=True,
    )
    document_vector = encoder.encode(
        request.document,
        prompt_name="Document",
        truncate_dim=request.dimensions,
        normalize_embeddings=True,
    )
    score = float(encoder.similarity(query_vector, document_vector).item())
    return {"score": score, "percent": round(score * 100, 2)}


@app.post("/api/search")
def search(request: SearchRequest):
    check_dimensions(request.dimensions)
    target = Path(request.path).expanduser().resolve()
    search_root = SEARCH_ROOT
    if not target.exists():
        raise HTTPException(status_code=404, detail="path not found")
    if not target.is_relative_to(search_root):
        raise HTTPException(status_code=403, detail="search is limited to the directory opened in Termux")
    supported = {".py", ".sh", ".js", ".ts", ".md", ".txt", ".json", ".html", ".css", ".c", ".h", ".cpp", ".rs", ".go"}
    ignored = {".git", ".cache", "node_modules", "__pycache__", ".local", ".venv", ".venv-ai"}
    if target.is_file():
        files = [target]
    else:
        files = []
        for base, dirs, names in os.walk(target):
            dirs[:] = [directory for directory in dirs if directory not in ignored]
            for name in names:
                if Path(name).suffix.lower() in supported:
                    files.append(Path(base) / name)
                    if len(files) >= MAX_SEARCH_FILES:
                        break
            if len(files) >= MAX_SEARCH_FILES:
                break
    chunks = []
    for path in files:
        resolved = path.resolve()
        if not resolved.is_relative_to(search_root) or not resolved.is_file():
            continue
        try:
            if resolved.stat().st_size > 250_000:
                continue
            lines = resolved.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for offset in range(0, len(lines), 30):
            text = "\n".join(lines[offset:offset + 30]).strip()
            if len(text) > 40:
                chunks.append({"file": str(path.relative_to(target if target.is_dir() else target.parent)), "line": offset + 1, "text": text[:600]})
                if len(chunks) >= MAX_SEARCH_CHUNKS:
                    break
        if len(chunks) >= MAX_SEARCH_CHUNKS:
            break
    if not chunks:
        return {"results": []}
    encoder = get_model()
    query_vector = encoder.encode(
        request.query,
        prompt_name="SearchQuery",
        truncate_dim=request.dimensions,
        normalize_embeddings=True,
    )
    document_vectors = encoder.encode(
        [chunk["text"] for chunk in chunks],
        prompt_name="Document",
        truncate_dim=request.dimensions,
        normalize_embeddings=True,
        batch_size=8,
    )
    scores = encoder.similarity(query_vector, document_vectors)[0]
    ranked = sorted(enumerate(scores), key=lambda item: item[1].item(), reverse=True)[:request.top]
    return {
        "results": [
            {
                "file": chunks[index]["file"],
                "line": chunks[index]["line"],
                "score": float(score.item()),
                "preview": chunks[index]["text"][:200].replace("\n", " "),
            }
            for index, score in ranked
        ]
    }


HTML = """<!doctype html>
<html lang="pt-BR">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark">
<title>EmbeddingGemma 2 local</title>
<style>
:root{font:16px system-ui,sans-serif;color:#e6edf3;background:#0d1117}body{max-width:850px;margin:32px auto;padding:0 18px}
h1{font-size:1.8rem}p,.hint{color:#9da7b3}.card{background:#161b22;border:1px solid #30363d;border-radius:12px;padding:18px;margin:16px 0}
label{display:block;margin:12px 0 6px}textarea,input,select,button{font:inherit;color:inherit;background:#0d1117;border:1px solid #484f58;border-radius:7px;padding:10px}
textarea{box-sizing:border-box;width:100%;min-height:95px}input{box-sizing:border-box;width:100%}button{background:#238636;border:0;cursor:pointer;margin-top:12px}
button:disabled{opacity:.6}output{display:block;white-space:pre-wrap;overflow-wrap:anywhere;margin-top:12px;color:#a5d6ff}.row{display:flex;gap:12px;align-items:center}
@media(max-width:600px){body{margin-top:18px}.row{display:block}}
</style>
<h1>EmbeddingGemma 2 <small>local</small></h1>
<p>Busca semantica, similaridade e vetores de texto. Seus dados ficam neste aparelho.</p>
<section class="card"><h2>Comparar textos</h2>
<label for="query">Consulta</label><textarea id="query" placeholder="Ex.: como iniciar um servidor local"></textarea>
<label for="document">Texto para comparar</label><textarea id="document" placeholder="Cole texto ou codigo"></textarea>
<div class="row"><label>Dimensao <select id="compare-dim"><option>256</option><option>128</option><option>512</option><option>768</option></select></label><button onclick="compareText()">Comparar</button></div><output id="compare-out"></output></section>
<section class="card"><h2>Buscar em arquivos</h2>
<label for="search-query">O que voce procura?</label><input id="search-query" placeholder="Ex.: autenticacao do usuario">
<label for="search-path">Pasta ou arquivo no Linux</label><input id="search-path" value="__SEARCH_PATH__">
<div class="row"><label>Resultados <select id="search-top"><option>5</option><option>10</option><option>20</option></select></label><button onclick="searchFiles()">Buscar</button></div><output id="search-out"></output></section>
<section class="card"><h2>Gerar embedding</h2><label for="embed-text">Texto</label><textarea id="embed-text"></textarea>
<div class="row"><label>Dimensao <select id="embed-dim"><option>256</option><option>128</option><option>512</option><option>768</option></select></label><button onclick="embedText()">Gerar vetor</button></div><output id="embed-out"></output></section>
<p class="hint">Modelo: google/embeddinggemma-2 · CPU · endpoint OpenAI compativel em /v1/embeddings</p>
<script>
async function post(path,data){const r=await fetch(path,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(data)});const b=await r.json();if(!r.ok)throw Error(b.detail||r.statusText);return b}
async function run(id,fn){const o=document.getElementById(id);o.textContent="Processando...";try{o.textContent=await fn()}catch(e){o.textContent="Erro: "+e.message}}
function dim(id){return Number(document.getElementById(id).value)}
function compareText(){return run("compare-out",async()=>{const r=await post("/api/compare",{query:document.getElementById("query").value,document:document.getElementById("document").value,dimensions:dim("compare-dim")});return `Similaridade: ${r.percent}% (score ${r.score.toFixed(4)})`})}
function searchFiles(){return run("search-out",async()=>{const r=await post("/api/search",{query:document.getElementById("search-query").value,path:document.getElementById("search-path").value,top:Number(document.getElementById("search-top").value),dimensions:256});return r.results.length?r.results.map((x,i)=>`${i+1}. [${x.score.toFixed(4)}] ${x.file}:${x.line}\\n${x.preview}`).join("\\n\\n"):"Nenhum trecho encontrado."})}
function embedText(){return run("embed-out",async()=>{const r=await post("/v1/embeddings",{input:document.getElementById("embed-text").value,dimensions:dim("embed-dim")});const v=r.data[0].embedding;return `Dimensao: ${v.length}\\nAmostra: ${JSON.stringify(v.slice(0,8))}\\nVetor completo: ${JSON.stringify(v)}`})}
</script>
</html>"""


def main():
    parser = argparse.ArgumentParser(description="EmbeddingGemma 2 local web interface")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8085)
    args = parser.parse_args()
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        parser.error("This server only accepts loopback hosts.")
    if not 1 <= args.port <= 65535:
        parser.error("port must be between 1 and 65535.")
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
