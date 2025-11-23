#!/usr/bin/env python3

"""
MyEverything_tkui.py

A modernized Tkinter + ttk UI rewrite of MyEverything: macOS Find GUI.
Keeps full find-command functionality while improving layout, spacing,
command preview, results table with row striping, and a status/error panel.

Original file reference: /mnt/data/MyEverything.py

Notes:
 - Date pickers are simple (Within N days / Exact date as text) to avoid
   external dependencies; macOS native date picker deferred.
 - Advanced features (syntax highlighting, presets, full command builder refactor)
   are deferred for a follow-up iteration.

Author: ChatGPT (generated)
"""

import tkinter as tk
from tkinter import ttk, filedialog, messagebox
import subprocess
import threading
import shlex
import os
import sys
import datetime

ORIGINAL_FILE = "/mnt/data/MyEverything.py"

class MyEverythingApp(ttk.Frame):
    def __init__(self, parent):
        super().__init__(parent)
        self.parent = parent
        self.parent.title("MyEverything: macOS Find GUI — Modern")
        self.parent.geometry("1100x760")
        self.style = ttk.Style()
        # Use a modern-ish theme if available
        try:
            self.style.theme_use('clam')
        except Exception:
            pass

        self._create_vars()
        self._build_ui()
        self.search_process = None
        self.result_count = 0

    def _create_vars(self):
        self.start_path = tk.StringVar(value=os.path.expanduser("~"))
        self.name_pattern = tk.StringVar(value="*")
        self.case_insensitive = tk.BooleanVar(value=True)
        self.file_type = tk.StringVar(value='f')  # f, d, any

        # size filter
        self.size_op = tk.StringVar(value='>')
        self.size_value = tk.StringVar()
        self.size_unit = tk.StringVar(value='M')

        # date filters: options: Any / Within N days / Since Date
        self.modified_mode = tk.StringVar(value='any')
        self.modified_days = tk.IntVar(value=7)
        self.modified_date = tk.StringVar()

        self.accessed_mode = tk.StringVar(value='any')
        self.accessed_days = tk.IntVar(value=7)
        self.accessed_date = tk.StringVar()

        self.changed_mode = tk.StringVar(value='any')
        self.changed_days = tk.IntVar(value=7)
        self.changed_date = tk.StringVar()

        self.other_args = tk.StringVar()
        self.command_preview_var = tk.StringVar()

        self.status_var = tk.StringVar(value='Ready.')
        self.stderr_visible = tk.BooleanVar(value=False)

    def _build_ui(self):
        pad = {'padx': 12, 'pady': 8}

        # PATH & PATTERN FRAME
        path_frame = ttk.LabelFrame(self, text='Path & Name Filters')
        path_frame.pack(fill='x', **pad)

        ttk.Label(path_frame, text='Start Path:').grid(row=0, column=0, sticky='w')
        path_entry = ttk.Entry(path_frame, textvariable=self.start_path)
        path_entry.grid(row=0, column=1, sticky='ew', padx=(6,6))
        ttk.Button(path_frame, text='Browse', command=self._browse).grid(row=0, column=2)

        ttk.Label(path_frame, text='Name Pattern:').grid(row=1, column=0, sticky='w', pady=(6,0))
        name_entry = ttk.Entry(path_frame, textvariable=self.name_pattern)
        name_entry.grid(row=1, column=1, sticky='ew', padx=(6,6), pady=(6,0))
        ttk.Checkbutton(path_frame, text='Case Insensitive (-iname)', variable=self.case_insensitive).grid(row=1, column=2, sticky='w', padx=(6,0))

        path_frame.columnconfigure(1, weight=1)

        # FILTERS FRAME
        filters_frame = ttk.LabelFrame(self, text='Filters (Type, Size, Dates, Other Arguments)')
        filters_frame.pack(fill='x', **pad)

        # File type
        ttk.Label(filters_frame, text='File Type:').grid(row=0, column=0, sticky='w')
        type_frame = ttk.Frame(filters_frame)
        type_frame.grid(row=0, column=1, sticky='w')
        for (text, val) in [('File', 'f'), ('Directory', 'd'), ('Any', 'any')]:
            ttk.Radiobutton(type_frame, text=text, variable=self.file_type, value=val).pack(side='left', padx=6)

        # Size widgets
        size_frame = ttk.Frame(filters_frame)
        size_frame.grid(row=1, column=0, columnspan=3, sticky='ew', pady=(8,0))
        ttk.Label(size_frame, text='Size:').pack(side='left')
        ttk.Combobox(size_frame, width=3, values=['>', '<', '='], textvariable=self.size_op, state='readonly').pack(side='left', padx=6)
        ttk.Entry(size_frame, width=8, textvariable=self.size_value).pack(side='left')
        ttk.Combobox(size_frame, width=5, values=['B','K','M','G'], textvariable=self.size_unit, state='readonly').pack(side='left', padx=6)
        ttk.Label(size_frame, text='(supports suffixes when using Other Arguments)').pack(side='left', padx=(12,0))

        # Date filters grid
        def date_row(label, mode_var, days_var, date_var, row_index):
            ttk.Label(filters_frame, text=label).grid(row=row_index, column=0, sticky='w', pady=(6,0))
            inner = ttk.Frame(filters_frame)
            inner.grid(row=row_index, column=1, sticky='w', pady=(6,0))
            ttk.Radiobutton(inner, text='Any', variable=mode_var, value='any').pack(side='left')
            ttk.Radiobutton(inner, text='Within', variable=mode_var, value='within').pack(side='left')
            ttk.Spinbox(inner, from_=1, to=3650, width=5, textvariable=days_var).pack(side='left', padx=(4,0))
            ttk.Label(inner, text='days').pack(side='left', padx=(4,8))
            ttk.Radiobutton(inner, text='Since', variable=mode_var, value='since').pack(side='left')
            ttk.Entry(inner, width=12, textvariable=date_var).pack(side='left', padx=(4,0))

        date_row('Modified (-mtime):', self.modified_mode, self.modified_days, self.modified_date, 2)
        date_row('Accessed (-atime):', self.accessed_mode, self.accessed_days, self.accessed_date, 3)
        date_row('Changed (-ctime):', self.changed_mode, self.changed_days, self.changed_date, 4)

        # Other args
        ttk.Label(filters_frame, text='Other Arguments (Advanced):').grid(row=5, column=0, sticky='nw', pady=(8,0))
        other_entry = tk.Text(filters_frame, height=3, wrap='none')
        other_entry.grid(row=5, column=1, columnspan=2, sticky='ew', pady=(8,0))
        other_entry.insert('1.0', '')

        # add a small dropdown of templates
        snippets = [
            '-perm 644',
            '-maxdepth 1',
            r'-exec mv {} {}.bak \;',
            '-delete',
            '! -name "*.tmp"',
            '-name "*.pyc" -o -name "*.log"',
            r'-exec chmod 644 {} \;',
            '-print0 | xargs -0 grep -l "search_string"'
        ]
 
        def insert_snippet(event=None):
            sel = snippet_box.get()
            if sel:
                other_entry.insert('end', sel + ' ')
        snippet_box = ttk.Combobox(filters_frame, values=snippets, state='readonly')
        snippet_box.grid(row=6, column=1, sticky='w', pady=(6,0))
        snippet_box.bind('<<ComboboxSelected>>', insert_snippet)

        filters_frame.columnconfigure(1, weight=1)

        # COMMAND PREVIEW
        cmd_frame = ttk.LabelFrame(self, text='Command Preview')
        cmd_frame.pack(fill='x', **pad)
        cmd_preview = ttk.Entry(cmd_frame, textvariable=self.command_preview_var, state='readonly', font=('Menlo', 10))
        cmd_preview.pack(fill='x', padx=8, pady=6)

        # RUN / STATUS
        run_frame = ttk.Frame(self)
        run_frame.pack(fill='x', **pad)
        self.run_button = ttk.Button(run_frame, text='▶ Run Find', command=lambda: self._start_search(other_entry))
        self.run_button.pack(side='left')
        self.cancel_button = ttk.Button(run_frame, text='■ Cancel', command=self._cancel_search)
        self.cancel_button.pack(side='left', padx=(8,0))
        ttk.Button(run_frame, text='🔍 Preview Find', command=lambda: self._preview_find(other_entry)).pack(side='left', padx=(12,0))
        ttk.Button(run_frame, text='Clear Results', command=self._clear_results).pack(side='left', padx=(12,0))

        ttk.Label(run_frame, textvariable=self.status_var).pack(side='right')

        # STDERR / LOG area (collapsible)
        stderr_frame = ttk.LabelFrame(self, text='Command Errors (stderr)')
        stderr_frame.pack(fill='both', expand=False, **pad)
        self.stderr_text = tk.Text(stderr_frame, height=4, wrap='word', background='#fff3f3')
        self.stderr_text.pack(fill='both', expand=True, padx=6, pady=6)
        self.stderr_text.configure(state='disabled')

        # RESULTS
        results_frame = ttk.LabelFrame(self, text='Results (Click headers to sort)')
        results_frame.pack(fill='both', expand=True, **pad)

        columns = ('name', 'folder', 'size', 'modified', 'accessed', 'changed')
        self.tree = ttk.Treeview(results_frame, columns=columns, show='headings')
        for col in columns:
            self.tree.heading(col, text=col.title(), command=lambda c=col: self._sort_by(c, False))
            self.tree.column(col, anchor='w')

        vsb = ttk.Scrollbar(results_frame, orient='vertical', command=self.tree.yview)
        hsb = ttk.Scrollbar(results_frame, orient='horizontal', command=self.tree.xview)
        self.tree.configure(yscroll=vsb.set, xscroll=hsb.set)
        self.tree.pack(fill='both', expand=True, side='left')
        vsb.pack(side='right', fill='y')
        hsb.pack(side='bottom', fill='x')

        self.tree.bind('<Double-1>', self._open_selected)

        # row striping
        self.tree.tag_configure('odd', background="#b8eec3")
        self.tree.tag_configure('even', background="#EA1313")
        # note: these background values assume dark theme; ttk will adapt in many cases

        # pack main frame
        self.pack(fill='both', expand=True)

    # ---------- UI Actions ----------
    def _browse(self):
        path = filedialog.askdirectory(initialdir=self.start_path.get() or os.path.expanduser('~'))
        if path:
            self.start_path.set(path)

    def _build_find_command(self, other_entry_text):
        parts = ['find']
        start = self.start_path.get().strip() or '.'
        parts.append(shlex.quote(start))

        # name pattern
        name = self.name_pattern.get().strip() or '*'
        if self.case_insensitive.get():
            parts.extend(['-iname', shlex.quote(name)])
        else:
            parts.extend(['-name', shlex.quote(name)])

        # type
        if self.file_type.get() == 'f':
            parts.extend(['-type', 'f'])
        elif self.file_type.get() == 'd':
            parts.extend(['-type', 'd'])
        # else 'any' -> nothing

        # size
        sv = self.size_value.get().strip()
        if sv:
            unit = self.size_unit.get()
            op = self.size_op.get()
            # convert to find +/-n[ckmg] heuristic: find uses -size with blocks; but we will use -size with suffixes supported by GNU find or use -size +10M etc.
            # Keep simple: build a -size expression with suffix
            suffix = unit
            # map to find suffix lowercase
            suffix_map = {'B':'c','K':'k','M':'M','G':'G'}
            suffix_flag = suffix_map.get(unit,'M')
            if op == '>':
                parts.append('-size')
                parts.append('+' + sv + suffix_flag)
            elif op == '<':
                parts.append('-size')
                parts.append('-' + sv + suffix_flag)
            else:
                parts.append('-size')
                parts.append(sv + suffix_flag)

        # dates
        def date_part(mode_var, days_var, date_var, flag):
            if mode_var.get() == 'within':
                n = int(days_var.get() or 0)
                # find uses -mtime n (in days). +N = more than N days; -N = less than N days; we want within N days -> -N
                return [flag, '-' + str(n)]
            elif mode_var.get() == 'since':
                # The native find doesn't accept exact dates easily across platforms; we will translate to -newermt 'YYYY-MM-DD' if supported (GNU/BSD have it on macOS as -newermt)
                d = date_var.get().strip()
                if d:
                    return ['-newermt', shlex.quote(d)]
            return []

        parts += date_part(self.modified_mode, self.modified_days, self.modified_date, '-mtime') or []
        parts += date_part(self.accessed_mode, self.accessed_days, self.accessed_date, '-atime') or []
        parts += date_part(self.changed_mode, self.changed_days, self.changed_date, '-ctime') or []

        # other args
        other = other_entry_text.strip()
        if other:
            # naive split; we allow the advanced user to type raw find fragments
            parts.append(other)

        # join safely for shell
        cmd = ' '.join(parts)
        return cmd
    def _preview_find(self, other_entry_widget):
        other_text = other_entry_widget.get('1.0', 'end').strip()
        cmd = self._build_find_command(other_text)
        self.command_preview_var.set(cmd)
        self.status_var.set('Preview updated.')

    def _start_search(self, other_entry_widget):
        if self.search_process:
            messagebox.showinfo('Search running', 'A search is already running. Cancel it before starting a new one.')
            return
        other_text = other_entry_widget.get('1.0', 'end').strip()
        cmd = self._build_find_command(other_text)
        self.command_preview_var.set(cmd)
        self.status_var.set('Running...')
        self.run_button.state(['disabled'])
        self.cancel_button.state(['!disabled'])
        self.stderr_text.configure(state='normal')
        self.stderr_text.delete('1.0', 'end')
        self.stderr_text.configure(state='disabled')
        self._clear_results()

        # run in a thread to avoid blocking UI
        def target():
            try:
                # We will run via /bin/bash -lc to allow advanced fragments in 'other'
                self.search_process = subprocess.Popen(['/bin/bash', '-lc', cmd], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                out, err = self.search_process.communicate()
                self.search_process = None
                if err:
                    self._append_stderr(err)
                if out:
                    lines = out.splitlines()
                    self._populate_results(lines)
                    self.status_var.set(f'Finished — {len(lines)} results')
                else:
                    self.status_var.set('Finished — 0 results')
            except Exception as e:
                self._append_stderr(str(e))
                self.status_var.set('Error')
            finally:
                self.run_button.state(['!disabled'])
                self.cancel_button.state(['disabled'])

        threading.Thread(target=target, daemon=True).start()

    def _cancel_search(self):
        if self.search_process and self.search_process.poll() is None:
            try:
                self.search_process.terminate()
                self.status_var.set('Cancelled')
            except Exception as e:
                self._append_stderr(str(e))
        else:
            self.status_var.set('No running search to cancel')

    def _append_stderr(self, txt):
        self.stderr_text.configure(state='normal')
        self.stderr_text.insert('end', txt + '\n')
        self.stderr_text.configure(state='disabled')

    def _clear_results(self):
        for row in self.tree.get_children():
            self.tree.delete(row)
        self.result_count = 0

    def _populate_results(self, lines):
        # lines are file paths; split into folder + name + file metadata
        for i, path in enumerate(lines):
            path = path.strip()
            if not path:
                continue
            folder, name = os.path.split(path)
            try:
                stat = os.stat(path)
                size = self._human_readable_size(stat.st_size)
                mtime = datetime.datetime.fromtimestamp(stat.st_mtime).strftime('%Y-%m-%d %H:%M:%S')
                atime = datetime.datetime.fromtimestamp(stat.st_atime).strftime('%Y-%m-%d %H:%M:%S')
                ctime = datetime.datetime.fromtimestamp(stat.st_ctime).strftime('%Y-%m-%d %H:%M:%S')
            except Exception:
                size = ''
                mtime = atime = ctime = ''
            tag = 'even' if (self.result_count % 2 == 0) else 'odd'
            self.tree.insert('', 'end', values=(name, folder, size, mtime, atime, ctime), tags=(tag,))
            self.result_count += 1

    def _human_readable_size(self, n):
        # simple human readable
        for unit in ['B','K','M','G','T']:
            if n < 1024.0:
                return "%3.1f%s" % (n, unit)
            n /= 1024.0
        return "%3.1fP" % (n,)

    def _open_selected(self, event=None):
        sel = self.tree.selection()
        if not sel:
            return
        row = sel[0]
        vals = self.tree.item(row, 'values')
        if not vals:
            return
        name, folder = vals[0], vals[1]
        full = os.path.join(folder, name)
        if os.path.exists(full):
            # open with macOS 'open'
            try:
                subprocess.Popen(['open', "-R", full])
            except Exception as e:
                messagebox.showerror('Open Failed', str(e))
        else:
            messagebox.showerror('Not Found', full + ' does not exist')

    def _sort_by(self, col, descending):
        # simple sort for the shown values
        data = [(self.tree.set(child, col), child) for child in self.tree.get_children('')]
        try:
            data.sort(key=lambda t: float(t[0]), reverse=descending)
        except Exception:
            data.sort(reverse=descending)
        for index, (val, child) in enumerate(data):
            self.tree.move(child, '', index)
        # reverse sort next time
        self.tree.heading(col, command=lambda c=col: self._sort_by(c, not descending))

def main():
    root = tk.Tk()
    app = MyEverythingApp(root)
    root.mainloop()

if __name__ == '__main__':
    main()
