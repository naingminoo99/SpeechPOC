
from __future__ import annotations

import re
from typing import Any, Optional



_MBS_VOCAB_SEED = [
    "Marina Bay Sands", "MBS", "Paiza", "Sands", "SkyPark",
    "ArtScience", "Shoppes", "Marquee", "Avenue", "Sampan", "Renku",
    "Chairman Suite", "Premier Suite", "Orchid Suite",
    "Presidential Suite", "Club", "Deluxe",
    "Spago", "Cut", "Waku Ghin", "Wakuda", "Punjab Grill", "db Bistro",
    "Bread Street Kitchen", "Lavo", "Koma", "Origin Bar", "Yardbird",
    "Mott 32", "Adrift", "RISE", "CÉ LA VI",
    "Yamazaki", "Hibiki", "Macallan", "Glenfiddich", "Glenmorangie", "Glenlivet",
    "Hennessy", "Rémy Martin", "Don Julio", "Patrón",
    "Johnnie Walker", "Chivas", "Bowmore",
    "Perrier", "Evian", "San Pellegrino", "Voss", "Fiji", "Acqua Panna",
    "Dom Pérignon", "Krug", "Veuve Clicquot", "Moët", "Bollinger", "Ruinart",
    "Longjing", "Tieguanyin", "Oolong", "Pu'er", "Earl Grey",
    "TWG", "Illy", "Nespresso",
    "Cohiba", "Davidoff", "Montecristo",
]

_WHISPER_VOCAB_HINT_BUDGET = 480


def _get_whisper_mbs_hint() -> str:
    out: list[str] = []
    used = 0
    for term in _get_vocab_list():
        addition = (", " if out else "") + term
        if used + len(addition) > _WHISPER_VOCAB_HINT_BUDGET:
            break
        out.append(term)
        used += len(addition)
    return ", ".join(out)

MBS_NORMALIZATIONS = [
    ("paizar / paisa / piza", "Paiza"),
    ("yamazake / yamasaki", "Yamazaki"),
    ("hi-bee-key / hibikey", "Hibiki"),
    ("don peri-yon / dom perinion", "Dom Pérignon"),
    ("voo cliquot / voov click-oh", "Veuve Clicquot"),
    ("wakku gin / waku gin / waku jin / waku-jin / wakujin", "Waku Ghin"),
    ("yad-bert / yardberg", "Yardbird"),
    ("see la vee / sila vie", "CÉ LA VI"),
    ("mo-ay / mo-ette", "Moët"),
    ("pu-air / pu-ehr", "Pu'er"),
    ("tee-gwan-yin", "Tieguanyin"),
    ("long-jing / long ching", "Longjing"),
    ("perry-air / perier", "Perrier"),
    ("san pellegreeno", "San Pellegrino"),
    ("mcallan / makallan", "Macallan"),
    ("spaggoggo / spagogo / spa-go-go", "Spago"),
    ("wakudaaa / wakudada", "Wakuda"),
    ("sandz sweet / sand sweet / sands sweet / sandz suite", "Sands Suite"),
]

MBS_ZH_ALIASES = [
    ("思帕戈 / 斯帕戈 / 斯帕高 / 思帕高 / 斯帕格", "Spago"),
    ("帕伊扎 / 派伊扎 / 派扎 / 派萨 / 派咋 / 派杂 / 拍杂 / 拍砸 / 拍咋 / 帕扎", "Paiza"),
    ("山崎", "Yamazaki"),
    ("麦卡伦 / 麥卡倫", "Macallan"),
    ("轩尼诗 / 軒尼詩", "Hennessy"),
    ("人头马 / 人頭馬", "Rémy Martin"),
    ("尊尼获加 / 約翰走路 / 约翰走路", "Johnnie Walker"),
    ("芝华士 / 芝華士", "Chivas"),
    ("唐培里侬 / 唐·培里侬 / 唐培里儂", "Dom Pérignon"),
    ("凯歌香槟 / 凱歌香檳", "Veuve Clicquot"),
    ("酩悦香槟 / 酩悅香檳 / 酩悦 / 酩悅", "Moët"),
    ("巴黎水", "Perrier"),
    ("依云 / 依雲", "Evian"),
    ("圣培露 / 聖培露 / 圣·培露 / 聖·培露", "San Pellegrino"),
    ("龙井茶 / 龍井茶 / 龙井 / 龍井", "Longjing"),
    ("铁观音 / 鐵觀音", "Tieguanyin"),
    ("乌龙茶 / 烏龍茶", "Oolong"),
    ("普洱茶 / 普洱", "Pu'er"),
    ("高希霸", "Cohiba"),
    ("大卫杜夫 / 大衛杜夫", "Davidoff"),
    ("蒙特克里斯托 / 蒙特克里斯多", "Montecristo"),
    ("滨海湾金沙 / 濱海灣金沙", "Marina Bay Sands"),
]

