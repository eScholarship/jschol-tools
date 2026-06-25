#!/apps/eschol/jschol/tocExtract/venv/bin/python3

import sys
import fitz  # PyMuPDF

def extract_toc(pdf_path):
    doc = fitz.open(pdf_path)
    toc = doc.get_toc()
    doc.close()
    return toc

if __name__ == "__main__":
    pdf_path = sys.argv[1]
    toc = extract_toc(pdf_path)

    for item in toc:
        level, title, page = item
        # Output in mutools compatible format (mutools itself changed to anchors instead of page nums, arrgh)
        lvltabs = '\t' * level
        if page < 1:
            print(f"{lvltabs}\"{title}\"\t(null)")
        else:
            print(f"{lvltabs}\"{title}\"\t#{page}")  # PyMuPDF get_toc() page numbers are 1-based
