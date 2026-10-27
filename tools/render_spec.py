#!/usr/bin/env python3
"""Render the master Markdown specification with ReportLab.

This optional publishing utility needs reportlab. It does not run the product,
network commands, models, or benchmarks. DejaVu fonts are used when available;
built-in fonts are the portable fallback.
"""
from __future__ import annotations

import argparse
import html
import re
import textwrap
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    BaseDocTemplate, CondPageBreak, Flowable, Frame, KeepTogether, NextPageTemplate,
    PageBreak, PageTemplate, Paragraph, Spacer, Table, TableStyle, XPreformatted,
)
from reportlab.platypus.tableofcontents import TableOfContents

NAVY = colors.HexColor('#102338')
INK = colors.HexColor('#172B42')
TEAL = colors.HexColor('#007F8B')
CYAN = colors.HexColor('#4AD5DC')
GREEN = colors.HexColor('#D8F199')
MUTED = colors.HexColor('#516273')
PALE = colors.HexColor('#EEF4F7')
LINE = colors.HexColor('#D6E1E8')
WHITE = colors.white
PAGE_W, PAGE_H = letter
MARGIN = 48
WIDTH = PAGE_W - 2 * MARGIN


def fonts():
    fontdir = Path('/usr/share/fonts/truetype/dejavu')
    names = {'CText': 'DejaVuSans.ttf', 'CBold': 'DejaVuSans-Bold.ttf',
             'CItalic': 'DejaVuSans-Oblique.ttf', 'CMono': 'DejaVuSansMono.ttf'}
    if all((fontdir / names[key]).exists() for key in ('CText', 'CBold', 'CMono')):
        for name, filename in names.items():
            selected = fontdir / filename
            if not selected.exists():
                selected = fontdir / names['CText']
            pdfmetrics.registerFont(TTFont(name, str(selected)))
        pdfmetrics.registerFontFamily('CText', normal='CText', bold='CBold', italic='CItalic', boldItalic='CBold')
        return 'CText', 'CBold', 'CMono'
    return 'Helvetica', 'Helvetica-Bold', 'Courier'


TEXT, BOLD, MONO = fonts()
STYLES = {}


def style(name, **kwargs):
    options = {'fontName': TEXT, 'textColor': INK}
    options.update(kwargs)
    result = ParagraphStyle(name, **options)
    STYLES[name] = result
    return result


style('Body', fontSize=10, leading=15, spaceAfter=9, splitLongWords=True)
style('Chapter', fontSize=23, leading=28, fontName=BOLD, spaceBefore=0, spaceAfter=18, keepWithNext=True)
style('Subhead', fontSize=12, leading=17, fontName=BOLD, textColor=TEAL, spaceBefore=10, spaceAfter=7, keepWithNext=True)
style('Small', fontSize=8.5, leading=12, textColor=MUTED, spaceAfter=7)
style('Bullet', fontSize=10, leading=14.6, leftIndent=12, firstLineIndent=-10, spaceAfter=6)
style('Table', fontSize=8.4, leading=11.7, spaceAfter=0, splitLongWords=True)
style('TableHead', fontSize=8.4, leading=11.7, fontName=BOLD, textColor=WHITE, spaceAfter=0)
style('Code', fontName=MONO, fontSize=7.6, leading=10.6, leftIndent=9, rightIndent=9, spaceBefore=4, spaceAfter=11, backColor=PALE, borderPadding=9)
style('CoverKicker', fontSize=9, leading=13, fontName=BOLD, textColor=CYAN, spaceAfter=0)
style('CoverTitle', fontSize=45, leading=54, fontName=BOLD, textColor=WHITE, spaceAfter=0)
style('CoverSub', fontSize=27, leading=35, fontName=BOLD, textColor=WHITE, spaceAfter=0)
style('CoverBody', fontSize=12.5, leading=19, textColor=colors.HexColor('#C7D6E4'), spaceAfter=0)
style('CoverCardTitle', fontSize=11.4, leading=16, fontName=BOLD, textColor=WHITE)
style('CoverCardBody', fontSize=9, leading=13.5, textColor=colors.HexColor('#D2E2EE'))
style('TOCTitle', fontSize=25, leading=31, fontName=BOLD, spaceAfter=15)
style('DiagramLabel', fontSize=10.2, leading=14.2, fontName=BOLD, alignment=1)
style('DiagramBody', fontSize=8.7, leading=12.3, textColor=MUTED, alignment=1)


def normalize(value):
    return value.replace('\u2011', '-').replace('\u2013', '-').replace('\u2014', '-').replace('\u2212', '-')


