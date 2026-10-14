#!/usr/bin/env python3
"""
EmbeddingGemma 2 - CLI & Local Server
Integrado ao ecossistema Termux AI / AI-Termux-Android.
"""

import os
import sys
import argparse
import time
import json
import hashlib
from pathlib import Path

# Suprime avisos desnecessários
os.environ["TOKENIZERS_PARALLELISM"] = "true"
os.environ["HF_HUB_DISABLE_SYMLINKS_WARNING"] = "1"

MODEL_ID = "google/embeddinggemma-2"
VALID_DIMS = (128, 256, 512, 768)
MAX_SEARCH_FILES = 200
MAX_SEARCH_CHUNKS = 100
MAX_FILE_SIZE = 250_000
MAX_CACHE_ENTRIES = 2000
SUPPORTED_EXTS = {
    ".py", ".sh", ".js", ".ts", ".md", ".txt", ".json",
    ".html", ".css", ".c", ".h", ".cpp", ".rs", ".go",
}
IGNORED_DIRS = {
    ".git", ".cache", "node_modules", "__pycache__",
    ".local", ".venv", ".venv-ai",
}
_model = None


def get_cache_path() -> Path:
    cache_dir = Path(os.environ.get("TERMUX_AI_CACHE_DIR", str(Path.home() / ".cache" / "termux-ai"))).expanduser()
    return cache_dir / "embeddings-cache.json"


def load_embedding_cache() -> dict:
    cache_path = get_cache_path()
    try:
        if not cache_path.is_file():
            return {}
        data = json.loads(cache_path.read_text(encoding="utf-8"))
        if isinstance(data, dict) and data.get("model") == MODEL_ID and isinstance(data.get("entries"), dict):
            return data["entries"]
    except Exception:
        pass
    return {}


def save_embedding_cache(entries: dict) -> None:
    cache_path = get_cache_path()
    try:
        cache_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if len(entries) > MAX_CACHE_ENTRIES:
            keys = list(entries.keys())[-MAX_CACHE_ENTRIES:]
            entries = {k: entries[k] for k in keys}
        tmp_path = cache_path.with_suffix(".tmp")
        payload = json.dumps({"model": MODEL_ID, "entries": entries})
        tmp_path.write_text(payload, encoding="utf-8")
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, cache_path)
    except Exception:
        pass


def chunk_cache_key(text: str, dimensions: int) -> str:
    digest = hashlib.sha256(f"{MODEL_ID}:{dimensions}:{text}".encode("utf-8")).hexdigest()
    return digest


def collect_search_chunks(target: Path, root_bound: Path | None = None) -> list[dict]:
    resolved_target = target.expanduser().resolve()
    bound = (root_bound.expanduser().resolve() if root_bound is not None
             else (resolved_target if resolved_target.is_dir() else resolved_target.parent))
    if not resolved_target.exists():
        raise FileNotFoundError(f"path not found: {target}")
    if not resolved_target.is_relative_to(bound):
        raise PermissionError("search is limited to the allowed directory")

    if resolved_target.is_file():
        files = [resolved_target]
        base_dir = resolved_target.parent
    else:
        base_dir = resolved_target
        files = []
        for base, dirs, names in os.walk(resolved_target):
            dirs[:] = [d for d in dirs if d not in IGNORED_DIRS]
            for name in sorted(names):
                candidate = Path(base) / name
                if candidate.suffix.lower() in SUPPORTED_EXTS:
                    files.append(candidate)
                    if len(files) >= MAX_SEARCH_FILES:
                        break
            if len(files) >= MAX_SEARCH_FILES:
                break

    chunks: list[dict] = []
    for path in files:
        try:
            resolved = path.resolve()
            if not resolved.is_relative_to(bound) or not resolved.is_file():
                continue
            if resolved.stat().st_size > MAX_FILE_SIZE:
                continue
            lines = resolved.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        rel_file = str(path.relative_to(base_dir) if path != base_dir else path.name)
        for offset in range(0, len(lines), 30):
            text = "\n".join(lines[offset:offset + 30]).strip()
            if len(text) > 40:
                chunks.append({
                    "file": rel_file,
                    "line": offset + 1,
                    "text": text[:600],
                })
                if len(chunks) >= MAX_SEARCH_CHUNKS:
                    break
        if len(chunks) >= MAX_SEARCH_CHUNKS:
            break
    return chunks


