css = """
    @import url('https://fonts.googleapis.com/css2?family=Playfair+Display:wght@400;700&family=Lato:wght@300;400&display=swap');

    @page {
        size: A4;
        margin: 0;
    }

    body {
        font-family: 'Lato', sans-serif;
        color: #4a3728;
        background: linear-gradient(135deg, #fdf6e3 0%, #f5e6d3 100%);
        margin: 0;
        padding: 40px 50px;
        min-height: 100vh;
        box-sizing: border-box;
    }

    /* Decorative border */
    body::before {
        content: '';
        position: fixed;
        top: 15px;
        left: 15px;
        right: 15px;
        bottom: 15px;
        border: 2px solid #c9a66b;
        border-radius: 8px;
        pointer-events: none;
    }

    /* Header decorations */
    .header {
        text-align: center;
        padding: 20px 0 30px;
        border-bottom: 1px solid #c9a66b;
        margin-bottom: 30px;
    }

    .header::before {
        content: '🥐 ✦ 🥖';
        display: block;
        font-size: 24px;
        letter-spacing: 15px;
        margin-bottom: 15px;
    }

    h1 {
        font-family: 'Playfair Display', Georgia, serif;
        font-size: 42px;
        font-weight: 700;
        color: #5c3d2e;
        margin: 0 0 8px;
        letter-spacing: 3px;
        text-transform: uppercase;
    }

    .tagline {
        font-family: 'Lato', sans-serif;
        font-size: 12px;
        font-weight: 300;
        color: #8b7355;
        letter-spacing: 4px;
        text-transform: uppercase;
    }

    h2 {
        font-family: 'Playfair Display', Georgia, serif;
        font-size: 22px;
        color: #6b4423;
        text-align: center;
        margin: 35px 0 20px;
        position: relative;
    }

    h2::before, h2::after {
        content: '─── ✦ ───';
        font-size: 10px;
        color: #c9a66b;
        display: block;
    }

    h2::after {
        margin-top: 5px;
    }

    h2::before {
        margin-bottom: 5px;
    }

    /* Menu items table */
    table {
        width: 100%;
        border-collapse: collapse;
        margin: 20px 0;
        background: rgba(255, 255, 255, 0.4);
        border-radius: 8px;
        overflow: hidden;
    }

    th {
        font-family: 'Playfair Display', Georgia, serif;
        font-size: 14px;
        font-weight: 700;
        color: #5c3d2e;
        text-transform: uppercase;
        letter-spacing: 2px;
        padding: 15px 20px;
        background: rgba(201, 166, 107, 0.2);
        border-bottom: 2px solid #c9a66b;
    }

    td {
        padding: 14px 20px;
        border-bottom: 1px dashed #d4c4a8;
        font-size: 14px;
    }

    tr:last-child td {
        border-bottom: none;
    }

    tr:hover {
        background: rgba(201, 166, 107, 0.1);
    }

    /* Item name styling */
    td:first-child {
        font-family: 'Playfair Display', Georgia, serif;
        font-weight: 400;
        color: #5c3d2e;
        font-size: 15px;
    }

    /* Price styling */
    td:last-child {
        font-weight: 400;
        color: #8b5a2b;
        text-align: right;
    }

    /* Footer */
    .footer {
        text-align: center;
        margin-top: 40px;
        padding-top: 25px;
        border-top: 1px solid #c9a66b;
        font-size: 11px;
        color: #8b7355;
        letter-spacing: 1px;
    }

    .footer::before {
        content: '🍞 Baked Fresh Daily 🍞';
        display: block;
        font-size: 13px;
        margin-bottom: 10px;
        color: #6b4423;
    }

    /* Lists styling */
    ul, ol {
        list-style: none;
        padding: 0;
        margin: 20px 0;
    }

    li {
        padding: 12px 25px;
        margin: 8px 0;
        background: rgba(255, 255, 255, 0.5);
        border-left: 3px solid #c9a66b;
        border-radius: 0 8px 8px 0;
        font-size: 14px;
    }

    li::before {
        content: '✦ ';
        color: #c9a66b;
    }

    p {
        line-height: 1.7;
        margin: 15px 0;
    }

    strong {
        color: #5c3d2e;
        font-weight: 700;
    }

    em {
        font-style: italic;
        color: #8b5a2b;
    }
"""
