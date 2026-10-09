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
from pathlib import Path

# Suprime avisos desnecessários
os.environ["TOKENIZERS_PARALLELISM"] = "true"
os.environ["HF_HUB_DISABLE_SYMLINKS_WARNING"] = "1"

MODEL_ID = "google/embeddinggemma-2"
_model = None

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
    target_path = Path(args.path or ".").resolve()
    max_results = args.top or 5
    truncate_dim = args.dim or 256

    if not target_path.exists():
        print(f"Caminho não encontrado: {target_path}", file=sys.stderr)
        return 1

    supported_exts = {".py", ".sh", ".js", ".ts", ".md", ".txt", ".json", ".html", ".css", ".c", ".h", ".cpp", ".rs", ".go"}
    chunks = []

    if target_path.is_file():
        files_to_scan = [target_path]
        base_dir = target_path.parent
    else:
        base_dir = target_path
        files_to_scan = []
        for root, dirs, files in os.walk(target_path):
            dirs[:] = [d for d in dirs if d not in {".git", ".cache", "node_modules", "__pycache__", ".local", ".venv", ".venv-ai"}]
            for fname in files:
                fpath = Path(root) / fname
                if fpath.suffix.lower() in supported_exts:
                    files_to_scan.append(fpath)

    for fpath in files_to_scan:
        try:
            content = fpath.read_text(encoding="utf-8", errors="ignore")
            lines = content.splitlines()
            step = 30
            for i in range(0, len(lines), step):
                chunk_text = "\n".join(lines[i:i + step]).strip()
                if len(chunk_text) > 40:
                    chunks.append({
                        "file": str(fpath.relative_to(base_dir) if fpath != base_dir else fpath.name),
                        "start_line": i + 1,
                        "text": chunk_text
                    })
        except Exception:
            continue

    if not chunks:
        print("Nenhum arquivo legível encontrado.", file=sys.stderr)
        return

    print(f"Indexados {len(chunks)} blocos em '{base_dir.name}'. Processando busca...")
    model = get_model()

    t0 = time.time()
    q_emb = model.encode(query, prompt_name="SearchQuery", truncate_dim=truncate_dim, normalize_embeddings=True)
    doc_texts = [c["text"][:600] for c in chunks]
    doc_embs = model.encode(doc_texts, prompt_name="Document", truncate_dim=truncate_dim, normalize_embeddings=True, batch_size=32)

    sims = model.similarity(q_emb, doc_embs)[0]
    ranked = sorted(enumerate(sims), key=lambda x: x[1].item(), reverse=True)[:max_results]
    dt = time.time() - t0

    print(f"\n=== Resultados para: '{query}' ({dt:.2f}s) ===")
    for rank, (idx, score) in enumerate(ranked, 1):
        chunk = chunks[idx]
        preview = chunk["text"][:140].replace("\n", " ")
        print(f"\n{rank}. [{score.item():.4f}] {chunk['file']}:{chunk['start_line']}")
        print(f"   Prévia: {preview}...")
    print()

def cmd_serve(args):
    import uvicorn
    from fastapi import FastAPI
    from pydantic import BaseModel
    from typing import List, Union

    app = FastAPI(title="EmbeddingGemma 2 Local Server", version="1.0.0")
    model = get_model(truncate_dim=args.dim)

    class EmbeddingRequest(BaseModel):
        input: Union[str, List[str]]
        model: str = "google/embeddinggemma-2"
        dimensions: int = args.dim or 768

    @app.get("/health")
    def health():
        return {"status": "ok", "model": MODEL_ID}

    @app.get("/v1/models")
    def list_models():
        return {
            "object": "list",
            "data": [
                {"id": "embeddinggemma-2", "object": "model", "owned_by": "google"},
                {"id": "google/embeddinggemma-2", "object": "model", "owned_by": "google"}
            ]
        }

    @app.post("/v1/embeddings")
    def create_embeddings(req: EmbeddingRequest):
        inputs = [req.input] if isinstance(req.input, str) else req.input
        dim = req.dimensions if req.dimensions in (128, 256, 512, 768) else None

        embs = model.encode(inputs, truncate_dim=dim, normalize_embeddings=True)
        data = []
        for idx, emb in enumerate(embs):
            data.append({
                "object": "embedding",
                "index": idx,
                "embedding": emb.tolist() if hasattr(emb, "tolist") else list(emb)
            })
        return {
            "object": "list",
            "data": data,
            "model": req.model,
            "usage": {"prompt_tokens": len(inputs) * 10, "total_tokens": len(inputs) * 10}
        }

    print(f"\nIniciando servidor EmbeddingGemma 2 na porta {args.port}...")
    print(f"Endpoint compatível com OpenAI: http://{args.host}:{args.port}/v1/embeddings")
    print("Pressione Ctrl+C para encerrar.\n")
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")

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
