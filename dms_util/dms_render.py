#!/usr/bin/env python3
"""
dms_render.py - Regenerate index.html from .dms_state.json

This is the clean, single-responsibility script that converts JSON state
into HTML. No string manipulation or regex trickery - just a template.

Usage:
  python3 dms_render.py --doc Doc --index Doc/index.html
"""
import argparse
import json
import html as html_module
from pathlib import Path
from datetime import datetime

def render_index_html(state_path: Path, index_path: Path):
    """Generate index.html from .dms_state.json"""
    
    # Read state
    if not state_path.exists():
        print(f"ERROR: {state_path} not found")
        return 1
    
    state = json.loads(state_path.read_text(encoding='utf-8'))
    
    # Group documents by category
    docs_by_category = {}
    for category in state.get("categories", []):
        docs_by_category[category] = []
    
    for file_path, doc_data in state.get("documents", {}).items():
        category = doc_data.get("category", "Junk")
        if category not in docs_by_category:
            docs_by_category[category] = []
        docs_by_category[category].append((file_path, doc_data))
    
    # Sort documents within each category
    for category in docs_by_category:
        docs_by_category[category].sort(key=lambda x: x[1].get("title", x[0]))
    
    # Generate HTML
    html_content = _generate_html(docs_by_category, state)
    
    # Write index.html
    index_path.write_text(html_content, encoding='utf-8')
    
    print(f"✓ Generated {index_path}")
    print(f"  Categories: {len(docs_by_category)}")
    total_docs = sum(len(docs) for docs in docs_by_category.values())
    print(f"  Documents: {total_docs}")
    
    return 0