def inline(value):
    value = html.escape(normalize(value)).replace('&lt;br/&gt;', '<br/>')
    value = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', value)
    value = re.sub(r'`([^`]+)`', lambda m: '<font name="'+MONO+'">'+m.group(1)+'</font>', value)
    value = re.sub(r'\[([^\]]+)\]\((https?://[^ )]+)\)', r'<link href="\2" color="#007F8B">\1</link>', value)
    value = re.sub(r'(?<!["=])(https?://[^\s<>;]+)', lambda m: '<link href="'+m.group(1)+'" color="#007F8B">'+m.group(1)+'</link>' if 'href=' not in value[max(0,m.start()-7):m.start()] else m.group(1), value)
    return value


def p(value, sty='Body'):
    return Paragraph(inline(value), STYLES[sty])


def body_page(canvas, doc):
    canvas.saveState()
    canvas.setStrokeColor(LINE)
    canvas.setLineWidth(0.6)
    canvas.line(MARGIN, PAGE_H - 33, PAGE_W - MARGIN, PAGE_H - 33)
    canvas.setFont(BOLD, 8)
    canvas.setFillColor(TEAL)
    canvas.drawString(MARGIN, PAGE_H - 25, 'CONTINUUM')
    canvas.setFont(TEXT, 7.3)
    canvas.setFillColor(MUTED)
    canvas.drawRightString(PAGE_W - MARGIN, PAGE_H - 25, 'PRODUCT + ENGINEERING SPECIFICATION  /  V3.0')
    canvas.line(MARGIN, 34, PAGE_W - MARGIN, 34)
    canvas.setFont(TEXT, 7.2)
    canvas.drawString(MARGIN, 22, '26 OCT 2026  |  META-CENTERED SPECIFICATION + IMPLEMENTATION')
    canvas.drawRightString(PAGE_W - MARGIN, 22, str(doc.page))
    canvas.restoreState()


def cover_page(canvas, doc):
    canvas.saveState()
    canvas.setFillColor(NAVY)
    canvas.rect(0, 0, PAGE_W, PAGE_H, fill=1, stroke=0)
    canvas.setStrokeColor(colors.HexColor('#1D3A52'))
    canvas.setLineWidth(0.65)
    for y in range(52, 790, 34):
        canvas.line(PAGE_W - 130, y, PAGE_W, y + 55)
    canvas.setFillColor(CYAN)
    canvas.rect(MARGIN, PAGE_H - 70, 50, 5, fill=1, stroke=0)
    canvas.setFillColor(GREEN)
    canvas.circle(PAGE_W - 64, 58, 5, fill=1, stroke=0)
    canvas.restoreState()


class Architecture(Flowable):
    def __init__(self):
        super().__init__()
        self.width = WIDTH
        self.height = 490

    def draw(self):
        c = self.canv

        def box(x, y, w, h, title, body, fill=PALE, accent=TEAL):
            c.setFillColor(fill)
            c.setStrokeColor(LINE)
            c.roundRect(x, y, w, h, 8, fill=1, stroke=1)
            c.setFillColor(accent)
            c.roundRect(x, y, w, 4, 2, fill=1, stroke=0)
            title_p = p(title, 'DiagramLabel')
            _, th = title_p.wrap(w - 20, h)
            title_p.drawOn(c, x + 10, y + h - 10 - th)
            body_p = p(body, 'DiagramBody')
            _, bh = body_p.wrap(w - 20, h)
            body_p.drawOn(c, x + 10, y + h - 16 - th - bh)

        def arrow(x1, y1, x2, y2):
            c.setStrokeColor(TEAL)
            c.setFillColor(TEAL)
            c.setLineWidth(1.2)
            c.line(x1, y1, x2, y2)
            path = c.beginPath()
            path.moveTo(x2, y2)
            path.lineTo(x2 - 3.5, y2 + 6)
            path.lineTo(x2 + 3.5, y2 + 6)
            path.close()
            c.drawPath(path, fill=1, stroke=0)

        half = (WIDTH - 16) / 2
        main = WIDTH - 172
        box(0, 410, half, 66, 'Task context', 'Deadline, evidence, stage,<br/>valid progress and dependencies')
        box(half + 16, 410, half, 66, 'Path observations', 'Fresh samples, baseline,<br/>load and service timing')
        arrow(half/2, 410, half/2, 383)
        arrow(half+16+half/2, 410, half+16+half/2, 383)
        box(0, 307, WIDTH, 76, 'Meta controller', 'Interprets the situation, chooses a bounded tool,<br/>checks the result and requests normal restoration', fill=colors.HexColor('#DDF3F2'))
        arrow(main/2, 307, main/2, 279)
        box(0, 217, main, 62, 'Admission guardian', 'Schema, freshness, ownership,<br/>revision, deadline and limits')
        arrow(main/2, 217, main/2, 189)
        box(0, 127, main, 62, 'Owned actuator', 'Apply or restore an allowed profile;<br/>read back the actual state')
        box(main+16, 127, 156, 152, 'Independent watchdog', 'Owned lease expiry<br/>and crash reconciliation.<br/><br/>Works without the<br/>Meta controller.', fill=colors.HexColor('#F1F3E8'))
        c.setStrokeColor(TEAL)
        c.line(main+16, 160, main, 160)
        path = c.beginPath()
        path.moveTo(main,160)
        path.lineTo(main+6,163.5)
        path.lineTo(main+6,156.5)
        path.close()
        c.setFillColor(TEAL)
        c.drawPath(path,fill=1,stroke=0)
        arrow(main/2, 127, main/2, 99)
        box(0, 20, WIDTH, 79, 'Fresh verification + useful Meta workload', 'Record observed recovery, goodput and validated task output.<br/>Return linked evidence to the controller and the stage view.', fill=colors.HexColor('#E9F1E4'), accent=colors.HexColor('#5B7A30'))


