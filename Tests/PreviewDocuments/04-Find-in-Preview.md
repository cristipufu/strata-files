# Find in a Markdown preview

Use the **Find** field at the top of the preview. Try `needle`, `resume`, `cafe`, or `Strata`.

Press **Return** to move forward and **Shift-Return** to move backward. Clear the field to remove the search highlights. Search finds document text; diagrams are images, so their labels are not part of the text search.

## A needle in a heading

Here is a needle in ordinary prose. Here is another NEEDLE in uppercase. The next occurrence is **needle in bold**, followed by *needle in italics*.

## Matches in a quote

> A needle also appears in this quoted paragraph.
>
> A second quoted needle gives you another match to navigate to.

## Matches in a table

| No | Category | Text |
| --: | :-- | :-- |
| 1 | First match | A needle in the first table row. |
| 2 | Second match | Another needle in a longer explanation that should wrap when the window is narrow. |
| 3 | Different word | Strata can search this row too. |

## Matches in code

```swift
let needle = "Find me in this code block"
let application = "Strata"
```

## Accents and case

These words let you compare case-insensitive and accent-insensitive matching:

- résumé
- resume
- RESUME
- Café
- cafe
- CAFÉ

## More text between matches

A file preview combines headings, lists, tables, and code in a single document. Searching should not change the file or remove paragraphs from the preview. You should still be able to select text and scroll normally after clearing the field.

The next paragraph contains the final needle.

## Last section

Strata appears once more at the end. Search backward from here to check that navigation reaches earlier matches.
