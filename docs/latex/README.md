# LaTeX documents

AXI-branded PDFs for partner reviews and technical reference.

## What's here

| File | Purpose |
|---|---|
| `AXI_peaq_Milestone_Update.tex` | Partnership-facing milestone update for the peaq team. Same content as the root `MILESTONES.md`, presented as an AXI letterhead document. |
| `AXI_peaq_Milestone_Update.pdf` | Compiled output (9 pages). Send this directly to the peaq team. |
| `AXI-Logo-link.png` | AXI logo asset. Required at compile time. |

## Compile

You need MiKTeX or TeX Live with `lualatex`. Calibri must be installed (it's bundled with Windows; for macOS or Linux, install Microsoft Calibri from the Microsoft fonts package).

```bash
lualatex AXI_peaq_Milestone_Update.tex
lualatex AXI_peaq_Milestone_Update.tex     # second pass for cross-references
```

The `lastpage` package needs two passes to resolve "Page X of Y" in the footer.

## Style

Mirrors the AXI technical-reference template (matches `AXI_FMC130_Vehicle_Compatibility_Guide`). Colour palette:

| Name | Hex | Use |
|---|---|---|
| `axiprimary` | `#0D4034` | Section headings · accent rule · headings |
| `axiaccent` | `#18E299` | Section underline |
| `axidark` | `#1B2A3D` | Subsection text |
| `axigray` | `#6B7280` | Captions · meta · footers |
| `axilight` | `#F0FDF4` | Callout backgrounds · alternating table rows |
| `tablerow` | `#F8FAF9` | Table row tinting |

Font: Calibri (regular + bold + italic).
Page: A4 with 2 cm margins, fancy header + footer with page numbers, document title in header-left and "Confidential / Partnership review" in header-right.

## Adding a new document

1. Copy the `.tex` source as a starting template.
2. Update the title block on the cover (title, subtitle, ref code, date).
3. Update the header (`\fancyhead[L]` and `\fancyhead[R]`).
4. Update the `hypersetup` PDF metadata (`pdftitle`, `pdfsubject`).
5. Compile twice with `lualatex`.

Keep all docs Calibri, A4, 10pt. Use the `axiprimary`-coloured `\section` heads with the `axiaccent` underline rule.
