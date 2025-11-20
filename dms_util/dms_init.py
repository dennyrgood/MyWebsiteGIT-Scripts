#!/usr/bin/env python3
"""
dms_init.py - Initialize a new Doc/ directory with index.html

Creates:
  - Doc/index.html (with DMS_STATE embedded)
  - Doc/md_outputs/ directory
  - Basic category structure
"""
from __future__ import annotations
import argparse
import sys
import json
from pathlib import Path
from datetime import datetime

INDEX_HTML_TEMPLATE = '''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Project Docs Index — Doc/</title>
  <style>
    :root{
      --bg:#0f1720;
      --panel:#0b1220;
      --muted:#9aa4b2;
      --accent:#79c0ff;
      --accent-2:#7ee787;
      --card:#0f1726;
      --glass: rgba(255,255,255,0.03);
    }
    html,body{height:100%;margin:0;font-family:Inter,ui-sans-serif,system-ui,-apple-system,Segoe UI,Roboto,"Helvetica Neue",Arial;}
    body{display:flex;flex-direction:column;background:linear-gradient(180deg,#071422 0%, #071522 60%);color:#e6eef6}
    header{padding:18px 20px;border-bottom:1px solid rgba(255,255,255,0.03);display:flex;align-items:center;gap:18px}
    header h1{font-size:18px;margin:0}
    header p{margin:0;color:var(--muted);font-size:13px}
    main{display:flex;flex:1;overflow:hidden}
    #sidebar{width:420px;max-width:46%;min-width:300px;padding:18px;border-right:1px solid rgba(255,255,255,0.03);overflow:auto;background:linear-gradient(180deg, rgba(255,255,255,0.012), rgba(255,255,255,0.008));}
    .controls{display:flex;gap:8px;align-items:center;margin-bottom:14px}
    .search{flex:1;display:flex;align-items:center;background:var(--glass);padding:8px;border-radius:8px}
    .search input{flex:1;border:0;background:transparent;color:inherit;padding:6px 8px;font-size:14px;outline:none}
    .search small{color:var(--muted);font-size:12px;margin-left:6px}
    .category {margin-top:10px}
    .category h2{margin:6px 0 6px;font-size:13px;color:var(--accent)}
    ul.files{list-style:none;padding:0;margin:0}
    li.file{padding:10px;border-radius:8px;margin:6px 0;display:flex;gap:10px;align-items:flex-start;background:linear-gradient(180deg, rgba(255,255,255,0.008), rgba(255,255,255,0.006));cursor:pointer}
    li.file:hover{box-shadow:0 2px 14px rgba(2,6,23,0.6)}
    .file .meta{flex:1}
    .file .title{color:#dff3ff;font-weight:600;font-size:14px;margin-bottom:4px}
    .file .title a{color:inherit;text-decoration:none}
    .file .desc{font-size:13px;color:var(--muted);line-height:1.3}
    .file .tags{font-size:12px;color:var(--muted);margin-top:6px}
    #viewer{flex:1;display:flex;flex-direction:column;min-width:360px}
    #viewerHeader{padding:14px;border-bottom:1px solid rgba(255,255,255,0.03);display:flex;align-items:center;gap:12px}
    #viewerHeader h3{margin:0;font-size:15px}
    #viewerBody{padding:18px;overflow:auto;background:linear-gradient(180deg, rgba(255,255,255,0.006), rgba(255,255,255,0.004))}
    #content{max-width:1000px;margin:0 auto}
    #mdViewer{background:rgba(255,255,255,0.01);padding:18px;border-radius:8px}
    #mdViewer h1,#mdViewer h2,#mdViewer h3{color:#e8faff}
    pre code{background:#011627;color:#c9dfff;padding:8px;border-radius:6px;display:block;overflow:auto}
    a.inline-link{color:var(--accent);text-decoration:none}
    .small-muted{color:var(--muted);font-size:13px}
    #rawViewer{
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
    }
    @media(max-width:980px){
      #sidebar{display:block;position:relative;width:100%;max-height:360px;overflow:auto}
      #viewer{min-height:calc(100vh - 360px)}
    }
  </style>
  <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
</head>
<body>
{DMS_STATE}
  <header>
    <div style="display:flex;flex-direction:column">
      <h1>Project Docs Index</h1>
      <p>Browse Doc/ and Doc/md_outputs/ — click a file name to view it. Markdown is rendered client-side. PDFs open in an embedded viewer.</p>
    </div>
  </header>

  <main>
    <aside id="sidebar" aria-label="Docs list">
      <div class="controls">
        <div class="search">
          <svg width="16" height="16" viewBox="0 0 24 24" style="opacity:.7;margin-right:6px"><path fill="currentColor" d="M15.5 14h-.79l-.28-.27A6.471 6.471 0 0016 9.5 6.5 6.5 0 109.5 16c1.61 0 3.09-.59 4.23-1.57l.27.28v.79l4.25 4.25 1.5-1.5L15.5 14z"></path></svg>
          <input id="searchInput" placeholder="Search files, descriptions, tags..." />
          <small id="resultCount"></small>
        </div>
        <div style="min-width:86px;text-align:right" class="small-muted">Click a file to preview</div>
      </div>

      <div id="lists">
        {CATEGORIES}
      </div>
    </aside>

    <section id="viewer" aria-label="Document viewer">
      <div id="viewerHeader">
        <h3 id="viewerTitle">Select a file to preview</h3>
        <div class="small-muted" id="viewerInfo">Files render client-side. Markdown will be converted to HTML. PDFs embedded if supported by browser.</div>
      </div>
      <div id="viewerBody">
        <div id="content">
          <div id="mdViewer" style="display:none"></div>
          <iframe id="pdfViewer" style="display:none;width:100%;height:75vh;border:0;border-radius:8px" sandbox="allow-same-origin allow-scripts allow-forms"></iframe>
          <div id="rawViewer" style="display:none"></div>
        </div>
      </div>
    </section>
  </main>

  <script>
    function safeFetchText(path){
      return fetch(path).then(r=>{
        if(!r.ok) throw new Error('Fetch failed '+r.status);
        return r.text();
      });
    }

    const mdViewer = document.getElementById('mdViewer');
    const pdfViewer = document.getElementById('pdfViewer');
    const rawViewer = document.getElementById('rawViewer');
    const viewerTitle = document.getElementById('viewerTitle');
    const searchInput = document.getElementById('searchInput');
    const resultCount = document.getElementById('resultCount');

    document.querySelectorAll('.file-link').forEach(link=>{
      link.addEventListener('click', (ev)=>{
        ev.preventDefault();
        const li = ev.target.closest('.file');
        openFilePreview(li);
      });
    });

    function extOf(path){
      return path.split('.').pop().toLowerCase();
    }

    function openFilePreview(li){
      const path = li.dataset.path;
      const pdf = li.dataset.pdf || '';
      viewerTitle.textContent = li.querySelector('.title').innerText;
      mdViewer.style.display = 'none';
      pdfViewer.style.display = 'none';
      rawViewer.style.display = 'none';
      
      const e = extOf(path);
      if(e === 'md' || path.endsWith('.md') || path.includes('md_outputs')){
        safeFetchText(path).then(txt=>{
          mdViewer.innerHTML = marked.parse(txt);
          mdViewer.style.display = 'block';
          if(pdf){
            const orig = document.createElement('div');
            orig.className = 'small-muted';
            orig.innerHTML = `Source PDF: <a class="inline-link" href="${pdf}" target="_blank" rel="noopener">${pdf}</a>`;
            if(mdViewer.firstChild) mdViewer.insertBefore(orig, mdViewer.firstChild);
            else mdViewer.appendChild(orig);
          }
        }).catch(err=>{
          rawViewer.style.display = 'block';
          rawViewer.textContent = 'Failed to load markdown: ' + err;
        });
        return;
      }
      
      if(e === 'pdf' || pdf.toLowerCase().endsWith('.pdf')){
        const pdfPath = (e === 'pdf') ? path : pdf;
        pdfViewer.src = pdfPath;
        pdfViewer.style.display = 'block';
        return;
      }
      
      if(['txt','log','out'].includes(e) || e.length<=4){
        safeFetchText(path).then(txt=>{
          rawViewer.style.display = 'block';
          rawViewer.textContent = txt;
        }).catch(err=>{
          rawViewer.style.display = 'block';
          rawViewer.textContent = 'Failed to load file: ' + err;
        });
        return;
      }
      
      rawViewer.style.display = 'block';
      rawViewer.innerHTML = `Open file: <a class="inline-link" href="${path}" target="_blank" rel="noopener">${path}</a>`;
    }

    function filterFiles(q){
      q = (q||'').toLowerCase().trim();
      const files = document.querySelectorAll('li.file');
      let visible = 0;
      files.forEach(li=>{
        const title = li.querySelector('.title').innerText.toLowerCase();
        const desc = li.querySelector('.desc').innerText.toLowerCase();
        const tags = li.querySelector('.tags').innerText.toLowerCase();
        if(!q || title.includes(q) || desc.includes(q) || tags.includes(q)){
          li.style.display = '';
          visible++;
        } else {
          li.style.display = 'none';
        }
      });
      resultCount.textContent = visible ? `${visible} shown` : 'no results';
    }

    searchInput.addEventListener('input', (e)=>{ filterFiles(e.target.value); });
    
    window.addEventListener('load', ()=>{ filterFiles(''); });
    
    window.addEventListener('keydown', (e)=>{
      if(e.key==='/' && document.activeElement !== searchInput){
        e.preventDefault();
        searchInput.focus();
        searchInput.select();
      }
    });
  </script>
</body>
</html>
'''

