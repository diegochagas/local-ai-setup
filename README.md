# Local AI Setup

![Bash](https://img.shields.io/badge/Bash-5%2B-green)
![License](https://img.shields.io/github/license/diegochagas/local-ai-setup)

Installs the local AI models my applications share, on one machine, with no
accounts, credits or limits:

- **[ComfyUI](https://github.com/comfyanonymous/ComfyUI)** with open-weight
  image models (Qwen-Image-Edit, FLUX.2 klein, SAM 2.1, BiRefNet, LaMa), as
  a `comfyui` systemd user service. Used by
  [GIMPhoto](https://github.com/diegochagas/gimphoto),
  [gimp-setup](https://github.com/diegochagas/gimp-setup)'s AI plug-ins,
  [comic-skills](https://github.com/diegochagas/comic-skills) and
  photo-restore.
- **[Ollama](https://ollama.com/)**, the local language-model server, as a
  system service. Used by the Goose agent
  ([linux-mint-setup](https://github.com/diegochagas/linux-mint-setup)
  installs and configures it), comic-skills' page descriptions,
  tvshow-skills' subtitle translation and Digivice.

Each application finds these through their services, so they need no
setting of their own. [linux-mint-setup](https://github.com/diegochagas/linux-mint-setup)
runs this setup as one of its steps; it also works on its own on Debian
and Ubuntu based systems.

## Installation

```bash
git clone https://github.com/diegochagas/local-ai-setup.git && cd local-ai-setup
cp config.sh.example config.sh   # set COMFYUI_DIR to install ComfyUI
./setup.sh
```

To preview the actions without changing anything:

```bash
./setup.sh --dry-run
```

The setup is idempotent: run it again at any time to add what is missing
or resume an interrupted model download. Each run writes a log to `logs/`.

### Requirements

`curl`, `git`, `python3` (with `python3-venv` for ComfyUI), `sha256sum`,
`sudo` and `systemctl`. ComfyUI needs an AMD64 machine with an NVIDIA GPU
and its proprietary driver (a 6 GB card is enough: what does not fit is
kept in RAM) and about 45 GB free; Ollama also runs on ARM64 and on the
CPU.

## Configuration

`config.sh` (copied from [`config.sh.example`](config.sh.example)), or the
same variables in the environment, as linux-mint-setup passes them:

| Variable | Default | What |
| --- | --- | --- |
| `COMFYUI_DIR` | empty: ComfyUI skipped | Where ComfyUI, its Python environment and its models go, e.g. a larger data disk |
| `COMFYUI_MODEL_SETS` | `qwen,klein,sam,birefnet,lama` | Model sets to download (empty: none) |
| `COMFYUI_PORT` | `8188` | Port of the `comfyui` service (127.0.0.1 only) |
| `OLLAMA_MODELS_DIR` | empty: Ollama's default | Where Ollama keeps its models |
| `COMFYUI_TORCH_INDEX_URL`, `OLLAMA_INSTALL_URL` | PyTorch CUDA 12.8, ollama.com | Installer sources |

## ComfyUI

**Skipped unless `COMFYUI_DIR` is set**, because the models are tens of GB.

- Installs ComfyUI in `COMFYUI_DIR` with its own Python virtual environment
  and PyTorch built for CUDA (`COMFYUI_TORCH_INDEX_URL`, CUDA 12.8 by
  default). AMD64 only; needs an NVIDIA GPU with the proprietary driver
  (on Linux Mint: Driver Manager) and `python3-venv`.
- Adds the [ComfyUI-GGUF](https://github.com/city96/ComfyUI-GGUF) custom
  node, which loads quantized models: a 20B editing model then runs on a
  6 GB card, keeping the rest of its weights in RAM; and the
  [SAM 2 nodes](https://github.com/kijai/ComfyUI-segment-anything-2)
  (pinned commit), behind GIMP's and GIMPhoto's AI selections; the
  [BiRefNet nodes](https://github.com/lldacing/ComfyUI_BiRefNet_ll)
  (pinned commit), behind GIMPhoto's Select Subject; the
  [inpaint nodes](https://github.com/Acly/comfyui-inpaint-nodes)
  (pinned commit), which run LaMa for GIMPhoto's Remove tool; and this
  setup's own `BBoxFromJSON` node
  ([`steps/comfyui/custom_nodes`](steps/comfyui/custom_nodes)), which lets
  apps give SAM 2 box prompts through ComfyUI's HTTP API.
- Downloads the model sets named in `COMFYUI_MODEL_SETS` (see
  [`steps/comfyui/models.tsv`](steps/comfyui/models.tsv)), each file
  verified against the SHA-256 Hugging Face publishes for it (LaMa, published
  on GitHub: the SHA-256 of the file as downloaded) and marked as
  verified so later runs do not re-hash it. An interrupted download resumes
  on the next run.

  | Set | Models | Size | Good at |
  | --- | --- | --- | --- |
  | `qwen` | Qwen-Image-Edit-2511 (4-bit GGUF) + Qwen2.5-VL text encoder, VAE and the 4-step Lightning LoRA | ~22 GB | Best quality: instruction edits that keep characters and text consistent. ~100 s per 1 MP image on a 6 GB GPU |
  | `klein` | FLUX.2 klein 4B (fp8) + Qwen3-4B text encoder and VAE | ~12 GB | Three times faster (~35 s), lower quality on detailed art. The only one that also generates images from text |
  | `sam` | SAM 2.1 large (fp16) | ~450 MB | Segment Anything: Object Selection, ~3 s per selection |
  | `birefnet` | BiRefNet general | ~450 MB | Finds the main subject of a picture: GIMPhoto's Select Subject, a few seconds |
  | `lama` | Big-LaMa | ~200 MB | Fills in what is removed (made for object removal): GIMPhoto's Remove tool, about a second |

  All five are installed by default (about 35 GB of models plus 8 GB for
  ComfyUI and PyTorch, and it wants 45 GB free); name only some to save
  disk. All are Apache 2.0 or MIT, so they can be used commercially.
- Writes a `comfyui` **systemd user service** on `127.0.0.1:COMFYUI_PORT`
  (8188 by default). It is deliberately **not enabled at boot**: it holds
  GPU memory while it runs. GIMP and GIMPhoto start it when they open and
  stop it when they close; they find ComfyUI through this service, so they
  need no setting of their own.

```bash
systemctl --user start comfyui     # then open http://127.0.0.1:8188
systemctl --user stop comfyui      # frees the GPU and the RAM
systemctl --user status comfyui    # is it running?
```

Scripts can drive it through its HTTP API and start the service themselves,
as comic-skills does (`INPAINT=qwen COMFYUI_SERVICE=comfyui`).

## Ollama

- Installs Ollama with its official script (AMD64 and ARM64). It uses an
  NVIDIA GPU when the proprietary driver is installed; a model larger than
  the GPU memory is split between GPU and CPU/RAM automatically.
- `OLLAMA_MODELS_DIR` moves the model storage to another disk, through its
  own systemd drop-in (`ollama.service.d/local-ai-setup.conf`); a service
  already using that directory (for instance through linux-mint-setup's
  older drop-in) is left as it is.
- Models are pulled by the applications that use them (`ollama pull`).

## Development

```bash
scripts/check            # shellcheck, the model table, unit tests (CI runs it)
./setup.sh --dry-run     # what a run would do
```

```
setup.sh                 the runner: checks, then the steps in order
lib/                     logging, dry-run aware commands, steps and summary
steps/comfyui/           comfyui.sh, the models.tsv it downloads and the
                         custom_nodes/ it installs into ComfyUI
steps/ollama.sh          Ollama and its models directory
tests/                   unit tests (the custom nodes)
```

## License

MIT. The models keep their own licences (Apache 2.0 or MIT, listed in
[`steps/comfyui/models.tsv`](steps/comfyui/models.tsv)); the ComfyUI nodes
installed are their authors' (the inpaint nodes are GPL-3.0).
