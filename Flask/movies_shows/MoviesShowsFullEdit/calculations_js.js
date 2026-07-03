// Calculate derived fields from code
function calculateDerivedFields(code) {
    const result = { B: '', D: '', E: '' };
    
    if (code === null || code === undefined || code === '') return result;
    
    const numCode = parseFloat(code);
    if (isNaN(numCode)) return result;
    
    // B (Sub): decimal part formatted to 1 decimal place
    const decimal = numCode - Math.floor(numCode);
    result.B = decimal.toFixed(1);
    
    // D (With): based on whole number
    const whole = Math.floor(numCode);
    if (whole === 0) result.D = 'Laura';
    else if (whole === 1) result.D = 'Laura Maybe';
    else if (whole === 2) result.D = 'Not Laura';
    else if (whole === 1000) result.D = 'Laura Only';
    else result.D = '';
    
    // E (Avail): based on decimal part
    const decimalStr = decimal.toFixed(1);
    if (decimalStr === '0.1') result.E = 'Avail Now';
    else if (decimalStr === '0.4') result.E = 'Weekly';
    else if (decimalStr === '0.5') result.E = 'Trying to Find';
    else if (decimalStr === '0.6') result.E = 'Found but $';
    else if (decimalStr === '0.7') result.E = 'Future Date Set';
    else if (decimalStr === '0.8') result.E = 'Announced as Coming';
    else if (decimalStr === '0.9') result.E = 'Unknown if Coming';
    else result.E = '';
    
    return result;
}

function formatValue(key, value) {
    if (value === null || value === undefined || value === '') return '';
    if (key === 'B') {
        const num = parseFloat(value);
        return isNaN(num) ? value : num.toFixed(1);
    }
    if (key === 'C') {
        const num = parseInt(value);
        return isNaN(num) ? value : Math.round(num).toString();
    }
    return value;
}