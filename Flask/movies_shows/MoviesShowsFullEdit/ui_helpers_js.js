// UI Helper Functions

function openTab(tabName) {
    document.querySelectorAll('.tab-content').forEach(tab => tab.classList.add('hidden'));
    document.querySelectorAll('.tab-button').forEach(btn => btn.classList.remove('active'));

    const target = document.getElementById(tabName);
    if (target) target.classList.remove('hidden');

    const btn = Array.from(document.querySelectorAll('.tab-button')).find(b => {
        const oc = b.getAttribute('onclick') || '';
        if (oc.includes(`openTab('${tabName}')`) || oc.includes(`openTab("${tabName}")`)) return true;
        if (b.dataset && b.dataset.tab === tabName) return true;
        return false;
    });
    if (btn) btn.classList.add('active');

    if (tabName === 'data-view' && typeof loadRows === 'function') {
        loadRows('data-view');
    }
}
window.openTab = openTab;

function showMessage(text, type, tab) {
    const msgDiv = document.getElementById(tab + '-message');
    msgDiv.textContent = text;
    msgDiv.className = 'message show ' + type;
    msgDiv.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    setTimeout(() => msgDiv.classList.remove('show'), 5000);
}

function buildBackendDisplayMessage(data) {
    let displayMessage = `✗ ${data && data.message ? data.message : 'Unknown error'}`;

    try {
        const msg = (data && data.message) ? data.message : '';
        let suggestions = '';

        if ((msg.includes("Invalid argument") || msg.includes("Errno 22")) &&
            (msg.includes("MoviesShows.xlsx") || msg.includes("OneDrive") || msg.includes("MS/MoviesShows.xlsx"))) {
            suggestions += ' Is the file still in the cloud?';
        }

        if ((msg.includes("Permission denied") || msg.includes("Errno 13")) &&
            (msg.includes("MoviesShows.xlsx") || msg.includes("OneDrive") || msg.includes("MS/MoviesShows.xlsx"))) {
            suggestions += ' Is the file open?';
        }

        if (suggestions) {
            displayMessage += suggestions;
        }
    } catch (innerErr) {
        // ignore parsing errors
    }

    return displayMessage;
}

function showBackendError(data, tab) {
    const displayMessage = buildBackendDisplayMessage(data);
    showMessage(displayMessage, 'error', tab);
    return displayMessage;
}

function escapeHtml(text) {
    if (!text) return '';
    return String(text).replace(/'/g, "\\'").replace(/"/g, '&quot;');
}

async function loadRows(tab) {
    showMessage('Loading data from Excel...', 'warning', tab);
    try {
        const response = await fetch(BACKEND_URL + '/api/data');
        const data = await response.json();
        if (response.ok && data.status === 'success') {
            allRows = data.data.sort((a, b) => (a.row_index || 0) - (b.row_index || 0));
            renderTable(tab);
            showMessage('Successfully loaded ' + allRows.length + ' rows.', 'success', tab);
        } else {
            const display = showBackendError(data, tab);
            document.getElementById('data-table-container').innerHTML = '<p style="color: red;">Error: ' + escapeHtml(display) + '</p>';
        }
    } catch (error) {
        showMessage('Network error: Could not connect to backend. ' + error.message, 'error', tab);
        document.getElementById('data-table-container').innerHTML = '<p style="color: red;">Network Error</p>';
    }
}