_ZH_ALIAS_PAIRS: list[tuple[str, str]] = []
for _zh_csv, _en in MBS_ZH_ALIASES:
    for _variant in _zh_csv.split("/"):
        _v = _variant.strip()
        if _v:
            _ZH_ALIAS_PAIRS.append((_v, _en))
_ZH_ALIAS_PAIRS.sort(key=lambda p: len(p[0]), reverse=True)

_ZH_ALIAS_LOOKUP: dict[str, str] = {v: en for v, en in _ZH_ALIAS_PAIRS}
_ZH_ALIAS_RE = (
    re.compile("|".join(re.escape(v) for v, _ in _ZH_ALIAS_PAIRS))
    if _ZH_ALIAS_PAIRS
    else None
)


_ZH_FAMILY_YU_BIAN = re.compile(
    r"[御玉欲育寓域预喻愈浴裕遇誉郁][扁匾贬](?:[会會])?"
)

MBS_ZH_PHONETIC_FAMILIES: list[tuple["re.Pattern[str]", tuple[int, int], str]] = [
    (_ZH_FAMILY_YU_BIAN, (2, 3), "Paiza"),
]


def _apply_zh_aliases_to_text(text: str) -> str:
    """Replace known ZH phoneticizations with their canonical English term.

    Two-pass:
      1. Literal aliases (single regex alternation, longest-first).
      2. Homophone-family patterns (character-class regexes that
         capture pinyin permutations Whisper-zh flips between).

    Cheap; runs in O(len(text) * families) with families ≤ a handful.
    Safe to call on any text (no-op when no variant matches).
    """
    if not text:
        return text
    out = text
    if _ZH_ALIAS_RE is not None:
        out = _ZH_ALIAS_RE.sub(lambda m: _ZH_ALIAS_LOOKUP[m.group(0)], out)
    for pattern, _len_range, canonical in MBS_ZH_PHONETIC_FAMILIES:
        out = pattern.sub(canonical, out)
    return out


def _apply_zh_aliases_to_words(words: list[dict[str, Any]]) -> list[dict[str, Any]]:
    if not words or (not _ZH_ALIAS_PAIRS and not MBS_ZH_PHONETIC_FAMILIES):
        return words
    literal_max = len(_ZH_ALIAS_PAIRS[0][0]) if _ZH_ALIAS_PAIRS else 0
    family_max = max((r[1] for _, r, _ in MBS_ZH_PHONETIC_FAMILIES), default=0)
    global_max = max(literal_max, family_max)

    out: list[dict[str, Any]] = []
    i = 0
    n = len(words)
    while i < n:
        replacement: Optional[tuple[str, int]] = None
        acc_parts: list[str] = []
        k = i
        acc = ""
        while k < n and len(acc) < global_max:
            acc_parts.append(words[k].get("w", "").strip())
            acc = "".join(acc_parts)
            k += 1

        for variant, canonical in _ZH_ALIAS_PAIRS:
            vlen = len(variant)
            if vlen > len(acc):
                continue
            running = ""
            for span in range(len(acc_parts)):
                running += acc_parts[span]
                if len(running) == vlen and running == variant:
                    replacement = (canonical, span + 1)
                    break
                if len(running) > vlen:
                    break
            if replacement is not None:
                break

        if replacement is None:
            for pattern, (min_chars, max_chars), canonical in MBS_ZH_PHONETIC_FAMILIES:
                running = ""
                boundary_per_span: list[int] = []
                for span in range(len(acc_parts)):
                    running += acc_parts[span]
                    boundary_per_span.append(len(running))
                for want in range(max_chars, min_chars - 1, -1):
                    try:
                        span_idx = boundary_per_span.index(want)
                    except ValueError:
                        continue
                    candidate = "".join(acc_parts[: span_idx + 1])
                    if pattern.fullmatch(candidate):
                        replacement = (canonical, span_idx + 1)
                        break
                if replacement is not None:
                    break

        if replacement is not None:
            canonical, consumed = replacement
            first = words[i]
            last = words[i + consumed - 1]
            raw = first.get("w", "")
            prefix_ws = raw[: len(raw) - len(raw.lstrip())]
            out.append({
                "w": f"{prefix_ws}{canonical}",
                "start": float(first.get("start", 0.0)),
                "end": float(last.get("end", 0.0)),
            })
            i += consumed
        else:
            out.append(words[i])
            i += 1
    return out


