#!/usr/bin/env python3

# 2025 11 23 14 31

"""
MyEverything_tkui.py

A modernized Tkinter + ttk UI rewrite of MyEverything: macOS Find GUI.
Keeps full find-command functionality while improving layout, spacing,
command preview, results table with row striping, and a status/error panel.

NOW WITH STREAMING RESULTS - results appear progressively during search!

Original file reference: /mnt/data/MyEverything.py

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
import queue
import argparse

ORIGINAL_FILE = "/mnt/data/MyEverything.py"

def parse_args():
    parser = argparse.ArgumentParser(description='MyEverything macOS Find GUI')
    parser.add_argument('--debug', action='store_true', help='Show stderr debug panel')
    return parser.parse_args()

DEBUG_MODE = parse_args().debug

class MyEverythingApp(ttk.Frame):
    def __init__(self, parent):
        super().__init__(parent)
        self.parent = parent
        self.parent.title("MyEverything: macOS Find GUI – Modern")
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
        self.search_thread = None
        self.output_queue = queue.Queue()
        self.temp_stderr = ""
        self.result_count = 0

    def _create_vars(self):
        self.debug_mode = DEBUG_MODE  # Add this line
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
        #self.stderr_visible = tk.BooleanVar(value=False)

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

        ttk.Button(filters_frame, 
            text='Clear Other Args', 
            command=lambda: other_entry.delete('1.0', 'end')
        ).grid(row=5, column=3, padx=(6,0), pady=(8,0), sticky='nw')
 
        # add a small dropdown of templates
        snippets = [
            '-perm 644',
            '-maxdepth 1',
            r'-exec mv {} {}.bak \;',
            '-delete',
            '! -name "*.tmp"',
            '-name "*.pyc" -o -name "*.log"',
            r'-exec chmod 644 {} \;',
            '-print0 | xargs -0 grep -l "search_string"',
            '-print0 | xargs -0 grep -l "MyWebsiteGIT" > /tmp/results.txt',
            '-not -name "*.pyc" -print0 | xargs -0 grep -l "MyWebsiteGIT"',
            r'-not \( -name "*.pyc" -or -name "*.txt" -or -name "*.md" \) -print0 | xargs -0 grep -l "MyWebsiteGIT"'
            ]
 
        def insert_snippet(event=None):
            sel = snippet_box.get()
            if sel:
                other_entry.insert('end', sel + ' ')
        snippet_box = ttk.Combobox(filters_frame, values=snippets, state='readonly', height=15)
        snippet_box.grid(row=6, column=1, sticky='ew', pady=(6,0))
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
        self.cancel_button = ttk.Button(run_frame, text='■ Cancel', command=self._cancel_search, state='disabled')
        self.cancel_button.pack(side='left', padx=(8,0))
        ttk.Button(run_frame, text='🔍 Preview Find', command=lambda: self._preview_find(other_entry)).pack(side='left', padx=(12,0))
        ttk.Button(run_frame, text='Clear Results', command=self._clear_results).pack(side='left', padx=(12,0))

        # Progress bar
        self.progress_bar = ttk.Progressbar(run_frame, mode='indeterminate', length=150)
        self.progress_bar.pack(side='left', padx=(12,0))

        ttk.Label(run_frame, textvariable=self.status_var).pack(side='right')

        # STDERR / LOG area (collapsible)
        if self.debug_mode:
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
        self.tree.tag_configure('odd', background="#f0f0f0")
        self.tree.tag_configure('even', background="#ffffff")

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

        # size
        sv = self.size_value.get().strip()
        if sv:
            unit = self.size_unit.get()
            op = self.size_op.get()
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
                return [flag, '-' + str(n)]
            elif mode_var.get() == 'since':
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
            parts.append(other)

        cmd = ' '.join(parts)
        return cmd

    def _preview_find(self, other_entry_widget):
        other_text = other_entry_widget.get('1.0', 'end').strip()
        cmd = self._build_find_command(other_text)
        self.command_preview_var.set(cmd)
        self.status_var.set('Preview updated.')

    def _start_search(self, other_entry_widget):
        if self.search_process or self.search_thread:
            messagebox.showinfo('Search running', 'A search is already running. Cancel it before starting a new one.')
            return
        
        other_text = other_entry_widget.get('1.0', 'end').strip()
        cmd = self._build_find_command(other_text)
        self.command_preview_var.set(cmd)
        self.status_var.set('Searching...')
        self.run_button.state(['disabled'])
        self.cancel_button.state(['!disabled'])
        self.progress_bar.start()
        
        if self.debug_mode:
            self.stderr_text.configure(state='normal')
            self.stderr_text.delete('1.0', 'end')
            self.stderr_text.configure(state='disabled')
        self.temp_stderr = ""
        self._clear_results()

        # Start search in thread
        self.search_thread = threading.Thread(
            target=self._execute_search_threaded,
            args=(cmd,),
            daemon=True
        )
        self.search_thread.start()
        
        # Start checking the output queue
        self.parent.after(100, self._process_stream_output)
    #new

    def _execute_search_threaded(self, command):
        """Executes the find command in a worker thread using Popen."""
        
        p = None 
        try:
            p = subprocess.Popen(
                ['/bin/bash', '-c', command],  # <-- Now it's a proper list for bash
                stdout=subprocess.PIPE, 
                stderr=subprocess.PIPE,
                text=True
            )
            
            self.process = p 
            
            # Use communicate() to get all output at once
            stdout, stderr = p.communicate()
            
            # Split output into lines and put in queue
            if stdout:
                for line in stdout.strip().split('\n'):
                    if line.strip():
                        self.output_queue.put(('result', line.strip()))
            
            if stderr:
                self.output_queue.put(('error_output', stderr))
                
            self.output_queue.put(('complete', p.returncode))

        except Exception as e:
            self.output_queue.put(('hard_error', f"Subprocess execution failed: {e}"))
        finally:
            if self.process is p:
                self.process = None


    
    def _process_stream_output(self):
        """Checks the queue for results/errors and updates the GUI."""
        
        # Process all items currently in the queue
        while not self.output_queue.empty():
            try:
                item_type, data = self.output_queue.get_nowait()
            except queue.Empty:
                break
            
            if item_type == 'result':
                self._insert_result(data)
                
            elif item_type == 'error_output':
                self.temp_stderr = data
                if self.debug_mode:
                    self._append_stderr(data)
                
            elif item_type == 'complete':
                self._finalize_search(success=True, return_code=data)
                return

            elif item_type == 'hard_error':
                self._finalize_search(success=False, error=data)
                return
            
        # If thread is still running, check again soon
        if self.search_thread and self.search_thread.is_alive():
            self.parent.after(100, self._process_stream_output)

    def _insert_result(self, path):
        """Insert a single result into the tree as it arrives."""
        if not path:
            return
        
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
        
        # Update status periodically
        if self.result_count % 10 == 0:
            self.status_var.set(f'Searching... {self.result_count} results')

    def _finalize_search(self, success, error=None, return_code=None):
        """Clean up and show final status."""
        self.run_button.state(['!disabled'])
        self.cancel_button.state(['disabled'])
        self.progress_bar.stop()
        self.search_process = None
        self.search_thread = None
        
        count = self.result_count
        
        if error:
            self.status_var.set(f'Search FAILED: {error}')
        elif self.temp_stderr or (return_code is not None and return_code not in [0, -15, 143]):
            # Only show error for real errors, not cancel signals (-15, 143)
            self.status_var.set(f'Completed with {count} results. NOTE: Errors occurred.')
        elif count == 0:
            self.status_var.set('Search complete. NO RESULTS FOUND.')
        else:
            self.status_var.set(f'Search complete. Found {count} results.')
        self.temp_stderr = ""

    def _cancel_search(self):
        """Terminates the running subprocess and cleans up the thread."""
        if self.process and self.process.poll() is None:
            try:
                # Send SIGTERM to the subprocess
                self.process.terminate()
                # Put cancel signal in queue so the UI thread knows to stop
                self.output_queue.put(('cancelled', None))
            except Exception as e:
                self.output_queue.put(('hard_error', str(e)))

    def _append_stderr(self, txt):
        self.stderr_text.configure(state='normal')
        self.stderr_text.insert('end', txt + '\n')
        self.stderr_text.configure(state='disabled')

    def _clear_results(self):
        for row in self.tree.get_children():
            self.tree.delete(row)
        self.result_count = 0

    def _human_readable_size(self, n):
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
            try:
                subprocess.Popen(['open', "-R", full])
            except Exception as e:
                messagebox.showerror('Open Failed', str(e))
        else:
            messagebox.showerror('Not Found', full + ' does not exist')

    def _sort_by(self, col, descending):
        data = [(self.tree.set(child, col), child) for child in self.tree.get_children('')]
        try:
            data.sort(key=lambda t: float(t[0]), reverse=descending)
        except Exception:
            data.sort(reverse=descending)
        for index, (val, child) in enumerate(data):
            self.tree.move(child, '', index)
        self.tree.heading(col, command=lambda c=col: self._sort_by(c, not descending))

def main():
    root = tk.Tk()
    app = MyEverythingApp(root)
    root.mainloop()

if __name__ == '__main__':
    main()
