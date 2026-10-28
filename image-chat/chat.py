"""Chat-style image editing in the terminal with the local ComfyUI models.

    python chat.py [picture] [--model qwen|klein] [--url http://127.0.0.1:8188]

Type an instruction, the model edits the picture, the result opens in the
image viewer and the next instruction edits that result. Results are saved
in ~/Downloads/<picture name> edits/. comfyui.sh starts ComfyUI before this
and stops it after; run with ComfyUI's own Python (it has Pillow).
"""

import argparse
import io
import readline  # noqa: F401  (arrow keys and history in input())
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image

from comfy_api import ComfyClient, ComfyError
from session import HELP, ChatSession, parse_command, results_dir
from workflows import MODELS, edit_workflow, model_size

DOWNLOADS = Path.home() / "Downloads"


def open_picture(path: Path) -> None:
    """Shows a picture in the desktop's image viewer, without waiting for it."""
    subprocess.Popen(["xdg-open", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def ask_picture() -> Path:
    """Asks for a picture until an existing file is given."""
    while True:
        path = Path(input("Picture to edit: ").strip().strip("'\"")).expanduser()
        if path.is_file():
            return path
        print(f"  No file at {path}")


def new_session(picture: Path, model: str) -> ChatSession:
    session = ChatSession(results_dir(picture, DOWNLOADS), picture.stem, [picture], model)
    session.out_dir.mkdir(parents=True, exist_ok=True)
    return session


def run_model(client: ComfyClient, picture: Image.Image, prompt: str, model: str, seed: int) -> Image.Image:
    """One edit; the result comes back at the picture's own size."""
    png = io.BytesIO()
    picture.save(png, "PNG")
    size = model_size(*picture.size)
    workflow = edit_workflow(model, client.upload(png.getvalue()), size, prompt, seed)
    prompt_id = client.queue(workflow)
    try:
        result = Image.open(io.BytesIO(client.wait_for_image(prompt_id)))
    except KeyboardInterrupt:
        client.interrupt()
        raise
    return result.convert("RGB").resize(picture.size, Image.Resampling.LANCZOS)


def edit(client: ComfyClient, session: ChatSession, prompt: str) -> None:
    """Edits the current picture, saves and shows the result, makes it current."""
    print(f"  ⏳ {session.model} is editing...", flush=True)
    started = time.monotonic()
    with Image.open(session.current) as picture:
        result = run_model(client, picture.convert("RGB"), prompt, session.model, session.seed)
    output = session.next_output()
    result.save(output)
    session.record_edit(output, prompt)
    print(f"  ✅ {output} ({time.monotonic() - started:.0f}s)")
    open_picture(output)


def retry(client: ComfyClient, session: ChatSession, _argument: str) -> None:
    if not session.last_prompt or not session.undo():
        print("  Nothing to retry yet.")
        return
    session.seed += 1
    edit(client, session, session.last_prompt)


def undo(_client: ComfyClient, session: ChatSession, _argument: str) -> None:
    if not session.undo():
        print("  Already at the original picture.")
        return
    print(f"  ↩  Back to {session.current}")
    open_picture(session.current)


def switch_model(_client: ComfyClient, session: ChatSession, argument: str) -> None:
    if argument:
        session.set_model(argument)
    print(f"  Model: {session.model} (available: {', '.join(MODELS)})")


def reopen(_client: ComfyClient, session: ChatSession, argument: str) -> ChatSession:
    path = Path(argument.strip("'\"")).expanduser()
    if not path.is_file():
        raise ValueError(f"no file at {path}")
    print(f"  Now editing {path}; results go to {results_dir(path, DOWNLOADS)}")
    return new_session(path, session.model)


COMMANDS = {
    "retry": retry,
    "undo": undo,
    "model": switch_model,
    "show": lambda _c, s, _a: open_picture(s.current),
    "help": lambda _c, _s, _a: print(HELP),
}


def handle(client: ComfyClient, session: ChatSession, line: str) -> ChatSession:
    """Runs one line of the chat; returns the session to continue with."""
    name, argument = parse_command(line)
    if name == "edit":
        edit(client, session, argument)
    elif name == "open":
        return reopen(client, session, argument)
    elif name in COMMANDS:
        COMMANDS[name](client, session, argument)
    else:
        print(f"  Unknown command /{name}; /help lists them.")
    return session


def chat(client: ComfyClient, session: ChatSession) -> None:
    """The prompt loop; returns on /quit, Ctrl+D or Ctrl+C at the prompt."""
    while True:
        try:
            line = input(f"\n[{session.model}] {session.current.name} > ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if line in ("/quit", "/exit"):
            return
        try:
            session = handle(client, session, line) if line else session
        except KeyboardInterrupt:
            print("\n  ✋ Edit cancelled.")
        except (ComfyError, ValueError, OSError) as error:
            print(f"  ❌ {error}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Edit a picture by chatting with the local ComfyUI models.")
    parser.add_argument("picture", nargs="?", type=Path)
    parser.add_argument("--model", choices=MODELS, default="qwen")
    parser.add_argument("--url", default="http://127.0.0.1:8188")
    args = parser.parse_args()
    try:
        picture = args.picture.expanduser() if args.picture else ask_picture()
    except (EOFError, KeyboardInterrupt):
        sys.exit("")
    if not picture.is_file():
        sys.exit(f"No file at {picture}")
    session = new_session(picture, args.model)
    print(f"{HELP}\n\nResults go to {session.out_dir}")
    chat(ComfyClient(args.url), session)


if __name__ == "__main__":
    main()