def _generate_html(docs_by_category, state):
    """Generate the complete HTML from state"""
    
    # Embed state in HTML for reference (read-only, for debugging)
    state_json = json.dumps(state, indent=2)
    
    categories_html = []
    for category in state.get("categories", []):
        docs = docs_by_category.get(category, [])
        cat_html = _generate_category_section(category, docs)
        categories_html.append(cat_html)
    
    html = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Project Docs Index — Doc/</title>
  <style>
    :root{{
      --bg:#0f1720;
      --panel:#0b1220;
      --muted:#9aa4b2;
      --accent:#79c0ff;
      --accent-2:#7ee787;
      --card:#0f1726;
      --glass: rgba(255,255,255,0.03);
    }}
    html,body{{height:100%;margin:0;font-family:Inter,ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,"Helvetica Neue",Arial;}}
    body{{display:flex;flex-direction:column;background:linear-gradient(180deg,#071422 0%, #071522 60%);color:#e6eef6}}
    header{{padding:18px 20px;border-bottom:1px solid rgba(255,255,255,0.03);display:flex;align-items:center;gap:18px}}
    header h1{{font-size:18px;margin:0}}
    header p{{margin:0;color:var(--muted);font-size:13px}}
    main{{display:flex;flex:1;overflow:hidden}}
    /* left pane */
    #sidebar{{width:420px;max-width:46%;min-width:300px;padding:18px;border-right:1px solid rgba(255,255,255,0.03);overflow:auto;background:linear-gradient(180deg, rgba(255,255,255,0.012), rgba(255,255,255,0.008));}}
    .controls{{display:flex;gap:8px;align-items:center;margin-bottom:14px}}
    .search{{flex:1;display:flex;align-items:center;background:var(--glass);padding:8px;border-radius:8px}}
    .search input{{flex:1;border:0;background:transparent;color:inherit;padding:6px 8px;font-size:14px;outline:none}}
    .search small{{color:var(--muted);font-size:12px;margin-left:6px}}
    .category {{margin-top:10px}}
    .category h2{{margin:6px 0 6px;font-size:13px;color:var(--accent)}}
    ul.files{{list-style:none;padding:0;margin:0}}
    li.file{{padding:10px;border-radius:8px;margin:6px 0;display:flex;gap:10px;align-items:flex-start;background:linear-gradient(180deg, rgba(255,255,255,0.008), rgba(255,255,255,0.006));cursor:pointer}}
    li.file:hover{{box-shadow:0 2px 14px rgba(2,6,23,0.6)}}
    .file .meta{{flex:1}}
    .file .title{{color:#dff3ff;font-weight:600;font-size:14px;margin-bottom:4px}}
    .file .title a{{color:inherit;text-decoration:none}}
    .file .desc{{font-size:13px;color:var(--muted);line-height:1.3}}
    .file .tags{{font-size:12px;color:var(--muted);margin-top:6px}}
    .file .fmt{{font-size:11px;padding:4px 6px;background:rgba(255,255,255,0.02);border-radius:6px;color:var(--muted);margin-left:6px}}

    /* right pane viewer */
    #viewer{{flex:1;display:flex;flex-direction:column;min-width:360px}}
    #viewerHeader{{padding:14px;border-bottom:1px solid rgba(255,255,255,0.03);display:flex;align-items:center;gap:12px}}
    #viewerHeader h3{{margin:0;font-size:15px}}
    #viewerBody{{padding:18px;overflow:auto;background:linear-gradient(180deg, rgba(255,255,255,0.006), rgba(255,255,255,0.004));display:flex;flex-direction:column}}
    /* content area */
    #content{{max-width:1000px;margin:0 auto;flex:1;display:flex;flex-direction:column;width:100%}}
    /* PDF viewer should take full height */
    #pdfViewer{{height:80vh !important;}}

SCRIPTS_DIR = Path.home() / "Documents/MyWebsiteGIT/Scripts"

    /* markdown container */
    #mdViewer{{background:rgba(255,255,255,0.01);padding:18px;border-radius:8px}}
    #mdViewer h1,#mdViewer h2,#mdViewer h3{{color:#e8faff}}
    pre code{{background:#011627;color:#c9dfff;padding:8px;border-radius:6px;display:block;overflow:auto}}
    a.inline-link{{color:var(--accent);text-decoration:none}}
    .small-muted{{color:var(--muted);font-size:13px}}

    /* RAW viewer: preserve CR/LF and indentation for text files */
    #rawViewer{{
      display:none;
      background:rgba(255,255,255,0.02);
      padding:12px;
      border-radius:8px;
      color:var(--muted);
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, "Roboto Mono", monospace;
      white-space: pre-wrap;
      word-break: break-word;
      line-height:1.45;
      font-size:13px;
    }}

    /* responsive */
    @media(max-width:980px){{
      #sidebar{{display:block;position:relative;width:100%;max-height:360px;overflow:auto}}
      #viewer{{min-height:calc(100vh - 360px)}}
    }}
  </style>
  <!-- marked.js for markdown rendering -->
  <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
</head>
<body>
<!-- DMS_STATE_JSON (read-only, embedded for reference)
{state_json}
-->
  <header>
    <h1>📚 Project Docs</h1>
    <p>Organized by category • Searchable • Responsive</p>
  </header>

  <main>
    <section id="sidebar">
      <div class="controls">
        <div class="search">
          <input type="text" id="searchInput" placeholder="Search..." />
          <small id="resultCount">0 shown</small>
        </div>
      </div>

      {"".join(categories_html)}
    </section>

    <section id="viewer">
      <div id="viewerHeader">
        <h3 id="viewerTitle">Select a document to view</h3>
      </div>
      <div id="viewerBody">
        <div id="content">
          <div id="mdViewer"></div>
          <div id="rawViewer"></div>
          <iframe id="pdfViewer" style="width:100%;height:100%;border:none;display:none;"></iframe>
        </div>
      </div>
    </section>
  </main>

  <script>
    const searchInput = document.getElementById('searchInput');
    const resultCount = document.getElementById('resultCount');
    const viewerTitle = document.getElementById('viewerTitle');
    const mdViewer = document.getElementById('mdViewer');
    const rawViewer = document.getElementById('rawViewer');
    const pdfViewer = document.getElementById('pdfViewer');

    function extOf(path) {{
      const ext = path.split('.').pop()?.toLowerCase() || '';
      return ext.length <= 5 ? ext : '';
    }}

    function safeFetchText(path) {{
      return fetch(path).then(r => r.text());
    }}

    function openFilePreview(liElement) {{
      let path, title;
      
      // Handle both element and string path inputs
      if(typeof liElement === 'string') {{
        path = liElement;
        title = path.split('/').pop().split('.')[0];
      }} else {{
        path = liElement.dataset.path;
        title = liElement.querySelector('.title')?.innerText || 'Document';
      }}
      
      const pdf = (liElement.dataset?.pdf || '');
      
      viewerTitle.innerText = title;
      mdViewer.style.display = 'none';
      pdfViewer.style.display = 'none';
      rawViewer.style.display = 'none';
      
      const e = extOf(path);
      if(e === 'md' || path.endsWith('.md') || path.includes('md_outputs')){{
        safeFetchText(path).then(txt=>{{
          mdViewer.innerHTML = marked.parse(txt);
          mdViewer.style.display = 'block';
          if(pdf){{
            const orig = document.createElement('div');
            orig.className = 'small-muted';
            orig.innerHTML = `Source PDF: <a class="inline-link" href="${{pdf}}" target="_blank" rel="noopener">${{pdf}}</a>`;
            if(mdViewer.firstChild) mdViewer.insertBefore(orig, mdViewer.firstChild);
            else mdViewer.appendChild(orig);
          }}
        }}).catch(err=>{{
          rawViewer.style.display = 'block';
          rawViewer.textContent = 'Failed to load markdown: ' + err;
        }});
        return;
      }}
      
      if(e === 'pdf' || pdf.toLowerCase().endsWith('.pdf')){{
        const pdfPath = (e === 'pdf') ? path : pdf;
        pdfViewer.src = pdfPath;
        pdfViewer.style.display = 'block';
        return;
      }}
      
      if(e === 'docx' || e === 'doc'){{
        rawViewer.style.display = 'block';
        rawViewer.innerHTML = `This is a binary Office file. <a class="inline-link" href="${{path}}" target="_blank" rel="noopener">Open ${{path}}</a>`;
        return;
      }}
      
      // Handle images
      if(['png','jpg','jpeg','gif','webp','bmp','svg'].includes(e)){{
        rawViewer.style.display = 'block';
        rawViewer.innerHTML = `<img src="${{path}}" style="max-width:100%;max-height:600px;border-radius:8px;" alt="${{title}}">`;
        return;
      }}
      
      if(['txt','log','out'].includes(e) || e.length<=4){{
        safeFetchText(path).then(txt=>{{
          rawViewer.style.display = 'block';
          rawViewer.textContent = txt;
        }}).catch(err=>{{
          rawViewer.style.display = 'block';
          rawViewer.textContent = 'Failed to load file: ' + err;
        }});
        return;
      }}
      
      rawViewer.style.display = 'block';
      rawViewer.innerHTML = `Open file: <a class="inline-link" href="${{path}}" target="_blank" rel="noopener">${{path}}</a>`;
    }}

    function filterFiles(q){{
      q = (q||'').toLowerCase().trim();
      const files = document.querySelectorAll('li.file');
      let visible = 0;
      files.forEach(li=>{{
        const title = li.querySelector('.title').innerText.toLowerCase();
        const desc = li.querySelector('.desc').innerText.toLowerCase();
        const tags = li.querySelector('.tags').innerText.toLowerCase();
        if(!q || title.includes(q) || desc.includes(q) || tags.includes(q)){{
          li.style.display = '';
          visible++;
        }} else {{
          li.style.display = 'none';
        }}
      }});
      resultCount.textContent = visible ? `${{visible}} shown` : 'no results';
    }}

    searchInput.addEventListener('input', (e)=>{{
      filterFiles(e.target.value);
    }});

    window.addEventListener('load', ()=>{{
      const hash = decodeURIComponent(location.hash.replace(/^#/,''));
      if(hash){{
        const el = Array.from(document.querySelectorAll('li.file')).find(li=>{{
          return li.dataset.path===hash || li.dataset.pdf===hash || li.querySelector('.title').innerText===hash;
        }});
        if(el) openFilePreview(el);
        else if(hash) openFilePreview(hash);  // If no li found, try opening the path directly
      }}
      filterFiles('');
    }});

    // Handle hash changes (when clicking image/file links)
    window.addEventListener('hashchange', ()=>{{
      const hash = decodeURIComponent(location.hash.replace(/^#/,''));
      if(hash){{
        const el = Array.from(document.querySelectorAll('li.file')).find(li=>{{
          return li.dataset.path===hash || li.dataset.pdf===hash || li.querySelector('.title').innerText===hash;
        }});
        if(el) openFilePreview(el);
        else if(hash) openFilePreview(hash);  // If no li found, try opening the path directly
      }}
    }});

    window.addEventListener('keydown', (e)=>{{
      if(e.key==='/' && document.activeElement !== searchInput){{
        e.preventDefault();
        searchInput.focus();
        searchInput.select();
      }}
    }});

    // Attach click handler to all file entries
    document.addEventListener('click', (e)=>{{
      const li = e.target.closest('li.file');
      if(li) openFilePreview(li);
    }});
  </script>
</body>
</html>"""
    
    return html

def _generate_category_section(category, docs):
    """Generate a category section with document list"""
    
    if not docs:
        return ""
    
    li_items = []
    for file_path, doc_data in docs:
        file_ext = Path(file_path).suffix.lstrip('.').upper() or 'N/A'
        title = html_module.escape(doc_data.get("title", Path(file_path).stem))
        summary = html_module.escape(doc_data.get("summary", ""))
        path_escaped = html_module.escape(file_path)
        
        # Check if this has an original file link (image paired with text)
        original_link = ""
        if doc_data.get("readable_version"):
            readable_path = html_module.escape(doc_data["readable_version"])
            original_file = Path(readable_path).stem
            # Determine icon and label based on file type
            if readable_path.lower().endswith(('.png', '.jpg', '.jpeg', '.gif', '.webp')):
                icon = "🖼️"
                label = "View Image"
            else:
                icon = "📄"
                label = "View Text/OCR"
            original_link = f'<br><small><a href="#{readable_path}" style="color:var(--accent-2)">{icon} {label}</a></small>'
        
        li = f"""            <li class="file" data-path="{path_escaped}" data-link="{path_escaped}">
      <div class="meta">
        <div class="title"><a href="#{path_escaped}" class="file-link">{title}</a></div>
        <div class="desc">{summary}{original_link}</div>
        <div class="tags small-muted">{file_ext} · {html_module.escape(category)}</div>
      </div>
            </li>"""
        li_items.append(li)
    
    category_escaped = html_module.escape(category)
    return f"""      <section class="category" data-category="{category_escaped}">
        <h2>{category_escaped}</h2>
        <ul class="files">
{"".join(li_items)}
        </ul>
      </section>

"""

def main():
    parser = argparse.ArgumentParser(description="Render index.html from .dms_state.json")
    parser.add_argument("--doc", default="Doc", help="Doc directory")
    parser.add_argument("--index", default="Doc/index.html", help="Path to output index.html")
    args = parser.parse_args()
    
    doc_dir = Path(args.doc)
    index_path = Path(args.index)
    state_path = doc_dir / ".dms_state.json"
    
    if not doc_dir.exists():
        print(f"ERROR: {doc_dir} not found")
        return 1
    
    return render_index_html(state_path, index_path)

if __name__ == "__main__":
    exit(main())
