import pandas as pd
import re
import sys

# Configuration
CONFIG = {
    'input_file': 'input.xlsm',
    'output_file': 'output.xlsx',
    'selected_columns': [0, 1, 2, 13, 15, 18, 19],
    'column_names': ['A', 'B', 'C', 'N', 'P', 'S', 'T'],
    'transform_column': 'C',
    'output_column': 'U'
}

# Transformation rules - each rule is a dict with pattern and template
RULES = [
    {
        'pattern': 'dhm4',
        'template': 'old dhm standard {transformed}'
    },
    {
        'pattern': '5eba!',
        'template': 'new dhm standard {transformed}'
    },
    {
        'pattern': 'ljm',
        'template': 'old Laura standard {transformed}'
    },
    {
        'pattern': 'ldm',
        'template': 'old joint standard {transformed}'
    }
]

def apply_lowercase_mask(text):
    """Replace lowercase a-z with '*', keep everything else as is."""
    return ''.join(['*' if c.islower() else c for c in text])

def transform_with_rule(value, pattern, template):
    """Apply a single transformation rule to a value."""
    if not isinstance(value, str):
        return None
    
    value_lower = value.lower()
    
    # Check if string starts with pattern
    if value_lower.startswith(pattern):
        # Get suffix after pattern (using original casing)
        suffix = value[len(pattern):]
        
        if suffix:
            # Keep first character as is, mask rest
            first_char = suffix[0]
            rest = apply_lowercase_mask(suffix[1:])
            transformed = first_char + rest
        else:
            transformed = ''
        
        # Format using template
        return template.format(transformed=transformed)
    
    return None

def transform_value(value):
    """Apply all transformation rules in order."""
    for rule in RULES:
        result = transform_with_rule(value, rule['pattern'], rule['template'])
        if result is not None:
            return result
    
    # No rule matched
    return ""

def main(input_file=None, output_file=None):
    """Main processing function."""
    # Use parameters or fall back to config
    input_file = input_file or CONFIG['input_file']
    output_file = output_file or CONFIG['output_file']
    
    # Load the input file
    print(f"Loading {input_file}...")
    df = pd.read_excel(input_file, engine='openpyxl')
    
    # Select specified columns
    df = df.iloc[:, CONFIG['selected_columns']]
    
    # Rename columns
    df.columns = CONFIG['column_names']
    
    # Apply transformation
    transform_col = CONFIG['transform_column']
    output_col = CONFIG['output_column']
    df[output_col] = df[transform_col].apply(transform_value)
    
    # Save output
    df.to_excel(output_file, index=False)
    print(f"Processed file saved as {output_file}")

if __name__ == '__main__':
    # Allow command-line arguments: python script.py [input_file] [output_file]
    if len(sys.argv) > 1:
        input_file = sys.argv[1]
        output_file = sys.argv[2] if len(sys.argv) > 2 else 'output.xlsx'
        main(input_file, output_file)
    else:
        main()