def rank_search_chunks(query: str, chunks: list[dict], dimensions: int = 256, top: int = 5, encoder=None) -> tuple[list[dict], int, int]:
    if not chunks:
        return [], 0, 0
    if encoder is None:
        encoder = get_model()

    cache_entries = load_embedding_cache()
    vectors: list[list[float] | None] = [None] * len(chunks)
    missing_indices: list[int] = []
    missing_texts: list[str] = []
    missing_keys: list[str] = []

    for idx, chunk in enumerate(chunks):
        key = chunk_cache_key(chunk["text"], dimensions)
        cached = cache_entries.get(key)
        if isinstance(cached, list) and len(cached) == dimensions:
            vectors[idx] = cached
        else:
            missing_indices.append(idx)
            missing_texts.append(chunk["text"])
            missing_keys.append(key)

    cached_count = len(chunks) - len(missing_indices)
    if missing_texts:
        encoded = encoder.encode(
            missing_texts,
            prompt_name="Document",
            truncate_dim=dimensions,
            normalize_embeddings=True,
            batch_size=16,
        )
        for pos, idx in enumerate(missing_indices):
            vec_item = encoded[pos]
            vec_list = vec_item.tolist() if hasattr(vec_item, "tolist") else [float(x) for x in vec_item]
            vectors[idx] = vec_list
            cache_entries[missing_keys[pos]] = vec_list
        save_embedding_cache(cache_entries)

    q_emb = encoder.encode(
        query,
        prompt_name="SearchQuery",
        truncate_dim=dimensions,
        normalize_embeddings=True,
    )
    q_list = q_emb.tolist() if hasattr(q_emb, "tolist") else [float(x) for x in q_emb]
    if q_list and isinstance(q_list[0], list):
        q_list = q_list[0]

    scored = []
    for idx, doc_vec in enumerate(vectors):
        assert doc_vec is not None
        score = float(sum(a * b for a, b in zip(q_list, doc_vec)))
        scored.append((idx, score))

    scored.sort(key=lambda item: item[1], reverse=True)
    results = [
        {
            "file": chunks[idx]["file"],
            "line": chunks[idx]["line"],
            "score": score,
            "text": chunks[idx]["text"],
            "preview": chunks[idx]["text"][:200].replace("\n", " "),
        }
        for idx, score in scored[:top]
    ]
    return results, cached_count, len(missing_indices)

def get_model(truncate_dim=None):
    global _model
    if _model is None:
        print("Carregando EmbeddingGemma 2 (270M parâmetros)...", file=sys.stderr)
        from sentence_transformers import SentenceTransformer
        import transformers
        transformers.logging.set_verbosity_error()
        try:
            _model = SentenceTransformer(
                MODEL_ID,
                config_kwargs={"vision_config": None, "audio_config": None},
                local_files_only=True,
            )
        except Exception:
            _model = SentenceTransformer(
                MODEL_ID,
                config_kwargs={"vision_config": None, "audio_config": None},
            )
    return _model

def cmd_info(args):
    print("\n=== EmbeddingGemma 2 ===")
    print(f"Modelo HuggingFace:  {MODEL_ID}")
    print("Arquitetura base:    Gemma 4 (Apache 2.0)")
    print("Modo ativo:          Texto & Código (270M parâmetros)")
    print("Contexto máximo:     8.192 tokens")
    print("Dimensões (MRL):     768d (padrão), 512d, 256d (3x menor), 128d (6x menor)")
    print("Armazenamento local: ~/.cache/huggingface/hub/models--google--embeddinggemma-2")
    print("Execução:            Local (Snapdragon ARM64 CPU via PyTorch)\n")

