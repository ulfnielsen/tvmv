# Field notes

TVMV renders Markdown as you read it and edits it in place. The markup stays
out of sight until you ask for it, so a draft reads like the {==finished page==}[^rv-a1b2].

## Review

Comments and suggestions are stored in the file itself, as CriticMarkup tied to
footnote threads, so they survive {~~every~>any~~}[^rv-c3d4] editor and every
diff. Each thread shows as a card beside the text it is about.

- Select text and choose **Comment…** from the right-click menu.
- Suggest an edit, and the reader can accept or reject it.{++ One click applies it.++}[^rv-e5f6]
- Replies are signed with your git name.

## Tables

| Feature        | Reading | Editing |
|:---------------|:-------:|:-------:|
| Outline        |   yes   |   yes   |
| Tables         |   yes   |   yes   |
| Review threads |   yes   |   yes   |
| Bookmarks      |   yes   |   —     |

In edit mode, hover a cell to add or remove rows and columns.

## Code

```swift
func greet(_ name: String) -> String {
    "Hello, \(name)"
}
```

> Plain text in, plain text out: the file stays yours.

[^rv-a1b2]: @ulf 2026-10-20: Is "finished" too strong for a draft?
    @mira 2026-10-20: It's the point — no visible syntax while reading.
[^rv-c3d4]: @mira 2026-10-20 suggestion: "any" reads better here.
[^rv-e5f6]: @ulf 2026-10-20 suggestion: Worth saying how cheap accepting is.
