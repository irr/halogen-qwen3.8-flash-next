# halogen-qwen3.8-flash-next

One command to run [halogen-flash-server](https://github.com/peonist-ai/halogen-flash-server)
with the Qwen3.8-Flash-Next checkpoint on an AMD Strix Halo (gfx1151) machine —
a GMKtec EVO-X2 in the original setup.

`./run.sh` downloads the weights (if missing), checks that the host is ready,
and starts the server in Docker with vision enabled and an OpenAI-compatible
API on **http://localhost:8000**.

## Requirements

**Hardware**

- AMD Strix Halo APU (gfx1151) with 128 GB unified memory, e.g. a GMKtec EVO-X2
- Roughly 300 GB of free disk for the weights (the full download is ~286 GiB;
  see [The weights](#the-weights))
- The loaded server holds most of a 128 GB host — plan on a machine of its own
  (see [Memory](#memory))

**Software**

- Docker Engine, with `/dev/kfd` and `/dev/dri` accessible
- [uv](https://docs.astral.sh/uv/) — used only to run the Hugging Face CLI for
  the download step

## Quick start

```bash
./run.sh
```

The first run downloads the weights into `./models/`; later runs verify them
and start immediately. Once the server is up:

```bash
curl -s http://localhost:8000/v1/models
```

## What `run.sh` does

1. **Downloads / verifies the weights** with
   `uv run --with "huggingface_hub[cli]" hf download peonist-ai/halogen-qwen3.8-flash-next --local-dir models`.
   Interrupted downloads resume; nothing is re-fetched once complete.
2. **Resolves GPU group GIDs numerically.** Docker Engine 29 resolves
   `--group-add` *names* against the image's `/etc/group`, which lacks host
   groups like `render`, and fails. The script instead reads the GIDs straight
   off `/dev/kfd` and `/dev/dri/*` and passes them as numbers.
3. **Checks host memory fragmentation.** The engine reserves large contiguous
   chunks; if the kernel buddy allocator has too few free 2 MiB (order-9)
   blocks, the script prints a warning with the
   `drop_caches` / `compact_memory` remedy, since the engine can otherwise die
   at "reserving the KV pool" after the slow weight-pinning step.
4. **Starts the container** (`docker run --rm`), publishing host port 8000 to
   the container's API port 8731, passing the GPU devices and their GIDs,
   `--ipc=host --ulimit memlock=-1:-1`, `HALOGEN_VISION_TOWER=1`,
   `HALOGEN_MAX_THINKING_TOKENS=8192`, and `./models` mounted read-only at
   `/models`.

The container is `--rm`, so it disappears on exit; the weights stay in
`./models` and the next start skips the download.

## Configuration

Everything lives in the variables at the top of `run.sh`:

| Variable    | Default                                              | Purpose                                        |
| ----------- | ---------------------------------------------------- | ---------------------------------------------- |
| `IMAGE`     | `ghcr.io/peonist-ai/halogen-flash-server:0.18.1`     | Server image; bump the tag to upgrade          |
| `PORT`      | `8000`                                               | Host port the API is published on              |
| `API_PORT`  | `8731`                                               | Container-side API port                        |
| `MAX_THINKING_TOKENS` | `8192`                                      | Thinking-token budget (`HALOGEN_MAX_THINKING_TOKENS`) |
| `CONTAINER_NAME` | `halogen-qwen3.8-flash-next`                 | Name for `docker run --name`                   |
| `MODELS_DIR` | `./models`                                           | Where the weights live (gitignored)            |

Extra engine settings are extra `-e` flags on the `docker run` line. For
example, to opt in to the smaller `ht43` checkpoint (0.16+ images):

```bash
-e HALOGEN_CHECKPOINT=/models/qwen38-flash-next-ht43.hgn
```

## The API

An OpenAI-compatible endpoint comes up on the published port: 
`/v1/chat/completions`, `/v1/completions`, `/v1/models`, and `/v1/responses`.
The last is the Responses API, so the **OpenAI Codex CLI** works against this
server directly, tool calls included. Structured output
(`response_format: json_schema` / `json_object`) is enforced while the model
decodes.

Vision is enabled (`HALOGEN_VISION_TOWER=1`), so image inputs are accepted.

```bash
curl http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "<id from /v1/models>",
    "messages": [{"role": "user", "content": "Say hello."}]
  }'
```

Full documentation is in the
[server repository](https://github.com/peonist-ai/halogen-flash-server).

## The weights

The download step fetches the whole
[`peonist-ai/halogen-qwen3.8-flash-next`](https://huggingface.co/peonist-ai/halogen-qwen3.8-flash-next)
repo, ~286 GiB. Of that, the required pair for current servers is the **v2
checkpoint plus its n-gram lookup table (~110 GiB)**; the rest is the optional
vision and draft-head files, the smaller `ht43` checkpoint, and the legacy
0.14 (`w4b`) files, which still load.

The weights are in halogen's own `.hgn` format and **will not load in
transformers, vLLM, or llama.cpp** — they exist to be mounted into the
halogen-flash-server container, which is what this repo does.

The full model card (precision, speculative decoding, file-by-file detail)
lands in `models/README.md` after the first download.

## Memory

- The script's buddy-info check (step 3 above) catches the one host-side
  failure mode that looks like a crash but isn't fixed by restarting the
  container.
- Loaded at the defaults, the server holds most of a 128 GB host, and what is
  left is mostly not in the large contiguous pieces another big process
  needs. If you run application containers or another model beside it, they
  compete for the remainder, and when it runs out both they and the server
  can stall for minutes at full CPU with no output — not a crash, and it
  needs no restart. The server reports what it leaves behind on its last line
  of startup; the [server repository](https://github.com/peonist-ai/halogen-flash-server)
  has the settings that give memory back.

## Repository layout

```
run.sh    launcher: downloads weights, preps the host, starts the container
models/   weights, downloaded on first run (gitignored)
```

## Provenance

The weights are a quantized derivative of
[Qwen/Qwen3.8-Flash-Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next) and
are governed by the upstream model's license; verify the terms before
commercial use. The halogen-flash **engine** is separate, closed source, and
distributed under its own terms via the
[server repository](https://github.com/peonist-ai/halogen-flash-server).
"halogen" is a trademark of Peonist, LLC.