def cmd_test(args):
    model = get_model()
    t0 = time.time()
    q = "Como criar um script em Bash no Termux?"
    d1 = "Tutorial de automação e scripts shell no Linux Termux Android."
    d2 = "Como fazer um pudim de leite condensado tradicional."

    emb_q = model.encode(q, prompt_name="SearchQuery", truncate_dim=256, normalize_embeddings=True)
    emb_d1 = model.encode(d1, prompt_name="Document", truncate_dim=256, normalize_embeddings=True)
    emb_d2 = model.encode(d2, prompt_name="Document", truncate_dim=256, normalize_embeddings=True)
    dt = time.time() - t0

    sim1 = model.similarity(emb_q, emb_d1).item()
    sim2 = model.similarity(emb_q, emb_d2).item()

    print("\n=== Teste de Inferência Local ===")
    print(f"Consulta: '{q}'")
    print(f"Doc 1 (Linux/Termux): Similaridade = {sim1:.4f} (esperado alto)")
    print(f"Doc 2 (Receita):      Similaridade = {sim2:.4f} (esperado baixo)")
    print(f"Dimensão (MRL):       256d")
    print(f"Tempo total de inferência: {dt:.2f}s\n")

def cmd_embed(args):
    text = args.text
    truncate_dim = args.dim
    model = get_model()

    prompt = args.prompt or "Document"
    emb = model.encode(
        text,
        prompt_name=prompt if prompt != "none" else None,
        truncate_dim=truncate_dim,
        normalize_embeddings=True,
    )

    vec = emb.tolist() if hasattr(emb, "tolist") else list(emb)
    print(f"\nTexto: '{text}'")
    print(f"Dimensão: {len(vec)}d (Normalizado: Sim)")
    print(f"Amostra dos primeiros 8 valores: {[round(x, 4) for x in vec[:8]]}")
    if args.json:
        print(json.dumps({"dimension": len(vec), "embedding": vec}))

def cmd_compare(args):
    text1 = args.text1
    text2 = args.text2
    model = get_model()

    emb1 = model.encode(text1, prompt_name="SearchQuery", truncate_dim=args.dim or 256, normalize_embeddings=True)
    emb2 = model.encode(text2, prompt_name="Document", truncate_dim=args.dim or 256, normalize_embeddings=True)
    sim = model.similarity(emb1, emb2).item()

    print(f"\nTexto 1 (Query): '{text1}'")
    print(f"Texto 2 (Doc):   '{text2}'")
    print(f"Similaridade semântica: {sim * 100:.2f}% (score: {sim:.4f})\n")

def cmd_search(args):
    query = args.query
    target_path = Path(args.path or ".").expanduser().resolve()
    max_results = args.top or 5
    truncate_dim = args.dim or 256

    if not target_path.exists():
        print(f"Caminho não encontrado: {target_path}", file=sys.stderr)
        return 1

    try:
        chunks = collect_search_chunks(target_path)
    except (FileNotFoundError, PermissionError) as exc:
        print(f"Erro na busca: {exc}", file=sys.stderr)
        return 1

    if not chunks:
        print("Nenhum arquivo legível encontrado.", file=sys.stderr)
        return

    base_name = target_path.name if target_path.is_dir() else target_path.parent.name
    print(f"Indexados {len(chunks)} blocos em '{base_name}'. Processando busca...")

    t0 = time.time()
    results, cached_count, encoded_count = rank_search_chunks(
        query=query,
        chunks=chunks,
        dimensions=truncate_dim,
        top=max_results,
    )
    dt = time.time() - t0

    cache_info = f"cache: {cached_count}/{len(chunks)}"
    print(f"\n=== Resultados para: '{query}' ({dt:.2f}s, {cache_info}) ===")
    for rank, item in enumerate(results, 1):
        preview = item["text"][:140].replace("\n", " ")
        print(f"\n{rank}. [{item['score']:.4f}] {item['file']}:{item['line']}")
        print(f"   Prévia: {preview}...")
    print()

def cmd_serve(args):
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import uvicorn
    import embeddinggemma_web

    if args.dim in VALID_DIMS:
        embeddinggemma_web.DEFAULT_DIM = args.dim
    embeddinggemma_web.get_model()

    print(f"\nIniciando servidor EmbeddingGemma 2 na porta {args.port}...")
    print(f"Endpoint compatível com OpenAI: http://{args.host}:{args.port}/v1/embeddings")
    print("Pressione Ctrl+C para encerrar.\n")
    uvicorn.run(embeddinggemma_web.app, host=args.host, port=args.port, log_level="info")

