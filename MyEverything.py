#!/usr/bin/env python3
import tkinter as tk
from tkinter import filedialog, ttk
import subprocess
import shlex
import os
import datetime 
import sys 

class MyEverythingApp:
    
    # --- 1. CONFIGURATION CONSTANTS (Leaner, Easier to Modify) ---
    
    # Defines Treeview column properties: (header_text, width, internal_data_key)
    # The internal_data_key is used to fetch raw data from self.file_data for accurate numeric sorting.
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
        master.geometry("1000x750")

        # --- Variables (Base) ---
        self.search_name = tk.StringVar(value="*")
        self.start_path = tk.StringVar(value=os.path.expanduser("~"))
        self.case_insensitive = tk.BooleanVar(value=True) 
        self.file_type = tk.StringVar(value="f") 

        # --- Variables (Time and Size Filters) ---
        self.size_val = tk.StringVar(value="")
        self.mtime_val = tk.StringVar(value="")
        self.atime_val = tk.StringVar(value="")
        self.ctime_val = tk.StringVar(value="")
        
        # Internal dictionary to store file metadata (raw size/timestamps) for accurate sorting
        self.file_data = {}

        # --- Build GUI ---
        self._create_widgets()

    def _create_widgets(self):
        """Builds all GUI components using the centralized COLUMN_SETUP."""
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

        # 2. Options Frame (File Type and Size)
        options_frame = ttk.LabelFrame(self.master, text="⚙️ Type and Size Filters")
        options_frame.pack(padx=10, pady=5, fill="x")
        
        # File Type (-type)
        ttk.Label(options_frame, text="File Type (-type):").grid(row=0, column=0, padx=5, pady=5, sticky="w")
        ttk.Radiobutton(options_frame, text="File (f)", variable=self.file_type, value="f").grid(row=0, column=1, padx=5, pady=5)
        ttk.Radiobutton(options_frame, text="Directory (d)", variable=self.file_type, value="d").grid(row=0, column=2, padx=5, pady=5)
        ttk.Radiobutton(options_frame, text="Any Type", variable=self.file_type, value="").grid(row=0, column=3, padx=5, pady=5)
        
        # Size Filter 
        size_desc = "Size (-size): +/-N[cKMG] (e.g., +10M = >10MB, -500k = <500KB)"
        ttk.Label(options_frame, text=size_desc).grid(row=1, column=0, columnspan=4, padx=5, pady=5, sticky="w")
        ttk.Entry(options_frame, textvariable=self.size_val, width=15).grid(row=1, column=4, padx=5, pady=5, sticky="w")
        
        options_frame.grid_columnconfigure(4, weight=1)

        # 3. Time Filter Frame
        time_desc = "Days: (+N = >N full days ago; -N = <N full days ago)"
        time_frame = ttk.LabelFrame(self.master, text=f"⌚ Time Filters {time_desc}")
        time_frame.pack(padx=10, pady=5, fill="x")
        
        ttk.Label(time_frame, text="Modified (-mtime):").grid(row=0, column=0, padx=5, pady=5, sticky="w")
        ttk.Entry(time_frame, textvariable=self.mtime_val, width=5).grid(row=0, column=1, padx=5, sticky="w")

        ttk.Label(time_frame, text="Accessed (-atime):").grid(row=0, column=2, padx=(20, 5), pady=5, sticky="w")
        ttk.Entry(time_frame, textvariable=self.atime_val, width=5).grid(row=0, column=3, padx=5, sticky="w")
        
        ttk.Label(time_frame, text="Changed (-ctime):").grid(row=0, column=4, padx=(20, 5), pady=5, sticky="w")
        ttk.Entry(time_frame, textvariable=self.ctime_val, width=5).grid(row=0, column=5, padx=5, sticky="w")
        
        time_frame.grid_columnconfigure(5, weight=1)

        # 4. Execute Button
        ttk.Button(self.master, text="▶️ Run Find Command", command=self.run_find).pack(pady=5, padx=10, fill="x")

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
        
        # Use constants for explicit color settings
        self.error_output = tk.Text(error_text_frame, height=4, state='disabled', wrap='word', 
                                    font=('Courier', 10), background=self.ERROR_BG_COLOR, 
                                    foreground=self.ERROR_FG_COLOR)
        
        error_scrollbar = ttk.Scrollbar(error_text_frame, command=self.error_output.yview)
        error_scrollbar.pack(side="right", fill="y")
        self.error_output.config(yscrollcommand=error_scrollbar.set)
        
        self.error_output.pack(side="left", fill="x", expand=True)
        # ------------------------------------

        # 5. Results Area
        ttk.Label(self.master, text="Results (Click headers to sort):").pack(padx=10, pady=2, anchor="w")
        
        results_frame = ttk.Frame(self.master)
        results_frame.pack(padx=10, pady=5, fill="both", expand=True)

        # Build columns list from keys in COLUMN_SETUP
        column_ids = list(self.COLUMN_SETUP.keys())[1:] # Skip "#0"
        self.results_tree = ttk.Treeview(results_frame, columns=column_ids, show="tree headings") 
        
        # Iterate over COLUMN_SETUP to configure columns and headings
        for col_id, config in self.COLUMN_SETUP.items():
            sort_command = lambda c=col_id: self._sort_column(self.results_tree, c, False)
            self.results_tree.heading(col_id, text=config["text"], command=sort_command)
            
            # Configure column width/stretch
            if col_id == "#0":
                self.results_tree.column(col_id, width=config["width"], stretch=tk.YES, anchor='w')
            elif col_id in ["Size", "Modified", "Accessed", "Changed"]:
                self.results_tree.column(col_id, width=config["width"], stretch=tk.NO, anchor='e')
            else:
                self.results_tree.column(col_id, width=config["width"], stretch=tk.YES, anchor='w')


        # Scrollbars
        v_scrollbar = ttk.Scrollbar(results_frame, orient="vertical", command=self.results_tree.yview)
        h_scrollbar = ttk.Scrollbar(results_frame, orient="horizontal", command=self.results_tree.xview)
        self.results_tree.config(yscrollcommand=v_scrollbar.set, xscrollcommand=h_scrollbar.set)
        
        v_scrollbar.pack(side="right", fill="y")
        h_scrollbar.pack(side="bottom", fill="x")
        self.results_tree.pack(fill="both", expand=True)
        
        # FEATURE: Bind double-click to open the folder in Finder
        self.results_tree.bind('<Double-1>', self._open_folder_in_finder)
        
        # Status Label
        self.status_label = ttk.Label(self.master, text="Ready.", relief=tk.SUNKEN, anchor="w")
        self.status_label.pack(fill="x", padx=10, pady=(0, 5))

    
    # --- HELPER METHODS ---
    
    def _select_path(self):
        """Opens a dialog to select the starting directory."""
        folder_selected = filedialog.askdirectory(initialdir=self.start_path.get())
        if folder_selected:
            self.start_path.set(folder_selected)

    def _update_status(self, message, color='black'):
        """Helper to update the main status bar."""
        self.status_label.config(text=message, foreground=color)

    def _log_error(self, message, is_exception=False):
        """Helper to insert and display errors in the dedicated error box."""
        self.error_output.config(state='normal')
        self.error_output.delete('1.0', tk.END)
        
        # If message is empty, we just clear the box and reset the label, don't update status
        if not message:
            self.error_status_label.config(text="Command Errors (stderr):", foreground='red')
            self.error_output.config(state='disabled')
            return

        self.error_output.insert(tk.END, message)
        self.error_output.see('1.0') # Scrolls to the top
        self.error_output.config(state='disabled')
        
        # Force redraw to ensure visibility
        self.master.update_idletasks() 
        
        status_text = "Command Errors (Python Exception) - FOUND:" if is_exception else "Command Errors (stderr) - FOUND:"
        self.error_status_label.config(text=status_text, foreground='red')

    def _build_find_command(self):
        """Constructs the full 'find' command based on GUI inputs (EFFICIENT)."""
        
        command = [
            "find",
            self.start_path.get()
        ]

        # Name/iName Filter (Special Case)
        search_arg = "-iname" if self.case_insensitive.get() else "-name"
        command.extend([search_arg, self.search_name.get()])

        # Iteratively build command using the FIND_FILTERS constant (Leaner logic)
        for var_name, flag in self.FIND_FILTERS:
            # Use getattr to fetch the correct StringVar instance
            var_instance = getattr(self, var_name, None) 
            if var_instance and var_instance.get().strip():
                command.extend([flag, var_instance.get().strip()])
        
        # The macOS 'find' command implicitly prints unless an action is specified.
        # We explicitly add -print to ensure consistent behavior across most environments.
        command.append("-print")
        
        return command

    def _open_folder_in_finder(self, event):
        """
        FEATURE: Executes 'open -R <path>' to reveal the selected file or directory in macOS Finder.
        This method is bound to the double-click event on the results tree.
        """
        
        # Identify the selected item
        item_id = self.results_tree.focus()
        if not item_id:
            return

        # Retrieve the necessary data from internal storage
        data = self.file_data.get(item_id)
        if not data:
            return

        # Construct the full path
        full_path = os.path.join(data.get("Folder"), data.get("Name"))
        
        # Execute the 'open -R' command (macOS native command)
        try:
            # -R flag reveals the file/folder in Finder, highlighting the item.
            subprocess.run(['open', '-R', full_path], check=False)
        except Exception as e:
            # Log this error specifically to console or a debug log, as it's not a 'find' error
            print(f"Error opening item in Finder: {e}")


    def run_find(self):
        """Executes the constructed find command and displays output."""
        
        self.results_tree.delete(*self.results_tree.get_children())
        self.file_data = {}
        self._update_status("Searching...")
        self._log_error("") # Clear previous errors

        try:
            find_command = self._build_find_command()
            quoted_command = ' '.join(shlex.quote(arg) for arg in find_command)

            # 1. SET RUNNING STATUS
            self.command_status_label.config(text="Running command:")
            self.command_output.config(state='normal')
            self.command_output.delete(0, tk.END)
            self.command_output.insert(0, quoted_command)
            self.command_output.config(state='readonly')
            self.master.update() 

            process = subprocess.run(
                find_command, 
                capture_output=True, 
                text=True, 
                check=False,
                timeout=300
            )

            # 2. UPDATE TO RAN STATUS
            self.command_status_label.config(text="Ran command:")

            results = process.stdout.splitlines()
            count = 0
            
            for path in results:
                if not path:
                    continue
                
                folder, name = os.path.split(path)
                
                size_bytes = 0
                mtime_timestamp = 0
                atime_timestamp = 0
                ctime_timestamp = 0
                
                try:
                    # Collect raw data for robust sorting
                    stat_info = os.stat(path)
                    size_bytes = stat_info.st_size
                    mtime_timestamp = stat_info.st_mtime
                    atime_timestamp = stat_info.st_atime
                    ctime_timestamp = stat_info.st_ctime
                except Exception:
                    # Skip files we can't stat (e.g., permission denied, broken symlink)
                    continue

                # Format data for display (separate from raw data storage)
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
                
                count += 1

            if process.stderr:
                self._log_error(process.stderr)
                self._update_status(f"Completed with {count} results. NOTE: Errors occurred (see error box).", 'red')
            elif count == 0:
                # FEATURE: No Results Found
                self._update_status("Search complete. NO RESULTS FOUND.", 'orange') 
            else:
                self._update_status(f"Search complete. Found {count} results.", 'green')

        except Exception as e:
            self.command_status_label.config(text="Ran command (Error):")
            self._log_error(f"An unexpected Python error occurred:\n{e}", is_exception=True)
            self._update_status(f"An unexpected error occurred: {e}", 'red')

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
        """
        Sorts the Treeview column using internal raw data keys.
        (LEANER LOGIC: Looks up data key from COLUMN_SETUP instead of using a long if/elif chain.)
        """
        
        # Retrieve the internal data key from the centralized configuration
        data_key = self.COLUMN_SETUP.get(col_id, {}).get("data_key")

        if data_key in ["Size_Bytes", "Modified_Timestamp", "Accessed_Timestamp", "Changed_Timestamp"]:
            # Numeric/Timestamp sort: use the raw data stored in self.file_data
            l = [(self.file_data[k][data_key], k) for k in tree.get_children('')]
        else:
            # String sort (Name/Folder): use the data stored in self.file_data
            if col_id == "#0":
                l = [(self.file_data[k]["Name"].lower(), k) for k in tree.get_children('')]
            else:
                 l = [(self.file_data[k]["Folder"].lower(), k) for k in tree.get_children('')]


        l.sort(reverse=reverse)

        # Rearrange items in the Treeview
        for index, (val, k) in enumerate(l):
            tree.move(k, '', index)

        # Reverse sort direction for next click
        tree.heading(col_id, command=lambda: self._sort_column(tree, col_id, not reverse))


if __name__ == "__main__":
    root = tk.Tk()
    app = MyEverythingApp(root)
    root.mainloop()