class SpecDoc(BaseDocTemplate):
    def afterFlowable(self, flowable):
        if isinstance(flowable, Paragraph) and flowable.style.name == 'Chapter':
            label = flowable.getPlainText()
            key = 'chapter-' + re.sub(r'[^A-Za-z0-9]+', '-', label).strip('-')
            self.canv.bookmarkPage(key)
            self.canv.addOutlineEntry(label, key, level=0, closed=False)
            self.notify('TOCEntry', (0, label, self.page, key))


def make_table(rows):
    ncols = len(rows[0])
    if ncols == 2:
        weights = [0.29, 0.71]
    elif ncols == 3:
        weights = [0.24, 0.39, 0.37]
    elif ncols == 4:
        weights = [0.19, 0.24, 0.30, 0.27]
    elif ncols == 5:
        weights = [0.09, 0.11, 0.25, 0.15, 0.40]
    else:
        weights = [1/ncols] * ncols
    cells = [[p(cell, 'TableHead' if i == 0 else 'Table') for cell in row] for i, row in enumerate(rows)]
    table = Table(cells, colWidths=[WIDTH*x for x in weights], repeatRows=1, hAlign='LEFT')
    table.setStyle(TableStyle([
        ('BACKGROUND', (0,0), (-1,0), NAVY),
        ('ROWBACKGROUNDS', (0,1), (-1,-1), [colors.white, PALE]),
        ('VALIGN', (0,0), (-1,-1), 'TOP'),
        ('LEFTPADDING', (0,0), (-1,-1), 7), ('RIGHTPADDING', (0,0), (-1,-1), 7),
        ('TOPPADDING', (0,0), (-1,-1), 7), ('BOTTOMPADDING', (0,0), (-1,-1), 7),
        ('LINEBELOW', (0,0), (-1,0), 0.5, NAVY),
        ('LINEBELOW', (0,1), (-1,-1), 0.35, LINE),
    ]))
    return [table, Spacer(1, 12)]


def parse_body(source):
    lines = source.splitlines()
    output = []
    i = next(i for i, line in enumerate(lines) if line.startswith('## 01.'))
    while i < len(lines):
        line = lines[i].strip()
        if not line:
            i += 1
            continue
        if re.match(r'^## \d{2}\.', line):
            if output:
                number = int(re.match(r'^## (\d{2})', line).group(1))
                if number in (16, 23):
                    output.append(PageBreak())
                else:
                    output.extend([CondPageBreak(190), Spacer(1, 20)])
            output.append(p(line[3:], 'Chapter'))
            i += 1
            continue
        if line.startswith('### '):
            output.append(p(line[4:], 'Subhead'))
            i += 1
            continue
        if line.startswith(('~~~', '```')):
            fence = line[:3]
            i += 1
            code = []
            while i < len(lines) and not lines[i].startswith(fence):
                for part in textwrap.wrap(lines[i], width=100, replace_whitespace=False, drop_whitespace=False) or ['']:
                    code.append(part)
                i += 1
            output.append(XPreformatted(html.escape('\n'.join(code)), STYLES['Code']))
            i += 1
            continue
        if line.startswith('|'):
            rows = []
            while i < len(lines) and lines[i].strip().startswith('|'):
                row = [v.strip() for v in lines[i].strip().strip('|').split('|')]
                if not all(re.fullmatch(r'[: -]+', v or '-') for v in row):
                    rows.append(row)
                i += 1
            output.extend(make_table(rows))
            continue
        if line.startswith('- ') or re.match(r'^\d+\. ', line):
            content = line[2:] if line.startswith('- ') else line
            prefix = '- ' if line.startswith('- ') else ''
            output.append(p(prefix + content, 'Bullet'))
            i += 1
            continue
        paragraph = [line]
        i += 1
        while i < len(lines) and lines[i].strip() and not lines[i].lstrip().startswith(('#', '|', '~~~', '```', '- ')) and not re.match(r'^\d+\. ', lines[i]):
            paragraph.append(lines[i].strip())
            i += 1
        output.append(p(' '.join(paragraph)))
    return output


