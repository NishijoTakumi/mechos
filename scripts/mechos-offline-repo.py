#!/usr/bin/env python3
# MECHOS_OFFLINE_REPO_BUILDER_V1
"""Build the MechOS offline install repository.

Resolves the complete dependency closure of the installer's package list
against the live Arch repositories, downloads (and signature-verifies) it with
pacman, and lays it out as a normal three-repository file mirror:

    <out>/core/os/x86_64/{core.db,*.pkg.tar.zst}
    <out>/extra/os/x86_64/...
    <out>/multilib/os/x86_64/...
    <out>/manifest.json

The installer points pacstrap at these directories with file:// servers, so a
clean install needs no network at all. Repository names intentionally match
the real ones: pacstrap copies the sync databases into the new system, which
keeps `pacman -S --needed` working offline there and lets a later online
`pacman -Syu` replace them normally.

Runs inside the Arch build container (needs pacman and repo-add).
"""
import argparse
import datetime
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ARCH = "x86_64"
REPOS = ("core", "extra", "multilib")
PKG_RE = re.compile(r"\.pkg\.tar\.(zst|xz|gz|bz2|lz4|lrz|lzo|Z)$")


def log(msg):
    print(f"[MechOS Offline Repo] {msg}", flush=True)


def die(msg):
    print(f"[MechOS Offline Repo] ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def run(cmd, capture=False, cwd=None):
    log("+ " + " ".join(str(c) for c in cmd))
    res = subprocess.run(
        [str(c) for c in cmd],
        cwd=cwd,
        check=False,
        text=True,
        stdout=subprocess.PIPE if capture else None,
    )
    if res.returncode != 0:
        die(f"command failed ({res.returncode}): {' '.join(str(c) for c in cmd)}")
    return res.stdout if capture else ""


def read_targets(path):
    targets = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            targets.extend(line.split())
    seen, ordered = set(), []
    for name in targets:
        if name not in seen:
            seen.add(name)
            ordered.append(name)
    if not ordered:
        die(f"package list is empty: {path}")
    return ordered


def make_conf(src, dst):
    """Copy pacman.conf (the container's by default) with [multilib] enabled."""
    if not Path(src).is_file():
        die(f"pacman configuration not found: {src}")
    text = Path(src).read_text(encoding="utf-8")
    text = re.sub(
        r"^#\[multilib\]\n#Include = /etc/pacman\.d/mirrorlist",
        "[multilib]\nInclude = /etc/pacman.d/mirrorlist",
        text,
        flags=re.M,
    )
    if not re.search(r"^\[multilib\]", text, flags=re.M):
        text += "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n"
    Path(dst).write_text(text, encoding="utf-8")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    ap.add_argument("--packages", required=True, help="file with package names")
    ap.add_argument("--out", required=True, help="output repository directory")
    ap.add_argument("--work", default=None, help="scratch directory (default: temp)")
    ap.add_argument("--pacman-conf", default="/etc/pacman.conf", help="base pacman.conf to derive from")
    args = ap.parse_args()

    for tool in ("pacman", "repo-add"):
        if shutil.which(tool) is None:
            die(f"{tool} is required (run inside the Arch build container)")

    targets = read_targets(args.packages)
    out = Path(args.out)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    own_work = args.work is None
    work = Path(args.work) if args.work else Path(tempfile.mkdtemp(prefix="mechos-offline-"))
    cache, dbpath = work / "cache", work / "db"
    for d in (cache, dbpath / "local", dbpath / "sync"):
        d.mkdir(parents=True, exist_ok=True)
    conf = work / "pacman.conf"
    make_conf(args.pacman_conf, conf)

    # No --root: -Sy/-Sp/-Sw never modify the root, and an explicit dbpath keeps
    # the container's own package database untouched. The empty local database
    # makes pacman resolve the *whole* closure, not just what is missing here.
    base = [
        "pacman", "--config", conf, "--dbpath", dbpath, "--cachedir", cache,
        "--logfile", work / "pacman.log", "--noconfirm",
    ]

    try:
        log(f"resolving {len(targets)} install targets")
        run(base + ["-Sy"])
        resolved = run(
            base + ["-Sp", "--print-format", "%r\t%n\t%v\t%f"] + targets, capture=True
        )
        rows = []
        for line in resolved.splitlines():
            parts = line.split("\t")
            if len(parts) == 4 and parts[0] in REPOS:
                rows.append(parts)
        if not rows:
            die("pacman resolved no packages; check the package list")
        # An unresolvable target (e.g. a package that left the repos) already
        # made the -Sp above fail, so the build stops here rather than shipping
        # an installer that cannot finish.
        log(f"closure: {len(rows)} packages; downloading and verifying signatures")
        run(base + ["-Sw"] + targets)

        per_repo = {r: [] for r in REPOS}
        total = 0
        for repo, name, ver, fname in rows:
            src = cache / fname
            if not src.is_file() or src.stat().st_size == 0:
                die(f"downloaded package is missing or empty: {fname}")
            dest_dir = out / repo / "os" / ARCH
            dest_dir.mkdir(parents=True, exist_ok=True)
            shutil.move(str(src), dest_dir / fname)
            sig = cache / (fname + ".sig")
            if sig.is_file():
                shutil.move(str(sig), dest_dir / (fname + ".sig"))
            per_repo[repo].append({"name": name, "version": ver, "file": fname})
            total += (dest_dir / fname).stat().st_size

        for repo in REPOS:
            dest_dir = out / repo / "os" / ARCH
            if not per_repo[repo]:
                # pacstrap refreshes every configured repo, so each needs a db.
                dest_dir.mkdir(parents=True, exist_ok=True)
            files = sorted(p.name for p in dest_dir.iterdir() if PKG_RE.search(p.name))
            db = f"{repo}.db.tar.gz"
            run(["repo-add", "--quiet", db] + files, cwd=dest_dir)
            # pacman reads <repo>.db; replace repo-add's symlinks with real
            # files so the tree survives any copy that does not keep links.
            for stem in (f"{repo}.db", f"{repo}.files"):
                link = dest_dir / stem
                if link.is_symlink():
                    target = (dest_dir / link.readlink()).resolve()
                    link.unlink()
                    shutil.copy2(target, link)
            for junk in dest_dir.glob("*.old"):
                junk.unlink()
            if not (dest_dir / f"{repo}.db").is_file():
                die(f"repository database was not created for {repo}")

        manifest = {
            "schema": 1,
            "built_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
            "arch": ARCH,
            "targets": targets,
            "package_count": len(rows),
            "total_bytes": total,
            "repos": {r: {"count": len(per_repo[r])} for r in REPOS},
            "packages": {r: per_repo[r] for r in REPOS},
        }
        (out / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n", encoding="utf-8")
        log(f"offline repository ready: {len(rows)} packages, {total / 2**30:.2f} GiB at {out}")
    finally:
        if own_work:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
