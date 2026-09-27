"""Read a packet from a folder or a zip through one interface.

A zip may hold the packet at its root or inside one top-level folder. Entry names that are
absolute or climb out with '..' are refused before anything is read, because a packet comes from
a phone the server does not control.
"""

from __future__ import annotations

import hashlib
import zipfile
from pathlib import Path, PurePosixPath


class PacketError(Exception):
    """The packet cannot be opened at all (no manifest, unsafe zip)."""


def safe_relative(path: str) -> bool:
    p = PurePosixPath(path)
    return bool(path) and not p.is_absolute() and ".." not in p.parts and "\\" not in path


class PacketFiles:
    def __init__(self, source: Path):
        self.source = source
        if source.is_dir():
            self._zip = None
            self._root = source
            self._prefix = ""
            if not (source / "manifest.json").is_file():
                raise PacketError(f"{source} has no manifest.json")
            return
        if not zipfile.is_zipfile(source):
            raise PacketError(f"{source} is neither a folder nor a zip")
        self._zip = zipfile.ZipFile(source)
        self._root = None
        names = [i.filename for i in self._zip.infolist() if not i.is_dir()]
        unsafe = [n for n in names if not safe_relative(n)]
        if unsafe:
            raise PacketError(f"zip entry names leave the packet: {unsafe[:3]}")
        manifests = [n for n in names if PurePosixPath(n).name == "manifest.json"]
        top = [n for n in manifests if len(PurePosixPath(n).parts) <= 2]
        if len(top) != 1:
            raise PacketError(
                f"zip must hold exactly one manifest.json at its root or in one top folder, "
                f"found {manifests[:3] or 'none'}"
            )
        parent = str(PurePosixPath(top[0]).parent)
        self._prefix = "" if parent == "." else parent + "/"

    def names(self) -> set[str]:
        """Every file in the packet, as manifest-relative paths."""
        if self._zip is None:
            return {
                p.relative_to(self._root).as_posix() for p in self._root.rglob("*") if p.is_file()
            }
        return {
            i.filename[len(self._prefix) :]
            for i in self._zip.infolist()
            if not i.is_dir() and i.filename.startswith(self._prefix)
        }

    def exists(self, path: str) -> bool:
        if not safe_relative(path):
            return False
        if self._zip is None:
            return (self._root / path).is_file()
        try:
            self._zip.getinfo(self._prefix + path)
        except KeyError:
            return False
        return True

    def size(self, path: str) -> int:
        if self._zip is None:
            return (self._root / path).stat().st_size
        return self._zip.getinfo(self._prefix + path).file_size

    def read(self, path: str) -> bytes:
        if not safe_relative(path):
            raise PacketError(f"unsafe path {path!r}")
        if self._zip is None:
            return (self._root / path).read_bytes()
        return self._zip.read(self._prefix + path)

    def sha256(self, path: str) -> str:
        digest = hashlib.sha256()
        if self._zip is None:
            with (self._root / path).open("rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    digest.update(chunk)
        else:
            with self._zip.open(self._prefix + path) as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    digest.update(chunk)
        return digest.hexdigest()

    def open(self, path: str):
        """A binary file object, for readers that stream (images, large CSVs)."""
        if self._zip is None:
            return (self._root / path).open("rb")
        return self._zip.open(self._prefix + path)
