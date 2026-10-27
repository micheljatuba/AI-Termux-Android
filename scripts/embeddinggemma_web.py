#!/usr/bin/env python3
import argparse
import html
import os
import sys
from pathlib import Path
from typing import Annotated

sys.path.insert(0, str(Path(__file__).resolve().parent))
from embeddinggemma_auth import DEFAULT_TOKEN_FILE, TokenGate, load_token
from embeddinggemma_cli import (
    MODEL_ID,
    VALID_DIMS,
    MAX_SEARCH_FILES,
    MAX_SEARCH_CHUNKS,
    collect_search_chunks,
    get_model as load_shared_model,
    rank_search_chunks,
)

import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field
from starlette.middleware.trustedhost import TrustedHostMiddleware

MAX_INPUTS = 16
MAX_TEXT_LENGTH = 8192
DEFAULT_DIM = 256
model = None
SEARCH_ROOT = Path(os.environ.get("TERMUX_AI_SEARCH_ROOT", str(Path.home()))).expanduser().resolve()


def get_model():
    global model
    if model is None:
        model = load_shared_model()
    return model


class EmbeddingRequest(BaseModel):
    input: str | list[str]
    model: str = MODEL_ID
    dimensions: int | None = Field(default=None, strict=True)


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
        "data": [
            {"id": "embeddinggemma-2", "object": "model", "owned_by": "google"},
            {"id": MODEL_ID, "object": "model", "owned_by": "google"},
        ],
    }


@app.post("/v1/embeddings")
def embeddings(request: EmbeddingRequest):
    dimensions = request.dimensions if request.dimensions is not None else DEFAULT_DIM
    check_dimensions(dimensions)
    if request.model not in (MODEL_ID, "embeddinggemma-2"):
        raise HTTPException(status_code=404, detail="model not found")
    texts = [request.input] if isinstance(request.input, str) else request.input
    check_texts(texts)
    encoder = get_model()
    tokenized = encoder.tokenize(texts)
    token_count = int(tokenized["attention_mask"].sum().item())
    vectors = encoder.encode(
        texts,
        truncate_dim=dimensions,
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
    chunks = collect_search_chunks(target, root_bound=search_root)
    if not chunks:
        return {"results": [], "cached": 0, "encoded": 0}
    results, cached_count, encoded_count = rank_search_chunks(
        query=request.query,
        chunks=chunks,
        dimensions=request.dimensions,
        top=request.top,
        encoder=get_model(),
    )
    return {
        "results": [
            {
                "file": item["file"],
                "line": item["line"],
                "score": item["score"],
                "preview": item["preview"],
            }
            for item in results
        ],
        "cached": cached_count,
        "encoded": encoded_count,
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
<p class="hint">Modelo: google/embeddinggemma-2 · CPU · endpoint OpenAI compativel em v1/embeddings, com o cabecalho Authorization: Bearer &lt;token&gt;</p>
<script>
async function post(path,data){const r=await fetch(path,{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(data)});const b=await r.json();if(!r.ok)throw Error(b.detail||r.statusText);return b}
async function run(id,fn){const o=document.getElementById(id);o.textContent="Processando...";try{o.textContent=await fn()}catch(e){o.textContent="Erro: "+e.message}}
function dim(id){return Number(document.getElementById(id).value)}
function compareText(){return run("compare-out",async()=>{const r=await post("api/compare",{query:document.getElementById("query").value,document:document.getElementById("document").value,dimensions:dim("compare-dim")});return `Similaridade: ${r.percent}% (score ${r.score.toFixed(4)})`})}
function searchFiles(){return run("search-out",async()=>{const r=await post("api/search",{query:document.getElementById("search-query").value,path:document.getElementById("search-path").value,top:Number(document.getElementById("search-top").value),dimensions:256});return r.results.length?r.results.map((x,i)=>`${i+1}. [${x.score.toFixed(4)}] ${x.file}:${x.line}\\n${x.preview}`).join("\\n\\n"):"Nenhum trecho encontrado."})}
function embedText(){return run("embed-out",async()=>{const r=await post("v1/embeddings",{input:document.getElementById("embed-text").value,dimensions:dim("embed-dim")});const v=r.data[0].embedding;return `Dimensao: ${v.length}\\nAmostra: ${JSON.stringify(v.slice(0,8))}\\nVetor completo: ${JSON.stringify(v)}`})}
</script>
</html>"""


def protected_app(token):
    """O app so responde com o token: outros apps do Android tambem alcancam 127.0.0.1."""
    return TokenGate(app, token)


def main():
    parser = argparse.ArgumentParser(description="EmbeddingGemma 2 local web interface")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8085)
    parser.add_argument("--token-file", default=str(DEFAULT_TOKEN_FILE))
    args = parser.parse_args()
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        parser.error("This server only accepts loopback hosts.")
    if not 1 <= args.port <= 65535:
        parser.error("port must be between 1 and 65535.")
    uvicorn.run(protected_app(load_token(args.token_file)), host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