def create_initial_categories() -> str:
    """Create default category sections"""
    default_categories = [
        ("Guides", "Guides & Documentation"),
        ("QuickRefs", "Quick References"),
        ("Scripts", "Scripts & Tools"),
        ("Uncategorized", "Uncategorized")
    ]
    
    sections = []
    for cat_id, display_name in default_categories:
        section = f'''
        <section class="category" data-category="{cat_id}">
          <h2>{display_name}</h2>
          <ul class="files">
          </ul>
        </section>
'''
        sections.append(section)
    
    return '\n'.join(sections)

def main():
    parser = argparse.ArgumentParser(description="Initialize new Doc/ directory with index.html")
    parser.add_argument("--doc", default="Doc", help="Doc directory to create")
    parser.add_argument("--index", default="Doc/index.html", help="Path for index.html")
    parser.add_argument("--force", action="store_true", help="Overwrite existing index.html")
    args = parser.parse_args()
    
    doc_dir = Path(args.doc)
    index_path = Path(args.index)
    
    # Create Doc/ and md_outputs/
    doc_dir.mkdir(parents=True, exist_ok=True)
    (doc_dir / "md_outputs").mkdir(exist_ok=True)
    
    print(f"Created directories:")
    print(f"  - {doc_dir}/")
    print(f"  - {doc_dir}/md_outputs/")
    
    # Check if index exists
    if index_path.exists() and not args.force:
        print(f"\nERROR: {index_path} already exists.", file=sys.stderr)
        print("Use --force to overwrite.", file=sys.stderr)
        return 1
    
    # Create initial DMS_STATE
    initial_state = {
        "processed_files": {},
        "categories": ["Guides", "QuickRefs", "Scripts", "Uncategorized"],
        "last_scan": datetime.now().isoformat(),
        "initialized": datetime.now().isoformat()
    }
    
    state_json = json.dumps(initial_state, indent=2)
    state_block = f"<!-- DMS_STATE\n{state_json}\n-->\n"
    
    # Build categories HTML
    categories_html = create_initial_categories()
    
    # Fill template
    html_content = INDEX_HTML_TEMPLATE.replace('{DMS_STATE}', state_block)
    html_content = html_content.replace('{CATEGORIES}', categories_html)
    
    # Write
    index_path.write_text(html_content, encoding='utf-8')
    
    print(f"\n✓ Created {index_path}")
    print("\nInitialization complete!")
    print("\nNext steps:")
    print("  1. Add files to Doc/")
    print("  2. Run 'dms scan' to detect new files")
    print("  3. Run 'dms auto' to process and add them to the index")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
