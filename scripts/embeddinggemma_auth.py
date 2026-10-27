"""Token de acesso do servidor web do EmbeddingGemma (sem dependencias externas).

No Android, qualquer app instalado alcanca 127.0.0.1: escutar so em loopback
protege contra outros aparelhos, nao contra outros apps. Por isso toda
requisicao precisa do mesmo token do painel (~/.local/share/termux-ai/web/token):

- no caminho:  http://127.0.0.1:8085/<token>/   (pagina e API relativas)
- ou no cabecalho  Authorization: Bearer <token>  (clientes compativeis com OpenAI)

Sem token valido a resposta e 404, sem revelar que o servico existe.
"""

import hmac
import re
from pathlib import Path

TOKEN_PATTERN = re.compile(r"^[0-9a-f]{32}$")
DEFAULT_TOKEN_FILE = Path.home() / ".local" / "share" / "termux-ai" / "web" / "token"


def load_token(path):
    """Le o token; falha fechado se o arquivo faltar ou estiver malformado."""
    try:
        token = Path(path).read_text(encoding="ascii").strip()
    except (OSError, UnicodeDecodeError) as error:
        raise SystemExit(f"Token do servidor web indisponivel em {path}: {error}") from None
    if not TOKEN_PATTERN.fullmatch(token):
        raise SystemExit(f"Token do servidor web invalido em {path}; execute: ia web stop e ia web start")
    return token


def ensure_token(path=DEFAULT_TOKEN_FILE):
    """Usa o token existente ou cria um novo (mesmo formato do painel), privado ao usuario."""
    path = Path(path)
    if path.exists():
        return load_token(path)
    import os
    import secrets

    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    token = secrets.token_hex(16)
    temporary = path.with_name(path.name + ".next")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="ascii") as handle:
        handle.write(token + "\n")
    os.replace(temporary, path)
    return token


class TokenGate:
    """Middleware ASGI: so repassa requisicoes HTTP com o token correto."""

    def __init__(self, app, token):
        if not TOKEN_PATTERN.fullmatch(token or ""):
            raise ValueError("token invalido")
        self.app = app
        self.token = token

    async def __call__(self, scope, receive, send):
        if scope["type"] == "lifespan":
            return await self.app(scope, receive, send)
        if scope["type"] != "http":
            if scope["type"] == "websocket":
                await send({"type": "websocket.close", "code": 1008})
            return None
        path = scope.get("path", "")
        segments = path.split("/", 2)
        if len(segments) >= 2 and segments[0] == "" and self._matches(segments[1]):
            if len(segments) == 2:
                return await self._respond(send, 307, b"", [(b"location", f"/{self.token}/".encode())])
            inner = dict(scope)
            inner["path"] = "/" + segments[2]
            inner["raw_path"] = inner["path"].encode("utf-8")
            return await self.app(inner, receive, send)
        if self._bearer_ok(scope.get("headers") or []):
            return await self.app(scope, receive, send)
        return await self._respond(send, 404, b"Not Found", [(b"content-type", b"text/plain; charset=utf-8")])

    def _matches(self, given):
        # bytes: compare_digest recusa str com caracteres nao ASCII (viraria erro 500)
        return hmac.compare_digest(given.encode("utf-8", "surrogateescape"), self.token.encode("ascii"))

    def _bearer_ok(self, headers):
        for name, value in headers:
            if name.lower() == b"authorization":
                scheme, _, given = value.decode("latin-1").partition(" ")
                return scheme.lower() == "bearer" and self._matches(given.strip())
        return False

    @staticmethod
    async def _respond(send, status, body, headers):
        await send({
            "type": "http.response.start",
            "status": status,
            "headers": [(b"cache-control", b"no-store"), (b"content-length", str(len(body)).encode()), *headers],
        })
        await send({"type": "http.response.body", "body": body})
