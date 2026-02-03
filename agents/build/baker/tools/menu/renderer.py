import logging
import markdown2
from datetime import datetime
from weasyprint import HTML

import baker.tools.menu.style as style

log = logging.getLogger(__name__)
pdf = f"daily_menu_{datetime.now().strftime('%Y-%m-%d')}.pdf"
html_preview = f"daily_menu_{datetime.now().strftime('%Y-%m-%d')}.html"


def render_menu(markdown_content: str):
    """
    Render a menu given in Markdown format into a printable PDF file.
    """
    # Convert Markdown to HTML
    clean_markdown_content = markdown_content.replace("\\n", "\n").replace("\\t", "\t")
    html_content = markdown2.markdown(clean_markdown_content)

    # Artisan bakery styling
    styled_html = f"""
    <!DOCTYPE html>
    <html>
    <head>
    <style>{style.css}</style>
    </head>
    <body>
        <div class="header">
            <h1>Daily Menu</h1>
            <div class="tagline">Kernel and Crust Breads & Pastries</div>
        </div>

        {html_content.replace("\\n", "<br />").replace("\\t", "&nbsp;")}

        <div class="footer">
            Made with love • {datetime.now().strftime("%B %d, %Y")}
        </div>
    </body>
    </html>
    """

    # Save HTML preview for the UI
    with open(html_preview, "w") as f:
        f.write(styled_html)

    # Generate PDF in a file
    HTML(string=styled_html).write_pdf(pdf)

    return {"status": "published", "file_name": pdf}


if __name__ == "__main__":
    sample_markdown_content = """# Daily Menu
## Breakfast
- Eggs Benedict
- Pancakes
- French Toast"""
    render_menu(sample_markdown_content)