def build(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    doc = SpecDoc(str(target), pagesize=letter, leftMargin=MARGIN, rightMargin=MARGIN,
                  topMargin=52, bottomMargin=48, title='Continuum - Product and Engineering Specification',
                  author='Continuum contributors', subject='Meta agent control, Goose implementation, and hackathon build specification',
                  allowSplitting=True)
    frame = Frame(MARGIN, 48, WIDTH, PAGE_H - 100, leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0)
    doc.addPageTemplates([PageTemplate(id='cover', frames=[frame], onPage=cover_page),
                          PageTemplate(id='normal', frames=[frame], onPage=body_page)])
    story = [Spacer(1, 55), p('META + GOOSE + C++  /  V3.0  /  26 OCTOBER 2026', 'CoverKicker'),
             Spacer(1, 24), p('CONTINUUM', 'CoverTitle'), Spacer(1, 24),
             p('The Meta agent<br/>repairs its path.', 'CoverSub'), Spacer(1, 20),
             p('A complete product specification and implementation repository.<br/>Meta reasoning. Bounded actions. Verified outcomes.', 'CoverBody'), Spacer(1, 32)]
    cards = []
    for title, body in [('OBSERVE', 'Path measurements and<br/>the task that matters.'),
                        ('META DECIDES', 'Model-selected tools<br/>with bounded authority.'),
                        ('VERIFY', 'Measured outcome and<br/>observed restoration.')]:
        cards.append([p(title, 'CoverCardTitle'), Spacer(1, 9), p(body, 'CoverCardBody')])
    cardtable = Table([cards], colWidths=[WIDTH/3]*3)
    cardtable.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,-1),colors.HexColor('#19364D')),
        ('VALIGN',(0,0),(-1,-1),'TOP'), ('LEFTPADDING',(0,0),(-1,-1),14),
        ('RIGHTPADDING',(0,0),(-1,-1),14), ('TOPPADDING',(0,0),(-1,-1),15),
        ('BOTTOMPADDING',(0,0),(-1,-1),18), ('LINEAFTER',(0,0),(-2,-1),1,NAVY)]))
    story.extend([cardtable, Spacer(1, 26), p('Specification, prompts, schemas, and typed source with a working first transport.<br/>Implementation follows this handoff.', 'CoverBody'),
                  NextPageTemplate('normal'), PageBreak(), p('Inside the build', 'TOCTitle'),
                  p('Start with the product and required Meta roles, then follow the architecture, tool contracts, implementation plan, and advanced extension designs. This repository contains the complete specification and the working source described in docs/STATUS.md.'), Spacer(1, 12)])
    toc = TableOfContents()
    toc.levelStyles = [ParagraphStyle('TOC0', fontName=TEXT, fontSize=9.2, leading=12.2,
                                      textColor=INK, leftIndent=0, firstLineIndent=0, spaceBefore=0, spaceAfter=0)]
    toc.dotsMinLevel = 0
    story.extend([toc, PageBreak(), p('Architecture at a glance', 'TOCTitle'),
                  p('The Meta controller sees both network evidence and task context. It selects a permitted tool; deterministic code admits and executes the request. Independent restoration remains available when the model is unreachable.'),
                  Architecture(),                  p('Architecture is proposed. All operational source entrypoints in this repository report their implementation state; see docs/STATUS.md. RaptorQ and local inference are separate extension gates.', 'Small'), PageBreak()])
    story.extend(parse_body(source.read_text(encoding='utf-8')))
    doc.multiBuild(story)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1]/'docs/SPECIFICATION.md')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    build(args.source, args.output)
    print(args.output.resolve())
