"""State of one image chat: which picture is current, which model edits it,
where the results go. No I/O here, so it is tested without ComfyUI."""

from dataclasses import dataclass, field
from pathlib import Path

from workflows import MODELS

HELP = """Type what to change in the picture, e.g. "erase all the texts".
Each edit starts from the previous result.

  /model [qwen|klein]  show or switch the model (qwen ~100 s, follows best; klein ~45 s)
  /retry               redo the last edit with another seed
  /undo                go back to the previous picture
  /open <file>         start over from another picture
  /show                open the current picture in the image viewer
  /help                this help
  /quit                leave (Ctrl+D works too); ComfyUI stops with it
Ctrl+C during an edit cancels it."""


@dataclass
class ChatSession:
    """The pictures of one chat, oldest first; the last one is edited next.

    >>> s = ChatSession(Path("~/Downloads/cat edits"), "cat", [Path("cat.jpg")])
    >>> s.next_output()
    PosixPath('~/Downloads/cat edits/cat-01.png')
    """

    out_dir: Path
    stem: str
    pictures: list[Path]
    model: str = "qwen"
    seed: int = 42
    last_prompt: str = ""
    _saved: int = field(default=0, repr=False)

    @property
    def current(self) -> Path:
        return self.pictures[-1]

    def next_output(self) -> Path:
        """Path for the next result: <stem>-NN.png in out_dir, never reused."""
        return self.out_dir / f"{self.stem}-{self._saved + 1:02d}.png"

    def record_edit(self, result: Path, prompt: str) -> None:
        self.pictures.append(result)
        self.last_prompt = prompt
        self._saved += 1

    def undo(self) -> bool:
        """Drops the latest result; False when only the original is left."""
        if len(self.pictures) < 2:
            return False
        self.pictures.pop()
        return True

    def set_model(self, name: str) -> None:
        if name not in MODELS:
            raise ValueError(f"unknown model {name!r}, expected one of {', '.join(MODELS)}")
        self.model = name


def results_dir(picture: Path, downloads: Path) -> Path:
    """Where the edits of `picture` are saved: ~/Downloads/<name> edits/.

    >>> results_dir(Path("/x/cat.jpg"), Path("/home/me/Downloads"))
    PosixPath('/home/me/Downloads/cat edits')
    """
    return downloads / f"{picture.stem} edits"


def parse_command(line: str) -> tuple[str, str]:
    """Splits "/model qwen" into ("model", "qwen"); an instruction gives ("edit", line).

    >>> parse_command("/open  ~/a b.png")
    ('open', '~/a b.png')
    >>> parse_command("erase the texts")
    ('edit', 'erase the texts')
    """
    if not line.startswith("/"):
        return "edit", line
    name, _, argument = line[1:].partition(" ")
    return name.lower(), argument.strip()
