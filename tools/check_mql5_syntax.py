#!/usr/bin/env python3
"""
Verification structurelle de sources MQL5, sans compilateur.

Lexe le fichier dans le BON ORDRE : chaines et caracteres litteraux d'abord,
commentaires ensuite. L'inverse est un piege classique -- une URL comme
"https://exemple.com" contient // et ferait disparaitre la fin de la chaine,
puis tout le reste du fichier serait mal analyse.

Verifie : equilibre des accolades/parentheses/crochets, chaines non fermees,
commentaires de bloc non fermes.
"""
import sys
import pathlib


def lex(src):
    """Retourne (code_sans_chaines_ni_commentaires, erreurs)."""
    out, errs = [], []
    i, n, line = 0, len(src), 1
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            out.append(c)
            i += 1
        elif c == '"' or c == "'":
            quote, start = c, line
            i += 1
            closed = False
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == "\n":
                    break
                if src[i] == quote:
                    i += 1
                    closed = True
                    break
                i += 1
            if not closed:
                errs.append(f"chaine non fermee ouverte ligne {start}")
            out.append(" ")
        elif src.startswith("//", i):
            while i < n and src[i] != "\n":
                i += 1
        elif src.startswith("/*", i):
            start = line
            i += 2
            closed = False
            while i < n:
                if src.startswith("*/", i):
                    i += 2
                    closed = True
                    break
                if src[i] == "\n":
                    line += 1
                i += 1
            if not closed:
                errs.append(f"commentaire de bloc non ferme ligne {start}")
        else:
            out.append(c)
            i += 1
    return "".join(out), errs


def check(path):
    src = pathlib.Path(path).read_text()
    code, errs = lex(src)

    pairs = {"{": "}", "(": ")", "[": "]"}
    stack = []
    for idx, ch in enumerate(code):
        if ch in pairs:
            stack.append((ch, code[:idx].count("\n") + 1))
        elif ch in pairs.values():
            if not stack or pairs[stack[-1][0]] != ch:
                errs.append(f"fermeture inattendue '{ch}' ligne {code[:idx].count(chr(10)) + 1}")
                break
            stack.pop()
    for ch, ln in stack[:3]:
        errs.append(f"'{ch}' jamais ferme, ouvert ligne {ln}")

    return len(src.splitlines()), errs


def main():
    targets = sys.argv[1:] or [str(p) for p in sorted(pathlib.Path("MQL5").rglob("*.mq*"))]
    bad = 0
    for t in targets:
        lines, errs = check(t)
        name = pathlib.Path(t).name
        if errs:
            bad += 1
            print(f"  {name:<28} {lines:>5} l.   ECHEC")
            for e in errs:
                print(f"      - {e}")
        else:
            print(f"  {name:<28} {lines:>5} l.   OK")
    print(f"\n  {len(targets) - bad}/{len(targets)} fichiers structurellement corrects")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
