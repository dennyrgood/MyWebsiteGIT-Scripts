#!/usr/bin/env python3
import tkinter as tk
from tkinter import filedialog, ttk
import subprocess
import shlex
import os
import datetime 

class MyEverythingApp:
    def __init__(self, master):
        self.master = master
        master.title("MyEverything: macOS Find GUI")
        master.geometry("1000x700")

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
        
        # Internal dictionary to store file metadata for sorting
        self.file_data = {}

        # --- Build GUI ---
        self._create_widgets()

    def _create_widgets(self):
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

        # Configure columns for input_frame
        input_frame.grid_columnconfigure(1, weight=1)

        # 2. Options Frame (File Type and Size)
        options_frame = ttk.LabelFrame(self.master, text="⚙️ Type and Size Filters")
        options_frame.pack(padx=10, pady=5, fill="x")
        
        # File Type (-type)
        ttk.Label(options_frame, text="File Type (-type):").grid(row=0, column=0, padx=5, pady=5, sticky="w")
        ttk.Radiobutton(options_frame, text="File (f)", variable=self.file_type, value="f").grid(row=0, column=1, padx=5, pady=5)
        ttk.Radiobutton(options_frame, text="Directory (d)", variable=self.file_type, value="d").grid(row=0, column=2, padx=5, pady=5)
        ttk.Radiobutton(options_frame, text="Any Type", variable=self.file_type, value="").grid(row=0, column=3, padx=5, pady=5)
        
        # Size Filter (NEW)
        ttk.Label(options_frame, text="Size (-size +/-N[cKMG]):").grid(row=1, column=0, padx=5, pady=5, sticky="w")
        ttk.Entry(options_frame, textvariable=self.size_val, width=15).grid(row=1, column=1, padx=5, pady=5, sticky="w")
        
        options_frame.grid_columnconfigure(3, weight=1)

        # 3. Time Filter Frame (NEW: For -mtime, -atime, -ctime)
        time_frame = ttk.LabelFrame(self.master, text="⌚ Time Filters (Days: +/-N)")
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

        # 5. Results Area
        ttk.Label(self.master, text="Results (Click headers to sort):").pack(padx=10, pady=2, anchor="w")
        
        results_frame = ttk.Frame(self.master)
        results_frame.pack(padx=10, pady=5, fill="both", expand=True)

        # Treeview setup for columns
        self.results_tree = ttk.Treeview(results_frame, 
                                         columns=("Folder", "Size", "Date"), 
                                         show="tree headings") # FIX: Explicitly includes 'tree' to force #0 header visibility
        
        # Column Headings & Sorting (REQUIRED COLUMNS)
        self.results_tree.heading("#0", text="File Name", command=lambda: self._sort_column(self.results_tree, "#0", False))
        self.results_tree.heading("Folder", text="Folder", command=lambda: self._sort_column(self.results_tree, "Folder", False))
        self.results_tree.heading("Size", text="Size", command=lambda: self._sort_column(self.results_tree, "Size", False))
        self.results_tree.heading("Date", text="Last Modified", command=lambda: self._sort_column(self.results_tree, "Date", False))
        
        # Column widths
        self.results_tree.column("#0", width=250, stretch=tk.YES, anchor='w') 
        self.results_tree.column("Folder", width=350, stretch=tk.YES, anchor='w')
        self.results_tree.column("Size", width=100, stretch=tk.NO, anchor='e')
        self.results_tree.column("Date", width=150, stretch=tk.NO, anchor='e')

        # Scrollbars
        v_scrollbar = ttk.Scrollbar(results_frame, orient="vertical", command=self.results_tree.yview)
        h_scrollbar = ttk.Scrollbar(results_frame, orient="horizontal", command=self.results_tree.xview)
        self.results_tree.config(yscrollcommand=v_scrollbar.set, xscrollcommand=h_scrollbar.set)
        
        v_scrollbar.pack(side="right", fill="y")
        h_scrollbar.pack(side="bottom", fill="x")
        self.results_tree.pack(fill="both", expand=True)
        
        # Status Label
        self.status_label = ttk.Label(self.master, text="Ready.", relief=tk.SUNKEN, anchor="w")
        self.status_label.pack(fill="x", padx=10, pady=(0, 5))


    def _select_path(self):
        """Opens a dialog to select the starting directory."""
        folder_selected = filedialog.askdirectory(initialdir=self.start_path.get())
        if folder_selected:
            self.start_path.set(folder_selected)

    def _build_find_command(self):
        """Constructs the full 'find' command based on GUI inputs."""
        
        command = [
            "find",
            self.start_path.get()
        ]

        # Add -type 
        file_type_val = self.file_type.get()
        if file_type_val:
            command.extend(["-type", file_type_val])
        
        # Add -name or -iname
        search_arg = "-iname" if self.case_insensitive.get() else "-name"
        command.extend([search_arg, self.search_name.get()])

        # Add Size Filter (-size)
        size_val = self.size_val.get().strip()
        if size_val:
            command.extend(["-size", size_val])
            
        # Add Time Filters (using only the first non-empty one to avoid conflicts)
        if self.mtime_val.get().strip():
            command.extend(["-mtime", self.mtime_val.get().strip()])
        elif self.atime_val.get().strip():
            command.extend(["-atime", self.atime_val.get().strip()])
        elif self.ctime_val.get().strip():
            command.extend(["-ctime", self.ctime_val.get().strip()])
        
        command.append("-print")
        
        return command

    def run_find(self):
        """Executes the constructed find command and displays output in the Treeview."""
        
        # Clear previous Treeview results
        self.results_tree.delete(*self.results_tree.get_children())
        self.file_data = {}
        self.status_label.config(text="Searching...", foreground='black')

        try:
            find_command = self._build_find_command()
            self.status_label.config(text=f"Running: {' '.join(shlex.quote(arg) for arg in find_command)}")
            
            # Execute the command
            process = subprocess.run(
                find_command, 
                capture_output=True, 
                text=True, 
                check=False,
                timeout=300
            )

            results = process.stdout.splitlines()
            count = 0
            
            for path in results:
                if not path:
                    continue
                
                # Use os.path.split to separate file name and folder path
                folder, name = os.path.split(path)
                
                size_bytes = 0
                mtime_timestamp = 0
                
                try:
                    # Fetch metadata (size and mtime) using os.stat
                    stat_info = os.stat(path)
                    size_bytes = stat_info.st_size
                    mtime_timestamp = stat_info.st_mtime
                except Exception:
                    # Handle files not found or permission denied
                    pass

                # Convert size and timestamp for display
                human_size = self._human_readable_size(size_bytes)
                mtime_date = datetime.datetime.fromtimestamp(mtime_timestamp).strftime('%Y-%m-%d %H:%M') if mtime_timestamp else "N/A"
                
                # Insert into Treeview: 'text' goes to the #0 File Name column
                item_id = self.results_tree.insert("", tk.END, text=name, values=(folder, human_size, mtime_date))
                
                # Store original data for accurate numeric sorting
                self.file_data[item_id] = {
                    "Name": name, 
                    "Folder": folder, 
                    "Size_Bytes": size_bytes, 
                    "Date_Timestamp": mtime_timestamp
                }
                
                count += 1

            if process.stderr:
                self.status_label.config(text=f"Completed with {count} results. NOTE: Errors occurred (see terminal).", foreground='red')
                print(f"--- FIND ERRORS ---\n{process.stderr}") 
            else:
                self.status_label.config(text=f"Search complete. Found {count} results.", foreground='green')

        except Exception as e:
            self.status_label.config(text=f"An unexpected error occurred: {e}", foreground='red')

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
        
    def _sort_column(self, tree, col, reverse):
        """Sorts the Treeview column by the relevant stored data."""
        if col == "#0":
            # Sort by File Name (text)
            l = [(tree.item(k, 'text').lower(), k) for k in tree.get_children('')]
        elif col == "Size":
            # Sort by raw size in bytes (numeric)
            l = [(self.file_data[k]["Size_Bytes"], k) for k in tree.get_children('')]
        elif col == "Date":
            # Sort by raw timestamp (numeric)
            l = [(self.file_data[k]["Date_Timestamp"], k) for k in tree.get_children('')]
        else:
            # Sort by Folder (text)
            l = [(tree.set(k, col).lower(), k) for k in tree.get_children('')]

        # Apply the sort order
        l.sort(reverse=reverse)

        # Rearrange items in the Treeview
        for index, (val, k) in enumerate(l):
            tree.move(k, '', index)

        # Reverse sort next time
        tree.heading(col, command=lambda: self._sort_column(tree, col, not reverse))


if __name__ == "__main__":
    root = tk.Tk()
    app = MyEverythingApp(root)
    root.mainloop()
