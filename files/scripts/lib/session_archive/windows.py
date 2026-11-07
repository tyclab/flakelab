"""Cut a rendered session into windows of whole records, one model call each, overlapping on record boundaries."""

from dataclasses import dataclass

HEADER = ("SESSION {uuid}\nWINDOW {number} of {total}; records @L{start} to @L{end}. "
          "Earlier windows may hold context you cannot see; later ones may correct this one.\n\n")


@dataclass(frozen=True)
class Window:
    name: str
    start_line: int
    end_line: int
    text: str


def tail(records, sizes, overlap):
    """The last records whose newline-joined text fits in overlap bytes, and that text's size."""
    count, used = 0, -1
    while count < len(records) and used + 1 + sizes[-1 - count] <= overlap:
        used += 1 + sizes[-1 - count]
        count += 1
    return records[len(records) - count:], sizes[len(sizes) - count:], max(used, 0)


def split(rendered, size=60_000, overlap=6_000):
    """Windows of at most size bytes of records (a longer record stands alone); each window after the first opens with
    the previous one's last overlap bytes of records when they fit beside its next record."""
    groups, current, sizes, used = [], [], [], 0
    for record in rendered.records:
        cost = len(record.rendered.encode())
        if current and used + 1 + cost > size:
            groups.append(current)
            current, sizes, used = tail(current, sizes, overlap)
            if current and used + 1 + cost > size:
                current, sizes, used = [], [], 0
        used += cost + (1 if current else 0)
        current.append(record)
        sizes.append(cost)
    if current:
        groups.append(current)
    return [Window(f"{rendered.uuid}.w{number}", group[0].line, group[-1].line,
                   HEADER.format(uuid=rendered.uuid, number=number, total=len(groups), start=group[0].line,
                                 end=group[-1].line) + "\n".join(r.rendered for r in group))
            for number, group in enumerate(groups, 1)]
