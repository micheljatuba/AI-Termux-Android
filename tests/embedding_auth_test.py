"""Testes do token do servidor web do EmbeddingGemma (sem FastAPI nem modelo)."""

import asyncio
import os
import stat
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from embeddinggemma_auth import TokenGate, ensure_token, load_token  # noqa: E402

TOKEN = "0123456789abcdef0123456789abcdef"


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    sys.exit(1)


def request(path, headers=(), kind="http"):
    seen = {}

    async def app(scope, receive, send):
        seen["path"] = scope.get("path")
        seen["raw_path"] = scope.get("raw_path")
        if scope["type"] == "http":
            await send({"type": "http.response.start", "status": 200, "headers": []})
            await send({"type": "http.response.body", "body": b"ok"})

    sent = []

    async def send(message):
        sent.append(message)

    async def receive():
        return {"type": "http.request", "body": b""}

    scope = {"type": kind, "path": path, "headers": list(headers)}
    asyncio.run(TokenGate(app, TOKEN)(scope, receive, send))
    return sent, seen


def status(path, headers=()):
    sent, seen = request(path, headers)
    return sent[0]["status"], seen


for path in ("/", "/api/search", "/v1/embeddings", "/health", f"/{TOKEN}x/api/search", f"/{TOKEN.upper()}/",
             "/" + TOKEN[:-1] + "/", "//" + TOKEN + "/", "/ção/x", ""):
    code, seen = status(path)
    if code != 404 or seen:
        fail(f"sem token valido o app nao pode ser chamado: {path!r} -> {code}")
sent, _ = request("/api/search")
if TOKEN.encode() in b"".join(m.get("body", b"") for m in sent):
    fail("a resposta 404 nao pode conter o token")

code, seen = status(f"/{TOKEN}/")
if code != 200 or seen["path"] != "/" or seen["raw_path"] != b"/":
    fail(f"o token no caminho deve levar a pagina inicial: {code} {seen}")
code, seen = status(f"/{TOKEN}/api/search")
if code != 200 or seen["path"] != "/api/search":
    fail(f"o token no caminho deve levar a API: {code} {seen}")
sent, seen = request(f"/{TOKEN}")
if sent[0]["status"] != 307 or (b"location", f"/{TOKEN}/".encode()) not in sent[0]["headers"] or seen:
    fail("o caminho sem barra final deve redirecionar para a pagina com token")

code, seen = status("/v1/embeddings", [(b"authorization", f"Bearer {TOKEN}".encode())])
if code != 200 or seen["path"] != "/v1/embeddings":
    fail("Authorization: Bearer <token> deve liberar clientes compativeis com OpenAI")
code, seen = status("/v1/embeddings", [(b"Authorization", f"bearer  {TOKEN} ".encode())])
if code != 200:
    fail("o esquema Bearer nao diferencia maiusculas")
for value in (f"Bearer {TOKEN}x".encode(), f"Basic {TOKEN}".encode(), b"Bearer", "Bearer ç".encode("utf-8"), TOKEN.encode()):
    code, seen = status("/v1/embeddings", [(b"authorization", value)])
    if code != 404 or seen:
        fail(f"cabecalho invalido foi aceito: {value!r}")
print("PASS EmbeddingGemma token gate: path and Bearer token required, 404 otherwise")

sent, seen = request(f"/{TOKEN}/ws", kind="websocket")
if seen or sent != [{"type": "websocket.close", "code": 1008}]:
    fail("websocket deve ser recusado")
lifespan = []


async def lifespan_app(scope, receive, send):
    lifespan.append(scope["type"])


asyncio.run(TokenGate(lifespan_app, TOKEN)({"type": "lifespan"}, None, None))
if lifespan != ["lifespan"]:
    fail("o ciclo de vida do servidor deve passar pelo portao")
try:
    TokenGate(lifespan_app, "curto")
    fail("token malformado foi aceito")
except ValueError:
    pass

with tempfile.TemporaryDirectory() as root:
    web = Path(root) / "state" / "web"
    token_file = web / "token"
    for content in (None, "abc\n", TOKEN.upper() + "\n"):
        if content is not None:
            web.mkdir(parents=True, exist_ok=True)
            token_file.write_text(content)
        try:
            load_token(token_file)
            fail(f"token ausente ou malformado foi aceito: {content!r}")
        except SystemExit:
            pass
    token_file.unlink()
    created = ensure_token(token_file)
    if len(created) != 32 or created != load_token(token_file):
        fail("ensure_token deve criar um token de 32 hexadecimais")
    if stat.S_IMODE(os.stat(token_file).st_mode) != 0o600 or stat.S_IMODE(os.stat(web).st_mode) != 0o700:
        fail("o token deve ficar privado (arquivo 600, pasta 700)")
    if ensure_token(token_file) != created:
        fail("ensure_token deve reaproveitar o token existente")
print("PASS EmbeddingGemma token file: fail-closed loading and private creation")
