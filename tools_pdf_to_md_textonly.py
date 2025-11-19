#!/usr/bin/env python3
"""
pdf_to_md_textonly.py

Simple PDF -> Markdown converter for text-only PDFs (NO OCR).

- Extracts selectable text using PyMuPDF (fitz).
- If a page has structured HTML, it converts HTML -> Markdown via html2text.
- Optionally extracts embedded images when --images is passed.
- Writes one .md file per PDF in --out-dir, and saves images in a sibling folder per PDF if extracted.

Usage:
  python tools/pdf_to_md_textonly.py input.pdf
  python tools/pdf_to_md_textonly.py /path/to/pdf_dir --out-dir ./md_outputs --images
  python tools/pdf_to_md_textonly.py input.pdf --overwrite

Dependencies:
  pip install pymupdf html2text
"""
from __future__ import annotations
import argparse
import logging
import os
import sys
from pathlib import Path
from typing import List, Tuple, Dict

LOG = logging.getLogger("pdf_to_md_textonly")


def ensure_dir(p: Path):
    p.mkdir(parents=True, exist_ok=True)


def extract_text_pages(pdf_path: Path) -> List[str]:
    """Extract selectable text per page using PyMuPDF (get_text('text'))."""
    try:
        import fitz  # PyMuPDF
    except Exception as e:
        LOG.error("PyMuPDF (fitz) is required for text extraction: %s", e)
        raise

    doc = fitz.open(str(pdf_path))
    pages_text: List[str] = []
    for p in doc:
        txt = p.get_text("text")
        pages_text.append(txt or "")
    doc.close()
    return pages_text


def html_page_to_markdown(pdf_path: Path, page_number: int) -> str:
    """
    Use PyMuPDF get_text('html') for the page and convert HTML -> Markdown via html2text.
    Return empty string on failure.
    """
    try:
        import fitz
        import html2text
    except Exception as e:
        LOG.debug("html2text or fitz missing (HTML->MD fallback disabled): %s", e)
        return ""

    try:
        doc = fitz.open(str(pdf_path))
        page = doc[page_number]
        html = page.get_text("html")
        doc.close()
        if not html:
            return ""
        converter = html2text.HTML2Text()
        converter.body_width = 0
        converter.ignore_images = True
        md = converter.handle(html)
        return md.strip()
    except Exception as e:
        LOG.debug("HTML->Markdown conversion failed for %s page %d: %s", pdf_path, page_number + 1, e)
        return ""


def extract_images(pdf_path: Path, out_image_dir: Path, prefix: str) -> Dict[int, List[Path]]:
    """
    Extract embedded images from PDF and save into out_image_dir.
    Returns mapping page_index -> list of image paths.
    """
    try:
        import fitz
    except Exception as e:
        LOG.error("PyMuPDF (fitz) is required for image extraction: %s", e)
        raise

    ensure_dir(out_image_dir)
    doc = fitz.open(str(pdf_path))
    images_by_page: Dict[int, List[Path]] = {}
    for page_index, page in enumerate(doc):
        image_list = page.get_images(full=True)
        if not image_list:
            continue
        saved = []
        for img_idx, img in enumerate(image_list, start=1):
            xref = img[0]
            try:
                pix = fitz.Pixmap(doc, xref)
                ext = "png"
                if pix.n >= 4:  # CMYK or with alpha
                    pix = fitz.Pixmap(fitz.csRGB, pix)
                out_name = f"{prefix}_page{page_index+1}_img{img_idx}.{ext}"
                out_path = out_image_dir / out_name
                pix.save(str(out_path))
                pix = None
                saved.append(out_path)
                LOG.debug("Saved image: %s", out_path)
            except Exception as e:
                LOG.warning("Failed to save image on page %d idx %d: %s", page_index + 1, img_idx, e)
        if saved:
            images_by_page[page_index] = saved
    doc.close()
    return images_by_page