_FUZZY_NEVER_REWRITE = frozenset("""
i a an the and but or so if for to of he she we they it his her their our my
this that these those there here is are was were be been being have has had
do does did will would should could can may might in on at with by from as
about please thank thanks hello hi good yes no ok okay always never sometimes
today tomorrow tonight morning evening afternoon night service butler guest
hotel room suite prefer prefers preferred like likes liked love loves want
wants wanted need needs needed enjoy enjoys request requests requested
arrival arriving arrives check checks checked checkin checkout welcome
welcomes welcomed better best free fresh water waiter waters drink drinks
meal meals breakfast lunch dinner pillow pillows flower flowers curtain
curtains blanket towel towels bottle bottles table chair sofa shower bath
allergic allergy allergies avoid avoids vegetarian vegan halal kosher
booking booked ordered order orders prepare prepared arrange arranged
remind reminder confirm confirmed schedule scheduled family friend friends
wife husband daughter son madam mister miss doctor about around before
after during between under over very really quite just also still then
than when where which while whose people person time times year years
month months week weeks day days hour hours minute minutes clock
""".split())

_FUZZY_TOKEN_BLOCKLIST = frozenset({
    "bay", "sky", "sea", "cut", "tea", "bar", "cup", "club", "room",
    "suite", "street", "la", "vi", "ce", "don", "san", "old", "new",
    "top", "rise", "grey", "earl",
})

_FUZZY_WORD_RE = re.compile(r"[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ'’-]*")


def _lev_dist(a: str, b: str, cap: int) -> int:
    """Levenshtein with early-out once every cell in a row exceeds `cap`."""
    m, n = len(a), len(b)
    if abs(m - n) > cap:
        return cap + 1
    prev = list(range(n + 1))
    for i in range(1, m + 1):
        cur = [i] + [0] * n
        row_min = i
        ca = a[i - 1]
        for j in range(1, n + 1):
            cost = 0 if ca == b[j - 1] else 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            if cur[j] < row_min:
                row_min = cur[j]
        if row_min > cap:
            return cap + 1
        prev = cur
    return prev[n]


def _fuzzy_dist_cap(length: int) -> int:
    if length <= 6:
        return 1
    if length <= 10:
        return 2
    return 3


def _build_fuzzy_index(terms: list[str]) -> dict[str, list[tuple[str, str]]]:
    """first-letter → [(lower, canonical)] for full terms and useful
    sub-tokens of multi-word terms."""
    index: dict[str, list[tuple[str, str]]] = {}
    seen: set[str] = set()

    def _add(lower: str, canonical: str) -> None:
        if len(lower) < 4 or lower in seen or lower in _FUZZY_TOKEN_BLOCKLIST:
            return
        seen.add(lower)
        index.setdefault(lower[0], []).append((lower, canonical))

    for term in terms:
        t = term.strip()
        if not t:
            continue
        if " " not in t:
            _add(t.lower(), t)
        else:
            for part in t.split():
                if len(part) >= 5:
                    _add(part.lower(), part)
    return index


_fuzzy_index_cache: Optional[dict[str, list[tuple[str, str]]]] = None


def _get_fuzzy_index() -> dict[str, list[tuple[str, str]]]:
    global _fuzzy_index_cache
    idx = _fuzzy_index_cache
    if idx is None:
        idx = _build_fuzzy_index(_get_vocab_list())
        _fuzzy_index_cache = idx
    return idx


