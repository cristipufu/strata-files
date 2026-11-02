"""Helpers the Swift source audits share."""


def code_only(source):
    """Ignore comments and string contents, preserving newlines and code offsets."""
    chars = list(source)
    index = 0
    while index < len(source):
        start = index
        if source.startswith("//", index):
            end = source.find("\n", index)
            index = len(source) if end < 0 else end
        elif source.startswith("/*", index):
            depth = 1
            index += 2
            while index < len(source) and depth:
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
        elif source[index] == '"':
            delimiter = '"""' if source.startswith('"""', index) else '"'
            index += len(delimiter)
            while index < len(source):
                if source[index] == "\\":
                    index += 2
                elif source.startswith(delimiter, index):
                    index += len(delimiter)
                    break
                else:
                    index += 1
        else:
            index += 1
            continue
        for position in range(start, min(index, len(chars))):
            if chars[position] != "\n":
                chars[position] = " "
    return "".join(chars)
