#!/usr/bin/env python3
"""Compose Desktop oracle: run a Compose example on Compose Desktop 1.12.0 (the
JVM) and on klio, and compare what they print.

    scripts/compose-oracle.py [options] <example.kt | example name>...

An example written against klio's headless scene (`KlioComposeScene`) or its
PNG helpers (`renderComposeToPng`, `klioDrawToPng`, `klioRenderToPng`) runs
unchanged on the JVM: declarations of the same names and signatures over
Compose Desktop's ImageComposeScene and skia surfaces are compiled beside it.
Each scene frame advances the clock by 16.67 ms, as klio's scene does. The
program runs headless; skiko unpacks its native library under the oracle home.

The classpath is resolved from Maven Central and Google Maven by
scripts/compose-oracle-fetch.py on first use. Everything the oracle writes
lives under target/parity-cache/compose-desktop-1.12.0 (COMPOSE_ORACLE_HOME
overrides it): jars/, cache/ and work/<example>/ with the compiled classes and
both outputs (jvm.txt, klio.txt, and their stderr).

Options:
  --jvm-only        run the JVM side only and print its output (an expected
                    output for a new example)
  --klio BIN        the klio binary (default: zig-out/bin/klio-harness)

The klio run inherits the environment, so KLIO_HOME selects the installed
packs (scripts/klio-local.sh's .klio-local for local pack work). It runs
with KLIO_CLIPBOARD=none, as the headless JVM has no system clipboard, and an
example's klio.datatransfer (java.awt.datatransfer's types under klio's name)
compiles as java.awt.datatransfer on the JVM. kotlinc
2.4.20 comes from KLIO_KOTLINC_JVM_HOME, else target/parity-cache/kotlinc-2.4.20
in this checkout or the main checkout. JAVA picks the JVM (default: java);
JAVA_OPTS adds flags.

Exit status: 0 when every example printed the same on both, 1 when one
differed or failed.
"""
import argparse
import difflib
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KOTLIN_VERSION = "2.4.20"
ORACLE_HOME = os.environ.get(
    "COMPOSE_ORACLE_HOME", os.path.join(ROOT, "target", "parity-cache", "compose-desktop-1.12.0"))

SCENE_SHIM = '''package androidx.compose.ui.klio

import androidx.compose.runtime.Composable
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.input.pointer.PointerEventType
import androidx.compose.ui.unit.Density
import java.io.File
import org.jetbrains.skia.EncodedImageFormat

class KlioComposeScene(private val width: Int, private val height: Int, density: Float = 1f) {
    private val scene = ImageComposeScene(width, height, Density(density))
    private var nanos = 0L

    private fun nextFrame(): org.jetbrains.skia.Image {
        val image = scene.render(nanos)
        nanos += 16_666_666L
        return image
    }

    fun setContent(content: @Composable () -> Unit) {
        scene.setContent(content)
        nextFrame()
    }

    fun frame() {
        nextFrame()
    }

    fun render(): ImageBitmap = nextFrame().toComposeImageBitmap()

    fun renderToPng(path: String): Boolean {
        val data = nextFrame().encodeToData(EncodedImageFormat.PNG) ?: return false
        File(path).writeBytes(data.bytes)
        return true
    }

    fun click(x: Float, y: Float) {
        scene.sendPointerEvent(PointerEventType.Press, Offset(x, y))
        scene.sendPointerEvent(PointerEventType.Release, Offset(x, y))
        nextFrame()
    }

    fun hover(x: Float, y: Float) {
        scene.sendPointerEvent(PointerEventType.Move, Offset(x, y))
        nextFrame()
    }

    fun sendPointerEvent(
        eventType: PointerEventType,
        position: Offset,
        scrollDelta: Offset = Offset(0f, 0f),
        timeMillis: Long = System.nanoTime() / 1_000_000L,
        type: androidx.compose.ui.input.pointer.PointerType = androidx.compose.ui.input.pointer.PointerType.Mouse,
        buttons: androidx.compose.ui.input.pointer.PointerButtons? = null,
        keyboardModifiers: androidx.compose.ui.input.pointer.PointerKeyboardModifiers? = null,
        nativeEvent: Any? = null,
        button: androidx.compose.ui.input.pointer.PointerButton? = null,
    ) = scene.sendPointerEvent(eventType, position, scrollDelta, timeMillis, type, buttons, keyboardModifiers, nativeEvent, button)

    fun sendKeyEvent(event: androidx.compose.ui.input.key.KeyEvent): Boolean = scene.sendKeyEvent(event)

    fun dispose() = scene.close()
}

fun renderComposeToPng(
    width: Int,
    height: Int,
    density: Float,
    path: String,
    content: @Composable () -> Unit,
): Boolean {
    val scene = ImageComposeScene(width, height, Density(density), content = content)
    val data = scene.render().encodeToData(EncodedImageFormat.PNG)
    scene.close()
    data ?: return false
    File(path).writeBytes(data.bytes)
    return true
}
'''

