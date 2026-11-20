# Renders docs/<name>.pdf from docs/<name>.html (A4, nav hidden, footer with title and page).
# Needs Chromium via Playwright, e.g. the Playwright image of the e2e check:
#   podman run --rm -v "$PWD/docs":/docs:Z -v "$PWD/scripts":/r:Z <playwright-image> \
#       python /r/render-docs-pdf.py blog-betrieb blog-operations blog-exploitation
import sys
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page()
    for name in sys.argv[1:]:
        pg.goto(f"file:///docs/{name}.html")
        pg.add_style_tag(content="nav{display:none!important}")
        pg.pdf(path=f"/docs/{name}.pdf", format="A4", print_background=True,
               scale=0.85, display_header_footer=True, header_template="<span></span>",
               footer_template='<div style="font-size:7px;width:100%;text-align:center;color:#888"><span class="title"></span> \u00b7 <span class="pageNumber"></span>/<span class="totalPages"></span></div>',
               margin={"top": "14mm", "bottom": "16mm", "left": "12mm", "right": "12mm"})
        print("ok", name)
    b.close()
