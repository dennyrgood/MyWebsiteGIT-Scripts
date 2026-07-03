// Table Rendering

function renderTable(tab) {
    const dataViewContainer = document.getElementById('data-table-container');
    
    if (allRows.length === 0) {
        dataViewContainer.innerHTML = '<p>No data found or table is empty.</p>';
        return;
    }

    const table = document.createElement('table');
    table.className = 'data-table';
    
    const thead = table.createTHead();
    const headers = ['Action', 'Row'].concat(FIELD_MAP.map(f => f.label));
    const headerRow = thead.insertRow();
    headers.forEach(text => {
        const th = document.createElement('th');
        th.textContent = text;
        headerRow.appendChild(th);
    });

    const tbody = table.createTBody();
    allRows.forEach(row => {
        const derived = calculateDerivedFields(row.code);
        
        const tr = tbody.insertRow();
        tr.dataset.rowIndex = row.row_index;

        const cellAction = tr.insertCell();
        cellAction.innerHTML = '<button class="btn-save" onclick="toggleEdit(' + row.row_index + ', this)">Edit</button>' +
            '<button class="btn-duplicate" onclick="duplicateRow(' + row.row_index + ')">Dup</button>' +
            '<button class="btn-delete" onclick="deleteRow(' + row.row_index + ', \'' + escapeHtml(row.title) + '\')">Delete</button>';

        const cellIndex = tr.insertCell();
        cellIndex.textContent = row.row_index;

        FIELD_MAP.forEach(field => {
            const td = tr.insertCell();
            td.dataset.fieldKey = field.key;
            
            let displayValue = row[field.key];
            if (field.calculated && derived[field.key] !== undefined) {
                displayValue = derived[field.key];
            }
            
            td.textContent = formatValue(field.key, displayValue);
            if (field.calculated) td.classList.add('calculated-field');
        });
    });

    dataViewContainer.innerHTML = '';
    dataViewContainer.appendChild(table);
}