GRAPHICS_SHIM = '''package androidx.compose.ui.graphics

import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import java.io.File
import org.jetbrains.skia.EncodedImageFormat
import org.jetbrains.skia.Surface

private fun Surface.savePng(path: String): Boolean {
    val data = makeImageSnapshot().encodeToData(EncodedImageFormat.PNG) ?: return false
    File(path).writeBytes(data.bytes)
    return true
}

fun klioDrawToPng(width: Int, height: Int, path: String, block: Canvas.() -> Unit): Boolean {
    val surface = Surface.makeRasterN32Premul(width, height)
    surface.canvas.asComposeCanvas().block()
    return surface.savePng(path)
}

fun klioRenderToPng(
    width: Int,
    height: Int,
    density: Float,
    path: String,
    block: DrawScope.() -> Unit,
): Boolean {
    val surface = Surface.makeRasterN32Premul(width, height)
    CanvasDrawScope().draw(
        Density(density),
        LayoutDirection.Ltr,
        surface.canvas.asComposeCanvas(),
        Size(width.toFloat(), height.toFloat()),
        block,
    )
    return surface.savePng(path)
}
'''


def git_main_checkout():
    try:
        common = subprocess.run(
            ["git", "-C", ROOT, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    return os.path.dirname(common)


def kotlinc_home():
    env = os.environ.get("KLIO_KOTLINC_JVM_HOME")
    if env:
        return env
    rel = os.path.join("target", "parity-cache", "kotlinc-" + KOTLIN_VERSION)
    candidates = [os.path.join(ROOT, rel)]
    main = git_main_checkout()
    if main:
        candidates.append(os.path.join(main, rel))
    for c in candidates:
        if os.path.isfile(os.path.join(c, "lib", "compose-compiler-plugin.jar")):
            return c
    sys.exit("compose-oracle: kotlinc %s not found (looked in %s); set KLIO_KOTLINC_JVM_HOME"
             % (KOTLIN_VERSION, ", ".join(candidates)))


def classpath():
    jars = os.path.join(ORACLE_HOME, "jars")
    listing = os.path.join(jars, "classpath.txt")
    if not os.path.isfile(listing) or os.path.getsize(listing) == 0:
        subprocess.run(
            [sys.executable, os.path.join(ROOT, "scripts", "compose-oracle-fetch.py"),
             "--jars", jars, "--cache", os.path.join(ORACLE_HOME, "cache")],
            check=True, stdout=sys.stderr)
    with open(listing) as f:
        return [l.strip() for l in f if l.strip()]


def resolve_example(arg):
    if os.path.isfile(arg):
        return os.path.abspath(arg)
    path = os.path.join(ROOT, "examples", arg if arg.endswith(".kt") else arg + ".kt")
    if os.path.isfile(path):
        return path
    sys.exit("compose-oracle: no example %s" % arg)


def main_class(src, name):
    cls = name[:1].upper() + name[1:] + "Kt"
    with open(src) as f:
        for line in f:
            s = line.strip()
            if s.startswith("package "):
                return s.split()[1] + "." + cls
    return cls


def run_jvm(src, name, kc, cp):
    work = os.path.join(ORACLE_HOME, "work", name)
    classes = os.path.join(work, "classes")
    os.makedirs(work, exist_ok=True)
    subprocess.run(["rm", "-rf", classes], check=True)
    shims = []
    for fname, text in (("KlioComposeScene.kt", SCENE_SHIM), ("KlioGraphics.kt", GRAPHICS_SHIM)):
        shims.append(os.path.join(work, fname))
        with open(shims[-1], "w") as f:
            f.write(text)
    with open(src) as f:
        text = f.read()
    if "klio.datatransfer" in text:
        src = os.path.join(work, os.path.basename(src))
        with open(src, "w") as f:
            f.write(text.replace("klio.datatransfer", "java.awt.datatransfer"))
    cpath = ":".join(cp)
    # The resolved classpath carries kotlin-stdlib at the compiler's version,
    # so kotlinc adds no second copy.
    compile_log = os.path.join(work, "compile.log")
    with open(compile_log, "w") as log:
        rc = subprocess.run(
            [os.path.join(kc, "bin", "kotlinc"), src] + shims + [
             "-Xplugin=" + os.path.join(kc, "lib", "compose-compiler-plugin.jar"),
             "-no-stdlib", "-no-reflect", "-jvm-target", "21",
             "-cp", cpath, "-d", classes],
            stdout=log, stderr=subprocess.STDOUT).returncode
    if rc != 0:
        with open(compile_log) as log:
            sys.stderr.write(log.read())
        return None, "kotlinc failed (%s)" % compile_log
    java = os.environ.get("JAVA", "java")
    cmd = [java, "-Djava.awt.headless=true",
           "-Dskiko.data.path=" + os.path.join(ORACLE_HOME, "skiko-data")]
    cmd += os.environ.get("JAVA_OPTS", "").split()
    cmd += ["-cp", classes + ":" + cpath, main_class(src, name)]
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    with open(os.path.join(work, "jvm.txt"), "w") as f:
        f.write(p.stdout)
    with open(os.path.join(work, "jvm.err"), "w") as f:
        f.write(p.stderr)
    if p.returncode != 0:
        return p.stdout, "the JVM run exited %d (%s)" % (p.returncode, os.path.join(work, "jvm.err"))
    return p.stdout, None


def run_flags(src):
    """The flags an example's `Run with: klio run ...` header names, as the
    corpus runs it (a pack feature it needs, say)."""
    try:
        with open(src, "r", encoding="utf-8", errors="replace") as f:
            head = [f.readline() for _ in range(12)]
    except OSError:
        return []
    for line in head:
        m = re.search(r"Run with:\s*klio run\s+(.*)", line)
        if m:
            return [a for a in m.group(1).split() if not a.endswith(".kt")]
    return []


def run_klio(src, name, klio):
    work = os.path.join(ORACLE_HOME, "work", name)
    env = dict(os.environ, KLIO_CLIPBOARD="none")
    p = subprocess.run([klio, "run", src] + run_flags(src), capture_output=True, text=True, cwd=ROOT, env=env)
    with open(os.path.join(work, "klio.txt"), "w") as f:
        f.write(p.stdout)
    with open(os.path.join(work, "klio.err"), "w") as f:
        f.write(p.stderr)
    if p.returncode != 0:
        return p.stdout, "klio exited %d (%s)" % (p.returncode, os.path.join(work, "klio.err"))
    return p.stdout, None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("examples", nargs="+")
    ap.add_argument("--jvm-only", action="store_true")
    ap.add_argument("--klio", default=os.path.join(ROOT, "zig-out", "bin", "klio-harness"))
    args = ap.parse_args()

    kc = kotlinc_home()
    cp = classpath()
    failed = 0
    for arg in args.examples:
        src = resolve_example(arg)
        name = os.path.splitext(os.path.basename(src))[0]
        jvm, jvm_err = run_jvm(src, name, kc, cp)
        if args.jvm_only:
            if jvm is not None:
                sys.stdout.write(jvm)
            if jvm_err:
                print("%s: %s" % (name, jvm_err), file=sys.stderr)
                failed += 1
            continue
        if jvm is None:
            print("%s: %s" % (name, jvm_err))
            failed += 1
            continue
        klio, klio_err = run_klio(src, name, args.klio)
        errors = [e for e in (jvm_err, klio_err) if e]
        if jvm == klio and not errors:
            print("%s: identical" % name)
            continue
        failed += 1
        print("%s: %s" % (name, "; ".join(errors) if errors else "different"))
        sys.stdout.writelines(difflib.unified_diff(
            jvm.splitlines(True), klio.splitlines(True), "jvm", "klio"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
