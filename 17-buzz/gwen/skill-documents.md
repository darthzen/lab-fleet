---
name: documents
description: Produce and convert Word, PowerPoint, Excel and PDF files on the VM with python-docx, python-pptx, openpyxl and LibreOffice headless.
---
Use this skill when Rick wants a file — a .docx, .pptx, .xlsx or .pdf — rather than a Google-native document. Google Workspace MCP is for Gmail, Calendar and Drive; office files that are not already in Drive come from here.

Where files go. ~/documents/<date>-<slug>/ on the VM, e.g. ~/documents/2026-11-23-quarterly-deck/. One directory per job; the smoke-test files are in ~/documents/smoke/.

Installed (2026-11-23). Distro packages: python313-pip, libreoffice-writer, libreoffice-impress, libreoffice-calc (about 282 MB in /usr/lib64/libreoffice). Venv at ~/docs-venv: python-docx, python-pptx, openpyxl, pypdf. Run python with ~/docs-venv/bin/python3.

Producing a .docx.
```python
from docx import Document
doc = Document()
doc.add_heading('Title', level=1)
doc.add_paragraph('Body text.')
table = doc.add_table(rows=2, cols=3)
table.cell(0,0).text = 'Header'
doc.save('/home/gwen/documents/2026-11-23-slug/doc.docx')
```

Producing a .pptx.
```python
from pptx import Presentation
prs = Presentation()
s = prs.slides.add_slide(prs.slide_layouts[0])
s.shapes.title.text = 'Title slide'
s.placeholders[1].text = 'Subtitle'
s2 = prs.slides.add_slide(prs.slide_layouts[1])
s2.shapes.title.text = 'Bullet slide'
tf = s2.placeholders[1].text_frame
tf.text = 'First point'
tf.add_paragraph().text = 'Second point'
prs.save('/home/gwen/documents/2026-11-23-slug/deck.pptx')
```

Producing an .xlsx.
```python
from openpyxl import Workbook
wb = Workbook()
ws = wb.active
ws.append(['Col A', 'Col B', 'Col C'])
ws.append(['row1', 'row2', 'row3'])
ws['D5'] = '=SUM(C2:C4)'
wb.save('/home/gwen/documents/2026-11-23-slug/data.xlsx')
```

Converting to PDF. LibreOffice headless, one command per file, output lands beside the input:
```
cd ~/documents/2026-11-23-slug && libreoffice --headless --convert-to pdf doc.docx
```
For .pptx the same command produces a PDF with one page per slide. For .xlsx, convert the active sheet.

Reading back. A file is done only when its content is read back, not when the save command exits with 0.
- .docx: open with python-docx, print doc.paragraphs[0].text and any table cells.
- .pptx: open with python-pptx, print s.shapes.title.text for every slide.
- .xlsx: open with openpyxl (data_only=False to see formulas, True for cached values), print header row and the cells you wrote.
- .pdf: open with pypdf, print len(reader.pages) and reader.pages[0].extract_text()[:80].

Delivery. Until the google-workspace skill is live, tell Rick the path on the VM (~/documents/<date>-<slug>/<file>). Once it is live, upload the file to his Google Drive through the google-workspace skill and hand him the link.
