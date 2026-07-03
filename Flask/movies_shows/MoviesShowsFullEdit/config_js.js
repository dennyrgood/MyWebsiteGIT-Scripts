// Configuration and constants
const BACKEND_URL = 'https://api-edit.ldmathes.cc';

const FIELD_MAP = [
    { key: 'code', label: 'Code', type: 'number', required: true },
    { key: 'B', label: 'Sub', type: 'text', calculated: true },
    { key: 'C', label: 'Pri', type: 'text' },
    { key: 'D', label: 'With', type: 'text', calculated: true },
    { key: 'E', label: 'Avail', type: 'text', calculated: true },
    { key: 'title', label: 'Title', type: 'text', required: true },
    { key: 'col_g', label: 'Next', type: 'text' },
    { key: 'col_h', label: 'Num', type: 'text' },
    { key: 'col_i', label: 'Where', type: 'text' },
    { key: 'col_j', label: 'Date Avail', type: 'text' },
    { key: 'col_k', label: 'URL', type: 'text' },
    { key: 'col_l', label: 'Notes', type: 'text' },
    { key: 'col_m', label: 'Synopsis', type: 'text' }
];

// Global state
let allRows = [];
let currentlyEditingRow = null;