def interactive_menu():
    while True:
        print("\n=== EmbeddingGemma 2 - Menu Local ===")
        print("1. Buscar semântica em arquivos do projeto")
        print("2. Gerar vetor de embedding para texto")
        print("3. Comparar similaridade entre dois textos")
        print("4. Iniciar servidor de embeddings (/v1/embeddings)")
        print("5. Teste rápido de inferência")
        print("6. Detalhes do modelo")
        print("0. Voltar")

        try:
            choice = input("\nEscolha: ").strip()
        except (EOFError, KeyboardInterrupt):
            break

        if choice == "0":
            break
        elif choice == "1":
            q = input("Digite o que procura: ").strip()
            if q:
                p = input("Pasta ou arquivo a pesquisar (Enter para atual): ").strip() or "."
                cmd_search(argparse.Namespace(query=q, path=p, top=5, dim=256))
        elif choice == "2":
            txt = input("Texto para embedding: ").strip()
            if txt:
                dim_str = input("Dimensão [768/512/256/128, padrão 256]: ").strip() or "256"
                dim = int(dim_str) if dim_str in ("128", "256", "512", "768") else 256
                cmd_embed(argparse.Namespace(text=txt, dim=dim, prompt="Document", json=False))
        elif choice == "3":
            t1 = input("Texto 1 (Consulta/Query): ").strip()
            t2 = input("Texto 2 (Documento/Código): ").strip()
            if t1 and t2:
                cmd_compare(argparse.Namespace(text1=t1, text2=t2, dim=256))
        elif choice == "4":
            port_str = input("Porta do servidor [padrão 8085]: ").strip()
            port = int(port_str) if port_str.isdigit() else 8085
            cmd_serve(argparse.Namespace(host="127.0.0.1", port=port, dim=None))
        elif choice == "5":
            cmd_test(None)
        elif choice == "6":
            cmd_info(None)

def main():
    parser = argparse.ArgumentParser(description="EmbeddingGemma 2 CLI Local")
    parser.add_argument("--version", "-v", "-V", action="version", version="2.0.0")
    subparsers = parser.add_subparsers(dest="command")

    # info
    subparsers.add_parser("info", help="Exibe informações do modelo")

    # test
    subparsers.add_parser("test", help="Testa inferência e similaridade")

    # embed
    p_embed = subparsers.add_parser("embed", help="Gera embedding para um texto")
    p_embed.add_argument("text", help="Texto para codificar")
    p_embed.add_argument("--dim", type=int, choices=[128, 256, 512, 768], default=None, help="Dimensão MRL")
    p_embed.add_argument("--prompt", choices=["SearchQuery", "Document", "none"], default="Document", help="Task prompt")
    p_embed.add_argument("--json", action="store_true", help="Saída em JSON")

    # compare
    p_comp = subparsers.add_parser("compare", help="Compara similaridade de dois textos")
    p_comp.add_argument("text1", help="Primeiro texto (Query)")
    p_comp.add_argument("text2", help="Segundo texto (Documento)")
    p_comp.add_argument("--dim", type=int, choices=[128, 256, 512, 768], default=None, help="Dimensão MRL")

    # search
    p_search = subparsers.add_parser("search", help="Busca semântica no código ou diretório")
    p_search.add_argument("query", help="Termo ou pergunta")
    p_search.add_argument("path", nargs="?", default=".", help="Diretório alvo (padrão: atual)")
    p_search.add_argument("--top", type=int, default=5, help="Quantidade máxima de resultados")
    p_search.add_argument("--dim", type=int, choices=[128, 256, 512, 768], default=256, help="Dimensão MRL (padrão 256d)")

    # serve
    p_serve = subparsers.add_parser("serve", help="Inicia servidor HTTP OpenAI-compatível")
    p_serve.add_argument("--host", choices=["127.0.0.1", "localhost", "::1"], default="127.0.0.1", help="Host (somente loopback)")
    p_serve.add_argument("--port", type=int, default=8085, help="Porta HTTP (padrão: 8085)")
    p_serve.add_argument("--dim", type=int, choices=[128, 256, 512, 768], default=None, help="Dimensão MRL")

    if len(sys.argv) == 1:
        interactive_menu()
        return

    args = parser.parse_args()
    if args.command == "info":
        cmd_info(args)
    elif args.command == "test":
        cmd_test(args)
    elif args.command == "embed":
        cmd_embed(args)
    elif args.command == "compare":
        cmd_compare(args)
    elif args.command == "search":
        cmd_search(args)
    elif args.command == "serve":
        cmd_serve(args)
    else:
        interactive_menu()

if __name__ == "__main__":
    main()
