#!/usr/bin/env python3

import tkinter as tk
from tkinter import filedialog, ttk
import subprocess
import shlex
import os
import datetime 
import sys 
import threading # NEW: For running search in background
import queue # NEW: For thread-safe communication

class MyEverythingApp:
    
    # --- 1. CONFIGURATION CONSTANTS (Leaner, Easier to Modify) ---
    
    # Defines Treeview column properties: (header_text, width, internal_data_key)
    COLUMN_SETUP = {
        "#0": {"text": "File Name", "width": 200, "data_key": "Name"},
        "Folder": {"text": "Folder", "width": 250, "data_key": "Folder"},
        "Size": {"text": "Size", "width": 80, "data_key": "Size_Bytes"},
        "Modified": {"text": "Modified Date", "width": 120, "data_key": "Modified_Timestamp"},
        "Accessed": {"text": "Accessed Date", "width": 120, "data_key": "Accessed_Timestamp"},
        "Changed": {"text": "Changed Date", "width": 120, "data_key": "Changed_Timestamp"},
    }
    
    # Maps GUI variables to their corresponding 'find' command flags.
    FIND_FILTERS = [
        ("file_type", "-type"),
        ("size_val", "-size"),
        ("mtime_val", "-mtime"),
        ("atime_val", "-atime"),
        ("ctime_val", "-ctime"),
    ]
    
    # Visual constants
    ERROR_BG_COLOR = '#FFEDED'  # Pale red/pink background for error box
    ERROR_FG_COLOR = 'black'    # Explicit black foreground for text contrast
    
    def __init__(self, master):
        self.master = master
        master.title("MyEverything: macOS Find GUI")
        # Set geometry for better visibility of results and error box
        master.geometry("1000x950")

        # --- Variables (Filter Inputs) ---
        self.search_name = tk.StringVar(value="*")
        self.start_path = tk.StringVar(value=os.path.expanduser("~"))
        self.case_insensitive = tk.BooleanVar(value=True) 
        self.file_type = tk.StringVar(value="f") 
        self.size_val = tk.StringVar(value="")
        self.mtime_val = tk.StringVar(value="")
        self.atime_val = tk.StringVar(value="")
        self.ctime_val = tk.StringVar(value="")
        self.other_args = tk.StringVar(value="") 
        
        # --- Threading/Process Variables (NEW) ---
        self.search_thread = None
        self.process = None # Holds the subprocess.Popen instance
        self.output_queue = queue.Queue() # Thread-safe queue for result communication
        self.temp_stderr = "" # Temporary holder for stderr output
        
        # Internal dictionary to store file metadata (raw size/timestamps) for accurate sorting
        self.file_data = {}
        
        # Flag to indicate if shell=True is needed (due to pipe in other_args)
        self.use_shell = False 

        # --- Build GUI ---
        self._create_widgets()

    def _create_widgets(self):
        """Builds all GUI components, consolidating filters and styling the status bar."""
        
        # --- Configure Style for Taller Status Bar ---
        style = ttk.Style()
        style.configure('Taller.TLabel', padding=(5, 10, 5, 10)) 

        # 1. Input Frame (Search Path and Pattern)
        input_frame = ttk.LabelFrame(self.master, text="🔍 Path and Name Filters")
        input_frame.pack(padx=10, pady=5, fill="x")

        # Start Path
        ttk.Label(input_frame, text="Start Path:").grid(row=0, column=0, padx=5, pady=5, sticky="w")
        path_entry = ttk.Entry(input_frame, textvariable=self.start_path)
        path_entry.grid(row=0, column=1, padx=5, pady=5, sticky="ew")
        ttk.Button(input_frame, text="Browse", command=self._select_path).grid(row=0, column=2, padx=5, pady=5)
        
        # Search Pattern (-name / -iname)
        ttk.Label(input_frame, text="Name Pattern:").grid(row=1, column=0, padx=5, pady=5, sticky="w")
        ttk.Entry(input_frame, textvariable=self.search_name).grid(row=1, column=1, padx=5, pady=5, sticky="ew")
        ttk.Checkbutton(input_frame, text="Case Insensitive (-iname)", variable=self.case_insensitive).grid(row=1, column=2, padx=5, pady=5)

        input_frame.grid_columnconfigure(1, weight=1)

        # 2. Consolidated Filters Frame
        filters_frame = ttk.LabelFrame(self.master, text="⚙️ Filters (Type, Size, Time, Permissions, Actions)")
        filters_frame.pack(padx=10, pady=5, fill="x")
        
        # Row 0: File Type (-type)
        ttk.Label(filters_frame, text="File Type:").grid(row=0, column=0, padx=5, pady=5, sticky="w")
        ttk.Radiobutton(filters_frame, text="File (f)", variable=self.file_type, value="f").grid(row=0, column=1, padx=5, pady=5)
        ttk.Radiobutton(filters_frame, text="Directory (d)", variable=self.file_type, value="d").grid(row=0, column=2, padx=5, pady=5)
        ttk.Radiobutton(filters_frame, text="Any Type", variable=self.file_type, value="").grid(row=0, column=3, padx=5, pady=5)
        
        # Row 1: Size Filter (-size)
        size_desc_text = "Size (-size):"
        ttk.Label(filters_frame, text=size_desc_text).grid(row=1, column=0, padx=5, pady=5, sticky="w")
        
        # Reduced width of size input box
        ttk.Entry(filters_frame, textvariable=self.size_val, width=8).grid(row=1, column=1, padx=5, pady=5, sticky="w") 
        
        # Added description text back next to the size input
        size_desc_info = "+/-N[cKMG] (e.g., +10M = >10MB, -500k = <500KB)"
        ttk.Label(filters_frame, text=size_desc_info).grid(row=1, column=2, columnspan=5, padx=5, pady=5, sticky="w") 

        # Row 3: Time Filters (-mtime, -atime, -ctime) 
        ttk.Label(filters_frame, text="Modified (-mtime):").grid(row=3, column=0, padx=5, pady=(10, 5), sticky="w")
        ttk.Entry(filters_frame, textvariable=self.mtime_val, width=5).grid(row=3, column=1, padx=5, sticky="w")

        ttk.Label(filters_frame, text="Accessed (-atime):").grid(row=3, column=2, padx=(20, 5), pady=(10, 5), sticky="w")
        ttk.Entry(filters_frame, textvariable=self.atime_val, width=5).grid(row=3, column=3, padx=5, sticky="w")
        
        ttk.Label(filters_frame, text="Changed (-ctime):").grid(row=3, column=4, padx=(20, 5), pady=(10, 5), sticky="w")
        ttk.Entry(filters_frame, textvariable=self.ctime_val, width=5).grid(row=3, column=5, padx=5, sticky="w") 
        
        # Added "Days" after the last time input box (Changed)
        ttk.Label(filters_frame, text="Days").grid(row=3, column=6, padx=(5, 5), pady=(10, 5), sticky="w")

        # Row 4/5/6: Other Arguments - MODIFIED WITH HELP BUTTON
        # Add "Other Arguments (Advanced)" entry field
        ttk.Label(filters_frame, text="Other Arguments (Advanced):").grid(
            row=4, column=0, columnspan=7, padx=5, pady=(10, 0), sticky="w")

        # Create the "Other Arguments" entry widget
        other_entry = ttk.Entry(filters_frame, textvariable=self.other_args)
        other_entry.grid(row=5, column=0, columnspan=6, padx=5, pady=(0, 5), sticky="ew")

        # Add the "?" help button next to the entry box
        ttk.Button(filters_frame, text="?", command=self._open_help_popup, width=2).grid(
            row=5, column=6, padx=5, pady=(0, 5), sticky="e")

        # Add examples text below the "Other Arguments" entry or keep as is
        examples = r'e.g., -perm 644 | ! -name ".*" | -exec "mv {} {}.bak" \;'
        ttk.Label(filters_frame, text=examples, font=('Courier', 10)).grid(
            row=6, column=0, columnspan=7, padx=5, pady=(0, 5), sticky="w")
        
        filters_frame.grid_columnconfigure(6, weight=1) 

        # 3. Execution Controls (NEW: Progress bar and Cancel button)
        exec_frame = ttk.Frame(self.master)
        exec_frame.pack(pady=5, padx=10, fill="x")

        self.run_button = ttk.Button(exec_frame, text="▶️ Run Find Command", command=self._start_search)
        self.run_button.pack(side="left", fill="x", expand=True)

        # Progress Bar (Indeterminate style for background processing)
        self.progress_bar = ttk.Progressbar(exec_frame, mode='indeterminate')
        self.progress_bar.pack(side="left", padx=(10, 5), fill="x", expand=True)
        
        self.cancel_button = ttk.Button(exec_frame, text="⏹️ Cancel", command=self._cancel_search, state=tk.DISABLED)
        self.cancel_button.pack(side="left", padx=(5, 0))

        # --- COMMAND & ERROR DISPLAY SECTION ---
        command_frame = ttk.LabelFrame(self.master, text="Command Status")
        command_frame.pack(padx=10, pady=5, fill="x")
        
        self.command_status_label = ttk.Label(command_frame, text="Ready.")
        self.command_status_label.pack(padx=5, pady=2, anchor="w")

        self.command_output = ttk.Entry(command_frame, state='readonly', font=('Courier', 10))
        self.command_output.pack(padx=5, pady=(0, 5), fill="x")

        self.error_status_label = ttk.Label(command_frame, text="Command Errors (stderr):", foreground='red')
        self.error_status_label.pack(padx=5, pady=(5, 0), anchor="w")
        
        error_text_frame = ttk.Frame(command_frame)
        error_text_frame.pack(padx=5, pady=(0, 5), fill="x")
        
        self.error_output = tk.Text(error_text_frame, height=4, state='disabled', wrap='word', 
                                    font=('Courier', 10), background=self.ERROR_BG_COLOR, 
                                    foreground=self.ERROR_FG_COLOR)
        
        error_scrollbar = ttk.Scrollbar(error_text_frame, command=self.error_output.yview)
        error_scrollbar.pack(side="right", fill="y")
        self.error_output.config(yscrollcommand=error_scrollbar.set)
        
        self.error_output.pack(side="left", fill="x", expand=True)

        # 4. Results Area
        ttk.Label(self.master, text="Results (Click headers to sort):").pack(padx=10, pady=2, anchor="w")
        
        results_frame = ttk.Frame(self.master)
        results_frame.pack(padx=10, pady=5, fill="both", expand=True)

        column_ids = list(self.COLUMN_SETUP.keys())[1:]
        self.results_tree = ttk.Treeview(results_frame, columns=column_ids, show="tree headings") 
        
        for col_id, config in self.COLUMN_SETUP.items():
            sort_command = lambda c=col_id: self._sort_column(self.results_tree, c, False)
            self.results_tree.heading(col_id, text=config["text"], command=sort_command)
            
            if col_id == "#0":
                self.results_tree.column(col_id, width=config["width"], stretch=tk.YES, anchor='w')
            elif col_id in ["Size", "Modified", "Accessed", "Changed"]:
                self.results_tree.column(col_id, width=config["width"], stretch=tk.NO, anchor='e')
            else:
                self.results_tree.column(col_id, width=config["width"], stretch=tk.YES, anchor='w')

        v_scrollbar = ttk.Scrollbar(results_frame, orient="vertical", command=self.results_tree.yview)
        h_scrollbar = ttk.Scrollbar(results_frame, orient="horizontal", command=self.results_tree.xview)
        self.results_tree.config(yscrollcommand=v_scrollbar.set, xscrollcommand=h_scrollbar.set)
        
        v_scrollbar.pack(side="right", fill="y")
        h_scrollbar.pack(side="bottom", fill="x")
        self.results_tree.pack(fill="both", expand=True)
        
        self.results_tree.bind('<Double-1>', self._open_folder_in_finder)
        
        # Status Label (Uses the 'Taller.TLabel' style)
        self.status_label = ttk.Label(self.master, text="Ready.", relief=tk.SUNKEN, anchor="w", style='Taller.TLabel')
        self.status_label.pack(fill="x", padx=10, pady=(0, 5))

    
    # --- THREADING & EXECUTION METHODS (PRIORITY 1) ---
    
    def _set_running_state(self, running):
        """Sets the state of the Run/Cancel buttons and progress bar."""
        if running:
            self.run_button.config(state=tk.DISABLED)
            self.cancel_button.config(state=tk.NORMAL)
            self.progress_bar.start()
            self._update_status("Searching...")
        else:
            self.run_button.config(state=tk.NORMAL)
            self.cancel_button.config(state=tk.DISABLED)
            self.progress_bar.stop()

    def _start_search(self):
        """Kicks off the find process in a separate thread."""
        
        self._set_running_state(True)
        self._log_error("") # Clear previous errors
        self.temp_stderr = "" # Clear temporary stderr holder

        try:
            # _build_find_command now returns either a list (shell=False) or a string (shell=True)
            find_command = self._build_find_command()
            self.results_tree.delete(*self.results_tree.get_children())
            self.file_data = {}

            # Display command being run (Handle list or string output)
            if isinstance(find_command, list):
                # Ensure the display command is correctly quoted using shlex.quote
                quoted_command = ' '.join(shlex.quote(arg) for arg in find_command)
            else:
                quoted_command = find_command # It's already the full string command

            self.command_output.config(state='normal')
            self.command_output.delete(0, tk.END)
            self.command_output.insert(0, quoted_command)
            self.command_output.config(state='readonly')
            self.command_status_label.config(text="Running command:")

            # Start the search thread
            self.search_thread = threading.Thread(
                target=self._execute_search_threaded, 
                args=(find_command,)
            )
            self.search_thread.daemon = True 
            self.search_thread.start()

            # Start checking the output queue periodically (Tkinter safe loop)
            self.master.after(100, self._process_stream_output)

        except Exception as e:
            self._finalize_search(success=False, error=f"Failed to start search thread: {e}")


    def _execute_search_threaded(self, command):
        """
        Executes the find command in a worker thread using Popen.
        Uses shell=True if the command is a string (meaning it contains a pipe).
        """
        is_shell_command = isinstance(command, str)
        
        try:
            # Use Popen to get streaming output
            self.process = subprocess.Popen(
                command, 
                stdout=subprocess.PIPE, 
                stderr=subprocess.PIPE,
                text=True, 
                bufsize=1,
                shell=is_shell_command # THIS IS THE CRITICAL CHANGE
            )
            
            # Stream stdout line by line and put into queue
            if self.process.stdout:
                for line in self.process.stdout:
                    if self.process.poll() is not None and not line.strip(): # Check if process terminated early
                        break
                    # IMPORTANT: For piped commands (like 'find ... | xargs grep'), the final output 
                    # is the file path list, which must be inserted into the tree.
                    self.output_queue.put(('result', line.strip()))

            # Wait for process to finish
            self.process.wait()

            # Read stderr
            stderr_output = self.process.stderr.read() if self.process.stderr else ""
            if stderr_output:
                self.output_queue.put(('error_output', stderr_output))
                
            # Signal the end of the search
            self.output_queue.put(('complete', self.process.returncode))

        except Exception as e:
            # Signal a hard error in the worker thread
            self.output_queue.put(('hard_error', f"Subprocess execution failed: {e}"))
        finally:
            # Ensure process handle is cleared in the thread context
            pass 

    def _process_stream_output(self):
        """Checks the queue for results/errors and updates the GUI."""
        
        # Process all items currently in the queue
        while not self.output_queue.empty():
            try:
                item_type, data = self.output_queue.get_nowait()
            except queue.Empty:
                break
            
            if item_type == 'result':
                self._insert_result_into_tree(data)
                
            elif item_type == 'error_output':
                # Store stderr output for final display
                self.temp_stderr = data
                
            elif item_type == 'complete':
                self.command_status_label.config(text="Ran command:")
                # The search is done, finalize the status
                self._finalize_search(success=True, return_code=data)
                return # Exit the after loop
            
            elif item_type == 'hard_error':
                self.command_status_label.config(text="Ran command (Error):")
                self._finalize_search(success=False, error=data)
                return # Exit the after loop

        # If the thread is still running, check again soon
        if self.search_thread and self.search_thread.is_alive():
            self.master.after(100, self._process_stream_output)

    def _cancel_search(self):
        """Terminates the running subprocess and cleans up the thread."""
        if self.process:
            # Send SIGTERM to the subprocess
            self.process.terminate() 
            self._finalize_search(success=False, status_message="Search CANCELLED by user.", color='blue')

    def _finalize_search(self, success, error=None, status_message=None, color=None, return_code=None):
        """Cleans up the state and updates the GUI with the final result."""
        
        self._set_running_state(False)
        self.process = None
        self.search_thread = None

        count = len(self.results_tree.get_children())
        
        if status_message:
            self._update_status(status_message, color=color or 'black')
        elif error:
            self._log_error(error, is_exception=True)
            self._update_status(f"Search FAILED: {error}", 'red')
        elif self.temp_stderr or (return_code is not None and return_code != 0):
            # Handle stderr from the process
            self._log_error(self.temp_stderr or f"Process exited with non-zero code: {return_code}")
            self._update_status(f"Completed with {count} results. NOTE: Errors occurred (see error box).", 'red')
        elif count == 0:
            self._update_status("Search complete. NO RESULTS FOUND.", 'orange') 
        else:
            self._update_status(f"Search complete. Found {count} results.", 'green')
            
        self.temp_stderr = "" # Reset temp stderr holder
    
    # --- HELPER METHODS ---
    
    def _select_path(self):
        """Opens a dialog to select the starting directory."""
        folder_selected = filedialog.askdirectory(initialdir=self.start_path.get())
        if folder_selected:
            self.start_path.set(folder_selected)

    def _open_help_popup(self):
        """Opens a Help pop-up with examples for 'Other Arguments'."""
        # Create the pop-up window
        help_popup = tk.Toplevel(self.master)
        help_popup.title("Advanced Arguments Examples")
        help_popup.geometry("600x600")
        
        # Add a scrollable text area
        text_frame = ttk.Frame(help_popup)
        text_frame.pack(fill="both", expand=True, padx=10, pady=10)
        
        scrollbar = tk.Scrollbar(text_frame)
        text = tk.Text(text_frame, wrap="word", yscrollcommand=scrollbar.set)
        scrollbar.config(command=text.yview)
        
        # Insert examples
        examples_text = r"""
        === Examples for 'Other Arguments' ===

        1. Permissions:
        - Find files with specific permissions:
          Example: -perm 755 
        - Exclude files with specific permissions:
          Example: ! -perm 644 

        2. Name and Pattern Matching:
        - Exclude temporary files:
          Example: ! -name "*.tmp"
        - Find multiple file types (e.g., .pyc or .log):
          Example: -name "*.pyc" -o -name "*.log"

        3. Date and Time Filters:
        - Modified after January 1, 2025:
          Example: -newermt "2025-01-01"

        4. Actions (Piping requires full command string - use carefully):
        - Delete matching files (USE WITH CAUTION):
          Example: -delete
        - Change permissions to 644:
          Example: -exec chmod 644 {} \;
          
        - Text Search (Piped): 
          Example: -print0 | xargs -0 grep -l "search_string"
          (Note: This requires 'shell=True' mode, handled automatically if '|' is present)
        """
        text.insert("1.0", examples_text)
        text.config(state="disabled")  # Make read-only
        text.pack(side="left", fill="both", expand=True)
        scrollbar.pack(side="right", fill="y")
        
        # Close button
        ttk.Button(help_popup, text="Close", command=help_popup.destroy).pack(pady=5)

    def _update_status(self, message, color='black'):
        """Helper to update the main status bar."""
        self.status_label.config(text=message, foreground=color)

    def _log_error(self, message, is_exception=False):
        """Helper to insert and display errors in the dedicated error box."""
        self.error_output.config(state='normal')
        self.error_output.delete('1.0', tk.END)
        
        if not message:
            self.error_status_label.config(text="Command Errors (stderr):", foreground='red')
            self.error_output.config(state='disabled')
            return

        self.error_output.insert(tk.END, message)
        self.error_output.see('1.0')
        self.error_output.config(state='disabled')
        
        self.master.update_idletasks() 
        
        status_text = "Command Errors (Python Exception) - FOUND:" if is_exception else "Command Errors (stderr) - FOUND:"
        self.error_status_label.config(text=status_text, foreground='red')

    def _build_find_command(self):
        """
        Constructs the full 'find' command based on GUI inputs.
        Returns a list if no pipe is used, or a single string if a pipe is used.
        """
        
        command = [
            "find",
            self.start_path.get() # Do not quote here, shlex.quote will handle it later if needed
        ]

        # Name/iName Filter (Special Case)
        search_name = self.search_name.get()
        if search_name:
            search_arg = "-iname" if self.case_insensitive.get() else "-name"
            # Pattern goes unquoted into the list
            command.extend([search_arg, search_name]) 

        # Iteratively build command using the FIND_FILTERS constant
        for var_name, flag in self.FIND_FILTERS:
            var_instance = getattr(self, var_name, None) 
            val = var_instance.get().strip() if var_instance else ""
            if val:
                # Value goes unquoted into the list
                command.extend([flag, val]) 

        # Append any manually specified arguments
        other_args_val = self.other_args.get().strip()
        
        # Detect pipe to decide on execution mode
        self.use_shell = '|' in other_args_val
        
        if self.use_shell:
            # CRITICAL FIX: Quote all arguments in the command list before joining them into the string.
            # This prevents wildcards like '*' from expanding prematurely in the shell.
            quoted_find_part = [shlex.quote(arg) for arg in command]
            
            full_command_string = ' '.join(quoted_find_part) + ' ' + other_args_val
            return full_command_string
        
        # If no pipe is used, we append the arguments and return a list (safer mode)
        if other_args_val:
            try:
                # Use shlex.split for robust parsing of complex arguments
                extra_args = shlex.split(other_args_val)
                command.extend(extra_args)
            except ValueError:
                self._log_error("Warning: shlex failed to parse 'Other Arguments'. Using simple split.", is_exception=False)
                command.extend(other_args_val.split())
        
        # Check for common action flags that supersede '-print'
        has_action = any(a in other_args_val for a in ['-exec', '-delete', '-ok', '-print0'])
        
        if not has_action:
            # If no explicit action is given in the "Other Arguments" field, 
            # we default back to the list-based output action.
            command.append("-print")
        
        # Ensure the starting path is quoted for Popen list execution
        # (This is a safety check for the non-shell mode)
        if command and command[1] == self.start_path.get():
             command[1] = shlex.quote(command[1])

        return command

    def _insert_result_into_tree(self, path):
        """Processes a single file path and inserts it into the Treeview."""
        if not path:
            return

        folder, name = os.path.split(path)
        
        size_bytes = 0
        mtime_timestamp = 0
        atime_timestamp = 0
        ctime_timestamp = 0
        
        try:
            stat_info = os.stat(path)
            size_bytes = stat_info.st_size
            mtime_timestamp = stat_info.st_mtime
            atime_timestamp = stat_info.st_atime
            ctime_timestamp = stat_info.st_ctime
        except Exception:
            # Skip files we can't stat
            return

        # Format data for display
        human_size = self._human_readable_size(size_bytes)
        date_format = '%Y-%m-%d %H:%M'
        mtime_date = datetime.datetime.fromtimestamp(mtime_timestamp).strftime(date_format)
        atime_date = datetime.datetime.fromtimestamp(atime_timestamp).strftime(date_format)
        ctime_date = datetime.datetime.fromtimestamp(ctime_timestamp).strftime(date_format)
        
        # Insert into Treeview
        item_id = self.results_tree.insert("", tk.END, text=name, 
            values=(folder, human_size, mtime_date, atime_date, ctime_date))
        
        # Store original data for accurate numeric sorting (Raw data storage)
        self.file_data[item_id] = {
            "Name": name, 
            "Folder": folder, 
            "Size_Bytes": size_bytes, 
            "Modified_Timestamp": mtime_timestamp,
            "Accessed_Timestamp": atime_timestamp,
            "Changed_Timestamp": ctime_timestamp
        }
        
    def _open_folder_in_finder(self, event):
        """
        Executes 'open -R <path>' to reveal the selected file or directory in macOS Finder.
        """
        item_id = self.results_tree.focus()
        if not item_id:
            return

        data = self.file_data.get(item_id)
        if not data:
            return

        full_path = os.path.join(data.get("Folder"), data.get("Name"))
        
        try:
            subprocess.run(['open', '-R', full_path], check=False)
        except Exception as e:
            print(f"Error opening item in Finder: {e}")

    def _human_readable_size(self, size_bytes):
        """Converts bytes to KB, MB, or GB."""
        if size_bytes <= 0:
            return "0 B"
        units = ['B', 'KB', 'MB', 'GB']
        i = 0
        while size_bytes >= 1024 and i < len(units) - 1:
            size_bytes /= 1024.0
            i += 1
        return f"{size_bytes:,.2f} {units[i]}"
        
    def _sort_column(self, tree, col_id, reverse):
        """Sorts the Treeview column using internal raw data keys."""
        
        data_key = self.COLUMN_SETUP.get(col_id, {}).get("data_key")

        if data_key in ["Size_Bytes", "Modified_Timestamp", "Accessed_Timestamp", "Changed_Timestamp"]:
            l = [(self.file_data[k][data_key], k) for k in tree.get_children('')]
        else:
            if col_id == "#0":
                l = [(self.file_data[k]["Name"].lower(), k) for k in tree.get_children('')]
            else:
                 l = [(self.file_data[k]["Folder"].lower(), k) for k in tree.get_children('')]


        l.sort(reverse=reverse)

        for index, (val, k) in enumerate(l):
            tree.move(k, '', index)

        tree.heading(col_id, command=lambda: self._sort_column(tree, col_id, not reverse))


if __name__ == "__main__":
    root = tk.Tk()
    app = MyEverythingApp(root)
    root.mainloop()