def build_markdown_for_pdf(
    pdf_path: Path,
    out_md_path: Path,
    out_image_dir: Path,
    extract_images_flag: bool = False,
):
    """Build markdown for a PDF (text-only approach, no OCR)."""
    LOG.info("Processing PDF: %s", pdf_path)
    ensure_dir(out_md_path.parent)

    pages_text = extract_text_pages(pdf_path)
    images_by_page = {}
    if extract_images_flag:
        images_by_page = extract_images(pdf_path, out_image_dir, prefix=pdf_path.stem)

    md_lines: List[str] = []
    md_lines.append(f"# {pdf_path.stem}\n")
    md_lines.append(f"_Source: {pdf_path.name}_\n")

    for i, page_text in enumerate(pages_text):
        md_lines.append("\n---\n")
        md_lines.append(f"\n## Page {i+1}\n")
        # Prefer HTML->Markdown if it gives something structured
        if page_text.strip():
            md_html_md = html_page_to_markdown(pdf_path, i)
            if md_html_md:
                md_lines.append(md_html_md)
            else:
                md_lines.append(page_text.rstrip())
        else:
            md_lines.append("\n*(No selectable text on this page)*\n")

        # Insert any embedded images if requested
        imgs = images_by_page.get(i, [])
        for img_path in imgs:
            rel = os.path.relpath(img_path, out_md_path.parent)
            md_lines.append(f"\n![image]({rel})\n")

    out_md_path.write_text("\n\n".join(md_lines), encoding="utf-8")
    LOG.info("Wrote Markdown: %s", out_md_path)


def process_path(input_path: Path, out_dir: Path, args):
    if input_path.is_dir():
        for p in sorted(input_path.iterdir()):
            if p.is_file() and p.suffix.lower() == ".pdf":
                out_md = out_dir / (p.stem + ".md")
                out_img_dir = out_dir / (p.stem + "_images")
                if out_md.exists() and not args.overwrite:
                    LOG.info("Skipping existing file (use --overwrite to force): %s", out_md)
                    continue
                build_markdown_for_pdf(p, out_md, out_img_dir, extract_images_flag=args.images)
    elif input_path.is_file():
        if input_path.suffix.lower() != ".pdf":
            LOG.error("Input file is not a PDF: %s", input_path)
            return
        ensure_dir(out_dir)
        out_md = out_dir / (input_path.stem + ".md")
        out_img_dir = out_dir / (input_path.stem + "_images")
        if out_md.exists() and not args.overwrite:
            LOG.info("Skipping existing file (use --overwrite to force): %s", out_md)
            return
        build_markdown_for_pdf(input_path, out_md, out_img_dir, extract_images_flag=args.images)
    else:
        LOG.error("Input path not found: %s", input_path)


def parse_args():
    p = argparse.ArgumentParser(description="Convert text-only PDF -> Markdown (NO OCR).")
    p.add_argument("input", help="PDF file or directory containing PDFs")
    p.add_argument("--out-dir", "-o", default="pdf_md_outputs", help="Output directory for .md and images")
    p.add_argument("--images", action="store_true", help="Extract embedded images (default: false)")
    p.add_argument("--overwrite", action="store_true", help="Overwrite existing .md outputs")
    p.add_argument("--quiet", action="store_true", help="Less logging output")
    return p.parse_args()


def main():
    args = parse_args()
    level = logging.INFO if args.quiet else logging.DEBUG
    logging.basicConfig(format="%(levelname)s: %(message)s", level=level)
    LOG.info("Starting text-only pdf -> md converter (NO OCR)")

    input_path = Path(args.input)
    out_dir = Path(args.out_dir)
    ensure_dir(out_dir)

    try:
        process_path(input_path, out_dir, args)
    except Exception as e:
        LOG.exception("Processing failed: %s", e)
        sys.exit(2)

    LOG.info("Done.")


if __name__ == "__main__":
    main()