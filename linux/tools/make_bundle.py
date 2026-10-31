#!/usr/bin/env python3
"""
make_bundle.py - a signed RAUC bundle for the DE25-Standard
(docs/plan_rauc.md, step 1).

    python3 linux/tools/make_bundle.py gui          # linux/webapp/ as a GUI release
    python3 linux/tools/make_bundle.py core         # build/images' FPGA core
    python3 linux/tools/make_bundle.py gui core     # both, one bundle (GUI activated first)
    python3 linux/tools/make_bundle.py image        # the whole image: rootfs + QSPI (step 2)
    python3 linux/tools/make_bundle.py core --core X.core.rbf --out x.raucb
    python3 linux/tools/make_bundle.py gui --keys DIR   # another key pair (refusal tests)

Each part is one artifact for the board's repositories (system.conf):

    [image.gui/de25web]   the release deploy_web.py would upload (the three .py,
                          static/, VERSION with the git state, BOARD)
    [image.core/de25_std] de25_std.core.rbf + de25_std.core.json (make_jic.sh),
                          checked as deploy_fpga.py checks them

An image (docs/plan_rauc.md step 2, A/B) goes into the slot group that is
not running, in this order:

    [image.rootfs]        build/images/rootfs.ext4 (make_sdcard_image.sh): the
                          rootfs with its kernel and DT
    [image.qspi]          the RSU bundle (make_rsu_bundle.py's: application
                          image, its U-Boot, its core), written by the
                          bundle's install hook (linux/board/rauc/image-hook)
                          through fpga_access.py

On the board `rauc install` checks the signature (keys from
linux/tools/rauc_keys.sh), dm-verity and compatible=de25-std, then its
post-install handler (linux/board/rauc/post-install) hands each part to the
code that tests it and rolls it back. deploy_bundle.py uploads and follows it.

Needs build/rauc/rauc-host (./build.sh rauc) and mksquashfs (squashfs-tools).
Writes build/images/de25_std_<parts>_<version>.raucb.
"""
import argparse
import gzip
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from deploy_fpga import CORE_NAME, pack_bundle  # noqa: E402
from deploy_web import pack_release  # noqa: E402
import make_rsu_bundle  # noqa: E402

ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "build", "images")
RAUC = os.path.join(ROOT, "build", "rauc", "rauc-host")
COMPATIBLE = "de25-std"
ARTIFACT = {"gui": "de25web", "core": "de25_std"}
ROOTFS = os.path.join(OUT, "rootfs.ext4")
HOOK = os.path.join(ROOT, "linux", "board", "rauc", "image-hook")
ORDER = ("image", "gui", "core")       # the slots first, then the artifacts


def make(parts, core_path, manifest_path, keys, out=None):
    """the bundle's path and a one-line description"""
    if not os.access(RAUC, os.X_OK):
        sys.exit(f"no {RAUC} - run ./build.sh rauc")
    if not shutil.which("mksquashfs"):
        sys.exit("no mksquashfs - install squashfs-tools")
    cert, key = os.path.join(keys, "signing.cert.pem"), os.path.join(keys, "signing.key.pem")
    if not (os.path.isfile(cert) and os.path.isfile(key)):
        sys.exit(f"no signing key in {keys} - run linux/tools/rauc_keys.sh")
    tars, desc, version = {}, [], []
    if "gui" in parts:
        blob, gui_version = pack_release()
        tars["gui"] = gzip.decompress(blob)
        desc.append(f"GUI {gui_version}")
        version.append(gui_version.replace("+", "-"))
    if "core" in parts:
        blob, manifest = pack_bundle(core_path, manifest_path)
        tars["core"] = gzip.decompress(blob)
        built = time.strftime("%Y-%m-%d %H:%M", time.localtime(manifest["build_id"]))
        desc.append(f"core build {manifest['build_id']} ({built})")
        version.append(f"core{manifest['build_id']}")
    image = None
    if "image" in parts:
        if not os.path.isfile(ROOTFS):
            sys.exit(f"no {ROOTFS} - run ./build.sh sdcard")
        qspi, rsu = make_rsu_bundle.pack({n: os.path.join(ROOT, "build", d)
                                          for n, d in make_rsu_bundle.FILES.items()})
        image = qspi
        desc.insert(0, f"image build {rsu['build_id']} (git {rsu['git']}), rootfs "
                       f"{time.strftime('%Y-%m-%d %H:%M', time.localtime(os.path.getmtime(ROOTFS)))}")
        version.insert(0, f"build{rsu['build_id']}")
    version = "_".join(version)
    with tempfile.TemporaryDirectory() as work:
        content = os.path.join(work, "content")
        os.mkdir(content)
        sections = []
        if image is not None:
            try:                                # 512 MB: a link where it can be one
                os.link(ROOTFS, os.path.join(content, "rootfs.ext4"))
            except OSError:
                shutil.copyfile(ROOTFS, os.path.join(content, "rootfs.ext4"))
            with open(os.path.join(content, "qspi.tar.gz"), "wb") as f:
                f.write(image)
            shutil.copyfile(HOOK, os.path.join(content, "hook"))
            os.chmod(os.path.join(content, "hook"), 0o755)
            sections.append("[image.rootfs]\nfilename=rootfs.ext4\n")
            sections.append("[image.qspi]\nfilename=qspi.tar.gz\nhooks=install\n")
        for part in ("gui", "core"):            # the handler's order, too
            if part not in tars:
                continue
            with open(os.path.join(content, f"{part}.tar"), "wb") as f:
                f.write(tars[part])
            sections.append(f"[image.{part}/{ARTIFACT[part]}]\nfilename={part}.tar\nconvert=tar-extract\n")
        with open(os.path.join(content, "manifest.raucm"), "w") as f:
            f.write(f"[update]\ncompatible={COMPATIBLE}\nversion={version}\n"
                    f"description={', '.join(desc)}\nbuild={time.strftime('%Y-%m-%dT%H:%M:%S')}\n\n"
                    "[bundle]\nformat=verity\n\n"
                    + ("[hooks]\nfilename=hook\n\n" if image is not None else "")
                    + "\n".join(sections))
        os.makedirs(OUT, exist_ok=True)
        out = out or os.path.join(OUT, f"de25_std_{'+'.join(p for p in ORDER if p in parts)}_{version}.raucb")
        if os.path.exists(out):
            os.remove(out)
        r = subprocess.run([RAUC, "bundle", f"--cert={cert}", f"--key={key}", content, out],
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit(f"rauc bundle failed:\n{r.stdout}{r.stderr}")
    return out, ", ".join(desc)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("parts", nargs="+", choices=ORDER)
    ap.add_argument("--core", default=os.path.join(OUT, CORE_NAME))
    ap.add_argument("--manifest", default=None, help="default: the .json beside --core")
    ap.add_argument("--keys", default=os.environ.get("RAUC_KEYS", os.path.expanduser("~/.de25_rauc_keys")))
    ap.add_argument("--out", help="default: build/images/de25_std_<parts>_<version>.raucb")
    args = ap.parse_args()
    out, desc = make(set(args.parts), args.core, args.manifest or args.core.replace(".rbf", ".json"),
                     args.keys, args.out)
    print(f"{out}: {desc}, {os.path.getsize(out)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
