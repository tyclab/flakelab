"""The citation check: is each quote of a summary item in a record its anchors name, exactly or with a difflib ratio of
FUZZY against a quote-long window of the record aligned on their longest common block? Reads, writes nothing."""

from difflib import SequenceMatcher

FUZZY = 0.85
LISTS = ("why", "when", "how", "outcome", "open_ends", "continue")


def close(quote, text) -> bool:
    # autojunk would drop a long quote's common characters from the match and understate the ratio.
    block = SequenceMatcher(None, text, quote, autojunk=False).find_longest_match(0, len(text), 0, len(quote))
    start = min(max(block.a - block.b, 0), max(len(text) - len(quote), 0))
    window = text[start:start + len(quote)]
    return SequenceMatcher(None, quote, window, autojunk=False).ratio() >= FUZZY


def found(quote, texts) -> bool:
    if not quote.strip():
        return False
    return any(quote in text for text in texts) or any(close(quote, text) for text in texts)


def cited(item, texts) -> dict:
    anchors = [line for line in dict.fromkeys(item["anchors"]) if line in texts]
    named = [text for line in anchors for text in texts[line]]
    verified = bool(anchors) and all(found(quote, named) for quote in item["quotes"])
    return {**item, "anchors": anchors, "verified": verified}


def check(summary, rendered) -> dict:
    """A copy of summary whose list items keep only anchors that name a record, once each, and gain verified."""
    texts = {}
    for record in rendered.records:
        texts.setdefault(record.line, []).append(record.text)
    return {**summary, **{name: [cited(item, texts) for item in summary[name]] for name in LISTS}}
