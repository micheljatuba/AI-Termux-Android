"""Teste do servidor web real do EmbeddingGemma (FastAPI), sem o modelo.

Roda quando fastapi e httpx estao instalados (o CI instala); caso contrario, avisa e sai.
"""

import os
import sys
from pathlib import Path

try:
    import uvicorn  # noqa: F401  (o servidor importa uvicorn)
    from fastapi.testclient import TestClient
except ImportError:
    if os.environ.get("TERMUX_AI_REQUIRE_WEB_TEST") == "1":
        print("FAIL: fastapi, httpx and uvicorn are required for the EmbeddingGemma web test", file=sys.stderr)
        sys.exit(1)
    print("SKIP EmbeddingGemma web routes: fastapi, httpx or uvicorn not installed")
    sys.exit(0)

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import embeddinggemma_web as web  # noqa: E402

TOKEN = "0123456789abcdef0123456789abcdef"
client = TestClient(web.protected_app(TOKEN), base_url="http://127.0.0.1")
bearer = {"Authorization": f"Bearer {TOKEN}"}


def expect(label, response, status, detail=None):
    if response.status_code != status or (detail is not None and detail not in response.text):
        print(f"FAIL: {label}: {response.status_code} {response.text[:200]}", file=sys.stderr)
        sys.exit(1)


for route in web.app.routes:
    if not route.path.startswith("/"):
        print(f"FAIL: rota sem barra inicial nao e encontrada: {route.path}", file=sys.stderr)
        sys.exit(1)

expect("pagina sem token", client.get("/"), 404)
expect("API sem token", client.post("/api/search", json={"query": "a", "path": "/"}), 404)
expect("embeddings sem token", client.post("/v1/embeddings", json={"input": "a"}), 404)
page = client.get(f"/{TOKEN}/")
expect("pagina com token", page, 200)
for call in ('post("api/compare"', 'post("api/search"', 'post("v1/embeddings"'):
    if call not in page.text:
        print(f"FAIL: a pagina deve chamar a API por caminho relativo ao token: {call}", file=sys.stderr)
        sys.exit(1)
expect("saude com token", client.get(f"/{TOKEN}/health"), 200, "ok")
expect("modelos via Bearer", client.get("/v1/models", headers=bearer), 200, "embeddinggemma")
expect("busca fora da pasta aberta", client.post(f"/{TOKEN}/api/search", json={"query": "a", "path": "/"}), 403)
expect("dimensao invalida", client.post(f"/{TOKEN}/api/compare", json={"query": "a", "document": "b", "dimensions": 7}), 422)
expect("modelo desconhecido", client.post("/v1/embeddings", json={"input": "a", "model": "x"}, headers=bearer), 404, "model not found")
csrf = client.post(f"/{TOKEN}/api/compare", content='{"query":"a","document":"b"}', headers={"content-type": "text/plain"})
expect("corpo text/plain (CSRF) recusado", csrf, 422)
rebinding = TestClient(web.protected_app(TOKEN), base_url="http://evil.example")
expect("Host externo (DNS rebinding) recusado", rebinding.get(f"/{TOKEN}/"), 400)
print("PASS EmbeddingGemma web routes behind the token with the real FastAPI app")