def _fuzzy_match_token(
    token_lower: str,
    index: dict[str, list[tuple[str, str]]],
) -> Optional[str]:
    if len(token_lower) < 4 or token_lower in _FUZZY_NEVER_REWRITE:
        return None
    best: Optional[str] = None
    best_d = 99
    for cand_lower, canonical in index.get(token_lower[0], ()):
        if cand_lower == token_lower:
            return None
        cap = _fuzzy_dist_cap(max(len(token_lower), len(cand_lower)))
        d = _lev_dist(token_lower, cand_lower, cap)
        if d <= cap and d < best_d:
            best, best_d = canonical, d
            if d == 1:
                break
    return best


def _fuzzy_correct_en(
    text: str,
    words: list[dict[str, Any]],
    extra_terms: str = "",
) -> tuple[str, list[dict[str, Any]]]:
    index = _get_fuzzy_index()
    if extra_terms:
        extra = _build_fuzzy_index(
            [t.strip() for t in extra_terms.split(",") if t.strip()]
        )
        if extra:
            merged: dict[str, list[tuple[str, str]]] = {
                k: list(v) for k, v in index.items()
            }
            for k, v in extra.items():
                merged.setdefault(k, []).extend(v)
            index = merged
    if not index:
        return text, words

    memo: dict[str, Optional[str]] = {}

    def _lookup(token: str) -> Optional[str]:
        low = token.lower()
        if low not in memo:
            memo[low] = _fuzzy_match_token(low, index)
        return memo[low]

    def _sub(m: "re.Match[str]") -> str:
        repl = _lookup(m.group(0))
        return repl if repl is not None else m.group(0)

    new_text = _FUZZY_WORD_RE.sub(_sub, text) if text else text
    new_words = words
    if words:
        new_words = []
        for w in words:
            raw = w.get("w") or ""
            fixed = _FUZZY_WORD_RE.sub(_sub, raw)
            if fixed != raw:
                nw = dict(w)
                nw["w"] = fixed
                new_words.append(nw)
            else:
                new_words.append(w)
    return new_text, new_words


def _get_vocab_list() -> list[str]:
    # POC: no database — the seed list is the server-side default; per-request terms from the
    # app are layered on via `normalize(..., extra_terms=...)`.
    return _MBS_VOCAB_SEED


def _get_mbs_vocab_line() -> str:
    return ", ".join(_get_vocab_list())


# --- POC additions -------------------------------------------------------------------------

def build_prompt(terms: list[str]) -> str:
    """Whisper initial_prompt from `terms` (app-supplied, else seed), within the hint budget."""
    out: list[str] = []
    used = 0
    for term in terms or _get_vocab_list():
        addition = (", " if out else "") + term
        if used + len(addition) > _WHISPER_VOCAB_HINT_BUDGET:
            break
        out.append(term)
        used += len(addition)
    return ", ".join(out)


_NORMALIZATION_RE: list[tuple["re.Pattern[str]", str]] = []
for _variants, _canonical in MBS_NORMALIZATIONS:
    for _variant in _variants.split("/"):
        _v = _variant.strip()
        if _v:
            # Whole-word, case-insensitive; hyphens/spaces in a variant match either separator.
            _pattern = r"[\s-]+".join(re.escape(p) for p in re.split(r"[\s-]+", _v))
            _NORMALIZATION_RE.append((re.compile(rf"(?<!\w){_pattern}(?!\w)", re.IGNORECASE), _canonical))
_NORMALIZATION_RE.sort(key=lambda p: len(p[0].pattern), reverse=True)


def _apply_en_normalizations(text: str) -> str:
    for pattern, canonical in _NORMALIZATION_RE:
        text = pattern.sub(canonical, text)
    return text


def normalize(text: str, language: Optional[str], extra_terms: list[str]) -> str:
    """Post-process a Whisper transcript: known mishearings, ZH aliases, then fuzzy EN snapping."""
    if not text:
        return text
    text = _apply_en_normalizations(text)
    if language and language.startswith("zh"):
        text = _apply_zh_aliases_to_text(text)
    text, _ = _fuzzy_correct_en(text, [], ", ".join(extra_terms))
    return text
