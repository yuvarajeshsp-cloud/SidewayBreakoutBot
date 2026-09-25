"""
Sideway Breakout Bot -- MT5 Signal Bridge (Windows GUI)

A desktop window instead of a terminal: runs the same webhook server as
webhook_bridge.py (both share bridge_core.py), but shows every signal
received in a live table, and appends the same rows to signal_log.csv next
to this script so history survives restarts and can be opened in Excel.

Run with:
    python bridge_app.py
or, to avoid a console window popping up alongside it:
    pythonw bridge_app.py
See README.md for how to freeze this into a standalone .exe with PyInstaller.
"""

import csv
import json
import os
import queue
import threading
import tkinter as tk
from tkinter import ttk, messagebox
import urllib.request

from bridge_core import create_app, default_pending_dir

CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bridge_app_config.json")
LOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "signal_log.csv")
CSV_FIELDS = ["time", "action", "group_id", "leg", "symbol", "dir", "entry", "sl", "tp", "status"]

STATUS_COLORS = {
    "queued": "#1e7e34",
    "rejected (bad secret)": "#c0392b",
}


def load_config() -> dict:
    defaults = {"secret": "changeme", "port": 5000, "pending_dir": ""}
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r") as f:
                defaults.update(json.load(f))
        except (ValueError, OSError):
            pass
    return defaults


def save_config(cfg: dict) -> None:
    with open(CONFIG_PATH, "w") as f:
        json.dump(cfg, f, indent=2)


