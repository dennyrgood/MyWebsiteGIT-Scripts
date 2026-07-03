// Edit, Duplicate, Delete Actions

function toggleEdit(rowIndex, button) {
    const row = document.querySelector('tr[data-row-index="' + rowIndex + '"]');
    const isEditing = row.classList.contains('editing');

    if (isEditing) {
        saveRow(rowIndex, row);
        currentlyEditingRow = null;
    } else {
        if (currentlyEditingRow !== null) {
            showMessage('Please save or cancel the currently edited row first.', 'warning', 'data-view');
            return;
        }

        row.classList.add('editing');
        currentlyEditingRow = rowIndex;

        const originalRowData = allRows.find(r => r.row_index === rowIndex);

        row.querySelectorAll('td[data-field-key]').forEach(td => {
            const fieldKey = td.dataset.fieldKey;
            const fieldInfo = FIELD_MAP.find(f => f.key === fieldKey);

            if (fieldInfo.calculated) {
                td.classList.add('calculated-field');
                return;
            }
            
            const originalValue = originalRowData[fieldKey] || '';

            const input = document.createElement('input');
            input.type = fieldInfo.type || 'text';
            input.value = originalValue;
            input.className = 'edit-field';
            input.dataset.key = fieldKey;
            
            if (fieldKey === 'code') {
                input.addEventListener('input', function() {
                    const derived = calculateDerivedFields(this.value);
                    const bCell = row.querySelector('td[data-field-key="B"]');
                    const dCell = row.querySelector('td[data-field-key="D"]');
                    const eCell = row.querySelector('td[data-field-key="E"]');
                    if (bCell) bCell.textContent = derived.B;
                    if (dCell) dCell.textContent = derived.D;
                    if (eCell) eCell.textContent = derived.E;
                });
            }
            
            td.textContent = '';
            td.appendChild(input);
        });
        
        const actionCell = row.cells[0];
        actionCell.innerHTML = '<button class="btn-save" onclick="saveRow(' + rowIndex + ', this.closest(\'tr\'))">Save</button>' +
            '<button class="btn-cancel" onclick="cancelEdit(' + rowIndex + ')">Cancel</button>';
    }
}

function cancelEdit(rowIndex) {
    const row = document.querySelector('tr[data-row-index="' + rowIndex + '"]');
    if (!row) return;

    row.classList.remove('editing');
    currentlyEditingRow = null;
    
    const originalRowData = allRows.find(r => r.row_index === rowIndex);
    const derived = calculateDerivedFields(originalRowData.code);
    
    row.querySelectorAll('td[data-field-key]').forEach(td => {
        const fieldKey = td.dataset.fieldKey;
        const fieldInfo = FIELD_MAP.find(f => f.key === fieldKey);
        
        let rawValue = originalRowData[fieldKey];
        if (fieldInfo.calculated && derived[fieldKey] !== undefined) {
            rawValue = derived[fieldKey];
        }
        
        td.textContent = formatValue(fieldKey, rawValue);
        
        if (fieldInfo.calculated) {
            td.classList.add('calculated-field');
        } else {
            td.classList.remove('calculated-field');
        }
    });

    const actionCell = row.cells[0];
    actionCell.innerHTML = '<button class="btn-save" onclick="toggleEdit(' + rowIndex + ', this)">Edit</button>' +
        '<button class="btn-duplicate" onclick="duplicateRow(' + rowIndex + ')">Dup</button>' +
        '<button class="btn-delete" onclick="deleteRow(' + rowIndex + ', \'' + escapeHtml(originalRowData.title) + '\')">Delete</button>';
}

async function saveRow(rowIndex, row) {
    showMessage('Saving changes...', 'warning', 'data-view');
    
    const payload = { row_index: rowIndex };
    let hasChanges = false;
    
    row.querySelectorAll('.edit-field').forEach(input => {
        payload[input.dataset.key] = input.value;
        hasChanges = true;
    });
    
    if (!hasChanges) {
        showMessage('No changes detected.', 'warning', 'data-view');
        cancelEdit(rowIndex);
        return;
    }

    const requiredFields = FIELD_MAP.filter(f => f.required).map(f => f.key);
    for (const key of requiredFields) {
        if (!payload[key]) {
            const label = FIELD_MAP.find(f => f.key === key).label;
            showMessage(label + ' field cannot be empty.', 'error', 'data-view');
            return;
        }
    }

    try {
        const response = await fetch(BACKEND_URL + '/api/update', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        
        const data = await response.json();
        
        if (response.ok && data.status === 'success') {
            showMessage(data.message, 'success', 'data-view');
            currentlyEditingRow = null;
            loadRows('data-view');
        } else {
            row.classList.remove('editing');
            currentlyEditingRow = null;
            showBackendError(data, 'data-view');
            loadRows('data-view');
        }
    } catch (error) {
        showMessage('Network error: ' + error.message, 'error', 'data-view');
    }
}

async function duplicateRow(rowIndex) {
    showMessage('Duplicating Row ' + rowIndex + '...', 'warning', 'data-view');
    
    const originalRowData = allRows.find(r => r.row_index === rowIndex);
    if (!originalRowData) {
        showMessage('Error: Could not find row data to duplicate.', 'error', 'data-view');
        return;
    }

    const payload = {};
    FIELD_MAP.forEach(field => {
        if (!field.calculated && originalRowData[field.key] !== undefined) {
            const value = originalRowData[field.key];
            payload[field.key] = value !== null && value !== undefined ? String(value).trim() : '';
        }
    });

    try {
        const response = await fetch(BACKEND_URL + '/api/add', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });

        const data = await response.json();

        if (response.ok && data.status === 'success') {
            showMessage(data.message, 'success', 'data-view');
            await loadRows('data-view');
            
            const newRow = allRows[allRows.length - 1];
            if (newRow) {
                setTimeout(() => {
                    const rowElement = document.querySelector('tr[data-row-index="' + newRow.row_index + '"]');
                    if (rowElement) {
                        rowElement.scrollIntoView({ behavior: 'smooth', block: 'center' });
                        const editButton = rowElement.querySelector('.btn-save');
                        if (editButton) {
                            toggleEdit(newRow.row_index, editButton);
                        }
                    }
                }, 100);
            }
        } else {
            showBackendError(data, 'data-view');
        }
    } catch (error) {
        showMessage('Network error: ' + error.message, 'error', 'data-view');
    }
}

async function deleteRow(rowNum, title) {
    showMessage('Attempting to delete Row ' + rowNum + ': ' + title + '...', 'warning', 'data-view');

    try {
        const response = await fetch(BACKEND_URL + '/api/delete', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ row_index: rowNum })
        });
        
        const data = await response.json();
        
        if (response.ok && data.status === 'success') {
            showMessage(data.message, 'success', 'data-view');
            allRows = [];
            loadRows('data-view');
        } else {
            showBackendError(data, 'data-view');
        }
    } catch (error) {
        showMessage('Network error: ' + error.message, 'error', 'data-view');
    }
}