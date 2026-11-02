# Markdown table layouts

Resize the preview window from narrow to wide. Short numeric columns should remain compact; descriptive columns should receive more room and wrap their text.

## Narrow numbers, long descriptions

| No | Feature | Status | Description |
| --: | :-- | :--: | :-- |
| 1 | Mermaid | Ready | Render a diagram from a fenced block without needing a separate application or internet connection. |
| 2 | Nested blocks | Ready | Keep diagrams inside their surrounding quotes and list items without losing indentation or following paragraphs. |
| 3 | Tables | Ready | Give short identifiers less room so explanatory text can use the available preview width. |
| 4 | Search | Ready | Find a word in the document, highlight occurrences, and move between matches with Return. |
| 5 | Appearance | Check | Compare the same preview in light and dark appearance, including a window that has just been resized. |
| 6 | Final row | Check | This longer final description should wrap instead of forcing the tiny row-number column to occupy a third of the table. |

## Left, center, and right alignment

| Left aligned | Centered | Right aligned |
| :-- | :--: | --: |
| Alpha | Open | 1 |
| Beta | Waiting | 12 |
| Gamma | Complete | 1,234 |
| Delta | Paused | 98,765 |

## Mixed lengths and inline formatting

| ID | Name | Notes | Size |
| --: | :-- | :-- | --: |
| 7 | **README.md** | A short note. | 2 KB |
| 8 | `project-configuration.json` | A much longer explanation with **bold text**, *emphasis*, and an inline `configuration_key` that should remain readable. | 128 KB |
| 9 | Résumé | Unicode text: café, naïve, résumé, Ελληνικά, 日本語. | 42 KB |
| 10 | Archive | A filename with spaces: `Quarterly report final.zip`. | 3.2 MB |

## Escaped pipes

| Operator | Meaning | Example |
| :-- | :-- | :-- |
| `a | b` | A pipe inside inline code | The pipe belongs in this cell. |
| Read | Write | An escaped pipe in ordinary text | This should still be a three-column table. |

## Table inside a blockquote

> | No | Item | Explanation |
> | --: | :-- | :-- |
> | 1 | Quoted table | The text should wrap within the quote rather than taking over the entire preview. |
> | 2 | Another row | The small first column should remain narrow. |

## Table inside a list

- **A list item containing a table**

  | No | Item | Description |
  | --: | :-- | :-- |
  | 1 | First | This row belongs to the table inside the list item. |
  | 2 | Second | This longer description should receive more room than its single-digit row number. |

- A normal list item after the table.

## End marker

This paragraph should appear below every table.