class BridgeApp:
    def __init__(self, root: tk.Tk):
        self.root = root
        root.title("Sideway Breakout Bot -- MT5 Signal Bridge")
        root.geometry("980x520")

        self.cfg = load_config()
        self.secret_var = tk.StringVar(value=self.cfg["secret"])
        self.port_var = tk.StringVar(value=str(self.cfg["port"]))
        self.pending_var = tk.StringVar(value=self.cfg.get("pending_dir") or default_pending_dir())
        self.status_var = tk.StringVar(value="Starting...")
        self.count_var = tk.StringVar(value="0 signals")

        self.event_queue: "queue.Queue[dict]" = queue.Queue()
        self.row_count = 0

        self._build_ui()
        self._ensure_csv_header()
        self._start_server()
        self.root.after(250, self._poll_queue)

    # ---------------------------------------------------------------- UI --
    def _build_ui(self):
        top = ttk.Frame(self.root, padding=8)
        top.pack(fill="x")

        ttk.Label(top, text="Shared Secret:").grid(row=0, column=0, sticky="w")
        secret_entry = ttk.Entry(top, textvariable=self.secret_var, width=28, show="*")
        secret_entry.grid(row=0, column=1, padx=4)
        self.show_secret_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(top, text="show", variable=self.show_secret_var,
                         command=lambda: secret_entry.config(show="" if self.show_secret_var.get() else "*")
                         ).grid(row=0, column=2)
        ttk.Button(top, text="Apply Secret", command=self._apply_secret).grid(row=0, column=3, padx=8)

        ttk.Label(top, text="Port (needs restart):").grid(row=0, column=4, sticky="w", padx=(16, 0))
        ttk.Entry(top, textvariable=self.port_var, width=8).grid(row=0, column=5, padx=4)

        ttk.Label(top, text="Pending folder:").grid(row=1, column=0, sticky="w", pady=(6, 0))
        ttk.Entry(top, textvariable=self.pending_var, width=70).grid(row=1, column=1, columnspan=4, sticky="we", pady=(6, 0))
        ttk.Button(top, text="Open Folder", command=self._open_pending_folder).grid(row=1, column=5, pady=(6, 0))

        status_frame = ttk.Frame(self.root, padding=(8, 0))
        status_frame.pack(fill="x")
        self.status_label = ttk.Label(status_frame, textvariable=self.status_var, foreground="#1e7e34")
        self.status_label.pack(side="left")
        ttk.Button(status_frame, text="Send Test Signal", command=self._send_test_signal).pack(side="right")

        table_frame = ttk.Frame(self.root, padding=8)
        table_frame.pack(fill="both", expand=True)

        columns = ["time", "action", "group_id", "leg", "symbol", "dir", "entry", "sl", "tp", "status"]
        headings = ["Time", "Action", "Group ID", "Leg", "Symbol", "Dir", "Entry", "SL", "TP", "Status"]
        widths = [140, 90, 150, 40, 70, 55, 80, 80, 80, 170]

        self.tree = ttk.Treeview(table_frame, columns=columns, show="headings", height=18)
        for col, head, w in zip(columns, headings, widths):
            self.tree.heading(col, text=head)
            self.tree.column(col, width=w, anchor="center" if col not in ("group_id", "status") else "w")
        vsb = ttk.Scrollbar(table_frame, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=vsb.set)
        self.tree.pack(side="left", fill="both", expand=True)
        vsb.pack(side="right", fill="y")

        self.tree.tag_configure("queued", foreground="#1e7e34")
        self.tree.tag_configure("rejected", foreground="#c0392b")
        self.tree.tag_configure("ignored", foreground="#7f8c8d")

        bottom = ttk.Frame(self.root, padding=8)
        bottom.pack(fill="x")
        ttk.Label(bottom, textvariable=self.count_var).pack(side="left")
        ttk.Button(bottom, text="Clear Table", command=self._clear_table).pack(side="right")
        ttk.Button(bottom, text="Open Log File (CSV)", command=self._open_log_file).pack(side="right", padx=8)

    # ------------------------------------------------------------ Server --
    def _start_server(self):
        port = int(self.port_var.get())
        pending_dir = self.pending_var.get().strip() or default_pending_dir()

        app = create_app(
            get_secret=lambda: self.secret_var.get(),
            get_pending_dir=lambda: self.pending_var.get().strip() or default_pending_dir(),
            on_event=self.event_queue.put,
        )

        def run():
            try:
                self.event_queue.put({"_status": f"Running on port {port}  |  pending: {pending_dir}", "_ok": True})
                app.run(host="0.0.0.0", port=port, threaded=True, use_reloader=False)
            except OSError as e:
                self.event_queue.put({"_status": f"Failed to start on port {port}: {e}", "_ok": False})

        threading.Thread(target=run, daemon=True).start()
        save_config({"secret": self.secret_var.get(), "port": port, "pending_dir": self.pending_var.get().strip()})

    def _apply_secret(self):
        save_config({"secret": self.secret_var.get(), "port": int(self.port_var.get()), "pending_dir": self.pending_var.get().strip()})
        messagebox.showinfo("Applied", "Secret updated -- takes effect immediately, no restart needed.")

    # --------------------------------------------------------------- CSV --
    def _ensure_csv_header(self):
        if not os.path.exists(LOG_PATH):
            with open(LOG_PATH, "w", newline="") as f:
                csv.DictWriter(f, fieldnames=CSV_FIELDS).writeheader()

    def _append_csv(self, record: dict):
        with open(LOG_PATH, "a", newline="") as f:
            csv.DictWriter(f, fieldnames=CSV_FIELDS).writerow({k: record.get(k, "") for k in CSV_FIELDS})

    # ------------------------------------------------------------ Events --
    def _poll_queue(self):
        try:
            while True:
                record = self.event_queue.get_nowait()
                if "_status" in record:
                    self.status_var.set(record["_status"])
                    self.status_label.configure(foreground="#1e7e34" if record.get("_ok") else "#c0392b")
                    continue
                self._add_row(record)
                self._append_csv(record)
        except queue.Empty:
            pass
        self.root.after(250, self._poll_queue)

    def _add_row(self, record: dict):
        status = record.get("status", "")
        tag = "queued" if status == "queued" else ("rejected" if status.startswith("rejected") else "ignored")
        values = [record.get(c, "") for c in ["time", "action", "group_id", "leg", "symbol", "dir", "entry", "sl", "tp", "status"]]
        self.tree.insert("", 0, values=values, tags=(tag,))
        self.row_count += 1
        self.count_var.set(f"{self.row_count} signals")

    # ------------------------------------------------------------- utils --
    def _clear_table(self):
        for item in self.tree.get_children():
            self.tree.delete(item)
        self.row_count = 0
        self.count_var.set("0 signals")

    def _open_pending_folder(self):
        path = self.pending_var.get().strip() or default_pending_dir()
        os.makedirs(path, exist_ok=True)
        os.startfile(path)  # Windows only, matches this app's target platform

    def _open_log_file(self):
        self._ensure_csv_header()
        os.startfile(LOG_PATH)

    def _send_test_signal(self):
        port = self.port_var.get()
        payload = json.dumps({
            "v": 1, "action": "OPEN", "secret": self.secret_var.get(),
            "group_id": f"MANUAL_TEST_{int(threading.get_ident()) % 100000}",
            "leg": 1, "legs_total": 1, "symbol": "TESTSYMBOL", "dir": "BUY",
            "entry": 1.0, "sl": 0.99, "tp": 1.02,
        }).encode()
        req = urllib.request.Request(
            f"http://127.0.0.1:{port}/webhook", data=payload,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        try:
            urllib.request.urlopen(req, timeout=3)
        except Exception as e:
            messagebox.showerror("Test signal failed", str(e))


if __name__ == "__main__":
    root = tk.Tk()
    BridgeApp(root)
    root.mainloop()
